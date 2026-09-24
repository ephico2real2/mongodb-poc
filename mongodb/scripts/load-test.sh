#!/usr/bin/env bash
# Concurrent load test for the whole search path, with latency percentiles and
# per-mongot distribution.
#
#   ./scripts/load-test.sh -c 8 -n 200          8 workers x 200 queries
#   ./scripts/load-test.sh -c 8 -n 200 -m vector
#
# Each worker is ONE mongosh process running a loop, so mongosh startup (~1s) is paid
# once per worker rather than per query and does not pollute the latency figures.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${NS:=mongodb-poc}" "${DB:=sample_mflix}" "${COLL:=movies}" "${REPLICAS:=3}"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-bgp-fabric}"
CONC=4 NUM=100 MODE=text
while getopts "c:n:m:" o; do case $o in c) CONC=$OPTARG;; n) NUM=$OPTARG;; m) MODE=$OPTARG;; esac; done
URI="mongodb://${ROOT_USER}:${ROOT_PASSWORD}@localhost:${PORT1}/admin?directConnection=true"
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT

TB=$(oc get pods -n "$NS" -l app=mongot-toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
counters() {
  [ -z "$TB" ] && return
  oc exec -n "$NS" "$TB" -- sh -c "
    for i in \$(seq 0 \$(( $REPLICAS - 1 ))); do
      v=\$(curl -s --max-time 4 http://mongot-search-0-\$i.mongot-search-0-svc:9946/metrics 2>/dev/null \
          | grep '^mongot_command_searchCommandTotalLatency_seconds_count' | awk '{print \$2}')
      echo \"mongot-search-0-\$i \${v:-0}\"
    done" 2>/dev/null
}
envoy_stat() {
  [ -z "$TB" ] && return
  oc exec -n "$NS" "$TB" -- sh -c \
    "curl -s --max-time 5 http://mongot-envoy-stats:9901/stats 2>/dev/null | grep -E '$1'" 2>/dev/null
}

echo "=== load test: ${CONC} workers x ${NUM} ${MODE} queries = $((CONC*NUM)) total ==="
echo "    corpus: $(docker exec -i mongo1 mongosh "$URI" --quiet --eval \
      "print(db.getSiblingDB('$DB').$COLL.countDocuments({}))" | tr -d '[:space:]') documents"
BEFORE=$(counters)
RETRY_B=$(envoy_stat 'mongot_rs_cluster\.upstream_rq_retry:' | awk '{print $2}')

if [ "$MODE" = "vector" ]; then
  Q='{$vectorSearch:{index:"vector_index",path:"plot_embedding",queryVector:V,numCandidates:200,limit:10}}'
  PRE='const V=[[0.9,0.1,0,0.05,0],[0,0,0.9,0,0],[0,0,0,0.92,0],[0,0.9,0,0,0],[0,0,0,0,0.92]][i%5];'
else
  Q='{$search:{index:"default",text:{query:T,path:{wildcard:"*"}}}}'
  PRE='const T=["detective","creature","astronaut","boxer","pennant","corruption"][i%6];'
fi

START=$(date +%s.%N)
for w in $(seq 1 "$CONC"); do
  ( docker exec -i mongo1 mongosh "$URI" --quiet --eval "
      const d=db.getSiblingDB('$DB');
      for (let i=0;i<$NUM;i++){
        $PRE
        const t=Date.now();
        try { d.$COLL.aggregate([$Q,{\$project:{_id:1}}]).toArray(); print(Date.now()-t); }
        catch(e) { print('ERR'); }
      }" 2>/dev/null > "$OUT/w$w.txt" ) &
done
wait
END=$(date +%s.%N)

AFTER=$(counters)
RETRY_A=$(envoy_stat 'mongot_rs_cluster\.upstream_rq_retry:' | awk '{print $2}')

python3 - "$OUT" "$START" "$END" <<'PY'
import sys, glob, statistics as st
d, start, end = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
lat, err = [], 0
for f in glob.glob(d + "/w*.txt"):
    for line in open(f):
        line = line.strip()
        if line == "ERR": err += 1
        elif line.isdigit(): lat.append(int(line))
lat.sort(); wall = end - start
if not lat: print("  NO SAMPLES"); raise SystemExit
def p(q): return lat[min(len(lat)-1, int(len(lat)*q))]
print(f"\n  queries ok : {len(lat):,}   errors: {err}")
print(f"  wall clock : {wall:.1f}s      throughput: {len(lat)/wall:,.0f} q/s")
print(f"  latency ms : min {lat[0]}  p50 {p(.50)}  p90 {p(.90)}  p99 {p(.99)}  max {lat[-1]}")
print(f"               mean {st.mean(lat):.1f}  stdev {st.pstdev(lat):.1f}")
PY

echo
echo "  distribution across mongot:"
TOT=0
while read -r pod a; do
  b=$(echo "$BEFORE" | awk -v p="$pod" '$1==p{print $2}')
  n=$(( ${a%.*} - ${b%.*} )); TOT=$((TOT+n))
  bar=""; k=$(( n/25 )); [ "$k" -gt 0 ] && bar=$(printf '#%.0s' $(seq 1 $((k>50?50:k))))
  printf "    %-20s %5d  %s\n" "$pod" "$n" "$bar"
done <<< "$AFTER"
printf "    %-20s %5d\n" "TOTAL" "$TOT"
echo "  envoy retries during run: $(( ${RETRY_A:-0} - ${RETRY_B:-0} ))"
envoy_stat 'mongot_rs_cluster\.(upstream_rq_timeout|upstream_cx_active|upstream_rq_pending_overflow):' | sed 's/^/    /'
