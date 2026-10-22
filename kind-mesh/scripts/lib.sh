# Sourced by the kind-mesh scripts: the lab's settings, and docker, kind and kubectl pointed at the lab's Colima VM
# and kubeconfig. The active docker context and ~/.kube/config are never changed: kind has no --context flag, so it
# reaches the VM through DOCKER_HOST, and every cluster's context goes to MESH_KUBECONFIG.
# shellcheck shell=bash
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$LAB_DIR/versions.env"
DOCKER_CTX="colima-$COLIMA_PROFILE"

say() { printf '\n== %s  (%s)\n' "$1" "$(date +%H:%M:%S)"; }
die() { echo "kind-mesh: $1" >&2; exit 1; }

# Points docker, kind, kubectl and helm at the lab. Fails when the VM is not running.
lab_env() {
  local host
  host=$(docker context inspect "$DOCKER_CTX" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) \
    || die "no docker context $DOCKER_CTX: start the VM with kind-mesh/scripts/colima-up.sh"
  export DOCKER_HOST="$host" KUBECONFIG="$MESH_KUBECONFIG"
  mkdir -p "$(dirname "$KUBECONFIG")"
}

# Every kind node of CLUSTERS as "<role> <name>", control planes first. One docker call, so a failure reaches the
# caller (pipefail) instead of reading as "no nodes".
lab_nodes() {
  docker ps -a --filter label=io.x-k8s.kind.cluster \
    --format '{{.Label "io.x-k8s.kind.cluster"}} {{.Label "io.x-k8s.kind.role"}} {{.Names}}' \
    | awk -v want=" $CLUSTERS " 'index(want, " " $1 " ") {print $2, $3}' | sort
}

# A kind node's address on the kind network; for a stopped node, the one it last booted with, which kind's entrypoint
# writes to /kind/old-ipv4 at every boot (and rewrites the node's kubeadm files from when it changes).
node_ip() {
  local ip
  ip=$(docker inspect "$1" --format '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}')
  # Docker 29 prints a stopped container's unset address as "invalid IP" (Go's zero netip.Addr), not as nothing
  # (measured 2026-10-22, Docker 29.5.2): only an IPv4 address counts.
  is_ipv4 "$ip" || ip=$(docker cp "$1:/kind/old-ipv4" - 2>/dev/null | tar -xO 2>/dev/null || true)
  if is_ipv4 "$ip"; then printf '%s' "$ip"; fi
}
is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; }

# The lab's VM as `colima list --json` reports it: "<status> <cpus> <memory in bytes> <disk in bytes> <address>",
# nothing when the profile does not exist; the address, empty when stopped, is last. The sizes are the ones the VM was
# last started with (Lima's lima.yaml, rewritten at each start).
colima_info() {
  colima list --json 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    if line.strip():
        d = json.loads(line)
        if d.get("name") == sys.argv[1]:
            print(d.get("status", ""), d.get("cpus", 0), d.get("memory", 0), d.get("disk", 0), d.get("address") or ""); break' "$COLIMA_PROFILE"
}

# The Mac reaches the LoadBalancer blocks through the VM: Docker's FORWARD policy drops what does not come from a
# docker bridge, so the VM accepts the block onto the kind bridge; the Mac's route is your sudo, printed, never run
# (cilium-implementation-poc poc1-colima-up.sh). The VM keeps no iptables rule across a stop (no netfilter-persistent),
# so up.sh and colima-up.sh both run this.
lb_path() {
  local br addr
  br="br-$(docker network inspect kind --format '{{.Id}}' | cut -c1-12)"
  colima ssh --profile "$COLIMA_PROFILE" -- sudo sh -c \
    "iptables -C DOCKER-USER -d $LB_RANGE -o $br -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -d $LB_RANGE -o $br -j ACCEPT"
  addr=$(colima_info | awk '{print $5}')
  echo "for the Mac to reach the clusters' LoadBalancer addresses, once per VM start: sudo route -n add -net $LB_RANGE ${addr:-<the VM address>}"
}

# helm, three tries: a chart repository's transient refusal is not the lab's failure, and upgrade --install is
# idempotent (cilium-implementation-poc scripts/lab-up.sh, helm_r).
helm_r() {
  local i out
  for i in 1 2 3; do
    if out=$(helm "$@" 2>&1); then printf '%s\n' "$out"; return 0; fi
    case "$out" in
      *"connection reset"*|*"TLS handshake timeout"*|*"i/o timeout"*|*"EOF"*|*"503"*|*"502"*)
        echo "  helm: transient failure, try $((i + 1)) of 3 in 15 s" >&2; sleep 15 ;;
      *) printf '%s\n' "$out" >&2; return 1 ;;
    esac
  done
  printf '%s\n' "$out" >&2; return 1
}
