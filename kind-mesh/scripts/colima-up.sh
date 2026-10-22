#!/usr/bin/env bash
# Starts the Colima VM the three kind clusters run in (profile COLIMA_PROFILE in versions.env), creating it the first
# time, raises its inotify limits, then starts the kind nodes on the addresses colima-down.sh recorded and waits for
# the API servers, Cilium and Cluster Mesh. The active docker context is left as it is (--activate=false).
#
#   kind-mesh/scripts/colima-up.sh      # idempotent: a running VM and running nodes are kept
#   kind-mesh/scripts/colima-down.sh    # records the nodes' addresses, stops the nodes and the VM
#
# vz and --network-address as cilium-implementation-poc's poc1 profile: the address is what a Mac route to the
# clusters' LoadBalancer block goes through. A stopped VM is started with versions.env's CPUs, memory and disk: colima
# 0.10.3 takes a flag given to `colima start` over its colima.yaml and rewrites Lima's lima.yaml before it starts the VM
# (cmd/start.go prepareConfig, environment/vm/lima/lima.go resume). A running VM ignores them ("already running,
# ignoring"), so a difference is reported, not applied. A larger disk is grown by `limactl disk resize` before the
# start (environment/vm/lima/disk.go syncDiskSize) and its partition and file system at boot (Lima 2.2.0,
# boot.Linux/05-lima-disks.sh); both only warn when they fail, so the size reached is checked. The VM type and a
# smaller disk cannot be changed.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

gib=1073741824
info=$(colima_info) || die "cannot read Colima's profiles"
read -r status cpus mem disk _ <<<"$info"
started=1
case "$status" in
  Running)
    echo "Colima profile $COLIMA_PROFILE is running: $cpus CPUs, $((mem / gib)) GiB, $((disk / gib)) GiB disk"
    if [ "$cpus" != "$COLIMA_CPUS" ] || [ "$mem" != $((COLIMA_MEMORY_GIB * gib)) ] || [ "$disk" -lt $((COLIMA_DISK_GIB * gib)) ]; then
      echo "  versions.env asks for ${COLIMA_CPUS} CPUs, ${COLIMA_MEMORY_GIB} GiB, ${COLIMA_DISK_GIB} GiB disk: a running" \
        "VM is not resized; kind-mesh/scripts/colima-down.sh, then this script, applies it"
    fi
    started= ;;
  "")
    say "create Colima profile $COLIMA_PROFILE: ${COLIMA_CPUS} CPUs, ${COLIMA_MEMORY_GIB} GiB, ${COLIMA_DISK_GIB} GiB disk"
    colima start --profile "$COLIMA_PROFILE" --vm-type vz --runtime docker --network-address --activate=false \
      --cpus "$COLIMA_CPUS" --memory "$COLIMA_MEMORY_GIB" --disk "$COLIMA_DISK_GIB" ;;
  *)
    say "start Colima profile $COLIMA_PROFILE (was $status, $cpus CPUs, $((mem / gib)) GiB, $((disk / gib)) GiB disk):" \
      "${COLIMA_CPUS} CPUs, ${COLIMA_MEMORY_GIB} GiB, ${COLIMA_DISK_GIB} GiB disk"
    colima start --profile "$COLIMA_PROFILE" --activate=false --cpus "$COLIMA_CPUS" --memory "$COLIMA_MEMORY_GIB" \
      --disk "$COLIMA_DISK_GIB" ;;
esac

# The docker file system, which the nodes' volumes (mongot's data path among them) live on. A partition table and the
# file system's own overhead take a little of the disk (60 GiB gave 97.9%, 2026-10-22); a disk that was not grown
# reads 60% of 100. Checked only on a VM this run started: a running one is reported above.
say "the docker disk"
colima ssh --profile "$COLIMA_PROFILE" -- df -h /var/lib/docker
fs=$(colima ssh --profile "$COLIMA_PROFILE" -- df -B1 --output=size /var/lib/docker | tail -1 | tr -d ' ')
[ -z "$started" ] || [ "$fs" -ge $((COLIMA_DISK_GIB * gib * 95 / 100)) ] \
  || die "the docker file system is $((fs / gib)) GiB, versions.env asks for ${COLIMA_DISK_GIB}: the disk was not grown (colima start's log says why)"

# Ubuntu's fs.inotify.max_user_instances is 128; a second kind cluster in one VM died on it in cilium-implementation-poc
# ("inotify_init: too many open files"), and one cluster with Cilium held 219 instances there. 512 is kind's own
# known-issues value; six nodes here.
say "inotify limits in the VM"
have=$(colima ssh --profile "$COLIMA_PROFILE" -- sysctl -n fs.inotify.max_user_instances)
if [ "$have" -lt 512 ]; then
  colima ssh --profile "$COLIMA_PROFILE" -- sudo sh -c "printf 'fs.inotify.max_user_instances = 512\nfs.inotify.max_user_watches = 1048576\n' > /etc/sysctl.d/99-kind-inotify.conf && sysctl -q -p /etc/sysctl.d/99-kind-inotify.conf"
fi
colima ssh --profile "$COLIMA_PROFILE" -- sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
colima list --profile "$COLIMA_PROFILE"

lab_env
list=$(lab_nodes) || die "cannot list the kind nodes"
if [ -z "$list" ]; then echo "no kind nodes yet: kind-mesh/scripts/up.sh creates the clusters"; exit 0; fi
for t in kubectl cilium; do command -v "$t" >/dev/null || die "$t is not installed"; done
# shellcheck disable=SC2153  # CLUSTERS comes from versions.env
read -r -a clusters <<<"$CLUSTERS"

# Every node is checked, and each stopped one pinned to its address, before any starts: `docker network connect --ip`
# on a stopped container keeps the address in its IPAMConfig, and Docker reapplies it at every start or refuses to start
# the container (docs: docker network connect; cilium-implementation-poc gotcha #43). The address is the one
# colima-down.sh recorded, and it must agree with the node's own (its address, or for a stopped node the one it last
# booted with); after a stop colima-down.sh did not make, there is no record and the node's own is used.
pin_of() { docker inspect "$1" --format '{{with index .NetworkSettings.Networks "kind"}}{{with .IPAMConfig}}{{.IPv4Address}}{{end}}{{end}}'; }
pin_node() { # <node>
  local n="$1" want rec holder
  rec=$(awk -v n="$n" '$1 == n {print $2}' "$MESH_NODE_IPS" 2>/dev/null || true)
  want=$(node_ip "$n")
  [ -n "$want" ] || want="$rec"
  [ -n "$want" ] || die "no address for $n: neither recorded nor in its /kind/old-ipv4"
  # A node at another address than the recorded one was started by Docker on its own, or the clusters were rebuilt.
  [ -z "$rec" ] || [ "$rec" = "$want" ] || die "$n was recorded at $rec but is (or last booted) at $want"
  if [ "$(docker inspect "$n" --format '{{.State.Status}}')" = running ]; then echo "  $n $want running"; return 0; fi
  holder=$(docker network inspect kind --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{println}}{{end}}' \
    | awk -v ip="$want/" 'index($2, ip) == 1 {print $1}')
  [ -z "$holder" ] || die "$want, $n's address, is held by $holder"
  # Docker ignores a connect to a network a stopped container is still on (moby updateNetworkSettings, "Avoid
  # duplicate config"), so the node leaves the network first, and the pin is read back.
  if [ "$(pin_of "$n")" != "$want" ]; then
    docker network disconnect kind "$n" >/dev/null 2>&1 || true
    docker network connect --ip "$want" kind "$n"
    [ "$(pin_of "$n")" = "$want" ] || die "$n could not be pinned to $want"
  fi
  echo "  $n $want pinned"
}
start_node() { # <node>
  local n="$1" want have
  [ "$(docker inspect "$n" --format '{{.State.Status}}')" = running ] && return 0
  want=$(pin_of "$n")
  docker start "$n" >/dev/null
  have=$(node_ip "$n")
  [ "$have" = "$want" ] || die "$n started on $have, not $want"
  echo "  $n $have started"
}

say "the kind nodes' addresses (${MESH_NODE_IPS/$HOME/\~})"
for n in $(printf '%s\n' "$list" | awk '{print $2}'); do pin_node "$n"; done

say "the control planes, then their API servers"
for n in $(printf '%s\n' "$list" | awk '$1 == "control-plane" {print $2}'); do start_node "$n"; done
# kubectl's --request-timeout defaults to 0, no timeout: one hung request would hold the loop.
for c in "${clusters[@]}"; do
  ready=
  for _ in $(seq 1 60); do
    if [ "$(kubectl --context "kind-$c" --request-timeout=5s get --raw /readyz 2>/dev/null)" = ok ]; then ready=1; break; fi
    sleep 5
  done
  [ -n "$ready" ] || die "the API server of $c is not ready after 60 tries, 5 s apart"
  echo "  kind-$c: API server ready"
done

say "the workers"
for n in $(printf '%s\n' "$list" | awk '$1 != "control-plane" {print $2}'); do start_node "$n"; done
# kind's own policy, which colima-down.sh turned off.
# shellcheck disable=SC2046
docker update --restart=on-failure:1 $(printf '%s\n' "$list" | awk '{print $2}') >/dev/null

say "nodes, Cilium and Cluster Mesh"
for c in "${clusters[@]}"; do
  kubectl --context "kind-$c" wait node --all --for=condition=Ready --timeout=5m >/dev/null
  kubectl --context "kind-$c" get nodes -o wide --no-headers | awk '{print "  " $1, $2, $6}'
done
for c in "${clusters[@]}"; do
  out=$(cilium status --context "kind-$c" --wait --wait-duration 10m --interactive=false 2>&1) \
    || { printf '%s\n' "$out"; die "Cilium is not healthy on $c"; }
  echo "  kind-$c: Cilium healthy"
done
for c in "${clusters[@]}"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 10m; done

say "the Mac's path to $LB_RANGE"
lb_path
