# Step 11 notes: End-to-end verification + README

## Findings during live bring-up (real fixes applied)

1. **CDN CNAME chains break DNS filtering.** `files.pythonhosted.org`
   CNAMEs to `dualstack.python.map.fastly.net`. Our unbound
   forward-zone for `files.pythonhosted.org` gets the query through
   to upstream, but unbound's default behavior is to then validate
   the CNAME target (fastly.net) against local-zones, which hits
   the root refuse and returns SERVFAIL. Fix: add `*.fastly.net` to
   the allowlist. This is a general pattern — any CDN-backed service
   needs the CDN suffix in the allowlist too. Documented in README
   under "Adding CDN-backed services".
   - Note: IP-layer allowlist was already fine (fastly IPs get into
     `allowed_v4` via pypi/pythonhosted A-record chains), so this was
     a pure DNS-layer bug.
2. **npm needs `/home/dev/.npm` writable.** Under read-only rootfs,
   npm fails with `ENOENT: no such file or directory, mkdir
   '/home/dev/.npm/_cacache'`. Added as a tmpfs with uid=1000. Cache
   is cheap to rebuild — no named volume needed.
3. **ssh fails without writable `/home/dev/.ssh`.** `ssh -T
   git@github.com` tries to create the directory for known_hosts.
   Added as tmpfs with mode=700 + uid=1000.
4. **`.invalid` doesn't hit the refuse root.** RFC 6761 reserves it
   and unbound answers with NXDOMAIN internally — wrong probe for the
   healthcheck. Switched to `definitely-not-allowlisted.example.net`.
5. **`gosu dev` broke under `cap_drop: ALL`**. SETUID/SETGID are
   required for user switching and were stripped. Rather than add
   them back, restructured the Dockerfile to pre-seed
   `/home/dev/.{claude,cargo,cache,config}` as dev-owned so Docker
   preserves that ownership on first named-volume mount. devbox-main.sh
   runs as dev directly from PID 1. Eliminated the whole
   `devbox/entrypoint.sh` file.
6. **unbound's own privilege-drop also broke**. Needed `username: ""`
   and `chroot: ""` in unbound-base.conf since SETUID/SETGID are
   gone. Sidecar is the boundary; no within-container user
   separation needed.
7. **NET_RAW is required by `xt_set`**. The reviewer originally said
   "drop it, iptables only needs NET_ADMIN". Empirically `iptables
   ... -m set --match-set allowed_v4` fails with "Can't open socket
   to ipset" without NET_RAW. Added back with a multi-line comment
   in compose.yaml so a future reader doesn't re-drop it.
8. **`dns: [127.0.0.1]` must be on the SIDECAR**, not devbox. Docker
   rejects `dns:` alongside `network_mode: service:...`. Devbox
   inherits via the shared netns.
9. **Tmpfs mounts for home subdirs need explicit uid/gid**. Default
   tmpfs is root-owned mode 755; dev can't write. Added
   `uid=1000,gid=1000` to `.cache`, `.config`, `.ssh`, `.npm` mount
   options.

## Decisions
- README lives in repo root (overwrites the initial stub). Contains
  prerequisites, quickstart, allowlist editing with the CDN-CNAME
  gotcha, the full verification checklist with expected outputs, a
  Threat model section, a Persistence table, a Recovery section,
  and a Project layout diagram.
- The single manual step for the operator is `docker exec -it
  devbox claude /login`. Documented in the quickstart right after
  `./scripts/up.sh`.
- Expanded the default allowlist to include `*.fastly.net`
  (required for PyPI) and `downloads.claude.ai` (for the claude
  installer path, included for completeness even though runtime
  rootfs is read-only).

## Constraints surfaced for operators
- Wildcards are DNS-only. IPs behind a wildcard subdomain are
  NOT automatically in the ipset. If you need IP reachability
  for a wildcard, add a corresponding non-wildcard entry for a
  specific subdomain so its IPs get resolved.
- `docker exec devbox <cmd>` defaults to `dev` user (1000:1000).
  Use `docker exec -u root devbox <cmd>` if you need root for
  debugging (the container defaults to dev now that gosu was
  eliminated).
- `docker compose down -v` — WITHOUT `--nuke` — is possible if
  an operator uses raw compose. The README explicitly directs
  users at `./scripts/down.sh --nuke` to make the destruction
  path deliberate and double-confirmed.

## For operators (picked up from the bring-up)
- Most common "it broke" cause after editing the allowlist is
  CNAME chains pointing outside the allowlisted suffixes. If a
  domain you just allowlisted doesn't resolve, check
  `docker compose exec fw-sidecar dig @1.1.1.1 <domain>` and see
  if it returns a CNAME to another domain; if so, add that base
  suffix too.
- If the sidecar healthcheck flips unhealthy, check
  `docker compose logs fw-sidecar` for reconcile output. An all-
  fail reconcile (exit code 1) is fatal at bootstrap; a partial-
  failure (exit code 2) continues but the healthcheck still
  reports healthy because unbound itself is up.

## Review resolutions
- _filled in after review pass_
