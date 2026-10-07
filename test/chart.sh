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
[[ "$(grep -c 'resourceNames' <<<"$p")" == 2 ]] && ok "the preflight reads Secrets and the ConfigMap by name only" || bad "preflight resourceNames"
[[ "$(grep -c 'helm.sh/hook: pre-install,pre-upgrade' <<<"$p")" == 4 ]] && ok "preflight: four pre-install hooks" || bad "preflight hooks"

# Monitoring: the ServiceMonitors and the alerts are on by default; all named after search.name.
o="$(objects)"
{ has "$o" "ServiceMonitor/mongot" && has "$o" "ServiceMonitor/mongot-envoy" && has "$o" "Service/mongot-envoy-stats"; } && ok "ServiceMonitors and the Envoy stats Service by default" || bad "ServiceMonitors missing by default"
has "$o" "PrometheusRule/mongot-distribution" && ok "the alert rules by default" || bad "alert rules missing by default"
# The dashboard: 27 panels in 5 sections. The 16 it had before the mongot data and process panels keep their
# titles: panels are added to this dashboard, not replaced.
python3 - "${CHART}/files/mongodb-search.json" <<'PY' && ok "the dashboard has 27 panels in 5 sections, the first 16 among them" || bad "dashboard panels or sections"
import json, sys
g = json.load(open(sys.argv[1]))
charts = [p["title"] for p in g["panels"] if p["type"] != "row"]; rows = [p["title"] for p in g["panels"] if p["type"] == "row"]
first = ["mongot pods up", "Envoy pods up", "mongot pods in Envoy", "Searches per second", "Largest share on one pod",
         "Searches per second, per mongot pod", "Share of searches, per mongot pod",
         "Requests per second to mongot, per Envoy pod", "Open connections from mongod, per Envoy pod",
         "Retries per second, per Envoy pod", "Responses per second from mongot, by class", "Envoy to mongot latency, 95th percentile",
         "Average search latency, per mongot pod", "Search failures per second, per mongot pod",
         "Replication lag, per mongot pod", "JVM memory used, per mongot pod"]
sys.exit(0 if len(charts) == 27 and len(rows) == 5 and charts[:16] == first and rows[-1] == "Does every mongot pod hold the same data?" else 1)
PY
# Colours (issue #35). Perses fixes a colour per query, not per series, so every line has a query of its own with a
# fixed colour: blue, red, yellow, and purple for a fourth. No line is left to a palette, where two can look alike.
python3 - "${CHART}/files/mongodb-search.json" "${CHART}/files/mongodb-search.perses.json" <<'PY' && ok "every line has a fixed colour (blue, red, yellow, purple), the same in both forms, 3 wide, with no fill" || bad "dashboard colours"
import json, sys
g, p = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
want = ["#2a7de1", "#e0362c", "#d49b00", "#b03fc9"]
ok = True
for x in g["panels"]:
    if x["type"] != "timeseries": continue
    refs = [t["refId"] for t in x["targets"]]
    colours = {o["matcher"]["options"]: o["properties"][0]["value"]["fixedColor"] for o in x["fieldConfig"]["overrides"]}
    chart = next(v for v in p["panels"].values() if v["spec"]["display"]["name"] == x["title"])["spec"]["plugin"]["spec"]
    perses = {refs[s["queryIndex"]]: s["colorValue"] for s in chart.get("querySettings", []) if s["colorMode"] == "fixed"}
    ok &= set(colours) == set(refs) and set(colours.values()) <= set(want) and len(set(colours.values())) == len(colours)   # every query, no colour twice
    ok &= perses == colours and x["fieldConfig"]["defaults"]["custom"] == {"lineWidth": 3, "fillOpacity": 0}
    ok &= chart["visual"] == {"areaOpacity": 0, "lineWidth": 3}
    if x["title"].endswith(("per mongot pod", "per Envoy pod")):
        ok &= [colours[r] for r in refs] == want and " unless on (pod) " in x["targets"][3]["expr"]   # the fourth query: every further pod
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
[[ "$(grep -c -- '- alert:' <<<"$m")" == 4 && "$(grep -c -- '- record:' <<<"$m")" == 3 ]] && ok "four alerts and three recording rules" || bad "alert or rule count"
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

[[ $fails == 0 ]] && echo "all chart tests passed" || { echo "${fails} failed"; exit 1; }
