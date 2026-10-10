#!/usr/bin/env bash
# Template tests for chart/mongodb-search-helm, no cluster needed:  test/chart.sh
# Needs helm (3 or 4) and python3; uses yq and shellcheck when they are installed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
CHART=chart/mongodb-search-helm
RUNBOOK=docs/mongot-envoy-mtls-fresh-install-runbook.md
REMOTE=${CHART}/examples/values-dvh-gp6-rnd.yaml
LAB=${CHART}/examples/values-crc.yaml
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
render() { helm template mongot "${CHART}" -n dvh-gp6-rnd -f "${REMOTE}" "$@" 2>&1; }
# kinds/names of one rendering, one per line: "Kind/name"
objects() { render "$@" | python3 -c '
import sys, re
for doc in sys.stdin.read().split("\n---"):
    k = re.search(r"^kind: (\S+)", doc, re.M); n = re.search(r"^  name: (\S+)", doc, re.M)
    if k and n: print(f"{k.group(1)}/{n.group(1)}")'; }
has()  { grep -qx "$2" <<<"$1"; }
refused() { render "$@" >/dev/null 2>&1 && bad "the schema refuses $1" || ok "the schema refuses $1"; }

helm lint "${CHART}" -f "${REMOTE}" >/dev/null 2>&1 && ok "helm lint (runbook values)" || bad "helm lint (runbook values)"

# The package: the prerequisites script travels with the chart, and nothing that looks like a key does, even when
# it was left in the chart's directory. (A copy is packaged: the chart's own directory is not written to.)
pkg="$(mktemp -d)"
cp -R "${CHART}" "${pkg}/chart"
mkdir "${pkg}/chart/some-namespace"
for f in some-namespace/ent-mongot-search-cert.secret.yaml some-namespace/ent-trust-bundle.configmap.yaml left.pem left.key left.crt key.pass; do echo x > "${pkg}/chart/${f}"; done
helm package "${pkg}/chart" -d "${pkg}" >/dev/null 2>&1
packed="$(tar -tzf "${pkg}"/mongodb-search-helm-*.tgz 2>/dev/null)"
grep -qx 'mongodb-search-helm/generate-mongodbsearch-prerequisites.sh' <<<"${packed}" \
  && ok "the package holds generate-mongodbsearch-prerequisites.sh" || bad "the package lacks the prerequisites script"
# The volume script and the three documents on volumes and scaling travel with the chart too: they are what an
# operator of the chart reads beside its values.
for f in expand-mongot-volumes.sh volumes.md scaling.md volume-expansion-runbook.md; do
  grep -qx "mongodb-search-helm/${f}" <<<"${packed}" || bad "the package lacks ${f}"
done
ok "the package holds the volume script, volumes.md, scaling.md and the expansion runbook"
# The hooks send their reader to two of those documents by name.
grep -q 'volume-expansion-runbook.md' "${CHART}/templates/40-wait.yaml" && grep -q 'volumes.md' "${CHART}/templates/00-preflight.yaml" \
  && ok "the gate names the expansion runbook and the preflight names volumes.md" || bad "a hook no longer names its document"
grep -qE '\.secret\.yaml$|\.configmap\.yaml$|\.pem$|\.key$|\.pass$|left\.crt$' <<<"${packed}" \
  && bad "the package holds a key, a certificate or a passphrase file: $(grep -E 'secret|configmap|left|pass' <<<"${packed}" | tr '\n' ' ')" \
  || ok ".helmignore keeps keys, certificates and passphrase files out of the package"
rm -rf "${pkg}"
helm lint "${CHART}" -f "${LAB}" >/dev/null 2>&1 && ok "helm lint (lab values)" || bad "helm lint (lab values)"

out="$(render)"; [[ $? -eq 0 ]] && ok "renders with the runbook values" || bad "renders with the runbook values: ${out:0:300}"
helm template mongot "${CHART}" -n mongodb-poc -f "${LAB}" >/dev/null 2>&1 && ok "renders with the lab values" || bad "renders with the lab values"
helm template mongot "${CHART}" -n x >/dev/null 2>&1 && bad "the defaults alone are refused (no hostname, no source)" || ok "the defaults alone are refused (no hostname, no source)"

# The operator: Manual, pinned, and both the approver and the gate aim at the same CSV.
grep -q '^  installPlanApproval: Manual$' <<<"$out" && ok "Manual approval" || bad "Manual approval"
grep -q '^  startingCSV: mongodb-kubernetes.v1.13.0$' <<<"$out" && ok "the Subscription starts at the pinned CSV" || bad "startingCSV"
[[ "$(grep -c 'value: "mongodb-kubernetes.v1.13.0"' <<<"$out")" == 2 ]] && ok "the approver and the gate target the pinned CSV" || bad "TARGET in approver and gate"
app="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' ${CHART}/Chart.yaml)"
grep -q "^  version: \"${app}\"$" ${CHART}/values.yaml && ok "appVersion equals operator.version" || bad "appVersion ${app} differs from operator.version"
grep -q "as mongodb-kubernetes ${app} installs it" ${CHART}/crds/mongodbsearch.mongodb.com.yaml && ok "the CRD copy is from the same operator version" || bad "the CRD copy is not from operator ${app}: run scripts/refresh-mongodbsearch-crd.sh"
! grep -q 'kind: ClusterRole' <<<"$out" && ok "no ClusterRole or ClusterRoleBinding anywhere" || bad "the chart renders cluster-scoped RBAC"

# The MongoDBSearch and the Route equal the runbook's Steps 6a and 6d (needs yq to read both sides).
if command -v yq >/dev/null; then
  rb="$(mktemp -d)"
  awk -v d="${rb}" '/^```yaml/{f=1;n++;next} /^```/{f=0} f{print > (d "/" n ".yaml")}' "${RUNBOOK}"
  for kind in MongoDBSearch Route; do
    want="$(yq -o=json -I=0 '.spec | sort_keys(..)' "$(grep -l "^kind: ${kind}$" "${rb}"/*.yaml)")"
    got="$(render | yq -o=json -I=0 "select(.kind == \"${kind}\") | .spec | sort_keys(..)")"
    [[ -n "$want" && "$got" == "$want" ]] && ok "${kind} spec equals the runbook's" || bad "${kind} spec differs from the runbook: ${got:0:200} != ${want:0:200}"
  done
  rm -rf "${rb}"
else
  printf 'skip  runbook comparison (yq is not installed)\n'
fi

# The namespace: the value wins, and without it every object follows helm's -n.
ns_of() { grep -E '^  namespace: ' | sort -u | tr -d ' ' | tr '\n' ' '; }
[[ "$(helm template mongot "${CHART}" -n elsewhere -f "${REMOTE}" | ns_of)" == "namespace:dvh-gp6-rnd " ]] \
  && ok "the namespace value places every object, whatever -n says" || bad "namespace value: $(helm template mongot "${CHART}" -n elsewhere -f "${REMOTE}" | ns_of)"
[[ "$(helm template mongot "${CHART}" -n team-a -f "${REMOTE}" --set namespace= | ns_of)" == "namespace:team-a " ]] \
  && ok "an empty namespace value falls back to -n" || bad "namespace fallback"
helm template mongot "${CHART}" -n elsewhere -f "${REMOTE}" | grep -A1 'name: NAMESPACE' | grep -q 'value: "elsewhere"' \
  && bad "a Job still reads the release namespace" || ok "the Jobs work in the namespace value"
render --set namespace=Not_A_Namespace >/dev/null 2>&1 && bad "the schema refuses an invalid namespace" || ok "the schema refuses an invalid namespace"

# search.version: left out when empty, present when set.
! render -s templates/10-mongodbsearch.yaml | grep -q '^  version:' && ok "spec.version is left out by default" || bad "spec.version rendered by default"
render -s templates/10-mongodbsearch.yaml --set search.version=1.70.1 | grep -q '^  version: "1.70.1"$' && ok "search.version reaches the resource" || bad "search.version"
! render -s templates/10-mongodbsearch.yaml --set loadBalancer.image= | grep -q 'deployment:' && ok "no Envoy override without loadBalancer.image" || bad "Envoy override rendered without an image"
render -s templates/10-mongodbsearch.yaml | grep -q 'name: ent-trust-bundle' && ok "the source CA is always rendered" || bad "source.external.tls.ca missing"
render -s templates/10-mongodbsearch.yaml --set search.keepOnUninstall=true | grep -q 'helm.sh/resource-policy: keep' && ok "keepOnUninstall keeps the resource" || bad "keepOnUninstall"
# The MongoDBSearch's annotations as one sorted block, so a key that landed under labels, a duplicated key, a lost
# sync-wave, a mis-indented line or a whitespace-only line each make a different block.
ms_annotations() { render -s templates/10-mongodbsearch.yaml "$@" | awk '/^  annotations:$/{f=1;next} f&&!/^    /{exit} f{print}' | LC_ALL=C sort; }
[ "$(ms_annotations --set search.keepOnUninstall=true)" = "$(printf '%s\n' '    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true,Prune=false,Delete=false' '    argocd.argoproj.io/sync-wave: "1"' '    helm.sh/resource-policy: keep')" ] \
  && ok "keepOnUninstall also stops an Argo CD prune and delete, and changes nothing else in the annotations" || bad "keepOnUninstall under Argo CD: $(ms_annotations --set search.keepOnUninstall=true | tr '\n' ';')"
[ "$(ms_annotations)" = "$(printf '%s\n' '    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true' '    argocd.argoproj.io/sync-wave: "1"')" ] \
  && ok "without keepOnUninstall the resource can be pruned and is not kept" || bad "Prune=false or keep rendered by default: $(ms_annotations | tr '\n' ';')"
# Only the MongoDBSearch is kept: the Route and the rest of the release go with an uninstall or a prune (volumes.md).
[ "$(render --set search.keepOnUninstall=true | grep -c 'resource-policy: keep\|Prune=false')" = 2 ] \
  && ok "only the MongoDBSearch carries keep and Prune=false" || bad "keep or Prune=false on another object: $(render --set search.keepOnUninstall=true | grep -n 'resource-policy: keep\|Prune=false' | tr '\n' ';')"
render -s templates/20-route.yaml | grep -q '^  host: mongot-search-rnd.company.net$' && ok "the Route host is externalHostname" || bad "Route host"
render -s templates/20-route.yaml | grep -A1 'kind: Service' | grep -q 'name: mongot-search-0-proxy-svc$' \
  && ok "the Route targets the operator's proxy Service by default" || bad "Route default target"
render -s templates/20-route.yaml --set route.serviceName=my-svc | grep -A1 'kind: Service' | grep -q 'name: my-svc$' \
  && ok "route.serviceName overrides the target Service" || bad "route.serviceName"

# Toggles.
o="$(objects --set operator.install=false)"
{ has "$o" "Subscription/mongodb-kubernetes" || has "$o" "OperatorGroup/mongot-mongodb-search-helm" || has "$o" "Job/mongot-mongodb-search-helm-approver" || has "$o" "Job/mongot-mongodb-search-helm-csv-reclaim"; } \
  && bad "operator.install=false renders no Subscription, OperatorGroup, approver or reclaim" || ok "operator.install=false renders no Subscription, OperatorGroup, approver or reclaim"
has "$o" "Job/mongot-mongodb-search-helm-wait" && ok "operator.install=false keeps the gate" || bad "gate missing without operator.install"
render --set operator.install=false -s templates/00-preflight.yaml | grep -q 'mongodb-kubernetes-database-pods' && ok "without operator.install the preflight checks mongot's ServiceAccount" || bad "preflight ServiceAccount check"
o="$(objects)"; has "$o" "OperatorGroup/mongot-mongodb-search-helm" && ok "an OperatorGroup by default" || bad "OperatorGroup missing"
o="$(objects --set operatorGroup.create=false)"; has "$o" "OperatorGroup/mongot-mongodb-search-helm" && bad "operatorGroup.create=false renders none" || ok "operatorGroup.create=false renders none"
o="$(objects --set csvReclaim.enabled=false)"; has "$o" "Job/mongot-mongodb-search-helm-csv-reclaim" && bad "csvReclaim.enabled=false renders no reclaim" || ok "csvReclaim.enabled=false renders no reclaim"
o="$(objects --set preflight.enabled=false)"; grep -q 'preflight' <<<"$o" && bad "preflight.enabled=false renders no preflight" || ok "preflight.enabled=false renders no preflight"
o="$(objects --set route.enabled=false)"; has "$o" "Route/mongot-search" && bad "route.enabled=false renders no Route" || ok "route.enabled=false renders no Route"

# Preflight: reads five objects by name and nothing else of theirs.
p="$(render -s templates/00-preflight.yaml)"
for n in ent-mongot-search-cert ent-mongot-search-lb-0-cert ent-mongot-search-lb-0-client-cert search-sync-source-password ent-trust-bundle; do
  grep -q "\"${n}\"" <<<"$p" || bad "preflight Role does not name ${n}"
done
[[ "$(grep -c 'resourceNames' <<<"$p")" == 3 ]] && ok "the preflight reads Secrets, the ConfigMap and the MongoDBSearch by name only" || bad "preflight resourceNames"
[[ "$(grep -c 'helm.sh/hook: pre-install,pre-upgrade' <<<"$p")" == 4 ]] && ok "preflight: four pre-install hooks" || bad "preflight hooks"

# Monitoring: the ServiceMonitors and the alerts are on by default; all named after search.name.
o="$(objects)"
{ has "$o" "ServiceMonitor/mongot" && has "$o" "ServiceMonitor/mongot-envoy" && has "$o" "Service/mongot-envoy-stats"; } && ok "ServiceMonitors and the Envoy stats Service by default" || bad "ServiceMonitors missing by default"
has "$o" "PrometheusRule/mongot-distribution" && ok "the alert rules by default" || bad "alert rules missing by default"
# The dashboard: 52 panels in 7 sections. The 16 it started with are all still there: panels are added, not replaced.
# The sixth section is about the indexes themselves, by index id (mongot's metrics carry no index name), and the
# seventh about the searches that ask for stored source.
python3 - "${CHART}/files/mongodb-search.json" <<'PY' && ok "the dashboard has 52 panels in 7 sections, the first 16 among them" || bad "dashboard panels or sections"
import json, sys
g = json.load(open(sys.argv[1]))
charts = [p["title"] for p in g["panels"] if p["type"] != "row"]; rows = [p["title"] for p in g["panels"] if p["type"] == "row"]
first = ["mongot pods up", "Envoy pods up", "mongot pods in Envoy", "Searches per second", "Largest share on one pod",
         "Searches per second, per mongot pod", "Share of searches, per mongot pod",
         "Requests per second to mongot, per Envoy pod", "Open connections from mongod, per Envoy pod",
         "Retries per second, per Envoy pod", "Responses per second from mongot, by class", "Envoy to mongot latency, 95th percentile",
         "Average search latency, per mongot pod", "Search failures per second, per mongot pod",
         "Replication lag, per mongot pod", "JVM memory used, per mongot pod"]
sys.exit(0 if len(charts) == 52 and len(set(charts)) == 52 and len(rows) == 7 and set(first) <= set(charts)
         and rows[-3:] == ["Does every mongot pod hold the same data?", "What does each index hold?", "Is stored source used?"] else 1)
PY
# Colours (issue #35): one palette, Tableau 10. A pod has one colour in every panel: the first blue, the second red,
# the third yellow, any further purple. Perses fixes a colour per query, so every line has a query of its own. A
# shade under every line, in its colour; one shade only where the pods read the same by design, since three shades
# on each other turn brown. The second pod dashed and the third dotted.
python3 - "${CHART}/files/mongodb-search.json" "${CHART}/files/mongodb-search.perses.json" <<'PY' && ok "every line, slice and state has a fixed colour from one palette, the same in both forms" || bad "dashboard colours"
import json, sys
g, p = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
BLUE, RED, YELLOW, PURPLE, GREEN, ORANGE = "#4e79a7", "#e15759", "#edc948", "#b07aa1", "#59a14f", "#f28e2b"
pods = [BLUE, RED, YELLOW, PURPLE]
SAME = {"Uptime, per mongot pod", "Data volume used, per mongot pod", "Indexes in catalog, per mongot pod",
        "Index size, per mongot pod", "Documents indexed, per mongot pod"}
perses = {v["spec"]["display"]["name"]: v["spec"]["plugin"] for v in p["panels"].values()}
ok = True
for x in g["panels"]:
    if x["type"] == "row": continue
    chart = perses[x["title"]]["spec"]
    by = {o["matcher"]["options"]: {q["id"]: q["value"] for q in o["properties"]} for o in x["fieldConfig"]["overrides"] if o["matcher"]["id"] == "byFrameRefID"}
    refs = [t["refId"] for t in x["targets"]]
    per_pod = x["title"].endswith(("per mongot pod", "per Envoy pod", "by mongot pod"))
    if x["type"] == "timeseries":
        colours = [by[r]["color"]["fixedColor"] for r in refs]
        ok &= len(set(colours)) == len(colours) and set(colours) <= {BLUE, RED, YELLOW, PURPLE, GREEN, ORANGE}      # every line, no colour twice
        # The two traffic panels are stacked: a band per pod, so three even pods are three colours and not one mix.
        stacked = x["title"] in ("Searches per second, per mongot pod", "Share of searches, per mongot pod")
        ok &= x["fieldConfig"]["defaults"]["custom"] == dict({"lineWidth": 1, "fillOpacity": 0}, **({"stacking": {"mode": "normal", "group": "A"}} if stacked else {}))
        ok &= chart["visual"] == dict({"areaOpacity": 0, "lineWidth": 1}, **({"stack": "all"} if stacked else {}))
        shades = {r: by[r]["custom.fillOpacity"] for r in refs if "custom.fillOpacity" in by[r]}
        ok &= shades == ({"A": 15} if x["title"] in SAME or len(refs) == 1 else dict.fromkeys(refs, 30 if stacked else 10))
        want = [dict({"queryIndex": i, "colorMode": "fixed", "colorValue": by[r]["color"]["fixedColor"]},
                     **({"areaOpacity": by[r]["custom.fillOpacity"] / 100} if "custom.fillOpacity" in by[r] else {}),
                     **({"lineStyle": {"dash": "dashed", "dot": "dotted"}[by[r]["custom.lineStyle"]["fill"]]} if "custom.lineStyle" in by[r] else {})) for i, r in enumerate(refs)]
        ok &= chart["querySettings"] == want
        if per_pod:
            ok &= colours == pods and " unless on (pod) " in x["targets"][3]["expr"]
            ok &= [by[r].get("custom.lineStyle", {}).get("fill") for r in refs] == [None, "dash", "dot", None]
    elif x["type"] == "piechart":
        ok &= [by[r]["color"]["fixedColor"] for r in refs] == pods == chart["colorPalette"]
    elif x["type"] == "status-history":
        ok &= [m["spec"]["result"]["color"] for m in chart["mappings"]] == [GREEN, RED] and all(v is not None for m in chart["mappings"] for v in m["spec"].values())
        if x["title"].endswith("per index"):
            ok &= x["targets"][0]["legendFormat"] == "{{index}}" and " or on (indexId_logString) " in x["targets"][0]["expr"]
            ok &= "job=\"__SEARCH__-index-info\"} @ end())" in x["targets"][0]["expr"]
    elif x["title"] in ("Each index", "Each index, now", "Each index, in the last hour", "What stored source adds"):
        # One row per index, under the label `index`: its name when the index info exporter gives one, its id otherwise.
        # Every query of a table carries the same labels, or Perses splits an index into several rows.
        cols = chart["columnSettings"]
        ok &= cols[0] == {"name": "timestamp", "hide": True} and (cols[1]["name"], cols[1]["header"]) == ("index", "Index")
        first = 2
        if x["title"] == "Each index":                       # the one table that also shows the id
            ok &= (cols[2]["name"], cols[2]["header"]) == ("indexId_logString", "Index id")
            first = 3
        ok &= [c["header"] for c in cols[first:]] == {
            "Each index": ["Type", "Stored source", "Vector memory"],
            "Each index, now": ["Pods STEADY", "Lucene docs", "Size", "Bytes per doc", "Growth, 24 h"],
            "Each index, in the last hour": ["Searches", "Failed searches", "Batch time", "Sync errors", "Lag, now"],
            "What stored source adds": ["Stored source", "Size", "Compared with", "Without it", "It adds", "Added per doc"]}[x["title"]]
        # Widths that hold every header in Grafana, whose header type is wider than the console's, and that add up to
        # no more than the 876 pixels of table the console drew on a page 1,280 wide. The name's column is 290.
        ok &= [c["width"] for c in cols[1:]] == {"Each index": [290, 215, 70, 125, 135],
                                                 "Each index, now": [290, 125, 115, 80, 125, 125],
                                                 "Each index, in the last hour": [290, 95, 130, 110, 105, 90],
                                                 "What stored source adds": [290, 110, 75, 120, 80, 80, 115]}[x["title"]]
        # The same widths in the Grafana source: the Perses file is generated from it, and a width changed there
        # without regenerating would otherwise pass.
        grafana_widths = {o["matcher"]["options"]: {q["id"]: q["value"] for q in o["properties"]}.get("custom.width")
                          for o in x["fieldConfig"]["overrides"] if o["matcher"]["id"] == "byName"}
        ok &= [grafana_widths.get(c["header"]) for c in cols[1:]] == [c["width"] for c in cols[1:]]
        ok &= sum(c["width"] for c in cols[1:]) <= 870 and x["gridPos"]["h"] >= (9 if x["title"] == "What stored source adds" else 10)
        if x["title"] == "What stored source adds":
            # What stored source adds is a comparison with the smallest index of the same collection and type that stores
            # nothing. With nothing to show it says so in a row: an empty table would read "No data".
            e = x["targets"][0]["expr"]
            ok &= e.endswith(' or on () label_replace(vector(0), "index", "no index is known to store fields", "", "")')
            ok &= all("min by (database, collection, indexType)" in t["expr"] for t in x["targets"][2:])
            # The index a row is compared with is named in a column of its own, between its size and that index's. Its
            # name is a label, compared_with, that every query joins to its rows with the names, from one and the same
            # expression: Perses joins the rows of a table by all their labels. bottomk keeps one candidate of a
            # collection and type whatever the sizes: `== min by` keeps two of the same size, and the join then fails.
            ok &= (cols[4]["name"], cols[4].get("header")) == ("compared_with", "Compared with")
            named = {t["expr"].partition(" group_left (database, collection, index_name, compared_with) ")[2]
                     .partition(', "ns", ".", "database", "collection")')[0] for t in x["targets"]}
            ok &= len(named) == 1 and "".join(named).count("bottomk by (database, collection, indexType) (1, ") == 1
            ok &= all(t["expr"].count("bottomk by (") == 1 and " == on (" not in t["expr"] for t in x["targets"])
            # Grafana lists a table's labels in the order its first series has them: the order is set, in both forms.
            order = [o for o in x["transformations"] if o["id"] == "organize"][0]["options"].get("indexByName", {})
            ok &= sorted(order, key=order.get) == ["Time", "index", "Value #A", "Value #B", "compared_with", "Value #C", "Value #D", "Value #E"]
            # That row's value is 0, which is "none" in the other table: here a dash, in both forms. Not an empty
            # text: the console drew the 0 for it.
            stored = {q["id"]: q["value"] for o in x["fieldConfig"]["overrides"] if o["matcher"]["options"] == "Stored source"
                      for q in o["properties"]}["mappings"][0]["options"]
            ok &= [stored[k]["text"] for k in "0123"] == ["-", "some fields", "all but some", "all fields"]
            ok &= [(c["condition"]["spec"]["value"], c["text"]) for c in cols[2]["cellSettings"]] == [
                ("0", "-"), ("1", "some fields"), ("2", "all but some"), ("3", "all fields")]
        by = {"Each index": "max by (index, indexId_logString) (",
              "What stored source adds": "max by (index, compared_with) ("}.get(x["title"], "max by (index) (")
        for t in x["targets"]:
            e = t["expr"]
            # The name where there is one, the id where there is none, each index once; and never a row per pod.
            ok &= e.startswith(by + "label_join(label_join(") and ' or on (indexId_logString) label_replace(' in e and " by (pod" not in e
            # The names are read at the end of the range: read along it, a chart carried an index twice when its name came
            # or went inside the range, once by its id and once by its name.
            ok &= 'mongodb_search_index_info{namespace="__NAMESPACE__",job="__SEARCH__-index-info"} @ end())' in e
        if x["title"] == "Each index":
            ok &= [(c["condition"]["spec"]["value"], c["text"]) for c in cols[3]["cellSettings"]] == [("0", "search"), ("1", "vector")]
            ok &= [(c["condition"]["spec"]["value"], c["text"]) for c in cols[4]["cellSettings"]] == [
                ("0", "none"), ("1", "some fields"), ("2", "all but some"), ("3", "all fields")]
            # The type of an index is read from a counter that exists from its creation: the lag gauge is NaN while it is built.
            ok &= "indexing_insert_total" in x["targets"][0]["expr"] and "replicationLagMs" not in x["targets"][0]["expr"]
    elif x["type"] == "bargauge":
        # Bars rank or count: one colour, since a colour per bar would change with every new index and mean nothing.
        ok &= x["fieldConfig"]["defaults"]["color"] == {"mode": "fixed", "fixedColor": BLUE} and x["fieldConfig"]["defaults"]["min"] == 0
        ok &= perses[x["title"]]["kind"] == "BarChart"
        if x["targets"][0].get("legendFormat") == "{{index}}":
            # A bar of an index is named above it, where a name is whole whatever its length: on the left Grafana cut
            # a 24 character id in 12 pixel type. The whole width: at less, the console cut the id on its axis.
            ok &= x["options"]["namePlacement"] == "top" and x["gridPos"]["w"] == 24 and " or on (indexId_logString) " in x["targets"][0]["expr"]
            # A bar is of "now": every selector is read at the end of the range, or an index that is gone, or a name that
            # is, keeps its bar for as long as the range reaches back.
            e = x["targets"][0]["expr"]
            ok &= e.count("} @ end()") == e.count("{namespace=")
        else:
            ok &= x["options"]["namePlacement"] == "left"
    elif x["type"] == "table":
        cols = chart["columnSettings"]
        ok &= cols[0] == {"name": "timestamp", "hide": True} and cols[1]["name"] == "pod" and [c["header"] for c in cols[2:]] == ["Index size", "Documents", "Indexes", "Not STEADY", "Volume used", "Uptime"]
        # the name of each pod on its colour, with text that can be read on it
        ok &= [c["backgroundColor"] for c in cols[1]["cellSettings"]] == pods and all(c["textColor"] in ("#000000", "#ffffff") for c in cols[1]["cellSettings"])
        ok &= [c["condition"]["kind"] for c in cols[1]["cellSettings"]] == ["Value", "Value", "Value", "Regex"]
    elif x["type"] == "stat":
        ok &= {s["color"] for s in x["fieldConfig"]["defaults"]["thresholds"]["steps"]} <= {GREEN, ORANGE, RED}
        e = x["targets"][0]["expr"]
        # Pods are counted by who reports an index, never through `up` (a pod being replaced has none), and one reading
        # per index and pod, so that two generations of an index are not two pods. An index being built is counted by
        # its state: the initial sync gauges count syncs on a pod, not indexes.
        if x["title"] == "Indexes missing a host":
            # An index the source lists on fewer hosts than there are mongot pods: one pod that lost its heartbeat row
            # is left out of the listing while the index still reads READY on the others (lab, 2 hosts of 3).
            ok &= "mongodb_search_index_listed_hosts{" in e and " < scalar(count(count by (pod) (" in e and "== 0" not in e and "up{" not in e
        if x["title"] == "Indexes that differ by pod":
            ok &= "up{" not in e and "max by (indexId_logString, pod)" in e and "count(count by (pod) (" in e
            # Documents are compared, a generation with itself, and sizes are not: each pod writes its own index files,
            # and the same documents took another number of bytes on one lab pod.
            ok &= "max by (indexId_logString, generationId_logString) (mongot_index_stats_numLuceneDocs{" in e
            ok &= "!= min by (indexId_logString) (mongot_index_stats_indexSizeBytes" not in e and e.count("indexSizeBytes") == 2
        if x["title"] == "Indexes being built":
            ok &= "status=~\"INITIAL_SYNC|NOT_STARTED\"" in e and "initialsync" not in e
    # A legend is below its chart, never beside it. A panel narrower than half the page needs two legend lines for
    # three pods, and Perses draws the second only from 11 units of height (measured in the console).
    if "legend" in x.get("options", {}):
        ok &= x["options"]["legend"]["placement"] == "bottom" and chart["legend"]["position"] == "bottom"
        ok &= x["gridPos"]["w"] >= 12 or x["gridPos"]["h"] >= 11
sys.exit(0 if ok else 1)
PY
# What the colours stand on, in both files. Each query of a per-pod chart selects its own pod by name, and the fourth
# every other one, from one expression: selected by `up`, a pod being replaced turned purple. The pie is read at the
# end of the range shown, or it keeps what stopped an hour ago; a Perses pie colours by position, so each of its
# queries gives one series, a pod keeps its place whenever it or a later one is known, and nothing is drawn unless a
# search ran. The table names the same pods on the same colours in both forms, with text that can be read. A stacked
# axis starts at 0 and a share ends at 1. A single number has the same thresholds in both. The Perses layout has the
# Grafana one's places and sizes: the console is where the 11 units were measured.
# A per-second rate and uptime start at 0 too; CPU is aggregated by pod like every other chart, so that a restarted
# pod is one series; the pie says in words that no search ran; the data source variable starts on Grafana's default.
python3 - "${CHART}/files/mongodb-search.json" "${CHART}/files/mongodb-search.perses.json" <<'PY' && ok "per-pod queries, the pie, the table, axes, thresholds, layout and data source agree in both forms" || bad "dashboard per-pod queries, pie, table, axes, thresholds, layout or data source"
import json, re, sys
g, p = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
BLUE, RED, YELLOW, PURPLE, GREEN, ORANGE = "#4e79a7", "#e15759", "#edc948", "#b07aa1", "#59a14f", "#f28e2b"
J, P = 'namespace="__NAMESPACE__",job="__SEARCH__-search-0-svc"', "__SEARCH__-search-0-"
NAME = lambda i: f'label_replace(vector(1), "pod", "{P}{i}", "", "")'
START = 'max by (pod) (kube_pod_start_time{namespace="__NAMESPACE__",pod=~"__SEARCH__-search-lb-0-.*"})'
TAILS = {"mongot": [f" and on (pod) {NAME(i)}" for i in range(3)] + [f" unless on (pod) ({NAME(0)} or {NAME(1)} or {NAME(2)})"],
         "Envoy": [f" and on (pod) topk(1, {START})", f" and on (pod) (topk(2, {START}) unless topk(1, {START}))",
                   f" and on (pod) (topk(3, {START}) unless topk(2, {START}))", f" unless on (pod) topk(3, {START})"]}
STATS = {"mongot pods up": [RED, GREEN], "Envoy pods up": [RED, GREEN], "mongot pods in Envoy": [RED, GREEN],
         "Searches per second": [GREEN], "Largest share on one pod": [GREEN, ORANGE, RED],
         "Indexes": [GREEN], "Indexes being built": [GREEN], "Indexes that differ by pod": [GREEN, RED],
         "Size of all indexes, on one pod": [GREEN], "Search indexes": [GREEN], "Vector indexes": [GREEN],
         "Memory for vector indexes": [GREEN], "Index builds waiting": [GREEN], "Indexes with a name": [GREEN],
         "Indexes with stored source": [GREEN], "Indexes missing a host": [GREEN, RED], "Stored source searches, 1 hour": [GREEN],
         "Stored source share, searches": [GREEN], "Stored source vector, 1 hour": [GREEN],
         "Stored source share, vector": [GREEN]}
def own(m):                                        # the searches per second of the pods a matcher selects, at the end of the range
    return (f"sum by (pod) (rate(mongot_command_searchCommandTotalLatency_seconds_count{{{J}{m}}}[5m] @ end())"
            f" + rate(mongot_command_vectorSearchCommandTotalLatency_seconds_count{{{J}{m}}}[5m] @ end()))")
some = " and on () (sum(" + own("")[len("sum by (pod) ("):] + " > 0)"
kept = lambda i, m: f'label_replace(count(up{{{J}{m}}} @ end() or {own(m)}) * 0, "pod", "{P}{i}", "", "")'
M = [f',pod="{P}0"', f',pod="{P}1"', f',pod="{P}2"', f',pod!="{P}0"', f',pod!~"{P}[01]"', f',pod!~"{P}[0-2]"']
PIE = [f'({own(M[0])} or label_replace(vector(0), "pod", "{P}0", "", "")){some}', f'({own(M[1])} or {kept(1, M[3])}){some}',
       f'({own(M[2])} or {kept(2, M[4])}){some}', f'label_replace(sum({own(M[5])}), "pod", "further pods", "", ""){some}']
def luminance(colour):
    r, gr, b = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in (int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5))]
    return 0.2126 * r + 0.7152 * gr + 0.0722 * b
def contrast(one, other):
    light, dark = sorted((luminance(one), luminance(other)), reverse=True)
    return (light + 0.05) / (dark + 0.05)
perses = {v["spec"]["display"]["name"]: (k, v["spec"]["plugin"]["spec"]) for k, v in p["panels"].items()}
place = {i["content"]["$ref"].rsplit("/", 1)[1]: (i["x"], i["width"], i["height"]) for l in p["layouts"] for i in l["spec"]["items"]}
ok = g["templating"]["list"][0]["current"] == {"selected": True, "text": "default", "value": "default"}
for x in g["panels"]:
    if x["type"] == "row": continue
    key, chart = perses[x["title"]]
    ok &= place[key] == (x["gridPos"]["x"], x["gridPos"]["w"], x["gridPos"]["h"])
    exprs = [t["expr"] for t in x["targets"]]
    for kind, tails in TAILS.items():
        if x["title"].endswith(f"per {kind} pod") and x["type"] == "timeseries":
            ok &= len(exprs) == 4 and all(e.endswith(t) for e, t in zip(exprs, tails))
            ok &= len({e[:-len(t)] for e, t in zip(exprs, tails)}) == 1          # one expression, four selections of it
            ok &= " by (pod) " in exprs[0][:-len(tails[0])]                       # a restarted pod is one series, not two
    if x["type"] == "piechart":
        ok &= exprs == PIE
    d = x["fieldConfig"]["defaults"]
    if x["type"] == "piechart":
        ok &= bool(d.get("noValue"))                                             # Grafana's "No data" reads as a fault
    if x["type"] == "timeseries" and (d.get("custom", {}).get("stacking") or d["unit"] in ("reqps", "ops") or x["title"].startswith("Uptime")):
        ok &= d.get("min") == 0 == chart["yAxis"].get("min")
        if d["unit"] == "percentunit": ok &= d.get("max") == 1 == chart["yAxis"].get("max")
    if x["type"] == "stat":
        steps = d["thresholds"]["steps"]
        ok &= [s["color"] for s in steps] == STATS[x["title"]]
        ok &= chart["thresholds"]["steps"] == [{"color": s["color"], "value": s["value"] or 0} for s in steps]
    if x["title"] == "Each mongot pod, now":
        maps = [m for o in x["fieldConfig"]["overrides"] for q in o["properties"] if q["id"] == "mappings" for m in q["value"]]
        want = [(k, v["color"]) for m in maps if m["type"] == "value" for k, v in m["options"].items()]
        want += [(m["options"]["pattern"], m["options"]["result"]["color"]) for m in maps if m["type"] == "regex"]
        ok &= want[:3] == list(zip([f"__SEARCH__-search-0-{i}" for i in range(3)], [BLUE, RED, YELLOW])) and [c for _, c in want[3:]] == [PURPLE]
        further = re.compile(want[3][0].replace("__SEARCH__", "a-b")) if len(want) == 4 else re.compile("$^")
        ok &= [n for n in (0, 1, 2, 3, 9, 10, 25, 100) if further.search(f"a-b-search-0-{n}")] == [3, 9, 10, 25, 100]
        ok &= not further.search("a-b-search-0-3-0") and not further.search("xa-b-search-0-3")
        cells = chart["columnSettings"][1]["cellSettings"]
        ok &= [(c["condition"]["spec"].get("value", c["condition"]["spec"].get("expr")), c["backgroundColor"]) for c in cells] == want
        ok &= all(c["textColor"] == max("#000000", "#ffffff", key=lambda text: contrast(text, c["backgroundColor"])) for c in cells)
sys.exit(0 if ok else 1)
PY
# The heap panel divides heap by heap: summed over every area, the maximum includes a -1 and the non-heap pools.
grep -q -F 'mongot_jvm_memory_max_bytes{namespace=\"__NAMESPACE__\",job=\"__SEARCH__-search-0-svc\",area=\"heap\"}' "${CHART}/files/mongodb-search.json" \
  && ok "the heap panel takes the heap's maximum only" || bad "heap maximum is not limited to the heap"
# Envoy's two counters without _total get the suffix at the scrape, and nothing uses the bare names: rate() on
# those is answered with "metric might not be a counter", which both dashboards show as a warning.
m="$(render -s templates/30-monitoring.yaml)"
{ grep -q 'regex: (envoy_cluster_upstream_rq_(?:retry|xx))' <<<"$m" && grep -q 'replacement: ${1}_total' <<<"$m"; } \
  && ok "the Envoy scrape gives upstream_rq_retry and upstream_rq_xx the _total suffix" || bad "Envoy counter rename"
bare="$({ echo "$m"; cat "${CHART}/files/mongodb-search.json" "${CHART}/files/mongodb-search.perses.json"; } | grep -o -E 'rate\(envoy_cluster_upstream_rq_(retry|xx)[{[]' || true)"
[[ -z "${bare}" ]] && ok "no alert or panel takes a rate of the bare Envoy counter names" || bad "bare Envoy counter in a rate: ${bare}"
# 0 / 0 is NaN: the share panel divides only when there were searches, and reads 0 otherwise.
for f in mongodb-search.json mongodb-search.perses.json; do
  grep -q -F '[5m]))) > 0)) or vector(0)' "${CHART}/files/${f}" && ok "${f}: the largest-share panel does not divide by zero" || bad "${f}: largest share divides by zero"
done
o="$(objects --set monitoring.alerts.enabled=false)"; has "$o" "PrometheusRule/mongot-distribution" && bad "alerts.enabled=false renders no rules" || ok "alerts.enabled=false renders no rules"
o="$(objects)"
o="$(objects --set monitoring.serviceMonitors.enabled=false)"
{ has "$o" "ServiceMonitor/mongot" || has "$o" "ServiceMonitor/mongot-envoy" || has "$o" "Service/mongot-envoy-stats"; } && bad "serviceMonitors.enabled=false renders none" || ok "serviceMonitors.enabled=false renders none"
o="$(objects --set monitoring.serviceMonitors.enabled=true --set monitoring.alerts.enabled=true --set search.name=srch)"
{ has "$o" "ServiceMonitor/srch" && has "$o" "ServiceMonitor/srch-envoy" && has "$o" "Service/srch-envoy-stats" && has "$o" "PrometheusRule/srch-distribution"; } \
  && ok "monitoring objects follow search.name" || bad "monitoring object names: ${o//$'\n'/ }"
m="$(render --set monitoring.alerts.enabled=true --set search.name=srch -s templates/30-monitoring.yaml)"
grep -q 'job=~"srch-search-0-svc|srch-envoy-stats"' <<<"$m" && ok "the no-traffic alert's job pattern follows search.name" || bad "alert job pattern"
[[ "$(grep -c -- '- alert:' <<<"$m")" == 12 && "$(grep -c -- '- record:' <<<"$m")" == 4 ]] && ok "twelve alerts and four recording rules" || bad "alert or rule count changed"
# The volume alert's three levels are values. As shipped: 70, 80 and 90, each level up to the next one's.
vol() { render -s templates/30-monitoring.yaml "$@" 2>&1 | grep -A12 -- '- alert: MongotDataPathFillingUp' | grep -E 'ratio >=|ratio <|severity:|for:' | tr -s ' ' | tr '\n' '|'; }
[[ "$(vol)" == ' mongot:data_path_used:ratio >= 0.7| and (mongot:data_path_used:ratio < 0.8 or mongot:data_path_used:ratio offset 15m < 0.8)| for: 30m| severity: info| mongot:data_path_used:ratio >= 0.8| and (mongot:data_path_used:ratio < 0.9 or mongot:data_path_used:ratio offset 5m < 0.9)| for: 15m| severity: warning| expr: mongot:data_path_used:ratio >= 0.9| for: 5m| severity: critical|' ]] \
  && ok "the volume alert has three levels, at 70, 80 and 90, each up to the next" || bad "the volume alert's levels: $(vol)"
# A changed level moves both the level and the end of the one below it.
[[ "$(vol --set monitoring.alerts.dataPathUsed.warning=77)" == *'ratio >= 0.7| and (mongot:data_path_used:ratio < 0.77 or mongot:data_path_used:ratio offset 15m < 0.77)|'*'ratio >= 0.77|'* ]] \
  && ok "a level set in the values moves the level and the end of the one below" || bad "a changed level: $(vol --set monitoring.alerts.dataPathUsed.warning=77)"
# null leaves a level out, and the level below it runs up to the next one that is left; all three null, no group.
[[ "$(vol --set monitoring.alerts.dataPathUsed.warning=null)" == ' mongot:data_path_used:ratio >= 0.7| and (mongot:data_path_used:ratio < 0.9 or mongot:data_path_used:ratio offset 5m < 0.9)| for: 30m| severity: info| expr: mongot:data_path_used:ratio >= 0.9| for: 5m| severity: critical|' ]] \
  && ok "a level set to null is left out, and the one below runs up to the next" || bad "a null level: $(vol --set monitoring.alerts.dataPathUsed.warning=null)"
off="$(render -s templates/30-monitoring.yaml --set monitoring.alerts.dataPathUsed.info=null --set monitoring.alerts.dataPathUsed.warning=null --set monitoring.alerts.dataPathUsed.critical=null)"
{ ! grep -q 'mongot.volume\|MongotDataPathFillingUp\|data_path_used' <<<"$off" && [[ "$(grep -c -- '- alert:' <<<"$off")" == 9 ]]; } \
  && ok "all three levels null leaves the volume alert out and the nine others in" || bad "the volume alert with every level null"
# The levels must rise (the template says which does not), and be numbers from 0 to 100 (the schema).
grep -q 'monitoring.alerts.dataPathUsed.critical is 90: it must be above warning (95)' <<<"$(render --set monitoring.alerts.dataPathUsed.warning=95)" \
  && grep -q 'monitoring.alerts.dataPathUsed.warning is 80: it must be above info (80)' <<<"$(render --set monitoring.alerts.dataPathUsed.info=80)" \
  && ok "levels that do not rise are refused, by name" || bad "levels out of order are rendered"
refused "a volume level above 100" --set monitoring.alerts.dataPathUsed.critical=120
refused "a volume level that is not a whole number" --set monitoring.alerts.dataPathUsed.info=72.5
refused "a volume level of 0, which would always fire" --set monitoring.alerts.dataPathUsed.info=0
refused "an unknown volume level" --set monitoring.alerts.dataPathUsed.page=95
# The whole map absent (a release's values from before 0.3.11 kept by --reuse-values): refused by name.
grep -q 'monitoring.alerts.dataPathUsed is missing' <<<"$(render --set monitoring.alerts.dataPathUsed=null)" \
  && ok "values without dataPathUsed at all (--reuse-values from 0.3.10) are refused by name" || bad "values without dataPathUsed: $(render --set monitoring.alerts.dataPathUsed=null 2>&1 | grep -m1 -i error)"
# The five index alerts name the index by the label mongot's metrics carry. What they do is tested with promtool,
# by test/alerts.sh.
[[ "$(grep -c 'indexId_logString }}' <<<"$m")" == 5 ]] && grep -q 'name: mongot.indexes' <<<"$m" && ok "the five index alerts name their index" || bad "index alerts"
grep -q '{{ $value | humanizePercentage }}' <<<"$m" && ok "Prometheus templating survives Helm" || bad "alert templating was eaten by Helm"

# Dashboards: Perses on by default, Grafana off; one Grafana source, a generated Perses copy, scoped to this namespace and name.
o="$(objects)"
{ has "$o" "PersesDashboard/mongot-search" && has "$o" "PersesDatasource/mongot-thanos"; } && ok "the Perses dashboard and its datasource by default" || bad "Perses dashboard missing by default"
has "$o" "ConfigMap/mongot-grafana-dashboard" && bad "no Grafana dashboard by default" || ok "no Grafana dashboard by default"
o="$(objects --set monitoring.persesDashboard.enabled=false)"
{ has "$o" "PersesDashboard/mongot-search" || has "$o" "PersesDatasource/mongot-thanos"; } && bad "persesDashboard.enabled=false renders none" || ok "persesDashboard.enabled=false renders none"
o="$(objects --set monitoring.persesDashboard.enabled=true --set monitoring.grafanaDashboard=true --set search.name=srch)"
{ has "$o" "PersesDashboard/srch-search" && has "$o" "PersesDatasource/srch-thanos" && has "$o" "ConfigMap/srch-grafana-dashboard"; } && ok "dashboard objects follow search.name" || bad "dashboard object names"
d="$(render --set monitoring.persesDashboard.enabled=true --set monitoring.grafanaDashboard=true --set search.name=srch -s templates/31-dashboards.yaml)"
! grep -q '__NAMESPACE__\|__SEARCH__' <<<"$d" && ok "no token is left in the rendered dashboards" || bad "a token survived rendering"
grep -q 'namespace=\\"dvh-gp6-rnd\\",job=\\"srch-search-0-svc\\"' <<<"$d" && ok "the dashboard queries name this namespace and search" || bad "dashboard query scope"
grep -q '"name": "srch-thanos"' <<<"$d" && grep -q 'secret: srch-thanos-secret' <<<"$d" && ok "every Perses query names the chart's datasource" || bad "Perses datasource name"
python3 - "${CHART}/files/mongodb-search.json" "${CHART}/files/mongodb-search.perses.json" <<'PY' && ok "the Perses dashboard has the Grafana one's panels and queries" || bad "the Perses dashboard is stale: run scripts/perses-dashboard.sh"
import json, sys
g = json.load(open(sys.argv[1])); p = json.load(open(sys.argv[2]))
want = {x["title"]: [t["expr"] for t in x["targets"]] for x in g["panels"] if x["type"] != "row"}
got = {x["spec"]["display"]["name"]: [q["spec"]["plugin"]["spec"]["query"] for q in x["spec"]["queries"]] for x in p["panels"].values()}
sys.exit(0 if want == got and not any(x["spec"]["plugin"]["kind"] == "Markdown" for x in p["panels"].values()) else 1)
PY

# Schema refusals.
refused "an unknown key" --set operator.typo=1
refused "a version with a v" --set operator.version=v1.13.0
refused "an IP address as hostname" --set loadBalancer.externalHostname=10.1.2.3
refused "an empty hostname" --set loadBalancer.externalHostname=
refused "a source without a port" --set 'source.hostAndPorts={abc234.uat.company.net}'
refused "an unknown balance algorithm" --set route.balance=first
refused "a search name the operator's suffixes would overflow" --set search.name=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# Argo CD: every hook Job is also an Argo hook, and the example never lets Argo own the CRD.
[[ "$(render | grep -c 'argocd.argoproj.io/hook: \(Sync\|PreSync\)')" == 7 ]] && ok "every hook object carries an Argo CD hook" || bad "Argo CD hook annotations"
grep -q 'skipCrds: true' ${CHART}/examples/argocd-application.yaml && ok "the Argo CD example skips the CRD" || bad "argocd example: skipCrds"

# The Jobs' scripts: bash syntax, and shellcheck when available.
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
render | python3 -c '
import sys, re
for doc in sys.stdin.read().split("\n---"):
    if "kind: Job" not in doc: continue
    name = re.search(r"^  name: (\S+)", doc, re.M).group(1)
    m = re.search(r"\n          args:\n            - \|\n(.*)", doc, re.S)
    lines = [l[14:] if l.startswith(" " * 14) else l.strip() for l in m.group(1).splitlines()]
    open(sys.argv[1] + "/" + name + ".sh", "w").write("\n".join(lines) + "\n")' "${tmp}"
n=0
for f in "${tmp}"/*.sh; do
  n=$((n + 1))
  bash -n "$f" 2>/dev/null && ok "bash -n $(basename "$f" .sh)" || bad "bash -n $(basename "$f" .sh): $(bash -n "$f" 2>&1)"
  if command -v shellcheck >/dev/null; then
    shellcheck -S warning -s bash "$f" >/dev/null && ok "shellcheck $(basename "$f" .sh)" || bad "shellcheck $(basename "$f" .sh): $(shellcheck -S warning -s bash -f gcc "$f" | head -5)"
  fi
done
[[ $n == 4 ]] && ok "four Job scripts checked" || bad "expected four Job scripts, found $n"
for s in scripts/refresh-mongodbsearch-crd.sh scripts/perses-dashboard.sh; do
  bash -n "$s" && ok "bash -n $s" || bad "bash -n $s"
done

# ------------------------------------------------------------------------------------------------ volumes
# The two hooks are shell scripts in Jobs. Each is taken out of the render and run here against a stand-in `oc`, so
# that what they say and how they end is tested without a cluster.
hook_script() {  # <template>: the script of the Job's container, as rendered
  render -s "templates/$1" | python3 -c '
import re, sys
doc = sys.stdin.read()
m = re.search(r"^          args:\n            - \|\n((?:(?:              .*)?\n)+)", doc, re.M)
sys.stdout.write("\n".join(l[14:] for l in m.group(1).split("\n")))'; }
hooks="$(mktemp -d)"; mkdir "${hooks}/bin"
hook_script 00-preflight.yaml > "${hooks}/preflight.sh"; hook_script 40-wait.yaml > "${hooks}/wait.sh"
cat > "${hooks}/bin/oc" <<'OC'
#!/usr/bin/env bash
# A cluster in which every hand-made object is there, the operator is installed, and the MongoDBSearch is what the
# FAKE_ variables say.
case "$*" in
  *mongodbsearch*"{.spec.clusters[0].replicas}"*) [ -z "${FAKE_REPLICAS_ERR:-}" ] || { echo "$FAKE_REPLICAS_ERR" >&2; exit 1; }
    [ -n "${FAKE_REPLICAS:-}" ] || { echo 'Error from server (NotFound): mongodbsearch.mongodb.com "mongot" not found' >&2; exit 1; }; printf '%s' "$FAKE_REPLICAS" ;;
  *mongodbsearch*"{.spec.clusters[0].persistence.single.storage}"*) printf '%s' "${FAKE_WANT_SIZE:-}" ;;
  *statefulsets.apps*volumeClaimTemplates*) printf '%s' "${FAKE_HAVE_SIZE:-}" ;;
  *mongodbsearch*"{.status.phase}"*) printf '%s' "${FAKE_PHASE:-Running}" ;;
  *mongodbsearch*"{.status.message}"*) printf '%s' "${FAKE_MESSAGE:-}" ;;
  *"{.metadata.generation}"*|*"{.status.observedGeneration}"*) printf 7 ;;
  *subscriptions*installedCSV*) printf 'mongodb-kubernetes.v1.13.0' ;;
  *clusterserviceversions*"{.status.phase}"*) printf Succeeded ;;
  *go-template*) printf 'tls.crt\ntls.key\nca.crt\npassword\n' ;;
  *"{.type}"*) printf kubernetes.io/tls ;;
  *) exit 0 ;;
esac
OC
chmod +x "${hooks}/bin/oc"
pre() { env PATH="${hooks}/bin:${PATH}" NAMESPACE=x TLS_SECRETS="a b c" PASSWORD_SECRET=p PASSWORD_KEY=password TRUST_CM=t OPERATOR_INSTALL=true \
          OPERATORGROUP= PACKAGE=mongodb-kubernetes SEARCH=mongot "$@" bash "${hooks}/preflight.sh" 2>&1; }
# Fewer mongot pods means their volumes are deleted by the operator: refused unless it is asked for by name.
out="$(pre FAKE_REPLICAS=3 WANT_REPLICAS=2 ALLOW_VOLUME_LOSS=false)"; rc=$?
[[ $rc == 1 && "$out" == *"REFUSED: search.replicas would go from 3 to 2."*"search.allowVolumeLoss=true"*"Nothing was changed."* ]] \
  && ok "the preflight refuses an upgrade to fewer mongot pods, and says what it would delete" || bad "preflight and fewer replicas (exit ${rc}): ${out##*$'\n'}"
out="$(pre FAKE_REPLICAS=3 WANT_REPLICAS=0 ALLOW_VOLUME_LOSS=false)"; rc=$?
[[ $rc == 1 && "$out" == *"would go from 3 to 0"* ]] && ok "and one to no pod at all" || bad "preflight and 0 replicas (exit ${rc})"
out="$(pre FAKE_REPLICAS=3 WANT_REPLICAS=2 ALLOW_VOLUME_LOSS=true)"; rc=$?
[[ $rc == 0 && "$out" == *"with search.allowVolumeLoss=true: the volumes of the pods that go are deleted"* && "$out" == *"all hand-made objects are present"* ]] \
  && ok "with search.allowVolumeLoss=true it lets it through, and says what goes" || bad "preflight with allowVolumeLoss (exit ${rc})"
for case in "FAKE_REPLICAS=3 WANT_REPLICAS=3" "FAKE_REPLICAS=3 WANT_REPLICAS=5" "WANT_REPLICAS=3"; do
  out="$(pre ${case} ALLOW_VOLUME_LOSS=false)"; rc=$?
  [[ $rc == 0 && "$out" != *REFUSED* ]] || bad "the preflight stopped ${case} (exit ${rc}): ${out##*$'\n'}"
done
ok "the same, more or a first install pass the preflight"
# A read of the resource that fails for any reason but "there is none" is refused: "no resource" would otherwise let
# a scale-down through unseen. No CRD yet (Argo CD's PreSync runs before the sync) is a first install.
out="$(pre FAKE_REPLICAS_ERR='Error from server (Forbidden): mongodbsearch.mongodb.com "mongot" is forbidden: User "system:serviceaccount:x:p" cannot get resource "mongodbsearch" in API group "mongodb.com"' WANT_REPLICAS=2 ALLOW_VOLUME_LOSS=false)"; rc=$?
out2="$(pre FAKE_REPLICAS_ERR='Unable to connect to the server: dial tcp: i/o timeout' WANT_REPLICAS=2 ALLOW_VOLUME_LOSS=false)"; rc2=$?
[[ $rc == 1 && $rc2 == 1 && "$out" == *"REFUSED: cannot read MongoDBSearch mongot"*"is forbidden"* && "$out2" == *"REFUSED: cannot read MongoDBSearch mongot"* ]] \
  && ok "the preflight refuses when it cannot read the resource (RBAC, the API), instead of taking that for a first install" || bad "preflight and an unreadable resource (exit ${rc}, ${rc2}): ${out##*$'\n'}"
out="$(pre FAKE_REPLICAS_ERR="error: the server doesn't have a resource type \"mongodbsearch\"" WANT_REPLICAS=2 ALLOW_VOLUME_LOSS=false)"; rc=$?
[[ $rc == 0 && "$out" != *REFUSED* ]] && ok "no CRD yet is a first install" || bad "preflight before the CRD exists (exit ${rc}): ${out##*$'\n'}"
out="$(pre FAKE_REPLICAS=abc WANT_REPLICAS=2 ALLOW_VOLUME_LOSS=false)"; rc=$?
[[ $rc == 1 && "$out" == *"not a number: abc"* ]] && ok "a replica count that is not a number is refused, not compared" || bad "preflight and a replica count of abc (exit ${rc}): ${out##*$'\n'}"

gate() { env PATH="${hooks}/bin:${PATH}" NAMESPACE=x OPERATOR_INSTALL=true SUBSCRIPTION=mongodb-kubernetes PACKAGE=mongodb-kubernetes \
           TARGET=mongodb-kubernetes.v1.13.0 SEARCH=mongot MONGOT_STS=mongot-search-0 MONGOT_REPLICAS=3 ENVOY_DEPLOY=mongot-search-lb-0 ENVOY_REPLICAS=2 \
           LB_CERT_SECRET=a LB_CLIENT_CERT_SECRET=b TRUST_CM=t ROUTE= INTERVAL=1 "$@" bash "${hooks}/wait.sh" 2>&1; }
FORBIDDEN="1 error occurred: * error creating/updating search statefulset x/mongot-search-0: StatefulSet.apps \"mongot-search-0\" is invalid: spec: Forbidden: updates to statefulset spec for fields other than 'replicas', 'ordinals', 'template', 'updateStrategy', 'revisionHistoryLimit', 'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden"
# A changed volume size: the resource is Failed and stays so. The gate does not wait out its budget (60 s here): it
# says what changed and where the steps are.
started=$SECONDS
out="$(gate WAIT_SECONDS=60 FAKE_PHASE=Failed FAKE_MESSAGE="$FORBIDDEN" FAKE_WANT_SIZE=300Gi FAKE_HAVE_SIZE=250Gi)"; rc=$?
[[ $rc == 1 && $((SECONDS - started)) -lt 20 && "$out" == *"STOPPED: search.persistence.storage is now 300Gi and the StatefulSet mongot-search-0 still has 250Gi."*"volume-expansion-runbook.md"* ]] \
  && ok "the gate names a changed volume size at once, and points to the runbook" || bad "the gate and a changed volume size (exit ${rc}, $((SECONDS - started)) s): ${out##*$'\n'}"
# Failed for another reason, or with the sizes equal: the gate waits and fails as before, and does not blame the volumes.
out="$(gate WAIT_SECONDS=3 FAKE_PHASE=Failed FAKE_MESSAGE="something else" FAKE_WANT_SIZE=300Gi FAKE_HAVE_SIZE=250Gi)"; rc=$?
out2="$(gate WAIT_SECONDS=3 FAKE_PHASE=Failed FAKE_MESSAGE="$FORBIDDEN" FAKE_WANT_SIZE=250Gi FAKE_HAVE_SIZE=250Gi)"; rc2=$?
out3="$(gate WAIT_SECONDS=3 FAKE_PHASE=Pending FAKE_MESSAGE="$FORBIDDEN" FAKE_WANT_SIZE=300Gi FAKE_HAVE_SIZE=250Gi)"; rc3=$?
[[ $rc == 1 && $rc2 == 1 && $rc3 == 1 && "$out$out2$out3" != *STOPPED* && "$out" == *"MongoDBSearch mongot Running: not within 3s"* && "$out2" == *"not within 3s"* && "$out3" == *"not within 3s"* ]] \
  && ok "any other failure is waited for and reported as before" || bad "the gate and another failure (exit ${rc}, ${rc2})"
rm -rf "${hooks}"

# ------------------------------------------------------------------------------------------------ index names
# monitoring.indexInfo: off by default, and when on a Deployment, its scripts, a Service and a ServiceMonitor of its
# own. The Service has a component of its own: the Envoy ServiceMonitor takes every Service of "observability".
! helm template mongot "${CHART}" -n dvh-gp6-rnd -f "${REMOTE}" | grep -q 'index-info' && ok "no index info exporter by default" || bad "index info objects rendered by default"
i="$(render -s templates/32-index-info.yaml --set monitoring.indexInfo.enabled=true --set monitoring.indexInfo.uriOptions=replicaSet=rs0)"
{ [[ "$(grep -c '^kind: ' <<<"$i")" == 4 ]] && grep -q '^kind: Deployment$' <<<"$i" && grep -q '^kind: ServiceMonitor$' <<<"$i" \
  && grep -q 'app.kubernetes.io/component: index-info' <<<"$i" && ! grep -q 'component: observability' <<<"$i"; } \
  && ok "the index info exporter is a Deployment, its scripts, a Service and a ServiceMonitor of its own" || bad "index info objects: $(grep '^kind: ' <<<"$i" | tr '\n' ' ')"
# It reaches the source with what the MongoDBSearch uses (hosts, CA) and with a user and a password of its own.
search="$(render -s templates/10-mongodbsearch.yaml)"
hosts="$(awk '/hostAndPorts:/{f=1; next} f && /^ *- /{gsub(/[" -]/, ""); printf "%s%s", s, $0; s=","; next} f{exit}' <<<"$search")"
ca="$(awk '/ca:/{getline; print $2; exit}' <<<"$search")"
sync="$(awk '/passwordSecretRef:/{f=1} f && /name:/{print $2; exit}' <<<"$search")"
{ [[ -n "$hosts" && -n "$ca" && -n "$sync" ]] && grep -q "value: \"${hosts}\"" <<<"$i" && grep -q "name: ${ca}$" <<<"$i" \
  && grep -q 'secretName: search-index-info-password' <<<"$i" && grep -q 'value: "replicaSet=rs0"' <<<"$i" && ! grep -q "${sync}" <<<"$i"; } \
  && ok "it uses the source's hosts and CA, and a password Secret of its own, not the sync user's" || bad "index info connection settings (hosts ${hosts}, CA ${ca})"
grep -q 'readOnlyRootFilesystem: true' <<<"$i" && grep -q 'runAsNonRoot: true' <<<"$i" && ! grep -q -E 'privileged: true|hostPath|hostNetwork' <<<"$i" \
  && ok "it runs unprivileged on a read-only file system" || bad "index info security context"
pre="$(render -s templates/00-preflight.yaml --set monitoring.indexInfo.enabled=true)"
grep -q 'name: INDEX_INFO_SECRET' <<<"$pre" && [[ "$(grep -c '"search-index-info-password"' <<<"$pre")" == 2 ]] && ! render -s templates/00-preflight.yaml | grep -q -e 'name: INDEX_INFO_SECRET' -e '"search-index-info-password"' \
  && ok "the preflight checks the exporter's password Secret, only when the exporter is on" || bad "preflight and index info"
refused "a question mark in indexInfo.uriOptions" --set monitoring.indexInfo.uriOptions='?x=1'
refused "an unknown key under indexInfo" --set monitoring.indexInfo.user=x
# Prometheus refuses a scrape timeout (25s here) longer than the interval, and the operator would then drop the
# ServiceMonitor in silence: the render fails instead, whatever the unit, and says why.
short="$(render --set monitoring.indexInfo.enabled=true --set monitoring.indexInfo.interval=15s)"
{ grep -q 'monitoring.indexInfo.interval is 15s: it must be at least 25s' <<<"$short" \
  && ! render --set monitoring.indexInfo.enabled=true --set monitoring.indexInfo.interval=0m >/dev/null 2>&1 \
  && render --set monitoring.indexInfo.enabled=true --set monitoring.indexInfo.interval=25s | grep -q '^      interval: 25s$' \
  && render --set monitoring.indexInfo.enabled=true --set monitoring.indexInfo.interval=2m | grep -q '^      interval: 2m$' \
  && render --set monitoring.indexInfo.interval=15s >/dev/null 2>&1; } \
  && ok "an indexInfo.interval shorter than the 25s scrape timeout is refused, and only when the exporter is on" || bad "indexInfo.interval and the scrape timeout"
# mongosh's telemetry is forbidden by its global configuration file, the one place it reads that from.
{ grep -q -A3 '^  mongosh.conf: |$' <<<"$i" && grep -q '^      forceDisableTelemetry: true$' <<<"$i" \
  && grep -q 'mountPath: /etc/mongosh.conf, subPath: mongosh.conf, readOnly: true' <<<"$i"; } \
  && ok "mongosh's telemetry is forbidden in its global configuration file" || bad "mongosh.conf of the index info exporter"

# The exporter itself, with a stand-in mongosh: the page it serves (for a name with a quote, a backslash, a newline,
# a letter outside ASCII and U+2028, a line separator to Python and not to JSON), a failure answered 503 and never old
# names, a mongosh that hangs answered 503 at its timeout, one listing for several scrapes, and the password in no
# argument list.
python3 - "${CHART}/files/index-info-exporter.py" <<'EXPORTER' && ok "the exporter serves the index names, fails the scrape when the source cannot be asked, and keeps the password out of arguments" || bad "the index info exporter"
import json, os, pathlib, socket, stat, subprocess, sys, tempfile, time, urllib.error, urllib.request
work = pathlib.Path(tempfile.mkdtemp()); (work / "bin").mkdir()
answer = {"collections": 2, "indexes": [
    {"id": "aaaaaaaaaaaaaaaaaaaaaaaa", "database": "shop", "collection": "items", "name": 'a "quoted" \\ name\nline two \u2028 \u00e9', "storedSource": "include", "storedSourcePaths": 3, "hosts": 3},
    {"id": "bbbbbbbbbbbbbbbbbbbbbbbb", "database": "shop", "collection": "orders", "name": "default", "storedSource": "none", "storedSourcePaths": 0, "hosts": 0}]}
fake = work / "bin" / "mongosh"
fake.write_text(f"""#!{sys.executable}
import json, os, sys
open({str(work / 'calls')!r}, "a").write(json.dumps({{"argv": sys.argv[1:], "uri": os.environ.get("SOURCE_URI", "")}}) + "\\n")
if os.path.exists({str(work / 'fail')!r}):
    sys.stderr.write("MongoServerError: Authentication failed.\\n"); sys.exit(1)
if os.path.exists({str(work / 'hang')!r}):
    import time; time.sleep(30)
# As mongosh writes it: UTF-8, and U+2028 as itself (JSON.stringify does not escape it).
sys.stdout.buffer.write(("a line mongosh may print first\\nRESULT " + {json.dumps(json.dumps(answer, ensure_ascii=False))} + "\\n").encode("utf-8"))
""")
fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
(work / "password").write_text("p@ss/w:rd\n")
with socket.socket() as s:
    s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]
env = dict(os.environ, PATH=f"{work}/bin:{os.environ['PATH']}", SOURCE_HOSTS="h1:27017,h2:27017", SOURCE_USERNAME="search-index-info",
           SOURCE_PASSWORD_FILE=str(work / "password"), SOURCE_CA_FILE="/etc/source-ca/ca.crt", SOURCE_URI_OPTIONS="replicaSet=rs0",
           LIST_SCRIPT="/app/index-info-list.js", CACHE_SECONDS="1", TIMEOUT_SECONDS="2", PORT=str(port))
server = subprocess.Popen([sys.executable, sys.argv[1]], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
def get(path):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=10) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
ok = True
try:
    for _ in range(50):
        try:
            if get("/healthz")[0] == 200: break
        except OSError:
            time.sleep(0.1)
    status, text = get("/metrics"); get("/metrics")
    calls = [json.loads(l) for l in (work / "calls").read_text().splitlines()]
    ok &= status == 200 and len(calls) == 1                                   # the second scrape was answered from the first
    ok &= 'mongodb_search_index_info{indexId_logString="aaaaaaaaaaaaaaaaaaaaaaaa",database="shop",collection="items",index_name="a \\"quoted\\" \\\\ name\\nline two \u2028 \u00e9",stored_source="include"} 1' in text
    ok &= 'mongodb_search_index_stored_source_paths{indexId_logString="aaaaaaaaaaaaaaaaaaaaaaaa"} 3' in text
    ok &= 'mongodb_search_index_listed_hosts{indexId_logString="bbbbbbbbbbbbbbbbbbbbbbbb"} 0' in text and "mongodb_search_index_info_collections 2" in text
    ok &= "mongodb_search_index_info_collect_timestamp_seconds " in text and text.endswith("\n")
    # The password is in the child's environment, percent-encoded, and in no argument; the hosts, the CA and the options are in the string.
    ok &= calls[0]["argv"] == ["--nodb", "--quiet", "--norc", "--file", "/app/index-info-list.js"]
    ok &= calls[0]["uri"] == "mongodb://search-index-info:p%40ss%2Fw%3Ard@h1:27017,h2:27017/admin?tls=true&tlsCAFile=%2Fetc%2Fsource-ca%2Fca.crt&appName=search-index-info&replicaSet=rs0"
    ok &= "p@ss" not in text and "p%40ss" not in text
    # A source that cannot be asked: 503 and no names, although a good answer was served a moment ago.
    (work / "fail").write_text(""); time.sleep(1.2)
    status, text = get("/metrics")
    ok &= status == 503 and "mongodb_search_index_info" not in text and "p%40ss" not in text
    ok &= get("/healthz")[0] == 200 and get("/other")[0] == 404
    (work / "fail").unlink()
    ok &= get("/metrics")[0] == 200                                           # and it recovers by itself
    # A mongosh that hangs is ended at TIMEOUT_SECONDS (2 here, 20 in the pod, under the 25 of the scrape) and answered 503.
    (work / "hang").write_text(""); time.sleep(1.2); started = time.time()
    ok &= get("/metrics")[0] == 503 and 1.5 < time.time() - started < 8
    (work / "hang").unlink()
    ok &= get("/metrics")[0] == 200
finally:
    server.kill()
sys.exit(0 if ok else 1)
EXPORTER
if command -v node >/dev/null; then
  node --check "${CHART}/files/index-info-list.js" 2>/dev/null && ok "the listing script parses (node --check)" || bad "index-info-list.js does not parse"
fi

[[ $fails == 0 ]] && echo "all chart tests passed" || { echo "${fails} failed"; exit 1; }
