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

# Pre-accept Claude Code's Bypass Permissions warning. On v2.1.x
# the key checked at prompt time is
# `skipDangerousModePermissionPrompt` in the user settings file
# (~/.claude/settings.json). A legacy `bypassPermissionsModeAccepted`
# in ~/.claude.json is auto-migrated to that key on startup, but
# the migration apparently does not complete before the prompt
# is rendered in a non-TTY-driven Remote Control launch, so the
# daemon stalls. Writing the migrated key directly bypasses the
# race. Both keys are set: the target key for the running session,
# and the legacy key to keep the operator's mental model aligned
# with Claude's UI (which toggles `bypassPermissionsModeAccepted`
# when clicked).
SETTINGS_JSON=/home/dev/.claude/settings.json
CLAUDE_JSON=/home/dev/.claude.json
python3 - "${SETTINGS_JSON}" "${CLAUDE_JSON}" <<'PY'
import json, os, sys

def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save(p, cfg):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, p)

settings_path, claude_path = sys.argv[1], sys.argv[2]

settings = load(settings_path)
if not settings.get("skipDangerousModePermissionPrompt"):
    settings["skipDangerousModePermissionPrompt"] = True
    save(settings_path, settings)

claude = load(claude_path)
if not claude.get("bypassPermissionsModeAccepted"):
    claude["bypassPermissionsModeAccepted"] = True
    save(claude_path, claude)
PY

# Claude Code v2.1.x exposes Remote Control as a top-level flag
# `--remote-control[=name]` (alias `--rc`) rather than as a
# `remote-control` subcommand with `--name`. The subcommand form
# fails with "unknown option '--name'" on this version.
#
# Use the `=` assignment form rather than a space-separated
# positional. Without a TTY (devbox runs as container PID 1)
# Claude Code treats bare positional arguments as the prompt for
# its non-interactive `--print` mode, so
# `claude --remote-control devbox` parses as "session devbox, no
# name given" and then fails the --print check. `--remote-control=devbox`
# binds the value to the flag unambiguously.
exec claude \
  --dangerously-skip-permissions \
  --remote-control="${DEVBOX_NAME:-devbox}"
