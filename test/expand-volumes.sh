#!/usr/bin/env bash
# Tests for chart/mongodb-search-helm/expand-mongot-volumes.sh, no cluster needed:  test/expand-volumes.sh
# A stand-in `oc` keeps a small cluster in files: one StatefulSet of three pods owned by a MongoDBSearch, their
# volume claims and a storage class. It answers what the script asks, changes its files when the script writes, and
# writes down every call, so that each test can say what was read, what was changed, and in which order.
# BASH_UNDER_TEST names the bash that runs the script (macOS ships 3.2).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SCRIPT="${PWD}/chart/mongodb-search-helm/expand-mongot-volumes.sh"
SH="${BASH_UNDER_TEST:-bash}"
NS=search-test
fails=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/expand-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"
echo "testing with $("${SH}" --version | head -1)"

# ------------------------------------------------------------------------------------------------ the stand-in oc
cat > "${work}/bin/oc" <<'EOF'
#!/usr/bin/env bash
# The cluster is the directory $FAKE: one file a fact. A claim is named data-mongot-search-0-<n>, a pod
# mongot-search-0-<n>; their files are pvc.<n>.* and pod.<n>.*.
f() { cat "${FAKE}/$1" 2>/dev/null; }
set_f() { printf '%s' "$2" > "${FAKE}/$1"; }
printf '%s\n' "$*" >> "${FAKE}/calls"
path="" kind="" name=""
for a in "$@"; do case "$a" in jsonpath=*) path="${a#jsonpath=}" ;; esac; done
n_of() { printf '%s' "${1##*-}"; }
case "$1" in
  whoami) [[ "${2:-}" == --show-server ]] && echo "https://api.example.test:6443" || echo "tester"; exit 0 ;;
  get)
    kind="$2"; name="$3"
    case "${kind}" in
      statefulset)
        # As RBAC refuses where a binding's role is gone: a Forbidden that ends in "not found".
        [[ ! -e "${FAKE}/sts.forbidden" ]] || { echo 'Error from server (Forbidden): statefulsets.apps "mongot-search-0" is forbidden: User "system:serviceaccount:x:y" cannot get resource "statefulsets" in API group "apps" in the namespace "x": RBAC: role.rbac.authorization.k8s.io "y" not found' >&2; exit 1; }
        [[ -e "${FAKE}/sts.replicas" && "${name}" == mongot-search-0 ]] || { echo "Error from server (NotFound): statefulsets.apps \"${name}\" not found" >&2; exit 1; }
        case "$*" in *go-template=*) printf 'app=mongot-search-0-svc,'; exit 0 ;; esac
        case "${path}" in
          '{.spec.replicas}') f sts.replicas ;;
          '{.status.readyReplicas}') f sts.ready ;;
          '{.spec.volumeClaimTemplates[*].metadata.name}') f sts.templates ;;
          '{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}') f sts.size ;;
          '{.metadata.ownerReferences[0].kind}') f sts.owner_kind ;;
          '{.metadata.ownerReferences[0].name}') f sts.owner ;;
          '{.metadata.uid}') f sts.uid ;;
          *) echo "the stand-in oc does not know: $*" >&2; exit 64 ;;
        esac ;;
      mongodbsearch.mongodb.com)
        case "${path}" in
          '{.spec.clusters[0].persistence.single.storage}') f mdbs.size ;;
          '{.status.phase}') f mdbs.phase ;;
          '{.status.message}') f mdbs.message ;;
          *) echo "the stand-in oc does not know: $*" >&2; exit 64 ;;
        esac ;;
      storageclass) [[ -e "${FAKE}/class.${name}" ]] || { echo "Error from server (NotFound): storageclasses \"${name}\" not found" >&2; exit 1; }; f "class.${name}" ;;
      persistentvolumeclaim)
        i="$(n_of "${name}")"
        [[ ! -e "${FAKE}/pvc.${i}.forbidden" ]] || { echo "Error from server (Forbidden): persistentvolumeclaims \"${name}\" is forbidden" >&2; exit 1; }
        [[ -e "${FAKE}/pvc.${i}.phase" ]] || { echo "Error from server (NotFound): persistentvolumeclaims \"${name}\" not found" >&2; exit 1; }
        case "${path}" in
          '') printf 'persistentvolumeclaim/%s\n' "${name}" ;;
          '{.status.phase}') f "pvc.${i}.phase" ;;
          '{.spec.resources.requests.storage}') f "pvc.${i}.asks" ;;
          '{.spec.storageClassName}') f "pvc.${i}.class" ;;
          '{.spec.volumeName}') printf 'pv-%s' "$i" ;;
          '{.metadata.ownerReferences[?(@.kind=="StatefulSet")].name}') f "pvc.${i}.owner" ;;
          '{.status.conditions[*].type}')
            # pvc.<n>.clears: the claim stops waiting by itself after that many looks (storage that grows a file
            # system in use, a little late).
            if [[ -e "${FAKE}/pvc.${i}.clears" ]]; then
              left="$(f "pvc.${i}.clears")"
              if (( left > 0 )); then set_f "pvc.${i}.clears" $(( left - 1 )); else set_f "pvc.${i}.conds" ""; set_f "pvc.${i}.has" "$(f "pvc.${i}.asks")"; rm -f "${FAKE}/pvc.${i}.clears" "${FAKE}/pvc.${i}.growing"; fi
            fi
            f "pvc.${i}.conds" ;;
          '{.status.capacity.storage}')
            # The volume grows a few looks after it was asked to, unless this cluster's driver waits for the pod.
            if [[ -e "${FAKE}/pvc.${i}.growing" ]]; then
              left="$(f "pvc.${i}.growing")"
              if [[ "$(f behaviour)" == never ]]; then :
              elif (( left > 0 )); then set_f "pvc.${i}.growing" $(( left - 1 ))
              elif [[ "$(f behaviour)" == pending* && ! -e "${FAKE}/pod.${i}.restarted" ]]; then set_f "pvc.${i}.conds" FileSystemResizePending
              else set_f "pvc.${i}.has" "$(f "pvc.${i}.asks")"; set_f "pvc.${i}.conds" ""; rm -f "${FAKE}/pvc.${i}.growing"; fi
            fi
            f "pvc.${i}.has" ;;
          *) echo "the stand-in oc does not know: $*" >&2; exit 64 ;;
        esac ;;
      persistentvolume) f reclaim ;;
      pod)
        i="$(n_of "${name}")"
        # A deleted pod that is still stopping: the same pod, still Ready, for a few more looks; then the new one.
        if [[ -e "${FAKE}/pod.${i}.stopping" ]]; then
          left="$(f "pod.${i}.stopping")"
          if (( left > 1 )); then set_f "pod.${i}.stopping" $(( left - 1 )); else rm -f "${FAKE}/pod.${i}.stopping"; set_f "pod.${i}.uid" "pod-${i}-again"; fi
        fi
        case "${path}" in *mountPath*) printf /mongot/data ;; '{.metadata.uid}') f "pod.${i}.uid" ;; *) f "pod.${i}.ready" ;; esac ;;
      pods) for i in 0 1 2; do [[ -e "${FAKE}/pod.${i}.uid" ]] && printf 'mongot-search-0-%s=%s ' "$i" "$(f "pod.${i}.uid")"; done ;;
      persistentvolumeclaims) for i in 0 1 2; do [[ -e "${FAKE}/pvc.${i}.uid" ]] && printf 'data-mongot-search-0-%s=%s ' "$i" "$(f "pvc.${i}.uid")"; done ;;
      *) echo "the stand-in oc does not know: $*" >&2; exit 64 ;;
    esac ;;
  exec)
    i="$(n_of "$2")"
    [[ ! -e "${FAKE}/noexec" ]] || { echo 'Error from server (Forbidden): pods "x" is forbidden: cannot create resource "pods/exec"' >&2; exit 1; }
    case "$*" in
      # df -PkT: the type and the size in KiB. fs.<n> holds "<type> <KiB>"; without it, an xfs as large as the claim's
      # capacity less one hundredth (a file system's own tables).
      *-PkT*)
        if [[ -e "${FAKE}/fs.${i}" ]]; then fs="$(f "fs.${i}")"; else fs="xfs $(f "pvc.${i}.has" | awk '{ sub(/Gi$/, ""); printf "%.0f", $1 * 1048576 * 0.99 }')"; fi
        printf 'Filesystem Type 1024-blocks Used Available Capacity Mounted on\n/dev/sdb %s 1000 1000 1%% /mongot/data\n' "${fs}" ;;
      *) printf 'Filesystem Size Used Avail Use%% Mounted on\n/dev/sdb %s 190G 110G 64%% /mongot/data\n' "$(f "pvc.${i}.has")" ;;
    esac ;;
  patch)
    [[ "$2" == persistentvolumeclaim ]] || { echo "the stand-in oc lets nothing but a claim be patched: $*" >&2; exit 64; }
    i="$(n_of "$3")"; size="$(printf '%s' "$*" | sed -n 's/.*"storage":"\([^"]*\)".*/\1/p')"
    set_f "pvc.${i}.asks" "${size}"; set_f "pvc.${i}.conds" Resizing; set_f "pvc.${i}.growing" 2 ;;
  delete)
    case "$2" in
      pod)
        i="$(n_of "$3")"; touch "${FAKE}/pod.${i}.restarted"
        case "$(f behaviour)" in
          # pending-late: the file system grows while the old pod is still stopping, and that pod stays Ready for
          # three more looks before the new one takes its name.
          pending-late) set_f "pod.${i}.stopping" 3 ;;
          # pending-shared: the one restart finishes every claim that waited (the others stop waiting before their turn).
          pending-shared) set_f "pod.${i}.uid" "pod-${i}-again"; for k in 0 1 2; do set_f "pvc.${k}.has" "$(f "pvc.${k}.asks")"; set_f "pvc.${k}.conds" ""; rm -f "${FAKE}/pvc.${k}.growing"; done ;;
          # pending-fails: the node's resize fails when the new pod mounts the volume; the claim keeps waiting, with an Error.
          pending-fails) set_f "pod.${i}.uid" "pod-${i}-again"; set_f "pvc.${i}.conds" "FileSystemResizePending NodeResizeError"; rm -f "${FAKE}/pvc.${i}.growing" ;;
          *) set_f "pod.${i}.uid" "pod-${i}-again" ;;
        esac ;;
      statefulset)
        case "$*" in *--cascade=orphan*) ;; *) touch "${FAKE}/DISASTER"; exit 0 ;; esac
        # The operator makes it again at the size its resource asks for, and is Running again.
        set_f sts.uid sts-again; set_f sts.size "$(f mdbs.size)"; set_f mdbs.phase Running; set_f mdbs.message ""
        [[ "$(f behaviour)" != rolls ]] || for i in 0 1 2; do set_f "pod.${i}.uid" "pod-${i}-rolled"; done ;;
      *) touch "${FAKE}/DISASTER" ;;
    esac ;;
  *) echo "the stand-in oc does not know: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "${work}/bin/oc"

# cluster <asks> <has> <resource's size>: three pods, each claim asking for and having those sizes, on a class that expands.
cluster() {
  export FAKE="${work}/cluster"; rm -rf "${FAKE}"; mkdir "${FAKE}"
  local i
  printf 3 > "${FAKE}/sts.replicas"; printf 3 > "${FAKE}/sts.ready"; printf data > "${FAKE}/sts.templates"; printf '%s' "$1" > "${FAKE}/sts.size"
  printf MongoDBSearch > "${FAKE}/sts.owner_kind"; printf mongot > "${FAKE}/sts.owner"; printf sts-first > "${FAKE}/sts.uid"
  printf '%s' "$3" > "${FAKE}/mdbs.size"; printf Running > "${FAKE}/mdbs.phase"; : > "${FAKE}/mdbs.message"
  printf true > "${FAKE}/class.thin-csi"; printf false > "${FAKE}/class.fixed"; : > "${FAKE}/behaviour"; printf Delete > "${FAKE}/reclaim"
  for i in 0 1 2; do
    printf Bound > "${FAKE}/pvc.${i}.phase"; printf '%s' "$1" > "${FAKE}/pvc.${i}.asks"; printf '%s' "$2" > "${FAKE}/pvc.${i}.has"
    printf thin-csi > "${FAKE}/pvc.${i}.class"; : > "${FAKE}/pvc.${i}.conds"; printf 'claim-%s' "$i" > "${FAKE}/pvc.${i}.uid"
    printf mongot-search-0 > "${FAKE}/pvc.${i}.owner"
    printf True > "${FAKE}/pod.${i}.ready"; printf 'pod-%s' "$i" > "${FAKE}/pod.${i}.uid"
  done
  : > "${FAKE}/calls"
}
# --wait 20 unless the test names its own: a script that waited for what never comes would otherwise hold a test
# for the 15 minutes of its default.
run() {
  local limit="--wait 20" a
  for a in "$@"; do [[ "$a" != --wait ]] || limit=""; done
  # shellcheck disable=SC2086
  env PATH="${work}/bin:${PATH}" TargetNamespace="${NS}" EXPAND_INTERVAL=1 EXPAND_PENDING_GRACE=2 "${SH}" "${SCRIPT}" "$@" ${limit} 2>&1
}
writes() { grep -c -E '^(patch|delete|scale|apply|create|replace|edit|annotate|label) ' "${FAKE}/calls"; }
patched() { grep '^patch ' "${FAKE}/calls" | awk '{print $3}' | sed 's/.*-//' | tr '\n' ' '; }
never_harmful() {  # no call that would change the number of pods, a resource, or delete anything but a pod or, orphaned, the StatefulSet
  [[ ! -e "${FAKE}/DISASTER" ]] && ! grep -q -E '^(scale|apply|create|replace|edit) |^patch (statefulset|mongodbsearch|persistentvolume )|^delete (persistentvolumeclaim|pvc|persistentvolume|mongodbsearch|namespace)|^patch .*replicas' "${FAKE}/calls"
}

# ------------------------------------------------------------------------------------------------ what it refuses
cluster 250Gi 250Gi 300Gi
refuses() {  # <what the message holds> <name of the test> <arguments...>
  local want="$1" name="$2" out rc; shift 2
  out="$("$@" 2>&1)"; rc=$?
  if [[ $rc -ne 0 && "$out" == *"$want"* && "$(writes)" == 0 ]]; then ok "refused: ${name}"; else bad "refused: ${name} (exit ${rc}, $(writes) writes): ${out##*$'\n'}"; fi
}
refuses "no namespace" "no namespace at all" env -u TargetNamespace PATH="${work}/bin:${PATH}" "${SH}" "${SCRIPT}" --check --statefulset mongot-search-0
refuses "disagree" "a flag and a variable that name two namespaces" run --check --statefulset mongot-search-0 --target-namespace other
refuses "not a namespace name" "a namespace that is not a name" env PATH="${work}/bin:${PATH}" TargetNamespace=../x "${SH}" "${SCRIPT}" --check --statefulset mongot-search-0
refuses "--statefulset <name> is required" "no StatefulSet named" run --check
refuses "no StatefulSet nosuch" "a StatefulSet that is not there" run --check --statefulset nosuch
refuses "needs --dry-run or --apply" "--expand with neither --dry-run nor --apply" run --expand --statefulset mongot-search-0
refuses "needs --dry-run or --apply" "--recreate-statefulset with neither" run --recreate-statefulset --statefulset mongot-search-0
refuses "not both" "--dry-run and --apply together" run --expand --statefulset mongot-search-0 --dry-run --apply
refuses "one action a run" "two actions" run --check --expand --statefulset mongot-search-0 --dry-run
refuses "changes nothing" "--check with --apply" run --check --apply --statefulset mongot-search-0
refuses "unknown argument" "an argument it does not know" run --expand --statefulset mongot-search-0 --apply --force
refuses "--size belongs to --expand" "--size given to --recreate-statefulset" run --recreate-statefulset --statefulset mongot-search-0 --size 300Gi --dry-run
refuses "has pods 0 to 2" "a pod the StatefulSet does not have" run --expand --statefulset mongot-search-0 --pod 7 --apply --yes
refuses "not a terminal" "--apply with nobody to type the namespace back" run --expand --statefulset mongot-search-0 --apply
refuses "asks for 300Gi" "a --size that is not the size the values ask for" run --expand --statefulset mongot-search-0 --size 400Gi --apply --yes
refuses "not a size" "a --size that is not a size" run --expand --statefulset mongot-search-0 --size big --apply --yes

cluster 250Gi 250Gi 200Gi
refuses "cannot be made smaller" "a size smaller than the claims have" run --expand --statefulset mongot-search-0 --apply --yes
refuses "less than the StatefulSet's 250Gi" "a StatefulSet asked back to a smaller size" run --recreate-statefulset --statefulset mongot-search-0 --apply --yes

cluster 250Gi 250Gi 300Gi; for i in 0 1 2; do printf fixed > "${FAKE}/pvc.${i}.class"; done
refuses "allowVolumeExpansion is false" "a storage class that cannot grow a volume" run --expand --statefulset mongot-search-0 --apply --yes
cluster 250Gi 250Gi 300Gi; printf gone > "${FAKE}/pvc.0.class"
refuses "allowVolumeExpansion is unreadable" "a storage class that cannot be read" run --expand --statefulset mongot-search-0 --apply --yes
cluster 250Gi 250Gi 300Gi; printf False > "${FAKE}/pod.0.ready"
refuses "is not Ready" "a pod that is not Ready" run --expand --statefulset mongot-search-0 --apply --yes
cluster 250Gi 250Gi 300Gi; printf Pending > "${FAKE}/pvc.0.phase"
refuses "not Bound" "a claim that is not Bound" run --expand --statefulset mongot-search-0 --apply --yes
cluster 250Gi 250Gi 300Gi; printf other-search-0 > "${FAKE}/pvc.1.owner"
refuses "belongs to StatefulSet other-search-0" "a claim with this name that another StatefulSet owns" run --expand --statefulset mongot-search-0 --pod 1 --apply --yes
cluster 250Gi 250Gi 300Gi; printf 'data logs' > "${FAKE}/sts.templates"
refuses "several volume claim templates" "a StatefulSet with two volume claim templates" run --check --statefulset mongot-search-0
cluster 250Gi 250Gi 300Gi; printf Deployment > "${FAKE}/sts.owner_kind"; : > "${FAKE}/mdbs.size"
refuses "give --size" "no size anywhere: not a MongoDBSearch's StatefulSet, and no --size" run --expand --statefulset mongot-search-0 --apply --yes
refuses "not owned by a MongoDBSearch" "making again a StatefulSet nobody would make again" run --recreate-statefulset --statefulset mongot-search-0 --apply --yes

cluster 250Gi 250Gi 300Gi
refuses "grow the claims first" "making the StatefulSet again before its claims have the size" run --recreate-statefulset --statefulset mongot-search-0 --apply --yes
cluster 300Gi 300Gi 300Gi; printf 250Gi > "${FAKE}/sts.size"; printf 2 > "${FAKE}/sts.ready"
refuses "2 of 3 pods" "making the StatefulSet again while a pod is not Ready" run --recreate-statefulset --statefulset mongot-search-0 --apply --yes
cluster 300Gi 300Gi 300Gi; printf 250Gi > "${FAKE}/sts.size"; printf Resizing > "${FAKE}/pvc.1.conds"
refuses "still being resized" "making the StatefulSet again while a claim is being resized" run --recreate-statefulset --statefulset mongot-search-0 --apply --yes

# ------------------------------------------------------------------------------------------------ --check, --dry-run
cluster 250Gi 250Gi 300Gi
out="$(run --check --statefulset mongot-search-0)"; rc=$?
[[ $rc == 0 && "$(writes)" == 0 && "$out" == *"namespace ${NS}"*"3 of 3 pods ready, volume claim template data at 250Gi"*"MongoDBSearch mongot: asks for 300Gi"*"pod 2: claim data-mongot-search-0-2 Bound, asks 250Gi, has 250Gi, class thin-csi (expands: true)"*"volume pv-2, reclaim policy Delete; the pod's file system: 250Gi at /mongot/data, 64% used"* ]] \
  && ok "--check reports the three sizes, the class and the pods, and changes nothing" || bad "--check (exit ${rc}, $(writes) writes)"
out="$(run --expand --statefulset mongot-search-0 --dry-run)"; rc=$?
[[ $rc == 0 && "$(writes)" == 0 && "$out" == *"would ask claim data-mongot-search-0-0 for 300Gi"*"oc patch persistentvolumeclaim data-mongot-search-0-2 -n ${NS} --type=merge"*'"storage":"300Gi"'*"dry run: nothing was changed"* ]] \
  && ok "--expand --dry-run prints the three requests, with the size the MongoDBSearch asks for, and changes nothing" || bad "--expand --dry-run (exit ${rc}, $(writes) writes)"
cluster 300Gi 300Gi 300Gi; printf 250Gi > "${FAKE}/sts.size"
out="$(run --recreate-statefulset --statefulset mongot-search-0 --dry-run)"; rc=$?
[[ $rc == 0 && "$(writes)" == 0 && "$out" == *"oc delete statefulset mongot-search-0 -n ${NS} --cascade=orphan --wait=false"*"dry run: nothing was changed"* ]] \
  && ok "--recreate-statefulset --dry-run prints the one delete, with --cascade=orphan, and changes nothing" || bad "--recreate-statefulset --dry-run (exit ${rc})"

# ------------------------------------------------------------------------------------------------ --expand --apply
cluster 250Gi 250Gi 300Gi
out="$(run --expand --statefulset mongot-search-0 --apply --yes)"; rc=$?
[[ $rc == 0 && "$(patched)" == "0 1 2 " && "$(writes)" == 3 ]] && never_harmful \
  && [[ "$(cat "${FAKE}/pvc.0.has")$(cat "${FAKE}/pvc.1.has")$(cat "${FAKE}/pvc.2.has")" == 300Gi300Gi300Gi && "$out" == *"pod 2: claim data-mongot-search-0-2 has 300Gi, pod mongot-search-0-2 is Ready; the pod's file system: 300Gi at /mongot/data"*"--recreate-statefulset"* ]] \
  && ok "--expand grows the three claims, and writes nothing but three requests" || bad "--expand --apply (exit ${rc}, patched $(patched), $(writes) writes): ${out##*$'\n'}"
# One at a time: the second claim is asked only after the first has its capacity.
first_has="$(grep -n 'data-mongot-search-0-0.*capacity' "${FAKE}/calls" | tail -1 | cut -d: -f1)"; second_asked="$(grep -n '^patch persistentvolumeclaim data-mongot-search-0-1 ' "${FAKE}/calls" | cut -d: -f1)"
[[ -n "${first_has}" && -n "${second_asked}" && "${second_asked}" -gt "${first_has}" ]] && ok "one claim at a time: the next is asked only when the one before has its size" || bad "the order of the requests (${first_has}, ${second_asked})"
# Run again: nothing is asked twice.
: > "${FAKE}/calls"; out="$(run --expand --statefulset mongot-search-0 --apply --yes)"; rc=$?
[[ $rc == 0 && "$(writes)" == 0 && "$out" == *"has 300Gi already: nothing to do"* ]] && ok "run again, it asks for nothing" || bad "--expand a second time (exit ${rc}, $(writes) writes)"

cluster 250Gi 250Gi 300Gi
out="$(run --expand --statefulset mongot-search-0 --pod 1 --apply --yes)"; rc=$?
[[ $rc == 0 && "$(patched)" == "1 " && "$(cat "${FAKE}/pvc.0.has")$(cat "${FAKE}/pvc.2.has")" == 250Gi250Gi ]] && never_harmful && ok "--pod 1 grows that pod's claim and no other" || bad "--pod 1 (exit ${rc}, patched $(patched))"

# Before the sync: the resource still asks for the old size, and --size names the new one.
cluster 250Gi 250Gi 250Gi
out="$(run --expand --statefulset mongot-search-0 --size 300Gi --apply --yes)"; rc=$?
[[ $rc == 0 && "$(patched)" == "0 1 2 " ]] && ok "--size names the size before the values are synced" || bad "--size before the sync (exit ${rc}): ${out##*$'\n'}"
# The same size written another way is the same size.
cluster 250Gi 250Gi 300Gi
out="$(run --expand --statefulset mongot-search-0 --size 322122547200 --dry-run)"; rc=$?
[[ $rc == 0 && "$out" == *"for 322122547200"* ]] && ok "300Gi and 322122547200 are the same size" || bad "a size in bytes (exit ${rc}): ${out##*$'\n'}"

# A claim that was asked already and has not grown yet is waited for, not asked again.
cluster 250Gi 250Gi 300Gi; printf 300Gi > "${FAKE}/pvc.0.asks"; printf Resizing > "${FAKE}/pvc.0.conds"; printf 1 > "${FAKE}/pvc.0.growing"
out="$(run --expand --statefulset mongot-search-0 --pod 0 --apply --yes)"; rc=$?
[[ $rc == 0 && "$(writes)" == 0 && "$out" == *"asks for 300Gi already"*"has 300Gi, pod mongot-search-0-0 is Ready"* ]] && ok "a claim that was asked before is waited for, not asked again" || bad "a claim already asked (exit ${rc}, $(writes) writes)"

# A driver that grows the file system only when the pod starts again.
cluster 250Gi 250Gi 300Gi; printf pending > "${FAKE}/behaviour"
out="$(run --expand --statefulset mongot-search-0 --apply --yes)"; rc=$?
[[ $rc == 3 && "$(patched)" == "0 " && "$(writes)" == 1 && "$out" == *"FileSystemResizePending"*"--restart-if-pending"*"Stopped before the next pod"* ]] && never_harmful \
  && ok "a claim that waits for its pod to restart stops the run, before the next pod, and no pod is deleted" || bad "FileSystemResizePending (exit ${rc}, patched $(patched), $(writes) writes)"
cluster 250Gi 250Gi 300Gi; printf pending > "${FAKE}/behaviour"
out="$(run --expand --statefulset mongot-search-0 --restart-if-pending --apply --yes)"; rc=$?
[[ $rc == 0 && "$(patched)" == "0 1 2 " && "$(grep -c '^delete pod ' "${FAKE}/calls")" == 3 && "$(grep -c '^delete ' "${FAKE}/calls")" == 3 ]] && never_harmful \
  && [[ "$(grep '^delete pod ' "${FAKE}/calls" | tr '\n' '|')" == "delete pod mongot-search-0-0 -n ${NS} --wait=false|delete pod mongot-search-0-1 -n ${NS} --wait=false|delete pod mongot-search-0-2 -n ${NS} --wait=false|" ]] \
  && [[ "$out" == *"deleting pod mongot-search-0-0, which keeps its claim"* && "$(cat "${FAKE}/pvc.2.has")" == 300Gi ]] \
  && ok "with --restart-if-pending it deletes that pod, and only pods, one after the other and without waiting inside oc, and goes on" || bad "--restart-if-pending (exit ${rc}, patched $(patched)): ${out##*$'\n'}"

# The file system grew while the deleted pod was still stopping (a driver that grows it in use, late), and that pod
# still reads Ready: the pod the script waits for must be the new one, or it moves to the next claim with a pod down.
cluster 250Gi 250Gi 300Gi; printf pending-late > "${FAKE}/behaviour"
out="$(run --expand --statefulset mongot-search-0 --pod 0 --restart-if-pending --apply --yes)"; rc=$?
[[ $rc == 0 && "$(grep -c '^delete pod ' "${FAKE}/calls")" == 1 && ! -e "${FAKE}/pod.0.stopping" && "$(cat "${FAKE}/pod.0.uid")" == pod-0-again && "$out" == *"pod mongot-search-0-0 is Ready"* ]] \
  && ok "after it deletes a pod it waits for the new pod to be Ready, not for the old one still stopping" || bad "the old pod taken for Ready (exit ${rc}; looks left before the new pod: $(cat "${FAKE}/pod.0.stopping" 2>/dev/null || echo none)): ${out##*$'\n'}"

# ------------------------------------------------------------------------------------------------ the pods last: --restart-later, --restart-pending
# Every claim first, the StatefulSet made again, and only then the pods whose claims wait for them.
cluster 250Gi 250Gi 300Gi; printf pending > "${FAKE}/behaviour"; printf 250Gi > "${FAKE}/sts.size"; printf Failed > "${FAKE}/mdbs.phase"
out="$(run --expand --statefulset mongot-search-0 --restart-later --apply --yes)"; rc=$?
[[ $rc == 0 && "$(patched)" == "0 1 2 " && "$(grep -c '^delete ' "${FAKE}/calls")" == 0 && "$(grep -o 'Left for --restart-pending' <<<"$out" | wc -l | tr -d ' ')" == 3 \
   && "$(cat "${FAKE}/pvc.0.has")$(cat "${FAKE}/pvc.2.has")" == 250Gi250Gi && "$(cat "${FAKE}/pvc.2.conds")" == FileSystemResizePending ]] && never_harmful \
  && ok "--expand --restart-later asks every claim, leaves each one that waits for its pod, and deletes nothing" || bad "--expand --restart-later (exit ${rc}, patched $(patched), $(grep -c '^delete ' "${FAKE}/calls") deletes): ${out##*$'\n'}"
: > "${FAKE}/calls"; out="$(run --recreate-statefulset --statefulset mongot-search-0 --apply --yes)"; rc=$?
[[ $rc == 1 && "$(writes)" == 0 && "$out" == *"grow the claims first"* ]] \
  && ok "--recreate-statefulset without --restart-later still refuses claims that wait for their pod" || bad "--recreate-statefulset on waiting claims (exit ${rc}, $(writes) writes): ${out##*$'\n'}"
: > "${FAKE}/calls"; out="$(run --recreate-statefulset --statefulset mongot-search-0 --restart-later --apply --yes)"; rc=$?
[[ $rc == 0 && "$(grep '^delete ' "${FAKE}/calls")" == "delete statefulset mongot-search-0 -n ${NS} --cascade=orphan --wait=false" && "$out" == *"was made again at 300Gi"*"done, but for the file systems of pod 0 1 2"*"--restart-pending"* ]] && never_harmful \
  && ok "--recreate-statefulset --restart-later makes the StatefulSet again over claims that wait, and says which pods are left" || bad "--recreate-statefulset --restart-later (exit ${rc}): ${out##*$'\n'}"
: > "${FAKE}/calls"; out="$(run --restart-pending --statefulset mongot-search-0 --dry-run)"; rc=$?
[[ $rc == 0 && "$(writes)" == 0 && "$(grep -c 'oc delete pod mongot-search-0-. -n '"${NS}"' --wait=false' <<<"$out")" == 3 && "$out" == *"dry run: nothing was changed"* ]] \
  && ok "--restart-pending --dry-run prints the three deletes and changes nothing" || bad "--restart-pending --dry-run (exit ${rc}, $(writes) writes)"
# One pod not Ready: no pod is deleted, however many claims wait.
printf False > "${FAKE}/pod.1.ready"; : > "${FAKE}/calls"
out="$(run --restart-pending --statefulset mongot-search-0 --apply --yes)"; rc=$?
[[ $rc == 1 && "$(writes)" == 0 && "$out" == *"pod mongot-search-0-1 is not Ready: a pod is restarted only while every pod is"* ]] \
  && ok "--restart-pending deletes no pod while another is not Ready" || bad "--restart-pending with a pod not Ready (exit ${rc}, $(writes) writes): ${out##*$'\n'}"
printf True > "${FAKE}/pod.1.ready"; : > "${FAKE}/calls"
out="$(run --restart-pending --statefulset mongot-search-0 --apply --yes)"; rc=$?
[[ $rc == 0 && "$(grep '^delete ' "${FAKE}/calls" | tr '\n' '|')" == "delete pod mongot-search-0-0 -n ${NS} --wait=false|delete pod mongot-search-0-1 -n ${NS} --wait=false|delete pod mongot-search-0-2 -n ${NS} --wait=false|" ]] && never_harmful \
  && [[ "$(cat "${FAKE}/pvc.0.has")$(cat "${FAKE}/pvc.1.has")$(cat "${FAKE}/pvc.2.has")" == 300Gi300Gi300Gi && -z "$(cat "${FAKE}/pvc.2.conds")" && "$out" == *"pod 2: claim data-mongot-search-0-2 has 300Gi, pod mongot-search-0-2 is Ready"*"Every claim that waited for its pod has its size"* ]] \
  && ok "--restart-pending deletes the three pods one after the other, each after the one before has its size and is Ready, and nothing else" || bad "--restart-pending --apply (exit ${rc}): $(grep '^delete ' "${FAKE}/calls" | tr '\n' '|') ${out##*$'\n'}"
# In order: the second pod is deleted only after the first claim has been read at its new size.
first_done="$(grep -n 'jsonpath={.status.capacity.storage}' "${FAKE}/calls" | grep 'data-mongot-search-0-0' | tail -1 | cut -d: -f1)"; second_delete="$(grep -n '^delete pod mongot-search-0-1 ' "${FAKE}/calls" | cut -d: -f1)"
[[ -n "${first_done}" && -n "${second_delete}" && "${first_done}" -lt "${second_delete}" ]] && ok "the next pod is deleted only after the one before is back on its claim" || bad "the order of --restart-pending (${first_done:-none}, ${second_delete:-none})"
: > "${FAKE}/calls"; out="$(run --restart-pending --statefulset mongot-search-0 --apply --yes)"; rc=$?
[[ $rc == 0 && "$(writes)" == 0 && "$out" == *"no claim of mongot-search-0 waits for its pod"*"no pod is restarted"* ]] \
  && ok "run again, or where no claim waits, --restart-pending restarts no pod" || bad "--restart-pending a second time (exit ${rc}, $(writes) writes)"
# The old pod still stopping and still Ready when its claim has grown: the new pod is the one waited for.
cluster 300Gi 250Gi 300Gi; printf pending-late > "${FAKE}/behaviour"; printf FileSystemResizePending > "${FAKE}/pvc.0.conds"; printf 0 > "${FAKE}/pvc.0.growing"
out="$(run --restart-pending --statefulset mongot-search-0 --pod 0 --apply --yes)"; rc=$?
[[ $rc == 0 && "$(grep -c '^delete pod ' "${FAKE}/calls")" == 1 && ! -e "${FAKE}/pod.0.stopping" && "$(cat "${FAKE}/pod.0.uid")" == pod-0-again && "$out" == *"pod mongot-search-0-0 is Ready"* ]] \
  && ok "--restart-pending also waits for the new pod, not for the old one still stopping" || bad "--restart-pending and a pod still stopping (exit ${rc}; looks left: $(cat "${FAKE}/pod.0.stopping" 2>/dev/null || echo none)): ${out##*$'\n'}"
# A claim that waits for its pod AND whose resize has failed (two conditions) is not "only FileSystemResizePending":
# the StatefulSet is not made again over it, and --restart-pending deletes no pod on it (the Error is said first).
cluster 300Gi 300Gi 300Gi; printf 250Gi > "${FAKE}/sts.size"; printf 250Gi > "${FAKE}/pvc.0.has"; printf 'FileSystemResizePending NodeResizeError' > "${FAKE}/pvc.0.conds"
refuses "grow the claims first" "--recreate-statefulset --restart-later over a claim with FileSystemResizePending and an Error" run --recreate-statefulset --statefulset mongot-search-0 --restart-later --apply --yes
cluster 300Gi 250Gi 300Gi; printf 'FileSystemResizePending NodeResizeError' > "${FAKE}/pvc.0.conds"
out="$(run --restart-pending --statefulset mongot-search-0 --pod 0 --apply --yes)"; rc=$?
[[ $rc == 2 && "$(writes)" == 0 && "$out" == *"the resize has failed [FileSystemResizePending NodeResizeError]"*"was not deleted"* ]] \
  && ok "--restart-pending deletes no pod whose resize the cluster says has failed, and says so" || bad "--restart-pending on a failed resize (exit ${rc}, $(writes) writes): ${out##*$'\n'}"
# A pod whose uid cannot be read is not deleted: the new pod could not be told from the old one afterwards.
cluster 300Gi 250Gi 300Gi; printf pending > "${FAKE}/behaviour"; printf FileSystemResizePending > "${FAKE}/pvc.0.conds"; printf 0 > "${FAKE}/pvc.0.growing"; rm -f "${FAKE}/pod.0.uid"
out="$(run --restart-pending --statefulset mongot-search-0 --pod 0 --apply --yes)"; rc=$?
[[ $rc == 2 && "$(writes)" == 0 && "$out" == *"cannot be read"*"nothing was deleted"* ]] \
  && ok "--restart-pending deletes no pod whose uid it cannot read" || bad "--restart-pending and an unreadable pod (exit ${rc}, $(writes) writes): ${out##*$'\n'}"
cluster 250Gi 250Gi 300Gi; printf pending > "${FAKE}/behaviour"; rm -f "${FAKE}/pod.0.uid"
out="$(run --expand --statefulset mongot-search-0 --pod 0 --restart-if-pending --apply --yes)"; rc=$?
[[ $rc == 2 && "$(grep -c '^delete ' "${FAKE}/calls")" == 0 && "$out" == *"cannot be read"*"nothing was deleted"* ]] \
  && ok "--expand --restart-if-pending deletes no pod whose uid it cannot read" || bad "--restart-if-pending and an unreadable pod (exit ${rc}): ${out##*$'\n'}"
# A claim that is seen waiting and then finishes by itself within the grace keeps its pod.
# Six looks at the claim come before the delete (the list, the failed-resize test, three in the grace of 2 s at
# 1 s, the last test): it finishes on the sixth. A grace cut short deletes the pod.
cluster 300Gi 250Gi 300Gi; printf FileSystemResizePending > "${FAKE}/pvc.0.conds"; printf 5 > "${FAKE}/pvc.0.clears"
out="$(run --restart-pending --statefulset mongot-search-0 --pod 0 --apply --yes)"; rc=$?
[[ $rc == 0 && "$(writes)" == 0 && "$out" == *"claim data-mongot-search-0-0 no longer waits for its pod: nothing to do"* ]] \
  && ok "--restart-pending watches a waiting claim for the grace first: one that finishes by itself keeps its pod" || bad "a claim that finished within the grace (exit ${rc}, $(writes) writes): ${out##*$'\n'}"
# The claims of the pods still to come stop waiting after the first restart: their pods are left alone.
cluster 250Gi 250Gi 300Gi; printf pending-shared > "${FAKE}/behaviour"
out="$(run --expand --statefulset mongot-search-0 --restart-later --apply --yes)"; rc=$?
: > "${FAKE}/calls"; out="$(run --restart-pending --statefulset mongot-search-0 --apply --yes)"; rc=$?
[[ $rc == 0 && "$(grep -c '^delete pod ' "${FAKE}/calls")" == 1 && "$(grep -o 'no longer waits for its pod: nothing to do' <<<"$out" | wc -l | tr -d ' ')" == 2 ]] \
  && ok "--restart-pending looks at each claim again before its pod goes: a claim that stopped waiting keeps its pod" || bad "a claim that stopped waiting in --restart-pending (exit ${rc}, $(grep -c '^delete pod ' "${FAKE}/calls") deletes): ${out##*$'\n'}"
# The restart makes the resize fail: it stops at once, before the next pod.
cluster 250Gi 250Gi 300Gi; printf pending-fails > "${FAKE}/behaviour"
out="$(run --expand --statefulset mongot-search-0 --restart-later --apply --yes)"; rc=$?
: > "${FAKE}/calls"; started=$SECONDS; out="$(run --restart-pending --statefulset mongot-search-0 --wait 60 --apply --yes)"; rc=$?
[[ $rc == 2 && $((SECONDS - started)) -lt 20 && "$(grep -c '^delete pod ' "${FAKE}/calls")" == 1 && "$out" == *"the resize has failed [FileSystemResizePending NodeResizeError]"*"Stopped before the next pod"* ]] \
  && ok "a resize that fails after the pod is deleted stops --restart-pending at once, before the next pod" || bad "a failed resize in --restart-pending (exit ${rc}, $((SECONDS - started)) s, $(grep -c '^delete pod ' "${FAKE}/calls") deletes): ${out##*$'\n'}"
cluster 250Gi 250Gi 300Gi
refuses "--restart-if-pending or --restart-later, not both" "--restart-if-pending with --restart-later" run --expand --statefulset mongot-search-0 --restart-if-pending --restart-later --dry-run
refuses "--restart-later belongs to --expand and --recreate-statefulset" "--restart-later given to --restart-pending" run --restart-pending --statefulset mongot-search-0 --restart-later --dry-run

# A claim that has the size already and still waits for its file system is not done: the same stop, and no "nothing to do".
cluster 300Gi 300Gi 300Gi; printf FileSystemResizePending > "${FAKE}/pvc.0.conds"
out="$(run --expand --statefulset mongot-search-0 --pod 0 --apply --yes)"; rc=$?
[[ $rc == 3 && "$(writes)" == 0 && "$out" != *"nothing to do"* && "$out" == *"FileSystemResizePending"* ]] \
  && ok "a claim at its size whose file system has not grown yet is waited for, not passed over" || bad "a claim at size with FileSystemResizePending (exit ${rc}, $(writes) writes): ${out##*$'\n'}"

# A resize the cluster reports as failed: it stops at once, and says how such a request is withdrawn.
cluster 250Gi 250Gi 300Gi; printf never > "${FAKE}/behaviour"
sed -i.bak 's|set_f "pvc.${i}.conds" Resizing; set_f "pvc.${i}.growing" 2|set_f "pvc.${i}.conds" "Resizing ControllerResizeError"; set_f "pvc.${i}.growing" 2|' "${work}/bin/oc"
started=$SECONDS; out="$(run --expand --statefulset mongot-search-0 --wait 60 --apply --yes)"; rc=$?
mv "${work}/bin/oc.bak" "${work}/bin/oc"; chmod +x "${work}/bin/oc"
[[ $rc == 2 && $((SECONDS - started)) -lt 20 && "$(patched)" == "0 " && "$out" == *"the resize has failed [Resizing ControllerResizeError]"*"still above 250Gi"* ]] && never_harmful \
  && ok "a resize the cluster says has failed stops the run at once, before the next pod" || bad "a failed resize (exit ${rc}, patched $(patched), $((SECONDS - started)) s)"

# A claim that never grows: it stops there, at its time limit.
cluster 250Gi 250Gi 300Gi; printf never > "${FAKE}/behaviour"
out="$(run --expand --statefulset mongot-search-0 --wait 3 --apply --yes)"; rc=$?
[[ $rc == 2 && "$(patched)" == "0 " && "$out" == *"not at 300Gi within 3 s"*"Stopped before the next pod"* ]] && never_harmful \
  && ok "a claim that does not grow in time stops the run before the next pod" || bad "a claim that never grows (exit ${rc}, patched $(patched))"

# ------------------------------------------------------------------------------------------------ --recreate-statefulset --apply
cluster 300Gi 300Gi 300Gi; printf 250Gi > "${FAKE}/sts.size"; printf Failed > "${FAKE}/mdbs.phase"
out="$(run --recreate-statefulset --statefulset mongot-search-0 --apply --yes)"; rc=$?
[[ $rc == 0 && "$(writes)" == 1 && "$(grep '^delete ' "${FAKE}/calls")" == "delete statefulset mongot-search-0 -n ${NS} --cascade=orphan --wait=false" ]] && never_harmful \
  && [[ "$out" == *"was made again at 300Gi; MongoDBSearch mongot is Running"*"the pods are the same pods"*"the volume claims are the same claims"* ]] \
  && ok "--recreate-statefulset deletes the StatefulSet with --cascade=orphan, once, without waiting inside oc, and nothing else" || bad "--recreate-statefulset --apply (exit ${rc}, $(writes) writes): ${out##*$'\n'}"
: > "${FAKE}/calls"; out="$(run --recreate-statefulset --statefulset mongot-search-0 --apply --yes)"; rc=$?
[[ $rc == 0 && "$(writes)" == 0 && "$out" == *"nothing to do"* ]] && ok "run again, it deletes nothing" || bad "--recreate-statefulset a second time (exit ${rc}, $(writes) writes)"
# An operator whose new StatefulSet differs in more than the size restarts the pods: said, not hidden.
cluster 300Gi 300Gi 300Gi; printf 250Gi > "${FAKE}/sts.size"; printf rolls > "${FAKE}/behaviour"
out="$(run --recreate-statefulset --statefulset mongot-search-0 --apply --yes)"; rc=$?
[[ $rc == 0 && "$out" == *"NOTE: the pods are not the same as before"*"the volume claims are the same claims"* ]] && ok "pods that are restarted after it are reported" || bad "pods restarted after the StatefulSet was made again (exit ${rc})"
# Claims that are not the same afterwards are an error, loudly.
cluster 300Gi 300Gi 300Gi; printf 250Gi > "${FAKE}/sts.size"
sed -i.bak 's|set_f sts.uid sts-again;|set_f sts.uid sts-again; set_f pvc.2.uid claim-2-new;|' "${work}/bin/oc"
out="$(run --recreate-statefulset --statefulset mongot-search-0 --apply --yes)"; rc=$?
mv "${work}/bin/oc.bak" "${work}/bin/oc"; chmod +x "${work}/bin/oc"
[[ $rc == 4 && "$out" == *"WARNING: the volume claims of ${NS} are not the same as before"* ]] && ok "a claim that is not the same afterwards is an error" || bad "a changed claim after the StatefulSet was made again (exit ${rc})"

# ------------------------------------------------------------------------------------------------ --plan
# The sizes compared, and what follows from them. It reads; it changes nothing.
plan() { out="$(run --plan --statefulset mongot-search-0)"; rc=$?; }
cluster 300Gi 300Gi 300Gi; plan
[[ $rc == 0 && "$(writes)" == 0 && "$out" == *"pod 1: claim data-mongot-search-0-1 asks 300Gi, has 300Gi; the pod sees 297.0 GiB (xfs)"*"nothing to do: the StatefulSet and every claim there is have what MongoDBSearch mongot asks for"* ]] \
  && ok "--plan on volumes that have what is asked: nothing to do, exit 0" || bad "--plan with nothing to do (exit ${rc}): ${out##*$'\n'}"
# A larger size in the resource: every claim to grow, then the StatefulSet.
cluster 250Gi 250Gi 300Gi; printf Failed > "${FAKE}/mdbs.phase"; plan
[[ $rc == 10 && "$(writes)" == 0 && "$(grep -c 'to grow to 300Gi: --expand' <<<"$out")" == 3 && "$out" == *"StatefulSet mongot-search-0: has 250Gi, to be made again at 300Gi"*"to do, in this order: grow 3 claim(s); make the StatefulSet again"* ]] \
  && ok "--plan on a larger size: three claims to grow and the StatefulSet to make again, exit 10" || bad "--plan on a larger size (exit ${rc}): ${out##*$'\n'}"
# Part of the way: one claim grown, one under way, one that waits for its pod, one not asked yet... and the StatefulSet.
cluster 300Gi 300Gi 300Gi; printf 250Gi > "${FAKE}/sts.size"
printf 250Gi > "${FAKE}/pvc.1.has"; printf Resizing > "${FAKE}/pvc.1.conds"; printf 250Gi > "${FAKE}/pvc.2.has"; printf FileSystemResizePending > "${FAKE}/pvc.2.conds"; plan
[[ $rc == 10 && "$out" == *"pod 0: claim data-mongot-search-0-0 asks 300Gi, has 300Gi"*"nothing to do"*"pod 1:"*"its resize is under way: --expand waits for it"*"pod 2:"*"its file system grows when its pod starts again: --restart-pending"*"to do, in this order: wait for 1 resize(s); make the StatefulSet again; restart 1 pod(s)"* ]] \
  && ok "--plan part of the way: each claim gets its own answer, and the steps their order" || bad "--plan part of the way (exit ${rc}): ${out##*$'\n'}"
# Only a pod to restart: the StatefulSet has its size already.
cluster 300Gi 300Gi 300Gi; printf 250Gi > "${FAKE}/pvc.0.has"; printf FileSystemResizePending > "${FAKE}/pvc.0.conds"; plan
[[ $rc == 10 && "$out" == *"to do, in this order: restart 1 pod(s)"* && "$out" != *"make the StatefulSet again"* ]] \
  && ok "--plan with the StatefulSet done and one claim waiting for its pod: one pod to restart" || bad "--plan with one waiting claim (exit ${rc}): ${out##*$'\n'}"
# A smaller size is not supported; a failed resize is for a person. Neither is something to do.
cluster 300Gi 300Gi 250Gi; plan; rc1=$rc; o1="$out"
cluster 250Gi 250Gi 300Gi; printf 300Gi > "${FAKE}/pvc.1.asks"; printf 'Resizing ControllerResizeError' > "${FAKE}/pvc.1.conds"; plan
[[ $rc1 == 1 && "$o1" == *"NOT SUPPORTED: MongoDBSearch mongot asks for 250Gi, less than the 300Gi the StatefulSet's volumes were made at"* && $rc == 1 && "$out" == *"the cluster reports its resize as failed: for a person"*"NEEDS A PERSON: 1 of the above"* && "$(writes)" == 0 ]] \
  && ok "--plan ends with 1 on a smaller size (not supported) and on a resize the cluster reports as failed (for a person)" || bad "--plan on what it does not do (exit ${rc1}, ${rc})"
# A first install: no StatefulSet yet is nothing to do; one that cannot be read is refused; a pod not made yet is not assessed.
cluster 300Gi 300Gi 300Gi; rm -f "${FAKE}/sts.replicas"; plan; rc1=$rc; o1="$out"
cluster 300Gi 300Gi 300Gi; touch "${FAKE}/sts.forbidden"; plan; rc2=$rc
cluster 300Gi 300Gi 300Gi; rm -f "${FAKE}/pvc.2.phase"; plan
[[ $rc1 == 0 && "$o1" == *"no StatefulSet mongot-search-0 in ${NS} yet: nothing to assess, and nothing to do"* && $rc2 == 1 && $rc == 0 && "$out" == *"pod 2: no claim data-mongot-search-0-2 yet (its pod has not been made): nothing to assess"* ]] \
  && ok "--plan before there is a StatefulSet, or a pod's claim, finds nothing to do; a StatefulSet it cannot read is refused" || bad "--plan on a first install (exit ${rc1}, ${rc2}, ${rc})"
# The volumes ahead of the values (grown by hand first): said, and nothing to do.
cluster 300Gi 300Gi 250Gi; printf 250Gi > "${FAKE}/sts.size"; plan
[[ $rc == 0 && "$(grep -c 'the values are behind the volume' <<<"$out")" == 3 ]] && ok "--plan with the volumes ahead of the values says so, and has nothing to do" || bad "--plan with the volumes ahead (exit ${rc}): ${out##*$'\n'}"
# A claim that has its size over a file system that has not: what --verify refuses and no step mends. Were it
# "nothing to do", the sync after a failed verification would pass. A shared export says nothing either way.
cluster 300Gi 300Gi 300Gi; printf 'xfs 262144000' > "${FAKE}/fs.1"; plan; rc1=$rc; o1="$out"
out="$(run --verify --statefulset mongot-search-0)"; rc2=$?
cluster 300Gi 300Gi 300Gi; for i in 0 1 2; do printf 'nfs4 10171392' > "${FAKE}/fs.${i}"; done; plan
[[ $rc1 == 1 && $rc2 == 5 && "$o1" == *"pod 1:"*"the claim has its size and the file system its pod sees has not: for a person"*"NEEDS A PERSON: 1 of the above"* && "$o1" != *"nothing to do:"* && $rc == 0 ]] \
  && ok "--plan does not say 'nothing to do' where --verify says NOT VERIFIED: a finished claim over a file system that has not grown is for a person" || bad "--plan and a file system that has not grown (exit ${rc1}, --verify ${rc2}, a shared export ${rc}): ${o1##*$'\n'}"
# A claim whose volume is still being made (a first install, a pod added) needs nobody.
cluster 300Gi 300Gi 300Gi; printf Pending > "${FAKE}/pvc.2.phase"; : > "${FAKE}/pvc.2.has"; plan
[[ $rc == 0 && "$out" == *"pod 2: claim data-mongot-search-0-2 is Pending (its volume is being made): nothing to assess yet"* && "$out" != *"for a person"* ]] \
  && ok "--plan takes a claim that is still Pending for a volume being made, not for a person's work" || bad "--plan and a Pending claim (exit ${rc}): ${out##*$'\n'}"
# A claim that cannot be read is not a claim that is not made yet: the plan stops there, and passes nothing over.
cluster 300Gi 250Gi 300Gi; for i in 0 1 2; do printf FileSystemResizePending > "${FAKE}/pvc.${i}.conds"; done; touch "${FAKE}/pvc.1.forbidden"; plan
[[ $rc == 1 && "$out" == *"claim data-mongot-search-0-1 cannot be read"* && "$out" != *"nothing to do"* && "$out" != *"no claim data-mongot-search-0-1 yet"* ]] \
  && ok "--plan stops at a claim it cannot read, instead of taking it for one that is not made yet" || bad "--plan and a claim that cannot be read (exit ${rc}): ${out##*$'\n'}"
# The values ask for less than a claim already asks for, and something is to be done: --expand, the first of the
# steps, would refuse. The plan says so itself, with 1, and does not send the Job on.
cluster 400Gi 400Gi 300Gi; printf 250Gi > "${FAKE}/sts.size"; printf Failed > "${FAKE}/mdbs.phase"; plan; rc1=$rc; o1="$out"
out="$(run --expand --statefulset mongot-search-0 --apply --yes --restart-later)"; rc2=$?
cluster 300Gi 300Gi 300Gi; printf 400Gi > "${FAKE}/pvc.0.asks"; printf FileSystemResizePending > "${FAKE}/pvc.0.conds"; plan
[[ $rc1 == 1 && $rc2 == 1 && "$o1" == *"NOT SUPPORTED: 3 claim(s) ask for more than the 300Gi of MongoDBSearch mongot"*"make the StatefulSet again"* && "$o1" != *"to do, in this order"* \
   && $rc == 1 && "$out" == *"NOT SUPPORTED: 1 claim(s)"*"restart 1 pod(s)"* ]] \
  && ok "--plan ends with 1, not with 'to do', where a claim asks for more than the values and something is to be done: --expand would refuse" || bad "--plan and claims ahead of the values with something to do (exit ${rc1}, --expand ${rc2}, ${rc}): ${o1##*$'\n'}"
# A claim that asks for less and has as much already (a volume larger than its request): --expand has nothing to do
# for it, and so has the plan. Were it "to grow", every sync would run the steps for nothing.
cluster 250Gi 300Gi 300Gi; printf 300Gi > "${FAKE}/sts.size"; plan
[[ $rc == 0 && "$(grep -c '^         nothing to do$' <<<"$out")" == 3 ]] && ok "--plan has nothing to do for a claim that has the size already, as --expand has" || bad "--plan and a claim that has more than it asks for (exit ${rc}): ${out##*$'\n'}"
# The order of the tests on a claim: a failed resize is for a person even where the claim also asks for less; a claim
# that asks for less is to grow even where it still waits for its pod from an earlier growth; a claim that was asked
# and has not grown is waited for without a condition, and one at its size with a condition left is waited for too.
cluster 250Gi 250Gi 300Gi; printf 'Resizing ControllerResizeError' > "${FAKE}/pvc.0.conds"; plan; rc1=$rc; o1="$out"
cluster 250Gi 250Gi 300Gi; printf 300Gi > "${FAKE}/sts.size"; printf FileSystemResizePending > "${FAKE}/pvc.0.conds"; plan; rc2=$rc; o2="$out"
cluster 300Gi 250Gi 300Gi; plan; rc3=$rc; o3="$out"
cluster 300Gi 300Gi 300Gi; printf Resizing > "${FAKE}/pvc.0.conds"; plan
[[ $rc1 == 1 && "$o1" == *"pod 0:"*"for a person"*"pod 1:"* && $rc2 == 10 && "$o2" == *"to do, in this order: grow 3 claim(s)"* && "$o2" != *"restart"* \
   && $rc3 == 10 && "$o3" == *"to do, in this order: wait for 3 resize(s)"* && $rc == 10 && "$out" == *"to do, in this order: wait for 1 resize(s)"* ]] \
  && ok "--plan's order: a failed resize before 'asks less', 'asks less' before a claim that waits for its pod, a resize under way by its size or by its condition" || bad "--plan's order (exit ${rc1}, ${rc2}, ${rc3}, ${rc})"
# What it cannot read a size from, or has no size for, is refused and not guessed at.
cluster 300Gi 300Gi 300Gi; printf big > "${FAKE}/pvc.1.asks"; plan; rc1=$rc; o1="$out"
cluster 300Gi 300Gi 300Gi; printf Deployment > "${FAKE}/sts.owner_kind"; plan; rc2=$rc; o2="$out"
out="$(run --verify --statefulset mongot-search-0)"; rc=$?
[[ $rc1 == 1 && "$o1" == *"names sizes this script cannot read (asks 'big', has '300Gi'): for a person"* && $rc2 == 1 && "$o2" == *"not owned by a MongoDBSearch: there is no size to plan for"* \
   && $rc == 1 && "$out" == *"not owned by a MongoDBSearch: there is no size to verify against"* ]] \
  && ok "--plan and --verify refuse a claim whose size cannot be read, and a StatefulSet that no MongoDBSearch owns" || bad "--plan and --verify on what they cannot read (exit ${rc1}, ${rc2}, ${rc})"

# ------------------------------------------------------------------------------------------------ --verify
# Has the growth taken effect, down to the file system each pod sees? It reads, and changes nothing.
cluster 300Gi 300Gi 300Gi
out="$(run --verify --statefulset mongot-search-0)"; rc=$?
[[ $rc == 0 && "$(writes)" == 0 && "$out" == *"pod 2: claim data-mongot-search-0-2 has 300Gi; the file system the pod sees has 297.0 GiB (xfs at /mongot/data): it has the claim's size"*"verified: MongoDBSearch mongot is Running at 300Gi"*"file systems compared with their claims: 3"* ]] \
  && ok "--verify passes a growth that has taken effect, and says what it compared" || bad "--verify on a finished growth (exit ${rc}, $(writes) writes): ${out##*$'\n'}"
# The claim has its size and the file system does not: the one thing the claim cannot say.
cluster 300Gi 300Gi 300Gi; printf 'xfs 262144000' > "${FAKE}/fs.1"
out="$(run --verify --statefulset mongot-search-0)"; rc=$?
[[ $rc == 5 && "$(writes)" == 0 && "$out" == *"NOT VERIFIED: pod 1: claim data-mongot-search-0-1 has 300Gi, and the file system the pod sees has 250.0 GiB (xfs at /mongot/data): the file system has not grown"*"--restart-pending"* && "$out" != *"NOT VERIFIED: pod 0"* ]] \
  && ok "--verify fails on a file system that is smaller than its claim, names the pod and what grows it" || bad "--verify and a file system that has not grown (exit ${rc}): ${out##*$'\n'}"
# A shared export has the export's size: said, not counted against the growth, and not counted as compared.
cluster 300Gi 300Gi 300Gi; for i in 0 1 2; do printf 'nfs4 10171392' > "${FAKE}/fs.${i}"; done
out="$(run --verify --statefulset mongot-search-0)"; rc=$?
[[ $rc == 0 && "$out" == *"the pod sees a shared export (nfs4, 9.7 GiB at /mongot/data)"*"file systems compared with their claims: 0; shared exports that cannot show it: 3"* ]] \
  && ok "--verify says a shared export cannot show the growth, and counts it as not compared" || bad "--verify on shared exports (exit ${rc}): ${out##*$'\n'}"
# SMB by its type, and any file system larger than its claim: no volume holds a file system larger than itself, so
# that one is not the volume's own (a directory of a node's disk, a file system shared in another way).
cluster 300Gi 300Gi 300Gi; printf 'cifs 10171392' > "${FAKE}/fs.0"; printf 'smb3 10171392' > "${FAKE}/fs.1"; printf 'xfs 1073741824' > "${FAKE}/fs.2"
out="$(run --verify --statefulset mongot-search-0)"; rc=$?
[[ $rc == 0 && "$out" == *"shared export (cifs,"*"shared export (smb3,"*"pod 2: claim data-mongot-search-0-2 has 300Gi; the pod sees a file system larger than that (xfs, 1024.0 GiB at /mongot/data): not this volume's own"*"file systems compared with their claims: 0; shared exports that cannot show it: 3"* ]] \
  && ok "--verify counts SMB, and a file system larger than its claim, as unable to show the growth and not as compared" || bad "--verify on SMB and on a file system larger than its claim (exit ${rc}): ${out##*$'\n'}"
# The 95%, to the KiB: at it a file system has its claim's size, one KiB under it has not. (300Gi: 298844160 KiB.)
cluster 300Gi 300Gi 300Gi; printf 'ext4 298844160' > "${FAKE}/fs.0"; out="$(run --verify --statefulset mongot-search-0)"; rc1=$?
cluster 300Gi 300Gi 300Gi; printf 'ext4 298844159' > "${FAKE}/fs.0"; out="$(run --verify --statefulset mongot-search-0)"; rc2=$?
[[ $rc1 == 0 && $rc2 == 5 && "$out" == *"NOT VERIFIED: pod 0:"*"the file system has not grown"* ]] && ok "--verify draws its line at 95% of the claim, to the KiB" || bad "--verify at 95% (exit ${rc1}, ${rc2})"
# It is its own claim a file system is held against, not the size the values ask for: claims grown ahead of the values.
cluster 400Gi 400Gi 300Gi; printf 300Gi > "${FAKE}/sts.size"; for i in 0 1 2; do printf 'xfs 311427072' > "${FAKE}/fs.${i}"; done
out="$(run --verify --statefulset mongot-search-0)"; rc=$?
[[ $rc == 5 && "$out" == *"claim data-mongot-search-0-0 has 400Gi, and the file system the pod sees has 297.0 GiB"* ]] \
  && ok "--verify holds a file system against its own claim, not against the size the values ask for" || bad "--verify and claims ahead of the values (exit ${rc}): ${out##*$'\n'}"
# Each of the other things that must hold.
cluster 300Gi 300Gi 300Gi; printf FileSystemResizePending > "${FAKE}/pvc.0.conds"; out="$(run --verify --statefulset mongot-search-0)"; rc1=$?
[[ "$out" == *"NOT VERIFIED: pod 0: claim data-mongot-search-0-0 is not finished [FileSystemResizePending]: its file system grows when its pod starts again: --restart-pending"* ]] || rc1=wrong
cluster 300Gi 250Gi 300Gi; out="$(run --verify --statefulset mongot-search-0)"; rc2=$?; [[ "$out" == *"has 250Gi, less than 300Gi: --expand"* ]] || rc2=wrong
cluster 300Gi 300Gi 300Gi; printf 250Gi > "${FAKE}/sts.size"; printf Failed > "${FAKE}/mdbs.phase"; out="$(run --verify --statefulset mongot-search-0)"; rc3=$?
[[ "$out" == *"NOT VERIFIED: MongoDBSearch mongot is Failed, not Running"*"NOT VERIFIED: StatefulSet mongot-search-0 has 250Gi, and MongoDBSearch mongot asks for 300Gi: --recreate-statefulset"* ]] || rc3=wrong
cluster 300Gi 300Gi 300Gi; printf False > "${FAKE}/pod.2.ready"; out="$(run --verify --statefulset mongot-search-0)"; rc4=$?; [[ "$out" == *"NOT VERIFIED: pod 2: pod mongot-search-0-2 is not Ready"* ]] || rc4=wrong
cluster 300Gi 300Gi 300Gi; touch "${FAKE}/noexec"; out="$(run --verify --statefulset mongot-search-0)"; rc5=$?; [[ "$out" == *"could not be read (oc exec, df)"* && "$(writes)" == 0 ]] || rc5=wrong
[[ "${rc1} ${rc2} ${rc3} ${rc4} ${rc5}" == "5 5 5 5 5" ]] \
  && ok "--verify fails, and says which, on a claim that waits, a claim too small, a StatefulSet or a resource not there yet, a pod not Ready, and a pod it cannot ask" || bad "--verify and what must hold: ${rc1} ${rc2} ${rc3} ${rc4} ${rc5}"
refuses "--verify changes nothing and takes neither --dry-run nor --apply" "--verify with --apply" run --verify --statefulset mongot-search-0 --apply

# ------------------------------------------------------------------------------------------------ the script itself
"${SH}" -n "${SCRIPT}" && ok "bash -n" || bad "bash -n"
[[ "$(grep -c 'oc delete statefulset' "${SCRIPT}")" == 2 && "$(grep 'oc delete statefulset' "${SCRIPT}" | grep -c -- '--cascade=orphan --wait=false')" == 2 ]] \
  && ok "every 'oc delete statefulset' in the script has --cascade=orphan and --wait=false (the command, and the line that prints it)" || bad "a delete of the StatefulSet without --cascade=orphan, or without --wait=false"
! grep -q -E 'oc (scale|apply|replace|edit)|delete (pvc|persistentvolumeclaim)|"replicas"' "${SCRIPT}" && ok "the script holds no command that scales, or deletes a claim" || bad "the script holds a command it must not"
if command -v shellcheck >/dev/null 2>&1; then shellcheck "${SCRIPT}" && ok "shellcheck" || bad "shellcheck"; fi
out="$(env PATH="${work}/bin:${PATH}" "${SH}" "${SCRIPT}" --help)"; [[ "$out" == *"--recreate-statefulset --statefulset <name>"*"Needs oc"* ]] && ok "--help prints the usage" || bad "--help"

echo
if [[ ${fails} -eq 0 ]]; then echo "all expand-volumes tests passed"; else echo "${fails} failed"; exit 1; fi
