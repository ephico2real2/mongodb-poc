#!/usr/bin/env bash
# Installs search in every cluster: the chart's three TLS Secrets and its trust bundle from the shared CA, the chart
# itself in namespace search (the operator through OLM, one mongot, one Envoy), and mongot-global, the global Service
# every mongod dials. Run after mongo-up.sh: the sync user's Secret and the replica set must exist.
#
#   kind-mesh/scripts/search-up.sh      # idempotent: helm upgrade --install
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
cd "$LAB_DIR"
lab_env
# shellcheck disable=SC2153  # CLUSTERS comes from versions.env
read -r -a clusters <<<"$CLUSTERS"
values=values/search.yaml
oc_image="$(sed -n 's/^    repository: //p' "$values"):$(sed -n 's/^    tag: "\(.*\)"/\1/p' "$values")"

# The Jobs' image is the lab's own (images/oc): built once by the VM's docker and copied into every node.
say "the Jobs' image, $oc_image, built and loaded into every node"
docker image inspect "$oc_image" >/dev/null 2>&1 || docker build -q -f images/oc/Containerfile -t "$oc_image" images/oc >/dev/null
for c in "${clusters[@]}"; do kind load docker-image "$oc_image" --name "$c" >/dev/null; echo "  $c: loaded"; done

for c in "${clusters[@]}"; do
  say "$c: the chart's TLS Secrets and trust bundle"
  kubectl --context "kind-$c" apply -f manifests/10-namespaces.yaml -f manifests/20-search-certificates.yaml >/dev/null
  kubectl --context "kind-$c" -n search wait certificate --all --for=condition=Ready --timeout=2m >/dev/null
  # The trust bundle is the shared root itself: it signs every mongod, mongot and Envoy certificate of the lab.
  kubectl --context "kind-$c" -n cert-manager get secret mesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | kubectl --context "kind-$c" -n search create configmap ent-trust-bundle --from-file=ca.crt=/dev/stdin \
      --dry-run=client -o yaml | kubectl --context "kind-$c" apply -f - >/dev/null
  kubectl --context "kind-$c" -n search get secret search-sync-source-password >/dev/null \
    || die "$c has no search/search-sync-source-password: run mongo-up.sh first"
  echo "  certificates Ready, ent-trust-bundle applied"
done

for c in "${clusters[@]}"; do
  say "$c: the chart (helm upgrade --install mongot, namespace search)"
  helm upgrade --install mongot ../chart/mongodb-search-helm -n search --kube-context "kind-$c" -f "$values" --timeout 20m \
    || { kubectl --context "kind-$c" -n search get pods,jobs,mongodbsearch 2>&1 | tail -20; die "the chart did not install on $c"; }
  kubectl --context "kind-$c" apply -f manifests/22-mongot-global.yaml >/dev/null
done

say "mongot-global: every cluster's Envoy, seen from each"
for c in "${clusters[@]}"; do
  echo "$c:"
  ip=$(kubectl --context "kind-$c" -n search get svc mongot-global -o jsonpath='{.spec.clusterIP}')
  kubectl --context "kind-$c" -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list 2>/dev/null \
    | grep -A3 -F "$ip:27028" | sed 's/^/  /'
done
