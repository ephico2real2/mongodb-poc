#!/usr/bin/env bash
# The lab's three resilience drills, each with a load running through it and its numbers printed. Each undoes what it
# does. Run them on a lab where check.sh passes.
#
#   kind-mesh/drills.sh envoy [c]  # cluster c (mesh1) loses its Envoy: do its mongod's searches move to another's?
#   kind-mesh/drills.sh mongot [c] [one|both]  # cluster c (mesh2) loses one mongot, or all, while its Envoy stays ready
#   kind-mesh/drills.sh failback [c]  # after the envoy drill: does restarting c's mongod bring its searches home?
#   kind-mesh/drills.sh cluster    # mesh0 freezes: does the replica set elect another primary, and do writes and
#                                  # searches go on in mesh1? Does mesh0 come back?
#
# mongot-global fails over between clusters only when a cluster has no ready Envoy (Cilium's affinity local keeps only
# local backends while one is ready, measured 2026-10-21). Envoy stays ready when its own mongot is down, so the mongot
# drill shows a lost mongot that is not failed over; the Envoy drill, a lost Envoy that is.
set -uo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/scripts/lib.sh"
lab_env
admin_pw=$(kubectl --context kind-mesh0 -n mongodb get secret mongo-admin -o jsonpath='{.data.password}' | base64 -d)
# CLIENT_OPTS adds connection-string options to the writing client, e.g. CLIENT_OPTS="connectTimeoutMS=5000&socketTimeoutMS=5000"
# to compare a client with timeouts against mongosh's defaults; the cluster drill's log is then drill-cluster-<options>.txt.
rs_uri="mongodb://mongo-mesh0.mongodb.svc.cluster.local,mongo-mesh1.mongodb.svc.cluster.local,mongo-mesh2.mongodb.svc.cluster.local/?replicaSet=rs0&tls=true&tlsCAFile=/run/mongod/ca.crt&serverSelectionTimeoutMS=2000${CLIENT_OPTS:+&$CLIENT_OPTS}"
out="$LAB_DIR/output"
# An interrupted drill must not leave a cluster's nodes cordoned or paused: undo both, for every cluster, on any exit.
restore() {
  local c
  for c in mesh0 mesh1 mesh2; do
    kubectl --context "kind-$c" uncordon "$c-control-plane" "$c-worker" >/dev/null 2>&1 || true
    docker unpause "$c-control-plane" "$c-worker" >/dev/null 2>&1 || true
  done
}
trap restore EXIT
t0=$(date +%s)
at() { while [ $(($(date +%s) - t0)) -lt "$1" ]; do sleep 0.5; done; }   # waits until t0 + <seconds>
note() { printf '[t+%3ss] %s\n' "$(($(date +%s) - t0))" "$1" | tee -a "$log"; }

# A load that runs for <seconds> in a cluster's own member: one search, and with "writes" one majority write through
# the replica set, every half second. It prints each failure with its time and, at the end, the totals as JSON.
load() { # <cluster> <seconds> <search|writes>
  kubectl --context "kind-$1" -n mongodb exec -i mongo-0 -c mongod -- \
    mongosh --quiet --tls --tlsCAFile /run/mongod/ca.crt --host localhost --file /dev/stdin <<EOF
db.getSiblingDB("admin").auth("labAdmin", "$admin_pw");
db.getMongo().setReadPref("nearest");
const rs = "$3" === "writes" ? new Mongo("$rs_uri") : null;
if (rs) rs.getDB("admin").auth("labAdmin", "$admin_pw");
const start = Date.now(), end = start + $2 * 1000, r = {search: {ok: 0, fail: 0}, write: {ok: 0, fail: 0}};
const s = () => ((Date.now() - start) / 1000).toFixed(1);
let firstFail = null, lastFail = null;
// Each operation's time, so that an operation that waits out a failover is seen, not only one that fails.
const timed = (k, f) => { const t = Date.now(); const at = s();
  try { f(); r[k].ok++; } catch (e) { r[k].fail++; firstFail = firstFail || at; lastFail = at; print("  " + k + " failed at " + at + " s: " + (e.codeName || e.message).slice(0, 90)); }
  const ms = Date.now() - t; if (!r[k].maxMs || ms > r[k].maxMs) { r[k].maxMs = ms; r[k].maxAt = at; } };
while (Date.now() < end) {
  timed("search", () => db.getSiblingDB("sample_mflix").movies.aggregate([{\$search: {index: "default", text: {query: "space", path: {wildcard: "*"}}}}, {\$limit: 1}]).toArray());
  if (rs) timed("write", () => rs.getDB("lab").drill.insertOne({at: new Date()}, {writeConcern: {w: "majority", wtimeout: 3000}}));
  sleep(500);
}
r.firstFailAt = firstFail; r.lastFailAt = lastFail;
print("RESULT " + JSON.stringify(r));
EOF
}
envoy_requests() { # <cluster>: requests its Envoy sent to its mongot
  local p; p=$(kubectl --context "kind-$1" -n search get pod -l app=mongot-search-lb-0 --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$p" ] || { echo "none"; return; }
  kubectl --context "kind-$1" get --raw "/api/v1/namespaces/search/pods/$p:9901/proxy/stats?filter=mongot_rs_cluster.upstream_rq_total$" 2>/dev/null | awk '{print $2}'
}
envoy_stat() { # <cluster> <stat name>: one counter of its Envoy, through the API server's proxy
  local p; p=$(kubectl --context "kind-$1" -n search get pod -l app=mongot-search-lb-0 --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$p" ] || { echo "none"; return; }
  kubectl --context "kind-$1" get --raw "/api/v1/namespaces/search/pods/$p:9901/proxy/stats?filter=$2$" 2>/dev/null | awk '{print $2}'
}
# That a cluster's mongod is on its own Envoy: one search must add a request to it. After an earlier failover it may
# still be on another cluster's, and a drill of this cluster's Envoy or mongot would then test nothing.
on_own_envoy() { # <cluster>
  local b a
  b=$(envoy_requests "$1")
  load "$1" 1 search >/dev/null 2>&1
  a=$(envoy_requests "$1")
  [ "$a" -gt "$b" ] 2>/dev/null || { note "$1's mongod is not on its own Envoy ($b -> $a requests); restart its mongod first: kubectl --context kind-$1 -n mongodb delete pod mongo-0"; return 1; }
  note "$1's mongod is on its own Envoy ($b -> $a requests)"
}
primary() { printf 'db.getSiblingDB("admin").auth("labAdmin", "%s"); print(db.hello().primary || "none")' "$admin_pw" \
  | kubectl --context "kind-$1" -n mongodb exec -i mongo-0 -c mongod -- mongosh --quiet --tls --tlsCAFile /run/mongod/ca.crt --host localhost --file /dev/stdin 2>/dev/null | cut -d. -f1; }

drill_envoy() { # <cluster>
  local c=$1 o1 o2 p b1 b2
  log="$out/drill-envoy-$c.txt"
  read -r o1 o2 <<<"$(for x in mesh0 mesh1 mesh2; do [ "$x" = "$c" ] || printf '%s ' "$x"; done)"
  t0=$(date +%s)
  echo "== drill: $c loses its Envoy while its mongod searches (120 s)" | tee "$log"
  on_own_envoy "$c" || return 1
  b1=$(envoy_requests "$o1"); b2=$(envoy_requests "$o2")
  load "$c" 120 search >"$out/drill-envoy-$c-load.txt" 2>&1 &
  at 15; note "cordon $c's nodes and delete its Envoy pod: its replacement cannot be scheduled"
  kubectl --context "kind-$c" cordon "$c-control-plane" "$c-worker" >/dev/null
  p=$(kubectl --context "kind-$c" -n search get pod -l app=mongot-search-lb-0 -o jsonpath='{.items[0].metadata.name}')
  kubectl --context "kind-$c" -n search delete pod "$p" --wait=false >/dev/null
  at 75; note "uncordon $c: its Envoy is scheduled again"
  kubectl --context "kind-$c" uncordon "$c-control-plane" "$c-worker" >/dev/null
  wait
  note "$c's Envoy ready again: $(kubectl --context "kind-$c" -n search get pod -l app=mongot-search-lb-0 -o jsonpath='{.items[0].status.containerStatuses[0].ready}')"
  note "requests through the other clusters' Envoys: $o1 $b1 -> $(envoy_requests "$o1"), $o2 $b2 -> $(envoy_requests "$o2"); $c's new Envoy: $(envoy_requests "$c")"
  tee -a "$log" <"$out/drill-envoy-$c-load.txt"
}

drill_mongot() { # <cluster> <one|both>: one of its mongot, or every one, goes away while its Envoy stays ready
  local c=$1 which=$2 o1 o2 b1 b2 rq rt pods
  log="$out/drill-mongot-$c-$which.txt"
  if [ "$which" = both ]; then
    pods=$(kubectl --context "kind-$c" -n search get pods -l app=mongot-search-0-svc -o jsonpath='{.items[*].metadata.name}')
  else
    pods=mongot-search-0-0
  fi
  read -r o1 o2 <<<"$(for x in mesh0 mesh1 mesh2; do [ "$x" = "$c" ] || printf '%s ' "$x"; done)"
  t0=$(date +%s)
  echo "== drill: $c loses $which of its mongot ($pods) while its Envoy stays ready and its mongod searches (120 s)" | tee "$log"
  on_own_envoy "$c" || return 1
  b1=$(envoy_requests "$o1"); b2=$(envoy_requests "$o2"); rq=$(envoy_requests "$c"); rt=$(envoy_stat "$c" mongot_rs_cluster.upstream_rq_retry)
  note "before: $c's Envoy $rq requests, $rt retries; $o1 $b1, $o2 $b2"
  load "$c" 120 search >"$out/drill-mongot-$c-$which-load.txt" 2>&1 &
  at 15; note "cordon $c's nodes and delete $pods: no replacement can be scheduled"
  kubectl --context "kind-$c" cordon "$c-control-plane" "$c-worker" >/dev/null
  # shellcheck disable=SC2086  # one argument per pod
  kubectl --context "kind-$c" -n search delete pod $pods --wait=false >/dev/null
  at 30; note "$c's Envoy ready: $(kubectl --context "kind-$c" -n search get pod -l app=mongot-search-lb-0 -o jsonpath='{.items[0].status.containerStatuses[0].ready}'); its mongot: $(kubectl --context "kind-$c" -n search get pods -l app=mongot-search-0-svc --no-headers -o custom-columns='N:.metadata.name,P:.status.phase,R:.status.containerStatuses[0].ready' | tr -s ' ' | tr '\n' ';')"
  at 75; note "uncordon $c: its mongot is scheduled again"
  kubectl --context "kind-$c" uncordon "$c-control-plane" "$c-worker" >/dev/null
  wait
  note "$c's mongot: $(kubectl --context "kind-$c" -n search get pods -l app=mongot-search-0-svc --no-headers -o custom-columns='N:.metadata.name,R:.status.containerStatuses[0].ready' | tr -s ' ' | tr '\n' ';')"
  note "after: $c's Envoy $(envoy_requests "$c") requests (was $rq), $(envoy_stat "$c" mongot_rs_cluster.upstream_rq_retry) retries (was $rt); $o1 $(envoy_requests "$o1") (was $b1), $o2 $(envoy_requests "$o2") (was $b2)"
  tee -a "$log" <"$out/drill-mongot-$c-$which-load.txt"
}

drill_failback() { # <cluster>: after a failover, does a restart of its mongod bring its searches home?
  local c=$1 b a st
  log="$out/drill-failback-$c.txt"
  t0=$(date +%s)
  echo "== drill: $c's mongod, on another cluster's Envoy after a failover, is restarted" | tee "$log"
  b=$(envoy_requests "$c"); load "$c" 1 search >/dev/null 2>&1; a=$(envoy_requests "$c")
  [ "$a" = "$b" ] || { note "$c's mongod is already on its own Envoy ($b -> $a); run the envoy drill first"; return 1; }
  note "before: one search through $c's member added nothing to $c's Envoy ($b -> $a): it went to another cluster"
  kubectl --context "kind-$c" -n mongodb delete pod mongo-0 >/dev/null
  kubectl --context "kind-$c" -n mongodb wait pod mongo-0 --for=condition=Ready --timeout=3m >/dev/null
  for _ in $(seq 1 60); do
    st=$(printf 'db.getSiblingDB("admin").auth("labAdmin", "%s"); print(db.hello().secondary || db.hello().isWritablePrimary)' "$admin_pw" \
      | kubectl --context "kind-$c" -n mongodb exec -i mongo-0 -c mongod -- mongosh --quiet --tls --tlsCAFile /run/mongod/ca.crt --host localhost --file /dev/stdin 2>/dev/null)
    [ "$st" = true ] && break; sleep 2
  done
  note "$c's mongod restarted and back in the replica set (secondary or primary: $st)"
  b=$(envoy_requests "$c"); load "$c" 1 search >/dev/null 2>&1; a=$(envoy_requests "$c")
  note "after: one search through $c's member added $((a - b)) to $c's Envoy ($b -> $a)"
}

drill_cluster() {
  log="$out/drill-cluster${CLIENT_OPTS:+-$(printf '%s' "$CLIENT_OPTS" | tr '&=' '-_')}.txt"
  t0=$(date +%s)
  echo "== drill: mesh0 (the primary's cluster) freezes for 60 s while mesh1 writes and searches (150 s)${CLIENT_OPTS:+; client options $CLIENT_OPTS}" | tee "$log"
  echo "primary before: $(primary mesh1)" | tee -a "$log"
  load mesh1 150 writes >"$out/drill-cluster-load.txt" 2>&1 &
  at 15; note "docker pause mesh0's two nodes"
  docker pause mesh0-control-plane mesh0-worker >/dev/null
  for _ in $(seq 1 40); do p=$(primary mesh1); [ -n "$p" ] && [ "$p" != none ] && [ "$p" != mongo-mesh0 ] && break; sleep 1; done
  at 0; note "new primary: $p"
  at 75; note "docker unpause mesh0's two nodes"
  docker unpause mesh0-control-plane mesh0-worker >/dev/null
  wait
  for _ in $(seq 1 60); do p=$(primary mesh1); [ "$p" = mongo-mesh0 ] && break; sleep 2; done
  at 0; note "primary after mesh0 is back: $p (mesh0 has priority 2, so it takes it back once caught up)"
  printf 'db.getSiblingDB("admin").auth("labAdmin", "%s"); rs.status().members.forEach(m => print("  " + m.name.split(".")[0] + " " + m.stateStr))' "$admin_pw" \
    | kubectl --context kind-mesh1 -n mongodb exec -i mongo-0 -c mongod -- mongosh --quiet --tls --tlsCAFile /run/mongod/ca.crt --host localhost --file /dev/stdin | tee -a "$log"
  tee -a "$log" <"$out/drill-cluster-load.txt"
}

case "${1:-}" in
  envoy) drill_envoy "${2:-mesh1}" ;;
  mongot) drill_mongot "${2:-mesh2}" "${3:-one}" ;;
  failback) drill_failback "${2:-mesh2}" ;;
  cluster) drill_cluster ;;
  *) echo "usage: $0 envoy [cluster] | mongot [cluster] [one|both] | failback [cluster] | cluster" >&2; exit 2 ;;
esac
