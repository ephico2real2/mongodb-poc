#!/usr/bin/env bash
# A tiny search application.
#
# It talks ONLY to MongoDB - exactly as a real application does. It has no idea that
# mongot, Envoy, MetalLB or a Route exist. mongod forwards the $search stage over gRPC
# to whatever mongotHost points at, and the results come back through that chain.
#
# Flags MUST precede the query - getopts stops at the first non-option argument.
#
#   ./app/search-cli.sh detective            full-text
#   ./app/search-cli.sh -v creature          vector (nearest theme)
#   ./app/search-cli.sh -v -y 1980 space     vector, filtered to year >= 1980
#   ./app/search-cli.sh -n 10 corruption     ten results
set -euo pipefail
cd "$(dirname "$0")/../mongodb"
set -a; . ./.env; set +a
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-bgp-fabric}"
: "${DB:=sample_mflix}" "${COLL:=movies}" "${LIMIT:=5}"

MODE=text YEAR=0
while getopts "vy:n:h" o; do case $o in
  v) MODE=vector;; y) YEAR=$OPTARG;; n) LIMIT=$OPTARG;;
  h) sed -n '2,12p' "$0"; exit 0;;
esac; done
shift $((OPTIND-1))
Q="${*:-detective}"
# guard the trap that flags after the query are silently ignored
case "$Q" in *" -"*) echo "  ERROR: flags must come BEFORE the query. Try: $0 -v -y 1990 space" >&2; exit 2;; esac
URI="mongodb://${ROOT_USER}:${ROOT_PASSWORD}@localhost:${PORT1}/admin?directConnection=true"

# the five themes the corpus is built around
case "$Q" in
  underdog|boxer|karate) V="[0.9,0.1,0,0.05,0]";;
  americana|baseball)    V="[0,0.9,0,0,0]";;
  creature|shark|horror) V="[0,0,0.9,0,0]";;
  space|astronaut)       V="[0,0,0,0.92,0]";;
  noir|detective|crime)  V="[0,0,0,0,0.92]";;
  *)                     V="[0.2,0.2,0.2,0.2,0.2]";;
esac

docker exec -i mongo1 mongosh "$URI" --quiet --eval "
const d = db.getSiblingDB('$DB');
const t0 = Date.now();
let rows;
if ('$MODE' === 'vector') {
  const stage = { index:'vector_index', path:'plot_embedding', queryVector:$V,
                  numCandidates:200, limit:$LIMIT };
  if ($YEAR > 0) stage.filter = { year: { \$gte: $YEAR } };
  rows = d.$COLL.aggregate([{ \$vectorSearch: stage },
    { \$project:{ title:1, year:1, genre:1, score:{ \$meta:'vectorSearchScore' } } }]).toArray();
} else {
  rows = d.$COLL.aggregate([
    { \$search:{ index:'default', text:{ query:'$Q', path:{ wildcard:'*' } } } },
    { \$project:{ title:1, year:1, genre:1, score:{ \$meta:'searchScore' } } },
    { \$limit: $LIMIT }]).toArray();
}
const ms = Date.now() - t0;
print('');
print('  query   : \"$Q\"   mode: $MODE' + ($YEAR > 0 ? '   filter: year >= $YEAR' : ''));
print('  corpus  : ' + d.$COLL.countDocuments({}).toLocaleString() + ' documents');
print('  latency : ' + ms + 'ms   results: ' + rows.length);
print('');
print('  ' + 'TITLE'.padEnd(30) + 'YEAR  ' + 'GENRE'.padEnd(10) + 'SCORE');
print('  ' + '-'.repeat(60));
rows.forEach(r => print('  ' + String(r.title).padEnd(30) + String(r.year).padEnd(6) +
                       String(r.genre||'').padEnd(10) + r.score.toFixed(4)));
print('');
"
