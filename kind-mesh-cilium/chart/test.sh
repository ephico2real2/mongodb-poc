#!/usr/bin/env bash
# Render tests for the lab's chart, mongodb-search-cilium: no cluster needed. Each row PASS or FAIL; the exit code is
# the number of FAILs.
#
#   kind-mesh-cilium/chart/test.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1
chart=mongodb-search-cilium
lab=(-n search -f values-lab.yaml)
fails=0
row() { if [ "$1" = 0 ]; then printf 'PASS  %s\n' "$2"; else printf 'FAIL  %s\n' "$2"; fails=$((fails + 1)); fi; }
has() { grep -q -- "$1" <<<"$2"; }

helm lint "$chart" -f values-lab.yaml >/dev/null 2>&1; row $? "helm lint with the lab's values"

out=$(helm template t "$chart" "${lab[@]}")
has 'endpoint: mongot-global.search.svc.cluster.local:27028' "$out"; row $? "lab: the MongoDBSearch's endpoint is the global Service"
! grep -qE '^[[:space:]]+managed:' <<<"$out"; row $? "lab: no operator Envoy (no loadBalancer.managed)"
! has 'certsSecretPrefix' "$out"; row $? "lab: no TLS on the search hop (searchTLS.enabled: false)"
has 'service.cilium.io/lb-l7: enabled' "$out"; row $? "lab: mongot-global balanced per request"
has 'service.cilium.io/global: "true"' "$out" && has 'service.cilium.io/affinity: "local"' "$out"; row $? "lab: mongot-global is global, local first"
has 'app: mongot-search-0-svc' "$out"; row $? "lab: mongot-global selects the mongot pods"
has 'replicas: 2' "$out"; row $? "lab: two mongot"
has 'startingCSV: mongodb-kubernetes.v1.13.0' "$out" && has 'installPlanApproval: Manual' "$out"; row $? "lab: the operator pinned to 1.13.0, Manual approval"
has 'TARGET, value: "mongodb-kubernetes.v1.13.0"' "$out"; row $? "lab: the approver approves 1.13.0 only"
has 'helm.sh/resource-policy: keep' "$out"; row $? "lab: the MongoDBSearch is kept on uninstall"

out=$(helm template t "$chart" "${lab[@]}" --set searchTLS.enabled=true --set globalService.lbL7.enabled=false)
has 'certsSecretPrefix: ent' "$out" && ! has 'lb-l7' "$out"; row $? "step 1 form: TLS on the search hop, balanced per connection"

err=$(helm template t "$chart" "${lab[@]}" --set searchTLS.enabled=true 2>&1 >/dev/null)
has 'cleartext gRPC only' "$err"; row $? "refused: TLS with per-request balancing"

err=$(helm template t "$chart" -n search 2>&1 >/dev/null)
has 'source.hostAndPorts is empty' "$err"; row $? "refused: no members in source.hostAndPorts"

out=$(helm template t "$chart" "${lab[@]}" --set operator.install=false)
! has 'kind: Subscription' "$out" && ! has 'kind: Job' "$out" && has 'kind: MongoDBSearch' "$out"; row $? "operator.install false: no Subscription, no approver, the MongoDBSearch still"

echo "== $fails failed"
exit "$fails"
