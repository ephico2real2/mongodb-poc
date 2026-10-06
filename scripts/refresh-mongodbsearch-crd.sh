#!/usr/bin/env bash
# Refreshes chart/mongodb-search-helm/crds/mongodbsearch.mongodb.com.yaml from a cluster that runs the operator
# version in Chart.yaml's appVersion. Run it after changing that version:  scripts/refresh-mongodbsearch-crd.sh
# It also prints the mongot version that operator runs by default. Needs oc logged in to such a cluster, and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

PACKAGE=mongodb-kubernetes
CRD=mongodbsearch.mongodb.com
CHART=chart/mongodb-search-helm
OUT=${CHART}/crds/${CRD}.yaml
want="${PACKAGE}.v$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' ${CHART}/Chart.yaml)"

# OLM's own CSV carries no olm.copiedFrom label; its copies in other namespaces do.
have="$(oc get csv -A -o json | python3 -c '
import json, sys
pkg = sys.argv[1]
names = {c["metadata"]["name"] for c in json.load(sys.stdin)["items"]
         if "olm.copiedFrom" not in (c["metadata"].get("labels") or {})}
print("\n".join(sorted(n for n in names if n.startswith(pkg + ".v"))))' "${PACKAGE}")"
[[ "${have}" == "${want}" ]] || { echo "the cluster runs '${have:-no ${PACKAGE}}'; Chart.yaml's appVersion wants ${want}" >&2; exit 1; }

{
  cat <<HDR
# The MongoDBSearch CRD as ${PACKAGE} ${want#*.v} installs it (read from the cluster's CRD; status and OLM metadata removed).
# Helm installs crds/ only when the CRD is absent and never changes or deletes it, so \`helm install\` can create
# the chart's MongoDBSearch before OLM has installed the operator; OLM then takes over this CRD and keeps it current.
# Do not edit by hand: regenerate with scripts/refresh-mongodbsearch-crd.sh.
HDR
  # Keep the name, the generator annotation and the spec; oc prints the YAML.
  oc get crd "${CRD}" -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
m = d["metadata"]
gen = {k: v for k, v in (m.get("annotations") or {}).items() if k == "controller-gen.kubebuilder.io/version"}
json.dump({"apiVersion": d["apiVersion"], "kind": d["kind"],
           "metadata": {"name": m["name"], "annotations": gen}, "spec": d["spec"]}, sys.stdout)' \
    | oc create --dry-run=client -f - -o yaml | grep -v '^  creationTimestamp: null$'
} > "${OUT}.tmp"
mv "${OUT}.tmp" "${OUT}"
echo "wrote ${OUT} (${PACKAGE} ${want#*.v})"

# The mongot version this operator runs when the resource sets no spec.version (values.yaml, search.version).
ns="$(oc get csv -A -o json | python3 -c '
import json, sys
for c in json.load(sys.stdin)["items"]:
    if c["metadata"]["name"] == sys.argv[1] and "olm.copiedFrom" not in (c["metadata"].get("labels") or {}):
        print(c["metadata"]["namespace"]); break' "${want}")"
oc get csv "${want}" -n "${ns}" -o json | python3 -c '
import json, sys
for d in json.load(sys.stdin)["spec"]["install"]["spec"]["deployments"]:
    for c in d["spec"]["template"]["spec"]["containers"]:
        for e in c.get("env", []):
            if e["name"] == "MDB_SEARCH_VERSION": print("default mongot version (MDB_SEARCH_VERSION):", e.get("value"))'
