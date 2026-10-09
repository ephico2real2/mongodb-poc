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

The step-by-step procedure, from creating the five prerequisite objects to installing, upgrading and
removing the chart, is in [`docs/prerequisite-and-setup-doc.md`](../../docs/prerequisite-and-setup-doc.md).

### The prerequisites script

`generate-mongodbsearch-prerequisites.sh`, in this directory and so in the package (0.3.3 and later), makes the five
objects from the company's password-protected PEM files: the key's password removed, the certificate checked for
this namespace and this use, one YAML file per object.

```bash
export TargetNamespace=dvh-gp6-rnd        # there is no default: without it, or --target-namespace, it refuses
mkdir -m 700 $TargetNamespace             # the script never creates the folder; the files go there
P=chart/mongodb-search-helm/generate-mongodbsearch-prerequisites.sh      # from the repository's root

bash $P --check --mongot <mongot PEM> --envoy <Envoy client PEM> --route <public hostname PEM>
bash $P --trustca <mongot PEM>          --dry-run     # then the same with --apply
bash $P --mongot  <mongot PEM>          --dry-run
bash $P --envoy   <Envoy client PEM>    --dry-run
bash $P --route   <public hostname PEM> --dry-run
bash $P --dbcred  --username mongotuser --dry-run
bash $P --check                                       # the five objects, and the lines for the values file
bash $P --clean                                       # removes the key files once the objects are in the cluster
```

| | |
| --- | --- |
| `--dry-run` | Writes the file; contacts no cluster |
| `--apply` | Writes the file, names the cluster and asks for the namespace to be typed (`--yes` skips that), then `oc create`. An object already there needs `--replace` |
| Prompts | The key's passphrase for `--mongot`, `--envoy` and `--route`; the password, twice, for `--dbcred`. For automation: `--passin-file`, `--password-file` |
| Run with `bash` | helm stores a chart's files without the executable bit |
| Run outside the chart | helm packages every file under this directory and keeps it in each release; the script refuses to write here, and `.helmignore` keeps keys and certificates out as a second guard |

From the package alone, with no clone:

```bash
helm pull https://github.com/ephico2real2/mongodb-poc/releases/download/mongodb-search-helm-0.3.6/mongodb-search-helm-0.3.6.tgz --untar
bash mongodb-search-helm/generate-mongodbsearch-prerequisites.sh --help
```

In short, once the prerequisites exist in the namespace, install the published package (no clone needed):

```bash
helm install mongot \
  https://github.com/ephico2real2/mongodb-poc/releases/download/mongodb-search-helm-0.3.6/mongodb-search-helm-0.3.6.tgz \
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
| `source.username` | `mongotuser` | Step 6a |
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

The chart ships one dashboard, **MongoDB Search**, in two forms from one source. Its seven sections each answer a question: is search up, is traffic spread across the mongot pods, is Envoy healthy, how is each mongot pod doing, does every mongot pod hold the same data, what does each index hold, and is stored source used. It has 45 panels: 13 single numbers, 22 line charts, a pie, 3 tables, 2 status histories and 4 bar charts. Those about mongot's process and its data are [described below](#the-mongot-process-and-data-panels), and those about the indexes [after them](#the-index-panels).

The captures below were taken on the lab on 2026-10-07, after 16 minutes of searches through the lab's search GUI. Click an image to open it full size. The dark captures, and earlier ones from a Perses and a Grafana run on a workstation, are beside them in [`docs/screenshots/`](../../docs/screenshots/).

### Perses, in the OpenShift console

On by default (`monitoring.persesDashboard.enabled`). In the console it is under **Observe → Dashboards (Perses)**, in the release's project.

<!-- markdownlint-disable MD033 -->
<img alt="The top of the dashboard in the OpenShift console, light theme. Is search up: 3 mongot pods up, 2 Envoy pods up, 3 mongot pods in Envoy, 1.04 searches per second, largest share on one pod 34 percent, all in green. Is traffic spread across the mongot pods: searches per second stacked in three bands of equal height, blue for the first pod, red for the second and yellow for the third, their top edge rising from 0.2 to 1.2 per second; the share of searches stacked to 100 percent, a third each; a pie of three equal slices in the same colours; each legend below its chart with all three pod names." src="../../docs/screenshots/dashboard-console-traffic.light.png">
<!-- markdownlint-enable MD033 -->

*Is search up, and is traffic spread: with even traffic each mongot pod is a band of equal height and a third of the pie.*

<!-- markdownlint-disable MD033 -->
<img alt="The section How is each mongot pod doing, light theme, nine panels with one line per mongot pod: blue solid for the first, red dashed for the second, yellow dotted for the third, each with a light shade of its own colour under it. Average search latency of 1.7 to 2.7 milliseconds, no search failures, replication lag of 10 seconds on the first pod with peaks of 15 and none on the second, JVM memory between 260 and 390 MiB, CPU of 1.5 to 5.5 percent, heap at 17 to 43 percent of its limit, time in garbage collection of 0.05 to 0.08 percent, uptime of 19 hours on an axis from zero, the same on every pod with one blue shade, and no search work run outside the parallel pool." src="../../docs/screenshots/dashboard-console-pods.light.png">
<!-- markdownlint-enable MD033 -->

*How is each mongot pod doing: where one pod reads higher than the others, the shade above them is in its colour.*

<!-- markdownlint-disable MD033 -->
<img alt="The section Does every mongot pod hold the same data, light theme. A table with one row per mongot pod, each pod name on its colour, and equal rows: index size 4.59 MiB, 40.1 thousand documents, 5 indexes, 0 not STEADY, volume 82 percent used, uptime 18.9 hours. Below it, index size and documents indexed as one line covering the other two, a status history green for STEADY on all three pods, 5 indexes in the catalog on an axis of whole numbers, the data volume at 82 percent of a 0 to 100 scale, and no indexing operations." src="../../docs/screenshots/dashboard-console-data.light.png">
<!-- markdownlint-enable MD033 -->

*Does every mongot pod hold the same data: equal rows in the table, one line in each chart.*

The dashboard in the lab's own OpenShift console (4.22.7, Cluster Observability Operator 1.5.3), opened by [`scripts/capture-console-dashboard.py`](../../scripts/capture-console-dashboard.py) as the lab's `developer` user, who held only the roles below. The three pictures are cut from one capture of the whole page, [`dashboard-console.light.png`](../../docs/screenshots/dashboard-console.light.png), which also holds the *Is Envoy healthy?* section; a `.dark.png` is beside each.

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
<img alt="The same dashboard in a Grafana 12.3.1 running in the lab namespace, on its default data source (Thanos Querier), last 15 minutes: the same five sections and 29 panels, and the same colours as in the console. Searches per second 0.84 and largest share on one pod 33 percent; searches per second and the share of searches stacked in blue, red and yellow bands from zero, the share adding up to 100 percent; a pie of three near-equal slices; the two Envoy pods in blue and red, their axes from zero; each mongot line 1 wide, the second dashed and the third dotted, with a light shade of its own colour underneath; a table with each pod name on its colour and equal rows; a status history green on all three pods with the legend STEADY; 5 indexes in the catalog on an axis from 0 to 5; the data volume at 82 percent of a 0 to 100 scale; and no warning sign or empty panel." src="../../docs/screenshots/dashboard-grafana-sidecar.light.png">
<!-- markdownlint-enable MD033 -->

*The chart's ConfigMap, loaded by the dashboard sidecar of a Grafana installed in the lab namespace for this measurement and removed afterwards (the Grafana Helm chart 10.5.15, Grafana 12.3.1, sidecar 2.5.0; [`test/grafana-sidecar/`](../../test/grafana-sidecar/)). Measured when the dashboard had 16 panels: the Grafana held no such dashboard before `monitoring.grafanaDashboard=true`, and 37 s after that upgrade started the sidecar had written the file and Grafana listed it. Measured again with the 27 panels of chart 0.3.0: listed with 27 panels in 5 rows, and all 27 queries answered through its Thanos Querier data source. Measured again on 2026-10-07 with the 29 panels shown here: listed with 29 panels and 97 queries, all 97 answered through its Thanos Querier data source (26 with no series, each expected: no fourth pod, no third Envoy pod, no 4xx, 5xx or other response class), and the page drew every panel in both themes.*

Two things that Grafana needed, which the chart does not provide: a Prometheus data source (the dashboard starts on Grafana's default one and lists any other under *Data source*; here Thanos Querier on port 9091 with the Grafana pod's own token), and a Role that lets the sidecar read ConfigMaps. The Grafana Helm chart's own Role also lets it read every Secret in the namespace; `test/grafana-sidecar/` replaces it with one for ConfigMaps only.

How the Perses form is generated from the Grafana one, and how both were validated, is in [`docs/grafana-to-perses-conversion.md`](../../docs/grafana-to-perses-conversion.md).

### Colours and shades

Every line, band, slice, table cell and state has a fixed colour, the same in both forms and in the light and the dark theme. None is left to a palette. The colours are six of the Tableau 10 palette, which was designed to be told apart without being loud ([How we designed the new color palettes in Tableau 10](https://www.tableau.com/blog/colors-upgrade-tableau-10-56782)).

| Colour | A mongot panel | An Envoy panel | Responses by class |
| --- | --- | --- | --- |
| Blue `#4e79a7` | the first pod, `<name>-search-0-0` | the pod started last | |
| Red `#e15759` | the second, `-1`; dashed | the one before it; dashed | 5xx |
| Yellow `#edc948` | the third, `-2`; dotted | the third; dotted | |
| Purple `#b07aa1` | any further pod; in the pie, all of them as one slice, *further pods* | any further pod | any other class |
| Green `#59a14f` | | | 2xx |
| Orange `#f28e2b` | | | 4xx |

The single numbers use the same green for good, and orange and red for their thresholds. *Indexes not STEADY* is green for `STEADY` and red for anything else. In the table, each pod's name sits on its colour.

How the lines are drawn:

- **Lines are 1 wide.** The second pod's line is dashed and the third's dotted, so that when the three lie on each other all three still show.
- **Each line has a shade of its own colour under it**, the line's colour at 10% opacity. Where one pod reads higher than the others, its shade shows above theirs; where they overlap, the shades blend.
- **The two traffic panels are stacked**, at 30% opacity. *Searches per second, per mongot pod* has one band per pod and its top edge is all searches; *Share of searches, per mongot pod* adds up to 100%. With even traffic the three lines would lie on each other, and three shades on each other turn brown; stacked, even traffic is three bands of equal height, each in its pod's colour. The axis of these two panels therefore reads the running total, not one pod's value; the pointer shows each pod's own.
- **Five panels keep one shade**, the first pod's blue at 15%: uptime, index size, documents indexed, indexes in catalog and data volume used. Every pod reads the same there by design, so three shades would again be one brown block.
- **A per-second rate and uptime start at 0**, as the two stacked panels do. Left to its own range, Grafana 12.3.1 drew the lab's 2xx responses on an axis from 0.725 to 0.85 per second, their shade starting there, and repeated tick labels on the uptime panel (`17.4 hours` twice over 9 minutes). Perses had the responses from 0 already and draws uptime from 0 now, the line where it was.
- **Legends are below the chart.** The three traffic panels are a third of the page wide, where three pod names take two legend lines; Perses draws the second line only in a panel at least 11 units high (measured in the console: at 8, 9 and 10 it was cut), so that row is 11 high and the others 8.

What makes the fixed colours possible, and what they cost:

- **One query per line.** Perses fixes a colour per query, not per series, so each per-pod panel asks four queries: one per pod and one for any further pod. The Grafana form carries the same four, coloured by query. The dashboard asks 97 queries a refresh (27 in chart 0.3.0, 90 in 0.3.1); measured on the lab through Thanos Querier, a refresh over 15 minutes took 0.45 s in all, with no warning on any query.
- **The pie is read at the end of the time range, and takes its colours by position.** A pie draws the last value of each query. Read over the whole range, it kept a pod that had gone, and searches that had stopped, for as long as the range reached back to them: three slices twenty minutes after the last search, in Grafana 12.3.1 and in Perses 0.54.0 alike (drawn 2026-10-07). So every selector of the pie carries `@ end()`. A Perses pie has a list of colours, not one per query (the same code in PieChart 0.13.1, the lab's, and 0.14.0; drawn in 0.14.0): a query with two series, or a query with none before one that has, moves the colours off their pods and paints the overflow `#ff0000`. So each of the pie's four queries gives one series: a pod's own, selected by name, or 0 in its place whenever that pod or a later one is known; every further pod summed as *further pods*; and nothing unless a search ran in the last 5 minutes: Grafana then writes *No search in the last 5 minutes* in the panel, Perses draws an empty circle. Checked in 750 states of the first three pods (serving, idle, just started, just gone, absent) with and without further pods: none wrong in either form.
- **mongot pods are told apart by name**, which a StatefulSet fixes, so a pod keeps its colour for good, also while it is replaced: each query selects its pod by the name alone. Selected through the pod's `up` series, a pod being replaced was drawn in purple, the colour of any further pod, in seven charts for as long as its `up` was gone and its last 5 minutes were still in the rates, and was named twice in the legend (drawn in Grafana 12.3.1, 2026-10-07).
- **Envoy pods are told apart by start time** (`kube_pod_start_time`), because their names are generated. A colour stays with a pod while the set of pods stays the same; when one is replaced, the order moves on. On the lab the two pods started in the same second, and the order between them was the same at every step of nine range queries.
- **Yellow is faint on white.** Measured contrast against the console's two backgrounds:

  | Colour | On white (light theme) | On `#292929` (dark theme) |
  | --- | --- | --- |
  | Blue | 4.5:1 | 3.2:1 |
  | Red | 3.7:1 | 4.0:1 |
  | Yellow | 1.6:1 | 9.0:1 |
  | Purple | 3.4:1 | 4.3:1 |

  The closest two pod colours are blue and purple (CIE76 ΔE 34); among the first three, red and yellow (ΔE 72). In the light theme the third pod's dotted yellow line is the hardest to see; its band, slice and table cell are not affected. In the console the names in the table are in black, which is at least 4.6:1 on each of the four colours; Grafana 12.3.1 chooses the text itself, near-white on blue and red (4.3:1 and 3.5:1) and near-black on yellow.
- **Before chart 0.3.1**, the Perses form took a colour generated from each series' name: measured, three muted tones for the mongot pods and two purples for the Envoy pods, with a contrast as low as 1.9:1 against the background.

### The mongot process and data panels

Eleven panels read mongot's own metrics, one line per mongot pod; *Indexes not STEADY* is a status history instead, one row per pod. Above the data panels a table, *Each mongot pod, now*, puts the latest index size, documents, indexes, indexes not STEADY, volume used and uptime of every pod side by side, so that equal data reads as equal rows. Readings are the lab's, on 2026-10-06, pod 0 / 1 / 2.

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

### The index panels

The sixth section, *What does each index hold?*, is about the indexes themselves: 10 panels that read mongot's per-index metrics, `mongot_index_stats_*`, by the label `indexId_logString`. The seventh, *Is stored source used?*, has 6 panels on the searches that ask for stored source. Readings are the lab's on 2026-10-08, with eight indexes, three of them made for this measurement, while test searches ran.

| Panel | What it reads | Lab reading |
| --- | --- | --- |
| Indexes | The number of index ids that report a size | 8 |
| Indexes being built | `mongot_initialsync_dispatcher_inProgressSyncs` and `queuedSyncs`, on the pod that has the most | 0 |
| Indexes that differ by pod | Index ids that some pod does not report, or whose size or document count is not the same on every pod | 0 |
| Size of all indexes, on one pod | `mongot_index_stats_indexSizeBytes`, the largest reading of each index, added up | 16,695,001 bytes |
| Stored source searches, 1 hour | The increase of `mongot_index_stats_query_feature_total{name="returnStoredSource"}` | 654 |
| Stored source share, searches | The rate of that counter over the rate of `mongot_search_metrics_searchCommandTotalCount_total`, 5 minutes | 34% |
| Stored source vector, 1 hour | The increase of `mongot_search_metrics_vectorStoredSourceQueries_total` | 654 |
| Stored source share, vector | The rate of that counter over the rate of `mongot_search_metrics_vectorSearchCommandTotalCount_total`, 5 minutes | 51% |
| Each index, now | A table, one row per index id: type, pods where it is `STEADY`, documents, size, bytes per document, growth in 24 hours | 5 search and 3 vector indexes, each `STEADY` on 3 pods, 5 to 20,024 documents, 5,339 to 5,900,486 bytes |
| Each index, in use | A table, one row per index id: searches, failed searches and sync errors in the last hour, replication lag | 623 to 685 searches on the five indexes that were queried, 0 on the other three; 0 failed, 0 sync errors, 0 ms |
| Size of each index | The same size, biggest first | 5,900,486 bytes down to 5,339 |
| Indexes by size | How many indexes fall in each of six size classes, from under 10 KB to 100 MB and over | 2, 1, 0, 5, 0, 0 |
| Indexes by type | How many are search indexes and how many vector indexes | 5 and 3 |
| Indexes not STEADY, per index | `mongot_index_stats_indexStatusCode` for every state but `STEADY`, summed over the pods | `STEADY` on all 8 |
| Searches that ask for stored source, per second | The two stored source counters as 5 minute rates | 0.37 to 0.49 a second each during the test searches |
| Query features used, last hour | The increase of `mongot_index_stats_query_feature_total`, by feature | `valueBoost`, `text`, `approximate`, `returnStoredSource`, and one each of `exists`, `phrase` and `compound` |

What to know when reading them:

- **An index is named by its id, not by its name.** mongot's metrics carry no index name, database or collection: one pod emitted 1,017 metric names and none has such a label. `$listSearchIndexes` on the source mongod returns the `id` and the `name` of each index of a collection, and its ids are the ones in the metrics. The tables and the charts show the whole id. The two charts that name every index on an axis take the whole width of the page: at less than half of it the console cut the 24 character id.
- **Stored source is counted, not located.** The two counters count the queries sent with `returnStoredSource`: on the lab, 30 `$search` and 30 `$vectorSearch` queries with it moved them from 0 to 30 each, 10 on each pod, and 60 queries without it moved neither. No metric says which index defines stored source or how many bytes it takes. Creating three indexes that define it added no metric name and no label.
- **What stored source costs shows only by comparison.** On one collection of 20,024 documents with the same mappings: 3,514,585 bytes with no stored source, 4,236,232 with three fields stored, 5,900,486 with every field stored. *Bytes per document* in the table is where that shows: 176, 212 and 295.
- **A new index reads 0 bytes at first.** The size of an index just built was 0 for under a minute, and *Indexes that differ by pod* can be above 0 for that long.
- **The size classes are this dashboard's own**, powers of ten. mongot has classes of its own, of which only two names appear in the lab's metrics. Grafana lists the classes from the smallest; the console's bar chart lists bars by their value, so there the fullest class is first.
- **Growth counts a new index from 0.** An index that did not exist 24 hours ago has its whole size as its growth.
- **Counts over an hour are estimates.** Prometheus extends an increase to the edges of its window: 60 queries read as 61.
- **Left out:** `mongot_index_stats_requiredMemoryBytes` (non-zero only on the vector indexes; the metric has no description) and the per-index latency of result batches (present only for search indexes that were queried, and not the time of a whole search).
- **Not seen on the lab:** an index being built while the dashboard was open, an index out of `STEADY`, a failed search, a sync error. Those panels and columns read 0 throughout.

**Where these 16 panels were looked at:** in the lab's console, dark theme, on pages 1,600 and 1,280 pixels wide, on 2026-10-08: no panel said "No data", and every id was whole. They were not drawn in a Grafana; the pictures above were taken before these sections existed and do not show them.

The four bar charts are one colour, blue: they rank or count, and a colour per bar would change with every new index. The section adds 31 queries to a refresh, 128 in all; through Thanos Querier over 15 minutes the 31 took 0.07 s, with no warning on any.

### Envoy counters without `_total`

Envoy exports `envoy_cluster_upstream_rq_retry` and `envoy_cluster_upstream_rq_xx` as counters (Prometheus records their type as `counter`), but without the `_total` that Prometheus expects at the end of a counter's name. `rate()` on such a name is answered with the notice *metric might not be a counter, name does not end in _total/_sum/_count/_bucket*. Thanos Querier returns that notice as a warning, and Perses and Grafana put a warning sign on the panel.

The chart's Envoy ServiceMonitor therefore renames the two at the scrape, to `envoy_cluster_upstream_rq_retry_total` and `envoy_cluster_upstream_rq_xx_total`. The two dashboard panels and the `MongotEnvoyRetriesElevated` alert use those names. What follows from that:

- with Envoy scraped by anything else (for example the hand-applied [`manifests/90-servicemonitors.yaml`](../../manifests/90-servicemonitors.yaml)), the retries and responses panels are empty and that alert never fires;
- on an upgrade from a release without the rename, those two panels start again from the upgrade: the earlier samples stay under the old names.

Measured on the lab on 2026-10-06, through Thanos Querier: before, each of the two queries came back with one warning; after, every query of the dashboard came back with none (16 queries then, 27 in chart 0.3.0, 90 in 0.3.1, 97 since 0.3.2).

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
