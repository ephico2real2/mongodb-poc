#!/usr/bin/env bash
# Installs the lab's search with its own chart, mongodb-search-cilium, release mongot-search, in every cluster. On a
# lab where kind-mesh-cilium's steps already made the objects by hand, the release adopts them (Helm's ownership
# labels and annotations are set first), so nothing is recreated: the chart's rendering equals the live
# MongoDBSearch, which the operator therefore does not roll.
#
#   kind-mesh-cilium/scripts/chart-up.sh      # idempotent: helm upgrade --install
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
lab_env
# shellcheck disable=SC2153  # CLUSTERS comes from versions.env
read -r -a clusters <<<"$CLUSTERS"
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
  # A CSV left by an earlier install blocks a new Subscription from resolving ("@existing/... and <catalog>/...
  # provide" the same CSV: measured after swap-search.sh, the operator running but OLM no longer managing it). The
  # earlier chart's csv-reclaim did this: delete that CSV, so the Subscription installs it again, and the approver
  # approves exactly operator.version. The operator is away for that minute; mongot and mongod keep serving.
  msg=$(kubectl --context "$ctx" -n "$ns" get subscription mongodb-kubernetes \
    -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].message}' 2>/dev/null || true)
  if [[ "$msg" == *"@existing/$ns//mongodb-kubernetes."*"provide"* ]]; then
    csv=$(sed -n "s|.*@existing/$ns//\(mongodb-kubernetes\.v[0-9.]*\) .*|\1|p" <<<"$msg")
    echo "  the Subscription cannot resolve beside $csv, left by an earlier install: deleting that CSV"
    kubectl --context "$ctx" -n "$ns" delete csv "$csv" --wait=true >/dev/null
  fi
  gen_before=$(kubectl --context "$ctx" -n "$ns" get mongodbsearch mongot -o jsonpath='{.metadata.generation}' 2>/dev/null || echo none)
  helm_r upgrade --install "$release" "$chart" -n "$ns" --kube-context "$ctx" -f "$values" --wait --timeout 10m >/dev/null \
    || die "the release did not install on $c"
  gen_after=$(kubectl --context "$ctx" -n "$ns" get mongodbsearch mongot -o jsonpath='{.metadata.generation}')
  echo "  release $(helm status "$release" -n "$ns" --kube-context "$ctx" -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["info"]["status"], "revision", d["version"])')"
  echo "  MongoDBSearch generation $gen_before -> $gen_after ($([ "$gen_before" = "$gen_after" ] && echo 'spec unchanged: no mongot rolled' || echo 'spec changed'))"
  echo "  approver: $(kubectl --context "$ctx" -n "$ns" logs job/${release}-mongodb-search-cilium-approver 2>/dev/null | tail -1)"
done
