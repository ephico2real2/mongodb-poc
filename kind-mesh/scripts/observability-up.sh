#!/usr/bin/env bash
# Hubble's flows between mongodb and search, from all three clusters, on a Grafana dashboard with each flow's source
# and destination cluster (grafana.com 23862, extended), in mesh0, namespace observability:
#   mesh0's Hubble relay (it reaches every node of the mesh) → hubble-observer → OpenTelemetry collector → Loki → Grafana.
# The setup of cilium-implementation-poc demo 25, without its cf2cnp and its policy, and with every verdict.
#
#   kind-mesh/scripts/observability-up.sh     # idempotent; prints Grafana's address
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
cd "$LAB_DIR"
lab_env
ctx=kind-mesh0
o=observability
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana >/dev/null

say "namespace $o and the observer's client certificate for the relay"
kubectl --context "$ctx" create namespace "$o" --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
kubectl --context "$ctx" apply -f "$o/10-relay-client-cert.yaml" >/dev/null
kubectl --context "$ctx" -n "$o" wait certificate/hubble-observer-relay-certs --for=condition=Ready --timeout=2m >/dev/null

say "Loki 3.6 (chart 7.3.0), one process, 6 h of flows"
helm_r upgrade --install loki grafana/loki --version 7.3.0 -n "$o" --kube-context "$ctx" -f "$o/values-loki.yaml" \
  --wait --timeout 10m >/dev/null

say "hubble-observer (vendored chart) and the collector that ships its flows"
helm_r upgrade --install hubble-observer "$o/chart/hubble-observer" -n "$o" --kube-context "$ctx" \
  -f "$o/values-hubble-observer.yaml" --wait --timeout 5m >/dev/null
kubectl --context "$ctx" apply -f "$o/20-otel-collector.yaml" >/dev/null
kubectl --context "$ctx" -n "$o" rollout status ds/otel-collector --timeout=3m >/dev/null

say "Grafana 12.3 (chart 10.5.15) with Loki and the flows dashboard"
if ! kubectl --context "$ctx" -n "$o" get secret grafana-admin >/dev/null 2>&1; then
  kubectl --context "$ctx" -n "$o" create secret generic grafana-admin --from-literal=admin-user=admin \
    --from-file=admin-password=<(openssl rand -hex 16 | tr -d '\n') >/dev/null
  echo "  Secret grafana-admin made (user admin; the password only in the Secret)"
fi
# The grafana.com export's import-time inputs resolved as the observer chart's template does (demo 25
# dashboard-from-file.sh): the data source to the dashboard's own variable, the observer's namespace; then a ConfigMap
# the sidecar provisions.
python3 - "$o/dashboard-cilium-hubble-flows.json" "$o" <<'PY' | kubectl --context "$ctx" apply -f - >/dev/null
import json, sys
path, ns = sys.argv[1:]
raw = open(path).read().replace("${DS_LOKI}", "${datasource}").replace("${VAR_HUBBLEOBSERVERNAMESPACE}", ns) \
    .replace("${VAR_HUBBLEOBSERVERCF2CNPURL}", "")
d = json.loads(raw); d.pop("__inputs", None); d.pop("__requires", None); d["id"] = None; d["uid"] = "hubble-observer-23862"
print(json.dumps({"apiVersion": "v1", "kind": "ConfigMap",
                  "metadata": {"name": "dashboard-hubble-flows", "namespace": ns,
                               "labels": {"grafana_dashboard": "1"}, "annotations": {"grafana_folder": "Hubble"}},
                  "data": {"hubble-observer-23862.json": json.dumps(d, separators=(",", ":"))}}))
PY
helm_r upgrade --install grafana grafana/grafana --version 10.5.15 -n "$o" --kube-context "$ctx" \
  -f "$o/values-grafana.yaml" --wait --timeout 5m >/dev/null
ip=""
for _ in $(seq 1 24); do
  ip=$(kubectl --context "$ctx" -n "$o" get svc grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [ -n "$ip" ] && break; sleep 5
done
kubectl --context "$ctx" -n "$o" get pods --no-headers | awk '{print "  " $1, $2, $3}'
echo "  Grafana: http://${ip:-<no address yet>}/d/hubble-observer-23862  (user admin; password:"
echo "  kubectl --context $ctx -n $o get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
