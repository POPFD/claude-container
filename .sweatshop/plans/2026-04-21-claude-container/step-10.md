# Step 10 notes: Operator scripts

## Decisions
- **`up.sh` refuses without `.env`**. A missing `.env` means the
  operator will see `${DNS_UPSTREAM:-1.1.1.1}`-style defaults
  silently — which is actually fine, but better to make the step
  explicit so operators know the `.env` is the place to tune
  memory/pids/DNS.
- **`down.sh` DEFAULT is safe** — never passes `-v`. Named volumes
  survive. `--nuke` is the one entrypoint that can destroy them,
  and it requires two exact phrases (`nuke`, then `yes delete it`)
  — not just `y` twice. Intentional friction; losing the OAuth
  token and plugin state is expensive to recover.
- **`shell.sh` uses `-u dev`** even though the image defaults to
  dev already. Defensive: if someone ever flips the Dockerfile to
  `USER root` for debugging the shell still lands in dev.
- **`reload.sh` is a thin wrapper** around
  `docker compose kill -s HUP fw-sidecar`. Could be an alias but a
  script is self-documenting.
- All scripts `cd "$(dirname "$0")/.."` so they work from any cwd
  as long as the repo is the containing directory.

## Constraints surfaced
- `docker compose kill -s HUP` delivers SIGHUP to PID 1 inside the
  container (tini). tini forwards to the entrypoint, which trips
  the RELOAD_REQUESTED flag. Verified in a live reload.
- `docker compose exec -it` requires a TTY. From non-TTY contexts
  (CI, pipes) `shell.sh` as written will fail. That's acceptable —
  it's explicitly a developer-facing convenience.

## For later steps
- **Step 11 README** should point operators at `./scripts/shell.sh`
  as the primary way to interact with the container.
- The `--nuke` workflow must be the recovery path for a
  corrupted claude-config volume — README should document that as
  the only supported way to restart auth from scratch.

## Review resolutions
- _filled in after review pass_
