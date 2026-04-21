#!/usr/bin/env bash
# Bring the stack up. Refuses to start if .env is missing so the
# operator knows to copy from .env.example first.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "error: .env not found." >&2
  echo "Run:" >&2
  echo "    cp .env.example .env" >&2
  echo "and adjust as needed, then re-run ./scripts/up.sh." >&2
  exit 1
fi

# Ensure the workspace bind-mount source exists with UID 1000 ownership
# BEFORE `docker compose up` runs. If the path doesn't exist, Docker
# auto-creates it as root:root, which leaves /workspace unwritable by
# the in-container `dev` user (uid 1000) and silently breaks every
# tool that tries to write there (git clone, cargo, claude, ...).
# WORKSPACE_PATH may be set in .env; honour the same default as
# compose.yaml.
WORKSPACE_PATH="${WORKSPACE_PATH:-$(grep -E '^WORKSPACE_PATH=' .env 2>/dev/null | tail -1 | cut -d= -f2-)}"
WORKSPACE_PATH="${WORKSPACE_PATH:-./workspace}"
if [[ ! -d "$WORKSPACE_PATH" ]]; then
  mkdir -p "$WORKSPACE_PATH"
fi
ws_uid=$(stat -c '%u' "$WORKSPACE_PATH")
if [[ "$ws_uid" != "1000" ]]; then
  echo "warning: $WORKSPACE_PATH is owned by uid=$ws_uid, but the in-container" >&2
  echo "  dev user is uid=1000. The bind mount will be unwritable from inside" >&2
  echo "  devbox. Fix with:" >&2
  echo "      sudo chown -R 1000:1000 \"$WORKSPACE_PATH\"" >&2
  echo "  (or set WORKSPACE_PATH in .env to a path you own as uid 1000)." >&2
fi

exec docker compose up -d --build "$@"
