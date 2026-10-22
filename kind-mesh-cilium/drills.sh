#!/usr/bin/env bash
# The drills of story #132, on search without the operator's Envoy: mongod reaches mongot straight through the Cilium
# global Service mongot-global. Each drill runs a search every half second through the cluster's own member and counts
# each cluster's searches at its mongot (mongot's own searchCommand counter, read through the API server's proxy).
# Each undoes what it does, also when interrupted.
#
#   kind-mesh-cilium/drills.sh mongot [c] one    # c (mesh2) loses the mongot its mongod is connected to
#   kind-mesh-cilium/drills.sh mongot [c] both   # c loses all its mongot: do its searches move to another cluster?
#   kind-mesh-cilium/drills.sh failback [c]      # after a failover: do c's searches come home, before and after a restart?
#   kind-mesh-cilium/drills.sh spread [c] [s]    # how c's searches are spread over its mongot pods
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
lab_env
admin_pw=$(kubectl --context kind-mesh0 -n mongodb get secret mongo-admin -o jsonpath='{.data.password}' | base64 -d)
out="$here/output"
mkdir -p "$out"
restore() {
  local c
  for c in mesh0 mesh1 mesh2; do kubectl --context "kind-$c" uncordon "$c-control-plane" "$c-worker" >/dev/null 2>&1 || true; done
}
trap restore EXIT
t0=$(date +%s)
at() { while [ $(($(date +%s) - t0)) -lt "$1" ]; do sleep 0.5; done; }
note() { printf '[t+%3ss] %s\n' "$(($(date +%s) - t0))" "$1" | tee -a "$log"; }

# A search every half second for <seconds> in a cluster's own member; each failure with its time, then the totals.
load() { # <cluster> <seconds>
  kubectl --context "kind-$1" -n mongodb exec -i mongo-0 -c mongod -- \
    mongosh --quiet --tls --tlsCAFile /run/mongod/ca.crt --host localhost --file /dev/stdin <<EOF
db.getSiblingDB("admin").auth("labAdmin", "$admin_pw");
db.getMongo().setReadPref("nearest");
const start = Date.now(), end = start + $2 * 1000, r = {ok: 0, fail: 0, maxMs: 0, maxAt: null, firstFailAt: null, lastFailAt: null};
const s = () => ((Date.now() - start) / 1000).toFixed(1);
while (Date.now() < end) {
  const t = Date.now(), at = s();
  try { db.getSiblingDB("sample_mflix").movies.aggregate([{\$search: {index: "default", text: {query: "space", path: {wildcard: "*"}}}}, {\$limit: 1}]).toArray(); r.ok++; }
  catch (e) { r.fail++; r.firstFailAt = r.firstFailAt || at; r.lastFailAt = at; print("  search failed at " + at + " s: " + (e.codeName || e.message).slice(0, 90)); }
  const ms = Date.now() - t; if (ms > r.maxMs) { r.maxMs = ms; r.maxAt = at; }
  sleep(500);
}
print("RESULT " + JSON.stringify(r));
EOF
}
# Searches one mongot pod has answered (0 when the pod is not running).
pod_searches() { # <cluster> <pod>
  local v
  v=$(kubectl --context "kind-$1" get --raw "/api/v1/namespaces/search/pods/$2:9946/proxy/metrics" 2>/dev/null \
    | awk '/^mongot_command_searchCommandTotalLatency_seconds_count/ {print int($2); exit}')
  echo "${v:-0}"
}
mongot_pods() { kubectl --context "kind-$1" -n search get pods -l app=mongot-search-0-svc --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'; }
# Searches each cluster's mongot answered, as "mesh0=N mesh1=N mesh2=N".
counts() {
  local c p n
  for c in mesh0 mesh1 mesh2; do
    n=0; for p in $(mongot_pods "$c"); do n=$((n + $(pod_searches "$c" "$p"))); done
    printf '%s=%s ' "$c" "$n"
  done
}
# The mongot pod of <cluster> that answers one search through its own member, or nothing if another cluster's did.
serving_pod() { # <cluster>
  local c=$1 p before=() i=0 hit=""
  local pods; read -r -a pods <<<"$(mongot_pods "$c")"
  for p in "${pods[@]}"; do before+=("$(pod_searches "$c" "$p")"); done
  load "$c" 1 >/dev/null 2>&1
  for p in "${pods[@]}"; do [ "$(pod_searches "$c" "$p")" -gt "${before[$i]}" ] && hit=$p; i=$((i + 1)); done
  echo "$hit"
}

drill_mongot() { # <cluster> <one|both>
  local c=$1 which=$2 pods holder
  log="$out/drill-mongot-$c-$which.txt"
  t0=$(date +%s)
  echo "== drill: $c loses $which of its mongot while its mongod searches (120 s); no Envoy, mongot-global straight to mongot" | tee "$log"
  holder=$(serving_pod "$c")
  [ -n "$holder" ] || { note "$c's mongod is not served by its own mongot; run the failback drill first"; return 1; }
  note "$c's mongod is served by its own $holder"
  if [ "$which" = both ]; then pods=$(mongot_pods "$c"); else pods=$holder; fi
  note "searches answered before: $(counts)"
  load "$c" 120 >"$out/drill-mongot-$c-$which-load.txt" 2>&1 &
  at 15; note "cordon $c's nodes and delete $pods: no replacement can be scheduled"
  kubectl --context "kind-$c" cordon "$c-control-plane" "$c-worker" >/dev/null
  # shellcheck disable=SC2086  # one argument per pod
  kubectl --context "kind-$c" -n search delete pod $pods --wait=false >/dev/null
  at 45; note "searches answered so far: $(counts)"
  at 75; note "uncordon $c: its mongot are scheduled again"
  kubectl --context "kind-$c" uncordon "$c-control-plane" "$c-worker" >/dev/null
  wait
  note "searches answered after: $(counts); $c's mongot: $(mongot_pods "$c")"
  note "after the drill, one search through $c's member is served by: $(serving_pod "$c" | sed 's/^$/another cluster/')"
  tee -a "$log" <"$out/drill-mongot-$c-$which-load.txt"
}

drill_failback() { # <cluster>
  local c=$1 st
  log="$out/drill-failback-$c.txt"
  t0=$(date +%s)
  echo "== drill: $c's searches after a failover, before and after a restart of its mongod" | tee "$log"
  note "one search through $c's member is served by: $(serving_pod "$c" | sed 's/^$/another cluster/')"
  kubectl --context "kind-$c" -n mongodb delete pod mongo-0 >/dev/null
  kubectl --context "kind-$c" -n mongodb wait pod mongo-0 --for=condition=Ready --timeout=3m >/dev/null
  for _ in $(seq 1 60); do
    st=$(printf 'db.getSiblingDB("admin").auth("labAdmin", "%s"); print(db.hello().secondary || db.hello().isWritablePrimary)' "$admin_pw" \
      | kubectl --context "kind-$c" -n mongodb exec -i mongo-0 -c mongod -- mongosh --quiet --tls --tlsCAFile /run/mongod/ca.crt --host localhost --file /dev/stdin 2>/dev/null)
    [ "$st" = true ] && break; sleep 2
  done
  note "$c's mongod restarted and back in the replica set: $st"
  note "one search through $c's member is served by: $(serving_pod "$c" | sed 's/^$/another cluster/')"
}

drill_spread() { # <cluster> <seconds>: how a cluster's searches are spread over its mongot pods
  local c=$1 secs=$2 p
  local before=() i=0 pods
  log="$out/drill-spread-$c.txt"
  t0=$(date +%s)
  read -r -a pods <<<"$(mongot_pods "$c")"
  echo "== $c's searches over its mongot pods: ${secs} s of searches through its member" | tee "$log"
  for p in "${pods[@]}"; do before+=("$(pod_searches "$c" "$p")"); done
  load "$c" "$secs" | grep RESULT | tee -a "$log"
  for p in "${pods[@]}"; do note "$p answered $(( $(pod_searches "$c" "$p") - ${before[$i]} ))"; i=$((i + 1)); done
}

case "${1:-}" in
  mongot) drill_mongot "${2:-mesh2}" "${3:-both}" ;;
  failback) drill_failback "${2:-mesh2}" ;;
  spread) drill_spread "${2:-mesh2}" "${3:-20}" ;;
  load-only) log=/dev/null; load "${2:-mesh2}" "${3:-60}" ;;   # a search load alone, for scripts/cleartext-l7.sh
  *) echo "usage: $0 mongot [cluster] [one|both] | failback [cluster] | spread [cluster] [seconds] | load-only [cluster] [seconds]" >&2; exit 2 ;;
esac
