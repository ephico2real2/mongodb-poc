#!/usr/bin/env bash
# Deploys the repository's search GUI (app/gui/server.py) in mesh0, set up for the mesh: a search can go through any
# cluster's member, and the page shows which cluster's mongot answered. Run after data-load.sh.
#
#   kind-mesh/scripts/gui-up.sh      # idempotent; prints the GUI's address
#
# The GUI logs in as its own user, search-gui, which may read sample_mflix and nothing else. Its password is made
# here once and kept only in the Secret of the connection string (namespace search, mesh0).
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
cd "$LAB_DIR"
lab_env
# shellcheck disable=SC2153  # CLUSTERS comes from versions.env
read -r -a clusters <<<"$CLUSTERS"
hosts="mongo-mesh0.mongodb.svc.cluster.local:27017,mongo-mesh1.mongodb.svc.cluster.local:27017,mongo-mesh2.mongodb.svc.cluster.local:27017"

say "every mongot pod's metrics, one global Service each"
for c in "${clusters[@]}"; do
  sed_args=()
  for n in "${clusters[@]}"; do
    sel=mongot-metrics-not-here; [ "$n" = "$c" ] && sel=mongot-search-0-svc
    sed_args+=(-e "s/__SEL_${n}__/$sel/")
  done
  sed "${sed_args[@]}" manifests/30-mongot-metrics.yaml | kubectl --context "kind-$c" apply -f - >/dev/null
  echo "  $c: mongot-metrics-$c-0 and -1 select its two mongot pods; the other clusters' select nothing here"
done

say "the GUI's user, search-gui (read on sample_mflix), and its connection string"
if kubectl --context kind-mesh0 -n search get secret mongot-gui-mongo-uri >/dev/null 2>&1; then
  echo "  the Secret exists, kept"
else
  gui_pw=$(openssl rand -hex 24)
  admin_pw=$(kubectl --context kind-mesh0 -n mongodb get secret mongo-admin -o jsonpath='{.data.password}' | base64 -d)
  # Through the replica set, so the user is created on whichever member is primary; the script on stdin.
  kubectl --context kind-mesh0 -n mongodb exec -i mongo-0 -c mongod -- mongosh --quiet \
    "mongodb://$hosts/?replicaSet=rs0&tls=true&tlsCAFile=/run/mongod/ca.crt" --file /dev/stdin <<EOF
const admin = db.getSiblingDB("admin");
admin.auth("labAdmin", "$admin_pw");
if (admin.getUsers({filter: {user: "search-gui"}}).users.length) admin.dropUser("search-gui");
admin.createUser({user: "search-gui", pwd: "$gui_pw", roles: [{role: "read", db: "sample_mflix"}]});
print("  search-gui: created");
EOF
  printf 'mongodb://search-gui:%s@%s/admin?replicaSet=rs0&tls=true&tlsCAFile=/ca/ca.crt' "$gui_pw" "$hosts" \
    | kubectl --context kind-mesh0 -n search create secret generic mongot-gui-mongo-uri --from-file=uri=/dev/stdin >/dev/null
  echo "  Secret mongot-gui-mongo-uri created"
fi

say "the GUI in mesh0"
kubectl --context kind-mesh0 -n search create configmap mongot-gui-src --from-file=server.py=../app/gui/server.py \
  --dry-run=client -o yaml | kubectl --context kind-mesh0 apply -f - >/dev/null
kubectl --context kind-mesh0 apply -f manifests/31-search-gui.yaml >/dev/null
# The code is a ConfigMap, which a running pod does not reread: a restart picks up a changed server.py.
kubectl --context kind-mesh0 -n search rollout restart deploy/mongot-gui >/dev/null
kubectl --context kind-mesh0 -n search rollout status deploy/mongot-gui --timeout=3m >/dev/null
ip=""
for _ in $(seq 1 24); do
  ip=$(kubectl --context kind-mesh0 -n search get svc mongot-gui -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [ -n "$ip" ] && break; sleep 5
done
echo "  the GUI: http://${ip:-<no address yet>}/  (from the Mac, with the route up.sh printed;"
echo "  or: kubectl --context kind-mesh0 -n search port-forward svc/mongot-gui 8080:80, then http://localhost:8080/)"
