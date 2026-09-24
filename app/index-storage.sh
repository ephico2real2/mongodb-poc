#!/usr/bin/env bash
# What each mongot replica actually stores, and how to check it yourself.
#
#   ./app/index-storage.sh
#
# Answers the question "how does the data in the mongot StatefulSet stay in sync"
# from the storage side: every replica builds and holds its OWN complete Lucene
# index, fed independently from the replica set. Nothing is shared between pods.
set -uo pipefail
cd "$(dirname "$0")/.."
: "${NS:=mongodb-poc}" "${STS:=mongot-search-0}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.crc/machines/crc/kubeconfig}"
C_B=$'\033[1m'; C_D=$'\033[2m'; C_0=$'\033[0m'
[ -t 1 ] || { C_B= C_D= C_0=; }

PODS=$(oc get pods -n "$NS" -l "statefulset.kubernetes.io/pod-name" -o name 2>/dev/null \
       | sed 's|pod/||' | grep "^${STS}-" | sort)
[ -z "$PODS" ] && PODS=$(oc get pods -n "$NS" --no-headers 2>/dev/null | awk '$1 ~ /^'"$STS"'-[0-9]+$/ {print $1}' | sort)
[ -z "$PODS" ] && { echo "no $STS pods in $NS" >&2; exit 1; }
FIRST=$(echo "$PODS" | head -1)

echo "${C_B}1. every replica holds the same set of indexes${C_0}"
echo "${C_D}   directory name is <indexId>_f<formatVersion>_u<n>_a<n>${C_0}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for p in $PODS; do
  oc exec -n "$NS" "$p" -- ls -1 /mongot/data 2>/dev/null | grep '_f[0-9]*_' | sort > "$tmp/$p.txt"
  printf "   %-22s %s index directories\n" "$p" "$(wc -l < "$tmp/$p.txt" | tr -d ' ')"
done
base="$tmp/$FIRST.txt"; same=1
for p in $PODS; do cmp -s "$base" "$tmp/$p.txt" || same=0; done
[ "$same" = 1 ] && echo "   ${C_D}-> identical index IDs on every replica${C_0}" \
                || echo "   -> WARNING: the replicas hold different index sets"
echo
sed 's/^/     /' "$base"

echo
echo "${C_B}2. the format version in the directory name matches the metric${C_0}"
oc exec -n "$NS" "$FIRST" -- ls -1 /mongot/data 2>/dev/null | grep -oE '_f[0-9]+_' | sort | uniq -c \
  | awk '{printf "   %s directories named %s\n", $1, $2}'
TB=$(oc get pods -n "$NS" -l app=mongot-toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$TB" ]; then
  oc exec -n "$NS" "$TB" -- sh -c "curl -s --max-time 5 http://$FIRST.${STS}-svc:9946/metrics 2>/dev/null \
    | grep -E '^mongot_configState_indexesInCatalog\{'" 2>/dev/null | sed 's/^/   /'
else
  echo "   ${C_D}(toolbox pod absent - skipping the metric cross-check)${C_0}"
fi

echo
echo "${C_B}3. what is inside one index directory${C_0}"
ID=$(head -1 "$base")
echo "   ${C_D}$ID${C_0}"
for p in $PODS; do
  out=$(oc exec -n "$NS" "$p" -- sh -c "ls -l /mongot/data/$ID 2>/dev/null | awk '\$5 ~ /^[0-9]+\$/ {print \$9\"=\"\$5}'" 2>/dev/null | sort | tr '\n' ' ')
  printf "     %-22s %s\n" "$p" "$out"
done
cat <<TXT
   ${C_D}.cfs/.cfe/.si are Lucene compound segment files, segments_N is the commit
   point, write.lock is the single-writer lock. This is a Lucene index on disk,
   not a copy of the BSON documents.${C_0}
TXT

echo
echo "${C_B}4. where the disk actually goes${C_0}"
for p in $PODS; do
  oc exec -n "$NS" "$p" -- sh -c 'du -sk /mongot/data/* 2>/dev/null' 2>/dev/null \
    | awk '{n=$2; sub(".*/","",n); print n, $1}' | sort > "$tmp/du-$p.txt"
done
printf "   %-38s" "entry"; for p in $PODS; do printf " %10s" "${p##*-}"; done; printf "   KB\n"
cut -d' ' -f1 "$tmp/du-$FIRST.txt" | while read -r e; do
  printf "   %-38s" "$e"; vals=""
  for p in $PODS; do v=$(awk -v k="$e" '$1==k{print $2}' "$tmp/du-$p.txt"); v=${v:-0}; vals="$vals $v"; printf " %10s" "$v"; done
  u=$(echo $vals | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
  [ "$u" -gt 1 ] && printf "   differs" ; printf "\n"
done
echo
idx=0
for p in $PODS; do
  s=$(grep '_f[0-9]*_' "$tmp/du-$p.txt" | awk '{t+=$2} END{print t+0}')
  d=$(awk '$1=="diagnostic.data"{print $2+0}' "$tmp/du-$p.txt")
  printf "   %-22s index data %6s KB   diagnostic.data %6s KB\n" "$p" "$s" "${d:-0}"
done
cat <<TXT

   ${C_D}The index data is the small part. diagnostic.data is mongot's own telemetry
   and usually dominates the volume, so a PVC that looks large is not evidence of
   a large index. Compare the index directories, not the total.${C_0}
TXT
