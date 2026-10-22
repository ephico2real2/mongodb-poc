#!/usr/bin/env bash
# Step 2 of story #132, on the lab after step 1: Cilium balances each search request instead of each connection.
#   A. WireGuard and Cilium's L7 load balancer in every cluster (one Helm upgrade each, one agent restart each)
#   C. the search hop to cleartext: mongot without TLS, then each mongod with searchTLSMode=disabled, one member at a
#      time, secondaries first; mongod's replica set traffic keeps TLS
#   B. mongot-global balanced per request (service.cilium.io/lb-l7), last: Cilium's L7 proxy reads only cleartext
# A search load through mesh2's member runs during A and C, so what each phase costs is measured
# (output/step2-load-*.txt).
#
#   kind-mesh-cilium/scripts/cleartext-l7.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
lab_env
# shellcheck disable=SC2153  # CLUSTERS comes from versions.env
read -r -a clusters <<<"$CLUSTERS"
admin_pw=$(kubectl --context kind-mesh0 -n mongodb get secret mongo-admin -o jsonpath='{.data.password}' | base64 -d)
out="$here/output"
member_state() { # <cluster>: PRIMARY, SECONDARY or nothing
  printf 'db.getSiblingDB("admin").auth("labAdmin", "%s"); const h = db.hello(); print(h.isWritablePrimary ? "PRIMARY" : (h.secondary ? "SECONDARY" : ""))' "$admin_pw" \
    | kubectl --context "kind-$1" -n mongodb exec -i mongo-0 -c mongod -- mongosh --quiet --tls --tlsCAFile /run/mongod/ca.crt --host localhost --file /dev/stdin 2>/dev/null
}
load_bg() { # <seconds> <file>: searches through mesh2's member, in the background
  "$here/drills.sh" load-only mesh2 "$1" >"$2" 2>&1 &
}

say "A. WireGuard and Cilium's L7 load balancer, one cluster at a time"
load_bg 420 "$out/step2-load-cilium.txt"
for c in "${clusters[@]}"; do
  helm_r upgrade cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system --kube-context "kind-$c" --reuse-values \
    -f "$here/cilium/values-step2.yaml" --wait --timeout 10m >/dev/null || die "Helm refused the upgrade on $c"
  # The operator and the agents read cilium-config only at start, and the upgrade changes that ConfigMap but not their
  # templates. Without restarts the agents stay unencrypted (first run: "Encryption: Disabled"). The operator goes
  # first: with the L7 backend on, an agent will not start until the operator has registered the CiliumEnvoyConfig
  # CRDs, and exits after 5 minutes (second run: "Unable to find all Cilium CRDs necessary within 5m0s").
  kubectl --context "kind-$c" -n kube-system rollout restart deploy/cilium-operator >/dev/null
  kubectl --context "kind-$c" -n kube-system rollout status deploy/cilium-operator --timeout=3m >/dev/null
  for _ in $(seq 1 60); do
    kubectl --context "kind-$c" get crd ciliumenvoyconfigs.cilium.io ciliumclusterwideenvoyconfigs.cilium.io >/dev/null 2>&1 && break; sleep 3
  done
  kubectl --context "kind-$c" -n kube-system rollout restart ds/cilium >/dev/null
  kubectl --context "kind-$c" -n kube-system rollout status ds/cilium --timeout=5m >/dev/null
  kubectl --context "kind-$c" -n kube-system rollout status ds/cilium-envoy --timeout=5m >/dev/null
  echo "  $c: $(kubectl --context "kind-$c" -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status 2>/dev/null | grep -E 'Encryption' | tr -s ' ')"
done
# The search hop goes cleartext only on a mesh that encrypts: every agent of every cluster must report WireGuard.
for c in "${clusters[@]}"; do
  for p in $(kubectl --context "kind-$c" -n kube-system get pods -l k8s-app=cilium -o name); do
    kubectl --context "kind-$c" -n kube-system exec "$p" -c cilium-agent -- cilium-dbg encrypt status 2>/dev/null | grep -q 'Encryption: Wireguard' \
      || die "$c $p does not report WireGuard encryption: stopping before the search hop goes cleartext"
  done
done
echo "  every agent of the three clusters reports WireGuard encryption"
for c in "${clusters[@]}"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 5m | grep -E 'connected|Cluster Connections' | sed "s/^/  $c: /"; done
wait

say "C. the search hop to cleartext: mongot first, then each mongod (secondaries first)"
load_bg 600 "$out/step2-load-cleartext.txt"
for c in "${clusters[@]}"; do kubectl --context "kind-$c" apply -f "$here/manifests/45-mongodbsearch-cleartext.yaml" >/dev/null; done
for c in "${clusters[@]}"; do
  kubectl --context "kind-$c" -n search rollout status statefulset/mongot-search-0 --timeout=10m >/dev/null
  echo "  $c: MongoDBSearch $(kubectl --context "kind-$c" -n search get mongodbsearch mongot -o jsonpath='{.status.phase}'), mongot without TLS"
done
order=()
for c in "${clusters[@]}"; do [ "$(member_state "$c")" = PRIMARY ] || order+=("$c"); done
for c in "${clusters[@]}"; do [ "$(member_state "$c")" = PRIMARY ] && order+=("$c"); done
for c in "${order[@]}"; do
  sed "s/__MESH__/$c/g; s/searchTLSMode=requireTLS/searchTLSMode=disabled/" "$here/../kind-mesh/manifests/13-mongod.yaml" \
    | kubectl --context "kind-$c" apply -f - >/dev/null
  kubectl --context "kind-$c" -n mongodb rollout status statefulset/mongo --timeout=5m >/dev/null
  for _ in $(seq 1 60); do st=$(member_state "$c"); [ -n "$st" ] && break; sleep 2; done
  echo "  $c: mongod with searchTLSMode=disabled, back as ${st:-?}"
done

say "B. mongot-global balanced per request"
for c in "${clusters[@]}"; do kubectl --context "kind-$c" apply -f "$here/manifests/44-mongot-global-l7.yaml" >/dev/null; done
sleep 10
for c in "${clusters[@]}"; do
  echo "  $c: CiliumEnvoyConfig for mongot-global: $(kubectl --context "kind-$c" -n search get ciliumenvoyconfig -o name 2>/dev/null | tr '\n' ' ')"
done
wait
say "step 2 applied; loads in output/step2-load-cilium.txt and step2-load-cleartext.txt"
