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
  https://github.com/ephico2real2/mongodb-poc/releases/download/mongodb-search-helm-0.2.0/mongodb-search-helm-0.2.0.tgz \
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

The chart ships one dashboard, **MongoDB Search**, in two forms from one source. Its four sections each answer a question: is search up, is traffic spread across the mongot pods, is Envoy healthy, and how is each mongot pod doing.

The captures below were taken on 2026-10-06 with the lab's data, read through Thanos Querier as the console reads it, a few minutes after searches started through the lab's search GUI. Click an image to open it full size. The dark captures are beside them in [`docs/screenshots/`](../../docs/screenshots/).

### Perses, in the OpenShift console

On by default (`monitoring.persesDashboard.enabled`). In the console it is under **Observe → Dashboards (Perses)**, in the release's project.

<!-- markdownlint-disable MD033 -->
<img alt="The MongoDB Search dashboard in Perses 0.54.0, last 15 minutes, in four sections, with no warning sign on any panel. Is search up: 3 mongot pods up, 2 Envoy pods up, 3 mongot pods in Envoy, 0.23 searches per second, largest share on one pod 33 percent. Is traffic spread: three per-pod lines that rise together once searches start, each near a third. Is Envoy healthy: all requests on one Envoy pod, one open connection from mongod on that pod, no retries, only 2xx responses, 95th percentile latency of 3 to 5 milliseconds. How is each mongot pod doing: average search latency of 4 to 5 milliseconds, no failures, no replication lag, JVM memory per pod." src="../../docs/screenshots/dashboard-perses.light.png">
<!-- markdownlint-enable MD033 -->

*The dashboard as the chart renders it, in Perses 0.54.0, the Perses version of the lab's Cluster Observability Operator. Captured in a local Perses of that version reading the lab's Thanos Querier; the page inside the OpenShift console was not captured. The retries and responses panels start at 16:02 because the chart had just begun scraping those two counters under their new names ([Envoy counters](#envoy-counters-without-_total)).*

### Grafana

Off by default (`monitoring.grafanaDashboard`). The chart ships it as a ConfigMap labelled `grafana_dashboard: "1"`, for a Grafana dashboard sidecar.

<!-- markdownlint-disable MD033 -->
<img alt="The MongoDB Search dashboard in Grafana 13.2.3, last 15 minutes, in four sections, with no warning sign on any panel. Is search up: 3 mongot pods up, 2 Envoy pods up, 3 mongot pods in Envoy, 0.30 searches per second, largest share on one pod 35 percent. Is traffic spread: three per-pod lines that rise together once searches start, their shares settling near a third. Is Envoy healthy: all requests on one Envoy pod, one open connection from mongod on that pod, no retries, only 2xx responses, 95th percentile latency falling from 8 to 3 milliseconds. How is each mongot pod doing: average search latency settling near 4 milliseconds, no failures, no replication lag, JVM memory per pod." src="../../docs/screenshots/dashboard-grafana.light.png">
<!-- markdownlint-enable MD033 -->

*The dashboard as the chart's ConfigMap carries it, loaded from a file by a local Grafana 13.2.3 reading the lab's Thanos Querier.*

How the Perses form is generated from the Grafana one, and how both were validated, is in [`docs/grafana-to-perses-conversion.md`](../../docs/grafana-to-perses-conversion.md).

### Envoy counters without `_total`

Envoy exports `envoy_cluster_upstream_rq_retry` and `envoy_cluster_upstream_rq_xx` as counters (Prometheus records their type as `counter`), but without the `_total` that Prometheus expects at the end of a counter's name. `rate()` on such a name is answered with the notice *metric might not be a counter, name does not end in _total/_sum/_count/_bucket*. Thanos Querier returns that notice as a warning, and Perses and Grafana put a warning sign on the panel.

The chart's Envoy ServiceMonitor therefore renames the two at the scrape, to `envoy_cluster_upstream_rq_retry_total` and `envoy_cluster_upstream_rq_xx_total`. The two dashboard panels and the `MongotEnvoyRetriesElevated` alert use those names. What follows from that:

- with Envoy scraped by anything else (for example the hand-applied [`manifests/90-servicemonitors.yaml`](../../manifests/90-servicemonitors.yaml)), the retries and responses panels are empty and that alert never fires;
- on an upgrade from a release without the rename, those two panels start again from the upgrade: the earlier samples stay under the old names.

Measured on the lab on 2026-10-06, through Thanos Querier: before, each of the two queries came back with one warning; after, all 16 of the dashboard's queries came back with none.

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
