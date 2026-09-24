#!/usr/bin/env bash
# Load the sample dataset and its search indexes into the external replica set.
#
# Index creation is NOT a local operation: mongod forwards it to
# searchIndexManagementHostAndPort, so these calls traverse the load balancer and
# Envoy exactly as queries do. If this script succeeds, that path works.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${DB:=sample_mflix}" "${COLL:=movies}"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-bgp-fabric}"
URI="mongodb://${ROOT_USER}:${ROOT_PASSWORD}@localhost:${PORT1}/admin?directConnection=true"

DOCS=$(cat data/movies.json)
IDX_TEXT=$(cat data/indexes/default.json)
IDX_VEC=$(cat data/indexes/vector_index.json)

docker exec -i mongo1 mongosh "$URI" --quiet --file /dev/stdin <<EOF
const db2 = db.getSiblingDB("${DB}");
const coll = "${COLL}";

db2[coll].drop();
db2[coll].insertMany(${DOCS});
print("documents loaded: " + db2[coll].countDocuments({}));

for (const spec of [${IDX_TEXT}, ${IDX_VEC}]) {
  try { db2[coll].dropSearchIndex(spec.name); sleep(1000); } catch (e) {}
  db2[coll].createSearchIndex(spec.name, spec.type, spec.definition);
  print("index requested: " + spec.name + " (" + spec.type + ")");
}

print("waiting for indexes to become queryable...");
for (let i = 0; i < 60; i++) {
  const all = db2[coll].getSearchIndexes();
  const ready = all.filter(x => x.queryable === true).map(x => x.name);
  if (ready.length === 2) { print("QUERYABLE: " + ready.join(", ")); break; }
  if (i === 59) { print("TIMEOUT - still waiting: " + JSON.stringify(all.map(x => [x.name, x.status]))); }
  sleep(2000);
}
EOF
