#!/usr/bin/env bash
# Deletes the three kind clusters and builds the lab again, to the state it is in today, by running the lab's own
# scripts in the order the lab was built (story #193; docs/building-the-kind-mesh-lab.md): this script orchestrates
# and times them, and holds no second copy of what they do. Each phase is logged; the run stops at the first failure,
# naming the phase. Before anything is deleted it checks what a rebuild needs and cannot make: the Colima VM running,
# the tools, and the Cilium images of our build in the VM's docker (versions.env, CILIUM_IMAGES_LOCAL=1).
#
#   kind-mesh/scripts/rebuild.sh                          # prints what a rebuild deletes, keeps and runs; changes nothing
#   kind-mesh/scripts/rebuild.sh --yes                    # deletes the clusters, rebuilds; logs in output/rebuild-<date>/
#   kind-mesh/scripts/rebuild.sh --yes --reclaim-docker   # then the VM's own docker: its build cache and unused images
#   kind-mesh/scripts/rebuild.sh --reclaim-docker         # only that, with the clusters as they are
#
# What is lost and what stays is printed before the deletion (plan). The VM itself is not touched: a stopped one is
# started with kind-mesh/scripts/colima-up.sh first.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
cd "$LAB_DIR/.."   # the repository's root: every command below is written as the READMEs give it
# shellcheck disable=SC2153  # CLUSTERS comes from versions.env
read -r -a clusters <<<"$CLUSTERS"
oc_image="localhost/kind-mesh/oc"   # the chart Jobs' image, built by search-up.sh when missing (kind-mesh/images/oc)

yes=0 reclaim=0
for a in "$@"; do
  case "$a" in
    --yes) yes=1 ;;
    --reclaim-docker) reclaim=1 ;;
    *) echo "usage: $0 [--yes] [--reclaim-docker]" >&2; exit 2 ;;
  esac
done

# The build, as the READMEs' bring-up tables give it (kind-mesh/README.md steps 2 to 9, kind-mesh-cilium/README.md
# steps 1, 4, 6 and 9), then the proofs: "<phase>|<command>", run in this order. The Cilium images of our build go in
# at up.sh (versions.env pins them, lib.sh passes them to Helm), so a fresh lab needs no cilium-build.sh upgrade: that
# script is for a lab that already runs.
phases=(
  "down|down"
  "up|kind-mesh/scripts/up.sh"
  "mongo-up|kind-mesh/scripts/mongo-up.sh"
  "search-up|kind-mesh/scripts/search-up.sh"
  "data-load|kind-mesh/scripts/data-load.sh"
  "gui-up|kind-mesh/scripts/gui-up.sh"
  "observability-up|kind-mesh/scripts/observability-up.sh"
  "swap-search|kind-mesh-cilium/scripts/swap-search.sh"
  "cleartext-l7|kind-mesh-cilium/scripts/cleartext-l7.sh"
  "chart-up|kind-mesh-cilium/scripts/chart-up.sh"
  "mongot-ingress|mongot_ingress"
  "check|kind-mesh/check.sh"
)
plan() {
  cat <<EOF
rebuild.sh deletes the kind clusters ${clusters[*]} and every volume in them:
  - the replica set's data and its search indexes (data-load.sh loads the sample data and makes the indexes again);
    what was written since, lab.drill and lab.probe among it, is gone
  - mongot's indexes (two mongot a cluster, 10Gi volumes each), rebuilt by mongot from the replica set
  - Loki's flows (the storage-loki-0 volume in mesh0) and Grafana's state (no volume: its admin password Secret, and
    anything saved in its UI)
  - the Secrets and users the scripts made (the keyfile, labAdmin, search-sync-source, search-gui, Grafana's admin):
    made again, with new passwords
  - the nodes' recorded addresses, ${MESH_NODE_IPS/$HOME/\~} (colima-up.sh refuses a record that names other nodes)
It keeps:
  - the Colima VM $COLIMA_PROFILE and the kind docker network ($LAB_SUBNET)
  - the images in the VM's docker: kind's node image, the Cilium images $CILIUM_IMAGE and
    ${CILIUM_CLUSTERMESH_IMAGE:-(none)}, the Jobs' $oc_image; with --reclaim-docker, the build cache and the
    unused images go, these never
  - the recorded runs: kind-mesh/output/ and kind-mesh-cilium/output/ are in git. This run's logs go to
    kind-mesh/output/rebuild-<date>/; cleartext-l7.sh rewrites kind-mesh-cilium/output/step2-load-*.txt (git diff shows it)
Then it runs, each phase timed and logged, stopping at the first failure:
EOF
  local p
  for p in "${phases[@]}"; do printf '  %-18s %s\n' "${p%%|*}" "${p#*|}"; done
}

# Docker's disk in the VM (the nodes' volumes and images live on it, colima-up.sh) and the VM docker's own use.
disk() {
  echo "-- the VM's docker file system:"
  colima ssh --profile "$COLIMA_PROFILE" -- df -h /var/lib/docker | sed 's/^/   /'
  echo "-- the VM docker's images, containers and build cache:"
  docker system df | sed 's/^/   /'
}

# The images the lab needs are kept; everything else that no container uses goes, and the whole build cache (the
# next Cilium build starts cold). docker rmi is called without -f: an image a container uses (a kind node's) is
# refused, and kept.
reclaim_docker() {
  local id ref
  say "the VM's docker: the build cache, then the images no container uses"
  docker builder prune --all --force
  while read -r id ref; do
    case "$ref" in
      "$oc_image":*|"$CILIUM_IMAGE"|"${CILIUM_CLUSTERMESH_IMAGE:-}"|"${KIND_NODE_IMAGE%%:*}":*) echo "  kept $ref (the lab needs it)"; continue ;;
      '<none>:<none>') ref=$id ;;
    esac
    # stdin from /dev/null: the loop's own stdin is the image list, which a command must not read.
    if docker rmi "$ref" </dev/null >/dev/null 2>&1; then echo "  removed $ref"; else echo "  kept $ref (in use)"; fi
  done < <(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}')
}

# The nodes' recorded addresses belong to the nodes down.sh deletes: a next colima-up.sh would refuse the new nodes
# against them (its pin_node). Then down.sh itself.
down() {
  if [ -f "$MESH_NODE_IPS" ]; then rm -f "$MESH_NODE_IPS"; echo "removed ${MESH_NODE_IPS/$HOME/\~}"; fi
  kind-mesh/scripts/down.sh
}
# Step 9 of kind-mesh-cilium/README.md: the policy, applied by hand there, in every cluster.
mongot_ingress() {
  local c
  for c in "${clusters[@]}"; do kubectl --context "kind-$c" apply -f kind-mesh-cilium/manifests/60-mongot-ingress.yaml; done
}

n=0
phase() { # <name> <command...>: timed, logged to $out/NN-<name>.log and summarized; a failure stops the run
  local name=$1 t log rc=0
  shift
  n=$((n + 1))
  log=$(printf '%s/%02d-%s.log' "$out" "$n" "$name")
  say "phase $n, $name: $*"
  t=$(date +%s)
  "$@" 2>&1 | tee "$log" || rc=$?
  t=$(($(date +%s) - t))
  if [ "$rc" = 0 ]; then
    printf '%-18s %5s s  ok\n' "$name" "$t" | tee -a "$summary"
  else
    printf '%-18s %5s s  FAILED (exit %s)\n' "$name" "$t" "$rc" | tee -a "$summary"
    die "stopped at phase $n, $name, after $t s (exit $rc): ${log/$HOME/\~}; the phases before it are done, those after it did not run"
  fi
}

say "what a rebuild does"
plan
lab_env
if [ "$yes" != 1 ]; then
  if [ "$reclaim" != 1 ]; then die "nothing deleted: add --yes to delete the clusters and rebuild"; fi
  disk; reclaim_docker; disk
  exit 0
fi

say "before any deletion: the tools, the images, the chart"
# The scripts check their own tools, but only once they run, after the deletion; up.sh's list is checked here first.
for t in docker kind kubectl helm cilium colima python3 openssl curl; do command -v "$t" >/dev/null || die "$t is not installed: nothing deleted"; done
if [ "${CILIUM_IMAGES_LOCAL:-0}" = 1 ]; then
  cilium_images_local
  echo "  the Cilium images are in the VM's docker: $CILIUM_IMAGE${CILIUM_CLUSTERMESH_IMAGE:+, $CILIUM_CLUSTERMESH_IMAGE}"
fi
if [ -n "$(docker images -q "$oc_image")" ]; then
  echo "  $oc_image is in the VM's docker"
else
  echo "  $oc_image is not in the VM's docker: search-up.sh builds it (kind-mesh/images/oc)"
fi
kind-mesh-cilium/chart/test.sh >/dev/null || die "the lab chart's render tests fail (kind-mesh-cilium/chart/test.sh): nothing deleted"
echo "  the lab chart's render tests pass"
disk

out="$LAB_DIR/output/rebuild-$(date +%Y-%m-%d)"
summary="$out/summary.txt"
mkdir -p "$out"
t_all=$(date +%s)
printf '== rebuild %s: phase, seconds, result\n' "$(date -u +%FT%TZ)" >>"$summary"
for p in "${phases[@]}"; do phase "${p%%|*}" "${p#*|}"; done
printf 'total              %5s s\n' "$(($(date +%s) - t_all))" | tee -a "$summary"
disk
if [ "$reclaim" = 1 ]; then reclaim_docker; disk; fi
say "rebuilt: ${clusters[*]}; the phases' logs and summary.txt in ${out/$HOME/\~}"
