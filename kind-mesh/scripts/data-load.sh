#!/usr/bin/env bash
# Loads the sample movies and their two search indexes (this repo's mongodb/data: movies.json, indexes/default.json,
# indexes/vector_index.json) into sample_mflix.movies, through the replica set, whichever member is primary. Run after
# search-up.sh: creating a search index is not local to mongod, which forwards it to mongotHost (mongot-global), so a
# success here is the first proof that a mongod reaches a mongot over the mesh.
#
#   kind-mesh/scripts/data-load.sh      # drops and reloads the collection and its indexes
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
cd "$LAB_DIR"
lab_env
data=../mongodb/data
admin_pw=$(kubectl --context kind-mesh0 -n mongodb get secret mongo-admin -o jsonpath='{.data.password}' | base64 -d)
rs_uri="mongodb://mongo-mesh0.mongodb.svc.cluster.local:27017,mongo-mesh1.mongodb.svc.cluster.local:27017,mongo-mesh2.mongodb.svc.cluster.local:27017/?replicaSet=rs0&tls=true&tlsCAFile=/run/mongod/ca.crt"

say "sample_mflix.movies and its search indexes, through rs0"
# The script goes on stdin, so neither the password nor the documents are in an argument.
kubectl --context kind-mesh0 -n mongodb exec -i mongo-0 -c mongod -- mongosh --quiet "$rs_uri" --file /dev/stdin <<EOF
db.getSiblingDB("admin").auth("labAdmin", "$admin_pw");
print("primary: " + db.hello().primary);
const coll = db.getSiblingDB("sample_mflix").movies;
coll.drop();
coll.insertMany($(cat "$data/movies.json"), {writeConcern: {w: "majority"}});
print("documents loaded: " + coll.countDocuments({}));
for (const spec of [$(cat "$data/indexes/default.json"), $(cat "$data/indexes/vector_index.json")]) {
  coll.createSearchIndex(spec.name, spec.type, spec.definition);
  print("index requested: " + spec.name + " (" + spec.type + ")");
}
for (let i = 0; i < 90; i++) {
  const all = coll.getSearchIndexes();
  const ready = all.filter(x => x.queryable === true).map(x => x.name);
  if (ready.length === 2) { print("queryable after " + (i * 2) + " s: " + ready.join(", ")); break; }
  if (i === 89) { print("not queryable after 180 s: " + JSON.stringify(all.map(x => [x.name, x.status]))); quit(1); }
  sleep(2000);
}
EOF
