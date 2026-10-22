#!/usr/bin/env bash
# The cost of a short election timeout: how long a link outage each setting rides out. mesh0, the primary, loses every
# packet to the other clusters for <d> seconds (scripts/wan.sh cut), nothing else changes; did the replica set elect
# another primary (its term moved)? Between cases mesh0 takes the primary back (priority 2). The replica set goes back
# to the defaults at the end, also when interrupted.
#
#   kind-mesh-cilium/scripts/blip-test.sh                                       # 10000 5000 2000 ms × 1.5 3 4.5 6 9 s
#   BLIP_TIMEOUTS="5000" BLIP_SECONDS="4 5 6" kind-mesh-cilium/scripts/blip-test.sh
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
lab_env
out="$here/output"
# shellcheck source-path=SCRIPTDIR source=rs-lib.sh
. "$here/scripts/rs-lib.sh"
read -r -a timeouts <<<"${BLIP_TIMEOUTS:-10000 5000 2000}"
read -r -a seconds <<<"${BLIP_SECONDS:-1.5 3 4.5 6 9}"
log="$out/blip-test.txt"
# shellcheck disable=SC2086  # one argument per setting
trap '"$here/scripts/wan.sh" off mesh0; reconfig $rs_defaults >/dev/null' EXIT

# Waits up to 5 minutes for mesh0 to be primary again; prints the term.
settle() {
  local t p
  for _ in $(seq 1 60); do read -r t p <<<"$(rs_term)"; [ "$p" = mongo-mesh0 ] && { echo "$t"; return 0; }; sleep 5; done
  return 1
}

echo "== link outage test, $(date -u +%FT%TZ): mesh0 (the primary) loses every packet to the other clusters for d seconds" | tee "$log"
echo "| electionTimeoutMillis | Outage | New primary elected | Term before -> after |" | tee -a "$log"
echo "| --- | --- | --- | --- |" | tee -a "$log"
for e in "${timeouts[@]}"; do
  # shellcheck disable=SC2086
  reconfig $rs_defaults "electionTimeoutMillis=$e" | grep 'reconfig ok: 1' >/dev/null || { echo "reconfig to $e failed" >&2; exit 1; }
  for d in "${seconds[@]}"; do
    before=$(settle) || { echo "mesh0 did not take the primary back" >&2; exit 1; }
    sleep 10   # heartbeats steady after the settle
    "$here/scripts/wan.sh" cut mesh0 "$d"
    sleep $(( e / 1000 + 15 ))   # long enough for an election that the outage started to finish
    read -r after _ <<<"$(rs_term)"
    # Any election moves the term: another member's, or mesh0 stepping down and winning again.
    printf '| %s | %s s | %s | %s -> %s |\n' "$e" "$d" "$([ "$after" = "$before" ] && echo no || echo yes)" "$before" "$after" | tee -a "$log"
  done
done
