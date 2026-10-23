#!/usr/bin/env bash
# Story #198: Cilium's Ingress controller on one cluster, for the vanity chart's test on kind (expose.type=ingress,
# class cilium, TLS passthrough): the lab has no OpenShift router. One Helm upgrade of the cluster's Cilium release
# with --reset-then-reuse-values, as cilium-build.sh does, adding cilium/values-ingress.yaml and nothing else: the
# release's values before and after are diffed, and only the ingressController keys may differ. The upgrade restarts
# the cluster's Cilium agents (#187: search on that cluster runs without Cilium's L7 proxy for about 62 s after a
# restart); the times are printed. Idempotent: a cluster that has it already is upgraded to the same values.
#
#   kind-mesh-cilium/scripts/ingress-up.sh mesh2 2>&1 | tee kind-mesh-cilium/output/ingress-up-mesh2.txt
#
# After it: the IngressClass cilium, and the Service cilium-ingress in kube-system with an address from the cluster's
# LoadBalancer pool, which the Mac reaches through the route up.sh prints.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
lab_env
c=${1:?usage: ingress-up.sh <cluster, e.g. mesh2>}
ctx="kind-$c"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

say "$c: the release's values before"
helm get values cilium -n kube-system --kube-context "$ctx" -o json >"$tmp/before.json"
helm get metadata cilium -n kube-system --kube-context "$ctx" -o json >"$tmp/metadata.json"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["chart"] == "cilium" and m["version"] == sys.argv[2], (m["chart"], m["version"])' \
  "$tmp/metadata.json" "$CILIUM_VERSION" || die "$c: the release must already be cilium $CILIUM_VERSION"
echo "  revision $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$tmp/metadata.json"), chart cilium $CILIUM_VERSION"

say "$c: helm upgrade --reset-then-reuse-values -f cilium/values-ingress.yaml (the agents restart)"
echo "  start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
helm_r upgrade cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system --kube-context "$ctx" \
  --reset-then-reuse-values -f "$here/cilium/values-ingress.yaml" --wait --timeout 10m >/dev/null \
  || die "Helm could not turn on the Ingress controller on $c"
echo "  helm done $(date -u +%Y-%m-%dT%H:%M:%SZ)"
# The flag lands in the cilium-config ConfigMap, which the agent and the operator read at start: the chart's
# DaemonSet template does not change with it (measured: the upgrade left the agents' pods as they were), so both are
# restarted here, as Cilium's Ingress page says (kubectl rollout restart of the operator and the agents).
kubectl --context "$ctx" -n kube-system rollout restart deployment/cilium-operator ds/cilium
kubectl --context "$ctx" -n kube-system rollout status deployment/cilium-operator --timeout=5m
kubectl --context "$ctx" -n kube-system rollout status ds/cilium --timeout=10m
echo "  agents rolled $(date -u +%Y-%m-%dT%H:%M:%SZ)"
cilium_healthy "$c" "after the Ingress controller"
echo "  cilium healthy $(date -u +%Y-%m-%dT%H:%M:%SZ)"

say "$c: the release's values after, against before: only ingressController may differ"
helm get values cilium -n kube-system --kube-context "$ctx" -o json >"$tmp/after.json"
python3 - "$tmp/before.json" "$tmp/after.json" <<'PY'
import json, sys
before, after = (json.load(open(p)) for p in sys.argv[1:3])
changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
print("  keys that differ:", changed or "none")
print("  ingressController:", json.dumps(after.get("ingressController")))
sys.exit(0 if changed in ([], ["ingressController"]) else 1)
PY

say "$c: the IngressClass and the shared Ingress Service's address"
kubectl --context "$ctx" get ingressclass cilium
for _ in $(seq 60); do
  ip=$(kubectl --context "$ctx" -n kube-system get svc cilium-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -n "$ip" ] && break
  sleep 2
done
kubectl --context "$ctx" -n kube-system get svc cilium-ingress
[ -n "${ip:-}" ] || die "$c: cilium-ingress has no LoadBalancer address from the pool"
echo "  cilium-ingress $ip (from the pool $(kubectl --context "$ctx" get ciliumloadbalancerippools -o jsonpath='{.items[0].metadata.name}'))"
lb_path
