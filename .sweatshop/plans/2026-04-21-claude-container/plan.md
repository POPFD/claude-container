# Plan: Docker-based Claude Code dev container with hardened egress filtering

## Goal

Deliver a two-container docker-compose stack:
- `fw-sidecar` owns the network namespace, enforces egress via iptables/ipset, and runs `unbound` as a filtering DNS resolver whose zones are generated from a YAML allowlist.
- `devbox` joins the sidecar's netns (no net caps), runs Claude Code with `--dangerously-skip-permissions` in Remote Control server mode, and ships a full dev toolchain (Rust, Node, Python, build tools).

The container + sidecar is the security boundary. An attacker who compromises anything inside `devbox` must not be able to (a) reach non-allowlisted hosts over IPv4 or IPv6, (b) resolve arbitrary DNS names, or (c) escape to the host.

## Threat model (acknowledged gaps)

These are explicitly in scope but not fully closed — they belong in the README threat model section, not hidden:

1. **DNS exfil through wildcard forward-zones.** Any wildcard entry (e.g. `*.githubusercontent.com`) forwards the entire suffix to the upstream resolver. A compromised process can exfiltrate data by encoding it in subdomain lookups under that suffix. We reduce exposure by: (a) preferring non-wildcard entries wherever possible, (b) logging all forwarded queries at `unbound` info level so an operator can audit. Full closure would require a per-label allowlist at the resolver — out of scope for v1.
2. **Upstream DNS is trusted.** We forward to `DNS_UPSTREAM` over cleartext UDP by default. We include an opt-in DoT mode (`DNS_UPSTREAM_TLS=1`) that switches unbound to `forward-tls-upstream: yes` — documented, one config line — for operators who want to close the on-path leak.
3. **Kernel exploits.** The container does not protect against kernel-level escapes. Host kernel patching is the operator's responsibility.
4. **Host DNS resolver compromise.** If `DNS_UPSTREAM` is malicious or compromised, it can redirect allowlisted domains to attacker-controlled IPs. Domain pinning via DNSSEC is out of scope for v1.

## Conventions

- Every step ends in a clean commit.
- Each step is independently reviewable; later steps may extend earlier files but never rewrite them wholesale.
- Verification for each step is scoped — "does *this* work in isolation" — not "does the whole system work." The final step does end-to-end verification.

---

### Step 1: Scaffold repo layout and .env.example

**What:** Create the directory skeleton (`devbox/`, `fw-sidecar/`, `scripts/`, `config/`), an empty `.gitignore` entry for `.env` and `workspace/`, and `.env.example` documenting every tunable.

**Why:** Establishes the file layout everything else will populate. Having `.env.example` first forces us to name all the knobs up front.

**Acceptance criteria:**
- [x] Directories exist: `devbox/`, `fw-sidecar/`, `scripts/`, `config/`, `workspace/` (the last gitignored).
- [x] `.env.example` contains: `DEVBOX_NAME`, `MEM_LIMIT`, `PIDS_LIMIT`, `DNS_UPSTREAM`, `DNS_UPSTREAM_TLS` (0/1), `WORKSPACE_PATH`, `UV_NO_UPDATE_CHECK=1`, `CARGO_NET_OFFLINE_AFTER` (documentation-only). Each line has a comment and a sensible default.
- [x] `.gitignore` ignores `.env`, `workspace/*` (with `!.gitkeep`).
- [x] `git status` clean after commit.

**Files likely involved:**
- `.env.example`
- `.gitignore`
- `workspace/.gitkeep`
- `devbox/.gitkeep`, `fw-sidecar/.gitkeep`, `scripts/.gitkeep`, `config/.gitkeep`

---

### Step 2: Author default `allowlist.yaml` and document its schema

**What:** Write `config/allowlist.yaml` covering Anthropic/Claude, GitHub (with port-22 override), Rust (crates.io + static.crates.io + index.crates.io + sh.rustup.rs), Node (registry.npmjs.org), Python (pypi.org + files.pythonhosted.org). Document the schema inline with comments.

**Why:** Downstream code (reconcile script, unbound config generator) needs a concrete schema to parse. Locking the schema now means step 4 can be written against a real example.

**Acceptance criteria:**
- [x] `config/allowlist.yaml` parses as valid YAML.
- [x] Contains top-level keys `domains`, `cidrs`, `ports` as agreed.
- [x] `ports.default` = `[443]`; `ports.overrides` includes a `github.com`-class entry allowing `[22, 443]`.
- [x] At least one wildcard domain entry (e.g. `*.githubusercontent.com`) present.
- [x] Inline comments describe each field and explicitly call out that wildcard entries are enforced at DNS level only, not IP level.

**Files likely involved:**
- `config/allowlist.yaml`

---

### Step 3: Build `fw-sidecar` base image with iptables/ipset/unbound tooling

**What:** Write `fw-sidecar/Dockerfile` based on `alpine:3.19+` that installs `iptables`, `ip6tables`, `ipset`, `unbound`, `unbound-control` (ships with unbound on Alpine), `bind-tools` (for `dig`), `python3`, `py3-yaml`, `bash`, and `tini`. Sidecar runs as root because of NET_ADMIN and rule management. Add a placeholder `entrypoint.sh` that just `exec tail -f /dev/null` for now.

During image build, run `unbound-control-setup` so the control socket key/cert pair exists at `/etc/unbound/` — this is required for step 5's `unbound-control reload`.

**Why:** Isolates the image build from any logic. A subsequent step adds reconcile logic without re-churning the Dockerfile.

**Acceptance criteria:**
- [x] `docker build fw-sidecar/` succeeds.
- [x] `docker run --rm <img> sh -c 'iptables -V && ipset -v && unbound -V && unbound-control -h && dig -v && python3 -c "import yaml"'` succeeds.
- [x] `/etc/unbound/unbound_control.key` and `/etc/unbound/unbound_server.key` exist in the image.
- [x] Image size under ~110 MB.
- [x] Entrypoint script is `+x`.

**Files likely involved:**
- `fw-sidecar/Dockerfile`
- `fw-sidecar/entrypoint.sh`
- `fw-sidecar/.dockerignore`

---

### Step 4: Implement the allowlist reconciler (Python)

**What:** Add `fw-sidecar/reconcile.py` — a script that:
1. Loads `/config/allowlist.yaml`.
2. For non-wildcard domains: resolves via `dig @<DNS_UPSTREAM>` to A/AAAA records, inserts into `allowed_v4` / `allowed_v6` ipsets.
3. For wildcard domains (`*.example.com`): no ipset entry; adds a forward-zone for the base suffix (`example.com`) to unbound.
4. Applies `cidrs` directly to ipsets.
5. Generates `/etc/unbound/unbound.conf.d/allowlist.conf` with `local-zone: "." refuse` as default, plus `forward-zone` entries for each allowed domain/suffix pointed at `DNS_UPSTREAM`. When `DNS_UPSTREAM_TLS=1`, emits `forward-tls-upstream: yes` and uses port 853.
6. Writes idempotently — computes desired state, diffs against current ipset/unbound config, only applies changes.
7. Reloads unbound via `unbound-control reload` after writing config.
8. Retries DNS resolution up to N=3 times with exponential backoff (1s, 2s, 4s) before giving up on a given domain; logs warnings but continues for other domains.

Ship with unit-testable helpers (no network/iptables calls): `parse_allowlist`, `build_unbound_conf`, `build_ipset_members`. Dry-run emits machine-parseable output (JSON to stdout) so tests can assert on it directly.

**Why:** The reconciler is the most complex piece. Separating pure logic (parse/generate) from side effects (ipset/unbound calls) keeps it testable.

**Acceptance criteria:**
- [x] `python3 reconcile.py --dry-run --config ../config/allowlist.yaml` emits JSON to stdout with keys `unbound_conf`, `ipset_v4`, `ipset_v6`, `ports`, exits 0.
- [x] `fw-sidecar/tests/test_reconcile.py` exercises `parse_allowlist`, `build_unbound_conf`, `build_ipset_members` against a fixture YAML and passes under `python3 -m pytest`.
- [x] **Wildcard test**: fixture with only `*.example.com` produces `build_ipset_members() == {v4: [], v6: []}` AND `build_unbound_conf()` contains a `forward-zone: name: "example.com."` entry.
- [x] **Port override test**: fixture with `ports.overrides` for `github.com=[22,443]` is present in the `ports` JSON output keyed by the literal domain.
- [x] **DoT test**: fixture with `DNS_UPSTREAM_TLS=1` emits `forward-tls-upstream: yes` and upstream port 853.
- [x] **Retry test**: when resolution fails, a WARN log line is emitted and the script exits 0 if at least one domain resolved; exits 1 only if *all* resolutions fail.

**Files likely involved:**
- `fw-sidecar/reconcile.py`
- `fw-sidecar/tests/test_reconcile.py`
- `fw-sidecar/tests/fixtures/sample-allowlist.yaml`

---

### Step 5: Implement firewall bootstrap + reconcile loop in `entrypoint.sh`

**What:** Replace the placeholder entrypoint. Sequence:

1. Assert `NET_ADMIN` present (abort if `capsh --print | grep cap_net_admin` fails).
2. **Disable IPv6 connectivity** in the netns: `sysctl -w net.ipv6.conf.all.disable_ipv6=1` and `net.ipv6.conf.default.disable_ipv6=1`. This eliminates the IPv6-bypass class entirely for v1. (Documented: operators who need IPv6 can remove this and rely on `ip6tables` + `allowed_v6` ipset, but it's off by default.) As belt-and-braces, `ip6tables -P INPUT/OUTPUT/FORWARD DROP` with no accept rules is still installed.
3. Bootstrap iptables. **Chain construction is explicit and ordered**:
   - `iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT DROP`
   - `iptables -A INPUT -i lo -j ACCEPT`
   - `iptables -A OUTPUT -o lo -j ACCEPT`
   - `iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT`
   - `iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT`
   - `iptables -A OUTPUT -d <DNS_UPSTREAM> -p udp --dport 53 -j ACCEPT` (sidecar → upstream)
   - `iptables -A OUTPUT -d <DNS_UPSTREAM> -p tcp --dport 53 -j ACCEPT`
   - When DoT: additionally allow tcp dport 853 to `<DNS_UPSTREAM>`.
   - `iptables -A OUTPUT -p udp --dport 53 -d 127.0.0.1 -j ACCEPT` (devbox → local unbound)
   - `iptables -A OUTPUT -p tcp --dport 53 -d 127.0.0.1 -j ACCEPT`
   - For each port in the union of `ports.default` and `ports.overrides.*.ports`: `iptables -A OUTPUT -p tcp --dport <P> -m set --match-set allowed_v4 dst -j ACCEPT`.
   - Final implicit DROP (the default policy).
4. Write base unbound config with `remote-control` enabled over local socket, default-refuse zone, and an empty allowlist include file. Start `unbound` in daemon mode on `127.0.0.1:53`.
5. Wait for unbound to be up (poll `unbound-control status` for up to 10s; exit 1 if it doesn't come up).
6. Run `reconcile.py` once synchronously — it must succeed at least partially (at least one domain resolved, per the reconciler's own semantics) or the sidecar exits 1.
7. Enter loop: sleep 60, run `reconcile.py`. Trap SIGHUP to trigger immediate reconciliation.
8. `tini` as PID 1 so signals propagate.

**Why:** This is where the sidecar becomes functional. Explicit chain construction means a reviewer can audit "is the firewall set up correctly" directly against the spec.

**Acceptance criteria:**
- [x] `docker run --rm --cap-add NET_ADMIN -v ./config:/config:ro fw-sidecar` reaches the reconcile loop (log line `reconcile ok, sleeping`).
- [x] `iptables -S OUTPUT` inside the sidecar matches the spec exactly (policy DROP + lo + conntrack + DNS-upstream + unbound-localhost + ipset-allowed per-port accepts).
- [x] `sysctl net.ipv6.conf.all.disable_ipv6` returns `1` inside the sidecar.
- [x] `unbound-control status` returns OK.
- [x] **Positive**: `dig @127.0.0.1 github.com` succeeds.
- [x] **Negative (DNS)**: `dig @127.0.0.1 evil.example.com` returns REFUSED.
- [x] **Negative (port)**: tested via `nc` to an allowed IP: `github.com:80` times out (port 80 not allowed), `github.com:443` succeeds, `github.com:22` succeeds (override).
- [x] **Negative (CIDR)**: `nc 1.1.1.1:443` (not in allowlist) times out.
- [x] `kill -HUP <pid>` triggers an immediate reconcile log line.

**Files likely involved:**
- `fw-sidecar/entrypoint.sh`
- `fw-sidecar/unbound-base.conf`
- `fw-sidecar/Dockerfile` (COPY the base conf)

---

### Step 6: Build `devbox` base image (Ubuntu + user + core apt tools)

**What:** Write `devbox/Dockerfile` stage 1 only: `ubuntu:24.04` base; install `git`, `curl`, `ca-certificates`, `build-essential`, `pkg-config`, `openssh-client`, `gnupg`, `tini`, `libcap2-bin` (for `capsh` in verification). Create `dev` user (uid/gid 1000). `/workspace` and `/home/dev` owned by `dev`. No language toolchains yet.

**Why:** Splitting image construction into phases keeps the diff on each step reviewable.

**Acceptance criteria:**
- [ ] `docker build devbox/` succeeds.
- [ ] `docker run --rm <img> id` (with `USER dev` set) shows uid=1000(dev) gid=1000(dev).
- [ ] `git --version`, `cc --version`, `ssh -V`, `capsh --version` all succeed inside the image.

**Files likely involved:**
- `devbox/Dockerfile`
- `devbox/.dockerignore`

---

### Step 7: Add language toolchains (Node, Rust, Python) to `devbox`

**What:** Extend `devbox/Dockerfile` to install:
- Node LTS via NodeSource or official tarball, plus `pnpm` via `corepack enable`.
- `rustup` + `stable` toolchain + `clippy` + `rustfmt`, installed as the `dev` user into `/home/dev/.rustup` and `/home/dev/.cargo`.
- Python 3 (from apt), plus `uv` via the official installer into `/home/dev/.local/bin`.
- Update `PATH` via `ENV` so all toolchains are on PATH for both login and non-login shells.
- Set `ENV UV_NO_UPDATE_CHECK=1`, `RUSTUP_UPDATE_ROOT=...` configured to fail cleanly, and document that no tool should attempt self-update at runtime (read-only rootfs).

**Why:** Getting language toolchains right (user-owned, on-PATH, no self-update attempts under read-only rootfs) is fiddly; isolating this step lets the reviewer focus on install mechanics.

**Acceptance criteria:**
- [ ] `docker run --rm <img> bash -lc "node --version && pnpm --version && rustc --version && cargo --version && cargo clippy --version && rustfmt --version && python3 --version && uv --version"` succeeds.
- [ ] None of the toolchains require root to run.
- [ ] Rustup and cargo live under `/home/dev/`, not `/root/` or `/opt/`.
- [ ] Running with `--read-only` (test harness): `docker run --rm --read-only --tmpfs /tmp --tmpfs /home/dev/.cache <img> bash -lc "node -e 'console.log(1)'"` succeeds — no tool tries to write outside tmpfs/home.

**Files likely involved:**
- `devbox/Dockerfile`

---

### Step 8: Install Claude CLI and wire the entrypoint

**What:** Add a final Dockerfile layer that installs `claude` via the official installer as the `dev` user. Before writing the entrypoint, the implementer runs `claude remote-control --help` in a scratch container and pastes the exact observed flag surface into the entrypoint (committing a comment block with the output in the entrypoint file for traceability). Write `devbox/entrypoint.sh`:

1. Script runs as root initially (entrypoint user=root in Dockerfile), because the `/home/dev/.claude` named volume is owned `root:root` on first provision.
2. `chown -R dev:dev /home/dev/.claude` (idempotent; noop after first run).
3. Drop to `dev`: `exec gosu dev /usr/local/bin/devbox-main.sh` (install `gosu` in step 6 — amend if missing).
4. `devbox-main.sh` (runs as `dev`):
   - `cd /workspace`.
   - If `~/.claude` has no credential files, print a clear multi-line hint: *"Run `docker exec -it devbox claude /login` to authenticate before starting Remote Control"* and exit 1.
   - Exec `claude remote-control --name "${DEVBOX_NAME:-devbox}" --dangerously-skip-permissions` (exact flag form per help output).

Use `tini` as PID 1.

**Why:** Entry logic is the operational contract. The two-stage (root → dev) entrypoint is the minimal-complexity fix for the named-volume permissions problem.

**Acceptance criteria:**
- [ ] `docker run --rm <img> claude --version` succeeds (as dev).
- [ ] Running the image with an empty `/home/dev/.claude` volume prints the login hint and exits 1 (documented behavior).
- [ ] With credentials mounted, container logs "Remote Control session URL: …" within 30s.
- [ ] The entrypoint performs `chown` only once per new volume; on a populated volume, `chown` is a noop (verify with `strace` or by checking file mtimes are unchanged on second start).
- [ ] `docker exec devbox id` returns `uid=1000(dev)` — main process runs as dev.

**Files likely involved:**
- `devbox/Dockerfile` (adds `gosu`, claude install)
- `devbox/entrypoint.sh`
- `devbox/devbox-main.sh`

---

### Step 9: Write `compose.yaml` wiring both services together

**What:** Author `compose.yaml`:

**`fw-sidecar`**:
- `build: ./fw-sidecar`
- `cap_drop: [ALL]`, `cap_add: [NET_ADMIN]` — **NET_RAW removed**; iptables/ipset do not require it.
- `sysctls: ["net.ipv6.conf.all.disable_ipv6=1"]` (belt-and-braces in addition to entrypoint sysctl).
- Bind-mount `./config:/config:ro`.
- Healthcheck: `CMD-SHELL unbound-control status >/dev/null && dig @127.0.0.1 evil.invalid 2>&1 | grep -q REFUSED` — tests that the resolver is up *and* default-deny is in effect; doesn't depend on external reachability.
- `restart: unless-stopped`.

**`devbox`**:
- `build: ./devbox`
- `network_mode: service:fw-sidecar`
- `depends_on: { fw-sidecar: { condition: service_healthy } }`
- `cap_drop: [ALL]` (no `cap_add`).
- `security_opt: [no-new-privileges:true]`
- `read_only: true`
- `tmpfs: ["/tmp", "/home/dev/.cache", "/home/dev/.config", "/run"]` — `.config` added so tools that write there don't fail.
- `pids_limit: ${PIDS_LIMIT:-1024}`, `mem_limit: ${MEM_LIMIT:-8g}`.
- `ulimits: { nofile: { soft: 4096, hard: 8192 } }`.
- Bind mount `${WORKSPACE_PATH:-./workspace}:/workspace`.
- Named volume `claude-config:/home/dev/.claude`.
- **Named volume `tool-caches:/home/dev/.cargo`** (non-optional — required for sane cargo rebuilds; a sub-path is also mounted for `.npm` and `.rustup` if needed, or document that the project-local `target/` is the persistent cache).
- **`dns: ["127.0.0.1"]`** — CRITICAL. Without this devbox's `/etc/resolv.conf` holds whatever the Docker daemon injects (host resolver, public resolvers), and all DNS from devbox bypasses the sidecar's unbound filter. This is load-bearing for the DNS-layer half of the security model.
- `restart: on-failure:3` — a clean exit (e.g. user explicitly stopped claude) should not auto-restart; failures get 3 retries.

**Acceptance criteria:**
- [ ] `docker compose config` parses with no errors using `.env.example` copied to `.env`.
- [ ] `docker compose up -d && docker inspect claude-container-devbox-1 --format '{{.HostConfig.CapAdd}} {{.HostConfig.CapDrop}}'` returns exactly `[] [ALL]` for devbox.
- [ ] `docker inspect` for fw-sidecar returns `[NET_ADMIN] [ALL]` — `NET_RAW` absent.
- [ ] `docker inspect claude-container-devbox-1 --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.SecurityOpt}}'` shows `true [no-new-privileges:true ...]`.
- [ ] `docker inspect` shows all four tmpfs mounts on devbox.
- [ ] `docker inspect` shows fw-sidecar has `net.ipv6.conf.all.disable_ipv6=1` sysctl.
- [ ] `docker exec devbox cat /etc/resolv.conf` shows exactly `nameserver 127.0.0.1` (ensures DNS routes through the sidecar's unbound, not the host resolver).
- [ ] Compose brings both services to healthy state; `docker compose ps` shows both running/healthy.

**Files likely involved:**
- `compose.yaml`

---

### Step 10: Add operator scripts (`up.sh`, `down.sh`, `shell.sh`, `reload.sh`)

**What:** Bash wrappers in `scripts/`:

- `up.sh` — `docker compose up -d --build`; pre-checks `.env` exists (offers to copy from `.env.example`).
- `down.sh` — `docker compose down` (explicitly NO `-v`). If `$1 == "--nuke"`, prompts twice for confirmation before calling `docker compose down -v` (this is the only supported way to wipe the `claude-config` volume, and it warns about Claude credential + memory loss).
- `shell.sh` — `docker compose exec -it -u dev devbox bash -l`.
- `reload.sh` — `docker compose kill -s HUP fw-sidecar`.
- All scripts `set -euo pipefail`, shellcheck-clean.

**Why:** Keeps day-to-day UX one short command and fences off the data-loss footgun.

**Acceptance criteria:**
- [ ] All four scripts are executable.
- [ ] `shellcheck scripts/*.sh` is clean.
- [ ] `./scripts/up.sh` with no `.env` prints the copy-from-example instruction and exits non-zero.
- [ ] `./scripts/down.sh` does NOT pass `-v` (verify via grep of the script and a dry-run test that the `claude-config` volume persists after `down` + `up`).
- [ ] `./scripts/down.sh --nuke` prompts twice before acting (verify with `yes n | ./scripts/down.sh --nuke` exiting without destruction).

**Files likely involved:**
- `scripts/up.sh`
- `scripts/down.sh`
- `scripts/shell.sh`
- `scripts/reload.sh`

---

### Step 11: End-to-end verification + README

**What:** Bring the stack up and verify the full contract, then write `README.md`.

Verification checklist (each command and expected output copied into the README):

1. `./scripts/up.sh` brings both services healthy.
2. Inside devbox via `./scripts/shell.sh`:
   - **Allowed network**: `curl -sS -o /dev/null -w "%{http_code}\n" https://api.anthropic.com/` → 2xx/4xx.
   - **Blocked domain (DNS)**: `getent hosts evil.example.com` → fails.
   - **Blocked by IP** (non-allowlisted): `curl --max-time 3 https://1.1.1.1/ || echo BLOCKED` → BLOCKED.
   - **Blocked by port** (allowed domain, wrong port): `curl --max-time 3 http://api.anthropic.com/ || echo BLOCKED` → BLOCKED.
   - **Wildcard allowed**: `curl -sS -o /dev/null -w "%{http_code}\n" https://raw.githubusercontent.com/github/docs/main/README.md` → 2xx.
   - **Port override (ssh:22)**: `ssh -T -o StrictHostKeyChecking=no -o ConnectTimeout=5 git@github.com` → reaches GitHub auth banner.
   - **IPv6 disabled**: `curl --max-time 3 -6 https://ipv6.google.com/ || echo BLOCKED_V6` → BLOCKED_V6.
   - **Tooling**: `cargo search serde --limit 1`, `pip download --no-deps requests -d /tmp/x`, `npm view react version` all succeed.
   - **No caps**: `capsh --print | grep "Current:"` → shows `=` (empty).
   - **Read-only rootfs**: `touch /etc/test 2>&1 | grep -q "Read-only"`.
   - **Tmpfs writable**: `touch /tmp/test && touch /home/dev/.cache/test && touch /home/dev/.config/test` all succeed.
3. Outside devbox: `docker inspect` confirms capabilities, security_opt, readonly_rootfs, tmpfs list, and pids/mem limits.
4. `docker compose logs devbox` shows `Remote Control session URL`.
5. **Allowlist reload**: add a domain to `config/allowlist.yaml`, `./scripts/reload.sh`, confirm `getent hosts <new-domain>` succeeds within ~5s.
6. **Persistence**: inside devbox create `/home/dev/.claude/TEST_PERSIST` and a dummy memory file under `/home/dev/.claude/projects/-workspace/memory/TEST.md`. `./scripts/down.sh && ./scripts/up.sh`. Re-shell; both files present.
7. **DNS recovery**: temporarily set `DNS_UPSTREAM` to an unreachable IP in `.env`, restart — sidecar should retry then fail healthcheck. Restore — sidecar recovers on next restart. Document the recovery path.

README contents:
- Prerequisites (docker, docker compose v2, bash).
- Quickstart (copy .env, `./scripts/up.sh`, `docker exec -it ... claude /login`, done).
- How to edit the allowlist and reload.
- **Threat model section** covering: what this protects against (cross-container host access, arbitrary egress, DNS exfil to unknown domains, caps escalation, rootfs tampering) and what it doesn't (kernel exploits, trusted DNS upstream, wildcard DNS as exfil channel, DNS query leak to upstream unless `DNS_UPSTREAM_TLS=1`).
- **Persistence semantics**: `claude-config` volume holds OAuth + `~/.claude/projects/<cwd-encoded>/memory/`. Survives `down`/`up` and image rebuilds. Only destroyed by `./scripts/down.sh --nuke` or manual `docker volume rm`. Host-side Claude memory is separate (different cwd).
- **Recovery**: what to do when sidecar fails health (`docker compose logs fw-sidecar`, check DNS upstream, `docker compose restart fw-sidecar`).

**Why:** A plan without executed e2e verification can hide integration bugs between otherwise-correct pieces.

**Acceptance criteria:**
- [ ] All 7 checklist items above pass on a clean machine.
- [ ] README contains copy-pasteable versions of each verification command with expected output.
- [ ] README has a "Threat model" section explicitly naming the wildcard-DNS gap, the DNS-upstream leak, and kernel-exploit out-of-scope.
- [ ] README explains how to add/remove allowlist entries, reload, and recover from sidecar failure.
- [ ] README warns prominently that `--nuke` destroys Claude credentials and memory.

**Files likely involved:**
- `README.md`
- Possibly minor fixes to any earlier file surfaced by e2e testing

---

## Summary of atomic commits

1. Scaffold layout + `.env.example`
2. Default `allowlist.yaml`
3. `fw-sidecar` image (base packages + unbound-control keys)
4. Reconciler script + unit tests (incl. wildcard/port/DoT/retry tests)
5. Firewall bootstrap + reconcile loop (explicit chain, IPv6 disabled, positive + negative tests)
6. `devbox` image — OS + user + gosu
7. `devbox` image — language toolchains (no self-update)
8. `devbox` image — Claude CLI + two-stage entrypoint (root→dev chown, login hint)
9. `compose.yaml` (NET_ADMIN only, `.config` tmpfs, on-failure:3, mandatory tool-caches volume)
10. Operator scripts (`--nuke` fence on down.sh)
11. E2E verification + README (incl. threat model, persistence, recovery)

## Auth invariant (NOT a deferral — a correctness constraint)

Remote Control requires a **full-scope OAuth session token**, obtained
via interactive `claude /login`. The long-lived tokens produced by
`claude setup-token` or set via `CLAUDE_CODE_OAUTH_TOKEN` are
**inference-only** and will fail with "Remote Control requires a
full-scope login token." Do NOT expose `CLAUDE_CODE_OAUTH_TOKEN` in
`.env.example` or the entrypoint. First-run auth is always interactive
(`docker exec -it devbox claude /login`), and the resulting
credentials persist in the `claude-config` named volume.

## Known deferrals (explicitly out of scope)

- Pre-seeding Claude credentials: user runs `claude /login` once inside the container.
- Full IPv6 egress enforcement: v6 is **disabled** in the netns rather than firewalled. Operators who need v6 can enable it and rely on `ip6tables` + `allowed_v6` ipset (scaffolded but unused by default).
- Host-level AppArmor/SELinux profile: out of scope per design discussion.
- Docker userns-remap: daemon-level, deliberately out of scope.
- Per-label DNS allowlisting (full closure of wildcard-DNS exfil): out of scope for v1.
- Audit log shipping from the sidecar: iptables LOG rules and log rotation are future work.
- DNSSEC validation on upstream responses.
- **`unbound-control` keys baked at image build time**: every container started from the same image has the same control socket keys. Low risk ONLY in the local-only use case (socket is loopback, sidecar runs as root, image never leaves the host). If the image is ever pushed to a registry (even a private one), anyone who can pull the image can extract the private key from the layer — regenerate keys at container startup instead of build time before doing so.
