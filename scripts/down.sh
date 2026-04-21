#!/usr/bin/env bash
# Bring the stack down. By default NEVER passes -v so Claude
# credentials, auto-memory, and tool caches in the named volumes
# survive. Use `./scripts/down.sh --nuke` to wipe everything
# (double-prompted — this deletes your Claude login and all
# plugin/memory state).
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--nuke" ]]; then
  cat <<'EOF' >&2
WARNING: --nuke deletes the claude-config and tool-caches named
volumes. You will lose:
  - Claude Code OAuth credentials (you'll need to re-run
    `claude /login` after the next up).
  - Claude auto-memory for projects accessed from the container.
  - Installed Claude Code plugins and their state.
  - Cargo/npm/uv caches under /home/dev/.cargo (rebuild-only cost).

The host ./workspace directory is NOT affected.

EOF
  read -r -p "Type 'nuke' to confirm: " confirm1
  if [[ "${confirm1}" != "nuke" ]]; then
    echo "aborted." >&2
    exit 1
  fi
  read -r -p "Really? Volumes cannot be recovered. Type the full phrase 'yes delete it': " confirm2
  if [[ "${confirm2}" != "yes delete it" ]]; then
    echo "aborted." >&2
    exit 1
  fi
  exec docker compose down -v
fi

exec docker compose down "$@"
