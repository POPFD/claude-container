#!/usr/bin/env bash
# Rebuild the firewall sidecar image and recreate the sidecar
# container so edits to config/allowlist.yaml take effect. The
# allowlist is baked into the image at build time (rather than
# bind-mounted), so an image rebuild is required on reload.
set -euo pipefail

cd "$(dirname "$0")/.."

docker compose build fw-sidecar
exec docker compose up -d --no-deps fw-sidecar
