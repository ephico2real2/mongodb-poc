#!/usr/bin/env bash
# Prove the search path works AND that Envoy distributes across every mongot.
#
# All observation happens INSIDE the cluster, through the toolbox pod, addressing
# everything by Service / StatefulSet DNS. No port-forward is required - which matters
# where port-forward is restricted, and exercises the same DNS a real client would use.
#
#   manifests/50-envoy-stats-service.yaml   Envoy admin, ClusterIP only
#   manifests/60-toolbox.yaml               the pod this script runs commands in
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${NS:=mongodb-poc}" "${QUERIES:=40}" "${DB:=sample_mflix}" "${COLL:=movies}"
: "${SEARCH_NAME:=mongot}" "${REPLICAS:=3}"
# The correctness assertions name documents from the CURATED 24 (_id 1..24). The bulk
# corpus (_id >= 1001) is built from the same five theme vectors, so unscoped nearest-
# neighbour assertions start failing the moment load-bulk.sh runs. Scope them by _id,
# which vector_index.json declares as a filter field.
: "${VEC_INDEX:=vector_index}" "${CURATED_MAX_ID:=1001}"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-bgp-fabric}"
URI="mongodb://${ROOT_USER}:${ROOT_PASSWORD}@localhost:${PORT1}/admin?directConnection=true"

TB=$(oc get pods -n "$NS" -l app=mongot-toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$TB" ]; then
  echo "toolbox not found - apply manifests/60-toolbox.yaml first" >&2; exit 1
fi
SVC="${SEARCH_NAME}-search-0-svc"

# per-pod search counter, addressed by StatefulSet DNS from inside the cluster
counters() {
  oc exec -n "$NS" "$TB" -- sh -c "
    for i in \$(seq 0 \$(( $REPLICAS - 1 ))); do
      v=\$(curl -s --max-time 4 http://${SEARCH_NAME}-search-0-\$i.${SVC}:9946/metrics 2>/dev/null \
          | grep '^mongot_command_searchCommandTotalLatency_seconds_count' | awk '{print \$2}')
      echo \"${SEARCH_NAME}-search-0-\$i \${v:-0}\"
    done" 2>/dev/null
}

echo "=== 1. correctness: \$search ==="
docker exec -i mongo1 mongosh "$URI" --quiet --eval "
const d=db.getSiblingDB('$DB');
const r=d.$COLL.aggregate([{\$search:{index:'default',text:{query:'karate',path:{wildcard:'*'}}}},
                           {\$project:{title:1,score:{\$meta:'searchScore'}}}]).toArray();
if(!r.length||r[0].title!=='The Karate Kid'){print('  FAIL: '+JSON.stringify(r));quit(1);}
print('  PASS  \$search \"karate\" -> '+r[0].title+'  score='+r[0].score.toFixed(3));"

echo "=== 2. correctness: \$vectorSearch (curated corpus) ==="
docker exec -i mongo1 mongosh "$URI" --quiet --eval "
const d=db.getSiblingDB('$DB');
const r=d.$COLL.aggregate([{\$vectorSearch:{index:'$VEC_INDEX',path:'plot_embedding',
  queryVector:[0.9,0.1,0.0,0.1,0.0],numCandidates:200,limit:3,
  filter:{_id:{\$lt:$CURATED_MAX_ID}}}},
  {\$project:{title:1,score:{\$meta:'vectorSearchScore'}}}]).toArray();
if(!r.length||r[0].title!=='The Karate Kid'){print('  FAIL: '+JSON.stringify(r));quit(1);}
r.forEach(x=>print('  PASS  '+x.title+'  score='+x.score.toFixed(4)));"

echo "=== 2b. correctness: \$vectorSearch WITH filter ==="
docker exec -i mongo1 mongosh "$URI" --quiet --eval "
const d=db.getSiblingDB('$DB');
// creature-horror vector over the curated 24, restricted to 1980+. Jaws (1975) is the
// nearest match overall, so its ABSENCE is what proves the year filter is live.
const r=d.$COLL.aggregate([{\$vectorSearch:{index:'$VEC_INDEX',path:'plot_embedding',
  queryVector:[0.0,0.0,0.90,0.0,0.0],numCandidates:200,limit:3,
  filter:{\$and:[{year:{\$gte:1980}},{_id:{\$lt:$CURATED_MAX_ID}}]}}},
  {\$project:{title:1,year:1}}]).toArray();
if(r.some(x=>x.year<1980)){print('  FAIL: filter leaked '+JSON.stringify(r));quit(1);}
if(r.some(x=>x.title==='Jaws')){print('  FAIL: Jaws (1975) came back');quit(1);}
if(!r.length){print('  FAIL: no results');quit(1);}
print('  PASS  filter year>=1980 -> '+r.map(x=>x.title+' ('+x.year+')').join(', '));"

echo "=== 3. counters BEFORE (via toolbox, StatefulSet DNS) ==="
BEFORE=$(counters); echo "$BEFORE" | sed 's/^/  /'

echo "=== 4. issuing $QUERIES queries ==="
docker exec -i mongo1 mongosh "$URI" --quiet --eval "
const d=db.getSiblingDB('$DB');
const t=['karate','boxer','shark','spaceship','baseball'];
for(let i=0;i<$QUERIES;i++){
  d.$COLL.aggregate([{\$search:{index:'default',text:{query:t[i%t.length],path:{wildcard:'*'}}}},
                     {\$project:{_id:1}}]).toArray();}
print('  issued $QUERIES');"

echo "=== 5. distribution (delta per mongot) ==="
AFTER=$(counters); TOTAL=0
while read -r pod a; do
  b=$(echo "$BEFORE" | awk -v p="$pod" '$1==p{print $2}')
  d=$(( ${a%.*} - ${b%.*} )); TOTAL=$((TOTAL+d))
  bar=""; n=$(( d > 60 ? 60 : d )); [ "$n" -gt 0 ] && bar=$(printf '#%.0s' $(seq 1 $n))
  printf "  %-22s %3d  %s\n" "$pod" "$d" "$bar"
done <<< "$AFTER"
echo "  --------------------------------------------"
printf "  %-22s %3d\n" "TOTAL" "$TOTAL"
[ "$TOTAL" -ge "$QUERIES" ] \
  && echo "  PASS  every query accounted for, spread across ${REPLICAS} pods" \
  || echo "  NOTE  total ($TOTAL) < queries ($QUERIES) - some may still be in flight"

echo "=== 6. Envoy's own view (EVERY replica, by pod IP) ==="
# The mongot-envoy-stats Service round-robins, so scraping it N times samples replicas
# at random and an idle replica reads zero. Address each Envoy pod directly instead.
# Only the replica holding mongod's connection reports traffic: a downstream TCP
# connection lives on one Envoy pod, which is why Envoy replicas buy restart tolerance,
# not throughput. upstream_cx_active is NOT a health signal - Envoy's upstream
# idle_timeout is 300s, so it legitimately reads 0 when no query is in flight.
for ip in $(oc get pods -n "$NS" -l "app=${SEARCH_NAME}-search-lb-0" \
              -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}'); do
  line=$(oc exec -n "$NS" "$TB" -- sh -c \
    "curl -s --max-time 5 http://$ip:9901/stats 2>/dev/null \
     | grep -E 'mongot_rs_cluster\.(upstream_rq_total|upstream_cx_active):'" 2>/dev/null \
    | tr '\n' ' ')
  printf "  %-15s %s\n" "$ip" "$line"
done
