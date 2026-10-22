#!/usr/bin/env bash
# Stops the lab's Colima VM; the clusters and their volumes stay inside it. Whether the mesh survives a stop and start
# is not yet tested: Docker may give the nodes new addresses, and the mesh is declared by control-plane address
# (cilium-implementation-poc pins them with scripts/cluster-pause.sh and cluster-resume.sh).
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
colima stop --profile "$COLIMA_PROFILE"
