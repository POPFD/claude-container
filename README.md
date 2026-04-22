# claude-container

A hardened Docker-based development stack for running Claude Code
24/7 with `--dangerously-skip-permissions`, backed by a firewall
sidecar that restricts egress to an operator-controlled allowlist.

- **claude-container** — sidecar owns the network namespace;
  dev container joins it and has zero network capabilities of
  its own.
- **Two-layer filtering** — iptables/ipset restricts egress by
  IP + port; `unbound` restricts DNS to an allowlist of domain
  suffixes, with everything else returning REFUSED.
- **Full dev toolchain** — Node + pnpm, Rust + clippy/rustfmt,
  Python + uv, Claude Code CLI, all running as a non-root `dev`
  user with no sudo and `no-new-privileges`. Missing packages can
  be installed from the host via `./scripts/install-pkg.sh <pkg>`;
  Claude inside the container cannot reach that path.
- **Drive from anywhere** — the container runs `claude
  remote-control` in server mode, so you can steer it from
  `claude.ai/code` or the mobile app.

## Prerequisites

- Docker 26+ and Docker Compose v2.
- A `claude.ai` subscription (Remote Control requires full-scope
  OAuth; the long-lived `CLAUDE_CODE_OAUTH_TOKEN` is
  inference-only and WILL NOT work).
- Host kernel with `nf_tables` backend for iptables and IPv6
  support for the disable sysctl.

## Quickstart

```bash
cp .env.example .env                  # edit tunables as needed
./scripts/up.sh                       # builds images, brings stack up
docker exec -it devbox claude /login  # one-time OAuth in your browser
docker compose restart devbox         # pick up the new credentials
```

After the login + restart, `docker compose logs devbox` shows a
`Remote Control session URL` line you can open in any browser to
drive the session from.

Day-to-day:
- `./scripts/shell.sh` — drop into a dev shell as `dev` in
  `/workspace`. From here you can `cargo build`, `pnpm install`,
  `pytest`, etc.
- `./scripts/shell.sh --pentest [--quick]` — run the in-container
  isolation pentest (`scripts/pentest.sh`) as the `dev` user. The
  script is streamed on stdin, so edits on the host take effect
  immediately — no image rebuild. Exits non-zero if any probe
  detects a regression against the threat model below.
- `./scripts/reload.sh` — rebuild the sidecar image and reload the
  egress allowlist after editing `config/allowlist.yaml`. The
  allowlist is baked into the sidecar image at build time, so an
  image rebuild is required to pick up edits.
- `./scripts/down.sh` — stop the stack. Named volumes persist.
- `./scripts/down.sh --nuke` — destroy the stack AND the
  `claude-config` + `tool-caches` volumes. You lose the OAuth
  token, Claude auto-memory, installed plugins, and cargo/npm
  caches. Requires typing `nuke` then `yes delete it` to
  confirm.

## Editing the allowlist

`config/allowlist.yaml` is the source of truth for egress. It
ships with sensible defaults for Anthropic APIs, GitHub,
Rust/Cargo, Node/npm, and Python/PyPI (including the fastly CDN
that PyPI CNAMEs to).

```yaml
domains:
  - api.anthropic.com
  - "*.githubusercontent.com"        # wildcard: DNS-only, no IP pin
cidrs:
  - 192.0.2.0/24                     # direct CIDR allow
ports:
  default: [443]
  overrides:
    - match: github.com
      ports: [22, 443]               # allow git+ssh to github.com
```

After editing:
```bash
./scripts/reload.sh
```
This rebuilds the sidecar image (the allowlist is baked in at
build time), recreates the sidecar container, re-resolves
domains, rebuilds ipsets, and reloads unbound.

### Adding CDN-backed services

Many services (pypi, AWS, GitHub release artifacts) CNAME to
third-party CDNs. Unbound won't answer a query whose CNAME
target is outside its forward-zones, so you must add the CDN
suffix too. Example:
```yaml
  - my-service.example.com
  - "*.cloudfront.net"               # if my-service CNAMEs here
```
The IP layer is unaffected — only the DNS resolution path gains
permission for that suffix.

## Verification

Once the stack is up, confirm the security posture end-to-end.
All commands below are copy-pasteable; each documents its
expected outcome.

```bash
# 1. Services healthy
docker compose ps
# fw-sidecar should show (healthy); devbox Up.

# 2. Caps + rootfs inspection
docker inspect devbox --format 'caps={{.HostConfig.CapAdd}}/{{.HostConfig.CapDrop}} ro={{.HostConfig.ReadonlyRootfs}} sec={{.HostConfig.SecurityOpt}}'
# => caps=[]/[ALL] ro=true sec=[no-new-privileges:true]

docker inspect fw-sidecar --format 'caps={{.HostConfig.CapAdd}}/{{.HostConfig.CapDrop}}'
# => caps=[CAP_NET_ADMIN CAP_NET_RAW]/[ALL]
# (NET_RAW is required by the `xt_set` iptables match extension —
# verified empirically; do not drop it.)

# 3. Egress is blocked by default (all from inside devbox)
./scripts/shell.sh
# Inside the container:
curl --max-time 4 -sS -o /dev/null -w "anthropic: %{http_code}\n" https://api.anthropic.com/
# => anthropic: 404  (reachable; 404 is the API's default for GET /)

getent hosts evil.example.com 2>&1 || echo "dns blocked"
# => dns blocked

curl --max-time 3 -sS -o /dev/null https://1.1.1.1/ || echo "ip blocked"
# => ip blocked

curl --max-time 3 -sS -o /dev/null http://api.anthropic.com/ || echo "port blocked"
# => port blocked   (allowed host, port 80 not in allowlist)

ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1 | head -1
# Reaches GitHub's auth banner (port override 22 works)

curl --max-time 3 -6 -sS -o /dev/null https://ipv6.google.com/ || echo "v6 blocked"
# => v6 blocked   (IPv6 disabled at the sysctl layer)

# 4. Tooling works
cargo search serde --limit 1
pip download --no-deps --quiet requests -d /tmp/x && ls /tmp/x
npm view react version

# 5. Hardening
capsh --print | grep ^Current:
# => Current: =    (empty — no caps)

touch /etc/test 2>&1 | grep Read-only
# => "Read-only file system"
touch /tmp/t /home/dev/.cache/t /home/dev/.config/t && echo home+tmp writable
```

## Threat model

**What this protects against**
- Arbitrary egress from anything inside devbox, including from
  a compromised Claude session running with
  `--dangerously-skip-permissions`. All TCP egress is
  ipset-gated by IP + port.
- DNS lookups for non-allowlisted names (returns REFUSED via
  unbound's default-refuse root zone).
- Container escape to the host via capability abuse, suid, or
  rootfs writes. The devbox has NO capabilities
  (`cap_drop: ALL`), `no-new-privileges`, read-only rootfs,
  user namespace isolation via a non-root uid, and resource
  caps (`pids_limit`, `mem_limit`, `nofile`).
- IPv6 bypass: v6 is disabled at the sysctl layer AND
  `ip6tables` has a default DROP policy as belt-and-braces.

**What it does NOT protect against**
- **Kernel exploits.** Host kernel patching is your
  responsibility.
- **Wildcard DNS exfiltration.** Any wildcard domain in the
  allowlist (e.g. `*.githubusercontent.com`) forwards all
  subdomain queries to the upstream resolver. A compromised
  process can smuggle data out by encoding it in subdomain
  names under that suffix. Prefer non-wildcard entries where
  practical. The IP layer is not a backstop here because these
  queries never reach an IP.
- **Trust in the upstream DNS resolver.** Set
  `DNS_UPSTREAM_TLS=1` in `.env` to forward over DoT and at
  least close the on-path leak.
- **Side-channel attacks through allowed services.** If
  `github.com` is in the allowlist and your Claude session is
  compromised, the attacker can exfiltrate via GitHub (gist,
  private repo writes, issue comments, etc.). This is an
  inherent property of any allowlist that permits
  user-controlled destinations.
- **The `unbound-control` keypair is baked into the sidecar
  image at build time.** Do not publish this image to a shared
  registry — anyone who can pull it would have the control
  socket key. The socket is loopback-only so this only matters
  if the image leaves the host.

## Persistence

| What | Where | Survives |
|------|-------|----------|
| OAuth token, Claude config | `claude-config` volume (`/home/dev/.claude`) | down/up, rebuilds, host restart. Destroyed only by `./scripts/down.sh --nuke`. |
| Claude auto-memory | `claude-config` volume at `/home/dev/.claude/projects/<encoded-cwd>/memory/` | Same as above. Distinct from any host-side Claude memory because the cwd (`/workspace`) is different. |
| Installed Claude plugins | `claude-config` volume at `/home/dev/.claude/plugins/` | Same as above. |
| Claude onboarding/theme state (`.claude.json`) | `home-dev` volume (`/home/dev`) | down/up, rebuilds, host restart. Destroyed by `./scripts/down.sh --nuke`. |
| Cargo registry cache | `tool-caches` volume (`/home/dev/.cargo`) | down/up. |
| npm cache, tool dotfiles, shell history | `home-dev` volume (`/home/dev`) | Same as Claude onboarding — part of the persistent $HOME volume. |
| Workspace source | `./workspace/` bind mount | Persists on the host. |

`/home/dev` is a named volume seeded from the image on first run
(bashrc, rustup, cargo, claude CLI install, etc. are copied in
once). Subsequent starts reuse the volume, so any dotfile a tool
drops at `$HOME` sticks. The rest of the rootfs outside `$HOME`
remains read-only — the hardening posture is unchanged. Image
rebuilds that change `$HOME` contents do NOT propagate into an
existing `home-dev` volume; run `./scripts/down.sh --nuke` to
pick up the new defaults.

## Recovery

**Sidecar unhealthy:**
```bash
docker compose logs fw-sidecar
# Check for "FATAL" lines. Common causes:
# - DNS_UPSTREAM unreachable at boot → restart sidecar once the network is back.
# - "IPv6 is not disabled" → your `--sysctl` / compose sysctls didn't apply.
```

**Claude session broken (auth loop, UI stuck):**
```bash
docker exec -it devbox claude /login      # re-run OAuth
docker compose restart devbox
```

**Full reset (destructive):**
```bash
./scripts/down.sh --nuke
./scripts/up.sh
docker exec -it devbox claude /login
docker compose restart devbox
```

## Project layout

```
claude-container/
├── compose.yaml                # Stack definition + hardening
├── .env.example                # Copy to .env; documents tunables
├── config/allowlist.yaml       # Egress allowlist (domains + cidrs + ports)
├── devbox/
│   ├── Dockerfile              # Ubuntu 24.04 + toolchains + claude
│   └── devbox-main.sh          # Entrypoint (runs as dev)
├── fw-sidecar/
│   ├── Dockerfile              # Alpine + iptables/ipset/unbound
│   ├── entrypoint.sh           # Firewall bootstrap + reconcile loop
│   ├── reconcile.py            # Allowlist → ipsets + unbound conf
│   ├── unbound-base.conf       # Base resolver config
│   └── tests/                  # Unit tests for the reconciler
├── scripts/
│   ├── up.sh / down.sh
│   ├── shell.sh                # Drop into dev shell
│   └── reload.sh               # SIGHUP the sidecar
└── workspace/                  # Bind-mounted into /workspace
```
