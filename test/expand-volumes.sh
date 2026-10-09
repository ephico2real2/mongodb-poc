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
NS=vectordb-test
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
        [[ -e "${FAKE}/sts.replicas" && "${name}" == mongot-search-0 ]] || exit 1
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
        i="$(n_of "${name}")"; [[ -e "${FAKE}/pvc.${i}.phase" ]] || exit 1
        case "${path}" in
          '{.status.phase}') f "pvc.${i}.phase" ;;
          '{.spec.resources.requests.storage}') f "pvc.${i}.asks" ;;
          '{.spec.storageClassName}') f "pvc.${i}.class" ;;
          '{.spec.volumeName}') printf 'pv-%s' "$i" ;;
          '{.metadata.ownerReferences[?(@.kind=="StatefulSet")].name}') f "pvc.${i}.owner" ;;
          '{.status.conditions[*].type}') f "pvc.${i}.conds" ;;
          '{.status.capacity.storage}')
            # The volume grows a few looks after it was asked to, unless this cluster's driver waits for the pod.
            if [[ -e "${FAKE}/pvc.${i}.growing" ]]; then
              left="$(f "pvc.${i}.growing")"
              if [[ "$(f behaviour)" == never ]]; then :
              elif (( left > 0 )); then set_f "pvc.${i}.growing" $(( left - 1 ))
              elif [[ "$(f behaviour)" == pending && ! -e "${FAKE}/pod.${i}.restarted" ]]; then set_f "pvc.${i}.conds" FileSystemResizePending
              else set_f "pvc.${i}.has" "$(f "pvc.${i}.asks")"; set_f "pvc.${i}.conds" ""; rm -f "${FAKE}/pvc.${i}.growing"; fi
            fi
            f "pvc.${i}.has" ;;
          *) echo "the stand-in oc does not know: $*" >&2; exit 64 ;;
        esac ;;
      persistentvolume) f reclaim ;;
      pod) i="$(n_of "${name}")"; case "${path}" in *mountPath*) printf /mongot/data ;; *) f "pod.${i}.ready" ;; esac ;;
      pods) for i in 0 1 2; do [[ -e "${FAKE}/pod.${i}.uid" ]] && printf 'mongot-search-0-%s=%s ' "$i" "$(f "pod.${i}.uid")"; done ;;
      persistentvolumeclaims) for i in 0 1 2; do [[ -e "${FAKE}/pvc.${i}.uid" ]] && printf 'data-mongot-search-0-%s=%s ' "$i" "$(f "pvc.${i}.uid")"; done ;;
      *) echo "the stand-in oc does not know: $*" >&2; exit 64 ;;
    esac ;;
  exec) i="$(n_of "$2")"; printf 'Filesystem Size Used Avail Use%% Mounted on\n/dev/sdb %s 190G 110G 64%% /mongot/data\n' "$(f "pvc.${i}.has")" ;;
  patch)
    [[ "$2" == persistentvolumeclaim ]] || { echo "the stand-in oc lets nothing but a claim be patched: $*" >&2; exit 64; }
    i="$(n_of "$3")"; size="$(printf '%s' "$*" | sed -n 's/.*"storage":"\([^"]*\)".*/\1/p')"
    set_f "pvc.${i}.asks" "${size}"; set_f "pvc.${i}.conds" Resizing; set_f "pvc.${i}.growing" 2 ;;
  delete)
    case "$2" in
      pod) i="$(n_of "$3")"; touch "${FAKE}/pod.${i}.restarted"; set_f "pod.${i}.uid" "pod-${i}-again" ;;
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
refuses "belong to --expand" "--size given to --recreate-statefulset" run --recreate-statefulset --statefulset mongot-search-0 --size 300Gi --dry-run
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
[[ $rc == 0 && "$(writes)" == 0 && "$out" == *"oc delete statefulset mongot-search-0 -n ${NS} --cascade=orphan"*"dry run: nothing was changed"* ]] \
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
  && [[ "$out" == *"deleting pod mongot-search-0-0, which keeps its claim"* && "$(cat "${FAKE}/pvc.2.has")" == 300Gi ]] \
  && ok "with --restart-if-pending it deletes that pod, and only pods, and goes on" || bad "--restart-if-pending (exit ${rc}, patched $(patched)): ${out##*$'\n'}"

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
[[ $rc == 0 && "$(writes)" == 1 && "$(grep '^delete ' "${FAKE}/calls")" == "delete statefulset mongot-search-0 -n ${NS} --cascade=orphan" ]] && never_harmful \
  && [[ "$out" == *"was made again at 300Gi; MongoDBSearch mongot is Running"*"the pods are the same pods"*"the volume claims are the same claims"* ]] \
  && ok "--recreate-statefulset deletes the StatefulSet with --cascade=orphan, once, and nothing else" || bad "--recreate-statefulset --apply (exit ${rc}, $(writes) writes): ${out##*$'\n'}"
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

# ------------------------------------------------------------------------------------------------ the script itself
"${SH}" -n "${SCRIPT}" && ok "bash -n" || bad "bash -n"
[[ "$(grep -c 'oc delete statefulset' "${SCRIPT}")" == 2 && "$(grep 'oc delete statefulset' "${SCRIPT}" | grep -c -- '--cascade=orphan')" == 2 ]] \
  && ok "every 'oc delete statefulset' in the script has --cascade=orphan (the command, and the line that prints it)" || bad "a delete of the StatefulSet without --cascade=orphan"
! grep -q -E 'oc (scale|apply|replace|edit)|delete (pvc|persistentvolumeclaim)|"replicas"' "${SCRIPT}" && ok "the script holds no command that scales, or deletes a claim" || bad "the script holds a command it must not"
if command -v shellcheck >/dev/null 2>&1; then shellcheck "${SCRIPT}" && ok "shellcheck" || bad "shellcheck"; fi
out="$(env PATH="${work}/bin:${PATH}" "${SH}" "${SCRIPT}" --help)"; [[ "$out" == *"--recreate-statefulset --statefulset <name>"*"Needs oc"* ]] && ok "--help prints the usage" || bad "--help"

echo
if [[ ${fails} -eq 0 ]]; then echo "all expand-volumes tests passed"; else echo "${fails} failed"; exit 1; fi
