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
#   CLIENT_OPTS=... kind-mesh-cilium/drills.sh primary freeze|kill|partition   # story #131: mesh0, the primary's
#                                                # cluster, lost; writes and searches from mesh1; every acknowledged write checked
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
  for c in mesh0 mesh1 mesh2; do
    kubectl --context "kind-$c" uncordon "$c-control-plane" "$c-worker" >/dev/null 2>&1 || true
    docker unpause "$c-control-plane" "$c-worker" >/dev/null 2>&1 || true
  done
  kubectl --context kind-mesh0 delete -f "$here/manifests/50-partition-mesh0.yaml" --ignore-not-found >/dev/null 2>&1 || true
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
# DRILL_TAG, when set, is added to the record's name, so a run under another server setting keeps its own record.
# CLIENT_OPTS adds options to the writing client's connection string, e.g. "timeoutMS=10000" (story #131).
# The drill's checks use the plain URI, so that the options under test do not change how the result is read.
rs_plain="mongodb://mongo-mesh0.mongodb.svc.cluster.local,mongo-mesh1.mongodb.svc.cluster.local,mongo-mesh2.mongodb.svc.cluster.local/?replicaSet=rs0&tls=true&tlsCAFile=/run/mongod/ca.crt"
rs_uri="$rs_plain${CLIENT_OPTS:+&$CLIENT_OPTS}"
# A majority write through the replica set and a search, every half second, from a cluster's member; each failure
# with its time, then the totals, including the longest wait of each. Each write has its own _id, <run>-<n>, so the
# drill can check every acknowledged write by id, and list the failed ones: a write that fails on its write concern
# (wtimeout) has been applied on the primary and is not undone. gapMs is the longest time between two acknowledged
# writes, the outage an application sees.
load_rw() { # <cluster> <seconds> <run id>
  kubectl --context "kind-$1" -n mongodb exec -i mongo-0 -c mongod -- \
    mongosh --quiet --tls --tlsCAFile /run/mongod/ca.crt --host localhost --file /dev/stdin <<EOF
db.getSiblingDB("admin").auth("labAdmin", "$admin_pw");
db.getMongo().setReadPref("nearest");
const rs = new Mongo("$rs_uri"); rs.getDB("admin").auth("labAdmin", "$admin_pw");
const start = Date.now(), end = start + $2 * 1000, r = {search: {ok: 0, fail: 0, maxMs: 0, maxAt: null}, write: {ok: 0, fail: 0, maxMs: 0, maxAt: null, gapMs: 0, gapAt: null, failedIds: []}};
const s = () => ((Date.now() - start) / 1000).toFixed(1);
const timed = (k, f) => { const t = Date.now(), at = s(); let ok = true;
  try { f(); r[k].ok++; } catch (e) { ok = false; r[k].fail++; print("  " + k + " failed at " + at + " s: " + (e.codeName || e.message).slice(0, 90)); }
  const ms = Date.now() - t; if (ms > r[k].maxMs) { r[k].maxMs = ms; r[k].maxAt = at; }
  return ok; };
let n = 0, lastOk = Date.now();
while (Date.now() < end) {
  const id = "$3-" + (++n);
  if (timed("write", () => rs.getDB("lab").drill.insertOne({_id: id, at: new Date()}, {writeConcern: {w: "majority", wtimeout: 3000}}))) {
    if (Date.now() - lastOk > r.write.gapMs) { r.write.gapMs = Date.now() - lastOk; r.write.gapAt = s(); }
    lastOk = Date.now();
  } else r.write.failedIds.push(id);
  timed("search", () => db.getSiblingDB("sample_mflix").movies.aggregate([{\$search: {index: "default", text: {query: "space", path: {wildcard: "*"}}}}, {\$limit: 1}]).toArray());
  sleep(500);
}
print("RESULT " + JSON.stringify(r));
EOF
}
# mongosh on mesh1's member, logged in, script on stdin, through the replica set.
rs_eval() { { printf 'db.getSiblingDB("admin").auth("labAdmin", "%s");\n' "$admin_pw"; cat; } \
  | kubectl --context kind-mesh1 -n mongodb exec -i mongo-0 -c mongod -- mongosh --quiet "$rs_plain" --file /dev/stdin 2>/dev/null; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
# Seconds from <epoch ms> to the first "Election succeeded" in <cluster>'s mongod log after it, and to the end of the
# new primary's catch-up, when it accepts writes: the member's own time, not the drill's polling, which waits on
# connections to an unreachable member. The VM's clock and this machine's agree to about 0.1 s (measured).
# shellcheck disable=SC2016  # $date is a key of mongod's JSON log, read by python
election_after() { # <cluster> <epoch ms>
  kubectl --context "kind-$1" -n mongodb logs mongo-0 -c mongod --since=10m 2>/dev/null | python3 -c '
import datetime, json, sys
since, elected = int(sys.argv[1]), None
for line in sys.stdin:
    want = "Transition to primary complete" if elected else "Election succeeded"
    if want not in line:
        continue
    ms = datetime.datetime.fromisoformat(json.loads(line)["t"]["$date"]).timestamp() * 1000
    if ms < since:
        continue
    if elected is None:
        elected = (ms - since) / 1000
    else:
        print(f"elected {elected:.1f} s after, writes accepted {(ms - since) / 1000:.1f} s after")
        break' "$2"
}
# The two other members' replication log for 40 s from <epoch ms>, in seconds after it: when each lost the primary,
# started an election and won it. mongod logs nothing of these components while the replica set is steady.
# shellcheck disable=SC2016  # $date is a key of mongod's JSON log, read by python
election_trace() { # <epoch ms>
  local c
  for c in mesh1 mesh2; do
    kubectl --context "kind-$c" -n mongodb logs mongo-0 -c mongod --since=10m 2>/dev/null | python3 -c '
import datetime, json, sys
since, c = int(sys.argv[1]), sys.argv[2]
for line in sys.stdin:
    try:
        d = json.loads(line)
    except ValueError:
        continue
    comp, msg, a = d.get("c"), d.get("msg", ""), d.get("attr", {})
    # The sync source retries repeat every second while the old primary is away and say nothing about the election.
    if comp not in ("ELECTION", "REPL_HB", "REPL") or "select a sync source" in msg or "select sync source" in msg:
        continue
    ms = datetime.datetime.fromisoformat(d["t"]["$date"]).timestamp() * 1000
    if since <= ms <= since + 40000:
        why = a.get("reason") or a.get("error") or a.get("status") or a.get("newState") or ""
        print(f"  {c} +{(ms - since) / 1000:5.1f} s  {comp:8} {msg} {why}"[:170])' "$1" "$c"
  done
}
election_timeout() { printf 'print(rs.conf().settings.electionTimeoutMillis)' | rs_eval; }
mongod_restarts() { kubectl --context kind-mesh0 -n mongodb get pod mongo-0 -o jsonpath='{.status.containerStatuses[?(@.name=="mongod")].restartCount}'; }
primary_member() { printf 'print((db.hello().primary || "none").split(".")[0])' | rs_eval; }

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
  log="$out/drill-mongot-$c-$which${DRILL_TAG:+-$DRILL_TAG}.txt"
  t0=$(date +%s)
  echo "== drill: $c loses $which of its mongot while its mongod searches (120 s); no Envoy, mongot-global straight to mongot" | tee "$log"
  holder=$(serving_pod "$c")
  [ -n "$holder" ] || { note "$c's mongod is not served by its own mongot; run the failback drill first"; return 1; }
  note "$c's mongod is served by its own $holder"
  if [ "$which" = both ]; then pods=$(mongot_pods "$c"); else pods=$holder; fi
  note "searches answered before: $(counts)"
  load "$c" 120 >"$out/drill-mongot-$c-$which${DRILL_TAG:+-$DRILL_TAG}-load.txt" 2>&1 &
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
  tee -a "$log" <"$out/drill-mongot-$c-$which${DRILL_TAG:+-$DRILL_TAG}-load.txt"
}

drill_failback() { # <cluster>
  local c=$1 st
  log="$out/drill-failback-$c${DRILL_TAG:+-$DRILL_TAG}.txt"
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

drill_primary() { # <freeze|kill|partition>: mesh0, the primary's cluster, is lost from 15 s to 75 s
  local mode=$1 before after ok failed all applied nfailed present p node restarts action_ms run
  log="$out/drill-primary-$mode${CLIENT_OPTS:+-$(printf '%s' "$CLIENT_OPTS" | tr '&=' '-_')}${DRILL_TAG:+-$DRILL_TAG}.txt"
  t0=$(date +%s)
  echo "== drill: the primary's cluster mesh0 lost by $mode, mesh1 writes and searches (150 s)${CLIENT_OPTS:+; client options $CLIENT_OPTS}" | tee "$log"
  [ "$(primary_member)" = mongo-mesh0 ] || { note "mesh0 is not primary ($(primary_member)); wait for it to take the primary back"; return 1; }
  before=$(printf 'print(db.getSiblingDB("lab").drill.countDocuments({}))' | rs_eval)
  note "primary mongo-mesh0; lab.drill holds $before documents; electionTimeoutMillis $(election_timeout)"
  run="drill-$(date +%s)"
  load_rw mesh1 150 "$run" >"$out/drill-primary-load.tmp" 2>&1 &
  at 15
  action_ms=$(now_ms)
  case "$mode" in
    freeze) note "docker pause mesh0's two nodes"; docker pause mesh0-control-plane mesh0-worker >/dev/null ;;
    # SIGKILL on the node: a force-deleted pod still gets SIGTERM, and mongod then steps down and hands the primary
    # over in about a second (measured, drill-primary-forcedelete.txt), which is not a crash.
    kill) node=$(kubectl --context kind-mesh0 -n mongodb get pod mongo-0 -o jsonpath='{.spec.nodeName}')
      restarts=$(mongod_restarts)
      note "SIGKILL mesh0's mongod on $node: no shutdown, no step-down"; docker exec "$node" pkill -KILL -x mongod ;;
    partition) note "cut mesh0's mongod off from the other clusters (Cilium deny policy)"; kubectl --context kind-mesh0 apply -f "$here/manifests/50-partition-mesh0.yaml" >/dev/null ;;
  esac
  for _ in $(seq 1 40); do p=$(primary_member); [ -n "$p" ] && [ "$p" != none ] && [ "$p" != mongo-mesh0 ] && break; sleep 1; done
  at 56   # the new primary's catch-up and the trace's 40 s are over: both read from the logs
  note "primary now: ${p:-none} ($(election_after "${p#mongo-}" "$action_ms") the $mode, by its log)"
  election_trace "$action_ms" | tee -a "$log"
  at 75
  case "$mode" in
    freeze) note "docker unpause mesh0's two nodes"; docker unpause mesh0-control-plane mesh0-worker >/dev/null ;;
    kill) note "nothing to undo: the kubelet restarted mongod ($(( $(mongod_restarts) - restarts )) restart in this run)" ;;
    partition) note "remove the deny policy"; kubectl --context kind-mesh0 delete -f "$here/manifests/50-partition-mesh0.yaml" >/dev/null ;;
  esac
  wait
  for _ in $(seq 1 60); do [ "$(primary_member)" = mongo-mesh0 ] && break; sleep 2; done
  note "primary after: $(primary_member)"
  cat "$out/drill-primary-load.tmp" >>"$log"; rm -f "$out/drill-primary-load.tmp"
  after=$(printf 'print(db.getSiblingDB("lab").drill.countDocuments({}))' | rs_eval)
  # Every acknowledged write, by its id: the run's documents less the failed writes found anyway. _id is unique, so
  # none can be there twice.
  read -r ok failed <<<"$(sed -n 's/^RESULT //p' "$log" | python3 -c 'import json, sys; w = json.load(sys.stdin)["write"]; print(w["ok"], json.dumps(w["failedIds"], separators=(",", ":")))')"
  # shellcheck disable=SC2016  # $regex and $in are mongosh's
  read -r all applied nfailed <<<"$(printf 'const c = db.getSiblingDB("lab").drill, f = %s; print(c.countDocuments({_id: {$regex: "^%s-"}}) + " " + c.countDocuments({_id: {$in: f}}) + " " + f.length)' "$failed" "$run" | rs_eval)"
  present=$((all - applied))
  note "acknowledged writes: $ok, found by id: $present ($before -> $after documents): $([ "$present" = "$ok" ] && echo 'every acknowledged write is there, once' || echo "MISSING $((ok - present))"); failed writes applied anyway: $applied of $nfailed"
  grep -E 'failed at|RESULT' "$log" | tail -6 | cut -c1-160
}

drill_spread() { # <cluster> <seconds>: how a cluster's searches are spread over its mongot pods
  local c=$1 secs=$2 p
  local before=() i=0 pods
  log="$out/drill-spread-$c${DRILL_TAG:+-$DRILL_TAG}.txt"
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
  primary) drill_primary "${2:-freeze}" ;;
  load-only) log=/dev/null; load "${2:-mesh2}" "${3:-60}" ;;   # a search load alone, for scripts/cleartext-l7.sh
  *) echo "usage: $0 mongot [cluster] [one|both] | failback [cluster] | spread [cluster] [seconds] | primary freeze|kill|partition | load-only [cluster] [seconds]" >&2; exit 2 ;;
esac
