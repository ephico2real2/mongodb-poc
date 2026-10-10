#!/usr/bin/env bash
# A load test of search through mongod, and what the managed Envoy and the mongot pods do under it.
#
#   export TargetNamespace=<the namespace of the MongoDBSearch>      # there is no default
#   export URI_SECRET=<a Secret there whose key "uri" holds a connection string of the source deployment>
#   test/load/run.sh <tag> <steps> <seconds a step> [pause between steps]
#   python3 test/load/analyze.py <out dir>/<tag>
#
#   test/load/run.sh first 1,2,4,8,16,32,64 60 15
#
# It runs a Job (search-load) that sends concurrent $search queries through mongod, in steps of concurrency, and
# about every 10 s reads from each Envoy pod, each mongot pod and the load pod their cgroup's CPU counters and
# memory: a plain cat inside the pod. It changes nothing but that Job and its ConfigMap, which stay for an hour.
# It writes <out dir>/<tag>.load (one JSON line a step), <tag>.samples and <tag>.log; analyze.py makes one row a
# step of them.
#
# Other settings, all from the environment: URI_KEY (uri), CA_CONFIGMAP (ent-trust-bundle, mounted at
# /etc/mongo-ca for a connection string that names /etc/mongo-ca/ca.crt), SEARCH_NAME (mongot), IMAGE (the stock
# MongoDB Community Server image, for its mongosh), OUT (the current directory), and for the queries DB
# (sample_mflix), COLL (movies), INDEX (default), TERMS (eight words), LIMIT (10).
# The connection string is read by the Job from the Secret; this script never sees it.
#
# Needs oc, logged in, with the right to create a Job and a ConfigMap and to exec into the pods.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
die() { printf '%s: %s\n' "$(basename "$0")" "$*" >&2; exit 1; }
[[ $# -ge 3 ]] || { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//' >&2; exit 1; }
NS="${TargetNamespace:-}"; [[ -n "${NS}" ]] || die "no namespace: export TargetNamespace=<ns>"
[[ "${NS}" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "not a namespace name: ${NS}"
[[ -n "${URI_SECRET:-}" ]] || die "no Secret: export URI_SECRET=<a Secret in ${NS} whose key holds a connection string>"
tag="$1"; steps="$2"; secs="$3"; pause="${4:-15}"
[[ "${steps}" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "steps are numbers with commas: ${steps}"
[[ "${secs}" =~ ^[0-9]+$ && "${pause}" =~ ^[0-9]+$ ]] || die "seconds and pause are whole numbers"
SEARCH="${SEARCH_NAME:-mongot}"; OUT="${OUT:-.}"
IMAGE="${IMAGE:-quay.io/mongodb/mongodb-community-server:8.3.4-ubi9}"
command -v oc >/dev/null 2>&1 || die "oc is not on the PATH"
oc whoami >/dev/null 2>&1 || die "oc is not logged in to a cluster"
oc get secret "${URI_SECRET}" -n "${NS}" -o name >/dev/null 2>&1 || die "no Secret ${URI_SECRET} in ${NS}"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
cg() {  # <pod> <container>: the cgroup's counters on one line
  oc exec -n "${NS}" "$1" -c "$2" -- cat /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/memory.current /sys/fs/cgroup/cpu.max 2>/dev/null </dev/null \
    | awk '$1=="usage_usec"{u=$2} $1=="nr_periods"{p=$2} $1=="nr_throttled"{t=$2} $1=="throttled_usec"{tu=$2}
           NF==1{mem=$1} NF==2 && ($1=="max" || $1 ~ /^[0-9]+$/) && $2 ~ /^[0-9]+$/{mx=$1 "/" $2}
           END{printf "usage_usec=%s periods=%s throttled=%s throttled_usec=%s mem=%s cpu_max=%s", u, p, t, tu, mem, mx}' || true
}

: > "${OUT}/${tag}.samples"
{
  echo "$(now) namespace ${NS} on $(oc whoami --show-server), steps ${steps}, ${secs} s each"
  oc get deployment "${SEARCH}-search-lb-0" -n "${NS}" -o jsonpath='envoy: {.spec.replicas} pods, resources {.spec.template.spec.containers[0].resources}{"\n"}'
  oc get statefulset "${SEARCH}-search-0" -n "${NS}" -o jsonpath='mongot: {.spec.replicas} pods, resources {.spec.template.spec.containers[0].resources}{"\n"}'
} | tee "${OUT}/${tag}.log"

oc create configmap search-load -n "${NS}" --from-file=load.js="${HERE}/search-load.js" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc delete job search-load -n "${NS}" --ignore-not-found --wait=true >/dev/null 2>&1
oc apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: search-load, namespace: ${NS}, labels: {app: search-load}}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata: {labels: {app: search-load}}
    spec:
      restartPolicy: Never
      securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: load
          image: ${IMAGE}
          command: ["mongosh", "--nodb", "--quiet", "--file", "/load/load.js"]
          env:
            - {name: MONGO_URI, valueFrom: {secretKeyRef: {name: "${URI_SECRET}", key: "${URI_KEY:-uri}"}}}
            - {name: STEPS, value: "${steps}"}
            - {name: SECONDS, value: "${secs}"}
            - {name: PAUSE, value: "${pause}"}
            - {name: DB, value: "${DB:-sample_mflix}"}
            - {name: COLL, value: "${COLL:-movies}"}
            - {name: INDEX, value: "${INDEX:-default}"}
            - {name: TERMS, value: "${TERMS:-detective,love,war,space,family,murder,king,night}"}
            - {name: LIMIT, value: "${LIMIT:-10}"}
            - {name: HOME, value: /tmp}
          resources: {requests: {cpu: 200m, memory: 192Mi}, limits: {cpu: "2", memory: 768Mi}}
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          volumeMounts: [{name: load, mountPath: /load}, {name: mongo-ca, mountPath: /etc/mongo-ca}]
      volumes:
        - {name: load, configMap: {name: search-load}}
        - {name: mongo-ca, configMap: {name: "${CA_CONFIGMAP:-ent-trust-bundle}"}}
EOF

envoys="$(oc get pods -n "${NS}" -l "app=${SEARCH}-search-lb-0" -o jsonpath='{range .items[*]}{.metadata.name} {end}')"
mongots="$(oc get pods -n "${NS}" -l "app=${SEARCH}-search-0-svc" -o jsonpath='{range .items[*]}{.metadata.name} {end}')"
n="$(tr ',' '\n' <<<"${steps}" | grep -c .)"; limit=$(( $(date +%s) + n * (secs + pause) + 180 ))
while [[ "$(date +%s)" -lt "${limit}" ]]; do
  t="$(now)"
  for p in ${envoys}; do echo "${t} envoy ${p##*-} $(cg "$p" envoy)" >> "${OUT}/${tag}.samples"; done
  for p in ${mongots}; do echo "${t} mongot ${p##*-} $(cg "$p" mongot)" >> "${OUT}/${tag}.samples"; done
  lp="$(oc get pods -n "${NS}" -l app=search-load -o jsonpath='{.items[0].metadata.name}' 2>/dev/null </dev/null || true)"
  [[ -z "${lp}" ]] || echo "${t} load ${lp##*-} $(cg "$lp" load)" >> "${OUT}/${tag}.samples"
  [[ -z "$(oc get job search-load -n "${NS}" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null </dev/null)" ]] || break
  sleep 5
done
oc logs job/search-load -n "${NS}" -c load > "${OUT}/${tag}.load" 2>/dev/null || true
tee -a "${OUT}/${tag}.log" < "${OUT}/${tag}.load"
echo "$(now) done. Envoy pods now: $(oc get pods -n "${NS}" -l "app=${SEARCH}-search-lb-0" -o jsonpath='{range .items[*]}{.metadata.name} restarts {.status.containerStatuses[0].restartCount}; {end}')" | tee -a "${OUT}/${tag}.log"
echo "next: python3 ${HERE}/analyze.py ${OUT}/${tag}"
