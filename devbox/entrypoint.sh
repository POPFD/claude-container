#!/bin/bash
# devbox entrypoint, runs as root. Does the minimum a root-only step
# can do (fix up /home/dev/.claude ownership on a freshly-created
# named volume) then drops to `dev` via gosu for the actual workload.
#
# This is a two-stage pattern because named volumes are created
# root:root by Docker on first provision, and the `dev` user can't
# write to them until chown'd. Running claude itself as root would
# also work but we want uid/gid integrity with the workspace bind
# mount.
set -euo pipefail

# Idempotent. First run on a fresh volume chowns; subsequent runs
# see files already owned by dev (1000:1000) and the chown is a noop.
if [[ -d /home/dev/.claude ]]; then
  chown -R dev:dev /home/dev/.claude
fi
if [[ -d /home/dev/.cargo ]]; then
  chown -R dev:dev /home/dev/.cargo
fi

exec gosu dev /devbox-main.sh "$@"
