#!/usr/bin/env bash
# Load the platform-incident corpus: the use case this POC actually argues for.
#
# Two indexes, because they answer different questions:
#   incidents_text    keyword recall  - "CrashLoopBackOff" finds the exact string
#   incidents_vector  semantic recall - "pods will not start" finds scheduling incidents
#                                        that never contain those words
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${DB:=platform_ops}" "${COLL:=incidents}"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-bgp-fabric}"
URI="mongodb://${ROOT_USER}:${ROOT_PASSWORD}@localhost:${PORT1}/admin?directConnection=true"

DOCS=$(cat data/incidents.json)
IDX_T=$(cat data/indexes/incidents-default.json)
IDX_V=$(cat data/indexes/incidents-vector.json)

docker exec -i mongo1 mongosh "$URI" --quiet --file /dev/stdin <<EOF
const db2 = db.getSiblingDB("${DB}");
db2.${COLL}.drop();
db2.${COLL}.insertMany(${DOCS});
print("incidents loaded: " + db2.${COLL}.countDocuments({}));

for (const spec of [${IDX_T}, ${IDX_V}]) {
  try { db2.${COLL}.dropSearchIndex(spec.name); sleep(1000); } catch (e) {}
  db2.${COLL}.createSearchIndex(spec.name, spec.type, spec.definition);
  print("index requested: " + spec.name + " (" + spec.type + ")");
}
print("waiting for both indexes to become queryable...");
for (let i = 0; i < 90; i++) {
  const ready = db2.${COLL}.getSearchIndexes().filter(x => x.queryable === true).map(x => x.name);
  if (ready.length === 2) { print("QUERYABLE: " + ready.join(", ")); break; }
  if (i === 89) print("TIMEOUT waiting for indexes");
  sleep(2000);
}
EOF
