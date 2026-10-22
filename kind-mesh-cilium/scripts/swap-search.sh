#!/usr/bin/env bash
# Step 1 of story #132, in each cluster: the chart's Envoy-based search out, search on Cilium alone in. In place: the
# MongoDBSearch, its mongot pods and their volumes stay (the chart marks the resource helm.sh/resource-policy: keep);
# only its load balancer changes, from the operator's Envoy to loadBalancer.unmanaged, and mongot-global moves from
# the Envoy pods to the mongot pods. mongod is not touched: it already dials mongot-global.
#
#   kind-mesh-cilium/scripts/swap-search.sh            # mesh0, mesh1, mesh2, one at a time
#   kind-mesh-cilium/scripts/swap-search.sh mesh2      # one
#
# Run on a lab built by kind-mesh/ (scripts/up.sh, mongo-up.sh, search-up.sh).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
lab_env
# shellcheck disable=SC2153  # CLUSTERS comes from versions.env
read -r -a clusters <<<"${*:-$CLUSTERS}"
m="$here/manifests"

for c in "${clusters[@]}"; do
  ctx="kind-$c"
  say "$c: keep the operator, then the chart out"
  # The chart's OperatorGroup and Subscription would go with the release, and the operator with them.
  kubectl --context "$ctx" -n search annotate operatorgroup mongot-mongodb-search-helm helm.sh/resource-policy=keep --overwrite >/dev/null
  kubectl --context "$ctx" -n search annotate subscription mongodb-kubernetes helm.sh/resource-policy=keep --overwrite >/dev/null
  if helm status mongot -n search --kube-context "$ctx" >/dev/null 2>&1; then
    helm uninstall mongot -n search --kube-context "$ctx" --wait --timeout 5m >/dev/null
    echo "  release mongot uninstalled; MongoDBSearch kept: $(kubectl --context "$ctx" -n search get mongodbsearch mongot -o jsonpath='{.metadata.name}')"
  else
    echo "  no release mongot, nothing to uninstall"
  fi
  kubectl --context "$ctx" apply -f "$m/39-operator-olm.yaml" >/dev/null
  echo "  operator: $(kubectl --context "$ctx" -n search get csv mongodb-kubernetes.v1.13.0 -o jsonpath='{.status.phase}')"
  # The CSV running is not OLM managing it: a Subscription made beside the earlier chart's CSV cannot resolve (measured).
  # scripts/chart-up.sh reclaims that CSV; until then OLM does not manage the operator.
  rf=$(kubectl --context "$ctx" -n search get subscription mongodb-kubernetes -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].status}' 2>/dev/null || true)
  if [ "$rf" = True ]; then
    echo "  warning: the Subscription is ResolutionFailed beside the earlier CSV: run scripts/chart-up.sh to reclaim it"
  fi

  say "$c: mongot's certificate for mongot-global, the MongoDBSearch without Envoy"
  kubectl --context "$ctx" apply -f "$m/40-mongot-certificate.yaml" >/dev/null
  kubectl --context "$ctx" -n search wait certificate/ent-mongot-search-cert --for=condition=Ready --timeout=2m >/dev/null
  kubectl --context "$ctx" apply -f "$m/41-mongodbsearch.yaml" >/dev/null
  for _ in $(seq 1 90); do
    phase=$(kubectl --context "$ctx" -n search get mongodbsearch mongot -o jsonpath='{.status.phase}')
    gen=$(kubectl --context "$ctx" -n search get mongodbsearch mongot -o jsonpath='{.metadata.generation}')
    seen=$(kubectl --context "$ctx" -n search get mongodbsearch mongot -o jsonpath='{.status.observedGeneration}')
    [ "$phase" = Running ] && [ "$gen" = "$seen" ] && break; sleep 5
  done
  [ "$phase" = Running ] && [ "$gen" = "$seen" ] || die "$c: MongoDBSearch is ${phase:-?} (generation $gen, observed ${seen:-?}) after 7.5 minutes"
  kubectl --context "$ctx" -n search rollout status statefulset/mongot-search-0 --timeout=10m >/dev/null

  say "$c: what the operator's Envoy left, removed; mongot-global onto the mongot pods"
  kubectl --context "$ctx" -n search delete deployment mongot-search-lb-0 --ignore-not-found >/dev/null
  kubectl --context "$ctx" -n search delete service mongot-search-0-proxy-svc --ignore-not-found >/dev/null
  kubectl --context "$ctx" -n search delete certificate ent-mongot-search-lb-0-cert ent-mongot-search-lb-0-client-cert --ignore-not-found >/dev/null
  kubectl --context "$ctx" -n search delete secret ent-mongot-search-lb-0-cert ent-mongot-search-lb-0-client-cert --ignore-not-found >/dev/null
  kubectl --context "$ctx" apply -f "$m/42-mongot-global.yaml" >/dev/null
  kubectl --context "$ctx" -n search get pods --no-headers | awk '{print "  " $1, $2, $3}'
done
