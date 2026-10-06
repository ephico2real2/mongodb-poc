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
wrote chart/mongodb-search-helm/files/mongodb-search.perses.json (16 panels)
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

helm upgrade mongot chart/mongodb-search-helm -n $NS -f my-values.yaml --timeout 20m   # with monitoring.persesDashboard.enabled: true

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

| Section | Panels |
| --- | --- |
| Is search up? | mongot pods up; Envoy pods up; mongot pods Envoy can reach; searches per second; largest share on one mongot pod |
| Is traffic spread across the mongot pods? | Searches per second, per pod; share of searches, per pod |
| Is Envoy healthy? | Requests per second to mongot; open connections from mongod; retries per second; responses by class; latency, 95th percentile |
| How is each mongot pod doing? | Average search latency; search failures per second; replication lag; JVM memory used |

| Way | Ran here | Result |
| --- | --- | --- |
| 1. Container, with podman | Yes; it is what produced the committed file | 16 panels, no placeholders |
| 2. `percli` binary | No: no `percli` is installed on this workstation | Same command as Way 1 without the container |
| 3. Server `/api/migrate` on the lab | Yes | Same 16 panels, queries, units and sections as Way 1 |

On the lab, the Perses operator reported both objects `Available=True` after `helm upgrade`, and all 16 queries returned series when run against the lab's Prometheus. The dashboard was not opened in the console for this document.
