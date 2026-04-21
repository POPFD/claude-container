#!/bin/bash
# Main devbox process, runs as `dev`. Pre-flights credentials and
# then execs `claude remote-control` in server mode.
#
# Auth invariant (see /plan.md): Remote Control requires a
# full-scope OAuth session token obtained via interactive
# `claude /login`. A long-lived inference-only token
# (CLAUDE_CODE_OAUTH_TOKEN / `claude setup-token`) CANNOT establish
# Remote Control sessions. First-run auth is always interactive:
# `docker exec -it devbox claude /login`.
set -euo pipefail

export PATH="/home/dev/.local/bin:/home/dev/.cargo/bin:${PATH:-}"
export HOME=/home/dev
export UV_NO_UPDATE_CHECK=1

cd /workspace

# Has the operator completed the OAuth flow?
#   - `~/.claude/.credentials.json` is Claude Code's token store.
#   - On a freshly-mounted `claude-config` volume this file is absent;
#     we surface a clear error rather than launching claude into a
#     login error loop.
if [[ ! -s /home/dev/.claude/.credentials.json ]]; then
  cat <<'EOF' >&2

╔════════════════════════════════════════════════════════════════╗
║  devbox: no Claude credentials found in the claude-config       ║
║  volume (/home/dev/.claude/.credentials.json).                  ║
║                                                                 ║
║  Complete the interactive OAuth flow ONCE from another shell:   ║
║                                                                 ║
║      docker exec -it devbox claude /login                       ║
║                                                                 ║
║  Then restart this container:                                   ║
║                                                                 ║
║      docker compose restart devbox                              ║
║                                                                 ║
║  NOTE: long-lived tokens (`claude setup-token` or               ║
║  CLAUDE_CODE_OAUTH_TOKEN) are inference-only and will NOT work  ║
║  for Remote Control — use `claude /login` instead.              ║
╚════════════════════════════════════════════════════════════════╝

EOF
  # Sleep instead of exiting so operators can still `docker exec` in
  # to run `claude /login`. Exit would cause on-failure:3 restart
  # loop storms.
  exec sleep infinity
fi

# Claude Code v2.1.x exposes Remote Control as a top-level flag
# `--remote-control [name]` (alias `--rc`) that takes the session
# name as a positional value, rather than as a `remote-control`
# subcommand with `--name`. Using the subcommand form fails with
# "unknown option '--name'" on this version. Both flags are
# top-level and must precede any subcommand (none is used here).
exec claude \
  --dangerously-skip-permissions \
  --remote-control "${DEVBOX_NAME:-devbox}"
