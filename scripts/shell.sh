#!/usr/bin/env bash
# Drop into a dev shell inside devbox. Uses `-u dev` defensively —
# image already defaults to dev, but `-u dev` survives if someone
# later flips the Dockerfile to USER root for debugging.
#
# Subcommands:
#   (no args)        interactive dev shell, cwd=/workspace
#   --pentest [...]  run scripts/pentest.sh inside the container
#                    (any trailing args are passed to pentest.sh,
#                    e.g. `./scripts/shell.sh --pentest --quick`)
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--pentest" ]]; then
  shift
  # Stream the host-side pentest.sh into an in-container bash. Running
  # via stdin keeps the script's host copy as the single source of
  # truth (no docker cp, no workspace pollution, no image rebuild).
  # INSIDE_DEVBOX=1 tells pentest.sh to skip its own host-side
  # re-exec. Extra args (e.g. --quick) are forwarded via `-s --`.
  exec docker compose exec -T -u dev \
    -e INSIDE_DEVBOX=1 \
    devbox bash -s -- "$@" < scripts/pentest.sh
fi

exec docker compose exec -it -u dev devbox bash -l "$@"
