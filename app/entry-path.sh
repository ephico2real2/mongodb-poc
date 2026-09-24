#!/usr/bin/env bash
# Which entry path is mongod actually using as its search head:
# the OpenShift Route, or the MetalLB VIP?
#
#   ./app/entry-path.sh
#
# Both paths can exist at once and both terminate on the same Envoy pods, so the
# port number alone is a guess. This walks the chain and proves it at the hop that
# can only be carrying traffic on one of them:
#
#   mongotHost -> DNS -> the hop that holds the TCP connection -> Envoy -> mongot
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./mongodb/.env 2>/dev/null || true; set +a
: "${NS:=mongodb-poc}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.crc/machines/crc/kubeconfig}"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-bgp-fabric}"
C_B=$'\033[1m'; C_D=$'\033[2m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
[ -t 1 ] || { C_B= C_D= C_G= C_Y= C_0=; }
step() { printf "\n${C_B}%s${C_0}\n" "$1"; }

step "1. mongotHost, read from the running mongod"
HOSTS=""
for n in 1 2 3; do
  p=$(eval echo "\${PORT$n:-}"); [ -z "$p" ] && continue
  h=$(docker exec -i "mongo$n" mongosh \
        "mongodb://${ROOT_USER}:${ROOT_PASSWORD}@localhost:$p/admin?directConnection=true" --quiet \
        --eval 'const r=db.adminCommand({getParameter:1,mongotHost:1}); print(r.mongotHost||"")' 2>/dev/null | tr -d '\r')
  printf "   mongo%s (%s): %s\n" "$n" "$p" "${h:-<unset>}"
  HOSTS="$HOSTS$h "
done
EP=$(printf '%s' "$HOSTS" | tr ' ' '\n' | grep . | sort -u)
[ "$(printf '%s\n' "$EP" | grep -c .)" -gt 1 ] && printf "   ${C_Y}the replica set disagrees on mongotHost${C_0}\n"
HOST="${EP%%:*}"; PORT="${EP##*:}"
[ -z "$HOST" ] && { echo "   no mongotHost set - mongod is not wired to a search head"; exit 1; }

step "2. what that name resolves to, from inside the mongod container"
RES=$(docker exec -i mongo1 sh -c "getent hosts $HOST 2>/dev/null | head -1" | awk '{print $1}')
printf "   %s -> ${C_B}%s${C_0}  port %s\n" "$HOST" "${RES:-<unresolved>}" "$PORT"

step "3. the candidate paths that exist on this cluster"
VIP=$(oc get svc -n "$NS" -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[0].ip}{" "}{.spec.ports[0].port}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v '^ ')
printf "   MetalLB VIP : %s\n" "${VIP:-<none>}"
RT=$(oc get route -n "$NS" -o jsonpath='{range .items[*]}{.spec.host}{" -> "}{.spec.port.targetPort}{" ("}{.spec.tls.termination}{")\n"}{end}' 2>/dev/null | grep -v '^ -> ')
printf "   Route       : %s\n" "$(printf '%s' "$RT" | head -1)"

step "4. which hop is actually holding the connection"
ENVOY_IPS=$(oc get pods -n "$NS" -l app=mongot-search-lb-0 -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | grep .)
R=$(oc get pods -n openshift-ingress \
      -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default -o name 2>/dev/null | head -1)
ROUTER_CONNS=0
if [ -n "$R" ] && [ -n "$ENVOY_IPS" ]; then
  PAT=$(printf '%s' "$ENVOY_IPS" | tr '\n' '|' | sed 's/|$//')
  ROUTER_CONNS=$(oc rsh -n openshift-ingress "$R" sh -c "ss -tn state established 2>/dev/null" 2>/dev/null \
                 | grep -Ec "($PAT):27028" || true)
fi
printf "   router -> Envoy established TCP : ${C_B}%s${C_0}\n" "$ROUTER_CONNS"

if [ "${ROUTER_CONNS:-0}" -gt 0 ]; then
  VERDICT="OpenShift Route"; WHY="the router pod is holding $ROUTER_CONNS established connection(s) to the Envoy pods"
else
  VERDICT="MetalLB VIP"; WHY="the router holds no connection to Envoy, so traffic is not traversing the Route"
fi

step "5. verdict"
printf "   mongod reaches mongot through the ${C_G}${C_B}%s${C_0}\n" "$VERDICT"
printf "   ${C_D}%s${C_0}\n" "$WHY"

if [ "$VERDICT" = "OpenShift Route" ]; then
  # Scope to this namespace's TCP backend block: haproxy.config holds every route
  # on the cluster, so an unscoped grep counts the whole ingress estate.
  BLOCK=$(oc rsh -n openshift-ingress "$R" sh -c \
    "awk '/^backend be_tcp:$NS:/{f=1} f&&/^backend /&&!/be_tcp:$NS:/{f=0} f' /var/lib/haproxy/conf/haproxy.config" 2>/dev/null | tr -d '\r')
  BAL=$(printf '%s\n' "$BLOCK" | awk '/^ *balance /{print; exit}' | xargs)
  SRV=$(printf '%s\n' "$BLOCK" | grep -c '^ *server ' || true)
  step "6. what the Route does to the connection"
  printf "   HAProxy backend: ${C_B}%s${C_0} across %s Envoy server(s)\n" "${BAL:-<unknown>}" "${SRV:-?}"
  cat <<TXT
   ${C_D}'balance source' with consistent hashing sends one source IP to one Envoy
   replica and keeps it there. mongod opens ONE long-lived HTTP/2 connection, so
   a second Envoy replica buys failover, not load sharing - expect it to show
   zero traffic. The spreading that matters happens one hop later, where that one
   Envoy distributes the individual gRPC streams across every mongot pod.${C_0}
TXT
fi

step "7. is that borne out in the access logs?"
for p in $(oc get pods -n "$NS" -l app=mongot-search-lb-0 -o jsonpath='{.items[*].metadata.name}'); do
  n=$(oc logs -n "$NS" "$p" 2>/dev/null | grep -c '"upstream_host"' || true)
  printf "   envoy %-40s %8s access lines\n" "$p" "$n"
done
