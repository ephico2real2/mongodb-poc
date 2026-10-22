# Sourced by the kind-mesh scripts: the lab's settings, and docker, kind and kubectl pointed at the lab's Colima VM
# and kubeconfig. The active docker context and ~/.kube/config are never changed: kind has no --context flag, so it
# reaches the VM through DOCKER_HOST, and every cluster's context goes to MESH_KUBECONFIG.
# shellcheck shell=bash
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$LAB_DIR/versions.env"
DOCKER_CTX="colima-$COLIMA_PROFILE"

say() { printf '\n== %s  (%s)\n' "$1" "$(date +%H:%M:%S)"; }
die() { echo "kind-mesh: $1" >&2; exit 1; }

# Points docker, kind, kubectl and helm at the lab. Fails when the VM is not running.
lab_env() {
  local host
  host=$(docker context inspect "$DOCKER_CTX" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) \
    || die "no docker context $DOCKER_CTX: start the VM with kind-mesh/scripts/colima-up.sh"
  export DOCKER_HOST="$host" KUBECONFIG="$MESH_KUBECONFIG"
  mkdir -p "$(dirname "$KUBECONFIG")"
}

# helm, three tries: a chart repository's transient refusal is not the lab's failure, and upgrade --install is
# idempotent (cilium-implementation-poc scripts/lab-up.sh, helm_r).
helm_r() {
  local i out
  for i in 1 2 3; do
    if out=$(helm "$@" 2>&1); then printf '%s\n' "$out"; return 0; fi
    case "$out" in
      *"connection reset"*|*"TLS handshake timeout"*|*"i/o timeout"*|*"EOF"*|*"503"*|*"502"*)
        echo "  helm: transient failure, try $((i + 1)) of 3 in 15 s" >&2; sleep 15 ;;
      *) printf '%s\n' "$out" >&2; return 1 ;;
    esac
  done
  printf '%s\n' "$out" >&2; return 1
}
