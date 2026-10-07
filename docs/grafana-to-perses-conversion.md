# Converting the Grafana Dashboard to Perses

Oct 6, 2026

## Overview

The chart ships one dashboard, **MongoDB Search**, in two forms:

| File | For | Edited by hand? |
| --- | --- | --- |
| `chart/mongodb-search-helm/files/mongodb-search.json` | Grafana | Yes. It is the only source |
| `chart/mongodb-search-helm/files/mongodb-search.perses.json` | Perses, in the OpenShift console | No. It is generated from the Grafana file |

This document records the commands that turn the first file into the second. Use Perses **0.54.0**: it is the Perses version inside the Cluster Observability Operator 1.5.3 that runs on the lab.

Both files contain two tokens, `__NAMESPACE__` and `__SEARCH__`. The chart replaces them with its namespace and `search.name` when it renders, so every query reads that one search setup.

**Before you start**

- [ ] `podman` or `docker`, or `percli` 0.54.0 with its plugins unpacked
- [ ] `python3`
- [ ] For Way 3 only: `oc` logged in to a cluster that runs the Cluster Observability Operator

## The short way

One script converts, checks and writes the Perses file:

```bash
scripts/perses-dashboard.sh
```

Expected:

```text
wrote chart/mongodb-search-helm/files/mongodb-search.perses.json (27 panels)
```

It uses `percli` from your `PATH` when its unpacked plugins are at `~/.local/share/perses/plugins`; otherwise it runs `percli` from the official Perses image with podman or docker. Then run the chart tests, which fail if the two files disagree:

```bash
test/chart.sh
```

The rest of this document is what the script does, as separate commands.

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

The converter leaves each query without a usable datasource name: `percli` leaves it empty and the server writes `${DS_PROMETHEUS}`. The chart creates a datasource named `<search.name>-thanos` beside the dashboard, so every query must name it. This also checks that every panel and query matches the Grafana file.

```bash
python3 - chart/mongodb-search-helm/files/mongodb-search.json /tmp/perses-work/raw.perses.json \
  > chart/mongodb-search-helm/files/mongodb-search.perses.json <<'PY'
import json, sys
grafana = json.load(open(sys.argv[1]))
spec = json.load(open(sys.argv[2]))["spec"]
want = {p["title"]: p["targets"][0]["expr"] for p in grafana["panels"] if p["type"] != "row"}
got = {p["spec"]["display"]["name"]: p["spec"]["queries"][0]["spec"]["plugin"]["spec"]["query"] for p in spec["panels"].values()}
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

| Section | Panels |
| --- | --- |
| Is search up? | mongot pods up; Envoy pods up; mongot pods in Envoy; searches per second; largest share on one pod |
| Is traffic spread across the mongot pods? | Searches per second, per pod; share of searches, per pod |
| Is Envoy healthy? | Requests per second to mongot; open connections from mongod; retries per second; responses by class; latency, 95th percentile |
| How is each mongot pod doing? | Average search latency; search failures per second; replication lag; JVM memory used; CPU used; JVM heap used, percent of limit; time in garbage collection; uptime; search work run outside the parallel pool |
| Does every mongot pod hold the same data? | Index size; documents indexed; indexes not STEADY; indexes in catalog; data volume used; indexing operations per second |

| Way | Ran here | Result |
| --- | --- | --- |
| 1. Container, with podman | Yes; it is what produced the committed file | 27 panels, no placeholders (16 before chart 0.3.0) |
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

### Colours (chart 0.3.1, issue #35)

On Oct 6, 2026 the lines of a panel were reported as too alike in the console. Measured in Perses 0.54.0 before the change: the three mongot pods drew as `#cb93b4`, `#4e6386` and `#d6bb86`, the two Envoy pods as two purples, with the closest pair at CIE76 ΔE 26 and a contrast as low as 1.9:1 on the background. The dashboard set no palette, so Perses made a colour from each series' name.

Perses 0.54 offers two palettes, neither with three well-separated first colours (its categorical one starts sky blue, green, blue), and a fixed colour per query. So every line now has a query of its own and a fixed colour: blue, red, yellow, and purple for a fourth. What each colour means is in the [chart README](../chart/mongodb-search-helm/README.md#colours).

| Check | Result |
| --- | --- |
| Every query through Thanos Querier | 90 of 90 `success`, no warning; 64 series, as before |
| Each pod on its own query | mongot pods 0, 1, 2 on the first three, nothing on the fourth; the two Envoy pods on the first two |
| One refresh, 15 minutes at a 30 s step | 0.16 s in all for the 90 queries |
| In the OpenShift console, light and dark | 5 of 5 sections, 27 panels drawn; no "No data", "NaN", "Forbidden" or warning sign |
| In a Grafana through the sidecar | 27 panels, 90 queries, line width 3, the same four colours; the page drew them |
| Ordering the Envoy pods | By Envoy's own uptime the first pod changed between steps (64 and 48 of 121); by `kube_pod_start_time`, the same pod at every step of nine range queries |

`scripts/perses-dashboard.sh` carries each colour set by query in the Grafana source into the Perses form, and compares every query of every panel.

Not validated: a `GrafanaDashboard` of the grafana-operator pointing at the ConfigMap. The lab's operator watches one namespace, `group-sync-dashboard`, which belongs to another project, and its data source is limited to that namespace's metrics.
