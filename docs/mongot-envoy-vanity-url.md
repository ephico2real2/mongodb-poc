# A vanity hostname for MongoDB Search: a second Envoy beside the operator's

The operator's Envoy accepts one TLS server name. This document is why a second, vanity hostname needs an Envoy of
our own, how `chart/mongot-envoy-vanity-url-helm` builds one from the operator's own configuration and the secrets
that already exist, what it changes and does not, its limits, and the install on OpenShift step by step, through a
Route and then through an Ingress. The chart's operating page (values, rotation, upgrade, troubleshooting) is its
[README](../chart/mongot-envoy-vanity-url-helm/README.md); the tests are recorded in
[testing-mongot-envoy-vanity-url.md](testing-mongot-envoy-vanity-url.md).

<!-- markdownlint-disable MD033 -->
<img alt="mongod dials the vanity hostname; the OpenShift router picks the passthrough Route by SNI and forwards the TLS stream to the chart's Envoy, which accepts the vanity server name, presents the existing server certificate, and balances the gRPC streams over the mongot pods with the existing client certificate; the operator's Envoy stands beside it, accepting only the MongoDBSearch's externalHostname, in front of the same mongot pods." src="diagrams/vanity-url/vanity.light.png">
<!-- markdownlint-enable MD033 -->

## The problem, measured

The operator (MongoDB Kubernetes operator 1.13.0) builds its Envoy's listener with a single filter chain whose match
is the MongoDBSearch's `externalHostname` and nothing else. Read from the running pod
([`envoy/lds.json`](envoy/lds.json), lines 12 to 18):

```json
"filter_chains": [
    {
        "filter_chain_match": {
            "server_names": [
                "grpc-search.apps-crc.testing"
            ]
        },
```

`tls_inspector` reads the SNI of every ClientHello before decryption and the chain is chosen by it; no SNI, or a
different one, matches no chain and the connection is closed ([`ENVOY-FLOW.md`](../ENVOY-FLOW.md), steps 2 and 3).
The route's `domains: ["*"]` matches any `:authority`, so the SNI is the only host gate.

What a client dialling an alias sees was measured on the lab with `vip-grpc-search.apps-crc.testing`, a spare SAN of
the certificate, as `mongotHost` (main [README, "What a wrong SNI does, by path"](../README.md#what-a-wrong-sni-does-by-path)):

```text
:27028  SNI vip-grpc-search...  -> Envoy closes the handshake, serves NO certificate
                                   ("unexpected eof while reading")

:443    SNI vip-grpc-search...  -> the router's DEFAULT certificate (CN=*.apps-crc.testing)
                                   and NO ALPN. TLS "succeeds" and never reaches Envoy.
```

The second case is the one on OpenShift: a passthrough Route is only taken when the SNI is in the router's
`os_sni_passthrough.map`; any other name falls to the terminating flow (`be_sni`), which binds the router's default
certificate with `no-alpn`. A check that asserts "TLS connects" passes while no request reaches the search tier.

Two more facts close the other ways out:

- The operator reconciles its Envoy's ConfigMap and Deployment: an edit to `lds.json` is overwritten. The
  MongoDBSearch has one `externalHostname`, so one name.
- mongot checks that a client certificate is signed by a trusted CA and does not check its name
  ([`TLS.md`](../TLS.md), "Limits worth designing around"). An Envoy of our own that presents the same client
  certificate is, to mongot, the operator's Envoy.

## The design

A second Envoy, run by a chart of this repository, beside the operator's and in front of the same mongot pods:

| | The operator's Envoy | Ours (`mongot-envoy-vanity-url-helm`) |
| --- | --- | --- |
| Owner | the operator, from the MongoDBSearch | the Helm release |
| Deployment | `<name>-search-lb-0` | `<name>-public-lb` |
| Accepted SNI | `externalHostname` | `publicHostname` (and more in `serverNames`) |
| Configuration | `bootstrap.json` + `lds.json` + `cds.json` from the operator's ConfigMap, reloaded from a watched directory | the same three, as static resources in one `bootstrap.yaml` in the chart's ConfigMap |
| Server certificate | `<prefix>-<name>-search-lb-0-cert` | the same secret |
| Client certificate to mongot | `<prefix>-<name>-search-lb-0-client-cert` | the same secret |
| Trust | `ent-trust-bundle` | the same ConfigMap |
| Upstream | `<name>-search-0-svc.<ns>.svc.cluster.local:27028`, STRICT_DNS, one host per pod, round robin | the same |
| Entry | the main chart's Route `mongot-search` on `externalHostname` | Route `<name>-public` on `publicHostname`, or an Ingress of class `openshift-default` |

Everything the operator sets is kept, value for value: the listener on 0.0.0.0:27028 with `tls_inspector`; TLS 1.3
only, ALPN `h2`, a client certificate required; the HTTP connection manager with the router filter, 1 MiB HTTP/2
windows, keepalive 60 s/10 s, `stream_idle_timeout` and `request_timeout` 300 s, the JSON access log; the route
`prefix: /, grpc: {}` with a 300 s timeout and the retry policy (`connect-failure,refused-stream,unavailable,reset,
resource-exhausted`, 2 retries, 60 s per try, `previous_hosts`, 3 host selection attempts); the cluster with circuit
breakers 1024/1024/1024/3, a 300 s upstream idle timeout, the same HTTP/2 options, the client certificate, the
Service name as SNI and TCP keepalive 3/10/3; the admin port 9901 with the four allowed paths; and
`global_downstream_max_connections: 50000`. The render test compares the chart's bootstrap with
[`docs/envoy/`](envoy/) field by field and names the fields that may differ: `server_names`, and the cluster's
endpoint and SNI, which follow the release's namespace.

The one change is `server_names`. A client dialling the vanity name sends it as SNI; the router's map now holds it
(the chart's Route), the router forwards the stream to our Envoy, our Envoy's chain matches it, presents the server
certificate, which already carries the name as a SAN, and the gRPC streams are split over the mongot pods as before.

A preflight Job runs before anything is created and refuses the install when a secret or the trust bundle is missing
or lacks a key, when the server certificate does not name a server name (a SAN, or a one-label wildcard, as the
prerequisites script matches), or when the mongot Service does not exist. It prints key names and the certificate's
DNS names, never a key.

## What it changes, and what it does not

Changes: adds a Deployment of two Envoy pods, their Service, budget and ConfigMap, a Route or Ingress, and, when
asked, a stats Service and a ServiceMonitor; all in the MongoDBSearch's namespace, all named `<name>-public…`.

Does not change: the MongoDBSearch, the operator's Envoy and its Route, the mongot pods, the secrets and the trust
bundle. Nothing of the operator's is read or written by the chart's objects; the preflight reads the two secrets,
the trust bundle and the mongot Service by name (its Role names them) and nothing else. Uninstalling the release
removes only what it made.

## Limits

- **A copied configuration.** An operator upgrade that changes its Envoy configuration is not followed. At each
  operator upgrade, re-read the three files from the operator's running Envoy into `docs/envoy/`
  ([`ENVOY-FLOW.md`](../ENVOY-FLOW.md), "Getting the config out of the pod"); `test/vanity-chart.sh` then names every
  field where the chart differs, and the template is changed to match.
- **Readiness follows Envoy, not mongot**, as the operator's Envoy: a pod is Ready when Envoy's admin answers
  `/ready`. With no mongot pod up, searches fail with `UNAVAILABLE` while the pods read Ready.
- **Certificates are read once.** After a rotation, `oc rollout restart deploy/<name>-public-lb` (the operator's Envoy
  needs the same; [`ENVOY-FLOW.md`](../ENVOY-FLOW.md), "watched_directory matters").
- **One mongod, one connection, one Envoy pod.** The second pod is a standby. The router's `balance: roundrobin`
  spreads connections, not requests; requests are spread by Envoy over mongot.
- **Router timeouts on an Ingress.** Whether a router timeout annotation on an Ingress reaches the generated Route
  is not documented by Red Hat; none is set. A passthrough Route's `timeout tunnel` default (1 h) covers the 300 s
  streams.
- **No Cilium path.** On the cluster-mesh labs the operator's Envoy is not used
  ([testing-kind-mesh-cilium.md](testing-kind-mesh-cilium.md)); this chart is for the OpenShift deployment with the
  operator's Envoy.

## Install on OpenShift, step by step

The main chart installed and serving in the namespace with mutual TLS. `NS` is that namespace, `HOST` the vanity
hostname, `NAME` the MongoDBSearch's name (`mongot` by default).

### Step 1: the certificate names the hostname

The server certificate Envoy presents must carry `HOST` as a SAN. Read it from the secret (the certificate is
public; the key is not printed):

```bash
oc get secret ent-${NAME}-search-lb-0-cert -n $NS -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -ext subjectAltName
```

**It worked when** the output lists `DNS:<HOST>` (or `DNS:*.` and the rest of the name, for a one-label wildcard).
Otherwise ask the company CA for a certificate that carries both names and make the secret from it with the main
chart's `generate-mongodbsearch-prerequisites.sh --route <pem> --hostname <externalHostname> --target-namespace $NS
--apply --replace` (the script names the secret `ent-mongot-search-lb-0-cert`: it hard-codes the prefix `ent` and
the name `mongot`; for another prefix or name, replace the secret the way it was first made). Then restart the
operator's Envoy, which reads it too: `oc rollout restart deploy/${NAME}-search-lb-0 -n $NS`.

### Step 2: install the chart (Route)

```bash
helm install ${NAME}-public chart/mongot-envoy-vanity-url-helm -n $NS --set search.name=$NAME --set publicHostname=$HOST
```

**It worked when** helm returns 0 and prints the release's notes. If it stops on the preflight:

```bash
oc logs -n $NS job/${NAME}-public-preflight
```

names what is missing (`MISSING: secret …`, `… does not name <HOST> (SANs: …)`, `MISSING: service …`), and nothing
was installed.

### Step 3: the pods

```bash
oc get pods -n $NS -l app=${NAME}-public-lb
oc logs -n $NS deploy/${NAME}-public-lb | head -20
```

**It worked when** two pods are `1/1 Running`, and the log shows `all clusters initialized` and `starting main
dispatch loop` with no `Failed to load` line. Readiness is Envoy's `/ready`; the operator's pods
(`-l app=${NAME}-search-lb-0`) are untouched.

### Step 4: the Route

```bash
oc get route ${NAME}-public -n $NS
oc get route ${NAME}-public -n $NS -o jsonpath='{.spec.tls.termination} {.metadata.annotations.haproxy\.router\.openshift\.io/balance} {.status.ingress[0].conditions[0].type}{"\n"}'
oc get route ${NAME}-public -n $NS -o jsonpath='{.status.ingress[0].routerCanonicalHostname}{"\n"}'
```

**It worked when** the TERMINATION column reads `passthrough`, the second line prints `passthrough roundrobin
Admitted`, and the third prints the router's hostname: give it to the DNS owner for the CNAME of `HOST`. "Admitted"
proves the router took the Route, not that traffic flows (main
[README, "The Route, and why Accepted proves nothing"](../README.md#the-route-and-why-accepted-proves-nothing)).

### Step 5: the handshake, from outside

Once DNS resolves `HOST` to the router:

```bash
openssl s_client -connect $HOST:443 -servername $HOST -alpn h2 </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -ext subjectAltName
openssl s_client -connect $HOST:443 -servername $HOST -alpn h2 </dev/null 2>&1 | grep -E 'ALPN|Protocol *:|TLSv1\.3'
```

**It worked when** the subject and SANs are the company certificate's (with `HOST` among the SANs), the issuer the
company CA, `ALPN protocol: h2` and `TLSv1.3`. The router's own certificate (`CN=*.apps…`) and no ALPN mean the SNI
did not match a passthrough Route: the Route is not admitted, or DNS points at another router.

Then the refusal that proves the gate is still a gate, with a name no Route serves:

```bash
openssl s_client -connect $HOST:443 -servername wrong.$HOST -alpn h2 </dev/null 2>&1 | grep -E 'subject=|ALPN'
```

**It worked when** the answer is the router's default certificate and `No ALPN negotiated` (the Route path), never
the company certificate.

### Step 6: a search through the vanity name

On a mongod host, or in a `mongosh` against one, with the company CA trusted:

```text
--setParameter=mongotHost=<HOST>:443
--setParameter=searchTLSMode=requireTLS
```

```javascript
db.movies.aggregate([{ $search: { text: { query: "space", path: "title" } } }, { $limit: 3 }])
```

**It worked when** results come back, and our Envoy's access log carries the stream:

```bash
oc logs -n $NS deploy/${NAME}-public-lb | grep '"logger":"access"' | tail -3
```

each line with an `upstream_host` that is a mongot pod IP on 27028.

### Step 7: the spread over the mongot pods

The Envoy image has no `curl` or `wget`; the admin port is read through the API server's pod proxy, as
`kind-mesh/drills.sh` reads the operator's Envoy:

```bash
P=$(oc get pods -n $NS -l app=${NAME}-public-lb -o jsonpath='{.items[0].metadata.name}')
oc get --raw "/api/v1/namespaces/$NS/pods/$P:9901/proxy/stats" | grep -E '^cluster\.mongot_rs_cluster\.(membership_healthy|upstream_rq_total)'
```

**It worked when** `membership_healthy` equals the number of mongot pods and `upstream_rq_total` climbs with the
searches. With `monitoring.serviceMonitor.enabled=true` the same counters are scraped per pod under
`job="${NAME}-public-envoy-stats"`; the main chart's dashboard panels select `job="${NAME}-envoy-stats"` (the
operator's Envoy) and do not show them.

### Step 8: the same through an Ingress

```bash
helm upgrade ${NAME}-public chart/mongot-envoy-vanity-url-helm -n $NS --reuse-values --set expose.type=ingress
oc get ingress ${NAME}-public -n $NS
oc get route -n $NS -o custom-columns='NAME:.metadata.name,HOST:.spec.host,TERM:.spec.tls.termination,BALANCE:.metadata.annotations.haproxy\.router\.openshift\.io/balance'
```

**It worked when** the Route `${NAME}-public` of Step 4 is gone, the Ingress has class `openshift-default`, and
OpenShift's generated Route `${NAME}-public-<suffix>` shows `HOST`, `passthrough` and `roundrobin`: the Ingress's
annotations were copied onto it. Steps 5 to 7 then pass unchanged. Deleting the Ingress deletes the generated Route.

### Rotation, upgrade, uninstall

- A rotated secret: `oc rollout restart deploy/${NAME}-public-lb -n $NS`.
- `helm upgrade … --reuse-values --set …`: the preflight runs first; a changed bootstrap or image rolls the pods.
- `helm uninstall ${NAME}-public -n $NS`: removes the chart's objects and nothing of the operator's.

## Sources

- [`docs/envoy/`](envoy/): the operator's Envoy configuration as read from its pod; [`ENVOY-FLOW.md`](../ENVOY-FLOW.md)
- Main [README](../README.md): "What a wrong SNI does, by path"; "Passthrough routes do honour the balance annotation"
- [mongot-route-balance-rationale.md](mongot-route-balance-rationale.md): the balance annotation, and the route
  controller copying an Ingress's annotations to its Route
- [mongot-envoy-mtls-fresh-install-runbook.md](mongot-envoy-mtls-fresh-install-runbook.md), Step 6d: the Route and the
  Ingress with the passthrough annotation
- Red Hat, OpenShift Container Platform, Networking, "Creating a route through an Ingress object": the
  `route.openshift.io/termination` annotation; a passthrough Ingress uses `path: ''` and `pathType: ImplementationSpecific`
- MongoDB, Known Limitations of MongoDB Search on Kubernetes: mongot does not validate the client certificate's name
  ([`TLS.md`](../TLS.md))
