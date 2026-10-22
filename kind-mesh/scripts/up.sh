#!/usr/bin/env bash
# Builds the platform of the kind mesh lab in the Colima VM: the kind network, mesh0, mesh1 and mesh2, and in each
# Cilium, CoreDNS upstreams, its LoadBalancer block, metrics-server, cert-manager with the shared CA, then Hubble and
# Cluster Mesh across the three, then OLM. Adapted from cilium-implementation-poc scripts/lab-up.sh, in its order:
# every cluster is complete on its own before anything crosses clusters, and the mesh is declared once every
# control plane's address is known.
#
#   kind-mesh/scripts/colima-up.sh && kind-mesh/scripts/up.sh     # idempotent: what exists is kept or upgraded
#   kind-mesh/scripts/down.sh                                    # deletes the three clusters
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
cd "$LAB_DIR"
lab_env
# shellcheck disable=SC2153  # CLUSTERS comes from versions.env
read -r -a clusters <<<"$CLUSTERS"
first="${clusters[0]}"

say "tools"
for t in docker kind kubectl helm cilium python3 openssl curl; do command -v "$t" >/dev/null || die "$t is not installed"; done
kv=$(kind version | awk '{print $2}' | sed 's/^v//')
[ "$kv" = "$KIND_VERSION" ] || echo "warning: kind $kv, the lab pins $KIND_VERSION"
printf 'kind %s | helm %s | %s | docker %s at %s\n' "$kv" "$(helm version --short)" \
  "$(cilium version --client 2>/dev/null | head -1)" "$(docker version --format '{{.Server.Version}}')" "${DOCKER_HOST/$HOME/\~}"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update cilium jetstack metrics-server >/dev/null

# kind creates its network without an IPv4 subnet when none exists, and Docker then picks any pool. The LoadBalancer
# blocks are pinned to 172.18.255.0/24, so the network is made here with that subnet and containers held to the lower
# half (cilium-implementation-poc lab-up.sh).
say "the kind docker network: $LAB_SUBNET, containers from $LAB_IP_RANGE"
if docker network inspect kind >/dev/null 2>&1; then
  have=$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
  [ "$have" = "$LAB_SUBNET" ] || die "a docker network 'kind' exists with subnet $have, not $LAB_SUBNET"
  echo "exists, kept"
else
  docker network create -d bridge --subnet "$LAB_SUBNET" --ip-range "$LAB_IP_RANGE" --gateway "${LAB_SUBNET%.*.*}.0.1" \
    -o com.docker.network.bridge.enable_ip_masquerade=true kind >/dev/null
  echo "created"
fi

for c in "${clusters[@]}"; do
  say "create $c"
  if kind get clusters 2>/dev/null | grep -qx "$c"; then echo "exists, kept"; else kind create cluster --config "clusters/$c.yaml" --wait 0; fi
done
cp_ip() { docker inspect "$1-control-plane" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'; }

cluster_up() {
  local c="$1" ctx="kind-$1" dns ok=0 i
  say "$c: Cilium $CILIUM_VERSION, agent $CILIUM_IMAGE (no Hubble yet: its certificates need cert-manager)"
  if helm status cilium -n kube-system --kube-context "$ctx" >/dev/null 2>&1; then
    echo "installed, kept; the mesh step upgrades it"
  else
    # The API server by the name in its certificate, not an address Docker may change on restart.
    # shellcheck disable=SC2154  # cilium_image_args comes from lib.sh
    helm_r install cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system --kube-context "$ctx" \
      -f cilium/values.yaml -f "cilium/values-$c.yaml" --set k8sServiceHost="$c-control-plane" --set k8sServicePort=6443 \
      --set hubble.enabled=false --set hubble.relay.enabled=false "${cilium_image_args[@]}" >/dev/null \
      || die "Helm refused the Cilium install on $c"
  fi
  cilium_healthy "$c" "after install"
  # After the install, once the operator has registered the release's CRDs; the mesh step's agent restart then makes
  # every agent write status.workloads.
  cilium_build_crd "$c"
  kubectl --context "$ctx" wait node --all --for=condition=Ready --timeout=5m >/dev/null
  kubectl --context "$ctx" get nodes -o wide --no-headers | awk '{print "  " $1, $2, $6}'

  # A kind node's resolver is Docker's 127.0.0.11, its own loopback, which a pod cannot reach: CoreDNS is given
  # public resolvers (cilium-implementation-poc lab-up.sh), and one name is resolved from a pod to prove it.
  say "$c: CoreDNS upstreams"
  kubectl --context "$ctx" -n kube-system patch deployment coredns \
    --patch '{"spec":{"template":{"spec":{"dnsPolicy":"None","dnsConfig":{"nameservers":["8.8.4.4","8.8.8.8"]}}}}}' >/dev/null
  kubectl --context "$ctx" -n kube-system rollout status deploy/coredns --timeout=3m >/dev/null
  for i in 1 2 3 4 5 6; do
    dns=$(kubectl --context "$ctx" run "dns-probe-$i" --rm -i --restart=Never --image=busybox:1.36 --command -- nslookup one.one.one.one 2>&1 || true)
    if printf '%s\n' "$dns" | grep -qE 'Address: [0-9]'; then ok=1; break; fi
    sleep 5
  done
  [ "$ok" = 1 ] || { printf '%s\n' "$dns"; die "pods on $c cannot resolve an external name"; }
  echo "  resolved: $(printf '%s\n' "$dns" | grep -m1 -E 'Address: [0-9]')"

  say "$c: its LoadBalancer block and L2 announcements"
  kubectl --context "$ctx" apply -f "cilium/lb-ippool-$c.yaml" >/dev/null
  kubectl --context "$ctx" get ciliumloadbalancerippools --no-headers \
    -o custom-columns='POOL:.metadata.name,START:.spec.blocks[*].start,STOP:.spec.blocks[*].stop'

  say "$c: metrics-server $METRICS_SERVER_CHART (kind's kubelets: --kubelet-insecure-tls)"
  helm_r upgrade --install metrics-server metrics-server/metrics-server --version "$METRICS_SERVER_CHART" -n kube-system \
    --kube-context "$ctx" --set 'args={--kubelet-insecure-tls}' --wait --timeout 5m >/dev/null

  say "$c: cert-manager $CERT_MANAGER_VERSION, the shared root, ClusterIssuer mesh-ca"
  helm_r upgrade --install cert-manager jetstack/cert-manager --version "$CERT_MANAGER_VERSION" -n cert-manager \
    --create-namespace --kube-context "$ctx" --set crds.enabled=true --wait --timeout 5m >/dev/null
  if [ "$c" = "$first" ]; then
    kubectl --context "$ctx" apply -f manifests/00-root-ca.yaml >/dev/null
    kubectl --context "$ctx" -n cert-manager wait certificate/mesh-root-ca --for=condition=Ready --timeout=2m >/dev/null
  else
    # Only the CA Secret crosses: name, namespace, type and data, nothing of mesh0's own metadata.
    kubectl --context "kind-$first" -n cert-manager get secret mesh-root-ca -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s.get("type", "kubernetes.io/tls"),
  "metadata": {"name": s["metadata"]["name"], "namespace": "cert-manager"}, "data": s["data"]}))' \
      | kubectl --context "$ctx" apply -f - >/dev/null
  fi
  kubectl --context "$ctx" apply -f manifests/01-ca-issuer.yaml >/dev/null
  kubectl --context "$ctx" wait clusterissuer/mesh-ca --for=condition=Ready --timeout=2m >/dev/null
  echo "  root CA $(kubectl --context "$ctx" -n cert-manager get secret mesh-root-ca -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | cut -c1-23)…, issuer Ready"
}

for c in "${clusters[@]}"; do cluster_up "$c"; done

# What `cilium clustermesh enable` and `connect` do, as Helm values: the apiserver on a NodePort, and every member by
# name and control-plane address. Cilium ignores its own entry in the list, so the same list goes to every cluster.
say "Hubble and Cluster Mesh on ${clusters[*]}"
fps=$(for c in "${clusters[@]}"; do kubectl --context "kind-$c" -n cert-manager get secret mesh-root-ca -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -fingerprint -sha256; done | sort -u | wc -l | tr -d ' ')
[ "$fps" = 1 ] || die "the clusters do not share one root CA ($fps fingerprints)"
declared=(--set clustermesh.useAPIServer=true --set clustermesh.apiserver.service.type=NodePort --set clustermesh.config.enabled=true)
i=0
for c in "${clusters[@]}"; do
  declared+=(--set-string "clustermesh.config.clusters[$i].name=$c" --set-string "clustermesh.config.clusters[$i].ips[0]=$(cp_ip "$c")"
    --set "clustermesh.config.clusters[$i].port=32379")
  i=$((i + 1))
done
for c in "${clusters[@]}"; do
  helm_r upgrade cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system --kube-context "kind-$c" \
    -f cilium/values.yaml -f "cilium/values-$c.yaml" -f cilium/values-mesh.yaml \
    --set k8sServiceHost="$c-control-plane" --set k8sServicePort=6443 "${declared[@]}" "${cilium_image_args[@]}" \
    --wait --timeout 10m >/dev/null \
    || die "Helm could not turn on Hubble and the mesh on $c"
  kubectl --context "kind-$c" -n kube-system wait certificate --all --for=condition=Ready --timeout=3m >/dev/null
  # Hubble lives in cilium-config, which the agents read at start.
  kubectl --context "kind-$c" -n kube-system rollout restart ds/cilium >/dev/null
  kubectl --context "kind-$c" -n kube-system rollout status ds/cilium --timeout=5m >/dev/null
  kubectl --context "kind-$c" -n kube-system rollout status deploy/clustermesh-apiserver --timeout=5m >/dev/null
  echo "$c: mesh apiserver at $(cp_ip "$c"):32379, ${#clusters[@]} members declared;" \
    "$(kubectl --context "kind-$c" -n kube-system exec ds/cilium -c cilium-agent -- cilium-agent --version | cut -d' ' -f1-3)"
done
for c in "${clusters[@]}"; do cilium_healthy "$c" "with the mesh"; done
for c in "${clusters[@]}"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 10m; done

# OLM v0 from its release files, as its install.sh does, per context. The chart installs the operator through OLM:
# its preflight and gate need the ClusterServiceVersion.
olm_base="https://github.com/operator-framework/operator-lifecycle-manager/releases/download/$OLM_VERSION"
for c in "${clusters[@]}"; do
  say "$c: OLM $OLM_VERSION"
  if kubectl --context "kind-$c" get deploy olm-operator -n olm >/dev/null 2>&1; then
    echo "installed, kept"
  else
    # Server side: the CRDs are too large for client-side apply's annotation, and a rerun after a partial install
    # updates what exists instead of stopping on AlreadyExists, as `kubectl create` (OLM's install.sh) would.
    kubectl --context "kind-$c" apply --server-side -f "$olm_base/crds.yaml" >/dev/null
    kubectl --context "kind-$c" wait --for=condition=Established --timeout=2m -f "$olm_base/crds.yaml" >/dev/null
    kubectl --context "kind-$c" apply --server-side -f "$olm_base/olm.yaml" >/dev/null
  fi
  kubectl --context "kind-$c" -n olm rollout status deploy/olm-operator --timeout=5m >/dev/null
  kubectl --context "kind-$c" -n olm rollout status deploy/catalog-operator --timeout=5m >/dev/null
  for i in $(seq 1 60); do
    phase=$(kubectl --context "kind-$c" -n olm get csv packageserver -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$phase" = Succeeded ] && break; sleep 5
  done
  [ "$phase" = Succeeded ] || die "OLM's packageserver on $c is ${phase:-absent} after 5 minutes"
  kubectl --context "kind-$c" -n olm get catalogsource operatorhubio-catalog --no-headers \
    -o custom-columns='CATALOG:.metadata.name,IMAGE:.spec.image,STATE:.status.connectionState.lastObservedState'
done

say "the Mac's path to $LB_RANGE"
lb_path
say "platform up: ${clusters[*]}; KUBECONFIG=${KUBECONFIG/$HOME/\~}"
