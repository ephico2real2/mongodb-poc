#!/usr/bin/env bash
# Story #131: the primary drill (drills.sh primary) for each way of losing mesh0 and each client setting, one run after
# another, then one table read from the runs' records. About 3 minutes a run; between runs mesh0 takes the primary back
# by itself (priority 2), and the drill waits for it.
#
#   kind-mesh-cilium/scripts/primary-matrix.sh                    # freeze, kill, partition × the four settings
#   kind-mesh-cilium/scripts/primary-matrix.sh kill partition     # some of the modes
#   kind-mesh-cilium/scripts/primary-matrix.sh --table            # only the table, from the records already there
# DRILL_TAG=<tag> (passed on to drills.sh) keeps a run under another server setting in records of its own.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/output"
# The writing client's options under test, added to its connection string ("" is mongosh 2.6.0's defaults).
settings=("" "connectTimeoutMS=5000&socketTimeoutMS=5000" "timeoutMS=10000" "heartbeatFrequencyMS=2000&connectTimeoutMS=5000")
record() { # <mode> <setting>: the record drills.sh writes for them
  printf '%s/drill-primary-%s%s%s.txt' "$out" "$1" "${2:+-$(printf '%s' "$2" | tr '&=' '-_')}" "${DRILL_TAG:+-$DRILL_TAG}"
}

if [ "${1:-}" != --table ]; then
  read -r -a modes <<<"${*:-freeze kill partition}"
  for m in "${modes[@]}"; do
    for o in "${settings[@]}"; do
      # drills.sh refuses to start until mesh0 is primary again; give it up to 5 minutes.
      for try in 1 2 3 4 5 6; do
        CLIENT_OPTS="$o" "$here/drills.sh" primary "$m" >/dev/null 2>&1 && break
        grep -q 'is not primary' "$(record "$m" "$o")" || { echo "drill $m ${o:-default} failed: $(record "$m" "$o")" >&2; break; }
        [ "$try" = 6 ] && { echo "mesh0 did not take the primary back: $(record "$m" "$o")" >&2; exit 1; }
        sleep 50
      done
      echo "done: $m ${o:-default}"
    done
  done
fi

echo "| Lost by | Client options | Writes failed | Longest write | Searches failed | New primary elected after | Acknowledged writes all there, once |"
echo "| --- | --- | --- | --- | --- | --- | --- |"
for m in freeze kill partition; do
  for o in "${settings[@]}"; do
    f=$(record "$m" "$o")
    grep -qs '^RESULT ' "$f" || continue   # no record yet, or a run that did not finish
    python3 - "$f" "$m" "${o:-defaults}" <<'EOF'
import json, re, sys
f, mode, opts = sys.argv[1:]
text = open(f).read()
r = json.loads(re.search(r"^RESULT (.*)$", text, re.M).group(1))
new = re.search(r"primary now: (\S+) \(elected ([\d.]+) s", text)
if not new:
    sys.exit(f"{f}: no election time recorded (a record from before drills.sh read it from the log)")
w, s = r["write"], r["search"]
check = "yes" if "every acknowledged write is there, once" in text else "**no**"
print(f"| {mode} | `{opts}` | {w['fail']} of {w['ok'] + w['fail']} | {w['maxMs'] / 1000:.1f} s | "
      f"{s['fail']} of {s['ok'] + s['fail']} | {new.group(2)} s ({new.group(1)}) | {check} |")
EOF
  done
done
