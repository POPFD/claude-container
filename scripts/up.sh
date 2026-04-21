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

exec docker compose up -d --build "$@"
