#!/usr/bin/env bash
# Test suite for the MongoDB Search on OpenShift reference deployment.
#
#   ./test/run.sh              every suite
#   ./test/run.sh platform     one suite: platform | data | search | distribution | tls
#   SKIP_DISTRIBUTION=1 ./test/run.sh
#
# Exit 0 = all passed. Exit 1 = at least one failed. Skips never fail the run.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./mongodb/.env 2>/dev/null || true; set +a
: "${NS:=mongodb-poc}" "${DB:=platform_ops}" "${COLL:=incidents}" "${REPLICAS:=3}"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-bgp-fabric}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.crc/machines/crc/kubeconfig}"
URI="mongodb://${ROOT_USER:-labAdmin}:${ROOT_PASSWORD:-x}@localhost:${PORT1:-27017}/admin?directConnection=true"

PASS=0 FAIL=0 SKIP=0; FAILED=()
C_OK=$'\033[32m'; C_NO=$'\033[31m'; C_SK=$'\033[33m'; C_DIM=$'\033[2m'; C_0=$'\033[0m'
[ -t 1 ] || { C_OK= C_NO= C_SK= C_DIM= C_0=; }

suite() { printf "\n${C_DIM}── %s ──────────────────────────────────────${C_0}\n" "$1"; }
ok()   { PASS=$((PASS+1)); printf "  ${C_OK}PASS${C_0}  %-52s %s\n" "$1" "${2:-}"; }
no()   { FAIL=$((FAIL+1)); FAILED+=("$1"); printf "  ${C_NO}FAIL${C_0}  %-52s %s\n" "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf "  ${C_SK}SKIP${C_0}  %-52s %s\n" "$1" "${2:-}"; }
# assert_eq NAME EXPECTED ACTUAL
assert_eq() { [ "$2" = "$3" ] && ok "$1" "$3" || no "$1" "expected '$2', got '$3'"; }
# assert_contains NAME NEEDLE HAYSTACK
assert_contains() { case "$3" in *"$2"*) ok "$1" "$2";; *) no "$1" "'$2' not in: ${3:0:70}";; esac; }
mongo() { docker exec -i mongo1 mongosh "$URI" --quiet --eval "$1" 2>/dev/null | tr -d '\r'; }

WANT="${1:-all}"
want() { [ "$WANT" = "all" ] || [ "$WANT" = "$1" ]; }

# ─── platform ────────────────────────────────────────────────────────────────
if want platform; then suite "platform"
  assert_eq "MongoDBSearch phase is Running" "Running" \
    "$(oc get mongodbsearch mongot -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)"
  assert_eq "all $REPLICAS mongot pods Ready" "$REPLICAS" \
    "$(oc get pods -n "$NS" --no-headers 2>/dev/null | awk '$1 ~ /^mongot-search-0-[0-9]+$/ && $2=="1/1" && $3=="Running"' | wc -l | tr -d ' ')"
  ENVOY=$(oc get pods -n "$NS" -l app=mongot-search-lb-0 --no-headers 2>/dev/null | awk '$2=="1/1" && $3=="Running"' | wc -l | tr -d ' ')
  [ "${ENVOY:-0}" -ge 1 ] && ok "Envoy replicas Running" "$ENVOY" || no "Envoy replicas Running" "got $ENVOY"
  assert_eq "headless Service has $REPLICAS ready endpoints" "$REPLICAS" \
    "$(oc get endpointslice -n "$NS" -l kubernetes.io/service-name=mongot-search-0-svc \
        -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null | grep -c true)"
  SEL=$(oc get svc mongot-grpc-lb -n "$NS" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
  case "$SEL" in mongot-search-lb-*) ok "entry Service selects the Envoy pods" "$SEL";;
    "") skip "entry Service selects the Envoy pods" "mongot-grpc-lb absent";;
    *) no "entry Service selects the Envoy pods" "selects '$SEL' - L7 IS BYPASSED";; esac
  assert_eq "external replica set has a PRIMARY" "1" \
    "$(mongo 'print(rs.status().members.filter(m=>m.stateStr=="PRIMARY").length)')"
fi

# ─── data ────────────────────────────────────────────────────────────────────
if want data; then suite "data"
  N=$(mongo "print(db.getSiblingDB('$DB').$COLL.countDocuments({}))")
  [ "${N:-0}" -ge 20 ] && ok "incident corpus loaded" "$N docs" || no "incident corpus loaded" "got ${N:-0}"
  assert_eq "both search indexes queryable" "2" \
    "$(mongo "print(db.getSiblingDB('$DB').$COLL.getSearchIndexes().filter(i=>i.queryable===true).length)")"
  assert_eq "every incident has a 6-dim embedding" "0" \
    "$(mongo "print(db.getSiblingDB('$DB').$COLL.countDocuments({\$expr:{\$ne:[{\$size:'\$embedding'},6]}}))")"
fi

# ─── search: the use case ────────────────────────────────────────────────────
if want search; then suite "search - keyword and semantic recall"
  T() { mongo "print(db.getSiblingDB('$DB').$COLL.aggregate([{\$search:{index:'incidents_text',text:{query:'$1',path:{wildcard:'*'}}}},{\$project:{incident_id:1}},{\$limit:${2:-3}}]).toArray().map(x=>x.incident_id).join(','))"; }
  V() { mongo "print(db.getSiblingDB('$DB').$COLL.aggregate([{\$vectorSearch:{index:'incidents_vector',path:'embedding',queryVector:[$1],numCandidates:50,limit:${2:-3}}},{\$project:{incident_id:1}}]).toArray().map(x=>x.incident_id).join(','))"; }

  assert_contains "keyword finds an exact term"        "INC-1002" "$(T 'CrashLoopBackOff')"
  assert_contains "keyword finds a distinctive phrase" "INC-1022" "$(T 'persistentVolumeClaimRetentionPolicy')"

  # the use case: a paraphrase sharing no distinctive vocabulary
  PARA=$(T 'everything hitting a single instance')
  case "$PARA" in *INC-1051*) no "keyword MISSES the paraphrase (expected)" "unexpectedly found it";;
    *) ok "keyword misses the paraphrase" "got ${PARA:-none}";; esac
  assert_contains "vector finds it from intent alone"  "INC-1051" "$(V '0.4,0.4,0,0,0,0.95')"

  assert_contains "vector groups the TLS domain"       "INC-1031" "$(V '0,0.2,0,0.97,0.05,0.02')"
  assert_contains "vector groups the storage domain"   "INC-1022" "$(V '0.3,0,0.95,0,0,0.05')"

  # filters must actually filter
  F=$(mongo "print(db.getSiblingDB('$DB').$COLL.aggregate([{\$vectorSearch:{index:'incidents_vector',path:'embedding',queryVector:[0,0.2,0,0.97,0.05,0.02],numCandidates:50,limit:5,filter:{component:{\$eq:'storage'}}}},{\$project:{component:1}}]).toArray().map(x=>x.component).join(','))")
  case "$F" in *tls*|*network*) no "vector filter excludes other components" "leaked: $F";;
    "") no "vector filter excludes other components" "no results";;
    *) ok "vector filter excludes other components" "$F";; esac

  # recall@3: each domain's probe vector should return that domain's incidents
  for pair in "scheduling:0.95,0.1,0.1,0,0.05,0.2" "network:0.1,0.96,0,0.15,0.05,0.2" \
              "storage:0.3,0,0.95,0,0,0.05" "tls:0,0.2,0,0.97,0.05,0.02" \
              "auth:0.1,0.05,0,0.2,0.95,0" "performance:0.4,0.4,0,0,0,0.95"; do
    d=${pair%%:*}; v=${pair#*:}
    got=$(mongo "print(db.getSiblingDB('$DB').$COLL.aggregate([{\$vectorSearch:{index:'incidents_vector',path:'embedding',queryVector:[$v],numCandidates:50,limit:3}},{\$project:{component:1}}]).toArray().map(x=>x.component).join(','))")
    hits=$(printf '%s' "$got" | tr ',' '\n' | grep -c "^$d$")
    [ "${hits:-0}" -ge 2 ] && ok "vector recall@3 for '$d'" "$hits/3" \
                           || no "vector recall@3 for '$d'" "$hits/3 - got $got"
  done

  # a query with no lexical match must return nothing, not noise
  assert_eq "keyword returns nothing for a nonsense term" "" "$(T 'zzzqqxnonsense')"
  # an impossible filter must return nothing rather than ignoring the filter
  assert_eq "an unsatisfiable filter returns nothing" "" \
    "$(mongo "print(db.getSiblingDB('$DB').$COLL.aggregate([{\$vectorSearch:{index:'incidents_vector',path:'embedding',queryVector:[0.4,0.4,0,0,0,0.95],numCandidates:50,limit:5,filter:{severity:{\$eq:'nonexistent'}}}},{\$project:{_id:1}}]).toArray().length||'')")"
fi

# --- entry path: Route or MetalLB VIP ----------------------------------------
if want entry; then suite "entry path"
  EPS=""
  for n in 1 2 3; do
    pn=$(eval echo "\${PORT$n:-}"); [ -z "$pn" ] && continue
    h=$(docker exec -i "mongo$n" mongosh "mongodb://${ROOT_USER}:${ROOT_PASSWORD}@localhost:$pn/admin?directConnection=true" \
          --quiet --eval 'print((db.adminCommand({getParameter:1,mongotHost:1}).mongotHost)||"")' 2>/dev/null | tr -d '\r')
    EPS="$EPS$h\n"
  done
  UNIQ=$(printf "$EPS" | grep . | sort -u); NU=$(printf '%s\n' "$UNIQ" | grep -c .)
  assert_eq "every mongod agrees on mongotHost" "1" "$NU"
  [ -n "$UNIQ" ] && ok "mongotHost is set" "$UNIQ" || no "mongotHost is set" "unset"

  assert_eq "mongod requires TLS to the search head" "requireTLS" \
    "$(docker exec -i mongo1 mongosh "mongodb://${ROOT_USER}:${ROOT_PASSWORD}@localhost:${PORT1}/admin?directConnection=true" \
        --quiet --eval 'print(db.adminCommand({getCmdLineOpts:1}).parsed.setParameter.searchTLSMode||"")' 2>/dev/null | tr -d '\r')"
  assert_eq "mongod uses gRPC for search" "true" \
    "$(docker exec -i mongo1 mongosh "mongodb://${ROOT_USER}:${ROOT_PASSWORD}@localhost:${PORT1}/admin?directConnection=true" \
        --quiet --eval 'print(db.adminCommand({getCmdLineOpts:1}).parsed.setParameter.useGrpcForSearch||"")' 2>/dev/null | tr -d '\r')"

  # Both entry paths terminate on the SAME Envoy and share ONE certificate, because a
  # ReplicaSet source gets exactly one SNI name. Verify each path end to end at the TLS
  # layer, and that a non-matching SNI is genuinely refused rather than quietly accepted.
  EH=$(oc get mongodbsearch mongot -n "$NS" \
        -o jsonpath='{.spec.clusters[0].loadBalancer.managed.externalHostname}' 2>/dev/null)
  VIPPORT=$(oc get svc mongot-grpc-lb -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
  tls_cn() {  # host:port SNI -> the CN served, or empty if no certificate was served
    echo | openssl s_client -connect "$1" -servername "$2" -alpn h2 2>/dev/null \
      | sed -n 's/.*subject=CN *= *\([^ ,]*\).*/\1/p' | head -1
  }
  if [ -n "$EH" ]; then
    assert_eq "Route path serves the Envoy certificate" "$EH" "$(tls_cn "$EH:443" "$EH")"
    if [ -n "$VIPPORT" ]; then
      assert_eq "MetalLB VIP path serves the SAME certificate" "$EH" "$(tls_cn "$EH:$VIPPORT" "$EH")"
    else
      skip "MetalLB VIP path serves the SAME certificate" "mongot-grpc-lb absent"
    fi
    # The spare SAN must NOT work as an SNI: on the VIP path Envoy closes the handshake
    # and serves nothing. (On :443 the router answers with its own wildcard cert instead,
    # which is why this is asserted against the VIP path, not the Route.)
    SPARE="vip-$EH"
    if [ -n "$VIPPORT" ]; then
      assert_eq "a non-matching SNI is refused by Envoy" "" "$(tls_cn "$EH:$VIPPORT" "$SPARE")"
    else
      skip "a non-matching SNI is refused by Envoy" "mongot-grpc-lb absent"
    fi
    # The Route must target a Service we own. The operator's mongot-search-0-proxy-svc
    # works too, but it is owner-referenced by the CR and named after it, so the ingress
    # contract would break when the CR is renamed or recreated.
    assert_eq "the Route targets our own Service" "mongot-search-lb" \
      "$(oc get route mongot-grpc -n "$NS" -o jsonpath='{.spec.to.name}' 2>/dev/null)"
    # Guard the bypass: the Route's target must resolve to the ENVOY pod IPs. Pointing it
    # at the headless mongot-search-0-svc would look plausible - same namespace, same port,
    # also headless - but it selects the mongot pods and skips the L7 entirely.
    RT=$(oc get route mongot-grpc -n "$NS" -o jsonpath='{.spec.to.name}' 2>/dev/null)
    RT_EPS=$(oc get endpointslice -n "$NS" -l kubernetes.io/service-name="$RT" \
              -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}' 2>/dev/null | sort | tr '\n' ' ')
    ENVOY_EPS=$(oc get pods -n "$NS" -l app=mongot-search-lb-0 \
                 -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null | sort | tr '\n' ' ')
    MONGOT_EPS=$(oc get pods -n "$NS" -l app=mongot-search-0-svc \
                  -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null | sort | tr '\n' ' ')
    if [ "$RT_EPS" = "$MONGOT_EPS" ] && [ -n "$MONGOT_EPS" ]; then
      no "the Route resolves to Envoy, not mongot" "it points straight at the mongot pods - the L7 is bypassed"
    else
      assert_eq "the Route resolves to Envoy, not mongot" "$ENVOY_EPS" "$RT_EPS"
    fi
    assert_eq "that Service selects the Envoy pods" \
      "$(oc get pods -n "$NS" -l app=mongot-search-lb-0 --no-headers 2>/dev/null | wc -l | tr -d ' ')" \
      "$(oc get endpointslice -n "$NS" -l kubernetes.io/service-name=mongot-search-lb \
          -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null | grep -c true)"
    # Every Envoy replica must be reachable through BOTH entry Services. The label
    # app=<name>-search-lb-<clusterIndex> carries the CLUSTER index, not a replica index,
    # so raising loadBalancer.managed.replicas adds pods under the same label. This
    # asserts that rather than assuming it.
    NREPL=$(oc get mongodbsearch mongot -n "$NS" \
             -o jsonpath='{.spec.clusters[0].loadBalancer.managed.replicas}' 2>/dev/null)
    NREPL=${NREPL:-1}
    assert_eq "Envoy Deployment runs the declared replica count" "$NREPL" \
      "$(oc get deploy mongot-search-lb-0 -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    for svc in mongot-search-lb mongot-grpc-lb; do
      got=$(oc get endpointslice -n "$NS" -l kubernetes.io/service-name=$svc \
             -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null | grep -c true)
      if [ -z "$(oc get svc "$svc" -n "$NS" --no-headers 2>/dev/null)" ]; then
        skip "$svc reaches every Envoy replica" "Service absent"
      else
        assert_eq "$svc reaches every Envoy replica" "$NREPL" "$got"
      fi
    done
    # The Route is passthrough: it holds no key material and cannot terminate TLS.
    assert_eq "the Route carries no key material (cannot terminate)" "" \
      "$(oc get route mongot-grpc -n "$NS" -o jsonpath='{.spec.tls.certificate}{.spec.tls.key}' 2>/dev/null)"
    # TLS terminates on the component the MongoDBSearch CR owns, not on the router.
    assert_contains "the terminating Deployment is owned by MongoDBSearch" "MongoDBSearch" \
      "$(oc get deploy mongot-search-lb-0 -n "$NS" -o jsonpath='{.metadata.ownerReferences[*].kind}' 2>/dev/null)"
    # And the certificate served is the enterprise-CA one - never the ingress wildcard.
    SERVED=$(echo | openssl s_client -connect "$EH:443" -servername "$EH" -alpn h2 2>/dev/null \
             | openssl x509 -noout -issuer 2>/dev/null)
    assert_contains "the served cert is issued by the enterprise CA" "Enterprise Root CA" "$SERVED"
    SUBJ=$(echo | openssl s_client -connect "$EH:443" -servername "$EH" -alpn h2 2>/dev/null \
           | openssl x509 -noout -subject 2>/dev/null)
    case "$SUBJ" in
      *"CN = *."*|*"CN=*."*) no "the served cert is not a wildcard" "$SUBJ";;
      *) ok "the served cert is not a wildcard" "${SUBJ#subject=}";;
    esac
    assert_contains "the spare VIP SAN is on the certificate" "$SPARE" \
      "$(oc get secret "${PFX:-lab}-mongot-search-lb-0-cert" -n "$NS" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
         | base64 -d 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null)"
  fi

  EIPS=$(oc get pods -n "$NS" -l app=mongot-search-lb-0 -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | grep .)
  RP=$(oc get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default -o name 2>/dev/null | head -1)
  RC=0
  if [ -n "$RP" ] && [ -n "$EIPS" ]; then
    PAT=$(printf '%s' "$EIPS" | tr '\n' '|' | sed 's/|$//')
    RC=$(oc rsh -n openshift-ingress "$RP" sh -c "ss -tn state established 2>/dev/null" 2>/dev/null | grep -Ec "($PAT):27028" || true)
  fi
  if [ "${RC:-0}" -gt 0 ]; then
    ok "entry path identified" "OpenShift Route ($RC established router->Envoy)"
    assert_contains "the Route is passthrough (edge/reencrypt break HTTP/2)" "passthrough" \
      "$(oc get route -n "$NS" -o jsonpath='{range .items[*]}{.spec.tls.termination}{" "}{end}' 2>/dev/null)"
    BLK=$(oc rsh -n openshift-ingress "$RP" sh -c \
      "awk '/^backend be_tcp:$NS:/{f=1} f&&/^backend /&&!/be_tcp:$NS:/{f=0} f' /var/lib/haproxy/conf/haproxy.config" 2>/dev/null | tr -d '\r')
    # The passthrough DEFAULT is `balance source`, which is degenerate when every client
    # arrives through one ingress path: HAProxy sees a single peer address and pins every
    # connection to one Envoy. The Route sets the balance annotation to correct that.
    ANN=$(oc get route mongot-grpc -n "$NS" \
            -o jsonpath='{.metadata.annotations.haproxy\.router\.openshift\.io/balance}' 2>/dev/null)
    assert_eq "the Route declares a balance algorithm" "roundrobin" "$ANN"
    assert_eq "HAProxy applied the annotated algorithm" "balance ${ANN:-source}" \
      "$(printf '%s\n' "$BLK" | awk '/^ *balance /{print; exit}' | xargs)"
    NSRV=$(printf '%s\n' "$BLK" | grep -c '^ *server ' || true)
    assert_eq "every Envoy replica is a Route backend" \
      "$(oc get pods -n "$NS" -l app=mongot-search-lb-0 --no-headers 2>/dev/null | wc -l | tr -d ' ')" "$NSRV"
  else
    ok "entry path identified" "MetalLB VIP (no router->Envoy connection)"
    assert_contains "the VIP Service is a LoadBalancer with an address" "." \
      "$(oc get svc mongot-grpc-lb -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
  fi
fi

# --- attribution: who actually answered --------------------------------------
if want attribution && [ -z "${SKIP_DISTRIBUTION:-}" ]; then suite "per-request attribution"
  BUSY=0; IDLE=0
  for p in $(oc get pods -n "$NS" -l app=mongot-search-lb-0 -o jsonpath='{.items[*].metadata.name}'); do
    n=$(oc logs -n "$NS" "$p" 2>/dev/null | grep -c '"upstream_host"' || true)
    [ "${n:-0}" -gt 0 ] && BUSY=$((BUSY+1)) || IDLE=$((IDLE+1))
  done
  [ "$BUSY" -ge 1 ] && ok "at least one Envoy is logging requests" "$BUSY busy / $IDLE idle" \
                    || no "at least one Envoy is logging requests" "none are"

  # Envoy logs one line per gRPC request, naming the pod that served it.
  OUT=$(FLUSH_WAIT=20 ./app/trace-query.sh -q -n 6 "pods" 2>/dev/null)
  SEEN=$(printf '%s\n' "$OUT" | grep -c '^  mongot-search-0-' || true)
  assert_eq "all $REPLICAS pods appear in a 6-query census" "$REPLICAS" "$SEEN"
  assert_contains "the census accounts for every query" "over 6 queries" "$OUT"
  ERR=$(oc logs -n "$NS" -l app=mongot-search-lb-0 --since=10m 2>/dev/null \
        | grep '"upstream_host"' | grep -vc '"grpc_status":"OK"' || true)
  assert_eq "no non-OK gRPC status in the last 10m" "0" "${ERR:-0}"
fi

# --- alerting ----------------------------------------------------------------
if want alerts; then suite "alerting rules"
  RULES=$(oc exec -n openshift-user-workload-monitoring thanos-ruler-user-workload-0 -c thanos-ruler -- \
    curl -s http://localhost:10902/api/v1/rules 2>/dev/null)
  if [ -z "$RULES" ]; then skip "rules loaded" "Thanos Ruler unreachable"; else
    # In OpenShift UWM a user PrometheusRule is evaluated by Thanos Ruler, NOT by
    # prometheus-user-workload, unless labelled prometheus-rule-evaluation-scope:
    # leaf-prometheus. Querying the wrong component reports a healthy rule missing.
    G=$(printf '%s' "$RULES" | python3 -c "
import json,sys
d=json.load(sys.stdin)
g=[x for x in d['data']['groups'] if x['name']=='mongot.distribution']
if not g: print('0 0'); raise SystemExit
r=g[0]['rules']
print(len(r), sum(1 for x in r if x.get('health')=='ok'))" 2>/dev/null)
    TOTR=${G%% *}; OKR=${G##* }
    [ "${TOTR:-0}" -eq 7 ] && ok "mongot.distribution rule group loaded" "$TOTR rules" \
                           || no "mongot.distribution rule group loaded" "got ${TOTR:-0}, expected 7"
    assert_eq "every rule evaluates without error" "${TOTR:-0}" "${OKR:-0}"
  fi
fi

# ─── distribution: the architecture's whole point ────────────────────────────
if want distribution && [ -z "${SKIP_DISTRIBUTION:-}" ]; then suite "distribution across mongot"
  TB=$(oc get pods -n "$NS" -l app=mongot-toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$TB" ]; then skip "per-pod distribution" "toolbox pod absent"; else
    ctr() { oc exec -n "$NS" "$TB" -- sh -c "
      for i in \$(seq 0 \$(( $REPLICAS - 1 ))); do
        curl -s --max-time 4 http://mongot-search-0-\$i.mongot-search-0-svc:9946/metrics 2>/dev/null \
          | grep '^mongot_command_searchCommandTotalLatency_seconds_count' | awk '{print \$2}'
      done" 2>/dev/null | tr '\n' ' '; }
    B=($(ctr))
    mongo "const d=db.getSiblingDB('$DB'); for(let i=0;i<30;i++){d.$COLL.aggregate([{\$search:{index:'incidents_text',text:{query:'pods',path:{wildcard:'*'}}}},{\$project:{_id:1}}]).toArray();} print('done')" >/dev/null
    A=($(ctr))
    TOT=0 USED=0 LINE=""
    for i in $(seq 0 $((REPLICAS-1))); do
      d=$(( ${A[$i]%.*} - ${B[$i]%.*} )); TOT=$((TOT+d)); [ "$d" -gt 0 ] && USED=$((USED+1))
      LINE="$LINE $d"
    done
    [ "$TOT" -ge 30 ] && ok "all 30 queries accounted for" "$TOT" || no "all 30 queries accounted for" "$TOT"
    assert_eq "every mongot replica served some" "$REPLICAS" "$USED"
    MAX=$(printf '%s\n' $LINE | sort -rn | head -1)
    if [ "$TOT" -gt 0 ] && [ $((MAX*100/TOT)) -lt 70 ]; then
      ok "no single pod dominates" "split:$LINE"
    else
      no "no single pod dominates" "split:$LINE - the L7 may be bypassed"
    fi
  fi
elif want distribution; then suite "distribution across mongot"; skip "per-pod distribution" "SKIP_DISTRIBUTION set"
fi

# ─── tls ─────────────────────────────────────────────────────────────────────
if want tls; then suite "tls"
  PFX=$(oc get mongodbsearch mongot -n "$NS" -o jsonpath='{.spec.security.tls.certsSecretPrefix}' 2>/dev/null)
  if [ -z "$PFX" ]; then
    skip "TLS enabled" "security.tls not set - running plaintext"
  else
    ok "TLS enabled" "certsSecretPrefix=$PFX"
    CA=$(oc get mongodbsearch mongot -n "$NS" -o jsonpath='{.spec.source.external.tls.ca.name}' 2>/dev/null)
    [ -n "$CA" ] && ok "source CA set (Envoy cert mounts depend on it)" "$CA" \
                 || no "source CA set (Envoy cert mounts depend on it)" "missing - Envoy certs will NOT mount"
    MNT=$(oc get pods -n "$NS" -l app=mongot-search-lb-0 \
      -o jsonpath='{.items[0].spec.containers[0].volumeMounts[*].name}' 2>/dev/null)
    assert_contains "Envoy mounts its server certificate" "envoy-server-cert" "$MNT"
    SAN=$(oc get secret "$PFX-mongot-search-lb-0-cert" -n "$NS" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
          | base64 -d 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null)
    EH=$(oc get mongodbsearch mongot -n "$NS" -o jsonpath='{.spec.clusters[0].loadBalancer.managed.externalHostname}' 2>/dev/null)
    assert_contains "Envoy cert covers externalHostname" "$EH" "$SAN"
    EP=$(grep '^MONGOT_ENDPOINT=' mongodb/.env 2>/dev/null | cut -d= -f2)
    case "${EP%%:*}" in ''|*[a-zA-Z]*) ok "mongotHost is a hostname, not an IP" "${EP:-unset}";;
      *) no "mongotHost is a hostname, not an IP" "$EP - TLS clients send no SNI for an IP";; esac
  fi
fi

printf "\n────────────────────────────────────────────────────────\n"
printf "  ${C_OK}%d passed${C_0}   ${C_NO}%d failed${C_0}   ${C_SK}%d skipped${C_0}\n" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -gt 0 ] && { printf "\n  failed:\n"; printf "    - %s\n" "${FAILED[@]}"; exit 1; }
exit 0
