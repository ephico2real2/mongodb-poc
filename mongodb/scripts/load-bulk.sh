#!/usr/bin/env bash
# Load the bulk corpus for load testing, on top of the curated documents.
#
# Streams JSON through mongosh stdin in batches: a single 4 MB JS literal is slow to
# parse and easy to blow up, and batching also lets progress be reported.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${DB:=sample_mflix}" "${COLL:=movies}" "${BATCH:=2000}"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-bgp-fabric}"
URI="mongodb://${ROOT_USER}:${ROOT_PASSWORD}@localhost:${PORT1}/admin?directConnection=true"
SRC="${1:-data/bulk-movies.json}"

TOTAL=$(python3 -c "import json;print(len(json.load(open('$SRC'))))")
echo "loading $TOTAL documents from $SRC in batches of $BATCH"
START=$(date +%s)
OFF=0
while [ "$OFF" -lt "$TOTAL" ]; do
  python3 -c "
import json,sys
d=json.load(open('$SRC'))[$OFF:$OFF+$BATCH]
print('db.getSiblingDB(\"$DB\").$COLL.insertMany(' + json.dumps(d) + ', {ordered:false});')
print('print(\"  +\" + $BATCH);')
" | docker exec -i mongo1 mongosh "$URI" --quiet --file /dev/stdin >/dev/null
  OFF=$((OFF + BATCH))
  printf "\r  inserted %d/%d" "$((OFF<TOTAL?OFF:TOTAL))" "$TOTAL"
done
echo
docker exec -i mongo1 mongosh "$URI" --quiet --eval "
print('  collection count: ' + db.getSiblingDB('$DB').$COLL.countDocuments({}));"
echo "  load took $(( $(date +%s) - START ))s"

echo "waiting for mongot to index..."
for i in $(seq 1 90); do
  R=$(docker exec -i mongo1 mongosh "$URI" --quiet --eval "
    const x=db.getSiblingDB('$DB').$COLL.getSearchIndexes();
    print(x.filter(i=>i.queryable===true).length);" 2>/dev/null | tr -d '[:space:]')
  [ "$R" = "2" ] && { echo "  both indexes queryable"; break; }
  sleep 4
done
