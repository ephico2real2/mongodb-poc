#!/usr/bin/env bash
# Election tuning, after story #131: the three primary drills (freeze, kill, partition) under several replica set
# settings, each profile in records of its own (DRILL_TAG=<profile>), with the writing client on the setting #131
# recommends. The replica set goes back to the defaults at the end, also when interrupted. About 8 minutes a profile.
#
#   kind-mesh-cilium/scripts/election-tuning.sh                  # every profile, in the order below
#   kind-mesh-cilium/scripts/election-tuning.sh e5000-c0 e2000-c0
#   kind-mesh-cilium/scripts/election-tuning.sh --table          # the table, from the records already there
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
lab_env
out="$here/output"
# shellcheck source-path=SCRIPTDIR source=rs-lib.sh
. "$here/scripts/rs-lib.sh"
client="heartbeatFrequencyMS=2000&connectTimeoutMS=5000"
# The replica set's settings per profile, over rs_defaults (electionTimeoutMillis 10000, catchUpTimeoutMillis -1: no
# limit, heartbeatTimeoutSecs 10). A new primary accepts writes only after its catch-up, which waits for a heartbeat
# result from every member; from a member that does not answer, that takes heartbeatTimeoutSecs.
order=(e10000 e10000-c0 e5000 e5000-c0 e5000-h5 e2000-c0)
declare -A profiles=(
  [e10000]="electionTimeoutMillis=10000"
  [e10000-c0]="electionTimeoutMillis=10000 catchUpTimeoutMillis=0"
  [e5000]="electionTimeoutMillis=5000"
  [e5000-c0]="electionTimeoutMillis=5000 catchUpTimeoutMillis=0"
  [e5000-h5]="electionTimeoutMillis=5000 heartbeatTimeoutSecs=5"
  [e2000-c0]="electionTimeoutMillis=2000 catchUpTimeoutMillis=0"
)

if [ "${1:-}" != --table ]; then
  run=("${@:-${order[@]}}")
  for p in "${run[@]}"; do [ -n "${profiles[$p]:-}" ] || { echo "no profile $p (${order[*]})" >&2; exit 2; }; done
  # shellcheck disable=SC2086  # one argument per setting
  trap 'reconfig $rs_defaults >/dev/null' EXIT
  for p in "${run[@]}"; do
    # shellcheck disable=SC2086
    reconfig $rs_defaults ${profiles[$p]} | grep 'reconfig ok: 1' >/dev/null || { echo "reconfig for $p failed: $out/election-tuning-reconfig.txt" >&2; exit 1; }
    DRILL_TAG=$p MATRIX_SETTINGS=$client "$here/scripts/primary-matrix.sh" | grep '^done' | sed "s/^/$p: /"
  done
fi

echo "| Replica set settings (others default) | Lost by | Writes failed | Longest write | Longest without an acknowledged write | New primary elected after | Writes accepted after | Searches failed | Acknowledged writes all there, once |"
echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
for p in "${order[@]}"; do
  # primary-matrix.sh's columns: lost by, client, writes failed, longest write, gap, searches failed, elected,
  # accepted, check. A profile with no records yet gives no rows.
  DRILL_TAG=$p MATRIX_SETTINGS=$client "$here/scripts/primary-matrix.sh" --table | { grep -E '^\| (freeze|kill|partition) ' || true; } \
    | awk -F' \\| ' -v s="${profiles[$p]}" '{ sub(/^\| /, "", $1); printf "| `%s` | %s | %s | %s | %s | %s | %s | %s | %s\n", s, $1, $3, $4, $5, $7, $8, $6, $9 }'
done
