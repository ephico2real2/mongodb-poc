#!/usr/bin/env bash
# Deletes the lab's kind clusters (all three, or those named) and every volume in them. The Colima VM and the kind
# docker network stay.
#
#   kind-mesh/scripts/down.sh            # mesh0, mesh1, mesh2
#   kind-mesh/scripts/down.sh mesh2      # one
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
lab_env
read -r -a clusters <<<"${*:-$CLUSTERS}"
for c in "${clusters[@]}"; do kind delete cluster --name "$c"; done
