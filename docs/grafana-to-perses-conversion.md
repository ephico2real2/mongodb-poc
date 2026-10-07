# Converting the Grafana Dashboard to Perses

Oct 6, 2026

## Overview

The chart ships one dashboard, **MongoDB Search**, in two forms:

| File | For | Edited by hand? |
| --- | --- | --- |
| `chart/mongodb-search-helm/files/mongodb-search.json` | Grafana | Yes. It is the only source |
| `chart/mongodb-search-helm/files/mongodb-search.perses.json` | Perses, in the OpenShift console | No. It is generated from the Grafana file |

This document records the commands that turn the first file into the second. Use Perses **0.54.0**: it is the Perses version inside the Cluster Observability Operator 1.5.3 that runs on the lab. The lab's server carries older panel plugins than the `perses:v0.54.0` image that `percli` runs from: read from its `/api/v1/plugins` on 2026-10-07, PieChart 0.13.1 against 0.14.0, Table 0.11.2 against 0.13.0, StatChart and StatusHistoryChart 0.12.1 against 0.13.0, TimeSeriesChart 0.13.0-beta.0 against 0.13.0. Every field the script writes was accepted and drawn by the lab's versions; check that again when either side moves.

Both files contain two tokens, `__NAMESPACE__` and `__SEARCH__`. The chart replaces them with its namespace and `search.name` when it renders, so every query reads that one search setup.

**Before you start**

- [ ] [diagram-kit](https://github.com/ephico2real2/diagram-kit) 0.2.0 or later, for its `perses-dashboard` command: `python3 -m venv .venv && .venv/bin/pip install "diagram-kit @ git+https://github.com/ephico2real2/diagram-kit@v0.2.2"`
- [ ] `podman` or `docker`, or `percli` 0.54.0 with its plugins unpacked
- [ ] `python3`
- [ ] For Way 3 only: `oc` logged in to a cluster that runs the Cluster Observability Operator

## The short way

One script converts, checks and writes the Perses file. It calls [diagram-kit](https://github.com/ephico2real2/diagram-kit)'s `perses-dashboard`, the one converter our repositories share (MPL-2.0):

```bash
scripts/perses-dashboard.sh
```

Expected:

```text
wrote chart/mongodb-search-helm/files/mongodb-search.perses.json (29 panels)
```

It takes `perses-dashboard` from `PERSES_DASHBOARD`, from your `PATH`, or from `.venv/bin`, and the command runs `percli` from the Perses image named by `PERSES_IMAGE` (default `docker.io/persesdev/perses:v0.54.0`) with podman or docker. Then run the chart tests, which fail if the two files disagree:

```bash
test/chart.sh
```

The rest of this document is what that command does, as separate commands. Since chart 0.3.2 the script also carries over what `percli` does not (the pie's colours and labels, the table's coloured cells and column order, an open-ended range), so use the script to produce the committed file; [Colours and chart kinds](#colours-and-chart-kinds-charts-031-and-032-issue-35) lists what it adds.

## Way 1: the container (nothing to install)

The image `docker.io/persesdev/perses:v0.54.0` contains `percli`. Its plugins are packed inside the image, and the Perses server unpacks them when it starts, so start the server first and run `percli` inside it.

```bash
mkdir -p /tmp/perses-work
cp chart/mongodb-search-helm/files/mongodb-search.json /tmp/perses-work/dashboard.json
chmod -R a+rX /tmp/perses-work

# Start the server; it unpacks the plugins
podman run -d --name percli-convert -v /tmp/perses-work:/work docker.io/persesdev/perses:v0.54.0
sleep 8

# Check the version (expect 0.54.0)
podman exec percli-convert /bin/percli version

# Convert
podman exec percli-convert /bin/percli migrate -f /work/dashboard.json --format native \
  --plugin.path /etc/perses/plugins --use-default-datasource -o json > /tmp/perses-work/raw.perses.json

podman rm -f percli-convert
```

`percli` prints `failed query migration: no plugins found matching target` once per query. It is harmless: every query is carried over unchanged (checked in Step 2 below).

With docker, replace `podman` with `docker`.

## Way 2: the percli binary

Install `percli` 0.54.0 and unpack its plugins as described in [openshift-coo-helm, `docs/percli.md`](https://github.com/ephico2real2/openshift-coo-helm/blob/main/docs/percli.md). Then:

```bash
percli migrate -f chart/mongodb-search-helm/files/mongodb-search.json --format native \
  --plugin.path ~/.local/share/perses/plugins --use-default-datasource -o json > /tmp/perses-work/raw.perses.json
```

`--plugin.path` must point at **unpacked** plugins. Pointed at the packed archives, `percli` exits 0 and turns every panel into a placeholder.

## Way 3: the Perses server on the cluster

The Perses server that the Cluster Observability Operator runs has its own converter at `/api/migrate`. On the lab it answered without a login.

```bash
# Reach the server from your machine
oc port-forward -n openshift-cluster-observability-operator svc/perses 18080:8080 &

# Wrap the Grafana JSON in the request body the endpoint expects
python3 -c 'import json; print(json.dumps({"input": {}, "grafanaDashboard": json.load(open("chart/mongodb-search-helm/files/mongodb-search.json"))}))' > /tmp/perses-work/body.json

# Convert (the server speaks HTTPS; -k accepts its service certificate)
curl -sk -X POST -H 'Content-Type: application/json' --data @/tmp/perses-work/body.json \
  https://localhost:18080/api/migrate > /tmp/perses-work/raw.perses.json

kill %1     # stop the port-forward
```

## After any of the three ways

### Step 1: Check nothing became a placeholder

```bash
grep -c 'Migration from Grafana not supported' /tmp/perses-work/raw.perses.json    # must print 0
```

### Step 2: Name the datasource and keep only the dashboard's spec

The converter leaves each query without a usable datasource name: `percli` leaves it empty and the server writes `${DS_PROMETHEUS}`. The chart creates a datasource named `<search.name>-thanos` beside the dashboard, so every query must name it. This also checks that every query of every panel matches the Grafana file. It leaves out what `scripts/perses-dashboard.sh` adds for the pie, the table and the status history; the committed file comes from the script.

```bash
python3 - chart/mongodb-search-helm/files/mongodb-search.json /tmp/perses-work/raw.perses.json \
  > chart/mongodb-search-helm/files/mongodb-search.perses.json <<'PY'
import json, sys
grafana = json.load(open(sys.argv[1]))
spec = json.load(open(sys.argv[2]))["spec"]
want = {p["title"]: [t["expr"] for t in p["targets"]] for p in grafana["panels"] if p["type"] != "row"}
got = {p["spec"]["display"]["name"]: [q["spec"]["plugin"]["spec"]["query"] for q in p["spec"]["queries"]] for p in spec["panels"].values()}
assert got == want, "the converted panels or queries differ from the Grafana ones"
for p in spec["panels"].values():
    for q in p["spec"]["queries"]:
        q["spec"]["plugin"]["spec"]["datasource"] = {"kind": "PrometheusDatasource", "name": "__SEARCH__-thanos"}
spec["variables"] = [v for v in spec.get("variables", []) if v["spec"]["name"] != "DS_PROMETHEUS"]
json.dump(spec, sys.stdout, indent=2); print()
PY
```

### Step 3: Test, install and check

```bash
test/chart.sh

helm upgrade mongot chart/mongodb-search-helm -n $NS -f my-values.yaml --timeout 20m   # the Perses dashboard is on by default

oc get persesdatasource mongot-thanos -n $NS -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}'
oc get persesdashboard mongot-search -n $NS -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}'
```

Expected: `True` twice. Then open **Observe → Dashboards (Perses)** in the console, pick the project, and open **MongoDB Search**.

A viewer needs `view` in the namespace to open the dashboard and `cluster-monitoring-view` to see its data. The datasource sends each viewer's own login to Thanos Querier on port 9091; nothing is stored.

## Changing the dashboard

1. Edit `chart/mongodb-search-helm/files/mongodb-search.json`. To edit it in a Grafana, first replace `__NAMESPACE__` and `__SEARCH__` with real values, and put the tokens back before you save the file here.
2. Keep each panel under the row whose question it answers. A Grafana row becomes a Perses section.
3. Run `scripts/perses-dashboard.sh`, then `test/chart.sh`, and commit both files together.

## What the conversion produced

Oct 6, 2026, Perses 0.54.0. Ways 1 and 3 were run, and after Step 2 they gave the same file, byte for byte: 16 panels (5 stat, 11 time series) in 4 sections, with every query and every unit identical to the Grafana file.

Since chart 0.3.0 the dashboard has 27 panels (5 stat, 22 time series) in 5 sections. Way 1 produced that file, and the 16 panels it already had came out identical to before; Way 3 was not run again.

Chart 0.3.1 kept those 27 panels and gave every line a query of its own: 90 queries. It was merged and never published. Since chart 0.3.2 it has 29 panels (5 stat, 21 time series, a pie, a table and a status history) and 97 queries, produced by the script through Way 1.

| Section | Panels |
| --- | --- |
| Is search up? | mongot pods up; Envoy pods up; mongot pods in Envoy; searches per second; largest share on one pod |
| Is traffic spread across the mongot pods? | Searches per second, per pod; share of searches, per pod; share of searches now, by pod (a pie) |
| Is Envoy healthy? | Requests per second to mongot; open connections from mongod; retries per second; responses by class; latency, 95th percentile |
| How is each mongot pod doing? | Average search latency; search failures per second; replication lag; JVM memory used; CPU used; JVM heap used, percent of limit; time in garbage collection; uptime; search work run outside the parallel pool |
| Does every mongot pod hold the same data? | Each mongot pod, now (a table); index size; documents indexed; indexes not STEADY (a status history); indexes in catalog; data volume used; indexing operations per second |

| Way | Ran here | Result |
| --- | --- | --- |
| 1. Container, with podman | Yes; it is what produced the committed file | 29 panels, no placeholders (16 before chart 0.3.0, 27 in it) |
| 2. `percli` binary | No: no `percli` is installed on this workstation | Same command as Way 1 without the container |
| 3. Server `/api/migrate` on the lab | Yes | Same 16 panels, queries, units and sections as Way 1 |

## Validated

Oct 6, 2026, on the lab (namespace `mongodb-poc`), with searches sent through the lab's search GUI during the checks. Screenshots of both forms are in the [chart README](../chart/mongodb-search-helm/README.md#dashboards).

| Check | How | Result |
| --- | --- | --- |
| The Perses objects are accepted | `oc get persesdashboard,persesdatasource` conditions | Both `Available=True` |
| The lab's Perses server holds the dashboard | `GET /api/v1/projects/mongodb-poc/dashboards/mongot-search` on the server, with a login | 16 panels, 4 sections |
| Every panel gets data through the Perses datasource | Each panel's query sent as the Perses UI sends it: `POST /proxy/projects/mongodb-poc/datasources/mongot-thanos/api/v1/query`, with a viewer's login | 16 of 16 panels returned series |
| The Perses dashboard draws | The chart's rendering loaded into a local Perses 0.54.0 with its web page, reading the lab's Prometheus | All 16 panels drawn, light and dark |
| The Grafana dashboard draws | The chart's ConfigMap JSON loaded from a file by a local Grafana 13.2.3, reading the lab's Prometheus | All 16 panels drawn, light and dark |

Two defects were found by these checks and fixed in the Grafana source:

- **Every Grafana panel read "No data".** The file named its data source `${DS_PROMETHEUS}` but defined no variable of that name, so a Grafana that loads the file from a ConfigMap reported `Datasource ${DS_PROMETHEUS} was not found`. The dashboard now carries its own data source variable.
- **Legends were cut off in Perses.** Three Envoy panels shared a row, and the second pod name did not fit. They are now two to a row.

Three more were reported from the console's Perses page later the same day, and fixed in the Grafana source and the chart:

- **A warning sign on two Envoy panels.** `rate()` on `envoy_cluster_upstream_rq_retry` and `envoy_cluster_upstream_rq_xx` came back from Thanos Querier with the warning *metric might not be a counter, name does not end in _total/_sum/_count/_bucket*. Both are counters; only their names lack the suffix. The chart's Envoy ServiceMonitor now adds `_total` at the scrape, and the panels and the retry alert use the new names ([chart README](../chart/mongodb-search-helm/README.md#envoy-counters-without-_total)). Measured through Thanos Querier after the change: 16 of 16 queries, no warning.
- **"NaN%" for the largest share when no search ran.** The query divided zero by zero. It now divides only when there were searches, and reads 0% otherwise.
- **A stat title cut short.** "Largest share on one mongot pod" did not fit its panel in the console, and "mongot pods Envoy can reach", as long and in a narrower panel, could not either. They are now "Largest share on one pod" and "mongot pods in Envoy".

Both dashboards were drawn again after these changes, this time reading the lab's Thanos Querier, as the console does: all 16 panels drawn, none with a warning sign.

### In the console, and through a Grafana sidecar

Later on Oct 6, 2026, the two checks that had been left open were run on the lab, with searches sent through the search GUI.

| Check | How | Result |
| --- | --- | --- |
| The dashboard inside the OpenShift console | [`scripts/capture-console-dashboard.py`](../scripts/capture-console-dashboard.py): a browser logs in to the lab's console as `developer` and opens **Observe → Dashboards (Perses)**, project `mongodb-poc` | 4 of 4 sections, 16 panels drawn; no "No data", no "NaN", no "Forbidden", no warning sign |
| Who can open it | `oc auth can-i get persesdashboards -n mongodb-poc --as developer`, before and after binding `view`, `persesdashboard-viewer-role` and `persesdatasource-viewer-role` in the namespace | `no`, then `yes`; the data came with `cluster-monitoring-view`, which the lab gives every logged-in user |
| Responses of 400 or above on that page, after the login | The script's list | Five `403` and one `500`, none of them the dashboard's: silences, `infrastructures/cluster`, `provisionings`, `groups`, Perses global datasources (the dashboard uses its namespace's own), and the console's package check |
| A Grafana sidecar loads the chart's ConfigMap | The Grafana Helm chart 10.5.15 with `sidecar.dashboards` on the label `grafana_dashboard: "1"`, installed in `mongodb-poc` with [`test/grafana-sidecar/`](../test/grafana-sidecar/); then `helm upgrade` of the search release with `monitoring.grafanaDashboard=true` | Before: Grafana's search for the dashboard returned `[]`. 37 s after the upgrade started: the sidecar logged `Writing /tmp/dashboards/mongodb-search.json`, and Grafana listed *MongoDB Search*, 16 panels in 4 rows, no token left in it |
| Every panel gets data in that Grafana | Each panel's query sent through `POST /api/ds/query` to its Thanos Querier data source (port 9091, the pod's own token) | 16 of 16 answered `200` with rows and no notice; the page drew all 16 |

Everything added for these checks was removed afterwards: the Grafana, its Role, the three RoleBindings, and `monitoring.grafanaDashboard` on the lab release. The mongot and Envoy pods were not restarted.

**On the lab since Oct 7, 2026, and kept.** The three RoleBindings were created again for the checks of charts 0.3.1 and 0.3.2 and stay in `mongodb-poc`, so that the dashboard can be opened and tested as a viewer at any time:

| RoleBinding | ClusterRole | Subject |
| --- | --- | --- |
| `console-validate-view` | `view` | User `developer` |
| `console-validate-persesdashboard-viewer-role` | `persesdashboard-viewer-role` | User `developer` |
| `console-validate-persesdatasource-viewer-role` | `persesdatasource-viewer-role` | User `developer` |

They are lab objects, made with `oc create rolebinding`; the chart does not create them and a `helm upgrade` or `helm uninstall` leaves them alone. Without them `developer` cannot open the dashboard in the console, and [`scripts/capture-console-dashboard.py`](../scripts/capture-console-dashboard.py) fails at the project. To remove them: `oc delete rolebinding console-validate-view console-validate-persesdashboard-viewer-role console-validate-persesdatasource-viewer-role -n mongodb-poc`.

The method for the sidecar follows the one recorded by the `openshift-ipsec-nas` project (its evidence `kind/03`); the console there was captured through a console server run on a workstation, and here through the cluster's own console with a viewer's login.

### The mongot process and data panels (chart 0.3.0)

Later on Oct 6, 2026, eleven panels were added from mongot's own metrics; what each reads is in the [chart README](../chart/mongodb-search-helm/README.md#the-mongot-process-and-data-panels). Before any file was changed, the eleven queries were run through the lab's Thanos Querier; after, the whole dashboard was checked the same ways as above.

| Check | How | Result |
| --- | --- | --- |
| The 16 panels it already had are untouched | The Grafana source compared before and after; the regenerated Perses file compared panel by panel | 0 lines removed from either file; 16 of 16 Perses panels identical, and their places in the layout |
| Every query answers | All 27 queries of the lab's `PersesDashboard` through Thanos Querier | 27 of 27 `success`, with series and no warning |
| What one refresh costs | Each query over 15 minutes at a 30 s step, through Thanos Querier | 0.03 s in total for the 16, 0.02 s for the 11 added |
| The dashboard inside the OpenShift console | `scripts/capture-console-dashboard.py`, as `developer` with the three reader roles | 5 of 5 sections, 27 panels drawn; no "No data", "NaN", "Forbidden" or warning sign |
| Through a Grafana sidecar | `test/grafana-sidecar/`, with `monitoring.grafanaDashboard=true` | Listed with 27 panels in 5 rows; 27 of 27 queries answered through its Thanos Querier data source; the page drew all 27 |

Two statements made while planning were corrected by these measurements. `mongot_jvm_memory_max_bytes` summed over every memory area gives 1.84 GB, which includes the non-heap pools and a `-1`; the heap's maximum is 518,979,584 bytes, so the panel divides heap by heap. And `rejectedConcurrentSearchExecutionCount` does not count refused searches: mongot's source (`MeteredCallerRunsPolicy`, in `LuceneIndexFactory.java`) runs the work on the calling thread when the pool is full.

On the lab, three of the new panels stayed at zero throughout (indexes not `STEADY`, indexing operations, work outside the pool), and *data volume used* shows the node's disk, because the lab's volumes come from a hostpath provisioner. The roles, the Grafana and its Role were removed again after the checks.

### Colours and chart kinds (charts 0.3.1 and 0.3.2, issue #35)

On Oct 6, 2026 the lines of a panel were reported as too alike in the console. Measured in Perses 0.54.0 before the change: the three mongot pods drew as `#cb93b4`, `#4e6386` and `#d6bb86`, the two Envoy pods as two purples, with the closest pair at CIE76 ΔE 26 and a contrast as low as 1.9:1 on the background. The dashboard set no palette, so Perses made a colour from each series' name.

Perses 0.54 offers two palettes, neither with three well-separated first colours (its categorical one starts sky blue, green, blue), and a fixed colour per query. So every line now has a query of its own and a fixed colour from the Tableau 10 palette: blue, red, yellow, and purple for a fourth. What each colour means, how the shades are drawn and why two panels are stacked is in the [chart README](../chart/mongodb-search-helm/README.md#colours-and-shades).

**What converts.** Tried in Perses 0.54.0 with one panel of each Grafana kind:

| Grafana panel | Perses 0.54.0 |
| --- | --- |
| `timeseries`, `stat`, `gauge`, `piechart`, `table`, `status-history` | The same kind |
| `bargauge` | A bar chart |
| `barchart`, `histogram`, `heatmap`, `state-timeline` | A placeholder that says the migration is not supported |

**What the script adds after `percli`**, each from the Grafana source, so that the Grafana file stays the only one edited:

| In the Grafana source | In the Perses file | Why `percli` is not enough |
| --- | --- | --- |
| The pie's colours per query | `colorPalette`, in the order of the queries | A Perses pie takes a list by position, not a colour per query: the source keeps each pie query to one series |
| The pie's `displayLabels: []` | `showLabels: false` | `percli` writes `showLabels: true` for any `displayLabels`, an empty list included |
| A value mapping with a colour on the table's pod column | `cellSettings` with `backgroundColor`, plus `textColor` black or white, whichever contrasts more (WCAG) | Perses keeps the theme's text colour, white on yellow in the dark theme; and `percli` drops a mapping by pattern, used for any pod after the third |
| The table's columns | The pod column first | `percli` puts a renamed column after the others; it hides the time column itself, from the `organize` transformation |
| A range mapping open at one end | The absent bound left out | It comes over as `null`, which Perses refuses |

`percli` itself carries over, measured by running it alone on the source: each query's colour, fill opacity and line style, set by an override on the query's `refId` (they become `querySettings`: `colorMode: fixed`, `colorValue`, `areaOpacity`, `lineStyle`); stacking (`stacking.mode: normal` becomes `stack: all`); and an axis minimum or maximum.

Measured on the lab on Oct 6 and 7, 2026, with searches running through the search GUI:

| Check | Result |
| --- | --- |
| Every query through Thanos Querier | 97 of 97 `success`, no warning or notice; 85 series |
| Each pod on its own query | mongot pods 0, 1, 2 on the first three, nothing on the fourth; the two Envoy pods on the first two |
| Queries with no series | 26: the fourth query of each of the 20 per-pod charts (no fourth pod), the third Envoy pod in three panels, and three response classes Envoy had not counted: 4xx, 5xx and any other |
| One refresh, 15 minutes at a 30 s step | 0.45 s in all for the 97 queries |
| In the OpenShift console, light and dark | 5 of 5 sections, 29 panels drawn; no "No data", "NaN", "Forbidden" or warning sign |
| The legend of a panel a third of the page wide | Three pod names take two lines; in the console the second line was cut at a panel height of 8, 9 and 10 units and drawn at 11. The legend's `size` made no difference |
| In a Grafana 12.3.1 through the sidecar | 29 panels and 97 queries listed, the two traffic panels stacked, the six colours only; 97 of 97 queries answered through its Thanos Querier data source, the same 26 with no series; the page drew every panel in light and dark, the table's pod cells in blue, red and yellow, and the state legend reading `STEADY` |
| Ordering the Envoy pods | By Envoy's own uptime the first pod changed between steps (64 and 48 of 121); by `kube_pod_start_time`, the same pod at every step of nine range queries |

Drawn again on Oct 7, 2026 for clusters the lab does not have. The chart's rendering (`helm template`) was loaded into a Grafana 12.3.1 and a Perses 0.54.0 container on a workstation, reading series shaped like the lab's from a local Prometheus 3.15.0, one namespace per case; the lab's own three pods were drawn in the same two through the lab's Thanos Querier. "Before" is the dashboard with each pod selected through its `up` series and the pie read over the whole range.

| Case | Grafana 12.3.1 | Perses 0.54.0 |
| --- | --- | --- |
| One, two, three, five and twelve pods, even traffic | Each pod on its colour in every chart; from the fourth pod on, one purple slice *further pods* and purple table cells. The same before | The same. The same before |
| One pod takes every search | One slice in that pod's colour; the other two at 0 in the legend | The same |
| A pod that is a target with no rate yet | Its place kept in the pie, at 0. The same before | Its place kept. Before: the third pod's slice `#ff0000` for as long as the first had no sample |
| No search for 20 minutes, the range reaching back to searches | Nothing drawn in the pie. Before: three slices | An empty circle. Before: three slices |
| A pod being replaced, its `up` gone | Its own colour throughout. Before: purple in seven charts and named twice in the legend; in the pie its share as *further pods* beside its stale slice | The pie in the pods' three colours. Before: a fourth, purple slice |
| A pod gone for 20 minutes | The pie: the two others, and its place at 0. Before: its stale slice and a slice *further pods* | The same. Before: the same two stale slices |
| The lab's three pods, searches running | Three slices in blue, red and yellow | The same |
| The pie in 750 states of the first three pods (serving, idle, just started, just gone, absent) with and without further pods | None wrong. Before: 366, a share under another name | None wrong. Before: 519, those or a colour off its owner |
| Uptime of the lab's pods over 9 minutes | An axis from 0 with four different tick labels. Before: `17.4 hours` twice | An axis from 0, the line where it was, near the top. Before: from 14.2 h |
| The lab's 2xx responses per second at steady traffic | An axis from 0. Before: from 0.725 to 0.85, the shade starting there | From 0, as before |
| A pod replaced 12 minutes ago, CPU chart | Named once. Before: twice, once for each address | Named once. Before: twice |
| No search for 20 minutes, the words in the pie | *No search in the last 5 minutes*, in place of Grafana's own *No data*, which a failed query also shows | An empty circle, no words |
| A Grafana with two Prometheus data sources, the second by name the default | Opens on the default. Before: on the first by name, with "No data" in nine places on the first screen | Not in the Perses form: its queries name the chart's own datasource |

`scripts/perses-dashboard.sh` compares every query of every panel with the Grafana source, and `test/chart.sh` checks the colours, shades, line styles, legends and the table's cells in both files, and that each per-pod query selects its pod by name and the pie is read at the end of the range.

Not validated: a `GrafanaDashboard` of the grafana-operator pointing at the ConfigMap. The lab's operator watches one namespace, `group-sync-dashboard`, which belongs to another project, and its data source is limited to that namespace's metrics.
