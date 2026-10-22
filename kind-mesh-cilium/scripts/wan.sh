#!/usr/bin/env bash
# A wide-area link, emulated: the three clusters share one VM, so the links between them have no delay and never drop.
# This puts Linux netem (tc) on a cluster's nodes, for their traffic to the other clusters' nodes only: the WireGuard
# packets that carry every pod-to-pod connection between clusters, and Cluster Mesh's own. Traffic inside the cluster
# is not touched.
#
#   kind-mesh-cilium/scripts/wan.sh delay mesh0 50 10 0.5   # 50 ms each way, 10 ms jitter, 0.5% loss
#   kind-mesh-cilium/scripts/wan.sh cut mesh0 4.5           # every packet to the other clusters lost for 4.5 s
#   kind-mesh-cilium/scripts/wan.sh show mesh0 | off mesh0
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
lab_env

nodes() { docker ps --format '{{.Names}}' | grep -E "^$1-(control-plane|worker)$"; }
# The kind network addresses of every node not in <cluster>.
others() { docker network inspect kind -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' \
  | awk -v c="$1-" 'NF && index($1, c) != 1 { sub(/\/.*/, "", $2); print $2 }'; }

off() { local n; for n in $(nodes "$1"); do docker exec "$n" tc qdisc del dev eth0 root 2>/dev/null || true; done; }
# netem <cluster> <netem arguments...>: a 4-band prio qdisc whose default map uses bands 1-3 only; the other
# clusters' nodes are filtered into band 4, which holds the netem.
netem() {
  local c=$1 n ip; shift
  off "$c"
  for n in $(nodes "$c"); do
    docker exec "$n" tc qdisc add dev eth0 root handle 1: prio bands 4 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1
    docker exec "$n" tc qdisc add dev eth0 parent 1:4 handle 40: netem "$@"
    for ip in $(others "$c"); do
      docker exec "$n" tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip dst "$ip/32" flowid 1:4
    done
  done
}

case "${1:-}" in
  delay) netem "$2" delay "${3}ms" "${4:-0}ms" loss "${5:-0}%" ;;
  cut) netem "$2" loss 100%; python3 -c "import time; time.sleep(float('$3'))"; off "$2" ;;
  off) off "$2" ;;
  show) for n in $(nodes "$2"); do echo "== $n"; docker exec "$n" tc qdisc show dev eth0; echo "filters: $(docker exec "$n" tc filter show dev eth0 | grep -c 'match' || true)"; done ;;
  *) echo "usage: $0 delay <cluster> <ms> [jitter ms] [loss %] | cut <cluster> <seconds> | show <cluster> | off <cluster>" >&2; exit 2 ;;
esac
