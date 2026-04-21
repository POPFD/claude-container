#!/usr/bin/env bash
# Drop into a dev shell inside devbox. Uses `-u dev` defensively —
# image already defaults to dev, but `-u dev` survives if someone
# later flips the Dockerfile to USER root for debugging.
set -euo pipefail

cd "$(dirname "$0")/.."

exec docker compose exec -it -u dev devbox bash -l "$@"
