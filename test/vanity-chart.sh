#!/usr/bin/env bash
# Template tests for chart/mongot-envoy-vanity-url-helm, no cluster needed:  test/vanity-chart.sh
# Needs helm (3 or 4), python3, yq and openssl; uses shellcheck when it is installed, and docker or podman for
# Envoy's own validation of the rendered bootstraps (CONTAINER_ENGINE picks one; with none set and no engine that
# check is skipped and says so; an engine named by CONTAINER_ENGINE that does not answer is a failure, as in CI).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
CHART=chart/mongot-envoy-vanity-url-helm
CAPTURE=docs/envoy                      # the operator's Envoy configuration, read from its running pod (ENVOY-FLOW.md)
HOST=mongot-public.example.com
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
# The namespace and search name of the capture (docs/envoy/cds.json names mongot-search-0-svc.mongodb-poc), so a
# render with these values must equal it everywhere but server_names.
render() { helm template mongot-public "${CHART}" -n mongodb-poc --set "publicHostname=${HOST}" "$@" 2>&1; }
objects() { render "$@" | yq -N '.kind + "/" + .metadata.name' 2>/dev/null | grep -v '^null' | LC_ALL=C sort; }
has()  { grep -qx "$2" <<<"$1"; }
# Only the schema's own refusal counts: a render that fails for another reason is a failure, not a refusal.
refused() { local what="$1" out; shift; out="$(render "$@")"; grep -q "specifications of the schema" <<<"${out}" && ok "the schema refuses ${what}" || bad "the schema refuses ${what}: $(tail -1 <<<"${out}")"; }
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT

for t in helm python3 yq openssl; do command -v "$t" >/dev/null || { echo "needs $t"; exit 1; }; done

# ------------------------------------------------------------------------------------------------ lint, defaults
helm lint "${CHART}" --set "publicHostname=${HOST}" >/dev/null 2>&1 && ok "helm lint" || bad "helm lint: $(helm lint "${CHART}" --set "publicHostname=${HOST}" 2>&1 | tail -3 | tr '\n' ' ')"
helm template x "${CHART}" -n x >/dev/null 2>&1 && bad "the defaults alone are refused (no publicHostname)" || ok "the defaults alone are refused (no publicHostname)"
out="$(render)"; [[ $? -eq 0 ]] && ok "renders with publicHostname alone" || bad "renders with publicHostname alone: ${out:0:300}"
# The package: no key, certificate or picture, whatever was left in the chart's directory (a copy is packaged).
pkg="$(mktemp -d)"; cp -R "${CHART}" "${pkg}/chart"
for f in left.pem left.key left.crt key.pass docs/left.png a.secret.yaml; do mkdir -p "$(dirname "${pkg}/chart/${f}")"; echo x > "${pkg}/chart/${f}"; done
helm package "${pkg}/chart" -d "${pkg}" >/dev/null 2>&1
packed="$(tar -tzf "${pkg}"/mongot-envoy-vanity-url-helm-*.tgz 2>/dev/null)"
! grep -qE '\.(pem|key|crt|pass|png|secret\.yaml)$' <<<"${packed}" && grep -qx 'mongot-envoy-vanity-url-helm/README.md' <<<"${packed}" \
  && ok ".helmignore keeps keys, certificates and pictures out of the package; the README travels with it" || bad "the package: $(grep -E 'left|pass|png|secret' <<<"${packed}" | tr '\n' ' ')"
rm -rf "${pkg}"

# ------------------------------------------------------------------------------------------------ the objects, their names
want="$(printf '%s\n' ConfigMap/mongot-public-envoy Deployment/mongot-public-lb Job/mongot-public-preflight PodDisruptionBudget/mongot-public-lb \
  Role/mongot-public-preflight RoleBinding/mongot-public-preflight Route/mongot-public Service/mongot-public-lb ServiceAccount/mongot-public-preflight)"
[[ "$(objects)" == "${want}" ]] && ok "by default: the config, the Deployment, its Service and budget, the Route and the preflight, every name from search.name" \
  || bad "the objects by default: $(objects | tr '\n' ' ')"
o="$(objects --set search.name=srch --set expose.name=vanity)"
has "$o" Route/vanity && has "$o" Deployment/srch-public-lb && has "$o" ConfigMap/srch-public-envoy && has "$o" Job/srch-public-preflight && ! has "$o" Route/srch-public \
  && ok "search.name renames everything; expose.name names the Route" || bad "names with search.name=srch, expose.name=vanity: $(tr '\n' ' ' <<<"$o")"
o="$(objects --set expose.enabled=false)"; ! grep -q 'Route/\|Ingress/' <<<"$o" && has "$o" Service/mongot-public-lb && ok "expose.enabled=false: no Route and no Ingress, the Service stays" || bad "expose.enabled=false: $(tr '\n' ' ' <<<"$o")"
o="$(objects --set preflight.enabled=false)"; ! grep -q 'preflight' <<<"$o" && ok "preflight.enabled=false renders no Job and no RBAC" || bad "preflight.enabled=false: $(tr '\n' ' ' <<<"$o")"
o="$(objects --set envoy.podDisruptionBudget.enabled=false)"; ! grep -q 'PodDisruptionBudget' <<<"$o" && ok "the budget can be turned off" || bad "podDisruptionBudget.enabled=false still renders one"
! render | grep -q 'kind: ClusterRole' && ok "no ClusterRole or ClusterRoleBinding anywhere" || bad "the chart renders cluster-scoped RBAC"
# The namespace: the value wins, and without it every object follows helm's -n; the cluster's FQDN follows it too.
ns_of() { grep -E '^  namespace: ' | sort -u | tr -d ' ' | tr '\n' ' '; }
[[ "$(helm template x "${CHART}" -n elsewhere --set "publicHostname=${HOST}" --set namespace=team-a | ns_of)" == "namespace:team-a " ]] \
  && ok "the namespace value places every object, whatever -n says" || bad "namespace value: $(helm template x "${CHART}" -n elsewhere --set "publicHostname=${HOST}" --set namespace=team-a | ns_of)"
[[ "$(render | ns_of)" == "namespace:mongodb-poc " ]] && ok "an empty namespace value falls back to -n" || bad "namespace fallback: $(render | ns_of)"

# ------------------------------------------------------------------------------------------------ the Route, the Ingress
route="$(render -s templates/20-route.yaml | yq -o=json -I=0 '{"host": .spec.host, "to": .spec.to.name, "port": .spec.port.targetPort, "tls": .spec.tls.termination, "wildcard": .spec.wildcardPolicy, "balance": .metadata.annotations["haproxy.router.openshift.io/balance"]}')"
[[ "${route}" == "{\"host\":\"${HOST}\",\"to\":\"mongot-public-lb\",\"port\":\"mongot-grpc\",\"tls\":\"passthrough\",\"wildcard\":\"None\",\"balance\":\"roundrobin\"}" ]] \
  && ok "the Route: host publicHostname, passthrough, no wildcard, balance roundrobin, to the chart's own Service" || bad "the Route: ${route}"
[[ "$(render -s templates/20-route.yaml --set expose.balance=leastconn --set expose.annotations.a=b --set expose.labels.l=v | yq -o=json -I=0 '[.metadata.annotations["haproxy.router.openshift.io/balance"], .metadata.annotations.a, .metadata.labels.l]')" == '["leastconn","b","v"]' ]] \
  && ok "expose.balance, annotations and labels reach the Route" || bad "expose.balance/annotations/labels on the Route"
ing="$(render --set expose.type=ingress)"
! grep -q 'kind: Route' <<<"${ing}" && grep -q 'kind: Ingress' <<<"${ing}" && ok "expose.type=ingress: an Ingress and no Route" || bad "expose.type=ingress rendered: $(grep '^kind:' <<<"${ing}" | sort -u | tr '\n' ' ')"
ingress="$(yq -o=json -I=0 'select(.kind == "Ingress") | {"name": .metadata.name, "class": .spec.ingressClassName, "term": .metadata.annotations["route.openshift.io/termination"], "balance": .metadata.annotations["haproxy.router.openshift.io/balance"], "host": .spec.rules[0].host, "path": .spec.rules[0].http.paths[0].path, "pathType": .spec.rules[0].http.paths[0].pathType, "svc": .spec.rules[0].http.paths[0].backend.service.name, "port": .spec.rules[0].http.paths[0].backend.service.port.name, "tls": (.spec.tls != null)}' <<<"${ing}")"
[[ "${ingress}" == "{\"name\":\"mongot-public\",\"class\":\"openshift-default\",\"term\":\"passthrough\",\"balance\":\"roundrobin\",\"host\":\"${HOST}\",\"path\":\"\",\"pathType\":\"ImplementationSpecific\",\"svc\":\"mongot-public-lb\",\"port\":\"mongot-grpc\",\"tls\":false}" ]] \
  && ok "the Ingress: class openshift-default, the passthrough and balance annotations, path '' with ImplementationSpecific, no spec.tls" || bad "the Ingress: ${ingress}"
[[ "$(render --set expose.type=ingress --set expose.ingressClassName=nginx --set expose.name=alias | yq -N 'select(.kind == "Ingress") | .metadata.name + " " + .spec.ingressClassName')" == "alias nginx" ]] \
  && ok "expose.name and expose.ingressClassName reach the Ingress" || bad "expose.name/ingressClassName on the Ingress"
refused "an expose.type that is neither route nor ingress" --set expose.type=loadbalancer
refused "a balance the router does not know" --set expose.balance=sticky
# The termination, balance and sync-wave annotations are the chart's: an expose.annotations entry of the same key
# would otherwise be rendered twice, the last one winning in some parsers, and make the Ingress edge.
[[ "$(render --set expose.type=ingress --set 'expose.annotations.route\.openshift\.io/termination=edge' --set 'expose.annotations.haproxy\.router\.openshift\.io/balance=source' --set 'expose.annotations.argocd\.argoproj\.io/sync-wave=9' --set expose.annotations.kept=yes | yq -N 'select(.kind == "Ingress") | .metadata.annotations | [.["route.openshift.io/termination"], .["haproxy.router.openshift.io/balance"], .["argocd.argoproj.io/sync-wave"], .kept] | join(" ")' | grep .)" == "passthrough roundrobin 2 yes" ]] \
  && ok "expose.annotations cannot replace the Ingress's termination, balance or sync-wave; other keys pass" || bad "reserved annotations on the Ingress: $(render --set expose.type=ingress --set 'expose.annotations.route\.openshift\.io/termination=edge' | yq -N 'select(.kind == "Ingress") | .metadata.annotations' | tr '\n' ';')"
[[ "$(render -s templates/20-route.yaml --set 'expose.annotations.haproxy\.router\.openshift\.io/balance=source' | grep -c 'haproxy.router.openshift.io/balance')" == 1 ]] && [[ "$(render -s templates/20-route.yaml --set 'expose.annotations.haproxy\.router\.openshift\.io/balance=source' | yq '.metadata.annotations["haproxy.router.openshift.io/balance"]')" == roundrobin ]] \
  && ok "expose.annotations cannot replace the Route's balance, and the key is rendered once" || bad "reserved annotations on the Route"
refused "an uppercase publicHostname" --set publicHostname=MONGOT.example.com
refused "a trailing dot in publicHostname" --set publicHostname=mongot.example.com.
refused "an uppercase server name" --set "publicHostname=${HOST}" --set "serverNames[0]=${HOST}" --set 'serverNames[1]=ALIAS.example.com'
refused "a trailing dot in a server name" --set "serverNames[0]=${HOST}" --set 'serverNames[1]=alias.example.com.'

# ------------------------------------------------------------------------------------------------ the secrets, the mounts, the Service
dep() { render -s templates/11-deployment.yaml "$@"; }
mounts="$(dep | yq '.spec.template.spec | ([.volumes[] | .name + "=" + (.secret.secretName // .configMap.name)] + [.containers[0].volumeMounts[] | .name + ":" + .mountPath]) | join(" ")')"
[[ "${mounts}" == 'envoy-config=mongot-public-envoy envoy-server-cert=ent-mongot-search-lb-0-cert envoy-client-cert=ent-mongot-search-lb-0-client-cert ca-cert=ent-trust-bundle envoy-config:/etc/envoy envoy-server-cert:/etc/envoy/tls/server envoy-client-cert:/etc/envoy/tls/client ca-cert:/etc/envoy/tls/ca' ]] \
  && ok "the secrets derive as the main chart's helpers (<prefix>-<name>-search-lb-0-cert, -client-cert, ent-trust-bundle) and mount where the operator's Envoy mounts them" || bad "volumes and mounts: ${mounts}"
[[ "$(dep --set tls.certsSecretPrefix=lab --set search.name=srch | yq -o=json -I=0 '[.spec.template.spec.volumes[] | .secret.secretName // .configMap.name]')" == '["srch-public-envoy","lab-srch-search-lb-0-cert","lab-srch-search-lb-0-client-cert","ent-trust-bundle"]' ]] \
  && ok "tls.certsSecretPrefix and search.name change the derived secret names" || bad "derived names with prefix lab, name srch"
[[ "$(dep --set tls.serverCertSecret=my-server --set tls.clientCertSecret=my-client --set tls.trustBundleConfigMap=my-ca | yq -o=json -I=0 '[.spec.template.spec.volumes[] | .secret.secretName // .configMap.name]')" == '["mongot-public-envoy","my-server","my-client","my-ca"]' ]] \
  && ok "tls.serverCertSecret, clientCertSecret and trustBundleConfigMap override the derived names" || bad "secret name overrides"
pf="$(render -s templates/00-preflight.yaml --set tls.serverCertSecret=my-server)"
grep -q '"my-server"' <<<"${pf}" && ! grep -q 'ent-mongot-search-lb-0-cert"' <<<"${pf}" && ok "the preflight's Role and env follow the override" || bad "the preflight still names the derived server secret with tls.serverCertSecret set"
[[ "$(render -s templates/12-service.yaml | yq -o=json -I=0 '{"type": .spec.type, "sel": .spec.selector, "port": .spec.ports[0]}')" == '{"type":"ClusterIP","sel":{"app":"mongot-public-lb"},"port":{"name":"mongot-grpc","port":27028,"targetPort":"mongot-grpc","protocol":"TCP"}}' ]] \
  && ok "the Service is ClusterIP, port mongot-grpc 27028, selecting this Deployment's pods only" || bad "the Service: $(render -s templates/12-service.yaml | yq -o=json -I=0 .spec)"
envoy="$(dep | yq -o=json -I=0 '{"replicas": .spec.replicas, "image": .spec.template.spec.containers[0].image, "args": .spec.template.spec.containers[0].args, "ready": .spec.template.spec.containers[0].readinessProbe.httpGet}')"
[[ "${envoy}" == '{"replicas":2,"image":"quay.io/ephico2real/envoy:v1.37-latest","args":["-c","/etc/envoy/bootstrap.yaml"],"ready":{"path":"/ready","port":"admin"}}' ]] \
  && ok "Envoy: the quay.io image, 2 replicas, readiness on admin /ready" || bad "the Envoy container: ${envoy}"
[[ "$(dep | yq '.spec.selector.matchLabels.app')" == "mongot-public-lb" ]] && [[ "$(render -s templates/13-poddisruptionbudget.yaml | yq -o=json -I=0 '{"max": .spec.maxUnavailable, "sel": .spec.selector.matchLabels, "policy": .spec.unhealthyPodEvictionPolicy}')" == '{"max":1,"sel":{"app":"mongot-public-lb"},"policy":"AlwaysAllow"}' ]] \
  && ok "the budget selects the Deployment's pods, maxUnavailable 1, AlwaysAllow" || bad "the budget: $(render -s templates/13-poddisruptionbudget.yaml | yq -o=json -I=0 .spec)"
[[ "$(dep | yq '.spec.template.metadata.annotations["checksum/config"] | length')" == 64 ]] && [[ "$(dep | yq '.spec.template.metadata.annotations["checksum/config"]')" != "$(dep --set envoy.timeouts.route=299s | yq '.spec.template.metadata.annotations["checksum/config"]')" ]] \
  && ok "a changed bootstrap changes the pod template (checksum/config), so the pods restart" || bad "checksum/config does not follow the config"
# Every container the chart makes requests and limits both CPU and memory (the main chart's rule: a ResourceQuota
# on limits refuses a pod that leaves one out).
containers="$(render --set monitoring.serviceMonitor.enabled=true | yq -N 'select(.kind == "Job" or .kind == "Deployment") | (.kind + "/" + .metadata.name) as $o | .spec.template.spec | ((.containers // []) + (.initContainers // [])) | .[] | $o + " " + .name + " " + ([.resources.requests.cpu, .resources.requests.memory, .resources.limits.cpu, .resources.limits.memory] | map(select(. != null)) | length | tostring)' 2>/dev/null)"
[[ "$(wc -l <<<"${containers}" | tr -d ' ')" == 2 ]] && ! grep -qv ' 4$' <<<"${containers}" \
  && ok "every container (Envoy, the preflight) requests and limits CPU and memory" || bad "a container without all four of requests.cpu, requests.memory, limits.cpu, limits.memory: $(tr '\n' ';' <<<"${containers}")"
# runAsNonRoot needs a numeric user: the image's is root (its entrypoint drops to envoy, 101), so a cluster that does
# not assign one, as kind, takes envoy.runAsUser; OpenShift's restricted-v2 assigns its own and needs none.
[[ "$(dep | yq '.spec.template.spec.securityContext.runAsUser')" == null ]] \
  && [[ "$(dep --set envoy.runAsUser=101 | yq -o=json -I=0 '.spec.template.spec.securityContext | [.runAsNonRoot, .runAsUser, .runAsGroup]')" == '[true,101,101]' ]] \
  && ok "no runAsUser by default (OpenShift assigns one); envoy.runAsUser sets the user and group" || bad "envoy.runAsUser: $(render --set envoy.runAsUser=101 | tail -1)"
refused "an Envoy memory limit that is not a Kubernetes quantity (512MB)" --set-string envoy.resources.limits.memory=512MB
refused "Envoy resources without limits" --set envoy.resources.limits=null

# ------------------------------------------------------------------------------------------------ monitoring
! render | grep -q 'ServiceMonitor\|envoy-stats' && ok "no stats Service and no ServiceMonitor by default" || bad "monitoring rendered by default"
mon="$(render --set monitoring.serviceMonitor.enabled=true --set monitoring.serviceMonitor.interval=30s --set monitoring.serviceMonitor.labels.release=prom)"
[[ "$(yq -N 'select(.kind == "Service" and .metadata.name == "mongot-public-envoy-stats") | .spec.type + " " + (.spec.ports[0].port | tostring) + " " + .spec.selector.app' <<<"${mon}")" == "ClusterIP 9901 mongot-public-lb" ]] \
  && ok "the stats Service is ClusterIP 9901 on this Deployment's pods" || bad "the stats Service"
[[ "$(yq -o=json -I=0 -N 'select(.kind == "ServiceMonitor") | {"name": .metadata.name, "label": .metadata.labels.release, "sel": .spec.selector.matchLabels, "ep": .spec.endpoints[0] | {"port": .port, "path": .path, "interval": .interval, "relabel": .metricRelabelings[0].replacement}}' <<<"${mon}")" == '{"name":"mongot-public-envoy","label":"prom","sel":{"app.kubernetes.io/component":"observability","app":"mongot-public-lb"},"ep":{"port":"admin","path":"/stats/prometheus","interval":"30s","relabel":"${1}_total"}}' ]] \
  && ok "the ServiceMonitor scrapes /stats/prometheus on admin with the main chart's _total relabel, and selects only this chart's stats Service" || bad "the ServiceMonitor: $(yq -o=json -I=0 -N 'select(.kind == "ServiceMonitor") | .spec' <<<"${mon}")"
! yq -N 'select(.kind == "Service") | .metadata.labels["mongodb.com/search-name"]' <<<"${mon}" | grep -qv null \
  && ok "the stats Service does not carry mongodb.com/search-name, so the main chart's monitor does not adopt it" || bad "the stats Service carries the main chart's selector label"
! grep -q 'kind: Route' <<<"$(render --set monitoring.serviceMonitor.enabled=true -s templates/30-monitoring.yaml)" && ok "never a Route to the admin port" || bad "a Route in the monitoring template"

# ------------------------------------------------------------------------------------------------ the schema
refused "an IP as publicHostname" --set publicHostname=10.0.0.1
refused "a one-label publicHostname" --set publicHostname=mongot
refused "an unknown top-level key" --set externalHostname=x.example.com
refused "an unknown key under envoy" --set envoy.imagePullPolicy=Always
refused "an unknown key under expose" --set expose.host=x.example.com
refused "a serverNames entry that is an IP" --set 'serverNames[0]=10.0.0.1'
refused "0 Envoy replicas" --set envoy.replicas=0
refused "a maxUnavailable of 0 (every drain would block)" --set envoy.podDisruptionBudget.maxUnavailable=0
refused "a timeout that is not an Envoy duration" --set envoy.timeouts.route=300
refused "a search.name of 44 characters" --set "search.name=$(printf 'n%.0s' {1..44})"
refused "a mongot.port above 65535" --set mongot.port=70000
refused "an invalid namespace" --set namespace=Not_A_Namespace
refused "a server name given twice (Envoy refuses overlapping filter chains)" --set "serverNames[0]=${HOST}" --set "serverNames[1]=${HOST}"
# The Route sends clients with publicHostname as SNI: a serverNames list without it would pass the preflight (which
# checks serverNames) while Envoy refused every client of the Route.
out="$(render --set 'serverNames[0]=a.example.com')"; rc=$?
[[ ${rc} -ne 0 ]] && grep -q "serverNames must hold publicHostname" <<<"${out}" \
  && ok "a serverNames list without publicHostname is refused, by name" || bad "serverNames without publicHostname: rc ${rc}, $(tail -1 <<<"${out}")"

# ------------------------------------------------------------------------------------------------ the Envoy config
# The rendered bootstrap against the operator's captured configuration, field by field. What may differ, and
# nothing else: the mechanism (dynamic_resources from lds.json and cds.json there, static_resources here), the
# listener's server_names, and the cluster's endpoint address and SNI, which name the mongot Service in the
# release's namespace. With the capture's own namespace and search name even those two are equal.
bootstrap() { render -s templates/10-envoy-config.yaml "$@" | yq -N '.data["bootstrap.yaml"]' | yq -o=json -I=0 .; }
bootstrap > "${tmp}/bootstrap.json"
bootstrap --set namespace=team-a --set search.name=srch --set publicHostname=a.example.com --set 'serverNames[0]=a.example.com' --set 'serverNames[1]=b.example.com' > "${tmp}/bootstrap-other.json"
python3 - "${CAPTURE}" "${tmp}" "${HOST}" <<'PY' && ok "the bootstrap equals the operator's captured config except server_names (and, in another namespace, the endpoint and SNI)" || bad "the bootstrap differs from the capture beyond the allowed fields (above)"
import json, sys
capture, tmp, host = sys.argv[1:4]
load = lambda p: json.load(open(p))
boot, lds, cds = load(f"{capture}/bootstrap.json"), load(f"{capture}/lds.json"), load(f"{capture}/cds.json")

def diff(a, b, path=""):
    """Every path where a and b differ, as "path: a != b"."""
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            out += diff(a.get(k, "<absent>"), b.get(k, "<absent>"), f"{path}.{k}")
        return out
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        return [d for i, (x, y) in enumerate(zip(a, b)) for d in diff(x, y, f"{path}[{i}]")]
    return [] if a == b else [f"{path}: {json.dumps(a)} != {json.dumps(b)}"]

ok = True
# A capture with more than one listener or cluster means the operator's Envoy changed shape: the static conversion
# must then be revisited, not compared element by element.
if len(lds["resources"]) != 1 or len(cds["resources"]) != 1:
    print(f"the capture has {len(lds['resources'])} listener(s) and {len(cds['resources'])} cluster(s): the chart converts exactly one of each"); sys.exit(1)
# What the capture says the listener and the cluster are, without the xDS envelope (@type names the resource's
# kind; a static resource has none).
listener = {k: v for k, v in lds["resources"][0].items() if k != "@type"}
cluster = {k: v for k, v in cds["resources"][0].items() if k != "@type"}
expected_other = {
    ".static_resources.listeners[0].filter_chains[0].filter_chain_match.server_names",
    ".static_resources.clusters[0].load_assignment.endpoints[0].lb_endpoints[0].endpoint.address.socket_address.address",
    ".static_resources.clusters[0].transport_socket.typed_config.sni",
}
for name, allowed in (("bootstrap.json", {".static_resources.listeners[0].filter_chains[0].filter_chain_match.server_names"}),
                      ("bootstrap-other.json", expected_other)):
    got = load(f"{tmp}/{name}")
    # The mechanism: the capture reads lds.json and cds.json; the chart holds both as static resources.
    if "dynamic_resources" in got or set(got.get("static_resources", {})) != {"listeners", "clusters"}:
        print(f"{name}: expected static_resources with listeners and clusters, no dynamic_resources"); ok = False
    # Every top-level key of the captured bootstrap but dynamic_resources (replaced by static_resources), so that a
    # setting the operator adds to its bootstrap at an upgrade is reported, not silently dropped.
    for key in sorted(set(boot) - {"dynamic_resources"}):
        for d in diff(boot[key], got.get(key, "<absent>"), f".{key}"):
            print(f"{name}: {d}"); ok = False
    if set(got) != (set(boot) - {"dynamic_resources"}) | {"static_resources"}:
        print(f"{name}: top-level keys {sorted(got)}, expected {sorted((set(boot) - {'dynamic_resources'}) | {'static_resources'})}"); ok = False
    if len(got["static_resources"]["listeners"]) != 1 or len(got["static_resources"]["clusters"]) != 1:
        print(f"{name}: one listener and one cluster expected"); ok = False
    diffs = diff(listener, got["static_resources"]["listeners"][0], ".static_resources.listeners[0]") \
          + diff(cluster, got["static_resources"]["clusters"][0], ".static_resources.clusters[0]")
    # A difference inside a list (server_names[0]) counts under its list's path.
    paths = {d.split(":")[0] for d in diffs}
    under = lambda p: next((a for a in allowed if p == a or p.startswith(a + "[")), None)
    print(f"{name}: {len(diffs)} field(s) differ from the capture: {sorted(paths)}")
    if any(under(p) is None for p in paths) or {under(p) for p in paths} != allowed:
        for d in diffs: print(f"  {d}")
        print(f"  allowed, and each expected: {sorted(allowed)}"); ok = False
# And the differing values are the ones the values file asked for.
other = load(f"{tmp}/bootstrap-other.json")
sn = other["static_resources"]["listeners"][0]["filter_chains"][0]["filter_chain_match"]["server_names"]
ep = other["static_resources"]["clusters"][0]["load_assignment"]["endpoints"][0]["lb_endpoints"][0]["endpoint"]["address"]["socket_address"]
sni = other["static_resources"]["clusters"][0]["transport_socket"]["typed_config"]["sni"]
if not (sn == ["a.example.com", "b.example.com"] and ep["address"] == sni == "srch-search-0-svc.team-a.svc.cluster.local" and ep["port_value"] == 27028):
    print(f"other values: server_names {sn}, endpoint {ep}, sni {sni}"); ok = False
first = load(f"{tmp}/bootstrap.json")
if first["static_resources"]["listeners"][0]["filter_chains"][0]["filter_chain_match"]["server_names"] != [host]:
    print("server_names is not [publicHostname] by default"); ok = False
sys.exit(0 if ok else 1)
PY
[[ "$(bootstrap --set envoy.retryPolicy.numRetries=5 --set envoy.retryPolicy.perTryTimeout=15s --set envoy.timeouts.route=120s --set envoy.timeouts.streamIdle=121s --set envoy.timeouts.request=122s --set envoy.timeouts.upstreamIdle=123s --set mongot.port=27029 \
  | python3 -c 'import json,sys; b=json.load(sys.stdin); l=b["static_resources"]["listeners"][0]; h=l["filter_chains"][0]["filters"][0]["typed_config"]; r=h["route_config"]["virtual_hosts"][0]["routes"][0]["route"]; c=b["static_resources"]["clusters"][0]
print(r["retry_policy"]["num_retries"], r["retry_policy"]["per_try_timeout"], r["timeout"], h["stream_idle_timeout"], h["request_timeout"], c["typed_extension_protocol_options"]["envoy.extensions.upstreams.http.v3.HttpProtocolOptions"]["common_http_protocol_options"]["idle_timeout"], l["address"]["socket_address"]["port_value"], c["load_assignment"]["endpoints"][0]["lb_endpoints"][0]["endpoint"]["address"]["socket_address"]["port_value"])')" == "5 15s 120s 121s 122s 123s 27029 27029" ]] \
  && ok "the retry, timeout and port values reach the bootstrap where the operator's values sit" || bad "retry/timeout/port values in the bootstrap"

# Envoy's own validation of the rendered bootstrap, in the image the chart runs (the one quay.io copy; its tag is
# what the chart pins). validate mode loads the TLS contexts, so throwaway certificate files stand where the
# secrets mount; the files go in as a tar stream (no bind mount: the engine may run in a VM that does not see
# this directory), unpacked over the image's /etc/envoy as root, then envoy runs as the image's own user.
# Skipped, and said so, where no container engine runs.
ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
image="$(yq '.envoy.image' "${CHART}/values.yaml")"
mkdir -p "${tmp}/envoy/tls/server" "${tmp}/envoy/tls/client" "${tmp}/envoy/tls/ca"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=throwaway" -keyout "${tmp}/envoy/tls/ca/ca.key" -out "${tmp}/envoy/tls/ca/ca.crt" >/dev/null 2>&1
for leg in server client; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=${leg}" -keyout "${tmp}/envoy/tls/${leg}/tls.key" -out "${tmp}/envoy/tls/${leg}/tls.crt" >/dev/null 2>&1
done
render -s templates/10-envoy-config.yaml | yq -N '.data["bootstrap.yaml"]' > "${tmp}/envoy/bootstrap.yaml"
cp "${tmp}/bootstrap-other.json" "${tmp}/envoy/bootstrap-other.json"   # the other namespace, two server names
sed 's/tls_inspector.v3.TlsInspector/tls_inspector.v3.NoSuchFilter/' "${tmp}/envoy/bootstrap.yaml" > "${tmp}/envoy/broken.yaml"
chmod -R a+rX "${tmp}/envoy"
validate() {  # <file under /etc/envoy>: Envoy's verdict on it, as the image's user
  tar -C "${tmp}/envoy" -cf - . | "${ENGINE}" run --rm -i --user 0 --entrypoint sh "${image}" -c \
    "tar -xf - -C /etc/envoy && chmod -R a+rX /etc/envoy && su-exec envoy envoy --mode validate -c /etc/envoy/$1" 2>&1
}
if command -v "${ENGINE}" >/dev/null 2>&1 && "${ENGINE}" info >/dev/null 2>&1; then
  if out="$(validate bootstrap.yaml)"; then
    ok "envoy --mode validate accepts the rendered bootstrap ($(grep -o "configuration '[^']*' OK" <<<"${out}" | head -1))"
  else
    bad "envoy --mode validate: $(tail -3 <<<"${out}" | tr '\n' ' ')"
  fi
  if out="$(validate bootstrap-other.json)"; then
    ok "envoy --mode validate accepts the render for another namespace with two server names"
  else
    bad "envoy --mode validate (other namespace, two server names): $(tail -3 <<<"${out}" | tr '\n' ' ')"
  fi
  # And it refuses a broken one, so the passes above mean something.
  validate broken.yaml >/dev/null && bad "envoy --mode validate accepted a bootstrap with an unknown filter type" || ok "envoy --mode validate refuses a broken bootstrap"
elif [ -n "${CONTAINER_ENGINE:-}" ]; then
  bad "envoy --mode validate: CONTAINER_ENGINE=${ENGINE} is set but the engine does not answer (CI must run this check)"
else
  printf 'skip  envoy --mode validate (no container engine: %s)\n' "${ENGINE}"
fi

# ------------------------------------------------------------------------------------------------ the preflight script
# Taken out of the render and run here against a stand-in curl (the API server, in files), a stand-in ServiceAccount
# directory and a throwaway certificate: what it accepts, what it refuses, and how it ends. Then bash -n and shellcheck.
render -s templates/00-preflight.yaml | python3 -c '
import re, sys
doc = sys.stdin.read()
m = re.search(r"\n          args:\n            - \|\n(.*)", doc, re.S)
lines = [l[14:] if l.startswith(" " * 14) else l.strip() for l in m.group(1).splitlines()]
open(sys.argv[1], "w").write("\n".join(lines) + "\n")' "${tmp}/preflight.sh"
bash -n "${tmp}/preflight.sh" 2>/dev/null && ok "bash -n preflight" || bad "bash -n preflight: $(bash -n "${tmp}/preflight.sh" 2>&1)"
if command -v shellcheck >/dev/null; then
  shellcheck -S warning -s bash "${tmp}/preflight.sh" >/dev/null && ok "shellcheck preflight" || bad "shellcheck preflight: $(shellcheck -S warning -s bash -f gcc "${tmp}/preflight.sh" | head -5)"
else
  printf 'skip  shellcheck (not installed)\n'
fi
# The stand-in curl: GET <api>/api/v1/namespaces/<ns>/<kind>/<name> answers 200 with ${CLUSTER}/<kind>.<name>.json,
# 403 with a Forbidden Status when ${CLUSTER}/<kind>.<name>.forbidden exists, else 404 with a NotFound Status, as
# the API server does; with ${CLUSTER}/down it fails as curl does when nothing answers. -o, -w, -H and --cacert are
# read as curl reads them. The stand-in ServiceAccount directory holds a token the output must never show.
mkdir -p "${tmp}/bin" "${tmp}/cluster" "${tmp}/sa"
printf 'stand-in-token\n' > "${tmp}/sa/token"; printf 'stand-in-ca\n' > "${tmp}/sa/ca.crt"
cat > "${tmp}/bin/curl" <<'CURL'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; -w|-H|--cacert) shift ;; http*) url="$1" ;; esac
  shift
done
[ -e "${CLUSTER}/down" ] && { echo "curl: (7) Failed to connect to kubernetes.default.svc port 443: Connection refused" >&2; exit 7; }
rest="${url#*/api/v1/namespaces/*/}"; kind="${rest%%/*}"; name="${rest#*/}"
if [ -e "${CLUSTER}/${kind}.${name}.forbidden" ]; then
  printf '{"kind":"Status","status":"Failure","message":"%s \\"%s\\" is forbidden: User \\"system:serviceaccount:ns:sa\\" cannot get resource \\"%s\\" in API group \\"\\" in the namespace \\"ns\\"","reason":"Forbidden","code":403}' "$kind" "$name" "$kind" > "$out"; printf 403
elif [ -e "${CLUSTER}/${kind}.${name}.json" ]; then
  cp "${CLUSTER}/${kind}.${name}.json" "$out"; printf 200
else
  printf '{"kind":"Status","status":"Failure","message":"%s \\"%s\\" not found","reason":"NotFound","code":404}' "$kind" "$name" > "$out"; printf 404
fi
CURL
chmod +x "${tmp}/bin/curl"
# A certificate with the vanity name and a one-label wildcard, as the prerequisites script would check it; and one
# with the hostname as its CN only, no SAN.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=mongot" -addext "subjectAltName=DNS:${HOST},DNS:*.apps.example.com,DNS:mongot-search-0-svc" \
  -keyout "${tmp}/server.key" -out "${tmp}/server.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=${HOST}" -keyout "${tmp}/cn.key" -out "${tmp}/cn.crt" >/dev/null 2>&1
# object <kind-plural> <name> [key=file...]: ${CLUSTER}/<kind>.<name>.json, its .data base64-encoded as the API has it.
object() {
  local kind="$1" name="$2"; shift 2
  python3 - "${tmp}/cluster/${kind}.${name}.json" "$name" "$@" <<'PY'
import base64, json, sys
out, name, *pairs = sys.argv[1:]
data = {k: base64.b64encode(open(f, "rb").read()).decode() for k, f in (p.split("=", 1) for p in pairs)}
json.dump({"metadata": {"name": name}, "data": data}, open(out, "w"))
PY
}
seed() {  # a cluster with everything the preflight needs
  rm -rf "${tmp}/cluster"; mkdir -p "${tmp}/cluster"
  object secrets ent-mongot-search-lb-0-cert tls.crt="${tmp}/server.crt" tls.key="${tmp}/server.key"
  object secrets ent-mongot-search-lb-0-client-cert tls.crt="${tmp}/server.crt" tls.key="${tmp}/server.key"
  object configmaps ent-trust-bundle ca.crt="${tmp}/server.crt"
  object services mongot-search-0-svc
}
seed
PF_ENV=(CLUSTER="${tmp}/cluster" SA_DIR="${tmp}/sa" NAMESPACE=mongodb-poc SERVER_SECRET=ent-mongot-search-lb-0-cert CLIENT_SECRET=ent-mongot-search-lb-0-client-cert
        TRUST_CM=ent-trust-bundle MONGOT_SERVICE=mongot-search-0-svc SERVER_NAMES="${HOST}" JOB_IMAGE=example/ubi:1)
preflight() {  # [NAME=value...]: runs the script; prints its exit code; its output in ${tmp}/preflight.out
  env -i PATH="${tmp}/bin:${PATH}" "${PF_ENV[@]}" "$@" bash "${tmp}/preflight.sh" > "${tmp}/preflight.out" 2>&1; echo $?
}
[[ "$(preflight)" == 0 ]] && grep -q "ok: ${HOST} is a name of the certificate" "${tmp}/preflight.out" && grep -q 'ok: service mongot-search-0-svc' "${tmp}/preflight.out" \
  && ok "preflight: everything present and the certificate naming the hostname passes" || bad "preflight with everything present: $(tail -2 "${tmp}/preflight.out" | tr '\n' ' ')"
grep -q 'BEGIN CERTIFICATE\|PRIVATE\|stand-in-token' "${tmp}/preflight.out" && bad "the preflight printed a certificate, a key or the token" || ok "the preflight prints names and keys' names, never a certificate, a key or the token"
[[ "$(preflight SERVER_NAMES="${HOST} x.apps.example.com")" == 0 ]] && ok "preflight: a one-label wildcard SAN covers x.apps.example.com" || bad "preflight: wildcard match: $(grep MISSING "${tmp}/preflight.out" | tr '\n' ' ')"
[[ "$(preflight SERVER_NAMES="a.b.apps.example.com")" == 1 ]] && grep -q 'does not name a.b.apps.example.com' "${tmp}/preflight.out" \
  && ok "preflight: a wildcard covers one label only; a.b.apps.example.com is refused" || bad "preflight: a.b.apps.example.com: $(tail -1 "${tmp}/preflight.out")"
[[ "$(preflight SERVER_NAMES="other.example.com")" == 1 ]] && grep -q "MISSING: secret ent-mongot-search-lb-0-cert: its certificate does not name other.example.com (SANs: ${HOST} \*.apps.example.com mongot-search-0-svc)" "${tmp}/preflight.out" && grep -q 'FAILED: 1 problem' "${tmp}/preflight.out" \
  && ok "preflight: a certificate without the name is refused, the message naming the SANs it has" || bad "preflight: name not on the certificate: $(grep 'MISSING\|FAILED' "${tmp}/preflight.out" | tr '\n' ' ')"
rm "${tmp}/cluster/secrets.ent-mongot-search-lb-0-cert.json"
[[ "$(preflight)" == 1 ]] && grep -q 'MISSING: secret ent-mongot-search-lb-0-cert: NotFound secrets "ent-mongot-search-lb-0-cert" not found' "${tmp}/preflight.out" && ! grep -q 'does not name' "${tmp}/preflight.out" \
  && ok "preflight: a missing server secret is refused by name with the API's reason, and its certificate is not then checked" || bad "preflight: missing server secret: $(grep 'MISSING\|FAILED' "${tmp}/preflight.out" | tr '\n' ' ')"
seed; rm "${tmp}/cluster/secrets.ent-mongot-search-lb-0-client-cert.json" "${tmp}/cluster/configmaps.ent-trust-bundle.json" "${tmp}/cluster/services.mongot-search-0-svc.json"
[[ "$(preflight)" == 1 ]] && [[ "$(grep -c MISSING "${tmp}/preflight.out")" == 3 ]] && grep -q 'FAILED: 3 problem' "${tmp}/preflight.out" \
  && ok "preflight: a missing client secret, trust bundle and mongot Service are each named, and counted" || bad "preflight: three missing: $(grep 'MISSING\|FAILED' "${tmp}/preflight.out" | tr '\n' ' ')"
seed; touch "${tmp}/cluster/secrets.ent-mongot-search-lb-0-client-cert.forbidden"
[[ "$(preflight)" == 1 ]] && grep -q 'MISSING: secret ent-mongot-search-lb-0-client-cert: Forbidden secrets "ent-mongot-search-lb-0-client-cert" is forbidden' "${tmp}/preflight.out" \
  && ok "preflight: a Forbidden reads as one, not as missing" || bad "preflight: Forbidden: $(grep MISSING "${tmp}/preflight.out" | tr '\n' ' ')"
seed; touch "${tmp}/cluster/down"
[[ "$(preflight)" == 1 ]] && grep -q 'the API server did not answer: curl: (7)' "${tmp}/preflight.out" && grep -q 'FAILED: 4 problem' "${tmp}/preflight.out" \
  && ok "preflight: an API server that does not answer is reported with curl's error, for each object" || bad "preflight: API down: $(grep 'MISSING\|FAILED' "${tmp}/preflight.out" | tr '\n' ' ')"
seed; object secrets ent-mongot-search-lb-0-client-cert tls.crt="${tmp}/server.crt"
[[ "$(preflight)" == 1 ]] && grep -q 'secret ent-mongot-search-lb-0-client-cert: no key tls.key' "${tmp}/preflight.out" \
  && ok "preflight: a secret without tls.key is refused" || bad "preflight: missing key: $(grep MISSING "${tmp}/preflight.out" | tr '\n' ' ')"
# A CN is not a name: a certificate whose subject is the hostname, with no SAN, is refused.
seed; object secrets ent-mongot-search-lb-0-cert tls.crt="${tmp}/cn.crt" tls.key="${tmp}/cn.key"
[[ "$(preflight)" == 1 ]] && grep -q "does not name ${HOST} (SANs: )" "${tmp}/preflight.out" && ok "preflight: a certificate with the hostname as CN and no SAN is refused" || bad "preflight: CN-only certificate: $(grep 'MISSING\|FAILED' "${tmp}/preflight.out" | tr '\n' ' ')"
seed; object secrets ent-mongot-search-lb-0-client-cert tls.key="${tmp}/server.key"
[[ "$(preflight)" == 1 ]] && grep -q 'client-cert: no key tls.crt' "${tmp}/preflight.out" && ok "preflight: a client secret without tls.crt is refused" || bad "preflight: client secret without tls.crt accepted"
seed; object configmaps ent-trust-bundle
[[ "$(preflight)" == 1 ]] && grep -q 'ent-trust-bundle: no key ca.crt' "${tmp}/preflight.out" && ok "preflight: a trust bundle without ca.crt is refused" || bad "preflight: trust bundle without ca.crt accepted"
seed; object secrets ent-mongot-search-lb-0-cert tls.crt="${tmp}/server.crt"
[[ "$(preflight)" == 1 ]] && grep -q 'lb-0-cert: no key tls.key' "${tmp}/preflight.out" && ok "preflight: a server secret without tls.key is refused" || bad "preflight: server secret without tls.key accepted"
# An image without curl, python3 or openssl: refused, naming the image and the tool, never skipped. A PATH of the
# other tools only, the stand-in curl among them.
seed
for missing in curl python3 openssl; do
  d="${tmp}/no-${missing}"; rm -rf "$d"; mkdir -p "$d"
  for t in bash base64 tr sed awk grep date cat tail cut printf env mktemp rm curl python3 openssl; do
    [ "$t" = "$missing" ] && continue
    if [ "$t" = curl ]; then ln -s "${tmp}/bin/curl" "$d/curl"; else p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -s "$p" "$d/$t"; fi
  done
  [[ "$(env -i PATH="$d" "${PF_ENV[@]}" bash "${tmp}/preflight.sh" > "${tmp}/preflight.out" 2>&1; echo $?)" == 1 ]] \
    && grep -q "REFUSED: the Job image example/ubi:1 has no ${missing}: jobs.image needs curl, python3 and openssl" "${tmp}/preflight.out" \
    && ok "preflight: an image without ${missing} is refused, naming the image and the tool" || bad "preflight without ${missing}: $(tail -1 "${tmp}/preflight.out")"
done
[[ "$(preflight SA_DIR="${tmp}/no-such-dir")" == 1 ]] && grep -q 'REFUSED: no ServiceAccount token' "${tmp}/preflight.out" \
  && ok "preflight: without a ServiceAccount token it refuses, never guesses" || bad "preflight without a token: $(tail -1 "${tmp}/preflight.out")"

# ------------------------------------------------------------------------------------------------ the documents
grep -q 'rollout restart deploy/' "${CHART}/templates/NOTES.txt" && grep -q 'rollout restart' "${CHART}/README.md" \
  && ok "NOTES and the README say to restart the pods after a certificate rotation" || bad "the rotation note is missing from NOTES.txt or README.md"
grep -q 'mongot-envoy-vanity-url-helm' README.md && grep -q 'mongot-envoy-vanity-url-helm' chart/mongodb-search-helm/README.md && grep -q 'docs/mongot-envoy-vanity-url.md' README.md \
  && ok "the main README and the main chart's README link the chart and its document" || bad "a README does not link the chart or docs/mongot-envoy-vanity-url.md"
[[ $fails == 0 ]] && echo "all vanity chart tests passed" || { echo "${fails} failed"; exit 1; }
