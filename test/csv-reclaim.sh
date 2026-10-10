#!/usr/bin/env bash
# Tests for the csv-reclaim hook of chart/mongodb-search-helm, no cluster needed:  test/csv-reclaim.sh
# The hook's script is taken out of the rendered Job and run against a stand-in `oc` that keeps a namespace in
# files: ClusterServiceVersions and Subscriptions, one directory each, one file a fact. The stand-in answers what
# the script asks, removes a ClusterServiceVersion when the script deletes it, and writes down every call, so that
# each test can say what was read, what was deleted, and how the script ended.
# The hook deletes something the chart does not own: every test below is about when it may, and when it must not.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
CHART=chart/mongodb-search-helm
PKG=mongodb-kubernetes
NS=vectordb-test
fails=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/reclaim-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"

# ------------------------------------------------------------------------------------------- the script under test
helm template mongot "${CHART}" -n "${NS}" -f "${CHART}/examples/values-dvh-gp6-rnd.yaml" -s templates/03-csv-reclaim.yaml | python3 -c '
import re, sys
doc = sys.stdin.read()
m = re.search(r"^          args:\n            - \|\n((?:(?:              .*)?\n)+)", doc, re.M)
sys.stdout.write("\n".join(l[14:] for l in m.group(1).split("\n")))' > "${work}/reclaim.sh"
[[ -s "${work}/reclaim.sh" ]] && bash -n "${work}/reclaim.sh" && ok "the hook's script is rendered and parses" || { bad "the hook's script could not be taken from the render"; exit 1; }

# ------------------------------------------------------------------------------------------------ the stand-in oc
cat > "${work}/bin/oc" <<'EOF'
#!/usr/bin/env bash
# The namespace is the directory $FAKE: csv/<name>/ and sub/<name>/, one file a fact. A fact file of several lines
# is a sequence: each read takes the first line and leaves the rest, the last line stays. A line "-" is empty.
printf '%s\n' "$*" >> "${FAKE}/calls"
fact() {  # <file>
  [[ -e "$1" ]] || return 0
  local first; first="$(head -1 "$1")"
  if [[ "$(wc -l < "$1")" -gt 1 ]]; then tail -n +2 "$1" > "$1.next" && mv "$1.next" "$1"; fi
  [[ "${first}" == "-" ]] || printf '%s' "${first}"
}
verb="$1"; shift
res=(); out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) shift 2 ;;
    -o) out="$2"; shift 2 ;;
    --wait=false) shift ;;
    *) res+=("$1"); shift ;;
  esac
done
if [[ ${#res[@]} -eq 2 ]]; then type="${res[0]}"; name="${res[1]}"
elif [[ "${res[0]}" == */* ]]; then type="${res[0]%%/*}"; name="${res[0]#*/}"
else type="${res[0]}"; name=""; fi
case "${type}" in
  clusterserviceversion*) kind=csv; single=clusterserviceversion.operators.coreos.com ;;
  subscription*) kind=sub; single=subscription.operators.coreos.com ;;
  *) echo "error: the server doesn't have a resource type \"${type}\"" >&2; exit 1 ;;
esac
dir="${FAKE}/${kind}/${name}"
case "${verb}" in
  get)
    if [[ -z "${name}" ]]; then
      [[ "${kind}" == sub && -e "${FAKE}/subs_err" ]] && { cat "${FAKE}/subs_err" >&2; exit 1; }
      for d in "${FAKE}/${kind}"/*/; do [[ -d "$d" ]] && printf '%s/%s\n' "${single}" "$(basename "$d")"; done
      exit 0
    fi
    [[ -d "${dir}" ]] || { echo "Error from server (NotFound): ${single%%.*}s.operators.coreos.com \"${name}\" not found" >&2; exit 1; }
    if [[ -e "${dir}/terminating" && "${out}" == name ]]; then
      # "flaky": that many reads of its name fail first, for a reason that is not NotFound.
      if [[ -e "${FAKE}/flaky" && "$(cat "${FAKE}/flaky")" -gt 0 ]]; then
        echo $(( $(cat "${FAKE}/flaky") - 1 )) > "${FAKE}/flaky"; echo "Unable to connect to the server: dial tcp: i/o timeout" >&2; exit 1
      fi
      left="$(cat "${FAKE}/sticky")"
      if [[ "${left}" -le 0 ]]; then rm -r "${dir}"; echo "Error from server (NotFound): ${single%%.*}s.operators.coreos.com \"${name}\" not found" >&2; exit 1; fi
      echo $(( left - 1 )) > "${FAKE}/sticky"
    fi
    case "${out}" in
      name) printf '%s/%s\n' "${single}" "${name}" ;;
      *'olm\.copiedFrom'*) fact "${dir}/copiedFrom" ;;
      *ownerReferences*) fact "${dir}/owners" ;;
      *'{.status.phase}'*) fact "${dir}/phase" ;;
      *'{.status.installedCSV}'*) fact "${dir}/installedCSV" ;;
      *ResolutionFailed*'{.status}'*) fact "${dir}/resolutionFailed" ;;
      *ResolutionFailed*'{.message}'*) fact "${dir}/message" ;;
      *'{.spec.name}'*) [[ -e "${dir}/package_err" ]] && { cat "${dir}/package_err" >&2; exit 1; }; fact "${dir}/package" ;;
      *) echo "stand-in oc: unexpected output form: ${out}" >&2; exit 1 ;;
    esac ;;
  delete)
    [[ -e "${FAKE}/delete_err" ]] && { cat "${FAKE}/delete_err" >&2; exit 1; }
    [[ -d "${dir}" ]] || { echo "Error from server (NotFound): \"${name}\" not found" >&2; exit 1; }
    # A ClusterServiceVersion has a finalizer: the file "sticky" keeps it there for that many more reads of its name.
    if [[ -e "${FAKE}/sticky" ]]; then touch "${dir}/terminating"; else rm -r "${dir}"; fi
    printf '%s "%s" deleted\n' "${single}" "${name}" ;;
  *) echo "stand-in oc: unexpected verb: ${verb}" >&2; exit 1 ;;
esac
EOF
# The script sleeps 5 s between readings; the tests give it one.
printf '#!/usr/bin/env bash\nexec /bin/sleep 1\n' > "${work}/bin/sleep"
chmod +x "${work}/bin/oc" "${work}/bin/sleep"

# ------------------------------------------------------------------------------------------------------- helpers
new() { FAKE="${work}/ns.$1"; mkdir -p "${FAKE}/csv" "${FAKE}/sub"; : > "${FAKE}/calls"; }
csv() {  # <name> <phase lines> [copiedFrom] [owners]
  mkdir -p "${FAKE}/csv/$1"; printf '%b\n' "$2" > "${FAKE}/csv/$1/phase"
  [[ -z "${3:-}" ]] || printf '%s\n' "$3" > "${FAKE}/csv/$1/copiedFrom"
  [[ -z "${4:-}" ]] || printf '%s\n' "$4" > "${FAKE}/csv/$1/owners"
}
sub() {  # <name> <package> <installedCSV lines> <ResolutionFailed lines>
  mkdir -p "${FAKE}/sub/$1"; printf '%s\n' "$2" > "${FAKE}/sub/$1/package"
  printf '%b\n' "$3" > "${FAKE}/sub/$1/installedCSV"; printf '%b\n' "$4" > "${FAKE}/sub/$1/resolutionFailed"
}
run() {  # [WAIT_SECONDS]: runs the hook; sets out, rc and took (seconds)
  local t0; t0=$(date +%s)
  out="$(env PATH="${work}/bin:${PATH}" FAKE="${FAKE}" NAMESPACE="${NS}" SUBSCRIPTION="${PKG}" PACKAGE="${PKG}" WAIT_SECONDS="${1:-4}" bash "${work}/reclaim.sh" 2>&1)"; rc=$?
  took=$(( $(date +%s) - t0 ))
}
deleted() { grep -c '^delete ' "${FAKE}/calls" || true; }
there() { [[ -d "${FAKE}/csv/$1" ]]; }
OLD="${PKG}.v1.13.0"

# ------------------------------------------------------------- the Subscription exists: what the hook did before
new clean; sub "${PKG}" "${PKG}" "-" "-"; run
[[ $rc == 0 && "$(deleted)" == 0 && "$out" == *"nothing could be orphaned"* && $took -le 2 ]] \
  && ok "no ClusterServiceVersion: nothing to reclaim, and it does not wait" || bad "no CSV: rc=$rc deleted=$(deleted) took=${took}s: $out"

new referenced; csv "${OLD}" Succeeded; sub "${PKG}" "${PKG}" "${OLD}" "-"; run
[[ $rc == 0 && "$(deleted)" == 0 && "$out" == *"nothing could be orphaned"* ]] && there "${OLD}" \
  && ok "a ClusterServiceVersion its Subscription has installed is left alone" || bad "referenced CSV: rc=$rc deleted=$(deleted): $out"

new orphan; csv "${OLD}" Succeeded; sub "${PKG}" "${PKG}" "-" "-\n-\nTrue"; run 20
[[ $rc == 0 && "$(deleted)" == 1 && "$out" == *"ResolutionFailed"*"ORPHANED"*"reclaimed: ${OLD}"* ]] && ! there "${OLD}" \
  && grep -q "^delete clusterserviceversion.operators.coreos.com/${OLD} -n ${NS} --wait=false\$" "${FAKE}/calls" \
  && ok "an orphan is deleted once OLM reports ResolutionFailed, by its full name and without waiting" || bad "orphan with ResolutionFailed: rc=$rc deleted=$(deleted): $out"

new installed; csv "${OLD}" Succeeded; sub "${PKG}" "${PKG}" "-\n${PKG}.v1.14.0" "-"; run 20
[[ $rc == 0 && "$(deleted)" == 0 && "$out" == *"OLM reports an installed CSV"* ]] && there "${OLD}" \
  && ok "OLM installing another version is a verdict: nothing is deleted" || bad "installed verdict: rc=$rc deleted=$(deleted): $out"

new noverdict; csv "${OLD}" Succeeded; sub "${PKG}" "${PKG}" "-" "-"; run 3
[[ $rc == 0 && "$(deleted)" == 0 && "$out" == *"no verdict within 3s; taking no action"* ]] && there "${OLD}" \
  && ok "no verdict from OLM inside the budget: nothing is deleted" || bad "no verdict: rc=$rc deleted=$(deleted): $out"

new copy; csv "${OLD}" Succeeded "openshift-operators"; sub "${PKG}" "${PKG}" "-" "True"; run
[[ $rc == 0 && "$(deleted)" == 0 ]] && there "${OLD}" && ok "an OLM copy is never deleted" || bad "copy: rc=$rc deleted=$(deleted): $out"

new owned; csv "${OLD}" Succeeded "" '[{"kind":"Subscription"}]'; sub "${PKG}" "${PKG}" "-" "True"; run
[[ $rc == 0 && "$(deleted)" == 0 ]] && there "${OLD}" && ok "a ClusterServiceVersion with an owner is never deleted" || bad "owned: rc=$rc deleted=$(deleted): $out"

new other; csv "${PKG}-community.v9.9.9" Succeeded; csv "cert-manager-operator.v1.20.0" Succeeded; sub "${PKG}" "${PKG}" "-" "True"; run
[[ $rc == 0 && "$(deleted)" == 0 ]] && there "${PKG}-community.v9.9.9" && there "cert-manager-operator.v1.20.0" \
  && ok "another package's ClusterServiceVersion is never deleted, a longer name of this one's included" || bad "other package: rc=$rc deleted=$(deleted): $out"

new settles; csv "${OLD}" "Installing\nInstalling\nInstalling\nSucceeded"; sub "${PKG}" "${PKG}" "-" "True"; run 20
[[ $rc == 0 && "$(deleted)" == 1 && "$out" == *"waiting for OLM to settle"*"ORPHANED"* ]] && ! there "${OLD}" \
  && ok "an orphan OLM is still working on is waited for, then deleted" || bad "settles: rc=$rc deleted=$(deleted): $out"

new unsettled; csv "${OLD}" Installing; sub "${PKG}" "${PKG}" "-" "True"; run 3
[[ $rc == 0 && "$(deleted)" == 0 && "$out" == *"still not settled at the deadline, leaving alone"*"never settled within 3s"* ]] && there "${OLD}" \
  && ok "an orphan that never settles is left alone" || bad "unsettled: rc=$rc deleted=$(deleted): $out"

new forbidden; csv "${OLD}" Succeeded; sub "${PKG}" "${PKG}" "-" "True"
echo 'Error from server (Forbidden): clusterserviceversions.operators.coreos.com "x" is forbidden' > "${FAKE}/delete_err"; run
[[ $rc == 1 && "$out" == *"FAILED: could not delete orphaned CSV ${OLD}"*"Forbidden"* ]] && there "${OLD}" \
  && ok "a refused delete fails the hook and says why" || bad "forbidden: rc=$rc: $out"

# ------------------------------------------ no Subscription of this package: the verdict Argo CD's wave -3 runs on
new nosub; csv "${OLD}" Succeeded; run 60
[[ $rc == 0 && "$(deleted)" == 1 && $took -le 5 && "$out" == *"no Subscription of ${PKG} in ${NS}"*"ORPHANED"*"${OLD}: gone"*"reclaimed: ${OLD}"* ]] && ! there "${OLD}" \
  && [[ "$out" != *"waiting for OLM to report"* ]] \
  && ok "with no Subscription, an orphan is deleted at once and seen to be gone" || bad "no Subscription: rc=$rc deleted=$(deleted) took=${took}s: $out"

new nosub-failed; csv "${OLD}" Failed; run 60
[[ $rc == 0 && "$(deleted)" == 1 ]] && ! there "${OLD}" \
  && ok "with no Subscription, an orphan that reads Failed (no OperatorGroup) is deleted too" || bad "no Subscription, Failed: rc=$rc deleted=$(deleted): $out"

new nosub-othersub; csv "${OLD}" Succeeded; sub cert-manager openshift-cert-manager-operator "cert-manager-operator.v1.20.0" "-"; run 60
[[ $rc == 0 && "$(deleted)" == 1 ]] && ! there "${OLD}" \
  && ok "a Subscription of another package does not count as one of this package" || bad "another package's Subscription: rc=$rc deleted=$(deleted): $out"

new nosub-settles; csv "${OLD}" "Installing\nInstalling\nInstalling\nFailed"; run 20
[[ $rc == 0 && "$(deleted)" == 1 && "$out" == *"waiting for OLM to settle"* ]] && ! there "${OLD}" \
  && ok "with no Subscription, an orphan OLM is still working on is waited for, then deleted" || bad "no Subscription, settles: rc=$rc deleted=$(deleted): $out"

new nosub-unsettled; csv "${OLD}" Installing; run 3
[[ $rc == 0 && "$(deleted)" == 0 && "$out" == *"no Subscription of ${PKG} and a candidate CSV (${OLD}) never settled within 3s"* ]] && there "${OLD}" \
  && ok "with no Subscription, an orphan that never settles is left alone" || bad "no Subscription, unsettled: rc=$rc deleted=$(deleted): $out"

new nosub-slow; csv "${OLD}" Succeeded; echo 2 > "${FAKE}/sticky"; run 20
[[ $rc == 0 && "$(deleted)" == 1 && "$out" == *"deleted, waiting for it to be gone"*"${OLD}: gone"* ]] && ! there "${OLD}" \
  && ok "the hook ends only when the deleted ClusterServiceVersion is gone" || bad "no Subscription, slow finalizer: rc=$rc deleted=$(deleted): $out"

new nosub-flaky; csv "${OLD}" Succeeded; echo 1 > "${FAKE}/sticky"; echo 1 > "${FAKE}/flaky"; run 20
[[ $rc == 0 && "$(deleted)" == 1 && "$out" == *"${OLD}: gone"* ]] && ! there "${OLD}" \
  && ok "a read that fails for another reason than NotFound is not 'gone': it is asked again" || bad "no Subscription, a failing read: rc=$rc deleted=$(deleted): $out"

new nosub-stuck; csv "${OLD}" Succeeded; echo 999 > "${FAKE}/sticky"; run 2
[[ $rc == 1 && "$(deleted)" == 1 && "$out" == *"FAILED: deleted ${OLD}, and it was not gone when the wait ended: it is still there"*"csv-cleanup"* ]] && [[ $took -ge 25 && $took -le 45 ]] \
  && ok "a deleted ClusterServiceVersion that does not go fails the hook by name, after 30 s at least" || bad "no Subscription, stuck finalizer: rc=$rc took=${took}s: $out"

new nosub-never; csv "${OLD}" Succeeded "openshift-operators"; csv "${PKG}.v1.12.0" Succeeded "" '[{"kind":"Subscription"}]'; csv "${PKG}-community.v9.9.9" Succeeded; run 60
[[ $rc == 0 && "$(deleted)" == 0 ]] && there "${OLD}" && there "${PKG}.v1.12.0" && there "${PKG}-community.v9.9.9" \
  && ok "with no Subscription, a copy, an owned one and another package's are still never deleted" || bad "no Subscription, never: rc=$rc deleted=$(deleted): $out"

new othername; csv "${OLD}" Succeeded; sub my-search-operator "${PKG}" "-" "-"; run 3
[[ $rc == 0 && "$(deleted)" == 0 && "$out" == *"no verdict within 3s; taking no action"* ]] && there "${OLD}" \
  && ok "a Subscription of this package under another name is not 'no Subscription': nothing is deleted" || bad "Subscription under another name: rc=$rc deleted=$(deleted): $out"

new samename; csv "${OLD}" Succeeded; sub "${PKG}" some-other-package "-" "-"; run 3
[[ $rc == 0 && "$(deleted)" == 0 && "$out" == *"no verdict within 3s; taking no action"* ]] && there "${OLD}" \
  && ok "a Subscription with the chart's Subscription name is not 'no Subscription', whatever its package: nothing is deleted" || bad "Subscription of the same name: rc=$rc deleted=$(deleted): $out"

new listfails; csv "${OLD}" Succeeded; echo 'Unable to connect to the server: dial tcp: i/o timeout' > "${FAKE}/subs_err"; run 3
[[ $rc == 0 && "$(deleted)" == 0 && "$out" == *"no verdict within 3s; taking no action"* ]] && there "${OLD}" \
  && ok "a list of Subscriptions that fails is not 'no Subscription': nothing is deleted" || bad "list fails: rc=$rc deleted=$(deleted): $out"

new unreadable; csv "${OLD}" Succeeded; sub something some-package "-" "-"; echo 'Error from server (Forbidden): subscriptions is forbidden' > "${FAKE}/sub/something/package_err"; run 3
[[ $rc == 0 && "$(deleted)" == 0 && "$out" == *"no verdict within 3s; taking no action"* ]] && there "${OLD}" \
  && ok "a Subscription whose package cannot be read is not 'no Subscription': nothing is deleted" || bad "unreadable package: rc=$rc deleted=$(deleted): $out"

new nosub-clean; run 60
[[ $rc == 0 && "$(deleted)" == 0 && $took -le 2 && "$out" == *"nothing could be orphaned"* ]] \
  && ok "with no Subscription and no ClusterServiceVersion, a first install, it does nothing and does not wait" || bad "first install: rc=$rc took=${took}s: $out"

# ------------------------------------------------------------------------------------------- where the hook runs
wave() {  # <kind> <name>: the Argo CD wave of that object in the render
  helm template mongot "${CHART}" -n "${NS}" -f "${CHART}/examples/values-dvh-gp6-rnd.yaml" | python3 -c '
import re, sys
for doc in sys.stdin.read().split("\n---"):
    if re.search(r"^kind: " + sys.argv[1] + "$", doc, re.M) and re.search(r"^  name: " + sys.argv[2] + "$", doc, re.M):
        m = re.search(r"argocd.argoproj.io/sync-wave: \"(-?\d+)\"", doc); print(m.group(1) if m else "none")' "$1" "$2"; }
R=mongot-mongodb-search-helm
[[ "$(wave Job ${R}-csv-reclaim)" == -3 && "$(wave ServiceAccount ${R}-csv-reclaim)" == -3 && "$(wave Role ${R}-csv-reclaim)" == -3 && "$(wave RoleBinding ${R}-csv-reclaim)" == -3 \
   && "$(wave OperatorGroup ${R})" == -2 && "$(wave Subscription ${PKG})" == -1 && "$(wave Job ${R}-approver)" == -1 ]] \
  && ok "under Argo CD the hook and its access come a wave before the OperatorGroup, and two before the Subscription" \
  || bad "waves: reclaim $(wave Job ${R}-csv-reclaim)/$(wave ServiceAccount ${R}-csv-reclaim)/$(wave Role ${R}-csv-reclaim)/$(wave RoleBinding ${R}-csv-reclaim), OperatorGroup $(wave OperatorGroup ${R}), Subscription $(wave Subscription ${PKG}), approver $(wave Job ${R}-approver)"
helm template mongot "${CHART}" -n "${NS}" -f "${CHART}/examples/values-dvh-gp6-rnd.yaml" -s templates/03-csv-reclaim.yaml > "${work}/reclaim.yaml"
grep -q '^    helm.sh/hook: post-install,post-upgrade$' "${work}/reclaim.yaml" && grep -q '^    helm.sh/hook-weight: "-2"$' "${work}/reclaim.yaml" \
  && grep -q '^    argocd.argoproj.io/hook: Sync$' "${work}/reclaim.yaml" \
  && ok "under Helm it is still a post-install and post-upgrade hook ahead of the approver, when the Subscription exists" || bad "the hook's Helm annotations changed"

echo
if [[ ${fails} -eq 0 ]]; then echo "all csv-reclaim tests passed"; else echo "${fails} failed"; exit 1; fi
