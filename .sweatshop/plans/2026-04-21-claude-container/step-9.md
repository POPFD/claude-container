# Step 9 notes: compose.yaml

## Decisions (surfaced by live bring-up)
- **NET_RAW must stay on the sidecar** (reviewer originally said
  drop it). `cap_drop: ALL` + `cap_add: NET_ADMIN` alone fails at
  `iptables ... -m set --match-set allowed_v4 ...` with "Can't open
  socket to ipset". `xt_set` needs NET_RAW empirically. Added a
  multi-line comment in compose.yaml explaining why (future reader
  must not "fix" the security posture by dropping it and breaking
  ipset match).
- **Devbox runs as `dev` from PID 1** — NO gosu hop. Achieved by
  pre-seeding `/home/dev/.claude`, `/home/dev/.cargo`, `.cache`,
  `.config` in the Dockerfile owned by dev, so Docker preserves
  that ownership when the named volumes first mount. Dropping the
  root→gosu pattern means no SETUID/SETGID caps are needed and
  `cap_drop: ALL` is clean. The old devbox/entrypoint.sh is gone.
- **`dns: [127.0.0.1]` on fw-sidecar, NOT devbox.** Docker rejects
  the `dns` key on a container with `network_mode: service:...`.
  The shared netns means devbox's /etc/resolv.conf is inherited
  from the sidecar's, so setting it there achieves the same end.
- **Healthcheck uses a bog-standard non-allowlisted domain**, not
  `.invalid`. unbound answers `.invalid` queries with built-in
  NXDOMAIN (reserved TLD) which bypasses our `local-zone "." refuse`.
  `definitely-not-allowlisted.example.net` hits the refuse as
  intended.
- **unbound runs as root inside the sidecar** via
  `username: "" / chroot: ""` in unbound-base.conf. Default behavior
  drops privs to the `unbound` user which requires SETGID/SETUID
  (stripped by cap_drop ALL). Sidecar is the boundary; within-
  container user separation buys nothing here.
- **tmpfs mounts for `.cache`/`.config` set `uid=1000,gid=1000`**
  explicitly. Default tmpfs is root-owned and dev can't write, so
  tools (uv, cargo, ssh) that write to those paths fail silently
  until an operator looks closely. /tmp stays at default 1777 (world-
  writable with sticky bit).

## Constraints surfaced
- `/etc/resolv.conf` is READ-ONLY under `read_only: true` rootfs in
  Docker. Earlier plan had the devbox entrypoint rewriting it — that
  was wrong and would have failed silently in production.
- Named-volume ownership inherits from the IMAGE path's ownership
  on first mount. This is undocumented-but-reliable Docker behavior.
  If a future step renames or moves the volume mount points, the
  corresponding Dockerfile `chown` must follow.
- unbound's built-in handling of RFC 6761 special-use TLDs (`invalid`,
  `localhost`, etc.) means some domains bypass the configured zones.
  Anything we use to probe "default deny" behavior must avoid these.

## For later steps
- **Step 10 `shell.sh`**: `docker compose exec -u dev devbox bash -l`
  is strictly redundant now since devbox defaults to dev. Still put
  `-u dev` for defensive clarity (a future change could flip the
  default back to root).
- **Step 11 e2e** can now verify the full stack. Real `claude /login`
  remains the one manual step.
- **Known debug runes**:
  - `docker compose logs -f fw-sidecar` — reconcile/firewall trace.
  - `docker compose logs -f devbox` — claude stdout.
  - `docker compose exec fw-sidecar ipset list allowed_v4 | head`
  - `docker compose exec fw-sidecar iptables -S OUTPUT`
  - `docker compose exec devbox getent hosts <foo>` to probe the
    DNS filter directly.

## Review resolutions
- _filled in after review pass_
