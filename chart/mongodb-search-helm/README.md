# mongodb-search-helm

MongoDB Search (mongot) behind the operator-managed Envoy on OpenShift, from one values file.

The chart replaces Steps 6a, 6b and 6d of the
[fresh install runbook](../../docs/mongot-envoy-mtls-fresh-install-runbook.md) and adds the operator install.
Steps 1 to 5 of the runbook stay manual: the chart never creates a certificate, a secret or the trust bundle.

## What it does

| Order | Object | What for |
| --- | --- | --- |
| before anything | preflight Job | Fails the install if a hand-made secret or the trust bundle is missing |
| 1 | OperatorGroup, Subscription | The MongoDB operator through OLM, on Manual approval, pinned to `operator.version` |
| 1 | MongoDBSearch | The resource of runbook Step 6a |
| 1 | Route | The passthrough Route of runbook Step 6d, with `balance: roundrobin` |
| 1 | ServiceMonitors | Per-pod scraping of mongot and Envoy; on by default |
| 1 | Alerts | Four alerts on traffic distribution and retries; on by default |
| 1 | Dashboard | "MongoDB Search" for Perses in the OpenShift console, on by default; the Grafana copy is off by default |
| 2 | csv-reclaim Job | Clears an operator CSV left behind by an earlier uninstall |
| 3 | approver Job | Approves the InstallPlan for `operator.version`, and no other |
| 4 | gate Job | Returns only when the operator, mongot, Envoy and the Route are ready |

## Install

The step-by-step procedure, from creating the five prerequisite objects by hand to installing, upgrading and
removing the chart, is in [`docs/prerequisite-and-setup-doc.md`](../../docs/prerequisite-and-setup-doc.md).

In short, once the prerequisites exist in the namespace, install the published package (no clone needed):

```bash
helm install mongot \
  https://github.com/ephico2real2/mongodb-poc/releases/download/mongodb-search-helm-0.3.0/mongodb-search-helm-0.3.0.tgz \
  -n dvh-gp6-rnd -f my-values.yaml --timeout 20m
```

Or from a checkout of this repository:

```bash
helm install mongot chart/mongodb-search-helm -n dvh-gp6-rnd \
  -f chart/mongodb-search-helm/examples/values-dvh-gp6-rnd.yaml --timeout 20m
```

Each chart version is published as a GitHub release named `mongodb-search-helm-<version>`, with the package attached.

## Values

| Value | Default | Runbook |
| --- | --- | --- |
| `namespace` | empty: the namespace given with `-n` | Where every object goes; it must hold the prerequisites |
| `operator.install` | `true` | `false` when an operator already serves the namespace |
| `operator.version` | `1.13.0` | The only version the approver approves |
| `operator.channel`, `.package`, `.source`, `.sourceNamespace` | `stable`, `mongodb-kubernetes`, `certified-operators`, `openshift-marketplace` | |
| `operatorGroup.create` | `true` | `false` when the namespace already has an OperatorGroup |
| `search.name` | `mongot` | Step 6a, `metadata.name` |
| `search.version` | empty | mongot follows the operator's default; set it to pin mongot |
| `search.replicas` | `3` | Step 6a |
| `search.resources` | 1 CPU / 3Gi to 3 CPU / 5Gi | Step 6a |
| `search.persistence.storage`, `.storageClass` | `10Gi`, `thin-csi` | Step 6a |
| `search.keepOnUninstall` | `false` | Keeps the resource, and so the index, on `helm uninstall` |
| `loadBalancer.externalHostname` | required | Step 6a; also the Route's host |
| `loadBalancer.replicas` | `2` | Step 6a |
| `loadBalancer.retryPolicy` | 2 retries, `60s` per try | Step 6a |
| `loadBalancer.image` | empty | Step 6a, the Envoy image override |
| `tls.certsSecretPrefix` | `ent` | Overview, the secret naming rule |
| `tls.trustBundleConfigMap` | `ent-trust-bundle` | Step 4 |
| `source.hostAndPorts` | required | Step 6a |
| `source.username` | `mongotUser` | Step 6a |
| `source.passwordSecret.name`, `.key` | `search-sync-source-password`, `password` | Step 5 |
| `observability.*` | Prometheus on 9946, forwarder `auto` | Step 6a |
| `route.enabled`, `.name` | `true`, `mongot-search` | Step 6d |
| `route.serviceName` | empty: `<search.name>-search-0-proxy-svc` | Step 6d |
| `route.targetPort` | `mongot-grpc` | Step 6d |
| `route.balance` | `roundrobin` | Step 6d; see the [rationale](../../docs/mongot-route-balance-rationale.md) |
| `monitoring.serviceMonitors.enabled` | `true` | Per-pod scraping of mongot and Envoy; needs user workload monitoring |
| `monitoring.alerts.enabled` | `true` | Alerts when traffic concentrates on one mongot pod |
| `monitoring.persesDashboard.enabled`, `.thanosURL` | `true`, Thanos Querier port 9091 | The "MongoDB Search" dashboard in the console; set it to `false` on a cluster without the Cluster Observability Operator |
| `monitoring.grafanaDashboard` | `false` | The same dashboard as a ConfigMap for a Grafana dashboard sidecar |
| `preflight.enabled` | `true` | |
| `installPlanApprover.waitSeconds`, `csvReclaim.*`, `wait.*`, `jobs.*` | see `values.yaml` | |

`values.schema.json` refuses an unknown key, an IP address as hostname and a source without a port.

## Dashboards

The chart ships one dashboard, **MongoDB Search**, in two forms from one source. Its five sections each answer a question: is search up, is traffic spread across the mongot pods, is Envoy healthy, how is each mongot pod doing, and does every mongot pod hold the same data. It has 27 panels; the last eleven, about mongot's process and its data, are [described below](#the-mongot-process-and-data-panels).

The captures below were taken on the lab on 2026-10-06, a few minutes after searches started through the lab's search GUI. Click an image to open it full size. The dark captures, and earlier ones from a Perses and a Grafana run on a workstation, are beside them in [`docs/screenshots/`](../../docs/screenshots/).

### Perses, in the OpenShift console

On by default (`monitoring.persesDashboard.enabled`). In the console it is under **Observe → Dashboards (Perses)**, in the release's project.

<!-- markdownlint-disable MD033 -->
<img alt="The OpenShift console, logged in as developer, project mongodb-poc, Dashboards, dashboard MongoDB Search, last 15 minutes, in five sections, with no warning sign on any panel. Is search up: 3 mongot pods up, 2 Envoy pods up, 3 mongot pods in Envoy, 0.54 searches per second, largest share on one pod 33 percent. Is traffic spread: three per-pod lines that rise together once searches start, each share near a third. Is Envoy healthy: all requests on one Envoy pod, one open connection from mongod on that pod, no retries, only 2xx responses, 95th percentile latency of 3 to 4.5 milliseconds. How is each mongot pod doing: average search latency of 5 to 9 milliseconds, no failures, replication lag readings of 4 and 9 seconds on two pods, JVM memory per pod, CPU of 2 to 6 percent, heap at 15 to 45 percent of its limit, about 0.1 percent of time in garbage collection, uptime near 5.6 hours on every pod, and no search work run outside the parallel pool. Does every mongot pod hold the same data: one flat line for all three pods in each panel, index size 4.6 MiB, 40 thousand documents, 0 indexes not STEADY, 5 indexes in the catalog, the data volume 82.5 percent used, and no indexing operations." src="../../docs/screenshots/dashboard-console.light.png">
<!-- markdownlint-enable MD033 -->

*The dashboard in the lab's own OpenShift console (4.22.7, Cluster Observability Operator 1.5.3), opened by [`scripts/capture-console-dashboard.py`](../../scripts/capture-console-dashboard.py) as the lab's `developer` user, who held only the roles below.*

**Who can see it.** Measured with that user: before the roles below, the API refused it the dashboard (`oc auth can-i get persesdashboards`: `no`); with them, every panel drew. The three namespace roles were given together; whether fewer would do was not measured.

| To | The viewer held | Where it comes from |
| --- | --- | --- |
| Open the project and the dashboard | `view`, `persesdashboard-viewer-role` and `persesdatasource-viewer-role` in the release's namespace | RoleBindings you create; the two Perses roles are ClusterRoles of the Cluster Observability Operator. The chart creates no RoleBinding |
| See the data | `cluster-monitoring-view` | The platform; the data source is Thanos Querier on port 9091, which checks it |

```bash
for role in view persesdashboard-viewer-role persesdatasource-viewer-role; do
  oc create rolebinding "search-dashboard-$role" -n <namespace> --clusterrole="$role" --group=<team>
done
```

### Grafana

Off by default (`monitoring.grafanaDashboard`). The chart ships it as a ConfigMap labelled `grafana_dashboard: "1"`, for a Grafana dashboard sidecar that watches the release's namespace.

<!-- markdownlint-disable MD033 -->
<img alt="The MongoDB Search dashboard in a Grafana 12.3.1 running in the lab namespace, data source Thanos Querier, last 15 minutes, in five sections, with no warning sign on any panel. Is search up: 3 mongot pods up, 2 Envoy pods up, 3 mongot pods in Envoy, 0.54 searches per second, largest share on one pod 34 percent. Is traffic spread: three per-pod lines that rise together once searches start, their shares settling between 32 and 34 percent. Is Envoy healthy: all requests on one Envoy pod, one open connection from mongod on that pod, no retries, only 2xx responses, 95th percentile latency of 3 to 4.5 milliseconds. How is each mongot pod doing: average search latency of 5 to 9 milliseconds, no failures, replication lag readings of 4 and 9 seconds on two pods, JVM memory per pod, CPU of 2 to 6 percent, heap at 15 to 45 percent of its limit, about 0.1 percent of time in garbage collection, uptime near 5.6 hours on every pod, and no search work run outside the parallel pool. Does every mongot pod hold the same data: one flat line for all three pods in each panel, index size 4.6 MiB, 40 thousand documents, 0 indexes not STEADY, 5 indexes in the catalog, the data volume 82.5 percent used, and no indexing operations." src="../../docs/screenshots/dashboard-grafana-sidecar.light.png">
<!-- markdownlint-enable MD033 -->

*The chart's ConfigMap, loaded by the dashboard sidecar of a Grafana installed in the lab namespace for this measurement and removed afterwards (the Grafana Helm chart 10.5.15, Grafana 12.3.1, sidecar 2.5.0; [`test/grafana-sidecar/`](../../test/grafana-sidecar/)). Measured when the dashboard had 16 panels: the Grafana held no such dashboard before `monitoring.grafanaDashboard=true`, and 37 s after that upgrade started the sidecar had written the file and Grafana listed it. Measured again with the 27 panels shown here: listed with 27 panels in 5 rows, and all 27 queries answered through its Thanos Querier data source.*

Two things that Grafana needed, which the chart does not provide: a Prometheus data source (the dashboard takes the default one; here Thanos Querier on port 9091 with the Grafana pod's own token), and a Role that lets the sidecar read ConfigMaps. The Grafana Helm chart's own Role also lets it read every Secret in the namespace; `test/grafana-sidecar/` replaces it with one for ConfigMaps only.

How the Perses form is generated from the Grafana one, and how both were validated, is in [`docs/grafana-to-perses-conversion.md`](../../docs/grafana-to-perses-conversion.md).

### The mongot process and data panels

Eleven panels read mongot's own metrics, one line per mongot pod. Readings are the lab's, on 2026-10-06, pod 0 / 1 / 2.

| Panel | What it reads | Lab reading |
| --- | --- | --- |
| CPU used | `mongot_process_cpu_usage`, 5 minute average: a share of the CPUs the process sees (`mongot_system_cpu_count`, 1 on the lab, the pod's CPU limit) | 4.8% / 3.1% / 3.3% |
| JVM heap used, percent of limit | Heap used over the heap's maximum | 16% / 27% / 37% of 495 MiB |
| Time in garbage collection | Rate of `mongot_jvm_gc_pause_seconds_sum`: the share of time paused | 0.05% / 0.05% / 0.06% |
| Uptime | `mongot_process_uptime_seconds`; a fall to zero is a restart | 5.7 h on each |
| Search work run outside the parallel pool | Rate of `mongot_rejectedConcurrentSearchExecutionCount_total` and its vector rescoring twin | 0 / 0 / 0 |
| Index size | `mongot_index_stats_indexSizeBytes`, all indexes | 4,808,700 bytes on each |
| Documents indexed | `mongot_index_stats_numLuceneDocs`, all indexes | 40,093 on each |
| Indexes not STEADY | `mongot_index_stats_indexStatusCode` for every state but `STEADY` | 0 / 0 / 0 |
| Indexes in catalog | `mongot_configState_indexesInCatalog` | 5 / 5 / 5 |
| Data volume used | `mongot_system_disk_space_data_path_free_bytes` and `_total_bytes` | 82.5% on each |
| Indexing operations per second | Rate of inserts, updates and deletes applied to the indexes | 0 / 0 / 0 |

What to know when reading them:

- **They show that every pod holds the same data, not how queries are spread.** Every mongot pod holds every index (the lab's three pods each report the same five). The second section shows the spread of queries.
- **Documents indexed is the strict comparison; index size is a loose one.** On the lab both are equal on every pod, with no update, delete or merge recorded. Each pod writes and merges its own index files, so sizes on a busy cluster are expected to differ somewhat; that was not measured.
- **Data volume used is the file system under mongot's data path.** With a volume of its own per pod, that is the volume. The lab's storage class is a hostpath provisioner, so there it is the node's disk: 160.5 GB in total and 82.5% used on every pod, while each pod's data takes about 18 MiB.
- **The pool panel does not count refused searches.** mongot's source gives the counter to a caller-runs policy: when the concurrent search pool is full the work runs on the calling thread, and the search is still answered. Above zero, the pool is saturated.
- **The heap limit is the JVM's, not the pod's.** On the lab it is 495 MiB, a quarter of the pod's 2 Gi memory limit. The older *JVM memory used* panel shows heap and non-heap together, in bytes.
- **Not seen on the lab:** an index out of `STEADY`, indexing activity, and work outside the pool. Those three panels were flat at zero throughout; their queries answer, and what they look like in trouble was not observed.

### Envoy counters without `_total`

Envoy exports `envoy_cluster_upstream_rq_retry` and `envoy_cluster_upstream_rq_xx` as counters (Prometheus records their type as `counter`), but without the `_total` that Prometheus expects at the end of a counter's name. `rate()` on such a name is answered with the notice *metric might not be a counter, name does not end in _total/_sum/_count/_bucket*. Thanos Querier returns that notice as a warning, and Perses and Grafana put a warning sign on the panel.

The chart's Envoy ServiceMonitor therefore renames the two at the scrape, to `envoy_cluster_upstream_rq_retry_total` and `envoy_cluster_upstream_rq_xx_total`. The two dashboard panels and the `MongotEnvoyRetriesElevated` alert use those names. What follows from that:

- with Envoy scraped by anything else (for example the hand-applied [`manifests/90-servicemonitors.yaml`](../../manifests/90-servicemonitors.yaml)), the retries and responses panels are empty and that alert never fires;
- on an upgrade from a release without the rename, those two panels start again from the upgrade: the earlier samples stay under the old names.

Measured on the lab on 2026-10-06, through Thanos Querier: before, each of the two queries came back with one warning; after, every query of the dashboard came back with none (16 queries then; 27 since chart 0.3.0).

## Maintaining the chart

The dashboard has one source, `files/mongodb-search.json` (Grafana). After changing it, run
`scripts/perses-dashboard.sh` to regenerate `files/mongodb-search.perses.json`; never edit that file by hand.
The script uses `percli` 0.54.0 from the PATH, or from the official Perses image with podman or docker. The commands, step by step,
are in [`docs/grafana-to-perses-conversion.md`](../../docs/grafana-to-perses-conversion.md).

When you change `operator.version`, change `appVersion` in `Chart.yaml` to match and run
`scripts/refresh-mongodbsearch-crd.sh` against a cluster on that version.

## Argo CD

Every hook also carries Argo CD annotations, and [`examples/argocd-application.yaml`](examples/argocd-application.yaml)
shows an Application. It sets `skipCrds: true`, so Argo CD never owns a CRD that OLM manages. Not run in the lab.

## Tests

```bash
test/chart.sh        # no cluster: lint, renders, the runbook comparison, schema refusals, the Jobs' scripts
```

## Tested

Installed, reinstalled and searched end to end on CRC on 2026-10-06. The runs, the timings and what was not tested
are in [`docs/prerequisite-and-setup-doc.md`](../../docs/prerequisite-and-setup-doc.md#tested-on-crc).
