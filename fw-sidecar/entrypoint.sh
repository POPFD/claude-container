#!/bin/bash
# fw-sidecar entrypoint: set up firewall + DNS filter, then run the
# reconcile loop.
#
# Expected runtime:
#   - NET_ADMIN capability (for iptables/ip6tables/ipset/sysctl).
#   - /etc/fw-sidecar/allowlist.yaml baked into the image at build
#     time from repo config/allowlist.yaml. Override with CONFIG env.
#   - DNS_UPSTREAM (default 1.1.1.1) and DNS_UPSTREAM_TLS (0/1) env vars.
#
# Signals:
#   - SIGHUP triggers an immediate reconcile.
#   - SIGTERM/SIGINT shut the loop down cleanly via tini.
set -euo pipefail

DNS_UPSTREAM="${DNS_UPSTREAM:-1.1.1.1}"
DNS_UPSTREAM_TLS="${DNS_UPSTREAM_TLS:-0}"
CONFIG="${CONFIG:-/etc/fw-sidecar/allowlist.yaml}"
UNBOUND_CONF_D="/etc/unbound/unbound.conf.d"
UNBOUND_ALLOWLIST_CONF="${UNBOUND_CONF_D}/allowlist.conf"
RECONCILE_INTERVAL="${RECONCILE_INTERVAL:-60}"

log() { printf '%s fw-sidecar: %s\n' "$(date -Iseconds)" "$*"; }
die() { log "FATAL: $*"; exit 1; }

# --------------------------------------------------------------------
# Preflight: caps, backend, sysctls.
# --------------------------------------------------------------------

# Use shell substring match instead of piping to `grep -q`: under
# `pipefail`, grep -q closes the pipe early, giving capsh SIGPIPE and
# making the whole pipeline exit nonzero even when the string matched.
caps="$(capsh --print 2>/dev/null || true)"
if [[ "${caps}" != *cap_net_admin* ]]; then
  die "missing NET_ADMIN capability — refusing to start"
fi

iptables_ver="$(iptables --version 2>&1 || true)"
if [[ "${iptables_ver}" != *nf_tables* ]]; then
  die "iptables is not using the nf_tables backend — host kernel must support nftables"
fi

# IPv6 must be disabled in this netns. /proc/sys is read-only in an
# unprivileged container, so the sysctl writes below are best-effort.
# The authoritative disable comes from Docker's --sysctl flag
# (compose.yaml, step 9). We ASSERT the final state here — a
# deployment that forgot --sysctl must not start.
sysctl -w net.ipv6.conf.all.disable_ipv6=1     >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1      >/dev/null 2>&1 || true

v6_state="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo missing)"
if [[ "${v6_state}" != "1" ]]; then
  die "IPv6 is not disabled (net.ipv6.conf.all.disable_ipv6=${v6_state}). Pass --sysctl net.ipv6.conf.all.disable_ipv6=1 or set it in compose.yaml."
fi

# --------------------------------------------------------------------
# Read port set from the allowlist (union of default + all overrides).
# Using --dry-run with the stub resolver so no DNS is needed for this
# preflight step; we only want the port list.
# --------------------------------------------------------------------

PORTS_JSON="$(RECONCILE_STUB_RESOLVER=1 python3 /reconcile.py \
  --dry-run --config "${CONFIG}" \
  --upstream "${DNS_UPSTREAM}")"

PORTS="$(printf '%s' "${PORTS_JSON}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join(str(p) for p in d["ports"]["union"]))
')"

log "allowlist ports (union): ${PORTS:-<none>}"

# --------------------------------------------------------------------
# Pre-create the ipsets (empty for now — populated a few lines down,
# BEFORE the iptables rules that reference them). `ipset swap` inside
# reconcile later is kernel-atomic.
# --------------------------------------------------------------------

ipset create -exist allowed_v4 hash:net family inet
ipset create -exist allowed_v6 hash:net family inet6

# --------------------------------------------------------------------
# iptables bootstrap. IMPORTANT: flush BEFORE setting policy to DROP.
# Setting policy first and flushing after creates a window where the
# policy is DROP and no ACCEPT rules exist — harmless in a fresh
# container but breaks in a warm restart scenario.
# --------------------------------------------------------------------

iptables -F
iptables -X
iptables -Z
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# loopback + conntrack
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DNS: sidecar → upstream (so the initial reconcile's `dig` can reach
# the resolver before we've set up the local unbound path).
iptables -A OUTPUT -d "${DNS_UPSTREAM}" -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -d "${DNS_UPSTREAM}" -p tcp --dport 53 -j ACCEPT
if [[ "${DNS_UPSTREAM_TLS}" == "1" ]]; then
  iptables -A OUTPUT -d "${DNS_UPSTREAM}" -p tcp --dport 853 -j ACCEPT
fi

# DNS: devbox (shared netns) → local unbound on 127.0.0.1:53.
iptables -A OUTPUT -p udp --dport 53 -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -d 127.0.0.1 -j ACCEPT

# NOTE: the per-port `--match-set allowed_v4` ACCEPT rules are
# installed AFTER the initial reconcile populates the ipset — see
# below. Installing them here with an empty ipset would silently drop
# all egress to allowlisted domains during bootstrap.

# ip6tables: drop everything. IPv6 is disabled via sysctl above; this
# is the secondary guard.
ip6tables -P INPUT  DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true
ip6tables -F 2>/dev/null || true

log "iptables bootstrap (pre-reconcile) complete"

# --------------------------------------------------------------------
# Point the sidecar's own resolver at unbound on loopback. reconcile.py
# always uses `dig @<upstream>` explicitly so it is unaffected by
# resolv.conf; everything else in the sidecar (including any
# hostnames baked into health probes) should go through the filter.
# Devbox gets the same treatment via compose's `dns:` key in step 9.
# --------------------------------------------------------------------
printf 'nameserver 127.0.0.1\noptions ndots:0\n' > /etc/resolv.conf
log "resolv.conf pointed at 127.0.0.1"

# --------------------------------------------------------------------
# Start unbound in the background, wait for it to come up.
# --------------------------------------------------------------------

# Seed the generated include file with the default-refuse zone so
# unbound starts valid even before the first reconcile.
mkdir -p "${UNBOUND_CONF_D}"
cat > "${UNBOUND_ALLOWLIST_CONF}" <<'EOF'
# Placeholder — real content written by reconcile.py.
server:
    local-zone: "." refuse
EOF

unbound -c /etc/unbound/unbound.conf -d &
UNBOUND_PID=$!

# Wait for remote-control to respond (up to ~10s). Bail early if
# unbound exited (misconfig, missing control keys, port conflict).
for i in $(seq 1 20); do
  if ! kill -0 "${UNBOUND_PID}" 2>/dev/null; then
    die "unbound process exited during startup (pid ${UNBOUND_PID}); check logs"
  fi
  if unbound-control status >/dev/null 2>&1; then
    log "unbound up (pid ${UNBOUND_PID})"
    break
  fi
  sleep 0.5
  if [[ $i -eq 20 ]]; then
    die "unbound failed to start within 10s"
  fi
done

# --------------------------------------------------------------------
# Initial reconcile. Exit codes: 0=ok, 2=partial, 1=total failure.
# Total failure is fatal at bootstrap (no domains reachable means the
# firewall is effectively deny-all, which breaks Remote Control too).
# --------------------------------------------------------------------

set +e
python3 /reconcile.py \
  --config "${CONFIG}" \
  --upstream "${DNS_UPSTREAM}" \
  $([[ "${DNS_UPSTREAM_TLS}" == "1" ]] && echo --upstream-tls)
RC=$?
set -e

case "${RC}" in
  0) log "initial reconcile ok" ;;
  2) log "initial reconcile PARTIAL (some upstreams failed); continuing" ;;
  *) die "initial reconcile failed (rc=${RC}); check DNS_UPSTREAM=${DNS_UPSTREAM}" ;;
esac

# --------------------------------------------------------------------
# NOW install the per-port ACCEPT rules that reference allowed_v4.
# The ipset is populated by the reconcile that just ran, so egress
# works immediately — no "blackhole until first reconcile" window.
# --------------------------------------------------------------------
for p in ${PORTS}; do
  iptables -A OUTPUT -p tcp --dport "${p}" -m set --match-set allowed_v4 dst -j ACCEPT
done
log "iptables egress rules installed"

# --------------------------------------------------------------------
# Reconcile loop. SIGHUP triggers an immediate run.
# --------------------------------------------------------------------

RELOAD_REQUESTED=0
trap 'RELOAD_REQUESTED=1; log "SIGHUP received"' HUP
# On shutdown, signal unbound then wait for it so tini sees a clean
# exit rather than orphaning the daemon. Traps are registered this
# late (after unbound is up) so the reference is live.
trap 'log "shutting down"; kill -TERM "${UNBOUND_PID}" 2>/dev/null; wait "${UNBOUND_PID}" 2>/dev/null; exit 0' INT TERM

while :; do
  # Sleep in 1s increments so SIGHUP is handled promptly.
  for _ in $(seq 1 "${RECONCILE_INTERVAL}"); do
    sleep 1
    if [[ ${RELOAD_REQUESTED} -eq 1 ]]; then
      RELOAD_REQUESTED=0
      break
    fi
  done
  set +e
  python3 /reconcile.py \
    --config "${CONFIG}" \
    --upstream "${DNS_UPSTREAM}" \
    $([[ "${DNS_UPSTREAM_TLS}" == "1" ]] && echo --upstream-tls)
  set -e
done
