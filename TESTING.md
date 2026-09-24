# Testing guide — from sample data to a proven load balance

How to load data, run text and vector search, and **prove Envoy distributes queries
across every `mongot`** rather than quietly serving them all from one pod.

That last part is the point. A deployment with the load balancing silently broken passes
every health check: queries succeed, pods are Ready, the Service reports three healthy
endpoints. Only measurement distinguishes it from a working one.

**Prerequisites:** the stack from [README.md](README.md) deployed and
`MongoDBSearch` at `phase=Running`, with the external replica set reachable.

| Script | Does |
|---|---|
| `mongodb/scripts/load-data.sh` | loads the documents and both search indexes |
| `mongodb/scripts/verify-search.sh` | runs the queries and measures distribution |

---

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
connection — which is the entire reason an L7 proxy is required. `upstream_cx_active=3`
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

**1. Do not count access-log lines.** Envoy emits **one record per gRPC stream, at stream
close** — not per request. Forty queries over long-lived streams produced **three** log
lines. Counting them under-reports distribution catastrophically.

```bash
# this is NOT a distribution measurement
oc logs -n mongodb-poc -l app=mongot-search-lb-0 | grep -o '"upstream_host":"[^"]*"' | sort | uniq -c
```

**2. A single stats scrape shows one Envoy pod.** `mongot-envoy-stats` is a normal
Service, so it round-robins. Scrape **every** Envoy pod and sum, which
`verify-search.sh` does. A scrape that lands on the idle replica reads zero.

**3. `/clusters` returns 403.** MCK restricts Envoy's admin listener to `/stats`,
`/ready`, `/logging` and `/drain_listeners`. Per-endpoint breakdowns are not available
from Envoy — that is why the per-pod truth comes from `mongot`'s own Prometheus
counters on `:9946`.

### Reaching the stats by hand

`manifests/50-envoy-stats-service.yaml` exposes the admin port as **ClusterIP only**.
Deliberately not a VIP and not a Route: it is still an admin surface.

```bash
oc port-forward -n mongodb-poc svc/mongot-envoy-stats 19901:9901
curl -s localhost:19901/stats | grep -E "mongot_rs_cluster\.(upstream_rq_total|upstream_cx_active)"
curl -s localhost:19901/ready
```

Counters worth knowing:

| Stat | Means |
|---|---|
| `upstream_rq_total` | requests this Envoy sent to `mongot` |
| `upstream_cx_active` | live connections — should equal the `mongot` replica count |
| `upstream_rq_retry` | retries fired, e.g. after `RESOURCE_EXHAUSTED` |
| `upstream_rq_timeout` | requests that hit the 300s route timeout |

### The per-pod counter

```bash
for p in mongot-search-0-0 mongot-search-0-1 mongot-search-0-2; do
  printf "%s " "$p"
  oc exec -n mongodb-poc $p -- curl -s localhost:9946/metrics \
    | grep "^mongot_command_searchCommandTotalLatency_seconds_count"
done
```

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
