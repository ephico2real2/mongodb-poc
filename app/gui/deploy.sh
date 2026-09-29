#!/usr/bin/env bash
# Deploy mongot-gui into any namespace that runs a MongoDBSearch. Idempotent.
#
#   NS=mongodb-poc ./app/gui/deploy.sh                          # reuse an existing URI Secret
#   NS=search MONGO_URI='mongodb://user:pass@host:27017/admin' \
#     SEARCH_NAME=acme MONGOT_REPLICAS=2 ./app/gui/deploy.sh
#
# Settings (all optional; defaults reproduce this lab):
#   DB COLL SEARCH_NAME CLUSTER_INDEX MONGOT_SVC MONGOT_REPLICAS METRICS_PORT
#   TEXT_INDEX VECTOR_INDEX VECTOR_PATH
set -euo pipefail
cd "$(dirname "$0")"
: "${NS:?set NS to the namespace to deploy into}"

# 1. The code, as a ConfigMap mounted at /app.
oc create configmap mongot-gui-src -n "$NS" --from-file=server.py=server.py \
  --dry-run=client -o yaml | oc apply -f -

# 2. Settings - only the variables actually set, so unset ones keep server.py's defaults.
args=()
for v in DB COLL SEARCH_NAME CLUSTER_INDEX MONGOT_SVC MONGOT_REPLICAS METRICS_PORT \
         TEXT_INDEX VECTOR_INDEX VECTOR_PATH; do
  [ -n "${!v:-}" ] && args+=("--from-literal=$v=${!v}")
done
oc create configmap mongot-gui-config -n "$NS" ${args[@]+"${args[@]}"} \
  --dry-run=client -o yaml | oc apply -f -

# 3. The connection string. Piped through stdin so it never appears in a process list.
if [ -n "${MONGO_URI:-}" ]; then
  printf '%s' "$MONGO_URI" | oc create secret generic mongot-gui-mongo-uri -n "$NS" \
    --from-file=uri=/dev/stdin --dry-run=client -o yaml | oc apply -f -
elif ! oc get secret mongot-gui-mongo-uri -n "$NS" >/dev/null 2>&1; then
  echo "no Secret mongot-gui-mongo-uri in $NS - set MONGO_URI to create it" >&2
  exit 1
fi

# 4. Deployment, Service, Route. The server reads its code, settings and connection string
#    only at startup, so a hash of all three goes on the pod template IN THE SAME APPLY: a
#    change rolls the pod once, an unchanged hash is a no-op. Only the hash is stored.
hash=$( { cat server.py
          oc get configmap mongot-gui-config -n "$NS" -o jsonpath='{.data}'
          oc get secret mongot-gui-mongo-uri -n "$NS" -o jsonpath='{.data.uri}'; } \
        | shasum -a 256 | cut -c1-16 )
sed "s|mongot-gui/config-hash: \"unset\"|mongot-gui/config-hash: \"$hash\"|" mongot-gui.yaml \
  | oc apply -n "$NS" -f -
oc rollout status deploy/mongot-gui -n "$NS" --timeout=180s

echo "https://$(oc get route mongot-gui -n "$NS" -o jsonpath='{.spec.host}')"
