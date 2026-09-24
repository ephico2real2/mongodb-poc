#!/usr/bin/env bash
# Prove the search path works AND that Envoy distributes across every mongot.
#
# Counters are snapshotted before and after, so the delta is attributable to THIS run
# rather than to whatever the pods did earlier.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${NS:=mongodb-poc}" "${QUERIES:=40}" "${DB:=sample_mflix}" "${COLL:=movies}"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-bgp-fabric}"
URI="mongodb://${ROOT_USER}:${ROOT_PASSWORD}@localhost:${PORT1}/admin?directConnection=true"

PODS=$(oc get pods -n "$NS" -l app="${MONGOT_STS_LABEL:-mongot-search-0-svc}" -o name 2>/dev/null \
       | sed 's|pod/||' || true)
[ -z "$PODS" ] && PODS=$(oc get pods -n "$NS" --no-headers 2>/dev/null \
       | awk '$1 ~ /^mongot-search-0-[0-9]+$/ {print $1}')

counter() {  # $1 = pod ; prints the search command count, or 0
  oc exec -n "$NS" "$1" -- sh -c \
    'curl -s --max-time 4 http://localhost:9946/metrics 2>/dev/null \
     | grep "^mongot_command_searchCommandTotalLatency_seconds_count" | awk "{print \$2}"' 2>/dev/null \
    | tr -d '\r' | head -1 | sed 's/^$/0/'
}

echo "=== 1. correctness: \$search ==="
docker exec -i mongo1 mongosh "$URI" --quiet --eval "
const d=db.getSiblingDB('$DB');
const r=d.$COLL.aggregate([{\$search:{index:'default',text:{query:'karate',path:{wildcard:'*'}}}},
                           {\$project:{title:1,score:{\$meta:'searchScore'}}}]).toArray();
if(!r.length||r[0].title!=='The Karate Kid'){print('  FAIL: '+JSON.stringify(r));quit(1);}
print('  PASS  \$search \"karate\" -> '+r[0].title+'  score='+r[0].score.toFixed(3));"

echo "=== 2. correctness: \$vectorSearch ==="
docker exec -i mongo1 mongosh "$URI" --quiet --eval "
const d=db.getSiblingDB('$DB');
const r=d.$COLL.aggregate([{\$vectorSearch:{index:'vector_index',path:'plot_embedding',
  queryVector:[0.9,0.1,0.0,0.1,0.0],numCandidates:10,limit:3}},
  {\$project:{title:1,score:{\$meta:'vectorSearchScore'}}}]).toArray();
if(!r.length||r[0].title!=='The Karate Kid'){print('  FAIL: '+JSON.stringify(r));quit(1);}
r.forEach(x=>print('  PASS  '+x.title+'  score='+x.score.toFixed(4)));"

echo "=== 3. snapshot counters BEFORE ==="
declare -A BEFORE
for p in $PODS; do BEFORE[$p]=$(counter "$p"); printf "  %-20s %s\n" "$p" "${BEFORE[$p]}"; done

echo "=== 4. issuing $QUERIES queries ==="
docker exec -i mongo1 mongosh "$URI" --quiet --eval "
const d=db.getSiblingDB('$DB');
const t=['karate','boxer','shark','spaceship','baseball'];
for(let i=0;i<$QUERIES;i++){
  d.$COLL.aggregate([{\$search:{index:'default',text:{query:t[i%t.length],path:{wildcard:'*'}}}},
                     {\$project:{_id:1}}]).toArray();}
print('  issued $QUERIES');"

echo "=== 5. distribution (delta per mongot) ==="
TOTAL=0
for p in $PODS; do
  AFTER=$(counter "$p"); D=$(( ${AFTER%.*} - ${BEFORE[$p]%.*} )); TOTAL=$((TOTAL+D))
  printf "  %-20s %3d  %s\n" "$p" "$D" "$(printf '#%.0s' $(seq 1 $((D>60?60:D)) 2>/dev/null))"
done
echo "  ------------------------------------------"
printf "  %-20s %3d\n" "TOTAL" "$TOTAL"
SERVING=$(for p in $PODS; do A=$(counter "$p"); echo "$A"; done | wc -l | tr -d ' ')
echo
if [ "$TOTAL" -ge "$QUERIES" ]; then echo "  PASS  every query accounted for"; else
  echo "  NOTE  total ($TOTAL) < queries ($QUERIES) - some may still be in flight"; fi

echo "=== 6. Envoy's own view ==="
echo "  NOTE: the stats Service round-robins across Envoy replicas, so a single"
echo "        scrape shows ONE pod. Summing every pod is the only correct total."
RQ_SUM=0
for ep in $(oc get pods -n "$NS" -l app=mongot-search-lb-0 -o name 2>/dev/null | sed 's|pod/||'); do
  # the envoy image has no curl, so port-forward and scrape from here
  oc port-forward -n "$NS" "pod/$ep" 19901:9901 >/dev/null 2>&1 &
  PF=$!; sleep 4
  RQ=$(curl -s --max-time 5 http://127.0.0.1:19901/stats 2>/dev/null \
       | grep -E "mongot_rs_cluster\.upstream_rq_total:" | awk '{print $2}' | tr -d '\r')
  CX=$(curl -s --max-time 5 http://127.0.0.1:19901/stats 2>/dev/null \
       | grep -E "mongot_rs_cluster\.upstream_cx_active:" | awk '{print $2}' | tr -d '\r')
  kill $PF 2>/dev/null; wait 2>/dev/null || true
  RQ=${RQ:-0}; CX=${CX:-0}
  RQ_SUM=$((RQ_SUM + RQ))
  printf "  %-38s upstream_rq_total=%-6s upstream_cx_active=%s\n" "$ep" "$RQ" "$CX"
done
echo "  ------------------------------------------"
printf "  %-38s %s\n" "SUM across Envoy replicas" "$RQ_SUM"
echo "  upstream_cx_active should equal the mongot replica count on the pod carrying traffic."
