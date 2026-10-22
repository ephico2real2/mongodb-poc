#!/usr/bin/env bash
# The lab's proofs, one PASS or FAIL row each, with the evidence beside it. The exit code is the number of FAILs
# (the shape of cilium-implementation-poc demos/40-shop-mesh-phase0/check.sh). It writes one probe document to
# lab.probe and reads it back; nothing else is changed.
#
#   kind-mesh/check.sh
# shellcheck disable=SC2015,SC2016  # row always returns 0, so A && row || row is if/else; $ in JavaScript is mongosh's
set -uo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/scripts/lib.sh"
lab_env
# shellcheck disable=SC2153  # CLUSTERS comes from versions.env
read -r -a clusters <<<"$CLUSTERS"
fails=0
row() { # <PASS|FAIL> <claim> <evidence>
  printf '%-4s  %-58s  %s\n' "$1" "$2" "$3"
  [ "$1" = PASS ] || fails=$((fails + 1))
  return 0
}
admin_pw=$(kubectl --context kind-mesh0 -n mongodb get secret mongo-admin -o jsonpath='{.data.password}' | base64 -d)
# mongosh in a cluster's own member, logged in as labAdmin; the script on stdin, so the password is in no argument.
msh() { # <cluster>; the script on stdin
  { printf 'db.getSiblingDB("admin").auth("labAdmin", "%s");\n' "$admin_pw"; cat; } \
    | kubectl --context "kind-$1" -n mongodb exec -i mongo-0 -c mongod -- \
      mongosh --quiet --tls --tlsCAFile /run/mongod/ca.crt --host localhost --file /dev/stdin 2>&1
}
pod_metric() { # <cluster> <pod:port> <path>: a pod's HTTP endpoint through the API server's proxy
  kubectl --context "kind-$1" get --raw "/api/v1/namespaces/search/pods/$2/proxy$3" 2>/dev/null
}

echo "== the mesh"
for c in "${clusters[@]}"; do
  out=$(cilium clustermesh status --context "kind-$c" 2>&1)
  n=$(grep -c 'configured, 2/2 connected' <<<"$out")
  [ "$n" = 2 ] && row PASS "$c is connected to both other clusters" "$n of 2 peers, 2/2 nodes each" \
    || row FAIL "$c is connected to both other clusters" "$n of 2 peers"
done

echo "== the replica set over three clusters"
states=$(printf 'rs.status().members.forEach(m => print(m.name.split(".")[0] + "=" + m.stateStr + "/" + m.health))' | msh mesh0)
primaries=$(grep -c '=PRIMARY/1' <<<"$states"); secondaries=$(grep -c '=SECONDARY/1' <<<"$states")
[ "$primaries" = 1 ] && [ "$secondaries" = 2 ] \
  && row PASS "rs0: one PRIMARY and two SECONDARY, all healthy" "$(tr '\n' ' ' <<<"$states")" \
  || row FAIL "rs0: one PRIMARY and two SECONDARY, all healthy" "$(tr '\n' ' ' <<<"$states")"
probe=$(date +%s)
printf 'const c = new Mongo("mongodb://mongo-mesh0.mongodb.svc.cluster.local,mongo-mesh1.mongodb.svc.cluster.local,mongo-mesh2.mongodb.svc.cluster.local/?replicaSet=rs0&tls=true&tlsCAFile=/run/mongod/ca.crt");
c.getDB("admin").auth("labAdmin", "%s");
c.getDB("lab").probe.insertOne({probe: %s}, {writeConcern: {w: 3, wtimeout: 10000}}); print("written")' "$admin_pw" "$probe" | msh mesh0 >/dev/null
for c in "${clusters[@]}"; do
  got=$(printf 'db.getMongo().setReadPref("nearest"); const d = db.getSiblingDB("lab").probe.findOne({probe: %s}); print((d ? "found" : "missing") + " on " + db.hello().me.split(".")[0] + (db.hello().secondary ? " (secondary)" : " (primary)"))' "$probe" | msh "$c")
  case "$got" in found*) row PASS "a write is on $c's member" "$got";; *) row FAIL "a write is on $c's member" "$got";; esac
done

echo "== search in every cluster"
for c in "${clusters[@]}"; do
  phase=$(kubectl --context "kind-$c" -n search get mongodbsearch mongot -o jsonpath='{.status.phase}' 2>/dev/null)
  want=$(kubectl --context "kind-$c" -n search get mongodbsearch mongot -o jsonpath='{.spec.clusters[0].replicas}' 2>/dev/null)
  ready=$(kubectl --context "kind-$c" -n search get pods -l app=mongot-search-0-svc -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c true)
  [ "$phase" = Running ] && [ "$ready" = "${want:-x}" ] && row PASS "$c: MongoDBSearch Running, every mongot Ready" "phase $phase, $ready of $want Ready" \
    || row FAIL "$c: MongoDBSearch Running, every mongot Ready" "phase ${phase:-none}, ${ready:-0} of ${want:-?} Ready"
done
# Each mongot's own view of the indexes it holds, from its metrics: an index created once, through mongod, must be
# STEADY on all three, which only happens if all three sync it from the replica set.
for c in "${clusters[@]}"; do
  for pod in $(kubectl --context "kind-$c" -n search get pods -l app=mongot-search-0-svc -o jsonpath='{.items[*].metadata.name}'); do
    m=$(pod_metric "$c" "$pod:9946" /metrics | grep '^mongot_index_stats_indexStatusCode{' | grep -v ' 0\.0$' | grep -v ' 0$')
    steady=$(grep 'status="STEADY"' <<<"$m" | awk '{s += $NF} END {print s + 0}')
    other=$(grep -v 'status="STEADY"' <<<"$m" | awk '{s += $NF} END {print s + 0}')
    [ "$steady" -ge 2 ] && [ "$other" = 0 ] && row PASS "$c's $pod holds the indexes, STEADY" "$steady STEADY, $other other" \
      || row FAIL "$c's $pod holds the indexes, STEADY" "$steady STEADY, $other other"
  done
done
# A search through each cluster's own member: with affinity local, its mongod's search goes to its own Envoy and
# mongot, so each answer is that cluster's mongot answering.
for c in "${clusters[@]}"; do
  n=$(printf 'db.getMongo().setReadPref("nearest"); print(db.getSiblingDB("sample_mflix").movies.aggregate([{$search: {index: "default", text: {query: "space", path: {wildcard: "*"}}}}, {$count: "n"}]).toArray().map(x => x.n)[0] || 0)' | msh "$c")
  [ "${n:-0}" -gt 0 ] 2>/dev/null && row PASS "\$search through $c's member returns results" "$n documents" \
    || row FAIL "\$search through $c's member returns results" "${n:-no answer}"
done

echo "== volumes"
for c in "${clusters[@]}"; do
  sizes=$(kubectl --context "kind-$c" get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.spec.resources.requests.storage} {end}')
  big=$(tr ' ' '\n' <<<"$sizes" | grep -v -E '=([0-9]|10)Gi$' | grep -c . || true)
  [ "$big" = 0 ] && row PASS "$c: no volume over 10Gi" "$sizes" || row FAIL "$c: no volume over 10Gi" "$sizes"
done

echo "== $fails failed"
exit "$fails"
