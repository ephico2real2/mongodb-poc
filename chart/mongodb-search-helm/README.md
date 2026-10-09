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
| 1 | Alerts | Twelve alerts: four on traffic distribution and retries, five on the indexes, and the volume under the indexes at three levels; on by default |
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
helm pull https://github.com/ephico2real2/mongodb-poc/releases/download/mongodb-search-helm-0.3.11/mongodb-search-helm-0.3.11.tgz --untar
bash mongodb-search-helm/generate-mongodbsearch-prerequisites.sh --help
```

In short, once the prerequisites exist in the namespace, install the published package (no clone needed):

```bash
helm install mongot \
  https://github.com/ephico2real2/mongodb-poc/releases/download/mongodb-search-helm-0.3.11/mongodb-search-helm-0.3.11.tgz \
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
| `monitoring.alerts.enabled` | `true` | The twelve [alerts](#alerts): traffic that concentrates on one mongot pod, an index in trouble, and the volume under the indexes filling up |
| `monitoring.alerts.dataPathUsed.info`, `.warning`, `.critical` | `70`, `80`, `90` | The three levels of [the volume alert](#the-volume-alert), in per cent used of the file system under mongot's data path. `null` leaves a level out |
| `monitoring.persesDashboard.enabled`, `.thanosURL` | `true`, Thanos Querier port 9091 | The "MongoDB Search" dashboard in the console; set it to `false` on a cluster without the Cluster Observability Operator |
| `monitoring.grafanaDashboard` | `false` | The same dashboard as a ConfigMap for a Grafana dashboard sidecar |
| `preflight.enabled` | `true` | |
| `installPlanApprover.waitSeconds`, `csvReclaim.*`, `wait.*`, `jobs.*` | see `values.yaml` | |

`values.schema.json` refuses an unknown key, an IP address as hostname and a source without a port.

## Dashboards

The chart ships one dashboard, **MongoDB Search**, in two forms from one source. Its seven sections each answer a question: is search up, is traffic spread across the mongot pods, is Envoy healthy, how is each mongot pod doing, does every mongot pod hold the same data, what does each index hold, and is stored source used. It has 52 panels: 20 single numbers, 22 line charts, a pie, 5 tables, 2 status histories and 2 bar charts. Those about mongot's process and its data are [described below](#the-mongot-process-and-data-panels), and those about the indexes [after them](#the-index-panels).

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

<!-- markdownlint-disable MD033 -->
<img alt="The section What does each index hold, in the OpenShift console, light theme. Eight numbers in green: 8 indexes, 0 being built, 0 that differ by pod, 15.92 MiB for all indexes on one pod, 5 search indexes, 3 vector indexes, 5.66 MiB of memory for vector indexes, 0 builds waiting. A table with one row per index id, each id whole: type search or vector, 3 pods STEADY on every row, 5 to 20 thousand Lucene documents, sizes from 5.21 KiB to 5.63 MiB, from 62.7 bytes to 1.31 KiB per document, and 2.83 MiB of vector memory on two vector indexes. A second table for the last hour: 767 or 768 searches on five indexes and 0 on three, 0 failed searches, a batch time of 1.29 to 1.57 ms on three search indexes, 0 sync errors, 0 lag, and a growth of 4.04, 1.67 and 5.63 MiB on the three indexes made that day. A bar chart of the size of each index, biggest first, the ids whole on its axis. A state history with one green row per index, STEADY throughout." src="../../docs/screenshots/dashboard-console-indexes.light.png">
<!-- markdownlint-enable MD033 -->

*What does each index hold: an index is named by its id, whole, in the tables and on the charts.*

<!-- markdownlint-disable MD033 -->
<img alt="The section Is stored source used, in the OpenShift console, light theme. Four numbers in green: 768 stored source searches in an hour, a 33 percent share of searches, 768 stored source vector searches, a 50 percent share of vector searches. A line chart of the searches that ask for stored source, both lines between 0.24 and 0.5 a second, the dashed red one on the blue one. A bar chart of the query features used in the last hour: valueBoost and text the longest bars, approximate shorter, returnStoredSource 768." src="../../docs/screenshots/dashboard-console-stored-source.light.png">
<!-- markdownlint-enable MD033 -->

*Is stored source used: how many searches ask for it, and what share of all searches that is.*

The two pictures above are from a capture of 2026-10-09, with chart 0.3.8 and test searches running; the three before them are from 2026-10-07.

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

<!-- markdownlint-disable MD033 -->
<img alt="The two index sections in the same Grafana, light theme, on 2026-10-09. The same eight numbers as in the console: 8 indexes, 0 being built, 0 that differ by pod, 15.9 MiB, 5 search and 3 vector indexes, 5.66 MiB of memory for vector indexes, 0 builds waiting. The same two tables with every header and every id whole and all eight rows showing. The size of each index as bars, biggest first, the ids whole in small type. The state history green for every index. Then Is stored source used: 667 searches and 666 vector searches in an hour, shares of 34 and 51 percent, the two rates on each other up to 0.5 a second, and the features text, valueBoost, approximate and returnStoredSource." src="../../docs/screenshots/dashboard-grafana-indexes.light.png">
<!-- markdownlint-enable MD033 -->

*The two index sections in Grafana: the same panels and readings as in the console.*

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
- **Documents indexed is the strict comparison; index size is a loose one.** Each pod writes and merges its own index files, so the same documents need not take the same bytes. On the lab the indexes built once from a collection have the same size on every pod; after 600 documents were written to one of them, its 605 documents took 112,781 bytes on two pods and 113,402 on the third, and still did after 12 quiet minutes. While an index is written to, the document counts differ too, by what arrived between the readings of the pods: on the lab Prometheus reads the first pod 9 seconds after the other two, and at two inserts a second the readings taken every 15 seconds on the minute were 17 to 24 documents apart, those taken 4 or 8 seconds later 7 to 15. The gap is the readings', not the pods'.
- **Data volume used is the file system under mongot's data path.** With a volume of its own per pod, that is the volume. The lab's storage class is a hostpath provisioner, so there it is the node's disk: 160.5 GB in total and 82.5% used on every pod, while each pod's data takes about 18 MiB.
- **The pool panel does not count refused searches.** mongot's source gives the counter to a caller-runs policy: when the concurrent search pool is full the work runs on the calling thread, and the search is still answered. Above zero, the pool is saturated.
- **The heap limit is the JVM's, not the pod's.** On the lab it is 495 MiB, a quarter of the pod's 2 Gi memory limit. The older *JVM memory used* panel shows heap and non-heap together, in bytes.
- **Not seen on the lab:** an index out of `STEADY`, indexing activity, and work outside the pool. Those three panels were flat at zero throughout; their queries answer, and what they look like in trouble was not observed.

### The index panels

The sixth section, *What does each index hold?*, is about the indexes themselves: 16 panels that read mongot's per-index metrics, `mongot_index_stats_*`, by the label `indexId_logString`. The seventh, *Is stored source used?*, has 7 panels on the searches that ask for stored source and on what it adds to an index. With the optional [index info exporter](#index-names-as-metrics) on, these panels show an index by its name; without it, by its id. Readings are the lab's on 2026-10-08, with eight indexes, three of them made for this measurement, while test searches ran.

| Panel | What it reads | Lab reading |
| --- | --- | --- |
| Indexes | The number of index ids that report a size | 8 |
| Indexes being built | Index ids that some pod holds in the state `INITIAL_SYNC` or `NOT_STARTED` | 0 |
| Indexes that differ by pod | Index ids that some pod does not report, or whose document count is not the same on every pod, among the pods that report any index | 0 |
| Size of all indexes, on one pod | `mongot_index_stats_indexSizeBytes`, the largest reading of each index, added up | 16,695,001 bytes |
| Stored source searches, 1 hour | The increase of `mongot_index_stats_query_feature_total{name="returnStoredSource"}` | 654 |
| Stored source share, searches | The rate of that counter over the rate of `mongot_search_metrics_searchCommandTotalCount_total`, 5 minutes | 34% |
| Stored source vector, 1 hour | The increase of `mongot_search_metrics_vectorStoredSourceQueries_total` | 654 |
| Stored source share, vector | The rate of that counter over the rate of `mongot_search_metrics_vectorSearchCommandTotalCount_total`, 5 minutes | 51% |
| Search indexes; Vector indexes | Index ids by the `indexType` label of their insert counter | 5 and 3 |
| Memory for vector indexes | `mongot_index_stats_requiredMemoryBytes`, the largest reading of each index, added up | 5,930,144 bytes |
| Index builds waiting | `mongot_initialsync_queue_queuedSyncs`, on the pod that has the most | 0 |
| Indexes with a name; Indexes with stored source; Indexes with no host listed | From the index info exporter: the indexes it names, those whose definition stores fields, and those the source lists no mongot host for | 8, 3 and 0; all 0 with the exporter off |
| Each index | A table, one row per index: its id, its type, what its definition stores, its vector memory | 5 search and 3 vector indexes; 2 store some fields and 1 all fields; 2,963,552 bytes of vector memory on two of them |
| Each index, now | A table, one row per index: pods where it is `STEADY`, Lucene documents, size, bytes per Lucene document, growth in 24 hours | Each `STEADY` on 3 pods, 5 to 20,024 documents, 5,339 to 5,900,487 bytes |
| Each index, in the last hour | A table, one row per index: searches, failed searches, average batch time and sync errors in the last hour, and the replication lag now | Searches on the five indexes that were queried, 0 failed, batches in about 1 ms on the three search indexes that were searched, 0 sync errors, a lag of 0 s |
| What stored source adds | A table of the indexes that store fields: their size, the smallest index of the same collection and type that stores nothing, and the difference | `ss_include` 721,648 bytes over `default`, `ss_all` 2,385,902, `ss_vector` 494,313 over `vector_index` |
| Size of each index | The same size, biggest first | 5,900,487 bytes down to 5,339 |
| Indexes not STEADY, per index | `mongot_index_stats_indexStatusCode` for every state but `STEADY`, summed over the pods | `STEADY` on all 8 |
| Searches that ask for stored source, per second | The two stored source counters as 5 minute rates | 0.37 to 0.49 a second each during the test searches |
| Query features used, last hour | The increase of `mongot_index_stats_query_feature_total`, by feature | `valueBoost`, `text`, `approximate`, `returnStoredSource`, and one each of `exists`, `phrase` and `compound` |

What to know when reading them:

- **An index is named by its id, unless the index info exporter is on.** mongot's metrics carry no index name, database or collection: one pod emitted 1,017 metric names and none has such a label. With the exporter on (`monitoring.indexInfo`), the tables, the size chart and the state history show `database.collection / index`, and *Each index* shows the id beside it; with it off, or for an index the source has not listed yet, they show the id. Both were drawn on the lab: 8 rows by name with the exporter on, the same 8 by id with it off.
- **An index is drawn once, whichever way it is named.** The names are read at the end of the range the page shows. Read along the range, a chart drew an index twice when its name came or went inside the range: 16 bars for 8 indexes on the lab, just after the exporter was switched off.
- **A long name can be cut in a table.** The *Index* column is 290 pixels wide, which holds the lab's longest name, 41 characters. The size chart and the state history show a name whole whatever its length; in Grafana a bar's name is above the bar for that reason.
- **Stored source is counted, and located only with the exporter.** The two counters count the queries sent with `returnStoredSource`: on the lab, 30 `$search` and 30 `$vectorSearch` queries with it moved them from 0 to 30 each, 10 on each pod, and 60 queries without it moved neither. No metric says which index defines stored source or how many bytes it takes. Creating three indexes that define it added no metric name and no label.
- **What stored source adds is a comparison, not a measurement.** No metric says what stored source takes. *What stored source adds* compares each index that stores fields with the smallest index of the same collection and type that stores nothing. On the lab's `movies`, 20,024 documents with the same mappings: 3,514,585 bytes with no stored source, 721,648 more with three fields stored (36 bytes a document), 2,385,902 more with every field stored (119 bytes a document). Whatever else differs between the two definitions is in the difference too: the lab's `ss_vector` has one filter field fewer than `vector_index`, so its 494,313 bytes are not only stored source. Without the exporter the table has one row that says no index is known to store fields, with a dash under *Stored source*.
- **A new index reads 0 bytes for up to 3 minutes.** mongot reads the size of an index from disk and keeps the reading for 3 minutes (`Suppliers.memoizeWithExpiration(..., Duration.ofMinutes(3))` in its `DiskIndexBackingStrategy`). Measured on the lab: an index whose 20,024 documents were there at 02:35:45Z read 0 bytes until 02:38:45Z. An earlier version of this page said "under a minute"; that was wrong.
- **The size is the whole index directory**: mongot adds up every file in it, so it includes stored source and vectors.
- **Documents are Lucene documents.** The metric is the index writer's document count. An index with an `embeddedDocuments` field holds one Lucene document more for every embedded document, so the count can be above the collection's; for such an index mongot also emits `mongot_index_stats_numEmbeddedRootDocs`. The lab has no such index, and its counts equal the collections'. The older panel *Documents indexed, per mongot pod* reads the same metric.
- **The lag is in whole seconds**, although the metric is in milliseconds, and is empty while an index is built.
- **Not `STEADY` is not always not served.** mongot answers searches from an index that is `STEADY`, `STALE` or `RECOVERING`; not from one that is `INITIAL_SYNC`, `NOT_STARTED` or `FAILED`.
- **There is no histogram of index sizes.** One was drawn in chart 0.3.6, with size classes of this dashboard's own, and removed in 0.3.7: the console's bar chart lists bars by their value, so the classes came out in the order of their counts, not of their sizes. mongot's own size classes are coarse and for other things (`small`, `medium`, `large`, `xlarge` at 1, 10 and 100 GiB, for the latency of vector searches); every index of the lab is `small`. *Size of each index* and the two counts by type say the same more plainly. Grafana lists the classes from the smallest; the console's bar chart lists bars by their value, so there the fullest class is first.
- **Growth counts a new index from 0.** An index that did not exist 24 hours ago has its whole size as its growth.
- **Counts over an hour are estimates.** Prometheus extends an increase to the edges of its window: 60 queries read as 61. The console also shortens a count of a thousand or more (`1.1K`); Grafana writes it out.
- **Vector memory** is `mongot_index_stats_requiredMemoryBytes`: what a vector index wants resident, the vectors plus 128 bytes of graph for each. On the lab 20,024 vectors of 5 dimensions read 2,963,552 bytes, which is 20,024 x (5 x 4 + 128). It is 0 for a search index.
- **The batch time is an average, and not the time of a whole search.** `mongot_index_stats_query_searchResultBatchLatencies_seconds` times the making of one batch of results, for search indexes only, and is an average here: mongot gives a sum and a count, and no buckets. The lab read 0.7 to 1.0 ms, when the whole search command averaged 1.4 ms, and about an hour later, with the test searches running, 1.3 to 1.6 ms.
- **`$listSearchIndexes` can say `PENDING` while the index is served.** On the lab it reports every index `PENDING` and not queryable, while mongot reports `STEADY` and searches return results. mongod builds that answer from the hosts whose heartbeat row in `__mdb_internal_search.serverState` is under 2 hours old. The lab was suspended for over 2 hours twice; a pod's hourly cleanup then removed the others' rows, and mongot 1.70.1 only updates its row, never re-creates it: each pod logs `Failed to update server state entry` every 30 seconds, and the collection holds 0 rows (read 2026-10-09). The index names and definitions in that answer are right; its status is not to be trusted there. mongot's own `indexStatusCode`, which these panels read, is. Restarting the three mongot pods one at a time put it right on 2026-10-09: a pod writes its row when it starts. Afterwards the collection held 3 rows, every index was `READY` and queryable on 3 hosts, and the warning had stopped.
- **Not seen on the lab:** an index being built while the dashboard was open, an index out of `STEADY`, a failed search, a sync error. Those panels and columns read 0 throughout.

**Where these 23 panels were looked at**, on 2026-10-09 with chart 0.3.9:

- In the lab's console as the viewer, with the index info exporter on, in both themes, on pages 1,600 and 1,280 pixels wide: all 7 sections, no panel said "No data", and every name, id and table header was whole. And with the exporter off, in the dark theme: the same, by id.
- In a Grafana 12.3.1 that loaded the chart's ConfigMap through its sidecar, with the exporter on, in both themes: it lists the dashboard with the same 52 panels in the same 7 rows; all 135 queries answered through its Thanos Querier data source with no failure and no notice; no panel said "No data".

Three things were wrong in the Grafana form of chart 0.3.7 and are corrected: its table headers were cut ("Pods STE..."), its tables showed seven rows of eight, and its bar chart cut the index ids. Grafana draws a header in wider type than the console and a bar's name in a column it caps at about 165 pixels, so the columns are wider, the tables a unit taller, and the ids of *Size of each index* are in 10 pixel type there. The console draws them full size.

The two bar charts are one colour: they rank or count, and a colour per bar would change with every new index. In the Grafana form it is the dashboard's blue, as a pale fill with its edge in the full colour. The console draws its bar chart in a brighter blue of its own and takes no colour from the dashboard, and it lists bars by their value whatever the query's order. The two sections add 38 queries to a refresh, 135 in all.

### Index names, as metrics

Optional, off by default (`monitoring.indexInfo.enabled`). mongot's metrics name an index by its id only. With this on, a small Deployment, `<search.name>-index-info`, publishes the name of every search index, so a query can show `sample_mflix.movies / default` where mongot says `6ab4bc25d292ce5f25d1b708`.

**How it works.** When Prometheus scrapes it, it asks the source deployment for its databases, their collections, and `$listSearchIndexes` of each collection, and keeps the answer for `cacheSeconds`. It reads no document. It runs on the stock MongoDB Community Server image, which has `python3` and `mongosh`; nothing is built for it. The image is named by its digest in `monitoring.indexInfo.image`, about 1 GB; on a cluster that pulls only from a registry of its own, mirror it there and set that value to the mirror. It reaches the source with the hosts and the CA the `MongoDBSearch` uses (`source.hostAndPorts`, `tls.trustBundleConfigMap`), and with a database user of its own.

**What it needs: one more prerequisite, made by hand.** A user on the source deployment that may list and nothing else, and its password in a Secret. Not the sync user: that one may read every collection and write mongot's catalog.

```javascript
// in mongosh, on the source deployment, as a user administrator
db.getSiblingDB("admin").createRole({role: "searchIndexLister", roles: [], privileges: [
  {resource: {cluster: true}, actions: ["listDatabases"]},
  {resource: {db: "", collection: ""}, actions: ["listCollections", "listSearchIndexes"]}]})
db.getSiblingDB("admin").createUser({user: "search-index-info", pwd: passwordPrompt(), roles: ["searchIndexLister"]})
```

```bash
# the same password, typed and not shown, into the Secret; printf adds no newline
printf 'search-index-info password: '; stty -echo; IFS= read -r PW; stty echo; echo
printf '%s' "$PW" | oc create secret generic search-index-info-password -n $NS --from-file=password=/dev/stdin
unset PW
```

Then set `monitoring.indexInfo.enabled: true`, and `monitoring.indexInfo.uriOptions` when the connection needs more (for example `replicaSet=rs0`). The preflight checks the Secret when the exporter is on.

**What it publishes.**

| Metric | Labels | Value |
| --- | --- | --- |
| `mongodb_search_index_info` | `indexId_logString`, `database`, `collection`, `index_name`, `stored_source` (`none`, `include`, `exclude` or `all`) | 1 |
| `mongodb_search_index_stored_source_paths` | `indexId_logString` | The field paths the stored source includes or excludes; 0 for `none` and `all` |
| `mongodb_search_index_listed_hosts` | `indexId_logString` | The mongot hosts the source lists for the index |
| `mongodb_search_index_info_collections` | | The collections that were asked |
| `mongodb_search_index_info_collect_timestamp_seconds`, `..._collect_duration_seconds` | | When the source was last asked, and how long it took |

The id is under the label mongot uses, `indexId_logString`, so the two join without relabelling:

```promql
max by (indexId_logString) (mongot_index_stats_indexSizeBytes{namespace="<ns>"})
  * on (indexId_logString) group_left (database, collection, index_name, stored_source)
  max by (indexId_logString, database, collection, index_name, stored_source) (mongodb_search_index_info{namespace="<ns>"})
```

**Measured on the lab**, 2026-10-09: the user above listed all 8 indexes of 3 collections in 0.49 s, and `find` and `insert` were refused to it (`Unauthorized`). The first `up` of 1 came under 2 minutes after the upgrade; the exporter serves 27 series; the query above returned the 8 sizes with their names, among them `sample_mflix` / `movies` / `ss_all` with `stored_source="all"`. The pod used 9 Mi of memory between scrapes.

What to know:

- **When the source cannot be asked, the scrape fails.** The exporter answers 503 and serves no names, so `up` goes to 0: a page of old names answered 200 would look healthy. Its log says why, in mongosh's words. Tested with a stand-in `mongosh` (`test/chart.sh`), not on the lab.
- **It does not publish the status of an index.** The source's `status` and `queryable` can be wrong (see `$listSearchIndexes` can say `PENDING`, above); mongot's own `indexStatusCode` is the one to read. `mongodb_search_index_listed_hosts` is the detector for that condition: it is 0 while searches work.
- **The names are readable by whoever can read the namespace's metrics.** It publishes index, collection and database names, and nothing of their content. Its Service is ClusterIP only.
- **One question per collection.** The cost grows with the number of collections, not of indexes. Measured with 3; not measured on a deployment with thousands, where `cacheSeconds` and `interval` should be raised.
- **`interval` is at least `25s`.** The exporter gives the source 20 seconds and its scrape times out at 25. Prometheus refuses a scrape timeout longer than the interval, and the Prometheus operator then leaves the ServiceMonitor out without telling Helm, so the chart refuses a shorter interval when it renders.
- **mongosh's telemetry is forbidden.** mongosh has it on by default: `enableTelemetry` was `true` in the configuration mongosh wrote for itself in the lab's pod. The pod mounts a global configuration file, `/etc/mongosh.conf`, with `forceDisableTelemetry: true`, the one place mongosh reads that setting from. On the lab mongosh 2.6.0 logged that it found the file, and `config.get("forceDisableTelemetry")` answered `true`. Whether mongosh sent anything before, run with a script as it is here, was not established: its documentation says it sends during interactive sessions.
- **Any name is served as it is.** A quote, a backslash, a newline, a letter outside ASCII, or one of the characters Python takes for a line break and JSON does not (U+2028, U+2029, U+0085): tested with a stand-in `mongosh`.
- **Views and time series collections are not asked**, nor the databases `admin`, `local`, `config` and mongot's own `__mdb_internal_search`.
- **The dashboard uses it when it is there.** The index panels show the name, what the index stores and what that adds; with the exporter off they show ids. How the two are joined, why it is built this way and what it leaves undone are in [Design: index names on the MongoDB Search dashboard](../../docs/index-names-exporter-design.md).

<!-- markdownlint-disable MD033 -->
<img alt="The section What does each index hold, in the OpenShift console, light theme, with the index info exporter on. Eleven numbers in green, among them 8 indexes, 8 indexes with a name, 3 indexes with stored source and 0 with no host listed. Three tables with one row per index, each by its name, from search_demo.movies / default to sample_mflix.movies / ss_all: the first also shows the id, the type, what the index stores (none, some fields, all fields) and its vector memory; the second pods STEADY, Lucene documents, size, bytes per document and growth in 24 hours; the third the searches, failed searches, batch time and sync errors of the last hour, and the lag now. A bar chart of the size of each index by name, biggest first, 8 bars. A state history with one green row per index, by name." src="../../docs/screenshots/dashboard-console-index-names.light.png">
<!-- markdownlint-enable MD033 -->

*With the exporter on: an index by its name, in the tables and on the charts.*

<!-- markdownlint-disable MD033 -->
<img alt="The section Is stored source used, in the OpenShift console, light theme, with the index info exporter on. Four numbers, then the table What stored source adds with three rows: sample_mflix.movies / ss_include stores some fields, 4.04 MiB against 3.35 MiB without it, adds 704.73 KiB, 36 bytes a document; sample_mflix.movies / ss_vector stores some fields, 1.67 MiB against 1.2 MiB, adds 482.73 KiB, 24.7 bytes a document; sample_mflix.movies / ss_all stores all fields, 5.63 MiB against 3.35 MiB, adds 2.28 MiB, 119 bytes a document. Below it the rate of the searches that ask for stored source and the query features used in the last hour." src="../../docs/screenshots/dashboard-console-stored-source-adds.light.png">
<!-- markdownlint-enable MD033 -->

*What stored source adds: each index that stores fields beside the one of its collection that stores nothing.*

### Envoy counters without `_total`

Envoy exports `envoy_cluster_upstream_rq_retry` and `envoy_cluster_upstream_rq_xx` as counters (Prometheus records their type as `counter`), but without the `_total` that Prometheus expects at the end of a counter's name. `rate()` on such a name is answered with the notice *metric might not be a counter, name does not end in _total/_sum/_count/_bucket*. Thanos Querier returns that notice as a warning, and Perses and Grafana put a warning sign on the panel.

The chart's Envoy ServiceMonitor therefore renames the two at the scrape, to `envoy_cluster_upstream_rq_retry_total` and `envoy_cluster_upstream_rq_xx_total`. The two dashboard panels and the `MongotEnvoyRetriesElevated` alert use those names. What follows from that:

- with Envoy scraped by anything else (for example the hand-applied [`manifests/90-servicemonitors.yaml`](../../manifests/90-servicemonitors.yaml)), the retries and responses panels are empty and that alert never fires;
- on an upgrade from a release without the rename, those two panels start again from the upgrade: the earlier samples stay under the old names.

Measured on the lab on 2026-10-06, through Thanos Querier: before, each of the two queries came back with one warning; after, every query of the dashboard came back with none (16 queries then, 27 in chart 0.3.0, 90 in 0.3.1, 97 since 0.3.2).

## Alerts

On by default (`monitoring.alerts.enabled`): one PrometheusRule, `<search.name>-distribution`, with three groups: traffic, indexes, and the volume. They need the ServiceMonitors, and user workload monitoring on the cluster.

| Alert | Fires when | For | Severity |
| --- | --- | --- | --- |
| `MongotTrafficNotDistributed` | One mongot pod serves over 90% of the searches | 10 m | warning |
| `MongotPodReceivingNoTraffic` | A mongot pod serves nothing while the others are busy | 15 m | info |
| `MongotEnvoyRetriesElevated` | Envoy retries more than one request a second | 10 m | warning |
| `MongotNoSearchTraffic` | Envoy has forwarded nothing to mongot | 30 m | info |
| `MongotIndexFailed` | An index is `FAILED` on a pod | 1 m | critical |
| `MongotIndexNotFollowing` | An index is `STALE`, or recovering from an error that is not transient, on a pod | 10 m | warning |
| `MongotIndexBuildRetrying` | The build of an index has failed and started again, on a pod | 15 m | warning |
| `MongotIndexesDifferByPod` | An index is missing on a pod; or it is `STEADY` on every pod, has not been written to for 10 minutes, and its document count differs between pods | 10 m | warning |
| `MongotIndexSearchesFailing` | mongot keeps failing searches on an index: failures less than 5 minutes apart | 5 m | warning |
| `MongotDataPathFillingUp` | The file system under mongot's data path is 70% used or more, on a pod | 30 m | info |
| `MongotDataPathFillingUp` | The same, 80% used or more | 15 m | warning |
| `MongotDataPathFillingUp` | The same, 90% used or more | 5 m | critical |

About the five index alerts:

- **They name the index by its id**, the label `indexId_logString` of mongot's metrics; three also name the pod. The dashboard's section *What does each index hold?* shows the same id.
- **Which states they watch.** mongot answers searches from an index that is `STEADY`, `STALE` or `RECOVERING`, and not from one that is `FAILED` or being built. So `FAILED` is critical after a minute; `STALE` and `RECOVERING_NON_TRANSIENT` are a warning, because results fall behind while searches still answer; `INITIAL_SYNC` and `RECOVERING_TRANSIENT` are no alert, a build and a hiccup being normal.
- **Where the times come from.** `MongotIndexBuildRetrying` waits the 15 minutes that MongoDB's metrics reference uses as the window of its initial-sync exception queries (`rate(mongot_index_stats_indexing_initialSyncExceptions_total[15m])`); the reference gives no hold time of its own. `MongotIndexesDifferByPod` compares an index once it has gone 10 minutes without a write and then waits its 10 minutes, so 20 minutes pass between the last write and the alert. An index written to at least once every 10 minutes is never compared, and no alert names a pod that falls behind on it: the dashboard does, in *Documents indexed, per mongot pod*, *Replication lag, per mongot pod* and the table *Each mongot pod, now*. Those two, the 10 minutes of `MongotIndexNotFollowing` and the 5 of `MongotIndexSearchesFailing` are this chart's choice, with no published figure behind them: change them if they are wrong for you.
- **What a failed search is.** One that reached the index and failed there: an error inside mongot, or a search the index refused, such as an operator on a field the index does not define. In mongot's source `failedQueries` is the sum of the two (`IndexMetricsUpdater.handleQueryException`), and only the per-pod counter `mongot_index_stats_query_invalidQueries_total` tells them apart. Measured on the lab, 2026-10-09: three `autocomplete` searches on a path not indexed for it moved the index's `totalQueries` and `failedQueries` by 3 and `invalidQueries` by 3; three searches with an operator that does not exist moved none of them, because mongot refused them before any index. So a client that keeps sending a search the index cannot run fires `MongotIndexSearchesFailing`. Until chart 0.3.9 the panel *Each index, in the last hour* said a query refused as invalid is not counted: that is true only of one mongot cannot parse.
- **What "differ by pod" compares, and why.** Document counts, of an index that is `STEADY` on every pod and that nothing has written to for 10 minutes. Measured on the lab, 2026-10-09, with the rule as first written (size or documents, at any time):
  - *An index that is written to never agrees.* Each pod is read at its own instant, on the lab the first pod 9 seconds after the other two: with two inserts a second the three pods were 17 to 24 documents apart at every one of 53 readings taken every 15 seconds on the minute (7 to 15 apart when read 4 or 8 seconds later), and the alert fired after its 10 minutes. The counts were equal within a minute of the last write.
  - *Sizes do not agree even when the documents do.* Each pod writes its own index files. The same 605 documents took 112,781 bytes on two pods and 113,402 on the third, and still did after 12 quiet minutes. So sizes are not compared, by the alert or by the number *Indexes that differ by pod*.
  - *A build or a rebuild is not a difference.* Every pod builds at its own pace, and a rebuild keeps the old generation beside the new one; a generation is compared with itself, and only when it is `STEADY` everywhere. From mongot's source and a promtool test, not seen on the lab.
- **One failed search does not fire `MongotIndexSearchesFailing`.** Its 5 minute rate is above 0 for under 5 minutes. Two failures less than 5 minutes apart do, 5 minutes after the first. The alert prints the rate with three decimals: one failure in 5 minutes is 0.003 a second.
- **Tested with promtool, and one of them on the lab.** [`test/alerts.sh`](../../test/alerts.sh) renders the rules and runs [`test/alerts.test.yaml`](../../test/alerts.test.yaml): each alert fires for its index and only for it, after its time and not before; an index being built is not "not following"; an index that is written to, one being built on three pods at their own pace, a rebuild beside its old generation, and one whose size alone differs do not "differ by pod"; one that stays a document short on a pod does, 20 minutes after its last write. On the lab, 2026-10-09: the rule as first written fired on an index that was only being written to; with this one loaded, the same writes for 14 minutes (1,668 documents, the pods 17 to 24 apart at every reading) left it inactive at each of the 30 readings taken of it. None of the five has been seen to fire for its real cause there.

### The volume alert

`MongotDataPathFillingUp` reads the used share of the file system under mongot's data path, per pod: `1 - mongot_system_disk_space_data_path_free_bytes / mongot_system_disk_space_data_path_total_bytes`. It is the number mongot itself acts on. In its source at v1.70.1 a disk monitor computes `(total - usable) / total` of that file system every 5 seconds, and the same panel of the dashboard draws it (*Data volume used, per mongot pod*).

**What mongot does by itself as the disk fills**, whoever is watching:

| Used | What mongot does | In MongoDB's words |
| --- | --- | --- |
| Above 85% | Stops building indexes: a new or rebuilt index waits. Resumes below 80% | "`mongot` disables initial sync. New index builds remain in PENDING. Existing indexes keep operating." |
| Above 90% | Stops following the source, for every index. Resumes below 85% | "`mongot` disables steady-state replication. Existing indexes stop receiving change events from `mongod`. Search results grow increasingly stale." |
| 95% | Exits, and exits again on a restart until space is freed | "`mongot` crashes. Recovery requires freeing disk before `mongot` can restart cleanly." |

The words are from MongoDB's [Recommended Alerts for mongot](https://www.mongodb.com/docs/search/self-managed/current/monitoring/recommended-alerts/), *Disk Fill and mongot Self-Protection Cascade*; the numbers and the two "resumes" are mongot's defaults in `DiskMonitorConfig.java` (0.85 and 0.80, 0.90 and 0.85, 0.95). They can be changed in mongot's own configuration (`advancedConfigs.diskMonitor`); this chart does not set them, and the alert's text assumes the defaults.

**The three levels, and where each number comes from.** The owner set them on 2026-10-09: a first level from 70 to 75%, 80%, and critical at 90%.

| Level | Used | Holds | Why this number |
| --- | --- | --- | --- |
| `info` | 70% | 30 m | MongoDB: "If this metric drops below 30% free, consider having a planning conversation to increase storage." It is also about where a rebuild stops fitting, below |
| `warning` | 80% | 15 m | MongoDB: "Having less than 20% free on the `mongot` dataPath volume can cause availability issues." It is the last level before mongot acts by itself |
| `critical` | 90% | 5 m | mongot stops following the source above it |

MongoDB's own recommended alert is one level later at each step, at 85, 90 and 95%, the three points where mongot acts. These are earlier on purpose: at about 180 to 190 GB of indexes a pod, as the owner reports for a QA cluster, a sync from scratch takes 4 to 5 hours (see *Replication lag*), so the time to act is before mongot does. The hold times are this chart's choice, shorter as the level rises; no published rule for mongot gives one.

- **A pod is in one level at a time.** A level runs from its number up to the next one's, so a pod at 92% is `critical` and not also `warning` and `info`: the console lists one alert for it, not three.
- **Rising into the next level leaves no minute without an alert.** The lower level stays on while the higher one holds, and stops when that one fires. Without that, a notice that the warning is *resolved* would go out at the moment the disk passes 90%. Falling back, the higher alert stops at once and the lower one holds its own time again.
- **A restarted pod is the same alert**: the alert names the namespace and the pod only.
- **Room for a rebuild.** MongoDB: "Plan for roughly 125% of the expected steady-state footprint during a rebuild." mongot keeps the old index beside the new one until the new one can answer, and builds nothing above 85%. So a volume that is more than about 68% used (0.85 / 1.25) cannot take a rebuild of everything on it; that figure is derived here, not MongoDB's. In bytes: 190 GB of indexes are 70% of a 271 GB volume, 75% of 253 GB and 80% of 238 GB.
- **On a shared disk the number is the disk's.** With a hostpath provisioner the data path is on the node's disk: the lab's three pods all read the same 61.6% of a 149 GiB disk on 2026-10-09, of which mongot's indexes are 16 MiB, and would raise three alerts that say the same thing. The alert's text says so. With a volume of its own per pod, the number is that volume's.

**Changing the levels.** They are values of the chart, whole numbers, and must rise. With the release's own values file, as for every upgrade of this chart: `--reuse-values` keeps the old chart's defaults, so from a release of 0.3.10 or earlier these three are absent and the upgrade is refused when the chart renders, `monitoring.alerts.dataPathUsed is missing: ...`.

```bash
# the first level at 75 instead of 70
helm upgrade mongot <chart> -n $NS -f my-values.yaml --timeout 20m --set monitoring.alerts.dataPathUsed.info=75

# MongoDB's own three points
helm upgrade mongot <chart> -n $NS -f my-values.yaml --timeout 20m \
  --set monitoring.alerts.dataPathUsed.info=85 --set monitoring.alerts.dataPathUsed.warning=90 --set monitoring.alerts.dataPathUsed.critical=95

# no info level: only warning and critical
helm upgrade mongot <chart> -n $NS -f my-values.yaml --timeout 20m --set monitoring.alerts.dataPathUsed.info=null
```

Or in a values file:

```yaml
monitoring:
  alerts:
    dataPathUsed:
      info: 75
      warning: 80
      critical: 90
```

A level set to `null` is left out, and the level below it then runs up to the next one that is left; all three `null` leaves the alert out and the other nine in. Levels that do not rise are refused when the chart renders, by name: `monitoring.alerts.dataPathUsed.critical is 90: it must be above warning (95)`. The hold times are not values.

**Where it shows in OpenShift.** In the console under **Observe**, **Alerting**. That page opens on the platform's own alerts that are firing: set the *Source* filter to **User** to see this one, as for every alert of this chart. It needs user workload monitoring on the cluster. A user who is not a cluster administrator also needs the role `monitoring-rules-view` in the namespace (`oc adm policy add-role-to-user monitoring-rules-view <user> -n $NS`): without it the console answers "You don't have access to this section", as it did to the lab's viewer.

**Seen on the lab**, 2026-10-09, with the levels lowered to 50, 55 and 60 so that the lab's 61.3% would count. The critical level went pending for the three pods at 13:21:56Z and was firing 5 minutes later; the two lower levels stayed inactive, as they should for a pod above the top level. The Alertmanager of user workload monitoring held three active alerts, one a pod: "The file system under mongot's data path on mongot-search-0-1 is 61.34% used". The rule and its three alerts were listed by Thanos Querier's rules API, which is what the console's Alerting page reads. Not seen there: the page itself, since the lab's viewer lacks the role above; and the alert rising from one level into the next on a real disk, which is tested with promtool only.

**Not in it: a "full in N days" rule.** The mixins that ship with Kubernetes also alert on a volume predicted to fill. It was looked at and left out: an index store grows in steps (a merge, a rebuild that keeps two copies for a time, then drops one), on the lab the slope of 6 hours was that of the node's other writers, and a restarted pod left a second series whose prediction alone would have fired.

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
