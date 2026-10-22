#!/usr/bin/env bash
# Who can reach mongot's cleartext gRPC port (27028) in mesh0? Four probe pods in mesh1, one per combination of the
# mongod pods' namespace (mongodb) and label (app=mongo), each sends a gRPC health check to both of mesh0's mongot
# pods and to mongot-global; then the Colima VM, a host outside WireGuard given a route to mesh0-worker's pods, opens
# a TCP connection to the mongot pod there. Run once without the policy and once with it
# (manifests/60-mongot-ingress.yaml); the record is output/mongot-reach-<tag>.txt.
#
#   kind-mesh-cilium/scripts/mongot-reach.sh open      # before the policy
#   kind-mesh-cilium/scripts/mongot-reach.sh policy    # with it
#
# A real gRPC request, not a port check: mongot-global goes through Cilium's L7 proxy on the client's node, which
# completes the TCP handshake itself, so only a response tells whether mongot was reached. With affinity local that
# proxy sends to mesh1's own mongot, so the mongot-global row tests mesh1's policy and the pod rows mesh0's. The probe
# pods carry app=mongo but not mesh=<cluster>, so the replica set's Services never select them.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
lab_env
tag=${1:?usage: mongot-reach.sh <tag>}
log="$here/output/mongot-reach-$tag.txt"
image=quay.io/mongodb/mongodb-community-server:8.3.4-ubi9 # on every node already; has curl with HTTP/2
probes=(default:none mongodb:none default:mongo mongodb:mongo)
route=()

cleanup() {
  local p ns
  for p in "${probes[@]}"; do
    ns=${p%%:*}
    kubectl --context kind-mesh1 -n "$ns" delete pod "reach-probe-${p//:/-}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  [ ${#route[@]} -eq 0 ] || colima --profile "$COLIMA_PROFILE" ssh -- sudo ip route del "${route[@]}" 2>/dev/null \
    || echo "mongot-reach: the VM's route is still there; remove it by hand: colima --profile $COLIMA_PROFILE ssh -- sudo ip route del ${route[*]}" >&2
}
trap cleanup EXIT

# An assignment, not a here-string, so that a failing kubectl stops the run (set -e) instead of leaving no pod rows.
pods=$(kubectl --context kind-mesh0 -n search get pods -l app=mongot-search-0-svc \
  -o jsonpath='{range .items[*]}{.status.podIP} {end}')
read -r -a targets <<<"$pods"
[ ${#targets[@]} -gt 0 ] || die "no mongot pod IP in mesh0"
targets+=(mongot-global.search.svc.cluster.local)
policy=$(kubectl --context kind-mesh0 -n search get cnp mongot-ingress -o name 2>/dev/null || echo "none")
policy1=$(kubectl --context kind-mesh1 -n search get cnp mongot-ingress -o name 2>/dev/null || echo "none")

# The probe: for each target, who answered a health check. mongot answers an empty call with grpc-status 13,
# "Half-closed without a request" (grpc-java); through mongot-global the same answer comes back with server: envoy.
# Envoy answers a gRPC request it could not pass on with HTTP 200 and its own grpc-status and message, printed whole
# (a header value can hold ": "); for a dropped connection that answer comes after its 5 s connect timeout, which is
# curl's --max-time too, so the row reads no answer in 5 s.
# shellcheck disable=SC2016  # expanded by the probe's shell
probe_sh='hdr() { printf "%s" "$h" | tr -d "\r" | awk -v k="$1" "{ i = index(\$0, \": \") } i && tolower(substr(\$0, 1, i - 1)) == k { v = substr(\$0, i + 2) } END { print v }"; }
for t in "$@"; do
  h=$(curl -s -o /dev/null -D - --http2-prior-knowledge --max-time 5 -X POST -H "content-type: application/grpc" \
    -H "te: trailers" --data-binary @/dev/null "http://$t:27028/grpc.health.v1.Health/Check" 2>/dev/null); rc=$?
  status=$(hdr grpc-status) msg=$(hdr grpc-message) via=$(hdr server)
  if [ "$msg" = "Half-closed without a request" ]; then r="mongot answered${via:+ (through $via)}";
  elif [ -n "$status" ]; then r="${via:-something} answered instead: grpc-status $status, $msg";
  elif [ $rc -eq 28 ]; then r="no answer in 5 s (dropped)";
  elif [ $rc -eq 6 ]; then r="name not resolved (curl exit 6)";
  elif [ $rc -eq 0 ]; then r="answered without a gRPC status: $(printf "%s" "$h" | head -1 | tr -d "\r")";
  else r="refused or reset (curl exit $rc)"; fi
  printf "  %-46s %s\n" "$t:27028" "$r"
done'

{
  echo "== Who can reach mongot's port 27028 in mesh0? $(date -u +%FT%TZ), tag $tag"
  echo "# policy in mesh0's search namespace: $policy; in mesh1's: $policy1"
  echo "# each probe: a pod in mesh1, image $image, sending a gRPC health check (curl --http2-prior-knowledge)"
  echo "# mongot-global: Cilium's Envoy on the probe's node sends it to mesh1's own mongot (affinity local)"
} | tee "$log"

for p in "${probes[@]}"; do
  ns=${p%%:*} label=${p##*:} name="reach-probe-${p//:/-}"
  labels=()
  [ "$label" = none ] || labels=(--labels "app=$label")
  # A probe left by an interrupted run must be gone before a new one is created (as drill-capture.sh does).
  kubectl --context kind-mesh1 -n "$ns" delete pod "$name" --ignore-not-found --wait=true --timeout=90s >/dev/null
  # ${labels[@]+...}: an empty array under set -u is an unbound variable to bash 3.2, macOS's /bin/bash.
  kubectl --context kind-mesh1 -n "$ns" run "$name" --image="$image" --image-pull-policy=IfNotPresent \
    --restart=Never ${labels[@]+"${labels[@]}"} --command -- sh -c "$probe_sh" probe "${targets[@]}" >/dev/null
  kubectl --context kind-mesh1 -n "$ns" wait "pod/$name" --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null
  node=$(kubectl --context kind-mesh1 -n "$ns" get pod "$name" -o jsonpath='{.spec.nodeName}')
  echo "# namespace $ns, app label: $label (on $node)" | tee -a "$log"
  kubectl --context kind-mesh1 -n "$ns" logs "$name" | tee -a "$log"
  kubectl --context kind-mesh1 -n "$ns" delete pod "$name" --wait=false >/dev/null
done

# The VM: on the kind network (the nodes' gateway), not a Cilium node, so its packets carry no WireGuard and no
# Cilium identity. A TCP connect is the right test here: nothing proxies it.
worker_ip=$(docker inspect mesh0-worker -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}')
cidr=$(kubectl --context kind-mesh0 get ciliumnode mesh0-worker -o jsonpath='{.spec.ipam.podCIDRs[0]}')
pod_ip=$(kubectl --context kind-mesh0 -n search get pods -l app=mongot-search-0-svc --field-selector spec.nodeName=mesh0-worker \
  -o jsonpath='{.items[0].status.podIP}')
echo "# the Colima VM, outside WireGuard, with a route to mesh0-worker's pods for the test: ip route replace $cidr via $worker_ip" | tee -a "$log"
# replace, not add: a route left by an interrupted run must not stop this one; the cleanup removes it either way.
colima --profile "$COLIMA_PROFILE" ssh -- sudo ip route replace "$cidr" via "$worker_ip"
route=("$cidr" via "$worker_ip")
# The exit status is read in the VM: colima ssh turns any non-zero remote status into its own 1.
rc=$(colima --profile "$COLIMA_PROFILE" ssh -- sh -c \
  "timeout 5 bash -c 'exec 3<>/dev/tcp/$pod_ip/27028' 2>/dev/null; echo \$?" 2>/dev/null || echo ssh-failed)
case $rc in
  0) r="TCP connection opened" ;;
  124) r="no TCP connection in 5 s (dropped)" ;;
  ssh-failed) r="not tested: colima ssh failed" ;;
  *) r="no TCP connection (exit $rc: refused)" ;;
esac
printf '  %-46s %s\n' "$pod_ip:27028" "$r" | tee -a "$log"
