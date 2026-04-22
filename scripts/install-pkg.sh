#!/usr/bin/env bash
# Host-side backchannel for installing apt packages into the running
# devbox container. Intended for the operator to run when Claude
# reports a missing tool.
#
# Security model:
#   - This script MUST only be runnable from the host. Claude and any
#     other in-container process runs as `dev` (uid 1000) with no
#     sudoers entry and `no-new-privileges`, so it cannot invoke
#     `apt-get` itself. Reaching this path requires access to the
#     host Docker socket, which Claude does not have.
#   - apt transport is plaintext HTTP, but packages are GPG-verified
#     by apt — on-path tamper is detectable and aborts the install.
#   - Installed packages live in the container rootfs. They survive
#     restarts but NOT `scripts/down.sh` (container recreation). If
#     you need persistence, bake the package into devbox/Dockerfile.
#
# Usage:
#   ./scripts/install-pkg.sh <pkg> [<pkg> ...]
#   ./scripts/install-pkg.sh --update            # just apt-get update
#   ./scripts/install-pkg.sh --shell             # root shell in devbox
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -eq 0 ]]; then
  sed -n '2,23p' "$0" >&2
  exit 2
fi

# Confirm the devbox container is up before we try to exec into it —
# otherwise `docker compose exec` produces a cryptic error.
if ! docker compose ps --status running devbox --format '{{.Name}}' \
      | grep -qx devbox; then
  echo "install-pkg: devbox container is not running." >&2
  echo "            Start it first with ./scripts/up.sh." >&2
  exit 1
fi

if [[ "${1:-}" == "--shell" ]]; then
  exec docker compose exec -it -u 0 devbox bash -l
fi

# apt-get update is always run (cheap if lists are fresh), so a bare
# --update invocation is a convenient way to prime the cache.
if [[ "${1:-}" == "--update" ]]; then
  exec docker compose exec -T -u 0 \
    -e DEBIAN_FRONTEND=noninteractive \
    devbox apt-get update
fi

# Delegate to a single apt-get transaction so failures are atomic and
# the output stays linear. `-T` avoids allocating a TTY (this is a
# one-shot command, not a shell).
exec docker compose exec -T -u 0 \
  -e DEBIAN_FRONTEND=noninteractive \
  devbox bash -c 'apt-get update && apt-get install -y --no-install-recommends "$@"' \
  _ "$@"
