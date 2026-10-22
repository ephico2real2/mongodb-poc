#!/usr/bin/env bash
# Reads the running lab and records what the testing record cites: mongod's election and rollback lines, the
# rollback check (each rolled-back _id looked up on the primary, and the count of lab.drill), OLM's catalog, Hubble's
# flow rates, the flows by pair of clusters from Loki, and the VM's memory and disk. Read-only.
#
#   kind-mesh/scripts/evidence.sh     # writes kind-mesh/output/evidence-<date>.txt and prints it
# shellcheck disable=SC2016,SC2001  # the $ and backticks are Python, JavaScript and LogQL, not the shell's
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
lab_env
out="$LAB_DIR/output/evidence-$(date +%Y-%m-%d).txt"
rs="mongodb://mongo-mesh0.mongodb.svc.cluster.local,mongo-mesh1.mongodb.svc.cluster.local,mongo-mesh2.mongodb.svc.cluster.local/?replicaSet=rs0&tls=true&tlsCAFile=/run/mongod/ca.crt"
admin_pw=$(kubectl --context kind-mesh0 -n mongodb get secret mongo-admin -o jsonpath='{.data.password}' | base64 -d)

{
echo "== recorded $(date -u +%Y-%m-%dT%H:%M:%SZ) by kind-mesh/scripts/evidence.sh"

echo; echo "== mongod's election and rollback lines (mesh1's member)"
kubectl --context kind-mesh1 -n mongodb logs mongo-0 -c mongod | python3 -c '
import json, sys
want = ("Starting an election", "Election succeeded", "Transition to primary complete", "Stepping down from primary", "Member is in new state")
for line in sys.stdin:
    try: d = json.loads(line)
    except ValueError: continue
    if d.get("msg", "").startswith(want):
        a = d.get("attr", {})
        print(d["t"]["$date"], d["msg"][:60], "|", {k: a[k] for k in ("term", "hostAndPort", "newState", "electionTimeoutPeriodMillis") if k in a})'

echo; echo "== rollback: each rolled-back _id on mesh0, looked up on the primary"
# Every document in a rollback file starts with its _id; the collection is the directory, by uuid.
ids=$(kubectl --context kind-mesh0 -n mongodb exec mongo-0 -c mongod -- python3 -c '
import glob, struct
for f in sorted(glob.glob("/data/db/rollback/*/removed.*.bson")):
    if "local.oplog" in f: continue
    b = open(f, "rb").read(); off = 0; ids = []
    while off < len(b):
        n = struct.unpack_from("<i", b, off)[0]; d = b[off:off + n]; i = d.find(b"\x07_id\x00")
        ids.append(d[i + 5:i + 17].hex() if i >= 0 else "?"); off += n
    print(f.split("/")[-2] + "/" + f.split("/")[-1], ",".join(ids))')
[ -n "$ids" ] || ids="none none"
{
  printf 'db.getSiblingDB("admin").auth("labAdmin", "%s");\n' "$admin_pw"
  echo 'const byUuid = {}; db.getMongo().getDBNames().forEach(n => { try { db.getSiblingDB(n).getCollectionInfos().forEach(c => { if (c.info && c.info.uuid) byUuid[c.info.uuid.toString()] = n + "." + c.name; }); } catch (e) {} });'
  echo "$ids" | while read -r f list; do
    [ "$f" = none ] && { echo 'print("no rollback files");'; continue; }
    printf 'print("%s (" + (byUuid["%s"] || "?") + "): each _id on the primary: " + [%s].map(h => { const [db_, coll] = (byUuid["%s"] || "x.y").split(/\\.(.+)/); return db.getSiblingDB(db_).getCollection(coll).countDocuments({_id: ObjectId(h)}); }).join(" "));\n' \
      "$f" "${f%%/*}" "$(echo "$list" | sed "s/\([0-9a-f]\{24\}\)/'\1'/g")" "${f%%/*}"
  done
  echo 'print("lab.drill documents: " + db.getSiblingDB("lab").drill.countDocuments({}));'
} | kubectl --context kind-mesh0 -n mongodb exec -i mongo-0 -c mongod -- mongosh --quiet "$rs" --file /dev/stdin

echo; echo "== OLM's catalog"
for c in mesh0 mesh1 mesh2; do
  echo "$c: $(kubectl --context "kind-$c" -n olm get catalogsource operatorhubio-catalog -o jsonpath='{.status.connectionState.lastObservedState}')"
done

echo; echo "== Hubble: flows a second, each agent"
for c in mesh0 mesh1 mesh2; do
  for p in $(kubectl --context "kind-$c" -n kube-system get pods -l k8s-app=cilium -o name); do
    echo "$c $p: $(kubectl --context "kind-$c" -n kube-system exec "$p" -c cilium-agent -- cilium-dbg status | grep -E '^Hubble:' | tr -s ' ')"
  done
done

echo; echo "== flows by source -> destination cluster, last 15 min (Loki in mesh0)"
q='sum by (flow_source_cluster_name, flow_destination_cluster_name) (count_over_time({namespace="observability",container="hubble-observer"} | regexp `(?P<message>.+)` | line_format `{{.message}}` | json [15m]))'
kubectl --context kind-mesh0 get --raw "/api/v1/namespaces/observability/services/loki:3100/proxy/loki/api/v1/query?query=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$q")" \
  | python3 -c '
import json, sys
for s in sorted(json.load(sys.stdin)["data"]["result"], key=lambda s: -float(s["value"][1])):
    m = s["metric"]; print("  ", m.get("flow_source_cluster_name", "(no pod)"), "->", m.get("flow_destination_cluster_name", "(no pod)"), s["value"][1])'

echo; echo "== memory used by the lab's pods (metrics-server)"
for c in mesh0 mesh1 mesh2; do
  kubectl --context "kind-$c" top pods -n mongodb --no-headers | sed "s/^/$c mongodb /"
  kubectl --context "kind-$c" top pods -n search --no-headers | sed "s/^/$c search  /"
done

echo; echo "== the VM"
colima ssh --profile "$COLIMA_PROFILE" -- sh -c 'free -m | sed -n 1,2p; df -h /var/lib/docker | tail -1'
} | tee "$out"
echo "written: ${out/$HOME/\~}"
