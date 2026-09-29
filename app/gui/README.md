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

`deploy.sh` replaces step 5 with a hash of `server.py`, the settings and the connection
string on the pod template, applied in the same `oc apply` (only the hash is stored).
Measured on this lab: an unchanged rerun keeps the same pod; a settings change rolls it
once; a changed connection string rolls it once; reverting goes back to the existing
ReplicaSet.

### Connection string

```text
mongodb://<user>:<password>@<host1>:<port>,<host2>:<port>,<host3>:<port>/<authDB>?replicaSet=<rsName>
```

- **User** — the GUI only runs aggregations, so `read` on the searched database is enough.
- **Password** — percent-encode `@ : / %` and similar (`p@ss` → `p%40ss`).
- **`/<authDB>`** — the database the user was created in (or `authSource=`).
- **`replicaSet=`** — with a single host and no `replicaSet`, `mongosh` connects
  **directly** to that one member; if it is a secondary, queries can fail.
- **TLS** — add `tls=true&tlsCAFile=/etc/mongo-ca/ca.crt` and mount the CA (see below).

## Example: an external replica set with TLS (UAT)

A MongoDBSearch whose sync source already uses TLS — the relevant part of its CR, with the
database host masked:

```yaml
source:
  external:
    hostAndPorts:
    - "<mongod-host>:<port>"
    tls:
      ca:
        name: ent-trust-bundle
  passwordSecretRef:
    key: password
    name: search-sync-source-password
  username: mongotUser
```

It already provides what the GUI needs in that namespace: the CA (`ent-trust-bundle`,
key `ca.crt`), a user (`mongotUser`, password in `search-sync-source-password`) and the
seed. The index names may not be known yet — run text mode first and leave `VECTOR_*`
unset.

**1. Variables**

```bash
NS=<uat-namespace>
```

**2. Build the connection string from the existing Secret** — the password is read and
percent-encoded inside the command, never typed or printed:

```bash
PW=$(oc get secret search-sync-source-password -n $NS -o jsonpath='{.data.password}' | base64 -d \
     | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')

export MONGO_URI="mongodb://mongotUser:${PW}@<mongod-host>:<port>/admin?replicaSet=<rsName>&tls=true&tlsCAFile=/etc/mongo-ca/ca.crt"
unset PW
```

Use the host name that is on mongod's certificate — the same one as in `hostAndPorts` —
not an IP. Change `/admin` if `mongotUser` lives in another database.

**3. Deploy, text mode only**

```bash
NS=$NS SEARCH_NAME=<MongoDBSearch name> MONGOT_REPLICAS=<replicas> \
  DB=<database> COLL=<collection> TEXT_INDEX=<text index name> \
  ./app/gui/deploy.sh
unset MONGO_URI
```

**4. Mount the CA, reusing `ent-trust-bundle`**

```bash
oc set volume deploy/mongot-gui -n $NS --add --name=mongo-ca \
  --type=configmap --configmap-name=ent-trust-bundle --mount-path=/etc/mongo-ca --read-only
```

This rolls the pod with `/etc/mongo-ca/ca.crt` in place. Later `deploy.sh` runs keep it:
client-side `oc apply` only removes fields it recorded itself.

**5. Find the names not known yet** — inside the GUI pod, which already has `mongosh` and
the connection string, so nothing sensitive is shown:

```bash
# replica set name, for step 2
oc exec -n $NS deploy/mongot-gui -- sh -c 'mongosh "$MONGO_URI" --quiet --eval "db.hello().setName"'

# every search index per collection: "search" ones are TEXT_INDEX candidates,
# "vectorSearch" ones are for later
oc exec -n $NS deploy/mongot-gui -- sh -c 'mongosh "$MONGO_URI" --quiet --eval "
db.getMongo().getDBNames().filter(d => ![\"admin\",\"local\",\"config\"].includes(d)).forEach(d =>
  db.getSiblingDB(d).getCollectionNames().forEach(c => { try {
    db.getSiblingDB(d)[c].getSearchIndexes().forEach(i =>
      print(d+\".\"+c, i.name, i.type || \"search\", i.status)) } catch(e) {} }))"'
```

Then rerun step 3 with the right `replicaSet`, `DB`, `COLL` and `TEXT_INDEX`.

**6. Verify**

```bash
curl -sk "https://$(oc get route mongot-gui -n $NS -o jsonpath='{.spec.host}')/healthz"   # ok
```

Open the Route and run a text search; the "which mongot answered" panel should rotate
across the pods.

**Tested on this repo's lab (2026-09-28)**, whose `mongodb-poc` namespace also has an
`ent-trust-bundle` (two roots) and whose mongod certificate is signed by one of them:

| Check | Result |
|---|---|
| step 4 mount | `/etc/mongo-ca/ca.crt` in the pod, read-only, both roots |
| `deploy.sh` rerun after step 4 | the `mongo-ca` volume is kept |
| GUI search with `tls=true&tlsCAFile=…` | results returned, pod attribution shown |
| mongod `serverStatus().transportSecurity` | +6 TLS connections during one GUI search, 0 over an idle window |
| same query from the pod **without** `tlsCAFile` | `MongoNetworkError: self-signed certificate in certificate chain` |

`mongosh` also prints `EACCES: permission denied, mkdir '/data/db/.mongodb'` — it cannot
save its history as the non-root pod user; queries are unaffected.

**Before relying on it:** `mongotUser` is mongot's replication identity. Beyond a smoke
test, use a dedicated user with `read` on the searched database only — sharing it means a
GUI leak exposes mongot's credentials, and rotating one breaks the other.

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
