#!/usr/bin/env bash
# Stops the lab's Colima VM; the clusters and their volumes stay inside it. A node's address is in its kubeadm files,
# etcd and API server certificate, and Cluster Mesh declares each member by its control-plane address (up.sh), so
# before the stop every kind node's address is recorded in MESH_NODE_IPS for colima-up.sh, which starts each node on
# it. The nodes are stopped first with their restart policy off: kind gives them on-failure:1, a node ended by the VM's
# shutdown exits non-zero, and Docker would start it again when the VM boots, on an address of its own choosing
# (moby daemon.restore and restartmanager; cilium-implementation-poc scripts/cluster-pause.sh, gotchas #6 and #119).
#
#   kind-mesh/scripts/colima-down.sh
#   kind-mesh/scripts/colima-up.sh      # starts the VM, then the nodes on their recorded addresses
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
lab_env

info=$(colima_info) || die "cannot read Colima's profiles"
read -r status _ <<<"$info"
if [ "$status" = Running ]; then
  # A running VM is stopped only once its nodes are recorded and stopped with their restart policy off.
  docker version >/dev/null 2>&1 || die "Docker in the VM does not answer: the nodes cannot be stopped, the VM is left running"
  list=$(lab_nodes) || die "cannot list the kind nodes: the VM is left running"
  read -r -a nodes <<<"$(printf '%s\n' "$list" | awk '{print $2}' | tr '\n' ' ')"
  if [ "${#nodes[@]}" -gt 0 ]; then
    say "the kind nodes' addresses to ${MESH_NODE_IPS/$HOME/\~}"
    for n in "${nodes[@]}"; do
      ip=$(node_ip "$n")
      [ -n "$ip" ] || die "no address for $n on the kind network: nothing recorded, nothing stopped"
      echo "$n $ip"
    done >"$MESH_NODE_IPS.tmp"
    mv "$MESH_NODE_IPS.tmp" "$MESH_NODE_IPS"
    sed 's/^/  /' "$MESH_NODE_IPS"

    say "stop the kind nodes, their restart policy off until colima-up.sh"
    docker update --restart=no "${nodes[@]}" >/dev/null
    docker stop -t 30 "${nodes[@]}" >/dev/null
    running=$(docker ps --format '{{.Names}}' | grep -F -x -f <(printf '%s\n' "${nodes[@]}") || true)
    [ -z "$running" ] || die "still running after the stop: $running"
    docker ps -a --filter label=io.x-k8s.kind.cluster --format '  {{.Names}} {{.Status}}'
  fi
fi

say "stop Colima profile $COLIMA_PROFILE"
colima stop --profile "$COLIMA_PROFILE"
