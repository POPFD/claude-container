# Step 5 notes: Firewall bootstrap + reconcile loop

## Decisions
- **Sysctl disable_ipv6 is redundant with `--sysctl` at container run
  time.** Inside a non-privileged container, `/proc/sys` is read-only
  and the sysctl writes from the entrypoint fail (warning logs). The
  real IPv6 disable must come from Docker via `--sysctl` / compose's
  `sysctls:` key (step 9). The entrypoint sysctl calls are kept
  behind `|| true` as a safety net for environments where /proc/sys
  is writable, but nobody should rely on them.
- **ip6tables policy DROP is still a belt-and-braces**. Even with
  v6 disabled at the stack level, `ip6tables -P ... DROP` prevents
  egress if some future operator enables v6 without noticing.
- **Preflight uses `[[ str == *needle* ]]` substring match, NOT pipes
  to `grep -q`.** `set -o pipefail` + `grep -q` makes the upstream
  process (capsh, iptables --version) receive SIGPIPE when grep exits
  early, turning the whole pipeline into a false-negative. Cost us
  half an hour; noted prominently to prevent regression.
- **Port set derived via `reconcile.py --dry-run`** (with stub
  resolver) at bootstrap. Keeps a single source of truth for the
  allowlist schema and avoids a second YAML parser in bash.
- **Sidecar's own `/etc/resolv.conf` is rewritten to `127.0.0.1`**
  so any internal DNS goes through unbound. `reconcile.py` uses
  `dig @<upstream>` explicitly so it's unaffected by this.
- **Unbound config must emit `local-zone: "<name>" transparent` for
  every allowed domain** in addition to the forward-zones. Without
  the transparent override, the `local-zone "." refuse` default
  shadows all forward-zones and every query returns REFUSED. Added a
  regression test (`test_unbound_conf_transparent_local_zones_...`).
- **SIGHUP loop wakes on 1s-resolution sleep** rather than sleeping
  the full 60s and trapping — signals are delivered but `sleep` only
  wakes on SIGINT/SIGTERM, so inner 1s ticks check a flag.

## Constraints surfaced
- `dig +short` output includes CNAME chain hostnames. The original
  "accept if contains digit" filter let through hostnames like
  `dks7yomi95k2d.cloudfront.net.` which crashed `ipset add`. Fixed
  in step 4's parse_dig_output via `ipaddress.ip_address()`.
  `apply_ipsets` also now validates members before calling `ipset
  add` so a future malformed entry degrades instead of aborting
  the whole reconcile.
- **Docker does not let a container write /proc/sys**. If IPv6
  disable needs to be enforced from within the entrypoint, the
  container would need `--privileged` (unacceptable). Using Docker's
  `--sysctl net.ipv6.conf.all.disable_ipv6=1` is the required
  approach — it's applied at namespace-setup time, outside the
  container's read-only /proc/sys view.
- **Unbound on Alpine uses `/etc/unbound/unbound.conf`** as the main
  config path. Dockerfile COPYs `unbound-base.conf` there.
- `/etc/resolv.conf` inside a Docker container is writable by
  default (bind-mounted from the daemon but rw). If some future
  Docker version locks this down, we'll need `--dns 127.0.0.1` on
  compose.

## For later steps
- **Step 9 compose MUST include** (in addition to what the plan
  already says):
  - `sysctls: [net.ipv6.conf.all.disable_ipv6=1,
    net.ipv6.conf.default.disable_ipv6=1]` on the sidecar
  - `dns: [127.0.0.1]` on devbox (so devbox's /etc/resolv.conf
    points at unbound via the shared netns)
- **Step 8 devbox entrypoint**: verify DNS goes through unbound. A
  simple `getent hosts evil.example.com` should fail.
- **Step 9 healthcheck** (already in plan): unbound-control status
  plus `dig @127.0.0.1 evil.invalid | grep REFUSED`. Still correct.
- **Step 11 e2e**: the verification commands I used here (`nc -w 3
  -v <ip> <port>` for port reachability) should replace any
  assumption that `curl` is installed. Alpine doesn't include curl
  by default; use wget or the IP-direct nc test.
- **Known debug runes**:
  - `docker exec fw-sidecar unbound-control status`
  - `docker exec fw-sidecar ipset list allowed_v4 | head`
  - `docker exec fw-sidecar iptables -S OUTPUT`
  - SIGHUP: `docker exec fw-sidecar kill -HUP 1`

## Review resolutions
- **Blocker (code)**: `iptables -P DROP` came BEFORE `iptables -F`.
  Flipped so flush runs first; policy set after. Matters on warm
  restarts.
- **Blocker (code)**: `resolve_all` had a latent for-else bug where
  AAAA success on a domain cleared `last_err`, silently hiding A-
  record failures. Rewrote to track per-rtype errors separately and
  log a WARNING when one rtype exhausts retries but the domain is
  still recorded as succeeded. Added regression test.
- **Blocker (domain)**: IPv6 disable sysctls were best-effort only.
  Added a hard preflight check that reads
  `/proc/sys/net/ipv6/conf/all/disable_ipv6` and exits 1 if it's
  not `1`. Verified that a container started without the `--sysctl`
  flag refuses to run.
- **Blocker (domain)**: per-port iptables ACCEPT rules were installed
  BEFORE the first reconcile, creating an egress blackhole during
  bootstrap. Reordered: now the initial reconcile populates ipsets
  first, then the per-port `-m set --match-set allowed_v4` rules are
  installed. Egress works immediately after "iptables egress rules
  installed" log line.
- **Non-blocking**: TERM trap now does `wait "${UNBOUND_PID}"` before
  `exit 0` to avoid orphaning unbound. Verified clean exit(0) on
  `docker stop`.
- **Non-blocking**: unbound startup poll now breaks early if
  `kill -0 ${UNBOUND_PID}` fails (process died from misconfig).
- **Non-blocking**: hard acceptance criterion added to step 9 plan
  for `dns: ["127.0.0.1"]` on devbox + explicit check that
  `/etc/resolv.conf` inside devbox matches exactly.
