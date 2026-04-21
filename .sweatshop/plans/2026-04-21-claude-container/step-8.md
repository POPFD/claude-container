# Step 8 notes: Claude CLI install + two-stage entrypoint

## Decisions
- **Claude CLI installed via the official installer** from
  `https://claude.ai/install.sh`. Installs claude 2.1.104 into
  `/home/dev/.local/bin/claude` (symlink → versioned dir under
  `.local/share/claude/versions/`). Well above the 2.1.51+ Remote
  Control requirement and the 2.1.110 mobile-push requirement.
- **Flag ordering matters** (probed empirically, not from docs):
  flags go AFTER the `remote-control` subcommand. These FAIL with
  "Unknown argument":
  - `claude --dangerously-skip-permissions remote-control`
  - `claude --name foo remote-control`
  These WORK:
  - `claude remote-control`
  - `claude remote-control --name foo --dangerously-skip-permissions`
  Captured as a multi-line comment in devbox-main.sh for future
  maintainers.
- **Two-stage entrypoint (root → gosu dev)**: /entrypoint.sh runs as
  root because fresh Docker named volumes are root-owned and `dev`
  can't write to them until chown. After the chown it execs
  /devbox-main.sh via gosu. devbox-main.sh does the credentials
  preflight and execs claude.
- **No-credentials path sleeps instead of exiting**. The "please run
  `claude /login`" banner is printed then `exec sleep infinity`.
  This keeps the container up so the operator CAN still
  `docker exec -it devbox claude /login`, and avoids triggering
  compose's `restart: on-failure:3` into a noisy loop-then-quit.
- **Dockerfile ends with `USER root`** because the entrypoint must
  start as root. Consequence: plain `docker exec -it devbox bash`
  lands in a root shell. `./scripts/shell.sh` (step 10) will always
  use `-u dev` to get a dev shell. Documented in step 8 notes and
  step 10 acceptance.
- **Chown is idempotent**: `chown -R dev:dev /home/dev/.claude` on a
  populated volume is fast and a noop if ownership is already
  correct. No special guard needed.
- **Added `downloads.claude.ai`** to the runtime allowlist. The
  installer uses it at BUILD time only (image is read-only at
  runtime so no self-update), but shipping it in the allowlist is
  cheap and lets operators run `claude update` inside the container
  for experiments — would fail at the filesystem layer but at least
  not at the network layer.

## Constraints surfaced
- **ENTRYPOINT + CMD**: `docker run <img> bash -lc '...'` does NOT
  override our entrypoint — CMD arg is ignored because the
  entrypoint execs its own script. To bypass for debugging:
  `docker run --rm --entrypoint bash devbox-test -lc '...'`. Also
  applies to how the healthcheck in step 9 must be structured.
- **Installer fetches from `downloads.claude.ai`** during image
  build. If an air-gapped build is ever needed, we'll have to
  pre-bake the installer payload. Not a v1 concern.
- **`/home/dev/.claude` is initialized by the installer at build
  time** (it creates `backups/`, `downloads/`, `settings.json`).
  At runtime these are MASKED by the claude-config volume mount
  on that path. That's desired: the volume's contents are what
  matters. But the first `docker compose up` with an empty volume
  sees a brand-new empty directory; the credentials preflight
  catches that and prints the login hint.

## For later steps
- **Step 9 compose** must:
  - Not set `user:` on devbox (leave it at image default = root)
    so the entrypoint chown logic runs.
  - Pass `DEVBOX_NAME` env var if operator customized it in `.env`.
  - Respect the `on-failure:3` restart policy — the sleep-infinity
    no-creds path means a crashing claude itself won't restart-loop
    indefinitely because the entrypoint does `exec sleep` on the
    credentials check. But claude itself crashing after a successful
    startup is rare and `on-failure:3` handles that case.
- **Step 10 `shell.sh`** MUST use `docker compose exec -u dev devbox bash -l`.
- **Step 11 e2e** needs a real `claude /login` to complete end-to-end.
  I marked that specific acceptance criterion as deferred for step 11
  (requires interactive OAuth in a real browser, which can't be
  automated from CI).
- **Plugins persist**: `/home/dev/.claude/plugins/` is inside the
  named volume, so `claude plugin install sweatshop` survives
  container lifecycle. Document this in step 11 README.

## Review resolutions
- _filled in after review pass_
