#!/usr/bin/env bash
# Grows the volumes under mongot's indexes, one pod at a time, and then lets the operator take the new size: the
# steps by hand of volume-expansion-runbook.md, beside this file. Nothing here deletes a volume, a claim or a pod's
# data, and nothing here changes the number of pods.
# It is packaged with the chart. helm stores a chart's files without the executable bit: run it with bash.
#
#   export TargetNamespace=dvh-vectordb-qa        # or --target-namespace <ns> on each command; there is no default
#   X=<the chart>/expand-mongot-volumes.sh
#
#   bash $X --check                --statefulset <name>
#   bash $X --expand               --statefulset <name> [--size <size>] [--pod <n>]   --dry-run | --apply
#   bash $X --recreate-statefulset --statefulset <name>                               --dry-run | --apply
#
# --check reads and reports: the size the MongoDBSearch asks for, the StatefulSet's, and for each pod its claim's
#   request, capacity, storage class and conditions. It changes nothing.
# --expand asks each volume claim of the StatefulSet for the new size, one claim at a time, the lowest pod first,
#   and waits for that claim's capacity and for its pod before the next. --pod <n> does that one pod's claim only.
#   The size is the one the MongoDBSearch asks for (the chart's search.persistence.storage, once synced); --size
#   names it instead, before the sync, and is refused when the two differ.
# --recreate-statefulset deletes the StatefulSet with --cascade=orphan, and only so, once every claim has the size:
#   the operator makes it again at the new size and adopts the pods and the claims, none of which is restarted or
#   deleted.
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
ACTION="" MODE="" NS_FLAG="" STS="" SIZE="" POD="" YES=no WAIT=900 RESTART_IF_PENDING=no
action() { [[ -z "${ACTION}" || "${ACTION}" == "$1" ]] || die "one action a run: --${ACTION} and --$1 were both given"; ACTION="$1"; }
mode()   { [[ -z "${MODE}" || "${MODE}" == "$1" ]] || die "--dry-run or --apply, not both"; MODE="$1"; }
value()  { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 needs a value"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)                action check ;;
    --expand)               action expand ;;
    --recreate-statefulset) action recreate-statefulset ;;
    --dry-run)              mode dry-run ;;
    --apply)                mode apply ;;
    --target-namespace)     value "$@"; NS_FLAG="$2"; shift ;;
    --statefulset)          value "$@"; STS="$2"; shift ;;
    --size)                 value "$@"; SIZE="$2"; shift ;;
    --pod)                  value "$@"; POD="$2"; shift ;;
    --wait)                 value "$@"; WAIT="$2"; shift ;;
    --restart-if-pending)   RESTART_IF_PENDING=yes ;;
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
  check) [[ -z "${MODE}" ]] || die "--check changes nothing and takes neither --dry-run nor --apply" ;;
  *)     [[ -n "${MODE}" ]] || die "--${ACTION} needs --dry-run or --apply" ;;
esac
[[ "${ACTION}" == expand || ( -z "${SIZE}" && -z "${POD}" ) ]] || die "--size and --pod belong to --expand"
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

REPLICAS="$(get statefulset "${STS}" '{.spec.replicas}')"
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

  local waited=0 pending=0 conditions last="" restarted=no
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
        [[ "${RESTART_IF_PENDING}" == yes ]] || { say "  ${claim}: FileSystemResizePending for ${pending} s. Its file system grows when pod ${pod} starts again: run again with --restart-if-pending, or delete that pod yourself (it keeps its claim). Stopped before the next pod." >&2; exit 3; }
        say "  ${claim}: FileSystemResizePending for ${pending} s: deleting pod ${pod}, which keeps its claim"
        # --wait=false, as for the StatefulSet below: oc would wait for a pod of that name to be gone, and the
        # StatefulSet makes one of the same name. This loop waits instead: for the claim, whose file system grows
        # when the new pod mounts it, and then for that pod to be Ready.
        oc delete pod "${pod}" -n "${NS}" --wait=false >/dev/null
        restarted=yes
      fi
    fi
    (( waited < WAIT )) || { say "  ${claim}: not at ${size} within ${WAIT} s (has ${have}, conditions [${conditions}]). Stopped before the next pod; the request stands, and running this again goes on waiting. See 'oc describe pvc ${claim} -n ${NS}'" >&2; exit 2; }
    sleep "${INTERVAL}"; waited=$(( waited + INTERVAL ))
  done
  waited=0
  until pod_ready "$i"; do
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
  say "done. When every claim of ${STS} has ${size} and the values ask for it: --recreate-statefulset"
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
  local i claim have selector
  for (( i = 0; i < REPLICAS; i++ )); do
    claim="$(claim_of "$i")"; have="$(get persistentvolumeclaim "${claim}" '{.status.capacity.storage}')"
    [[ -n "${have}" ]] || die "no claim ${claim} in ${NS}"
    (( $(bytes "${have}") >= $(bytes "${WANTED}") )) || die "claim ${claim} has ${have}, less than ${WANTED}: grow the claims first (--expand)"
    [[ -z "$(conditions_of "${claim}")" ]] || die "claim ${claim} is still being resized [$(conditions_of "${claim}")]: wait for it"
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
  say "done. Sync or upgrade the chart again: its gate passes now"
}

case "${ACTION}" in
  check)                report ;;
  expand)               expand ;;
  recreate-statefulset) recreate ;;
esac
