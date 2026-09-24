#!/usr/bin/env bash
# Measure how long a write takes to become searchable.
#
#   ./app/sync-probe.sh              insert, update and delete, timed
#   ./app/sync-probe.sh -n 5         run the cycle five times and summarise
#   ./app/sync-probe.sh -s           also show what each mongot replica holds on disk
#   ./app/sync-probe.sh -r           show the replicas disagreeing right after a write
#
# Writes a uniquely tagged document, polls the search index until the change is
# visible, then removes it. The corpus is left exactly as it was found.
#
# What this demonstrates: mongot does not query mongod at search time. It keeps its
# own Lucene index, fed by a change stream. The number below is how far behind that
# index runs - MongoDB calls it index replication lag.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./mongodb/.env 2>/dev/null || true; set +a
: "${NS:=mongodb-poc}" "${DB:=platform_ops}" "${COLL:=incidents}" "${INDEX:=incidents_text}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.crc/machines/crc/kubeconfig}"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-bgp-fabric}"
URI="mongodb://${ROOT_USER:-labAdmin}:${ROOT_PASSWORD:-x}@localhost:${PORT1:-27017}/admin?directConnection=true"

RUNS=1 SHOWDISK= REPL=
while getopts "n:srh" o; do case $o in
  n) RUNS=$OPTARG;; s) SHOWDISK=1;; r) REPL=1;;
  h) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) exit 2;;
esac; done

C_B=$'\033[1m'; C_D=$'\033[2m'; C_G=$'\033[32m'; C_0=$'\033[0m'
[ -t 1 ] || { C_B= C_D= C_G= C_0=; }

echo "${C_B}write-to-searchable latency${C_0} ${C_D}${DB}.${COLL} via index ${INDEX}${C_0}"
echo "${C_D}each run inserts one tagged document, updates it, deletes it, and times each step${C_0}"
echo

docker exec -i mongo1 mongosh "$URI" --quiet --eval "
const d = db.getSiblingDB('$DB');
const runs = $RUNS;
const ins=[], upd=[], del=[];

for (let r = 0; r < runs; r++) {
  const tag = 'ZZSYNCPROBE' + Date.now() + '_' + r;
  const hit = () => d.${COLL}.aggregate([
    {\$search:{index:'$INDEX', text:{query:tag, path:{wildcard:'*'}}}},
    {\$limit:1},{\$project:{_id:0,incident_id:1}}]).toArray().length;

  let t = Date.now();
  d.${COLL}.insertOne({incident_id:tag, title:tag+' probe', component:'performance',
    severity:'low', symptom:'synthetic sync probe', embedding:[0,0,0,0,0,1]});
  let a = -1; while (Date.now()-t < 30000) { if (hit() > 0) { a = Date.now()-t; break; } }

  t = Date.now();
  d.${COLL}.updateOne({incident_id:tag},{\$set:{symptom:'RENAMED'+tag}});
  let b = -1;
  while (Date.now()-t < 30000) {
    const r2 = d.${COLL}.aggregate([{\$search:{index:'$INDEX',text:{query:'RENAMED'+tag,path:{wildcard:'*'}}}},
      {\$limit:3},{\$project:{_id:0,incident_id:1}}]).toArray();
    if (r2.some(x => x.incident_id === tag)) { b = Date.now()-t; break; }
  }

  t = Date.now();
  d.${COLL}.deleteOne({incident_id:tag});
  let c = -1; while (Date.now()-t < 30000) { if (hit() === 0) { c = Date.now()-t; break; } }

  ins.push(a); upd.push(b); del.push(c);
  if (runs > 1) print('  run ' + (r+1) + '   insert ' + a + ' ms   update ' + b + ' ms   delete ' + c + ' ms');
}

function stat(name, xs) {
  const ok = xs.filter(x => x >= 0);
  if (!ok.length) { print('  ' + name + '  no result within 30s'); return; }
  ok.sort((p,q) => p-q);
  const med = ok[Math.floor(ok.length/2)];
  print('  ' + name.padEnd(8) + ' min ' + String(ok[0]).padStart(5) + ' ms' +
        '   median ' + String(med).padStart(5) + ' ms' +
        '   max ' + String(ok[ok.length-1]).padStart(5) + ' ms');
}
if (runs > 1) print('');
stat('insert', ins); stat('update', upd); stat('delete', del);
print('');
print('  corpus left at ' + d.${COLL}.countDocuments({}) + ' documents');
" 2>/dev/null

if [ -n "$SHOWDISK" ]; then
  echo
  echo "${C_B}what each replica holds${C_0} ${C_D}every pod keeps its own complete Lucene index${C_0}"
  for i in $(seq 0 2); do
    p="mongot-search-0-$i"
    sz=$(oc exec -n "$NS" "$p" -- du -sh /mongot/data 2>/dev/null | awk '{print $1}')
    n=$(oc exec -n "$NS" "$p" -- sh -c 'ls -1d /mongot/data/*_f6_* 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')
    printf "  %-20s %-6s across %s index directories\n" "$p" "${sz:-?}" "${n:-?}"
  done
  echo "  ${C_D}sizes differ because each replica merges its own Lucene segments independently;${C_0}"
  echo "  ${C_D}the indexed content is the same, the bytes on disk are not${C_0}"
fi

if [ -n "$REPL" ]; then
  echo
  echo "${C_B}do the replicas agree straight after a write?${C_0}"
  echo "${C_D}\$searchMeta counts inside mongot, so this reads one replica per query - whichever${C_0}"
  echo "${C_D}Envoy picked. A repeating period equal to the replica count is round robin.${C_0}"
  echo
  docker exec -i mongo1 mongosh "$URI" --quiet --eval "
const d = db.getSiblingDB('$DB');
const tag = 'ZZREPLPROBE' + Date.now();
// count.total comes back as a Long; Long(0) === 0 is false in mongosh, so coerce it.
const meta = () => { const r = d.${COLL}.aggregate([{\$searchMeta:{index:'$INDEX',
  text:{query:tag,path:{wildcard:'*'}}, count:{type:'total'}}}]).toArray();
  return r.length ? Number(r[0].count.total) : 0; };

d.${COLL}.insertOne({incident_id:tag,title:tag,component:'performance',severity:'low',embedding:[0,0,0,0,0,1]});
let pat='';
for (let i=0;i<30;i++) pat += (meta()>0 ? '1' : '0');
print('  ' + pat);
print('  ' + (pat.match(/1/g)||[]).length + ' of 30 searches saw the new document');
let t=Date.now(), streak=0;
while (Date.now()-t < 30000 && streak < 30) { streak = meta()>0 ? streak+1 : 0; }
print('');
print('  all replicas agreed after ' + (Date.now()-t) + ' ms');
d.${COLL}.deleteOne({incident_id:tag});
print('  corpus left at ' + d.${COLL}.countDocuments({}) + ' documents');
" 2>/dev/null
fi
