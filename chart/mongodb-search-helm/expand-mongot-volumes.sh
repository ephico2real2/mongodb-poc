#!/usr/bin/env bash
# Grows the volumes under mongot's indexes, one pod at a time, and then lets the operator take the new size: the
# steps by hand of volume-expansion-runbook.md, beside this file. Nothing here deletes a volume, a claim or a pod's
# data, and nothing here changes the number of pods.
# It is packaged with the chart. helm stores a chart's files without the executable bit: run it with bash.
#
#   export TargetNamespace=search-qa              # or --target-namespace <ns> on each command; there is no default
#   X=<the chart>/expand-mongot-volumes.sh
#
#   bash $X --check                --statefulset <name>
#   bash $X --plan                 --statefulset <name>
#   bash $X --expand               --statefulset <name> [--size <size>] [--pod <n>]   --dry-run | --apply
#   bash $X --recreate-statefulset --statefulset <name>                               --dry-run | --apply
#   bash $X --restart-pending      --statefulset <name> [--pod <n>]                   --dry-run | --apply
#   bash $X --verify               --statefulset <name>
#
# --check reads and reports: the size the MongoDBSearch asks for, the StatefulSet's, and for each pod its claim's
#   request, capacity, storage class and conditions. It changes nothing.
# --plan reads the same, compares the sizes, and says for each claim and for the StatefulSet what has to be done,
#   if anything: a claim to grow, a resize to wait for, the StatefulSet to make again, a pod to restart. It changes
#   nothing. It ends with 0 when nothing is to be done, with 10 when something is, and with 1 when what is asked
#   is not supported (a smaller size, also one smaller than a claim already asks for while something is to be done)
#   or needs a person (a resize the cluster reports as failed, a claim that cannot be read, a claim that has its
#   size over a file system that has not).
# --expand asks each volume claim of the StatefulSet for the new size, one claim at a time, the lowest pod first,
#   and waits for that claim's capacity and for its pod before the next. --pod <n> does that one pod's claim only.
#   The size is the one the MongoDBSearch asks for (the chart's search.persistence.storage, once synced); --size
#   names it instead, before the sync, and is refused when the two differ.
# --recreate-statefulset deletes the StatefulSet with --cascade=orphan, and only so, once every claim has the size:
#   the operator makes it again at the new size and adopts the pods and the claims, none of which is restarted or
#   deleted.
# --restart-pending deletes, one at a time, each pod whose claim waits for it (FileSystemResizePending, seen for two
#   minutes): the volume has grown, and its file system grows when the pod starts again. The pod keeps its claim
#   and comes back on it; the next is deleted only once that one is Ready. A claim that does not wait is left
#   alone, and so is its pod.
#
# --verify says whether the growth has taken effect, and changes nothing: the MongoDBSearch Running and the
#   StatefulSet at its size, every claim at that size with no resize waiting, every pod Ready, and the file system
#   each pod sees (df, inside the pod) as large as its claim. It ends with 5 when one of these is not so. A shared
#   export (NFS) has the export's size whatever the claim says, and a file system larger than its claim is not that
#   volume's own: said, and not counted against it.
#
# Storage that grows a file system in use needs no pod restarted, and none of the three deletes one. Storage that
# cannot leaves the claim waiting. Then, either of:
#   --expand --restart-if-pending                      the pod is restarted there, before the next claim;
#   --expand --restart-later, --recreate-statefulset --restart-later, then --restart-pending
#                                                      every claim first, the StatefulSet made again, the pods last.
#
# --dry-run prints what --apply would do and changes nothing. --apply asks for the namespace to be typed back;
# --yes skips that. --wait <seconds> is how long one claim may take (900). --restart-if-pending lets --expand
# delete a pod whose claim waits for a restart to grow its file system (FileSystemResizePending): a deleted pod
# keeps its claim and comes back on it.
#
# Needs oc, logged in to the cluster. Under bash 3.2 and later.
set -euo pipefail

ME="$(basename "$0")"
die()  { printf '%s: %s\n' "${ME}" "$*" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------------------------------- arguments
ACTION="" MODE="" NS_FLAG="" STS="" SIZE="" POD="" YES=no WAIT=900 RESTART_IF_PENDING=no RESTART_LATER=no
action() { [[ -z "${ACTION}" || "${ACTION}" == "$1" ]] || die "one action a run: --${ACTION} and --$1 were both given"; ACTION="$1"; }
mode()   { [[ -z "${MODE}" || "${MODE}" == "$1" ]] || die "--dry-run or --apply, not both"; MODE="$1"; }
value()  { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 needs a value"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)                action check ;;
    --plan)                 action plan ;;
    --expand)               action expand ;;
    --recreate-statefulset) action recreate-statefulset ;;
    --restart-pending)      action restart-pending ;;
    --verify)               action verify ;;
    --dry-run)              mode dry-run ;;
    --apply)                mode apply ;;
    --target-namespace)     value "$@"; NS_FLAG="$2"; shift ;;
    --statefulset)          value "$@"; STS="$2"; shift ;;
    --size)                 value "$@"; SIZE="$2"; shift ;;
    --pod)                  value "$@"; POD="$2"; shift ;;
    --wait)                 value "$@"; WAIT="$2"; shift ;;
    --restart-if-pending)   RESTART_IF_PENDING=yes ;;
    --restart-later)        RESTART_LATER=yes ;;
    --yes)                  YES=yes ;;
    -h|--help)              usage; exit 0 ;;
    *)                      die "unknown argument: $1 (--help lists them)" ;;
  esac
  shift
done

[[ -n "${ACTION}" ]] || { usage >&2; exit 1; }
# The namespace is never assumed: not a default, and not the project oc happens to be in.
NS_ENV="${TargetNamespace:-}"
[[ -z "${NS_FLAG}" || -z "${NS_ENV}" || "${NS_FLAG}" == "${NS_ENV}" ]] \
  || die "--target-namespace ${NS_FLAG} and TargetNamespace=${NS_ENV} disagree"
NS="${NS_FLAG:-${NS_ENV}}"
[[ -n "${NS}" ]] || die "no namespace: export TargetNamespace=<ns> or give --target-namespace <ns>"
[[ "${NS}" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "not a namespace name: ${NS}"
[[ -n "${STS}" ]] || die "--statefulset <name> is required: the mongot StatefulSet, <search name>-search-0"
[[ "${STS}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "not a StatefulSet name: ${STS}"
[[ "${WAIT}" =~ ^[0-9]+$ ]] || die "--wait takes seconds: ${WAIT}"
[[ -z "${POD}" || "${POD}" =~ ^[0-9]+$ ]] || die "--pod takes the pod's number: ${POD}"
case "${ACTION}" in
  check|plan|verify) [[ -z "${MODE}" ]] || die "--${ACTION} changes nothing and takes neither --dry-run nor --apply" ;;
  *)     [[ -n "${MODE}" ]] || die "--${ACTION} needs --dry-run or --apply" ;;
esac
[[ "${ACTION}" == expand || -z "${SIZE}" ]] || die "--size belongs to --expand"
[[ "${ACTION}" == expand || "${ACTION}" == restart-pending || -z "${POD}" ]] || die "--pod belongs to --expand and --restart-pending"
[[ "${RESTART_IF_PENDING}" == no || "${RESTART_LATER}" == no ]] || die "--restart-if-pending or --restart-later, not both: a pod is restarted there, or after the StatefulSet is made again"
[[ "${RESTART_IF_PENDING}" == no || "${ACTION}" == expand ]] || die "--restart-if-pending belongs to --expand"
[[ "${RESTART_LATER}" == no || "${ACTION}" == expand || "${ACTION}" == recreate-statefulset ]] || die "--restart-later belongs to --expand and --recreate-statefulset"
INTERVAL="${EXPAND_INTERVAL:-5}"          # seconds between two looks at a claim; the tests shorten it
PENDING_GRACE="${EXPAND_PENDING_GRACE:-120}"   # how long FileSystemResizePending may stand before it counts

# ---------------------------------------------------------------------------------------------------- reading
command -v oc >/dev/null 2>&1 || die "oc is not on the PATH"
oc whoami >/dev/null 2>&1 || die "oc is not logged in to a cluster"

# get <kind> <name> <jsonpath>: the field, or nothing when the object or the field is absent. Never a failure: under
# "set -e" a failed read inside an assignment would end the script before it could say what is missing.
get()   { oc get "$1" "$2" -n "${NS}" -o "jsonpath=$3" 2>/dev/null || true; }
# bytes <quantity>: a Kubernetes size as a whole number of bytes ("300Gi", "1.5Ti", "250G", "1073741824").
bytes() {
  awk -v q="$1" 'BEGIN {
    n = q; u = ""
    if (match(q, /[A-Za-z]+$/)) { u = substr(q, RSTART); n = substr(q, 1, RSTART - 1) }
    if (n !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
    m["Ki"] = 1024; m["Mi"] = 1024^2; m["Gi"] = 1024^3; m["Ti"] = 1024^4; m["Pi"] = 1024^5
    m["k"] = 1000; m["M"] = 1000^2; m["G"] = 1000^3; m["T"] = 1000^4; m["P"] = 1000^5; m[""] = 1
    if (!(u in m)) exit 1
    printf "%.0f\n", n * m[u]
  }'
}
is_size() { bytes "$1" >/dev/null 2>&1; }
# absent <kind> <name>: true only when the API server says there is no such object. One that cannot be read (no
# right to, the API away) is not absent, and RBAC's own refusal can end in "not found" too (a binding whose role is
# gone): only the server's NotFound of that kind counts.
absent() { local e; e="$(oc get "$1" "$2" -n "${NS}" -o name 2>&1)" && return 1; [[ "${e}" == "Error from server (NotFound): $1"* ]]; }

REPLICAS="$(get statefulset "${STS}" '{.spec.replicas}')"
# --plan before there is a StatefulSet (a first install): nothing to assess, and not an error. A StatefulSet that
# cannot be read is refused like everywhere else.
if [[ -z "${REPLICAS}" && "${ACTION}" == plan ]] && absent statefulset "${STS}"; then
  say "no StatefulSet ${STS} in ${NS} yet: nothing to assess, and nothing to do"; exit 0
fi
[[ -n "${REPLICAS}" ]] || die "no StatefulSet ${STS} in ${NS} (or it cannot be read)"
READY="$(get statefulset "${STS}" '{.status.readyReplicas}')"; READY="${READY:-0}"
TEMPLATES="$(get statefulset "${STS}" '{.spec.volumeClaimTemplates[*].metadata.name}')"
[[ -n "${TEMPLATES}" ]] || die "StatefulSet ${STS} has no volume claim template: nothing to grow"
[[ "${TEMPLATES}" != *" "* ]] || die "StatefulSet ${STS} has several volume claim templates (${TEMPLATES}): this script grows one"
TEMPLATE="${TEMPLATES}"
STS_SIZE="$(get statefulset "${STS}" '{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}')"
OWNER_KIND="$(get statefulset "${STS}" '{.metadata.ownerReferences[0].kind}')"
OWNER="$(get statefulset "${STS}" '{.metadata.ownerReferences[0].name}')"
# What the values ask for, once synced: the size in the MongoDBSearch that owns the StatefulSet.
WANTED=""
[[ "${OWNER_KIND}" != MongoDBSearch ]] || WANTED="$(get mongodbsearch.mongodb.com "${OWNER}" '{.spec.clusters[0].persistence.single.storage}')"

claim_of() { say "${TEMPLATE}-${STS}-$1"; }
pod_of()   { say "${STS}-$1"; }
# new_pod <pod> <uid of the pod that was deleted>: there is a pod of that name again, and it is another pod.
new_pod() { local uid; uid="$(get pod "$1" '{.metadata.uid}')"; [[ -n "${uid}" && "${uid}" != "$2" ]]; }
pod_ready() { [[ "$(get pod "$(pod_of "$1")" '{.status.conditions[?(@.type=="Ready")].status}')" == True ]]; }
conditions_of() { get persistentvolumeclaim "$1" '{.status.conditions[*].type}'; }
# reclaim_of <claim>: the volume behind it and its reclaim policy. "Delete" means the disk goes with the claim.
reclaim_of() {
  local pv policy; pv="$(get persistentvolumeclaim "$1" '{.spec.volumeName}')"
  [[ -n "${pv}" ]] || { say "no volume"; return; }
  policy="$(oc get persistentvolume "${pv}" -o 'jsonpath={.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || true)"
  say "${pv}, reclaim policy ${policy:-not readable}"
}
# file_system_of <pod number>: the size of the file system the pod sees under its claim, as df prints it, or nothing.
file_system_of() {
  local pod path; pod="$(pod_of "$1")"
  path="$(get pod "${pod}" "{.spec.containers[0].volumeMounts[?(@.name==\"${TEMPLATE}\")].mountPath}")"
  [[ -n "${path}" ]] || return 0
  oc exec "${pod}" -n "${NS}" -- df -h "${path}" 2>/dev/null | awk 'NR == 2 {print $2 " at " $6 ", " $5 " used"}' || true
}
class_expands() {  # $1 = storage class; prints true, false, or why it cannot be told
  local c; c="$(oc get storageclass "$1" -o 'jsonpath={.allowVolumeExpansion}' 2>&1)" || { say "unreadable: ${c}"; return; }
  say "${c:-false}"
}

# fs_of <pod number>: "<type> <bytes> <mount path>" of the file system the pod sees under its claim, or nothing when
# it cannot be read (no pod, no right to exec, no df).
fs_of() {
  local pod path; pod="$(pod_of "$1")"
  path="$(get pod "${pod}" "{.spec.containers[0].volumeMounts[?(@.name==\"${TEMPLATE}\")].mountPath}")"
  [[ -n "${path}" ]] || return 0
  oc exec "${pod}" -n "${NS}" -- df -PkT "${path}" 2>/dev/null | awk 'NR == 2 && $3 ~ /^[0-9]+$/ { printf "%s %.0f %s\n", $2, $3 * 1024, $7 }' || true
}
gib() { awk -v b="$1" 'BEGIN { printf "%.1f GiB", b / 1073741824 }'; }
# fs_against <type> <bytes> <the claim's capacity>: what the file system a pod sees says of its claim.
#   shared  an export (NFS, SMB): the export's size, whatever the claim says;
#   larger  more than a twentieth over the claim: no volume holds a file system larger than itself, so it is not
#           this volume's own (a directory of a node's disk, a file system shared in another way);
#   short   under 95% of the claim: it has not grown;
#   grown   otherwise. A file system is a little smaller than its volume (its own tables), so 95% counts; a growth
#           of less than a twentieth cannot be told from that by size, and the claim's own status says it then.
# In twentieths (19, 20, 21), not hundredths: bash counts in 64 bits, and the smaller factors keep that exact for
# every size bytes() reads.
fs_against() {
  local claim; claim="$(bytes "$3")"
  case "$1" in nfs*|cifs|smb*) say shared; return ;; esac
  if (( $2 * 20 > claim * 21 )); then say larger
  elif (( $2 * 20 < claim * 19 )); then say short
  else say grown; fi
}

# ---------------------------------------------------------------------------------------------------- --plan
# The sizes, compared: what the MongoDBSearch asks for, what the StatefulSet's volumes were made at, and for each
# claim what it asks for and what it has. From them, what is to be done to each, in the order it is done.
plan() {
  local i claim bound asks have conditions fs type fsbytes path want phase seen short grow=0 await=0 restart=0 remake=0 people=0 ahead=0 todo=""
  [[ "${OWNER_KIND}" == MongoDBSearch ]] || die "StatefulSet ${STS} is not owned by a MongoDBSearch: there is no size to plan for"
  is_size "${WANTED}" || die "MongoDBSearch ${OWNER} names no size this script can read"
  is_size "${STS_SIZE}" || die "StatefulSet ${STS} names no size this script can read"
  want="$(bytes "${WANTED}")"; phase="$(get mongodbsearch.mongodb.com "${OWNER}" '{.status.phase}')"
  say "MongoDBSearch ${OWNER} asks for ${WANTED} and is ${phase:-?}; StatefulSet ${STS} has ${STS_SIZE}, ${READY} of ${REPLICAS} pods ready"
  if (( want < $(bytes "${STS_SIZE}") )); then
    say "NOT SUPPORTED: MongoDBSearch ${OWNER} asks for ${WANTED}, less than the ${STS_SIZE} the StatefulSet's volumes were made at. A volume cannot be made smaller: correct the values. Nothing is to be done to a claim" >&2
    exit 1
  fi
  (( want == $(bytes "${STS_SIZE}") )) || remake=1
  for (( i = 0; i < REPLICAS; i++ )); do
    claim="$(claim_of "$i")"
    bound="$(get persistentvolumeclaim "${claim}" '{.status.phase}')"
    if [[ -z "${bound}" ]]; then
      # Not there, as the API server says: not "could not be read", which would pass a claim over unseen.
      absent persistentvolumeclaim "${claim}" || die "claim ${claim} cannot be read: nothing can be said of it, and nothing is done"
      say "  pod ${i}: no claim ${claim} yet (its pod has not been made): nothing to assess"
      continue
    fi
    # A claim whose volume is still being made (a first install, a pod added) has no size yet, and needs nobody.
    if [[ "${bound}" == Pending ]]; then
      say "  pod ${i}: claim ${claim} is Pending (its volume is being made): nothing to assess yet"
      continue
    fi
    asks="$(get persistentvolumeclaim "${claim}" '{.spec.resources.requests.storage}')"
    have="$(get persistentvolumeclaim "${claim}" '{.status.capacity.storage}')"
    conditions="$(conditions_of "${claim}")"
    if ! is_size "${asks}" || ! is_size "${have}"; then
      say "  pod ${i}: claim ${claim} names sizes this script cannot read (asks '${asks}', has '${have}'): for a person"; people=$(( people + 1 )); continue
    fi
    seen=""; short=no; fs="$(fs_of "$i")"
    if [[ -n "${fs}" ]]; then
      read -r type fsbytes path <<<"${fs}"; seen="; the pod sees $(gib "${fsbytes}") (${type})"
      [[ "$(fs_against "${type}" "${fsbytes}" "${have}")" != short ]] || short=yes
    fi
    say "  pod ${i}: claim ${claim} asks ${asks}, has ${have}${conditions:+, conditions [${conditions}]}${seen}"
    (( $(bytes "${asks}") <= want )) || ahead=$(( ahead + 1 ))
    if [[ "${conditions}" == *Error* ]]; then
      say "         the cluster reports its resize as failed: for a person ('oc describe pvc ${claim} -n ${NS}')"; people=$(( people + 1 ))
    # As --expand has it: a claim that has the size already is not asked again, whatever it asks for.
    elif (( $(bytes "${asks}") < want && $(bytes "${have}") < want )); then
      say "         to grow to ${WANTED}: --expand"; grow=$(( grow + 1 ))
    elif [[ " ${conditions} " == *" FileSystemResizePending "* ]]; then
      say "         its volume has grown; its file system grows when its pod starts again: --restart-pending"; restart=$(( restart + 1 ))
    elif (( $(bytes "${have}") < want )) || [[ -n "${conditions}" ]]; then
      say "         its resize is under way: --expand waits for it"; await=$(( await + 1 ))
    # The one thing the claim cannot say, and --verify would refuse: none of the steps mends it (no claim waits).
    elif [[ "${short}" == yes ]]; then
      say "         the claim has its size and the file system its pod sees has not: for a person (--verify says the same; that pod started again may grow it, and it keeps its claim)"; people=$(( people + 1 ))
    elif (( $(bytes "${asks}") > want )); then
      say "         nothing to do (it asks for more than the values do: the values are behind the volume)"
    else
      say "         nothing to do"
    fi
  done
  (( remake == 0 )) || say "  StatefulSet ${STS}: has ${STS_SIZE}, to be made again at ${WANTED} once the claims have it: --recreate-statefulset"
  if (( people > 0 )); then
    say "NEEDS A PERSON: ${people} of the above. Nothing is done until that is looked at" >&2
    exit 1
  fi
  (( grow == 0 )) || todo="${todo}grow ${grow} claim(s); "
  (( await == 0 )) || todo="${todo}wait for ${await} resize(s); "
  (( remake == 0 )) || todo="${todo}make the StatefulSet again; "
  (( restart == 0 )) || todo="${todo}restart ${restart} pod(s); "
  # --expand, the first of the steps, refuses a size under what a claim asks for: with something to do, that is said
  # here, before anything is changed. With nothing to do the values are only behind the volumes (grown by hand first).
  if [[ -n "${todo}" ]] && (( ahead > 0 )); then
    say "NOT SUPPORTED: ${ahead} claim(s) ask for more than the ${WANTED} of MongoDBSearch ${OWNER}, and there is something to do (${todo%; }): --expand refuses a size under a claim's. Correct the values to what the claims ask for. Nothing is to be done until then" >&2
    exit 1
  fi
  if [[ -z "${todo}" ]]; then
    say "nothing to do: the StatefulSet and every claim there is have what MongoDBSearch ${OWNER} asks for"
    return 0
  fi
  say "to do, in this order: ${todo%; }"
  exit 10
}

# ---------------------------------------------------------------------------------------------------- --verify
# Each file system is judged by fs_against, above: the same test --plan uses.
verify() {
  local i claim have conditions fs type bytes path phase problems=0 compared=0 shared=0
  [[ "${OWNER_KIND}" == MongoDBSearch ]] || die "StatefulSet ${STS} is not owned by a MongoDBSearch: there is no size to verify against"
  is_size "${WANTED}" || die "MongoDBSearch ${OWNER} names no size this script can read"
  not() { say "NOT VERIFIED: $*"; problems=$(( problems + 1 )); }
  phase="$(get mongodbsearch.mongodb.com "${OWNER}" '{.status.phase}')"
  say "MongoDBSearch ${OWNER} asks for ${WANTED} and is ${phase:-?}; StatefulSet ${STS} has ${STS_SIZE:-?}, ${READY} of ${REPLICAS} pods ready"
  [[ "${phase}" == Running ]] || not "MongoDBSearch ${OWNER} is ${phase:-?}, not Running"
  if is_size "${STS_SIZE}" && [[ "$(bytes "${STS_SIZE}")" == "$(bytes "${WANTED}")" ]]; then :; else
    not "StatefulSet ${STS} has ${STS_SIZE:-?}, and MongoDBSearch ${OWNER} asks for ${WANTED}: --recreate-statefulset"
  fi
  for (( i = 0; i < REPLICAS; i++ )); do
    claim="$(claim_of "$i")"
    have="$(get persistentvolumeclaim "${claim}" '{.status.capacity.storage}')"; conditions="$(conditions_of "${claim}")"
    if ! is_size "${have}"; then not "pod ${i}: claim ${claim} has no size that can be read"; continue; fi
    (( $(bytes "${have}") >= $(bytes "${WANTED}") )) || not "pod ${i}: claim ${claim} has ${have}, less than ${WANTED}: --expand"
    [[ -z "${conditions}" ]] || not "pod ${i}: claim ${claim} is not finished [${conditions}]$([[ " ${conditions} " != *" FileSystemResizePending "* ]] || echo ': its file system grows when its pod starts again: --restart-pending')"
    pod_ready "$i" || not "pod ${i}: pod $(pod_of "$i") is not Ready"
    fs="$(fs_of "$i")"
    if [[ -z "${fs}" ]]; then
      not "pod ${i}: the file system pod $(pod_of "$i") sees could not be read (oc exec, df): the claim says ${have}, the pod was not asked"
      continue
    fi
    read -r type bytes path <<<"${fs}"
    case "$(fs_against "${type}" "${bytes}" "${have}")" in
      shared)
        shared=$(( shared + 1 ))
        say "  pod ${i}: claim ${claim} has ${have}; the pod sees a shared export (${type}, $(gib "${bytes}") at ${path}): the export's size, whatever the claim says, so it cannot show the growth" ;;
      larger)
        shared=$(( shared + 1 ))
        say "  pod ${i}: claim ${claim} has ${have}; the pod sees a file system larger than that (${type}, $(gib "${bytes}") at ${path}): not this volume's own, so it cannot show the growth" ;;
      short)
        compared=$(( compared + 1 ))
        not "pod ${i}: claim ${claim} has ${have}, and the file system the pod sees has $(gib "${bytes}") (${type} at ${path}): the file system has not grown. Its pod started again grows it: --restart-pending, or delete that pod (it keeps its claim)" ;;
      *)
        compared=$(( compared + 1 ))
        say "  pod ${i}: claim ${claim} has ${have}; the file system the pod sees has $(gib "${bytes}") (${type} at ${path}): it has the claim's size" ;;
    esac
  done
  if (( problems > 0 )); then
    say "NOT VERIFIED: ${problems} of the above. Nothing was changed" >&2
    exit 5
  fi
  say "verified: MongoDBSearch ${OWNER} is Running at ${WANTED}, the StatefulSet and every claim have it, every pod is Ready; file systems compared with their claims: ${compared}$( (( shared == 0 )) || echo "; shared exports that cannot show it: ${shared}")"
}

# ---------------------------------------------------------------------------------------------------- --check
report() {
  say "namespace ${NS}, on $(oc whoami --show-server 2>/dev/null || echo '?') as $(oc whoami 2>/dev/null)"
  say "StatefulSet ${STS}: ${READY} of ${REPLICAS} pods ready, volume claim template ${TEMPLATE} at ${STS_SIZE:-?}"
  if [[ "${OWNER_KIND}" == MongoDBSearch ]]; then
    say "MongoDBSearch ${OWNER}: asks for ${WANTED:-?}, is $(get mongodbsearch.mongodb.com "${OWNER}" '{.status.phase}')"
  else
    say "owner: ${OWNER_KIND:-none} ${OWNER}: not a MongoDBSearch, so the size must be given with --size"
  fi
  local i claim class
  for (( i = 0; i < REPLICAS; i++ )); do
    claim="$(claim_of "$i")"
    class="$(get persistentvolumeclaim "${claim}" '{.spec.storageClassName}')"
    say "  pod ${i}: claim ${claim} $(get persistentvolumeclaim "${claim}" '{.status.phase}'), asks $(get persistentvolumeclaim "${claim}" '{.spec.resources.requests.storage}'), has $(get persistentvolumeclaim "${claim}" '{.status.capacity.storage}'), class ${class:-?} (expands: $(class_expands "${class}")), conditions [$(conditions_of "${claim}")], pod $(pod_ready "$i" && echo Ready || echo 'NOT Ready')"
    say "         volume $(reclaim_of "${claim}"); the pod's file system: $(file_system_of "$i")"
  done
}

# ---------------------------------------------------------------------------------------------------- --apply
confirm() {  # $1 = what is about to happen
  say "$1"
  say "  cluster $(oc whoami --show-server 2>/dev/null || echo '?'), as $(oc whoami), namespace ${NS}"
  [[ "${YES}" == yes ]] && return 0
  [[ -t 0 ]] || die "not a terminal: give --yes to go on without typing the namespace back"
  local typed; printf 'Type the namespace to go on: '; IFS= read -r typed
  [[ "${typed}" == "${NS}" ]] || die "that is not ${NS}: nothing was changed"
}

# ---------------------------------------------------------------------------------------------------- --expand
target_size() {
  if [[ -n "${SIZE}" ]]; then
    is_size "${SIZE}" || die "not a size: ${SIZE} (for example 300Gi)"
    [[ -z "${WANTED}" || "$(bytes "${SIZE}")" == "$(bytes "${WANTED}")" || "$(bytes "${WANTED}")" == "$(bytes "${STS_SIZE}")" ]] \
      || die "--size ${SIZE}, but MongoDBSearch ${OWNER} asks for ${WANTED}: the values are the source of the size. Leave --size out, or correct the values"
    say "${SIZE}"
  else
    [[ -n "${WANTED}" ]] || die "no size: StatefulSet ${STS} is not owned by a MongoDBSearch that names one; give --size <size>"
    is_size "${WANTED}" || die "MongoDBSearch ${OWNER} asks for ${WANTED}, which is not a size this script can read"
    say "${WANTED}"
  fi
}

expand_one() {  # $1 = pod number, $2 = size
  local i="$1" size="$2" claim pod class want have asks phase expands
  claim="$(claim_of "$i")"; pod="$(pod_of "$i")"; want="$(bytes "${size}")"
  phase="$(get persistentvolumeclaim "${claim}" '{.status.phase}')"
  [[ -n "${phase}" ]] || die "no claim ${claim} in ${NS}: is pod ${i} one of StatefulSet ${STS}'s?"
  [[ "${phase}" == Bound ]] || die "claim ${claim} is ${phase}, not Bound"
  # A claim is chosen by its name; where it names an owner (it does under the operator's retention policy), that
  # owner must be this StatefulSet.
  local owner; owner="$(get persistentvolumeclaim "${claim}" '{.metadata.ownerReferences[?(@.kind=="StatefulSet")].name}')"
  [[ -z "${owner}" || "${owner}" == "${STS}" ]] || die "claim ${claim} belongs to StatefulSet ${owner}, not ${STS}"
  asks="$(get persistentvolumeclaim "${claim}" '{.spec.resources.requests.storage}')"
  have="$(get persistentvolumeclaim "${claim}" '{.status.capacity.storage}')"
  if ! is_size "${asks}" || ! is_size "${have}"; then die "claim ${claim} names sizes this script cannot read (asks '${asks}', has '${have}')"; fi
  # Kubernetes cannot make a volume smaller, and would refuse; said here in plain words first.
  (( $(bytes "${asks}") <= want )) || die "claim ${claim} already asks for ${asks}, more than ${size}: a volume cannot be made smaller"
  if (( $(bytes "${have}") >= want )) && [[ -z "$(conditions_of "${claim}")" ]]; then
    say "pod ${i}: claim ${claim} has ${have} already: nothing to do"
    return 0
  fi
  class="$(get persistentvolumeclaim "${claim}" '{.spec.storageClassName}')"
  expands="$(class_expands "${class}")"
  [[ "${expands}" == true ]] || die "claim ${claim} is of storage class ${class:-?}, whose allowVolumeExpansion is ${expands}: Kubernetes will not grow it. Nothing was changed for this claim"
  pod_ready "$i" || die "pod ${pod} is not Ready: grow a volume only under a healthy pod. Nothing was changed for this claim"

  if [[ "${MODE}" == dry-run ]]; then
    say "pod ${i}: would ask claim ${claim} for ${size} (it asks ${asks}, has ${have}; class ${class} expands):"
    say "    oc patch persistentvolumeclaim ${claim} -n ${NS} --type=merge -p '{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${size}\"}}}}'"
    say "  and would wait up to ${WAIT} s for its capacity, and for pod ${pod} to be Ready"
    return 0
  fi

  if (( $(bytes "${asks}") < want )); then
    say "pod ${i}: asking claim ${claim} for ${size} (it asks ${asks}, has ${have})"
    oc patch persistentvolumeclaim "${claim}" -n "${NS}" --type=merge \
      -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${size}\"}}}}" >/dev/null
  else
    say "pod ${i}: claim ${claim} asks for ${asks} already and has ${have}: waiting for it"
  fi

  local waited=0 pending=0 conditions last="" restarted=no old_pod_uid=""
  while :; do
    have="$(get persistentvolumeclaim "${claim}" '{.status.capacity.storage}')"
    conditions="$(conditions_of "${claim}")"
    [[ "${have} ${conditions}" == "${last}" ]] || say "  ${claim}: has ${have}${conditions:+, conditions [${conditions}]}"
    last="${have} ${conditions}"
    if (( $(bytes "${have}") >= want )) && [[ -z "${conditions}" ]]; then break; fi
    # The cluster says the resize has failed: more waiting does not help.
    if [[ "${conditions}" == *Error* ]]; then
      say "  ${claim}: the resize has failed [${conditions}]. Stopped before the next pod. 'oc describe pvc ${claim} -n ${NS}' says why. A size too large for the datastore can be withdrawn by asking for a smaller one that is still above ${have}; this script does not do that" >&2
      exit 2
    fi
    # The volume has grown and its file system waits for the pod to be started again: a driver without online
    # expansion. A deleted pod keeps its claim (the StatefulSet's policy is about scaling and deletion only).
    if [[ " ${conditions} " == *" FileSystemResizePending "* ]]; then
      pending=$(( pending + INTERVAL ))
      if (( pending >= PENDING_GRACE )) && [[ "${restarted}" == no ]]; then
        # The volume itself has grown: the next claim can be asked. The pod is restarted after the StatefulSet has
        # been made again, by --restart-pending.
        if [[ "${RESTART_LATER}" == yes ]]; then
          say "pod ${i}: claim ${claim} waits for its pod (FileSystemResizePending for ${pending} s): the volume has grown, and its file system grows when pod ${pod} starts again. Left for --restart-pending"
          return 0
        fi
        [[ "${RESTART_IF_PENDING}" == yes ]] || { say "  ${claim}: FileSystemResizePending for ${pending} s. Its file system grows when pod ${pod} starts again: run again with --restart-if-pending, or with --restart-later and then --restart-pending once the StatefulSet is made again, or delete that pod yourself (it keeps its claim). Stopped before the next pod." >&2; exit 3; }
        say "  ${claim}: FileSystemResizePending for ${pending} s: deleting pod ${pod}, which keeps its claim"
        # --wait=false, as for the StatefulSet below: oc would wait for a pod of that name to be gone, and the
        # StatefulSet makes one of the same name. This loop waits instead: for the claim, whose file system grows
        # when the new pod mounts it, and then for that pod to be Ready. The uid tells the new pod from the old
        # one, which can still read Ready while it stops.
        old_pod_uid="$(get pod "${pod}" '{.metadata.uid}')"
        [[ -n "${old_pod_uid}" ]] || { say "  pod ${pod} cannot be read (no uid): nothing was deleted. Stopped before the next pod" >&2; exit 2; }
        oc delete pod "${pod}" -n "${NS}" --wait=false >/dev/null
        restarted=yes
      fi
    fi
    (( waited < WAIT )) || { say "  ${claim}: not at ${size} within ${WAIT} s (has ${have}, conditions [${conditions}]). Stopped before the next pod; the request stands, and running this again goes on waiting. See 'oc describe pvc ${claim} -n ${NS}'" >&2; exit 2; }
    sleep "${INTERVAL}"; waited=$(( waited + INTERVAL ))
  done
  waited=0
  # After a delete, the pod that is Ready must be the new one, not the old one on its way out.
  until pod_ready "$i" && { [[ "${restarted}" == no ]] || new_pod "${pod}" "${old_pod_uid}"; }; do
    (( waited < WAIT )) || { say "  pod ${pod} is not Ready within ${WAIT} s of its claim growing. Stopped before the next pod" >&2; exit 2; }
    sleep "${INTERVAL}"; waited=$(( waited + INTERVAL ))
  done
  local fs; fs="$(file_system_of "$i")"
  [[ -z "${fs}" ]] || fs="; the pod's file system: ${fs}"
  say "pod ${i}: claim ${claim} has ${have}, pod ${pod} is Ready${fs}"
}

expand() {
  local size i first=0 last=$(( REPLICAS - 1 ))
  size="$(target_size)"
  [[ "${REPLICAS}" -gt 0 ]] || die "StatefulSet ${STS} has no pods: nothing to grow"
  if [[ -n "${POD}" ]]; then
    (( POD <= last )) || die "--pod ${POD}: StatefulSet ${STS} has pods 0 to ${last}"
    first="${POD}"; last="${POD}"
  fi
  [[ "${MODE}" == dry-run ]] || confirm "About to grow the volume claims of StatefulSet ${STS}, pod ${first} to ${last}, to ${size}, one at a time."
  for (( i = first; i <= last; i++ )); do expand_one "$i" "${size}"; done
  [[ "${MODE}" == dry-run ]] && { say "dry run: nothing was changed"; return 0; }
  if [[ "${RESTART_LATER}" == yes ]]; then
    say "done. When the values ask for ${size}: --recreate-statefulset --restart-later, then --restart-pending for the claims that wait for their pod"
  else
    say "done. When every claim of ${STS} has ${size} and the values ask for it: --recreate-statefulset"
  fi
}

# ---------------------------------------------------------------------------------------------------- --recreate-statefulset
uids() {  # $1 = kind, $2 = a label selector or nothing: "name=uid name=uid ..."
  if [[ -n "${2:-}" ]]; then oc get "$1" -n "${NS}" -l "$2" -o 'jsonpath={range .items[*]}{.metadata.name}={.metadata.uid} {end}' 2>/dev/null
  else oc get "$1" -n "${NS}" -o 'jsonpath={range .items[*]}{.metadata.name}={.metadata.uid} {end}' 2>/dev/null; fi
}
recreate() {
  [[ "${OWNER_KIND}" == MongoDBSearch ]] || die "StatefulSet ${STS} is not owned by a MongoDBSearch: nothing would make it again. Refused"
  if [[ -z "${WANTED}" ]] || ! is_size "${WANTED}"; then die "MongoDBSearch ${OWNER} names no size this script can read"; fi
  is_size "${STS_SIZE}" || die "StatefulSet ${STS} names no size this script can read"
  if [[ "$(bytes "${WANTED}")" == "$(bytes "${STS_SIZE}")" ]]; then
    say "StatefulSet ${STS} has ${STS_SIZE}, which is what MongoDBSearch ${OWNER} asks for: nothing to do"
    return 0
  fi
  (( $(bytes "${WANTED}") > $(bytes "${STS_SIZE}") )) || die "MongoDBSearch ${OWNER} asks for ${WANTED}, less than the StatefulSet's ${STS_SIZE}: a volume cannot be made smaller. Correct the values"
  [[ "${READY}" == "${REPLICAS}" ]] || die "${READY} of ${REPLICAS} pods of ${STS} are Ready: make it again only when every pod is"
  local i claim have asks selector waiting=""
  for (( i = 0; i < REPLICAS; i++ )); do
    claim="$(claim_of "$i")"; have="$(get persistentvolumeclaim "${claim}" '{.status.capacity.storage}')"
    [[ -n "${have}" ]] || die "no claim ${claim} in ${NS}"
    # A claim that waits for its pod, and for nothing else: its volume has grown to what it asks for, and its
    # capacity follows when the pod starts again. With --restart-later that is enough here.
    if [[ "${RESTART_LATER}" == yes && "$(conditions_of "${claim}")" == FileSystemResizePending ]]; then
      asks="$(get persistentvolumeclaim "${claim}" '{.spec.resources.requests.storage}')"
      is_size "${asks}" || die "claim ${claim} asks for a size this script cannot read ('${asks}')"
      (( $(bytes "${asks}") >= $(bytes "${WANTED}") )) || die "claim ${claim} asks for ${asks}, less than ${WANTED}: grow the claims first (--expand)"
      waiting="${waiting} ${i}"
      continue
    fi
    (( $(bytes "${have}") >= $(bytes "${WANTED}") )) || die "claim ${claim} has ${have}, less than ${WANTED}: grow the claims first (--expand)"
    [[ -z "$(conditions_of "${claim}")" ]] || die "claim ${claim} is still being resized [$(conditions_of "${claim}")]: wait for it, or with only FileSystemResizePending: --restart-later here and --restart-pending after"
  done

  if [[ "${MODE}" == dry-run ]]; then
    say "would delete StatefulSet ${STS} and leave its pods and claims (the operator makes it again at ${WANTED}):"
    say "    oc delete statefulset ${STS} -n ${NS} --cascade=orphan --wait=false"
    say "dry run: nothing was changed"
    return 0
  fi
  confirm "About to delete StatefulSet ${STS} with --cascade=orphan. Its ${REPLICAS} pods and their claims stay; the operator makes the StatefulSet again at ${WANTED}."
  # The $k and $v are the template's, not the shell's: single quotes are what keeps them so.
  # shellcheck disable=SC2016
  selector="$(oc get statefulset "${STS}" -n "${NS}" -o 'go-template={{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null)"
  selector="${selector%,}"
  [[ -n "${selector}" ]] || die "StatefulSet ${STS} has no pod selector that can be read"
  local pods_before claims_before old_uid new_uid waited=0
  pods_before="$(uids pods "${selector}")"; claims_before="$(uids persistentvolumeclaims)"
  old_uid="$(get statefulset "${STS}" '{.metadata.uid}')"
  # The one delete of this script. Without --cascade=orphan it would take every pod and, by the operator's policy
  # for this StatefulSet, every volume claim with it.
  # --wait=false: oc would otherwise wait for the object to be gone by watching its name, and the operator makes a
  # StatefulSet of the same name again within a second. A watch that starts after that (or is not allowed, as for
  # a service account without list and watch) waits for a delete that has already happened, for up to a week. The
  # loop below waits instead, for the new StatefulSet, and no longer than --wait.
  oc delete statefulset "${STS}" -n "${NS}" --cascade=orphan --wait=false >/dev/null
  until new_uid="$(get statefulset "${STS}" '{.metadata.uid}')"; [[ -n "${new_uid}" && "${new_uid}" != "${old_uid}" ]]; do
    (( waited < WAIT )) || { say "the operator has not made StatefulSet ${STS} again within ${WAIT} s. The pods run on without it and nothing is lost: see the operator's log, and do NOT delete the pods" >&2; exit 2; }
    sleep "${INTERVAL}"; waited=$(( waited + INTERVAL ))
  done
  until [[ "$(get mongodbsearch.mongodb.com "${OWNER}" '{.status.phase}')" == Running ]]; do
    (( waited < WAIT )) || { say "MongoDBSearch ${OWNER} is $(get mongodbsearch.mongodb.com "${OWNER}" '{.status.phase}') ${WAIT} s after the StatefulSet was made again: $(get mongodbsearch.mongodb.com "${OWNER}" '{.status.message}')" >&2; exit 2; }
    sleep "${INTERVAL}"; waited=$(( waited + INTERVAL ))
  done
  say "StatefulSet ${STS} was made again at $(get statefulset "${STS}" '{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}'); MongoDBSearch ${OWNER} is Running"
  if [[ "$(uids pods "${selector}")" == "${pods_before}" ]]; then
    say "the pods are the same pods: none was restarted"
  else
    say "NOTE: the pods are not the same as before: the operator's StatefulSet differs from the old one in more than the size, and its pods are being restarted one at a time, each on its claim"
  fi
  if [[ "$(uids persistentvolumeclaims)" == "${claims_before}" ]]; then
    say "the volume claims are the same claims"
  else
    say "WARNING: the volume claims of ${NS} are not the same as before. Compare: oc get pvc -n ${NS}" >&2; exit 4
  fi
  if [[ -n "${waiting}" ]]; then
    say "done, but for the file systems of pod${waiting}: their claims wait for their pods. Next: --restart-pending"
  else
    say "done. Sync or upgrade the chart again: its gate passes now"
  fi
}

# ---------------------------------------------------------------------------------------------------- --restart-pending
pending_now() { [[ " $(conditions_of "$1") " == *" FileSystemResizePending "* ]]; }
restart_pending() {
  local i j first=0 last=$(( REPLICAS - 1 )) claim pod asks have conditions owner waited list="" fs old_pod_uid
  [[ "${REPLICAS}" -gt 0 ]] || die "StatefulSet ${STS} has no pods: nothing to restart"
  if [[ -n "${POD}" ]]; then
    (( POD <= last )) || die "--pod ${POD}: StatefulSet ${STS} has pods 0 to ${last}"
    first="${POD}"; last="${POD}"
  fi
  for (( i = first; i <= last; i++ )); do
    claim="$(claim_of "$i")"
    [[ -n "$(get persistentvolumeclaim "${claim}" '{.status.phase}')" ]] || die "no claim ${claim} in ${NS}: is pod ${i} one of StatefulSet ${STS}'s?"
    owner="$(get persistentvolumeclaim "${claim}" '{.metadata.ownerReferences[?(@.kind=="StatefulSet")].name}')"
    [[ -z "${owner}" || "${owner}" == "${STS}" ]] || die "claim ${claim} belongs to StatefulSet ${owner}, not ${STS}"
    if pending_now "${claim}"; then list="${list} ${i}"; fi
  done
  if [[ -z "${list}" ]]; then
    say "no claim of ${STS} waits for its pod (FileSystemResizePending): no pod is restarted"
    return 0
  fi
  if [[ "${MODE}" == dry-run ]]; then
    for i in ${list}; do
      say "pod ${i}: would delete pod $(pod_of "$i"), whose claim $(claim_of "$i") waits for it, and wait for it to be Ready on that claim:"
      say "    oc delete pod $(pod_of "$i") -n ${NS} --wait=false"
    done
    say "dry run: nothing was changed"
    return 0
  fi
  confirm "About to delete, one at a time, the pods of StatefulSet ${STS} whose claims wait for them: pod${list}. Each keeps its claim and comes back on it."
  for i in ${list}; do
    claim="$(claim_of "$i")"; pod="$(pod_of "$i")"
    # A resize the cluster already reports as failed: said at once, before any waiting.
    conditions="$(conditions_of "${claim}")"
    if [[ "${conditions}" == *Error* ]]; then
      say "  ${claim}: the resize has failed [${conditions}]. Pod ${pod} was not deleted. 'oc describe pvc ${claim} -n ${NS}' says why" >&2; exit 2
    fi
    # Storage that grows a file system in use shows the claim waiting for a moment and then finishes by itself:
    # only a claim that is seen waiting for the whole grace has its pod deleted.
    waited=0
    while pending_now "${claim}" && (( waited < PENDING_GRACE )); do sleep "${INTERVAL}"; waited=$(( waited + INTERVAL )); done
    if ! pending_now "${claim}"; then say "pod ${i}: claim ${claim} no longer waits for its pod: nothing to do"; continue; fi
    # One pod away at a time: every pod of the StatefulSet is Ready before this one is deleted.
    for (( j = 0; j < REPLICAS; j++ )); do
      pod_ready "$j" || die "pod $(pod_of "$j") is not Ready: a pod is restarted only while every pod is. Pod ${pod} was not deleted; run this again when they are"
    done
    asks="$(get persistentvolumeclaim "${claim}" '{.spec.resources.requests.storage}')"
    is_size "${asks}" || die "claim ${claim} asks for a size this script cannot read ('${asks}')"
    # The cluster says the resize has failed (NodeResizeError beside FileSystemResizePending): a restart would not
    # help, and the Error is said first, as in --expand.
    conditions="$(conditions_of "${claim}")"
    if [[ "${conditions}" == *Error* ]]; then
      say "  ${claim}: the resize has failed [${conditions}]. Pod ${pod} was not deleted. 'oc describe pvc ${claim} -n ${NS}' says why" >&2; exit 2
    fi
    # --wait=false: as in --expand, this loop waits, for the claim and then for the new pod, told from the old one
    # by its uid. Without the uid the two could not be told apart: then nothing is deleted.
    old_pod_uid="$(get pod "${pod}" '{.metadata.uid}')"
    [[ -n "${old_pod_uid}" ]] || { say "  pod ${pod} cannot be read (no uid): nothing was deleted. Stopped before the next pod" >&2; exit 2; }
    say "pod ${i}: deleting pod ${pod}, which keeps its claim ${claim}"
    oc delete pod "${pod}" -n "${NS}" --wait=false >/dev/null
    waited=0
    while :; do
      have="$(get persistentvolumeclaim "${claim}" '{.status.capacity.storage}')"; conditions="$(conditions_of "${claim}")"
      if is_size "${have}" && (( $(bytes "${have}") >= $(bytes "${asks}") )) && [[ -z "${conditions}" ]]; then break; fi
      if [[ "${conditions}" == *Error* ]]; then
        say "  ${claim}: the resize has failed [${conditions}]. Stopped before the next pod. 'oc describe pvc ${claim} -n ${NS}' says why" >&2; exit 2
      fi
      (( waited < WAIT )) || { say "  ${claim}: not at ${asks} within ${WAIT} s of its pod being deleted (has ${have}, conditions [${conditions}]). Stopped before the next pod. See 'oc describe pod ${pod} -n ${NS}' and 'oc describe pvc ${claim} -n ${NS}'" >&2; exit 2; }
      sleep "${INTERVAL}"; waited=$(( waited + INTERVAL ))
    done
    waited=0
    until pod_ready "$i" && new_pod "${pod}" "${old_pod_uid}"; do
      (( waited < WAIT )) || { say "  pod ${pod} is not Ready within ${WAIT} s of its claim growing. Stopped before the next pod" >&2; exit 2; }
      sleep "${INTERVAL}"; waited=$(( waited + INTERVAL ))
    done
    fs="$(file_system_of "$i")"; [[ -z "${fs}" ]] || fs="; the pod's file system: ${fs}"
    say "pod ${i}: claim ${claim} has ${have}, pod ${pod} is Ready${fs}"
  done
  say "done. Every claim that waited for its pod has its size"
}

case "${ACTION}" in
  check)                report ;;
  expand)               expand ;;
  recreate-statefulset) recreate ;;
  restart-pending)      restart_pending ;;
  plan)                 plan ;;
  verify)               verify ;;
esac
