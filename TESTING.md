# Testing guide — from sample data to a proven load balance

How to load data, run text and vector search, and **prove Envoy distributes queries
across every `mongot`** rather than quietly serving them all from one pod.

That last part is the point. A deployment with the load balancing silently broken passes
every health check: queries succeed, pods are Ready, the Service reports three healthy
endpoints. Only measurement distinguishes it from a working one.

**Prerequisites:** the stack from [README.md](README.md) deployed and
`MongoDBSearch` at `phase=Running`, with the external replica set reachable.

| Script / manifest | Does |
|---|---|
| `mongodb/scripts/load-data.sh` | loads the documents and both search indexes |
| `mongodb/scripts/verify-search.sh` | runs the queries and measures distribution |
| `manifests/50-envoy-stats-service.yaml` | exposes Envoy's admin port, **ClusterIP only** |
| `manifests/60-toolbox.yaml` | the in-cluster pod all observation runs from |

**Observation happens inside the cluster.** Everything is addressed by Service and
StatefulSet DNS from a toolbox pod — no `port-forward`, no local tooling. That matters
because `port-forward` is restricted in many clusters, and because it exercises the same
DNS a real client would use.

```bash
oc apply -f manifests/50-envoy-stats-service.yaml
oc apply -f manifests/60-toolbox.yaml
oc rollout status deploy/mongot-toolbox -n mongodb-poc
```

---


## The test suite

```bash
./test/run.sh                  # every suite
./test/run.sh search           # one suite
SKIP_DISTRIBUTION=1 ./test/run.sh
```

Suites: `platform`, `data`, `search`, `entry`, `attribution`, `alerts`, `distribution`, `tls`.
Exit 0 means every assertion passed; exit 1 lists the failures by name. Skips never fail a run,
so the suite degrades cleanly when an optional piece (the toolbox pod, Thanos) is absent.

```text
── entry path ──────────────────────────────────────
  PASS  every mongod agrees on mongotHost                    1
  PASS  mongod requires TLS to the search head               requireTLS
  PASS  entry path identified                                OpenShift Route (2 established router->Envoy)
  PASS  the Route is passthrough (edge/reencrypt break HTTP/2) passthrough
  PASS  HAProxy load-balances the passthrough backend by source balance source

── per-request attribution ──────────────────────────────────────
  PASS  at least one Envoy is logging requests               1 busy / 1 idle
  PASS  all 3 pods appear in a 6-query census                3
  PASS  no non-OK gRPC status in the last 10m                0

────────────────────────────────────────────────────────
  61 passed   0 failed   0 skipped
```

### What each suite is actually guarding

| Suite | The failure it catches |
|---|---|
| `platform` | the entry Service pointed at the **mongot** pods instead of Envoy — the silent L7 bypass |
| `data` | a corpus that loaded but whose indexes never became `queryable` |
| `search` | recall regressions, and filters that are silently ignored rather than applied |
| `entry` | the replica set disagreeing on `mongotHost`; a Route flipped off `passthrough` or given key material; TLS silently moving off the operator-owned Envoy; the ingress wildcard being served instead of the enterprise certificate; a non-matching SNI quietly accepted |
| `attribution` | one pod serving everything while all three report Ready |
| `alerts` | a `PrometheusRule` that was applied but never loaded |
| `distribution` | round robin degrading to a single pod under load |
| `tls` | the coupling defect — Envoy cert volumes silently not mounted |

Two assertions encode findings that cost real debugging time:

- **`source CA set (Envoy cert mounts depend on it)`** — the operator gates Envoy's
  certificate volumes on `spec.source.external.tls.ca`. Set `security.tls` without it and
  the pods come up healthy with no certificates mounted.
- **`mongotHost is a hostname, not an IP`** — TLS clients send no SNI for an IP literal, so
  a passthrough Route cannot pick a backend and the path fails at the handshake.

### A note on where alerting rules live

In OpenShift user-workload monitoring a user-namespace `PrometheusRule` is evaluated by
**Thanos Ruler**, *not* by `prometheus-user-workload`, unless it carries the label
`openshift.io/prometheus-rule-evaluation-scope: leaf-prometheus`. Both components'
`ruleSelector` match expressions say so explicitly. Querying the wrong one reports a
perfectly healthy rule group as missing — the `alerts` suite queries Thanos Ruler.


## Step 1 — the sample data

`mongodb/data/` holds five `sample_mflix`-shaped documents, after MongoDB's dev.to
walkthrough *"My first local vector search: MongoDB Community Edition"*.

**One deliberate departure from the article.** It uses Voyage AI `autoEmbed`, which needs
an API key and outbound HTTPS from every `mongot` pod. These documents carry explicit
5-dimension vectors instead, so the test is self-contained, deterministic and free.

```json
{ "_id": 1, "title": "The Karate Kid", "year": 1984, "genre": "drama",
  "plot": "A bullied boy learns karate from a wise handyman.",
  "plot_embedding": [0.9, 0.1, 0.0, 0.1, 0.0] }
```

They are **not real embeddings**. They are positioned so nearest-neighbour ordering is
predictable and assertable — enough to prove the vector path end to end, not to say
anything about semantic quality.

Two index definitions sit in `mongodb/data/indexes/`:

```json
// default.json - full text
{ "name": "default", "type": "search",
  "definition": { "mappings": { "dynamic": true } } }

// vector_index.json - vector, plus a filter field
{ "name": "vector_index", "type": "vectorSearch",
  "definition": { "fields": [
    { "type": "vector", "path": "plot_embedding", "numDimensions": 5, "similarity": "cosine" },
    { "type": "filter", "path": "year" } ] } }
```

---

## Step 2 — load it

```bash
cd mongodb && ./scripts/load-data.sh
```

```text
documents loaded: 5
index requested: default (search)
index requested: vector_index (vectorSearch)
waiting for indexes to become queryable...
QUERYABLE: default, vector_index
```

**This step is already a test of the whole path.** Index creation is not local: `mongod`
forwards it to `searchIndexManagementHostAndPort`, which is the load-balancer endpoint.
So the call traverses VIP → Service → Envoy → `mongot` exactly as a query does. If
`load-data.sh` reaches `QUERYABLE`, the control path works.

If it stops at `TIMEOUT`, the indexes were accepted but never became queryable — that is
a `mongot` → `mongod` **sync** problem, not a query-path problem. Check
`oc logs mongot-search-0-0 -n mongodb-poc | grep -i auth`.

---

## Step 3 — query it

```bash
./scripts/verify-search.sh
```

### Text search

```text
PASS  $search "karate" -> The Karate Kid  score=1.119
```

### Vector search

```text
PASS  The Karate Kid   score=1.0000
PASS  Rocky            score=0.9889
PASS  Field of Dreams  score=0.6598
```

The ordering is the assertion. Querying with the Karate Kid vector returns it first,
then *Rocky* — the other underdog-sports document — then *Field of Dreams*. The
thrillers (*Jaws*, *Alien*) fall outside `limit: 3`. Ordering that changes means the
vector path is wrong even when results are returned.

---

## Step 4 — validate the distribution

This is the step that distinguishes a working L7 from a silently broken one.

The script snapshots each `mongot`'s own counter **before** and **after**, so the delta
belongs to this run rather than to whatever the pods did earlier:

```text
=== 3. snapshot counters BEFORE ===
  mongot-search-0-0    13
  mongot-search-0-1    15
  mongot-search-0-2    14

=== 4. issuing 40 queries ===

=== 5. distribution (delta per mongot) ===
  mongot-search-0-0     14  ##############
  mongot-search-0-1     13  #############
  mongot-search-0-2     13  #############
  ------------------------------------------
  TOTAL                 40
  PASS  every query accounted for

=== 6. Envoy's own view ===
  mongot-search-lb-0-...-kt2cx   upstream_rq_total=126   upstream_cx_active=3
  mongot-search-lb-0-...-zcjxr   upstream_rq_total=16    upstream_cx_active=3
```

**What this proves.** `mongod` holds **one** connection to the endpoint, and those 40
requests reached **three** pods. Distribution is therefore **per request**, not per
connection, which is what an L7 proxy provides. `upstream_cx_active=3`
on each Envoy confirms a live connection to every `mongot`.

**What a broken deployment looks like:**

```text
  mongot-search-0-0     40  ####...####
  mongot-search-0-1      0
  mongot-search-0-2      0
```

All queries still succeed. Nothing errors. This is the failure the
[L4 bypass](README.md#the-failure-that-produces-no-error) produces — usually because the
entry Service selector points at the `mongot` pods rather than `app=<name>-search-lb-<idx>`.

---

## Step 5 — reading the numbers correctly

Three things will mislead you.

**1. Use the access log — but scrape the POD, not the Service.** Envoy emits one record
**per request**, each carrying `upstream_host`, so it is the best instrument available:
it shows per-request ordering, which the Prometheus counters cannot.

```bash
# per-request distribution, from the pod that carries the connection
oc logs -n mongodb-poc <envoy-pod> | grep '"logger":"access"' \
  | grep -o 'upstream=[0-9.]*' | sort | uniq -c
```

Only one Envoy replica carries the connection; the other reads zero forever. Aggregating
with `-l app=...` mixes an idle pod into the sample.

**2. A single stats scrape shows one Envoy pod.** `mongot-envoy-stats` is a normal
`ClusterIP` Service, so a scrape may land on the idle replica and read zero. Address each
Envoy **pod IP** instead.

**3. `/clusters` returns 403.** MCK restricts Envoy's admin listener to `/stats`,
`/ready`, `/logging` and `/drain_listeners`. Per-endpoint breakdowns are not available
from Envoy — that is why the per-pod truth comes from `mongot`'s own Prometheus
counters on `:9946`.

### Reading the stats from inside the cluster

```bash
TB=$(oc get pods -n mongodb-poc -l app=mongot-toolbox -o jsonpath='{.items[0].metadata.name}')

# Envoy, by Service name
oc exec -n mongodb-poc $TB -- curl -s http://mongot-envoy-stats:9901/stats \
  | grep -E "mongot_rs_cluster\.(upstream_rq_total|upstream_cx_active)"
```

Scrape it three times and the round-robin caveat becomes visible:

```text
scrape 1: upstream_cx_active: 3   upstream_rq_total: 168     <- the Envoy carrying traffic
scrape 2: upstream_cx_active: 0   upstream_rq_total: 16      <- the idle replica
scrape 3: upstream_cx_active: 3   upstream_rq_total: 168
```

A single scrape that lands on the idle replica reads near-zero and looks like a failure.
Sum across replicas, or scrape repeatedly.

Counters worth knowing:

| Stat | Means |
|---|---|
| `upstream_rq_total` | requests this Envoy sent to `mongot` |
| `upstream_cx_active` | live upstream connections **right now** — *not* a health signal. The cluster's `idle_timeout` is 300s, so between bursts this is legitimately **0**. Observed 0, 2, 3 and 6 on a healthy system |
| `upstream_rq_retry` | retries fired, e.g. after `RESOURCE_EXHAUSTED` |
| `upstream_rq_timeout` | requests that hit the 300s route timeout |

### The per-pod counter, by StatefulSet DNS

Each `mongot` is individually addressable, so the breakdown needs no `exec` into each pod:

```bash
oc exec -n mongodb-poc $TB -- sh -c '
for i in 0 1 2; do
  printf "mongot-search-0-$i  "
  curl -s http://mongot-search-0-$i.mongot-search-0-svc:9946/metrics \
    | grep "^mongot_command_searchCommandTotalLatency_seconds_count"
done'
```

```text
mongot-search-0-0.mongot-search-0-svc:9946   41
mongot-search-0-1.mongot-search-0-svc:9946   42
mongot-search-0-2.mongot-search-0-svc:9946   40
```

The headless Service resolves to every pod, which is what lets Envoy fan out:

```bash
oc exec -n mongodb-poc $TB -- getent hosts mongot-search-0-svc
#   10.217.0.253
#   10.217.1.6
#   10.217.1.7
```

## What a healthy deployment looks like

<!-- markdownlint-disable MD033 -->
<img alt="OpenShift console pod list for the mongodb-poc namespace: the MCK operator, three mongot pods, two Envoy replicas and the toolbox, all Running 1/1 with zero restarts." src="docs/screenshots/console-pods.jpg">
<!-- markdownlint-enable MD033 -->

Seven pods, all `Running 1/1`, **zero restarts**:

| Pod | Role |
|---|---|
| `mongodb-kubernetes-operator-*` | MCK |
| `mongot-search-0-0/1/2` | the three `mongot`, StatefulSet-ordinal named |
| `mongot-search-lb-0-*` ×2 | the operator-managed Envoy |
| `mongot-toolbox-*` | in-cluster observation |

### Measured resource usage vs the defaults

`oc adm top pods` on an idle-to-light load:

```text
mongot-search-0-0                      14m   449Mi
mongot-search-0-1                      15m   451Mi
mongot-search-0-2                      15m   440Mi
mongot-search-lb-0-...-kt2cx            4m    25Mi
mongot-search-lb-0-...-zcjxr            4m    23Mi
mongodb-kubernetes-operator-...         1m    34Mi
mongot-toolbox-...                      0m     6Mi
```

Worth knowing before you size a cluster: **`mongot` defaults to 2 CPU / 4 GiB of
*requests* per replica** — three replicas reserve 6 CPU / 12 GiB before anything runs.
Actual usage here is ~**450 MiB and ~15 millicores** each. The gap is enormous at this
data volume, and the default is sized for real corpora, not five documents. Measure
against your own data before either accepting the default or cutting it.

**Envoy is almost free** — ~25 MiB and 4 millicores per replica. There is no resource
argument for running one replica instead of two, and one replica means a rolling restart
severs every in-flight cursor.

---

## Step 6 — failure behaviour worth exercising

| Test | Command | Expected |
|---|---|---|
| `mongot` restart | `oc delete pod mongot-search-0-1 -n mongodb-poc` | new queries keep succeeding; in-flight streams on that pod fail |
| Distribution after restart | re-run `verify-search.sh` | load returns to all three once the pod is Ready |
| Envoy restart | `oc rollout restart deploy/mongot-search-lb-0 -n mongodb-poc` | with `replicas: 2`, absorbed |
| Primary failover | stop the `mongod` holding PRIMARY | election, then queries resume |

**The honest limit:** Envoy retries `RESOURCE_EXHAUSTED` **only when the gRPC status
arrives in response headers**. Once `mongot` has begun streaming a response, a failure
mid-stream is not retryable — `mongod` sees `RST_STREAM` / "Remote error from mongot".
MCK's own access-log comment says as much. Envoy buys you load-shedding resilience and
tolerance for *new* streams, not mid-flight stream survival.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `load-data.sh` hangs before `QUERYABLE` | `mongot` cannot sync — check the SCRAM user has `searchCoordinator` |
| Index created but queries return nothing | index not queryable yet, or the wrong index name in `$search` |
| All queries on one `mongot` | entry Service selector points at `mongot` pods, not `app=<name>-search-lb-<idx>` |
| `AuthenticationFailed` in `mongot` logs | the sync-source Secret and the DB user password disagree |
| Queries fail after enabling TLS | `mongotHost` is an IP — TLS clients send no SNI for IP literals, so no filter chain matches |
| `/clusters` 403 | expected; MCK restricts the admin listener |
