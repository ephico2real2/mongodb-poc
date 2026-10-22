#!/usr/bin/env bash
# Builds the replica set rs0 over the mesh: one mongod in each cluster, reached by its global member Service, mesh0's
# primary while it is up (priority 2, the others 1). Then the users: an administrator, and the sync user mongot logs in
# with (role searchCoordinator).
#
#   kind-mesh/scripts/mongo-up.sh     # idempotent: existing Secrets, members and users are kept
#
# The keyfile and the passwords are made here, once, with openssl, and exist only as Secrets in the clusters: never in
# a file, an argument or the output. The administrator's is in Secret mongo-admin (namespace mongodb, every cluster),
# the sync user's in search-sync-source-password (namespace search, every cluster), where the chart reads it.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
cd "$LAB_DIR"
lab_env
# shellcheck disable=SC2153  # CLUSTERS comes from versions.env
read -r -a clusters <<<"$CLUSTERS"
first="${clusters[0]}"
fqdn() { echo "mongo-$1.mongodb.svc.cluster.local"; }

# A Secret made once in mesh0 and copied, data only, to the others; $3 makes its data when mesh0 has none.
shared_secret() { # <namespace> <name> <command printing a JSON object of key: base64 value>
  local ns=$1 name=$2 data c
  if ! data=$(kubectl --context "kind-$first" -n "$ns" get secret "$name" -o jsonpath='{.data}' 2>/dev/null) || [ -z "$data" ]; then
    data=$($3)
    echo "  $ns/$name: made"
  else
    echo "  $ns/$name: exists in $first, kept"
  fi
  for c in "${clusters[@]}"; do
    printf '%s' "$data" | python3 -c '
import json, sys
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
  "metadata": {"name": sys.argv[1], "namespace": sys.argv[2]}, "data": json.load(sys.stdin)}))' "$name" "$ns" \
      | kubectl --context "kind-$c" apply -f - >/dev/null
  done
}
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
new_keyfile() { printf '{"keyfile":"%s"}' "$(openssl rand -base64 756 | tr -d '\n' | base64 | tr -d '\n')"; }
new_admin() { printf '{"username":"%s","password":"%s"}' "$(b64 labAdmin)" "$(b64 "$(openssl rand -hex 24)")"; }
new_sync() { printf '{"password":"%s"}' "$(b64 "$(openssl rand -hex 24)")"; }

say "namespaces and member Services in ${clusters[*]}"
for c in "${clusters[@]}"; do
  kubectl --context "kind-$c" apply -f manifests/10-namespaces.yaml -f manifests/11-member-services.yaml >/dev/null
done

say "the keyfile and the passwords, shared by the three clusters"
shared_secret mongodb mongo-keyfile new_keyfile
shared_secret mongodb mongo-admin new_admin
shared_secret search search-sync-source-password new_sync

for c in "${clusters[@]}"; do
  say "$c: certificate and mongod"
  sed "s/__MESH__/$c/g" manifests/12-mongod-certificate.yaml | kubectl --context "kind-$c" apply -f - >/dev/null
  kubectl --context "kind-$c" -n mongodb wait certificate/mongod --for=condition=Ready --timeout=2m >/dev/null
  sed "s/__MESH__/$c/g" manifests/13-mongod.yaml | kubectl --context "kind-$c" apply -f - >/dev/null
done
for c in "${clusters[@]}"; do
  kubectl --context "kind-$c" -n mongodb rollout status statefulset/mongo --timeout=5m >/dev/null
  echo "$c: $(kubectl --context "kind-$c" -n mongodb get pod mongo-0 -o jsonpath='{.status.phase} on {.spec.nodeName}, {.status.podIP}')"
done

# mongosh in a member's pod, reading its script from stdin so that no password is in an argument.
msh() { # <cluster> [mongosh options]; the script on stdin
  local c=$1; shift
  kubectl --context "kind-$c" -n mongodb exec -i mongo-0 -c mongod -- \
    mongosh --quiet --tls --tlsCAFile /run/mongod/ca.crt --host localhost "$@" --file /dev/stdin
}
admin_pw=$(kubectl --context "kind-$first" -n mongodb get secret mongo-admin -o jsonpath='{.data.password}' | base64 -d)
sync_pw=$(kubectl --context "kind-$first" -n search get secret search-sync-source-password -o jsonpath='{.data.password}' | base64 -d)

say "initiate rs0 from $first"
# hello needs no login, before and after the users exist; rs.status() is refused without one once labAdmin exists.
if [ "$(printf 'print(db.hello().setName || "")' | msh "$first" 2>/dev/null)" != rs0 ]; then
  # Under the localhost exception: no user exists yet.
  msh "$first" <<EOF
rs.initiate({_id: "rs0", members: [
  {_id: 0, host: "$(fqdn mesh0):27017", priority: 2},
  {_id: 1, host: "$(fqdn mesh1):27017", priority: 1},
  {_id: 2, host: "$(fqdn mesh2):27017", priority: 1}]})
EOF
else
  echo "already initiated"
fi
for _ in $(seq 1 60); do
  primary=$(printf 'print(db.hello().isWritablePrimary)' | msh "$first" 2>/dev/null || true)
  [ "$primary" = true ] && break; sleep 5
done
[ "$primary" = true ] || die "$first did not become primary in 5 minutes"

say "users: labAdmin (root) and search-sync-source (searchCoordinator)"
# The localhost exception allows creating the first user and nothing else, not even listing users: so a login is
# tried first, and labAdmin is created only when it fails.
msh "$first" <<EOF
const admin = db.getSiblingDB("admin");
let exists = true;
try { admin.auth("labAdmin", "$admin_pw"); } catch (e) { exists = false; }
if (!exists) {
  admin.createUser({user: "labAdmin", pwd: "$admin_pw", roles: [{role: "root", db: "admin"}]});
  admin.auth("labAdmin", "$admin_pw");
}
print("labAdmin: " + (exists ? "exists" : "created"));
if (admin.getUsers({filter: {user: "search-sync-source"}}).users.length === 0) {
  admin.createUser({user: "search-sync-source", pwd: "$sync_pw", roles: [{role: "searchCoordinator", db: "admin"}]});
  print("search-sync-source: created");
} else { print("search-sync-source: exists"); }
EOF

say "rs0 as each member sees it"
for c in "${clusters[@]}"; do
  printf 'db.getSiblingDB("admin").auth("labAdmin", "%s"); rs.status().members.forEach(m => print("  " + m.name + "  " + m.stateStr + "  health " + m.health))' "$admin_pw" \
    | msh "$c" | sed "s/^/$c sees:/"
done
