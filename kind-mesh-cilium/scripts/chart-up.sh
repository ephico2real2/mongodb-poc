#!/usr/bin/env bash
# Installs the lab's search with its own chart, mongodb-search-cilium, release mongot-search, in every cluster. On a
# lab where kind-mesh-cilium's steps already made the objects by hand, the release adopts them (Helm's ownership
# labels and annotations are set first), so nothing is recreated: the chart's rendering equals the live
# MongoDBSearch, which the operator therefore does not roll.
#
#   kind-mesh-cilium/scripts/chart-up.sh            # mesh0, mesh1, mesh2; idempotent: helm upgrade --install
#   kind-mesh-cilium/scripts/chart-up.sh mesh2      # one
#
# A CSV that blocks the Subscription (left by an earlier install, or by scripts/swap-search.sh) is cleared by the
# chart's own hook, templates/00-csv-reclaim.yaml; its log is printed below.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
lab_env
# shellcheck disable=SC2153  # CLUSTERS comes from versions.env
read -r -a clusters <<<"${*:-$CLUSTERS}"
release=mongot-search
ns=search
chart="$here/chart/mongodb-search-cilium"
values="$here/chart/values-lab.yaml"

"$here/chart/test.sh" >/dev/null || die "the chart's render tests fail: kind-mesh-cilium/chart/test.sh"
for c in "${clusters[@]}"; do
  ctx="kind-$c"
  say "$c: release $release (chart mongodb-search-cilium)"
  # Adopt what exists: an object Helm did not make is refused unless it carries the release's ownership.
  for obj in operatorgroup/mongot-mongodb-search-helm subscription/mongodb-kubernetes mongodbsearch/mongot service/mongot-global; do
    if kubectl --context "$ctx" -n "$ns" get "$obj" >/dev/null 2>&1; then
      kubectl --context "$ctx" -n "$ns" label "$obj" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
      kubectl --context "$ctx" -n "$ns" annotate "$obj" meta.helm.sh/release-name="$release" meta.helm.sh/release-namespace="$ns" --overwrite >/dev/null
      echo "  adopted $obj"
    fi
  done
  gen_before=$(kubectl --context "$ctx" -n "$ns" get mongodbsearch mongot -o jsonpath='{.metadata.generation}' 2>/dev/null || echo none)
  helm_r upgrade --install "$release" "$chart" -n "$ns" --kube-context "$ctx" -f "$values" --wait --timeout 10m >/dev/null \
    || die "the release did not install on $c"
  gen_after=$(kubectl --context "$ctx" -n "$ns" get mongodbsearch mongot -o jsonpath='{.metadata.generation}')
  echo "  release $(helm status "$release" -n "$ns" --kube-context "$ctx" -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["info"]["status"], "revision", d["version"])')"
  echo "  MongoDBSearch generation $gen_before -> $gen_after ($([ "$gen_before" = "$gen_after" ] && echo 'spec unchanged: no mongot rolled' || echo 'spec changed'))"
  kubectl --context "$ctx" -n "$ns" logs "job/${release}-mongodb-search-cilium-csv-reclaim" 2>/dev/null | sed 's/^/  /'
  echo "  $(kubectl --context "$ctx" -n "$ns" logs "job/${release}-mongodb-search-cilium-approver" 2>/dev/null | tail -1)"
done
