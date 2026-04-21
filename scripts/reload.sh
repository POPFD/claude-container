#!/usr/bin/env bash
# Force the firewall sidecar to re-read config/allowlist.yaml
# immediately. Sends SIGHUP to the entrypoint (PID 1 inside the
# sidecar) which interrupts the reconcile loop's sleep.
set -euo pipefail

cd "$(dirname "$0")/.."

exec docker compose kill -s HUP fw-sidecar
