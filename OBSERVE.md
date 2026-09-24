# Seeing request distribution to the `mongot` pods

Three ways to watch traffic reach the search pods, from a live graph down to individual
requests. Use the graph to monitor, the access log to debug.

---

## 1. The console graph (best for watching)

<!-- markdownlint-disable MD033 -->
<img alt="OpenShift console Metrics view showing three overlapping lines at roughly 7 requests per second, one per mongot pod, with a table reading mongot-search-0-0 7.62, -0-1 7.16, -0-2 7.06." src="docs/screenshots/console-metrics-distribution.jpg">
<!-- markdownlint-enable MD033 -->

```text
mongot-search-0-0   7.62 req/s
mongot-search-0-1   7.16 req/s      three lines, one per pod, essentially superimposed
mongot-search-0-2   7.06 req/s
```

**Three lines sitting on top of each other is the proof.** One line carrying everything
while two sit at zero is the [L4 bypass](README.md#the-failure-that-produces-no-error).

**Open it directly** — CRC, already URL-encoded:

```text
https://console-openshift-console.apps-crc.testing/monitoring/query-browser?query0=sum%20by%20%28pod%29%20%28rate%28mongot_command_searchCommandTotalLatency_seconds_count%5B2m%5D%29%29
```

Or: **Observe → Metrics**, then paste:

```promql
sum by (pod) (rate(mongot_command_searchCommandTotalLatency_seconds_count[2m]))
```

### Queries worth keeping

| What | Query |
|---|---|
| text search rate per pod | `sum by (pod) (rate(mongot_command_searchCommandTotalLatency_seconds_count[2m]))` |
| **vector** search rate per pod | `sum by (pod) (rate(mongot_command_vectorSearchCommandTotalLatency_seconds_count[2m]))` |
| share of total per pod | `sum by (pod) (rate(mongot_command_searchCommandTotalLatency_seconds_count[2m])) / ignoring(pod) group_left sum(rate(mongot_command_searchCommandTotalLatency_seconds_count[2m]))` |
| Envoy → `mongot` request rate | `sum(rate(envoy_cluster_upstream_rq_total{envoy_cluster_name="mongot_rs_cluster"}[2m]))` |
| Envoy retries (load shedding) | `sum(rate(envoy_cluster_upstream_rq_retry[2m]))` |
| Envoy upstream errors | `sum(rate(envoy_cluster_upstream_rq_xx{envoy_response_code_class!="2"}[2m]))` |

> **`mongot` counts text and vector queries separately.** A text-only query shows `0` for
> a pure vector workload, which reads as "nothing is being served". Use the matching
> metric.

---

## 2. Setting it up

User-workload monitoring must be on. On CRC it already is; elsewhere:

```bash
oc -n openshift-monitoring get cm cluster-monitoring-config -o jsonpath='{.data.config\.yaml}'
#   enableUserWorkload: true
```

Then apply the scrape configuration:

```bash
oc apply -f manifests/90-servicemonitors.yaml
```

Two `ServiceMonitor`s — `mongot` on port `prometheus` (9946) and `mongot-envoy` on port
`admin` (9901, path `/stats/prometheus`). Confirm all five targets come up:

```bash
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  sh -c 'curl -s "http://localhost:9090/api/v1/targets?state=active"' \
  | python3 -c "
import sys,json;d=json.load(sys.stdin)
for t in d['data']['activeTargets']:
    if t['labels'].get('namespace')=='mongodb-poc':
        print(t['labels'].get('pod'), t['labels'].get('endpoint'), t['health'])"
```

```text
mongot-search-lb-0-...-5r4qg  admin       up        <- Envoy
mongot-search-lb-0-...-v5ffh  admin       up        <- Envoy
mongot-search-0-0             prometheus  up
mongot-search-0-1             prometheus  up
mongot-search-0-2             prometheus  up
```

**Allow ~2 minutes.** The operator writes the scrape config into a Secret promptly, but
Prometheus reloads on its own cycle — targets read `0` for a while and that is not a
fault. Check the Secret to tell "not yet" from "never":

```bash
oc get secret prometheus-user-workload -n openshift-user-workload-monitoring \
  -o jsonpath='{.data.prometheus\.yaml\.gz}' | base64 -d | gunzip | grep -c mongodb-poc
#   non-zero => config generated, Prometheus simply has not reloaded yet
```

> **Envoy does not block the scrape.** MCK restricts its admin listener to `/stats`,
> `/ready`, `/logging` and `/drain_listeners`, but that is a **prefix** match, so
> `/stats/prometheus` returns 200. Verified from the monitoring namespace:
> `mongot-envoy-stats.mongodb-poc:9901/stats/prometheus → http=200`. There are no
> NetworkPolicies in the namespace either.

---

## 3. The Envoy access log (best for debugging)

One record **per request**, each carrying the `mongot` that served it. This is the only
instrument that shows per-request *ordering* — the counters give totals, not sequence.

```bash
# only ONE Envoy replica carries the connection; find it, then read it
for p in $(oc get pods -n mongodb-poc -l app=mongot-search-lb-0 -o name); do
  echo "$p: $(oc logs -n mongodb-poc $p | grep -c '"logger":"access"')"
done

oc logs -n mongodb-poc <the-busy-pod> | grep '"logger":"access"' \
  | grep -o 'upstream=[0-9.]*' | sort | uniq -c
```

```text
  14 upstream=10.217.1.38
  13 upstream=10.217.1.36
  13 upstream=10.217.1.37
```

Map an IP to a pod with:

```bash
oc get pods -n mongodb-poc -l app=mongot-search-0-svc -o custom-columns=NAME:.metadata.name,IP:.status.podIP
```

**Do not aggregate with `-l app=mongot-search-lb-0`** — that mixes in the idle replica,
which has `downstream_cx_total: 0` for its entire life.

Each record also carries `grpc_status`, `duration_ms`, `response_flags` and a
`client_id` that matches `mongod`'s own `attr.session.clientId`, so a slow query can be
joined across both sides without time-guessing.

---

## 4. The script (best for a one-off check)

```bash
cd mongodb && ./scripts/verify-search.sh
```

Snapshots each pod's counter before and after a fixed number of queries and prints the
delta, so the result is attributable to that run rather than to history.

---

## Which to use

| Question | Use |
|---|---|
| Is traffic spread right now? | the console graph (§1) |
| Which pod served *this* query? | the access log (§3) |
| Did my change break distribution? | `verify-search.sh` (§4) |
| Is Envoy retrying / shedding load? | `envoy_cluster_upstream_rq_retry` (§1) |

**One counter to distrust:** `upstream_cx_active` is not a health signal. The cluster's
`idle_timeout` is 300s, so between bursts it is legitimately **0**. Values of 0, 2, 3 and
6 have all been observed on a healthy system.
