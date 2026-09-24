#!/usr/bin/env bash
# Run a search and report WHICH mongot pod answered it.
#
#   ./app/trace-query.sh "CrashLoopBackOff"         one text search, traced
#   ./app/trace-query.sh -n 12 "pods"               twelve searches + a pod census
#   ./app/trace-query.sh -m vector -d performance   a vector search by failure domain
#   ./app/trace-query.sh -n 12 -q "pods"            census only, no per-query detail
#
# Attribution comes from Envoy's access log - one line per gRPC request, carrying
# upstream_host - NOT from mongot's Prometheus counters. Those are scraped and lag
# the response, so a single query is often still invisible in them when it returns
# (observed: 2 of 5 single queries undetectable by counter delta). The access log
# is written per request and names the pod exactly.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./mongodb/.env 2>/dev/null || true; set +a
: "${NS:=mongodb-poc}" "${DB:=platform_ops}" "${COLL:=incidents}" "${FLUSH_WAIT:=15}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.crc/machines/crc/kubeconfig}"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-bgp-fabric}"
URI="mongodb://${ROOT_USER:-labAdmin}:${ROOT_PASSWORD:-x}@localhost:${PORT1:-27017}/admin?directConnection=true"

MODE=text N=1 DOMAIN=performance QUIET=
while getopts "m:n:d:qh" o; do case $o in
  m) MODE=$OPTARG;; n) N=$OPTARG;; d) DOMAIN=$OPTARG;; q) QUIET=1;;
  h) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) exit 2;;
esac; done
shift $((OPTIND-1))
Q="${*:-pods}"

# Hand-set probe vectors, one per failure domain: [sched, net, storage, tls, auth, perf]
case "$DOMAIN" in
  scheduling)  VEC="0.95,0.1,0.1,0,0.05,0.2" ;;
  network)     VEC="0.1,0.96,0,0.15,0.05,0.2" ;;
  storage)     VEC="0.3,0,0.95,0,0,0.05"      ;;
  tls)         VEC="0,0.2,0,0.97,0.05,0.02"   ;;
  auth)        VEC="0.1,0.05,0,0.2,0.95,0"    ;;
  performance) VEC="0.4,0.4,0,0,0,0.95"       ;;
  *) echo "unknown domain '$DOMAIN' (scheduling|network|storage|tls|auth|performance)" >&2; exit 2;;
esac

C_D=$'\033[2m'; C_B=$'\033[1m'; C_G=$'\033[32m'; C_R=$'\033[31m'; C_0=$'\033[0m'
[ -t 1 ] || { C_D= C_B= C_G= C_R= C_0=; }

# upstream_host is an IP; render it as the pod name.
PODMAP=$(oc get pods -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{"\n"}{end}' 2>/dev/null \
  | awk '/^mongot-search-0-/ && $2 {printf "%s=%s;", $2, $1}')
NPODS=$(printf '%s' "$PODMAP" | tr ';' '\n' | grep -c . )
[ "${NPODS:-0}" -eq 0 ] && { echo "no mongot pods found in namespace $NS" >&2; exit 1; }

query() {
  local pipeline
  if [ "$MODE" = vector ]; then
    pipeline="{\$vectorSearch:{index:'incidents_vector',path:'embedding',queryVector:[$VEC],numCandidates:50,limit:3}},
              {\$project:{_id:0,incident_id:1,title:1,component:1,score:{\$meta:'vectorSearchScore'}}}"
  else
    pipeline="{\$search:{index:'incidents_text',text:{query:'$Q',path:{wildcard:'*'}}}},{\$limit:3},
              {\$project:{_id:0,incident_id:1,title:1,component:1,score:{\$meta:'searchScore'}}}"
  fi
  docker exec -i mongo1 mongosh "$URI" --quiet --eval "
    db.getSiblingDB('$DB').$COLL.aggregate([$pipeline]).toArray()
      .forEach(d=>print('    '+d.incident_id+'  '+d.title+'  ['+d.component+']  '+d.score.toFixed(3)))" 2>/dev/null
}

# One pass over the new access lines -> "pod<TAB>ip<TAB>grpc_status<TAB>duration_ms".
parse() {
  PODMAP="$PODMAP" python3 -c "
import sys, json, os
pods = dict(p.split('=',1) for p in os.environ['PODMAP'].split(';') if p)
for line in sys.stdin:
    if '\"upstream_host\"' not in line: continue
    try: d = json.loads(line.strip())
    except ValueError: continue
    ip = d.get('upstream_host','').split(':')[0]
    print('\t'.join([pods.get(ip, ip), ip, str(d.get('grpc_status','?')), str(d.get('duration_ms','?'))]))"
}
since_lines() { oc logs -n "$NS" -l app=mongot-search-lb-0 --since-time="$1" --tail=-1 2>/dev/null | grep '"upstream_host"'; }

if [ "$MODE" = vector ]; then
  echo "${C_B}vector search${C_0} ${C_D}domain=$DOMAIN  index=incidents_vector${C_0}"
else
  echo "${C_B}text search${C_0} ${C_D}\"$Q\"  index=incidents_text${C_0}"
fi
echo "${C_D}entry ${MONGOT_ENDPOINT:-<mongotHost>}  ->  Envoy  ->  $NPODS mongot pods${C_0}"
echo

CENSUS=$(mktemp); trap 'rm -f "$CENSUS"' EXIT
for i in $(seq 1 "$N"); do
  T0=$(date -u -v-2S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '2 seconds ago' '+%Y-%m-%dT%H:%M:%SZ')
  BEFORE=$(since_lines "$T0" | wc -l | tr -d ' ')
  OUT=$(query)
  # Envoy buffers access logs and flushes on --file-flush-interval-msec, which the
  # operator leaves at Envoy's 10s default (measured: a line lands ~9s after the
  # query returns). Poll against a wall-clock deadline, not an iteration count.
  NEW=""; DEADLINE=$(( $(date +%s) + FLUSH_WAIT ))
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    CUR=$(since_lines "$T0")
    [ "$(printf '%s' "$CUR" | grep -c . )" -gt "$BEFORE" ] && { NEW=$(printf '%s\n' "$CUR" | tail -n +$((BEFORE+1))); break; }
  done

  [ -z "$QUIET" ] && { echo "${C_B}query $i${C_0}"; printf '%s\n' "${OUT:-    (no results)}"; }
  if [ -z "$NEW" ]; then
    [ -z "$QUIET" ] && echo "    ${C_D}served by: access log not flushed in time${C_0}"
  else
    ROWS=$(printf '%s\n' "$NEW" | parse)
    printf '%s\n' "$ROWS" | cut -f1 >> "$CENSUS"
    if [ -z "$QUIET" ]; then
      while IFS=$'\t' read -r pod ip st ms; do
        [ -z "$pod" ] && continue
        [ "$st" = OK ] && M="${C_G}OK${C_0}" || M="${C_R}${st}${C_0}"
        echo "    served by: ${C_B}${pod}${C_0} ${C_D}($ip)${C_0}  $M  ${ms}ms"
      done <<< "$ROWS"
      NR=$(printf '%s\n' "$ROWS" | grep -c .)
      [ "$NR" -gt 1 ] && echo "    ${C_D}$NR gRPC requests for this one aggregation${C_0}"
    fi
  fi
  [ -z "$QUIET" ] && echo
done

TOTAL=$(grep -c . "$CENSUS" 2>/dev/null); TOTAL=${TOTAL:-0}
if [ "$TOTAL" -gt 0 ]; then
  echo "${C_D}──────────────────────────────────────────────${C_0}"
  echo "${C_B}who answered${C_0} ${C_D}($TOTAL gRPC requests over $N quer$([ "$N" = 1 ] && echo y || echo ies))${C_0}"
  sort "$CENSUS" | uniq -c | sort -k2 | while read -r c p; do
    pct=$(( c * 100 / TOTAL )); bar=$(printf '%*s' $(( pct / 3 )) '' | tr ' ' '#')
    printf "  %-20s %4d  %3d%%  %s\n" "$p" "$c" "$pct" "$bar"
  done
  SEEN=$(sort -u "$CENSUS" | grep -c .)
  [ "$SEEN" -lt "$NPODS" ] && echo "  ${C_R}only $SEEN of $NPODS pods answered${C_0}" \
                           || echo "  ${C_D}all $NPODS pods answered${C_0}"
fi
