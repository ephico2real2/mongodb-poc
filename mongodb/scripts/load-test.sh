#!/usr/bin/env bash
# Concurrent load test for the whole search path, with latency percentiles and
# per-mongot distribution.
#
#   ./scripts/load-test.sh -c 8 -n 200          8 workers x 200 queries
#   ./scripts/load-test.sh -c 8 -n 200 -m vector
#
# Each worker is ONE mongosh process running a loop, so mongosh startup (~1s) is paid
# once per worker rather than per query and does not pollute the latency figures. It
# IS inside the wall clock, so the throughput figure is a floor, not a steady-state rate.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${NS:=mongodb-poc}" "${DB:=sample_mflix}" "${COLL:=movies}" "${REPLICAS:=3}"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-bgp-fabric}"
CONC=4 NUM=100 MODE=text
while getopts "c:n:m:" o; do case $o in c) CONC=$OPTARG;; n) NUM=$OPTARG;; m) MODE=$OPTARG;; esac; done
EXPECTED=$((CONC*NUM))
URI="mongodb://${ROOT_USER}:${ROOT_PASSWORD}@localhost:${PORT1}/admin?directConnection=true"
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT

# mongot counts $search and $vectorSearch under SEPARATE Prometheus counters. Reading the
# $search counter during a vector run reports 0/0/0, which this repo's own rubric reads as
# "one pod serving everything". Pick the counter that matches the mode.
if [ "$MODE" = "vector" ]; then
  METRIC=mongot_command_vectorSearchCommandTotalLatency_seconds_count
else
  METRIC=mongot_command_searchCommandTotalLatency_seconds_count
fi

TB=$(oc get pods -n "$NS" -l app=mongot-toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
counters() {
  [ -z "$TB" ] && return
  oc exec -n "$NS" "$TB" -- sh -c "
    for i in \$(seq 0 \$(( $REPLICAS - 1 ))); do
      v=\$(curl -s --max-time 4 http://mongot-search-0-\$i.mongot-search-0-svc:9946/metrics 2>/dev/null \
          | grep '^$METRIC' | awk '{print \$2}')
      echo \"mongot-search-0-\$i \${v:-0}\"
    done" 2>/dev/null
}
# Sum a stat across EVERY Envoy replica. Scraping the mongot-envoy-stats Service
# round-robins, so a single scrape can land on the idle replica and read zero.
envoy_stat_sum() {
  [ -z "$TB" ] && { echo 0; return; }
  local total=0 v
  for ip in $(oc get pods -n "$NS" -l app=mongot-search-lb-0 \
                -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null); do
    v=$(oc exec -n "$NS" "$TB" -- sh -c \
      "curl -s --max-time 5 http://$ip:9901/stats 2>/dev/null | grep -E '$1' | awk '{print \$2}'" \
      2>/dev/null | head -1)
    total=$(( total + ${v:-0} ))
  done
  echo "$total"
}

echo "=== load test: ${CONC} workers x ${NUM} ${MODE} queries = ${EXPECTED} total ==="
echo "    corpus: $(docker exec -i mongo1 mongosh "$URI" --quiet --eval \
      "print(db.getSiblingDB('$DB').$COLL.countDocuments({}))" | tr -d '[:space:]') documents"
BEFORE=$(counters)
RETRY_B=$(envoy_stat_sum 'mongot_rs_cluster\.upstream_rq_retry:')

if [ "$MODE" = "vector" ]; then
  Q='{$vectorSearch:{index:"vector_index",path:"plot_embedding",queryVector:V,numCandidates:200,limit:10}}'
  PRE='const V=[[0.9,0.1,0,0.05,0],[0,0,0.9,0,0],[0,0,0,0.92,0],[0,0.9,0,0,0],[0,0,0,0,0.92]][i%5];'
else
  Q='{$search:{index:"default",text:{query:T,path:{wildcard:"*"}}}}'
  PRE='const T=["detective","creature","astronaut","boxer","pennant","corruption"][i%6];'
fi

START=$(date +%s.%N)
for w in $(seq 1 "$CONC"); do
  # stderr is kept: a worker that dies at startup writes nothing to stdout, and without
  # this its 100 missing queries would be invisible in the "errors: 0" line.
  ( docker exec -i mongo1 mongosh "$URI" --quiet --eval "
      const d=db.getSiblingDB('$DB');
      for (let i=0;i<$NUM;i++){
        $PRE
        const t=Date.now();
        try { d.$COLL.aggregate([$Q,{\$project:{_id:1}}]).toArray(); print(Date.now()-t); }
        catch(e) { print('ERR'); }
      }" > "$OUT/w$w.txt" 2> "$OUT/w$w.err" ) &
done
wait
END=$(date +%s.%N)

AFTER=$(counters)
RETRY_A=$(envoy_stat_sum 'mongot_rs_cluster\.upstream_rq_retry:')

python3 - "$OUT" "$START" "$END" "$EXPECTED" <<'PY'
import sys, glob, os, statistics as st
d, start, end, expected = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
lat, err = [], 0
for f in glob.glob(d + "/w*.txt"):
    for line in open(f):
        line = line.strip()
        if line == "ERR": err += 1
        elif line.isdigit(): lat.append(int(line))
lat.sort(); wall = end - start
missing = expected - len(lat) - err
if not lat:
    print("  NO SAMPLES - every worker failed to start; see the .err files")
    raise SystemExit(1)
def p(q): return lat[min(len(lat)-1, int(len(lat)*q))]
print(f"\n  queries ok : {len(lat):,}   errors: {err}   missing: {missing}  (of {expected:,} requested)")
if missing:
    print("  WARNING: workers produced fewer results than requested - a worker died"
          " before or during the run. First stderr lines:")
    for f in sorted(glob.glob(d + "/w*.err")):
        head = open(f).read().strip().splitlines()[:2]
        if head: print(f"    {os.path.basename(f)}: {head[0][:160]}")
print(f"  wall clock : {wall:.1f}s      throughput: {len(lat)/wall:,.0f} q/s"
      f"   (includes one mongosh startup per worker - a floor, not a steady-state rate)")
busy = sum(lat) / 1000.0 / max(1, len(glob.glob(d + "/w*.txt")))   # per-worker seconds spent in queries
print(f"  busy rate  : {len(lat)/busy:,.0f} q/s   (queries / per-worker query time - startup excluded)")
print(f"  latency ms : min {lat[0]}  p50 {p(.50)}  p90 {p(.90)}  p99 {p(.99)}  max {lat[-1]}")
print(f"               mean {st.mean(lat):.1f}  stdev {st.pstdev(lat):.1f}")
PY

echo
echo "  distribution across mongot ($MODE queries, metric: $METRIC):"
TOT=0
while read -r pod a; do
  b=$(echo "$BEFORE" | awk -v p="$pod" '$1==p{print $2}')
  n=$(( ${a%.*} - ${b%.*} )); TOT=$((TOT+n))
  bar=""; k=$(( n/25 )); [ "$k" -gt 0 ] && bar=$(printf '#%.0s' $(seq 1 $((k>50?50:k))))
  printf "    %-20s %5d  %s\n" "$pod" "$n" "$bar"
done <<< "$AFTER"
printf "    %-20s %5d  (requested %d)\n" "TOTAL" "$TOT" "$EXPECTED"
echo "  envoy retries during run: $(( RETRY_A - RETRY_B ))"
