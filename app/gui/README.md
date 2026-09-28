# mongot-gui — a reusable search GUI

A small web page that runs `$search` / `$vectorSearch` **through MongoDB** and shows
**which `mongot` pod answered**. It talks only to `mongod`; `mongod` forwards the search
over gRPC to `mongot`. The attribution comes from reading each `mongot`'s Prometheus
counter just before and just after the query.

| File | What it is |
|---|---|
| `server.py` | the whole app — python3 stdlib + `mongosh`, no dependencies |
| `mongot-gui.yaml` | Deployment, Service, Route — **no namespace**, apply with `-n` |
| `deploy.sh` | creates the ConfigMaps and Secret, applies the manifest, idempotent |

## The image

`quay.io/mongodb/mongodb-community-server:8.3.4-ubi9` — the **stock** MongoDB Community
Server image, unmodified. It is used because it already ships `python3` and `mongosh`; the
GUI's code comes from a ConfigMap. MongoDB publishes the identical image to both
registries (checked 2026-09-28):

| | docker.io/mongodb/… | quay.io/mongodb/… |
|---|---|---|
| index | `sha256:fc8c72e0…` | `sha256:fc8c72e0…` |
| linux/amd64 | `sha256:b37f5262…` | `sha256:b37f5262…` |
| linux/arm64 | `sha256:cdc528cb…` | `sha256:cdc528cb…` |

## What the target needs

- a `MongoDBSearch` with `spec.observability.prometheus` enabled (the per-pod counters)
- search indexes on the collection: a text index and, for vector mode, a vector index
- a MongoDB user that can run the aggregation — the connection string goes in a Secret

## Deploy

```bash
# first time in a namespace: pass the connection string, it becomes a Secret
NS=search MONGO_URI='mongodb://user:pass@mongod-1.corp:27017/admin?replicaSet=rs0' \
  SEARCH_NAME=acme MONGOT_REPLICAS=2 ./app/gui/deploy.sh

# later runs: the Secret is reused
NS=search ./app/gui/deploy.sh
```

The script prints the Route URL. The connection string is piped through stdin, so it
never appears in a process list.

### The same thing by hand

```bash
NS=search

# 1. the code
oc create configmap mongot-gui-src -n $NS --from-file=server.py=app/gui/server.py \
  --dry-run=client -o yaml | oc apply -f -

# 2. settings - only the ones that differ from the defaults below
oc create configmap mongot-gui-config -n $NS \
  --from-literal=SEARCH_NAME=acme --from-literal=MONGOT_REPLICAS=2 \
  --dry-run=client -o yaml | oc apply -f -

# 3. the connection string (key must be `uri`)
oc create secret generic mongot-gui-mongo-uri -n $NS --from-literal=uri='mongodb://…'

# 4. Deployment, Service, Route
oc apply -n $NS -f app/gui/mongot-gui.yaml

# 5. the server reads code and settings only at startup
oc rollout restart deploy/mongot-gui -n $NS
```

`deploy.sh` replaces step 5 with a hash of `server.py` + the settings on the pod template,
applied in the same `oc apply`. Measured on this lab: an unchanged rerun keeps the same
pod; a settings change rolls it once; reverting a setting goes back to the existing
ReplicaSet.

## Settings

All optional, from `mongot-gui-config`. The defaults reproduce this repo's lab.

| Variable | Default | Meaning |
|---|---|---|
| `SEARCH_NAME` | `mongot` | the `MongoDBSearch` CR name |
| `CLUSTER_INDEX` | `0` | `spec.clusters[]` index |
| `MONGOT_REPLICAS` | `3` | how many `mongot` pods to read counters from |
| `MONGOT_SVC` | `<SEARCH_NAME>-search-<CLUSTER_INDEX>-svc` | headless Service of the `mongot` pods |
| `METRICS_PORT` | `9946` | `spec.observability.prometheus.port` |
| `DB`, `COLL` | `sample_mflix`, `movies` | the collection searched |
| `TEXT_INDEX` | `default` | index for `mode=text` |
| `VECTOR_INDEX`, `VECTOR_PATH` | `vector_index`, `plot_embedding` | index and field for `mode=vector` |

Pods are addressed as `<SEARCH_NAME>-search-<CLUSTER_INDEX>-<n>.<MONGOT_SVC>`, the names the
operator gives them.

**One limit of vector mode:** it has no embedding model. It maps a few theme words
(`underdog`, `karate`, `americana`, `baseball`, `creature`, `horror`, `space`,
`astronaut`, `noir`, `detective`) to fixed 5-dimension vectors that match this repo's demo
corpus; any other word falls back to a flat vector. Text mode works on any collection.

## Verify and remove

```bash
curl -sk "https://$(oc get route mongot-gui -n $NS -o jsonpath='{.spec.host}')/healthz"   # ok

oc delete -n $NS -f app/gui/mongot-gui.yaml
oc delete configmap mongot-gui-src mongot-gui-config -n $NS
oc delete secret mongot-gui-mongo-uri -n $NS
```

`manifests/95-search-gui.yaml` is the lab's original fixed-namespace version; this
component is the same app with the lab-specific values made settings.
