#!/bin/bash
# Start the service locally for development on macOS.
#
#   ./dev-startup.sh
#
# There is no /root/VM.set on a laptop, so this runs the containers as you
# (your own uid/gid) under a placeholder account name. There is no catalog
# storage either: /hats/ serves ./dev-hats, which starts empty. Put a small
# HATS catalog in it to try the listings.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

mkdir -p dev-hats

export SVC_USER=dev-svc
export SVC_UID="$(id -u)"
export SVC_GID="$(id -g)"
export SVC_FQDN=localhost
export HATS_DIR="$PWD/dev-hats"

# The same blue/green deploy as on the VM, with docker. Run it again to
# deploy a second time and watch the colours swap.
CONTAINER_ENGINE=docker ./deploy.sh "$@"
echo
echo "data.lsdb.io at http://localhost:8080/"
echo "lsdb.io at      http://lsdb.localhost:8080/  (or: curl -H 'Host: lsdb.io' http://localhost:8080/)"
echo "Stop with: docker compose down  (in a shell with the SVC_* variables above set)"
