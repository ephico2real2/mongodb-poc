#!/usr/bin/env bash
# A drill with every Hubble drop on the six nodes recorded while it runs, and a control on each node that proves the
# recording works there: a pod in the node's own cluster, pinned to the node, whose egress to 192.0.2.1 (TEST-NET-1) a
# temporary policy denies, so its attempts must appear as drops in that node's stream. A node whose control shows no
# drop proves nothing about the drops there, and the run fails.
#
#   kind-mesh-cilium/scripts/drill-capture.sh <tag> mongot mesh2 both   # record: output/drill-mongot-mesh2-both-<tag>.txt
#                                                                       #   and output/drill-capture-<tag>.txt
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
lab_env
tag=${1:?usage: drill-capture.sh <tag> <drills.sh arguments...>}
shift
cap="$here/output/drill-capture-$tag.txt"
clusters=(mesh0 mesh1 mesh2)
dir=$(mktemp -d)
pids=()
drill=""

# Runs on every exit, a signal included (bash runs the EXIT trap on SIGINT and SIGTERM). The drill is a background
# child so that a signal is acted on at once, and it is stopped here: its own trap restores what it changed. Its
# children go first (its load's kubectl exec would otherwise search on, up to 120 s, after it).
kill_tree() { local p; for p in $(pgrep -P "$1"); do kill_tree "$p"; done; kill "$1" 2>/dev/null || true; }
cleanup() {
  local c
  [ -z "$drill" ] || kill_tree "$drill"
  [ ${#pids[@]} -eq 0 ] || kill "${pids[@]}" 2>/dev/null || true
  for c in "${clusters[@]}"; do
    kubectl --context "kind-$c" -n default delete pod -l run=capture-control --ignore-not-found --wait=false \
      >/dev/null 2>&1 || true
    kubectl --context "kind-$c" -n default delete cnp capture-control --ignore-not-found >/dev/null 2>&1 || true
  done
  rm -rf "$dir"
}
trap cleanup EXIT

# Controls left by an interrupted run must be gone before new ones are created.
for c in "${clusters[@]}"; do
  kubectl --context "kind-$c" -n default delete pod -l run=capture-control --ignore-not-found --wait=true --timeout=90s >/dev/null
done

# One stream per node, straight to a file so that $! is kubectl itself. The remote side is a shell that ends hubble
# when its stdin closes, which happens when kubectl is killed or dies; killing kubectl alone leaves
# `hubble observe --follow` running in the agent for good. The stdin is a FIFO this script holds open, so the remote
# shell sees no EOF before then. IPv6 multicast from a new pod is dropped as an unsupported protocol; hubble-observer
# leaves it out too. Beside each stream, the node's control: a pod pinned to the node (nodeName: a cordon does not
# stop it), denied by the cluster's capture-control policy.
mkfifo "$dir/stdin"
exec 3<>"$dir/stdin"
for c in "${clusters[@]}"; do
  kubectl --context "kind-$c" apply -f - >/dev/null <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: capture-control
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      run: capture-control
  enableDefaultDeny:
    egress: false
  egressDeny:
    - toCIDR: [192.0.2.1/32]
EOF
  while read -r p node; do
    # shellcheck disable=SC2016  # $! is the remote shell's
    kubectl --context "kind-$c" -n kube-system exec -i "$p" -c cilium-agent -- sh -c 'hubble observe --follow \
      --verdict DROPPED --not --drop-reason-desc UNSUPPORTED_L3_PROTOCOL -o compact & cat >/dev/null; kill $!' \
      <&3 >"$dir/$node" 2>&1 &
    pids+=($!)
    kubectl --context "kind-$c" -n default run "capture-control-${node#"$c-"}" --labels=run=capture-control \
      --image=docker.io/library/busybox:1.36 --image-pull-policy=IfNotPresent --restart=Never \
      --overrides="{\"spec\":{\"nodeName\":\"$node\"}}" \
      -- sh -c 'trap "exit 0" TERM; while true; do nc -z -w 1 192.0.2.1 9; sleep 2; done' >/dev/null
  done < <(kubectl --context "kind-$c" -n kube-system get pods -l k8s-app=cilium --no-headers \
    -o custom-columns=:metadata.name,:spec.nodeName)
done
[ ${#pids[@]} -eq 6 ] || { echo "expected 6 cilium agents, found ${#pids[@]}" >&2; exit 1; }
for c in "${clusters[@]}"; do
  kubectl --context "kind-$c" -n default wait pod -l run=capture-control --for=condition=Ready --timeout=90s >/dev/null
done

# Envoy's counters for mongot-global on every node, before and after: a policy drop of an upstream connection is
# silent (policy-deny-response none), so Envoy counts a connect timeout after its 5 s, and a connect failure too (the
# failures include the timeouts); a backend that goes away refuses at once, a connect failure and no timeout.
# A read that fails is recorded as unread, not fatal: after the drill, set -e would end the script and the cleanup
# would delete the drops recorded on every node.
envoy_counts() { # <file>: one line per node: <node> <connect_fail> <connect_timeout>, or <node> unread
  local c p node m
  for c in "${clusters[@]}"; do
    while read -r p node; do
      if m=$(kubectl --context "kind-$c" -n kube-system exec "$p" -c cilium-agent -- cilium-dbg envoy admin metrics); then
        awk -v n="$node" '/envoy_cluster_name="search\/mongot-global"/ && /upstream_cx_connect_fail\{/ {f = $2}
            /envoy_cluster_name="search\/mongot-global"/ && /upstream_cx_connect_timeout\{/ {t = $2}
            END {print n, f + 0, t + 0}' <<<"$m"
      else
        echo "$node unread"
      fi
    done < <(kubectl --context "kind-$c" -n kube-system get pods -l k8s-app=cilium --no-headers \
      -o custom-columns=:metadata.name,:spec.nodeName)
  done >"$1"
}
envoy_counts "$dir/envoy-before"
DRILL_TAG=$tag "$here/drills.sh" "$@" >/dev/null 2>&1 &
drill=$!
wait "$drill" && rc=0 || rc=$?
drill=""
sleep 3
envoy_counts "$dir/envoy-after"
kill "${pids[@]}" 2>/dev/null || true
wait "${pids[@]}" 2>/dev/null || true
pids=()

# The record: the policy under test in each cluster, each node's control (its count and the span of its drops, the
# proof that the node's stream covered the drill), then every other drop with its node.
raw="$dir/all"
: >"$raw"
summary=()
unproven=0
for f in "$dir"/mesh*; do
  node=${f##*/}
  n=$(grep -c 'default/capture-control' "$f" || true)
  # grep finds nothing on a node whose stream failed; under pipefail that must not end the script before the record.
  span=$({ grep 'default/capture-control' "$f" || true; } \
    | awk 'NR == 1 {f = substr($0, 1, 19)} {l = substr($0, 1, 19)} END {if (NR) print f " .. " l}')
  summary+=("# control on $node (default/capture-control-* to 192.0.2.1, denied): $n drops recorded${span:+, $span}")
  [ "$n" -gt 0 ] || unproven=$((unproven + 1))
  sed "s|^|$node |" "$f" | grep -v 'default/capture-control' >>"$raw" || true
done
{
  echo "== Hubble drops on the six nodes during: drills.sh $* (tag $tag, $(date -u +%FT%TZ), drill exit $rc)"
  for c in "${clusters[@]}"; do
    echo "# mongot-ingress policy in $c: $(kubectl --context "kind-$c" -n search get cnp mongot-ingress -o name 2>/dev/null || echo none)"
  done
  printf '%s\n' "${summary[@]}"
  # A node missing from either read (its agents could not be listed) or unread in either is said so, not left out.
  awk 'FILENAME == ARGV[1] {f[$1] = $2; t[$1] = $3; next} {seen[$1] = 1}
    $2 == "unread" || !($1 in f) || f[$1] == "unread" {printf "# envoy mongot-global on %s: not read\n", $1; next}
    {printf "# envoy mongot-global on %s: connect failures +%d, connect timeouts +%d\n", $1, $2 - f[$1], $3 - t[$1]}
    END {for (n in f) if (!(n in seen)) printf "# envoy mongot-global on %s: not read\n", n}' \
    "$dir/envoy-before" "$dir/envoy-after"
  echo "# every other drop: $(grep -c . "$raw" || true)"
  grep . "$raw" || true
} | tee "$cap"
[ "$unproven" -eq 0 ] || { echo "$unproven node(s) recorded no control drop: this capture proves nothing there" >&2; exit 1; }
