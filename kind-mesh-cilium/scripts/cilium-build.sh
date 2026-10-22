#!/usr/bin/env bash
# Story #145: our Cilium build (CILIUM_IMAGE in kind-mesh/versions.env: release 1.20.2 plus Hubble naming the workload
# of a pod on another node of the same cluster) on the running lab, one cluster at a time, under searches and writes.
# For each cluster: the build's CiliumEndpoint CRD and its label first, then a Helm upgrade that changes the images and
# nothing else (--reset-then-reuse-values keeps every value the release runs: WireGuard, the L7 backend, the mesh,
# Hubble's TLS; checked on the release's values before and after), then step 2's gate before the next cluster: every
# agent on the build, the clustermesh-apiserver on its image when the build has one, Cilium healthy, WireGuard on every
# agent, connected to both other clusters, and every CiliumEndpoint of a pod with an owner carrying status.workloads.
# Then #187's step: once the mongot-global frontend on mongod's node is an L7 load balancer again, Cilium's Envoy there
# must count mongod's searches; if it does not, that cluster's mongod is restarted (output/cilium-build-l7.txt).
#
# Story #190: the same rollout from #145's build to the one that names the workload across Cluster Mesh, which needs
# the clustermesh-apiserver's image too (CILIUM_CLUSTERMESH_IMAGE), both built in the VM's docker (CILIUM_IMAGES_LOCAL=1:
# kind load, no pull). What each side runs and names is pinned in versions.env (CILIUM_BEFORE_COMMIT, CILIUM_BEFORE_SCOPE,
# CILIUM_SCOPE): the next build is a pin change.
#
#   kind-mesh-cilium/scripts/cilium-build.sh measure before   # on what runs now: output/cilium-build-before.txt
#   kind-mesh-cilium/scripts/cilium-build.sh upgrade 2>&1 | tee kind-mesh-cilium/output/cilium-build.log
#                                                             # mesh2, mesh1, then mesh0 (the primary's); the loads in
#                                                             # output/cilium-build-evidence.*/cilium-build-load-<cluster>.txt
#   kind-mesh-cilium/scripts/cilium-build.sh upgrade mesh2    # the named clusters only, in that order
#   LOAD_SECONDS=60 ... upgrade                               # the load runs in batches of this many seconds (60)
#                                                             # until the last gate passes; each batch checks its writes
#   kind-mesh-cilium/scripts/cilium-build.sh measure after    # on the build: output/cilium-build-after.txt
#   kind-mesh-cilium/scripts/cilium-build.sh drill            # mesh2 loses its mongot: do its cross-cluster search
#                                                             # flows name the workload? (with CILIUM_SCOPE=mesh, expected
#                                                             # all named; otherwise none)
#
# Back to the release: inspect history, then rollback to the saved original revision explicitly. The CRD keeps the
# optional field, which the release ignores, and its label, which the release operator leaves alone.
# shellcheck disable=SC2015  # row always returns 0, so A && row || row is if/else
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
# shellcheck disable=SC1091
. "$here/scripts/rs-lib.sh"   # rs_eval, for rs_healthy
lab_env
# shellcheck disable=SC2153  # CLUSTERS comes from versions.env
read -r -a clusters <<<"$CLUSTERS"
out="$here/output"
# The build's commit from its tag, and what runs before it (versions.env). Agents print the build clone's
# `git rev-parse --short`, whose length is the clone's: #145's printed 1d3a02ab, #190's prints 9e5a34a525 while its tag
# ends in 9e5a34a5. So a printed commit matches when it starts with the expected one (on_commit), never by equality.
commit=${CILIUM_IMAGE##*-}
before_commit=$CILIUM_BEFORE_COMMIT
[[ "$commit" =~ ^[0-9a-f]{7,}$ && "$before_commit" =~ ^[0-9a-f]{7,}$ ]] \
  || die "CILIUM_IMAGE must end in -<commit> and CILIUM_BEFORE_COMMIT be a commit (7+ hex digits)"
for x in "$CILIUM_BEFORE_SCOPE" "$CILIUM_SCOPE"; do
  case "$x" in node|cluster|mesh) ;; *) die "CILIUM_BEFORE_SCOPE and CILIUM_SCOPE are node, cluster or mesh, not $x" ;; esac
done
l7_record="$out/cilium-build-l7.txt"   # #187's step, per cluster; "RESTARTED <cluster>" when its mongod was restarted
tmp=$(mktemp -d "$out/cilium-build-evidence.XXXXXX")
load_pids=()
active_cluster=none
completed_clusters=""
finish() {
  local rc=$? pid c
  trap - EXIT
  touch "$tmp/stop-load"
  for pid in ${load_pids[@]+"${load_pids[@]}"}; do wait "$pid" || rc=1; done
  for c in "${clusters[@]}"; do
    if [ -s "$tmp/cilium-build-load-$c.txt" ]; then
      summarize_load "$tmp/cilium-build-load-$c.txt" || rc=1
    fi
  done
  if [ "$rc" -ne 0 ]; then
    echo "STOPPED: active=$active_cluster; passed gates=$completed_clusters; evidence=$tmp" >&2
    echo "No rollback: earlier clusters remain upgraded; active cluster may be mixed/failed, its CRD remains. Later clusters were not upgraded. Inspect Helm history and saved revisions before repair; do not blindly rollback the previous revision." >&2
  fi
  echo "Evidence retained: $tmp"
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
t0=$(date +%s)
note() { printf '[t+%3ss] %s\n' "$(($(date +%s) - t0))" "$1"; }
fails=0
row() { # <PASS|FAIL> <claim> <evidence>, as kind-mesh/check.sh prints them
  printf '%-4s  %-66s  %s\n' "$1" "$2" "$3"
  [ "$1" = PASS ] || fails=$((fails + 1))
}

agents() { # <cluster>: each Cilium agent as "<pod> <version> <commit>", from the agent binary
  local p pods version
  pods=$(kubectl --context "kind-$1" -n kube-system get pods -l k8s-app=cilium -o name) || return 1
  [ "$(printf '%s\n' "$pods" | sed '/^$/d' | wc -l | tr -d ' ')" = 2 ] || return 1
  for p in $pods; do
    version=$(kubectl --context "kind-$1" -n kube-system exec "$p" -c cilium-agent -- cilium-agent --version) || return 1
    echo "${p#pod/} $(cut -d' ' -f2,3 <<<"$version")"
  done
}
agent_on() { # <cluster> <node>: the Cilium agent pod on that node
  kubectl --context "kind-$1" -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=$2" -o jsonpath='{.items[0].metadata.name}'
}
# The CiliumEndpoints of <cluster>: "<all> <with status.workloads> <missing> <missing names>", where missing counts the
# CiliumEndpoints without it whose pod has a workload by Cilium's rule (v1.20.2 pkg/k8s/utils/workload.go: a generated
# name and a controller owner). A bare pod has none to carry.
ceps() { # <cluster>
  local endpoints pods
  endpoints=$(kubectl --context "kind-$1" get ciliumendpoints -A -o json) || return 1
  pods=$(kubectl --context "kind-$1" get pods -A -o json) || return 1
  python3 -c '
import json, sys
ceps = json.load(open(sys.argv[1]))["items"]
owned = {(p["metadata"]["namespace"], p["metadata"]["name"]) for p in json.load(open(sys.argv[2]))["items"]
         if not p.get("spec", {}).get("hostNetwork") and p.get("status", {}).get("phase") not in ("Succeeded", "Failed")
         and p["metadata"].get("generateName") and any(o.get("controller") for o in p["metadata"].get("ownerReferences", []))}
assert ceps and owned, "empty CEP or owned-pod inventory"
named = [c for c in ceps if c.get("status", {}).get("workloads")]
present = {(c["metadata"]["namespace"], c["metadata"]["name"]) for c in named}
missing = ["/".join(k) for k in sorted(owned - present)]
print(len(ceps), len(named), len(missing), ",".join(missing) or "-")' \
    <(printf '%s\n' "$endpoints") <(printf '%s\n' "$pods")
}
# Hubble flows on stdin (hubble observe -o json), replies left out, as "<type>=<named>/<all> ...": named when
# destination.workloads holds <kind/name>. With <cluster>, only flows to another cluster count.
named_count() { # <kind/name> [cluster]
  python3 -c '
import collections, json, sys
want, home = sys.argv[1], sys.argv[2]
n, named = collections.Counter(), collections.Counter()
for line in sys.stdin:
    try:
        f = json.loads(line)["flow"]
    except (ValueError, KeyError):
        continue
    d = f.get("destination", {})
    if f.get("is_reply") or (home and d.get("cluster_name") in (home, None)):
        continue
    if d.get("workloads") and not any(w.get("kind", "") + "/" + w.get("name", "") == want for w in d["workloads"]):
        n["INVALID"] = 0
        named["INVALID"] = 1
    n[f.get("Type")] += 1
    named[f.get("Type")] += any(w.get("kind", "") + "/" + w.get("name", "") == want for w in d.get("workloads", []))
print(" ".join(f"{t}={named[t]}/{n[t]}" for t in sorted(n)) or "none")' "$1" "${2:-}"
}
flows() { # <cluster> <agent pod> <kind/name> <hubble filters...>: the last minute's flows on that agent, counted
  local c=$1 a=$2 want=$3
  shift 3
  local raw="$tmp/$c-flow-$RANDOM.json"
  kubectl --context "kind-$c" -n kube-system exec "$a" -c cilium-agent -- hubble observe --since "$flow_since" -o json "$@" >"$raw" || return 1
  named_count "$want" <"$raw"
}
# PASS when <flows> has the <required> type, and in every type all (or none) of its flows name the workload. An L3/L4
# flow is reported for a new connection, not for every packet, so a connection the proxy keeps open may show none.
verdict() { # <flows> <all|none> <required type>
  local w t v
  [[ " $1" == *" $3="* ]] || { echo FAIL; return; }
  for w in $1; do
    t=${w%%=*} v=${w#*=}
    [ "$t" != "$w" ] || { echo FAIL; return; }
    if [ "$2" = all ]; then [ "${v%/*}" = "${v#*/}" ] || { echo FAIL; return; }
    else [ "${v%/*}" = 0 ] || { echo FAIL; return; }; fi
  done
  echo PASS
}

# A fresh direct connection creates L3/L4 evidence even when the L7 proxy reuses its backend connection.
# It originates inside the same mongod container and targets the already selected mongot; no pods are moved.
probe_l34() { # <cluster> <mongot pod>
  local ip reply
  ip=$(kubectl --context "kind-$1" -n search get pod "$2" -o jsonpath='{.status.podIP}') || return 1
  [ -n "$ip" ] || return 1
  reply=$(kubectl --context "kind-$1" -n mongodb exec mongo-0 -c mongod -- curl -sS -o /dev/null -D - \
    --http2-prior-knowledge --max-time 5 -X POST -H 'content-type: application/grpc' -H 'te: trailers' \
    --data-binary @/dev/null "http://$ip:27028/grpc.health.v1.Health/Check") || return 1
  printf '%s\n' "$reply" >"$tmp/$1-$2-probe.txt"
  grep -q 'Half-closed without a request' <<<"$reply"
}

# Compare application identity and placement, excluding the deliberately replaced Cilium agents.
placement() {
  local c
  for c in "${clusters[@]}"; do
    kubectl --context "kind-$c" -n mongodb get pod mongo-0 -o json >"$tmp/$c-mongo.json" || return 1
    kubectl --context "kind-$c" -n search get pods -l app=mongot-search-0-svc -o json >"$tmp/$c-mongot.json" || return 1
  done
  python3 - "$tmp" "${clusters[@]}" >"$1" <<'PYCODE'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1]); rows = []
for c in sys.argv[2:]:
    mongo = json.loads((root / (c + "-mongo.json")).read_text())
    targets = json.loads((root / (c + "-mongot.json")).read_text())["items"]
    assert len(targets) == 2
    for p in [mongo] + targets:
        m = p["metadata"]; s = p["spec"]; status = p["status"]
        assert not m.get("deletionTimestamp") and status["phase"] == "Running"
        rows.append([c, m["namespace"], m["name"], m["uid"], status["podIP"], s["nodeName"], m.get("ownerReferences", [])])
print(json.dumps(sorted(rows), sort_keys=True))
PYCODE
}

# The batches' totals. gapMs is the longest wait for an acknowledged write while writes were being made; betweenMs the
# longest time between two batches, when the harness (kubectl exec, mongosh, the batch's check) wrote nothing: it is
# kept apart, as it is not an outage the load saw. A pause for a mongod restart (PAUSED) is not a time between batches.
summarize_load() {
  python3 - "$1" <<'PYCODE'
import json, sys
rows, between, prev = [], [], None
for l in open(sys.argv[1]):
    if l.startswith("PAUSED"):
        prev = None
    elif l.startswith("RESULT "):
        rows.append(json.loads(l[7:]))
        if prev:
            between.append(rows[-1]["write"]["startMs"] - prev["write"]["endMs"])
        prev = rows[-1]
assert rows, "no completed load batches"
summary = {k: {"ok": sum(r[k]["ok"] for r in rows), "fail": sum(r[k]["fail"] for r in rows),
               "maxMs": max(r[k]["maxMs"] for r in rows)} for k in ("write", "search")}
summary["write"]["gapMs"] = max(r["write"]["gapMs"] for r in rows)
summary["write"]["betweenMs"] = max(between, default=0)
summary["batches"] = len(rows)
print("SUMMARY " + sys.argv[1] + " " + json.dumps(summary, sort_keys=True))
PYCODE
}

# Finite batches keep the load alive for arbitrarily long gates. Each batch checks its exact acknowledged ids.
# On exit the current batch finishes; no infrastructure restore or detached loader remains.
# stop-load-<cluster> pauses one cluster's load (its batch finishes), for a restart of its mongod, whose container
# the load runs in.
load_batches() {
  local c=$1 secs=$2 batch=$3
  while [ ! -e "$tmp/stop-load" ] && [ ! -e "$tmp/stop-load-$c" ]; do
    batch=$((batch + 1))
    if ! CLIENT_OPTS="${CLIENT_OPTS:-timeoutMS=10000}" "$here/drills.sh" load-rw "$c" "$secs" "build-$c-$(basename "$tmp")-$batch"; then
      touch "$tmp/load-failed-$c"
      return 1
    fi
  done
  echo "$batch" >"$tmp/load-batch-$c"
}
start_load() { # <cluster>: its load in the background, appended to its log, batch ids continuing; upgrade's $secs
  local c=$1
  load_batches "$c" "${secs:?}" "$(cat "$tmp/load-batch-$c" 2>/dev/null || echo 0)" >>"$tmp/cilium-build-load-$c.txt" 2>&1 &
  load_pids+=($!)
  echo $! >"$tmp/load-pid-$c"
}
pause_load() { # <cluster>: waits for its current batch, then no load through its member until resume_load
  local c=$1 pid p kept=()
  pid=$(cat "$tmp/load-pid-$c")
  touch "$tmp/stop-load-$c"
  wait "$pid" || die "$c: load or acknowledged-write check failed"
  for p in "${load_pids[@]}"; do [ "$p" = "$pid" ] || kept+=("$p"); done
  load_pids=(${kept[@]+"${kept[@]}"})
  echo "PAUSED $(date -u +%FT%TZ) for a restart of $c's mongod" >>"$tmp/cilium-build-load-$c.txt"
}
resume_load() { rm -f "$tmp/stop-load-$1"; start_load "$1"; }
check_loads() {
  local c
  for c in "${clusters[@]}"; do [ ! -e "$tmp/load-failed-$c" ] || die "$c: load or acknowledged-write check failed"; done
}

# Every agent of an inventory (agents) on CILIUM_VERSION and a commit starting with <commit>: see `commit` above.
on_commit() { # <inventory> <commit>
  awk -v v="$CILIUM_VERSION" -v h="$2" 'NF != 3 || $2 != v || $3 !~ /^[0-9a-f]+$/ || length($3) > 40 || index($3, h) != 1 {bad=1} END {exit bad}' <<<"$1"
}
# What Hubble names at <scope> (versions.env): mongod's flows to the mongot on the other node of its cluster (named
# from cluster up), and to the other clusters' mongod (named at mesh only), as verdict's all or none.
other_node() { case "$1" in node) echo none ;; *) echo all ;; esac; }
cross_cluster() { case "$1" in mesh) echo all ;; *) echo none ;; esac; }

# The measurement, in every cluster: which build each agent runs, which CiliumEndpoints carry status.workloads, and
# whether Hubble names the workload of mongod's search flows to the mongot on the other node of its cluster (#145),
# to the mongot on its own node (named by the release already: the control), and of mongod's replication flows to the
# other clusters' members (#190). Before expects CILIUM_BEFORE_COMMIT at CILIUM_BEFORE_SCOPE, after the build at
# CILIUM_SCOPE.
measure() { # <before|after>
  local tag=$1 log="$out/cilium-build-$1.txt" c node agent remote same others x rf sf xf v all named missing names
  local want scope ver inventory flow_since expect cross
  case "$tag" in
    before) want=$before_commit scope=$CILIUM_BEFORE_SCOPE ;;
    after) want=$commit scope=$CILIUM_SCOPE ;;
    *) die "measure expects before or after" ;;
  esac
  expect=$(other_node "$scope") cross=$(cross_cluster "$scope")
  placement "$tmp/placement.json"
  if [ "$tag" = after ]; then
    # A mongod restarted by #187's step (RESTARTED in the record) has a new UID and address; nothing else may change.
    python3 - "$out/cilium-build-placement.json" "$tmp/placement.json" "$l7_record" <<'PYCODE' \
      || die "pod UID/IP/node/owner changed, or no baseline placement; take a new before measurement"
import json, os, sys
base, now = (json.load(open(f)) for f in sys.argv[1:3])
restarted = {l.split()[1] for l in open(sys.argv[3]) if l.startswith("RESTARTED ")} if os.path.exists(sys.argv[3]) else set()
key = lambda r: [r[0], r[1], r[2], r[5], r[6]] if r[1] == "mongodb" and r[0] in restarted else r
assert [key(r) for r in base] == [key(r) for r in now]
PYCODE
  fi
  fails=0
  {
    echo "== $tag: $(date -u +%Y-%m-%dT%H:%MZ); expecting every agent on $CILIUM_VERSION $want, workloads named at scope $scope"
    for c in "${clusters[@]}"; do
      echo "== $c"
      inventory=$(agents "$c") || die "$c: cannot inventory both agents"
      ver=$(awk '{print $1 "=" $2 ":" $3}' <<<"$inventory" | tr '\n' ' ')
      on_commit "$inventory" "$want" && row PASS "$c: every agent on $want" "$ver" || row FAIL "$c: every agent on $want" "$ver"
      inventory=$(ceps "$c") || die "$c: cannot inventory CEPs"
      read -r all named missing names <<<"$inventory"
      if [ "$scope" = node ]; then
        [ "$named" = 0 ] && row PASS "$c: no CiliumEndpoint carries status.workloads" "$named of $all" \
          || row FAIL "$c: no CiliumEndpoint carries status.workloads" "$named of $all"
      else
        [ "$missing" = 0 ] && [ "$named" -gt 0 ] && row PASS "$c: every CiliumEndpoint of an owned pod carries status.workloads" "$named of $all; missing: $names" \
          || row FAIL "$c: every CiliumEndpoint of an owned pod carries status.workloads" "$named of $all; missing: $names"
      fi
      node=$(kubectl --context "kind-$c" -n mongodb get pod mongo-0 -o jsonpath='{.spec.nodeName}')
      agent=$(agent_on "$c" "$node")
      remote=$(kubectl --context "kind-$c" -n search get pods -l app=mongot-search-0-svc \
        -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' | awk -v n="$node" '$2 != n {print $1; exit}')
      same=$(kubectl --context "kind-$c" -n search get pods -l app=mongot-search-0-svc \
        -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' | awk -v n="$node" '$2 == n {print $1; exit}')
      # About 16 searches through the member, so the last minute has search flows to read; mongot-global's L7 proxy
      # spreads them over the cluster's mongot (step 2), so both mongot get some.
      flow_since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      v=$("$here/drills.sh" load-only "$c" 8 2>&1 | sed -n 's/^RESULT //p')
      python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["ok"] > 0 and r["fail"] == 0' "$v" || die "$c: search load failed"
      echo "      searches through $c's member: $v; mongod on $node, read on its agent $agent"
      if [ -n "$remote" ]; then
        probe_l34 "$c" "$remote" || die "$c: fresh mongot L3/L4 probe failed"
        sleep 1
        rf=$(flows "$c" "$agent" StatefulSet/mongot-search-0 --from-cluster "$c" --from-pod mongodb/mongo-0 --to-cluster "$c" --to-pod "search/$remote" --port 27028)
        row "$(verdict "$rf" "$expect" L3_L4)" "$c: other-node L3/L4 attribution" "$rf"
        row "$(verdict "$rf" "$expect" L7)" "$c: mongod -> $remote (other node) names $([ "$expect" = none ] && echo nothing || echo StatefulSet/mongot-search-0)" "named/flows: $rf"
      else
        row FAIL "$c: a mongot on the other node than mongod" "none: both mongot on $node"
      fi
      if [ -n "$same" ]; then
        sf=$(flows "$c" "$agent" StatefulSet/mongot-search-0 --from-cluster "$c" --from-pod mongodb/mongo-0 --to-cluster "$c" --to-pod "search/$same" --port 27028)
        row "$(verdict "$sf" all L7)" "$c: mongod -> $same (same node, the control) names StatefulSet/mongot-search-0" "named/flows: $sf"
      else
        row FAIL "$c: same-node control mongot" "missing"
      fi
      others=()
      for x in "${clusters[@]}"; do [ "$x" = "$c" ] || others+=(--to-cluster "$x"); done
      xf=$(flows "$c" "$agent" StatefulSet/mongo --from-cluster "$c" --from-pod mongodb/mongo-0 --to-pod mongodb/mongo-0 "${others[@]}" --port 27017)
      row "$(verdict "$xf" "$cross" L3_L4)" "$c: mongod -> the other clusters' mongod names $([ "$cross" = none ] && echo nothing || echo StatefulSet/mongo)" "named/flows: $xf"
    done
    echo "== $tag: $fails failed"
  } | tee "$log"
  v=$(sed -n "s/^== $tag: \([0-9]*\) failed$/\1/p" "$log")
  placement "$tmp/placement-end.json"
  cmp "$tmp/placement.json" "$tmp/placement-end.json" || die "placement changed during measurement"
  # A new baseline: #187's restarts recorded against the old one no longer apply.
  if [ "$v" = 0 ] && [ "$tag" = before ]; then cp "$tmp/placement.json" "$out/cilium-build-placement.json"; rm -f "$l7_record"; fi
  [ "$v" = 0 ]
}

# Step 2's gate, and the build's own: before the next cluster is touched.
gate() { # <cluster>
  local c=$1 ctx="kind-$1" p o n all named missing names i inventory
  kubectl --context "$ctx" -n kube-system rollout status ds/cilium --timeout=5m >/dev/null
  inventory=$(agents "$c") || die "$c: cannot inventory both agents"
  on_commit "$inventory" "$commit" || die "$c: agents not on the build $CILIUM_VERSION $commit: $(tr '\n' ' ' <<<"$inventory")"
  note "$c: every agent answers $CILIUM_VERSION $commit*"
  # The apiserver's image has no version command, so the Deployment's container images are the check; the rollout
  # status, that its pods run that template.
  if [ -n "${CILIUM_CLUSTERMESH_IMAGE:-}" ]; then
    kubectl --context "$ctx" -n kube-system rollout status deploy/clustermesh-apiserver --timeout=5m >/dev/null
    o=$(kubectl --context "$ctx" -n kube-system get deploy clustermesh-apiserver \
      -o jsonpath='{range .spec.template.spec.initContainers[*]}{.name}={.image}{"\n"}{end}{range .spec.template.spec.containers[*]}{.name}={.image}{"\n"}{end}')
    [ -n "$o" ] && awk -F= -v want="$CILIUM_CLUSTERMESH_IMAGE" '$2 != want {bad=1} END {exit bad}' <<<"$o" \
      || die "$c: clustermesh-apiserver not on $CILIUM_CLUSTERMESH_IMAGE: $(tr '\n' ' ' <<<"$o")"
    note "$c: clustermesh-apiserver rolled out, $(wc -l <<<"$o" | tr -d ' ') containers on $CILIUM_CLUSTERMESH_IMAGE"
  fi
  cilium_healthy "$c" "on the build"
  # shellcheck disable=SC2013  # Kubernetes pod names contain no whitespace
  for p in $(awk '{print $1}' <<<"$inventory"); do
    kubectl --context "$ctx" -n kube-system exec "$p" -c cilium-agent -- cilium-dbg encrypt status 2>/dev/null | grep -q 'Encryption: Wireguard' \
      || die "$c $p does not report WireGuard encryption"
  done
  o=$(cilium clustermesh status --context "$ctx" --wait --wait-duration 5m 2>&1) || { printf '%s\n' "$o"; die "$c: clustermesh command failed"; }
  n=$(grep -c 'configured, 2/2 connected' <<<"$o" || true)
  [ "$n" = $((${#clusters[@]} - 1)) ] || { printf '%s\n' "$o"; die "$c is connected to $n of $((${#clusters[@]} - 1)) clusters"; }
  note "$c: Cilium healthy, WireGuard on every agent, connected to the $n other clusters"
  # Each new agent writes its endpoints' status once it has their identities; allow it a minute.
  for i in $(seq 1 30); do
    inventory=$(ceps "$c") || die "$c: CEP inventory failed"
    read -r all named missing names <<<"$inventory"
    [ "$missing" = 0 ] && break
    sleep 2
  done
  [ "$missing" = 0 ] || die "$c: $missing CiliumEndpoints of owned pods without status.workloads after $((i * 2)) s: $names"
  note "$c: $named of $all CiliumEndpoints carry status.workloads (the others' pods have no owner)"
}

# The build's images on every node of <clusters> before any agent restarts, so that no agent waits on a download (the
# DaemonSet replaces both agents of a cluster at once: maxUnavailable 2, the chart's default). The nodes' /var is the
# VM's one docker disk, which also holds mongot's volumes (local-path; kind-mesh/versions.env): mongot stops indexing
# at 85% of it used (#182), so no image may take the disk there. The first cluster, allowed 4 GiB (two images on two
# nodes; #145 allowed 2 GiB for one image on one node). Reserve at least that much for every cluster, even
# when the first cluster is cached. This is a capacity budget, not an upper bound proved from image sizes; include
# import scratch space in CILIUM_IMAGE_CLUSTER_BUDGET_KIB and exclude concurrent disk writers.
disk_used() { # <node> [KiB more]: the % of the node's /var used, with that much more written; fails at 85% or above
  local df size avail
  df=$(docker exec "$1" df -k --output=size,avail /var | tail -1) || return 1
  read -r size avail <<<"$df"
  [ "${size:-0}" -gt 0 ] && [ -n "${avail:-}" ] || return 1
  echo $(((size - avail + ${2:-0}) * 100 / size))
  [ $(((size - avail + ${2:-0}) * 100)) -lt $((size * 85)) ]
}
avail_kib() { docker exec "$1" df -k --output=avail /var | tail -1 | tr -d ' '; }
place_images() { # <cluster>: kind load from the VM's docker (CILIUM_IMAGES_LOCAL=1), or a pull on each node
  local img n
  if [ "${CILIUM_IMAGES_LOCAL:-0}" = 1 ]; then cilium_load_local "$1"; return; fi
  for img in "$CILIUM_IMAGE" ${CILIUM_CLUSTERMESH_IMAGE:+"$CILIUM_CLUSTERMESH_IMAGE"}; do
    for n in "$1-control-plane" "$1-worker"; do docker exec "$n" crictl pull "$img" >/dev/null; done
  done
}
prepull() { # <cluster...>
  local c n first=$1 before per pct reserve remaining=$#
  # A cached first cluster cannot estimate a cold one. Reserve a budget for EVERY
  # cluster before writing; increase this bound for larger images/import scratch space.
  reserve=${CILIUM_IMAGE_CLUSTER_BUDGET_KIB:-4194304}
  [[ "$reserve" =~ ^[1-9][0-9]*$ ]] || die "CILIUM_IMAGE_CLUSTER_BUDGET_KIB must be positive"
  n="$first-control-plane"
  pct=$(disk_used "$n" $((reserve * remaining))) || die "the VM's disk would be ${pct:-?}% used with the image budgets; mongot stops indexing at 85%"
  for c in "$@"; do
    pct=$(disk_used "$n" $((reserve * remaining))) || die "$c: insufficient disk for remaining image budgets"
    before=$(avail_kib "$n")
    place_images "$c"
    remaining=$((remaining - 1))
    if [ "$c" = "$first" ]; then
      per=$((before - $(avail_kib "$n")))
      [ "$per" -ge "$reserve" ] || per=$reserve
      pct=$(disk_used "$n" $((per * ($# - 1)))) \
        || die "the VM's disk would be ${pct:-?}% used once all $# clusters hold the images ($((per / 1024)) MiB each); mongot stops indexing at 85%"
      note "images on $c: $((per / 1024)) MiB; the VM's disk $pct% used once all $# clusters hold them"
    else
      pct=$(disk_used "$n") || die "the VM's disk is ${pct:-?}% used after the images went onto $c; mongot stops indexing at 85%"
      note "images on $c: the VM's disk $pct% used"
    fi
  done
}

# #187: an agent restart writes mongot-global's frontend as plain L4 for about a minute, and a connection mongod opens
# then goes straight to one mongot, past Cilium's Envoy, until mongod reconnects. So once the frontend on mongod's node
# is an L7 load balancer again, its Envoy must count 20 searches through mongod (drills.sh load-only, 10 s); the
# harness loads are paused for this check. The aggregate delta is a smoke test: retries, fanout or external
# traffic can still mask bypass. It is not per-request attribution or proof that every search crossed Envoy.
mongot_frontend_l7() { # <cluster> <agent> <frontend ip>: every slot-0 entry of <ip>:27028 has the L7 flag
  kubectl --context "kind-$1" -n kube-system exec "$2" -c cilium-agent -- cilium-dbg bpf lb list -o json 2>/dev/null \
    | python3 -c '
import json, sys
fe = [v for k, v in json.load(sys.stdin).items() if k in (sys.argv[1] + " (0)", sys.argv[1] + "/i (0)")]
sys.exit(0 if fe and all(any("l7-load-balancer" in e for e in v) for v in fe) else 1)' "$3:27028/TCP"
}
envoy_requests() { # <cluster> <agent>: upstream_rq_total of search/mongot-global in the Envoy of that agent's node
  kubectl --context "kind-$1" -n kube-system exec "$2" -c cilium-agent -- cilium-dbg envoy admin metrics \
    | awk '$1 ~ /^envoy_cluster_upstream_rq_total\{/ && index($1, "envoy_cluster_name=\"search/mongot-global\"") {n += $2; hit = 1}
      END {if (!hit) exit 1; printf "%d\n", n}'
}
envoy_counts() { # <cluster>: true when Envoy on mongod's node counted the searches; recorded either way
  local c=$1 ip node agent i before after v ok
  ip=$(kubectl --context "kind-$c" -n search get svc mongot-global -o jsonpath='{.spec.clusterIP}')
  [ -n "$ip" ] || die "$c: no ClusterIP for search/mongot-global"
  node=$(kubectl --context "kind-$c" -n mongodb get pod mongo-0 -o jsonpath='{.spec.nodeName}')
  agent=$(agent_on "$c" "$node" || true)
  [ -n "$node" ] && [ -n "$agent" ] || die "$c: no node or agent for mongo-0"
  for i in $(seq 1 60); do
    mongot_frontend_l7 "$c" "$agent" "$ip" && break
    [ "$i" -lt 60 ] || die "$c: mongot-global ($ip:27028) on $node is not an L7 load balancer after 300 s"
    sleep 5
  done
  note "$c: mongot-global $ip:27028 is an L7 load balancer on $node (check $i)"
  before=$(envoy_requests "$c" "$agent") || die "$c: no upstream_rq_total for search/mongot-global from $agent"
  v=$("$here/drills.sh" load-only "$c" 10 2>&1 | sed -n 's/^RESULT //p') || die "$c: search command failed"
  ok=$(python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["ok"] > 0 and r["fail"] == 0; print(r["ok"])' "$v") || die "$c: search load failed"
  after=$(envoy_requests "$c" "$agent") || die "$c: no upstream_rq_total for search/mongot-global from $agent"
  printf '%s L7 %s: %s searches answered, Envoy on %s counted %s (%s -> %s)\n' "$(date -u +%FT%TZ)" "$c" "$ok" "$node" \
    "$((after - before))" "$before" "$after" | tee -a "$l7_record"
  [ $((after - before)) -ge "$ok" ]
}
rs_healthy() { # every member of rs0 up, PRIMARY or SECONDARY
  printf 'const m = rs.status().members; print("RS " + (m.length === %s && m.every(x => x.health === 1 && ["PRIMARY", "SECONDARY"].includes(x.stateStr)) ? "healthy" : m.map(x => x.name.split(".")[0] + "=" + x.stateStr).join(",")))\n' \
    "${#clusters[@]}" | rs_eval | grep -qx 'RS healthy'
}
mongod_restart() { # <cluster>: one member at a time, and only while every member is healthy
  local c=$1 uid i now
  # l7_after_restart has drained every harness load; check health AFTER that wait.
  rs_healthy || die "$c: not restarting mongod while a member of rs0 is not healthy"
  uid=$(kubectl --context "kind-$c" -n mongodb get pod mongo-0 -o jsonpath='{.metadata.uid}')
  [ -n "$uid" ] || die "$c: cannot identify mongo-0 for restart"
  note "$c: Envoy did not count mongod's searches; restarting mongo-0 (#187); if primary, this triggers an election (mesh0 is normally primary)"
  rs_healthy || die "$c: rs0 health changed before deletion"
  kubectl --context "kind-$c" -n mongodb delete pod mongo-0 --wait=true --timeout=5m >/dev/null
  for i in $(seq 1 60); do
    now=$(kubectl --context "kind-$c" -n mongodb get pod mongo-0 -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
    [ -n "$now" ] && [ "$now" != "$uid" ] && break
    [ "$i" -lt 60 ] || die "$c: no new mongo-0 after 300 s"
    sleep 5
  done
  kubectl --context "kind-$c" -n mongodb wait pod/mongo-0 --for=condition=Ready --timeout=10m >/dev/null || die "$c: mongo-0 not Ready"
  for i in $(seq 1 60); do
    rs_healthy && break
    [ "$i" -lt 60 ] || die "$c: rs0 not healthy 300 s after mongo-0 was Ready"
    sleep 5
  done
  echo "RESTARTED $c $(date -u +%FT%TZ) mongo-0 $uid -> $now" | tee -a "$l7_record"
}
# envoy_counts runs as a condition, where set -e is off: each of its steps dies on its own failure.
l7_after_restart() { # <cluster>
  local c
  # Drain all harness traffic before sampling counters. Keep it paused through the
  # restart and second check; any failure exits without launching another batch.
  for c in "${clusters[@]}"; do pause_load "$c"; done
  if ! envoy_counts "$1"; then
    mongod_restart "$1"
    envoy_counts "$1" || die "$1: Cilium's Envoy still does not count mongod's searches after mongod's restart (#187)"
  fi
  for c in "${clusters[@]}"; do resume_load "$c"; done
}

upgrade() { # <cluster...>
  local c ctx secs rev done_at pid
  say "the build $CILIUM_IMAGE on every node of $*"
  for c in "$@"; do
    case " $CLUSTERS " in *" $c "*) ;; *) die "unknown cluster: $c" ;; esac
    helm get metadata cilium -n kube-system --kube-context "kind-$c" -o json >"$tmp/$c-metadata.json"
    python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["chart"] == "cilium" and m["version"] == sys.argv[2]' "$tmp/$c-metadata.json" "$CILIUM_VERSION" || die "$c: release chart must already be cilium $CILIUM_VERSION"
  done
  prepull "$@"
  # Load batches cover every upgrade and gate. RESULT times are per batch; their epoch times give the time between.
  secs=${LOAD_SECONDS:-60}
  [[ "$secs" =~ ^[1-9][0-9]*$ ]] || die "LOAD_SECONDS must be a positive batch duration"
  say "searches and majority writes through every member in $secs s batches until all gates finish"
  t0=$(date +%s)
  for c in "${clusters[@]}"; do start_load "$c"; done
  sleep 10
  for c in "$@"; do
    active_cluster=$c
    check_loads
    ctx="kind-$c"
    say "$c: the build's CRD, then the images"
    helm get values cilium --all -n kube-system --kube-context "$ctx" -o json >"$tmp/$c-before.json"
    rev=$(helm status cilium -n kube-system --kube-context "$ctx" -o json | python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])')
    printf '%s\n' "$rev" >"$tmp/$c-original-revision.txt"
    cilium_build_crd "$c"
    note "$c: CRD applied and labelled"
    # shellcheck disable=SC2154  # cilium_image_args comes from lib.sh
    helm upgrade cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system --kube-context "$ctx" --reset-then-reuse-values \
      "${cilium_image_args[@]}" --wait --timeout 10m >/dev/null || die "Helm upgrade/wait failed on $c; resources may already have changed"
    note "$c: Helm revision $rev -> $(helm status cilium -n kube-system --kube-context "$ctx" -o json | python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])')"
    helm get values cilium --all -n kube-system --kube-context "$ctx" -o json >"$tmp/$c-after.json"
    # Every value the release ran is still there, unchanged; only the image keys cilium_image_args sets differ: the
    # agent's (image) and, with CILIUM_CLUSTERMESH_IMAGE, the clustermesh-apiserver's (clustermesh.apiserver.image).
    python3 -c '
import copy, json, sys
keys = ("repository", "tag", "useDigest", "pullPolicy")
def split(v):
    v, now = copy.deepcopy(v), []
    for path in [["image"]] + [["clustermesh", "apiserver", "image"]] * (sys.argv[3] != ""):
        d = v
        for k in path[:-1]:
            d = d.get(k, {})
        img = d.get(path[-1], {})
        now.append(".".join(path) + " " + "%s:%s" % (img.get("repository"), img.get("tag")))
        for k in keys:
            img.pop(k, None)
    return v, now
(b, _), (a, now) = (split(json.load(open(f))) for f in sys.argv[1:3])
assert b == a, "values other than the image keys changed"
print("  values kept: " + ", ".join(sorted(a)) + "; now " + "; ".join(now))' \
      "$tmp/$c-before.json" "$tmp/$c-after.json" "${CILIUM_CLUSTERMESH_IMAGE:-}" || die "the upgrade on $c changed a value other than the image keys"
    gate "$c"
    l7_after_restart "$c"
    completed_clusters="$completed_clusters $c"
    check_loads
  done
  for c in "$@"; do active_cluster=$c; gate "$c"; check_loads; done
  active_cluster=none
  done_at=$(($(date +%s) - t0))
  note "upgrades and final gates done at t+${done_at}s; finishing the current load batches"
  touch "$tmp/stop-load"
  for pid in "${load_pids[@]}"; do wait "$pid" || die "a load or acknowledged-write check failed"; done
  check_loads
  for c in "${clusters[@]}"; do
    echo "  load through $c:"
    sed -n '/^RESULT /p; /^WRITES/p; /failed at/p' "$tmp/cilium-build-load-$c.txt"
  done
}

# mesh2 loses its mongot (drills.sh mongot mesh2 both, recorded as output/drill-mongot-mesh2-both-build.txt): its
# searches go to the other clusters' mongot meanwhile, so mongod's flows to a mongot in another cluster can be read.
# The flows are followed on mesh2 mongo-0's agent for the whole drill (its ring buffer may not hold a minute-old flow
# by the end). With CILIUM_SCOPE=mesh (#190) every one of them names the workload, L3/L4 and L7; otherwise none does.
drill() {
  local c=mesh2 node agent pid cross expect t
  expect=$(cross_cluster "$CILIUM_SCOPE")
  node=$(kubectl --context "kind-$c" -n mongodb get pod mongo-0 -o jsonpath='{.spec.nodeName}')
  agent=$(agent_on "$c" "$node")
  kubectl --context "kind-$c" -n kube-system exec "$agent" -c cilium-agent -- timeout 200 hubble observe --follow -o json \
    --from-cluster "$c" --from-pod mongodb/mongo-0 --to-namespace search --port 27028 >"$tmp/drill-flows.json" 2>/dev/null &
  pid=$!
  DRILL_TAG=build "$here/drills.sh" mongot "$c" both || { wait "$pid" || true; die "mongot drill failed"; }
  wait "$pid" || true
  {
    echo "== $c's search flows to another cluster's mongot during drills.sh mongot $c both, build $commit, scope $CILIUM_SCOPE ($(date -u +%Y-%m-%dT%H:%MZ))"
    echo "  to another cluster: $(named_count StatefulSet/mongot-search-0 "$c" <"$tmp/drill-flows.json") (named/flows; expected $expect named)"
    echo "  to any cluster:     $(named_count StatefulSet/mongot-search-0 <"$tmp/drill-flows.json") (named/flows, $c's own included)"
  } | tee "$out/cilium-build-drill.txt"
  cross=$(named_count StatefulSet/mongot-search-0 "$c" <"$tmp/drill-flows.json")
  # Preserve the cluster-scope drill: reused connections need not emit L3/L4.
  for t in L7 $([ "$CILIUM_SCOPE" = mesh ] && echo L3_L4); do
    [ "$(verdict "$cross" "$expect" "$t")" = PASS ] || die "cross-cluster drill: $t flows missing, or not $expect named: $cross"
  done
  # The drill measures attribution, not search reliability: 1 to 3 searches fail at the moment the mongot are deleted
  # (testing record C8, #187), so failures are reported and only a drill that answered nothing stops the run.
  sed -n 's/^RESULT //p' "$out/drill-mongot-$c-both-build-load.txt" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print("  searches during the drill: %d answered, %d failed" % (r["ok"], r["fail"])); assert r["ok"] > 0' \
    | tee -a "$out/cilium-build-drill.txt" || die "drill searches were not answered or not recorded"
}

case "${1:-}" in
  measure) measure "${2:?before or after}" ;;
  upgrade) shift; if [ $# -eq 0 ]; then upgrade mesh2 mesh1 mesh0; else upgrade "$@"; fi ;;
  drill) drill ;;
  *) echo "usage: $0 measure before|after | upgrade [cluster...] | drill" >&2; exit 2 ;;
esac
