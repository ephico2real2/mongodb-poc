# MongoDB Search reachable through a vanity hostname, with a second Envoy beside the operator's

This guide installs `chart/mongot-envoy-vanity-url-helm` on OpenShift beside `chart/mongodb-search-helm`: a second
Envoy that accepts the vanity hostname (a name the company's DNS points at the OpenShift router) as its TLS server
name, behind its own passthrough Route or Ingress, in front of the same mongot pods, with the same secrets. The
operator's Envoy accepts exactly one TLS server name, `externalHostname`, and the operator reconciles it, so a second
name needs an Envoy of our own. The steps install it through a Route, check each piece, switch mongod to the vanity
name, then do the same through an Ingress; Verify proves which path the traffic takes.

## What you get

- The operator's Envoy accepts one TLS server name: `server_names: [externalHostname]` in its one filter chain
  ([`envoy/lds.json`](envoy/lds.json), line 15; operator 1.13.0).
- A second Envoy, Deployment `<search.name>-public-lb`, two pods, running the operator's configuration as static
  resources: the render test finds one differing field, `server_names`
  ([the record](testing-mongot-envoy-vanity-url.md), C7), and Envoy 1.37.6 accepts the bootstrap (C9).
- The same secrets as the operator's Envoy, mounted at the operator's paths; nothing of the operator's is changed.
- A passthrough Route `<search.name>-public` on the vanity hostname with `balance: roundrobin` (the passthrough
  default `source` sent 26,605 connections to one Envoy pod and 0 to the other in the lab), or an Ingress of class
  `openshift-default` that OpenShift turns into that Route.
- A preflight that refuses the install when a secret or the trust bundle is missing, when the server certificate
  does not name the vanity hostname, or when the mongot Service is absent; a public UBI 9 image, no `oc`, no pull
  secret.
- `expose.enabled=false` as the troubleshooting and DR-test switch: the Route goes, a mongod on the vanity name
  stops reaching search, and setting it back restores it.

## Architecture

<!-- markdownlint-disable MD033 -->
<img alt="mongod dials the vanity hostname; the OpenShift router picks the passthrough Route by SNI and forwards the TLS stream to the chart's Envoy, which accepts the vanity server name, presents the existing server certificate, and balances the gRPC streams over the mongot pods with the existing client certificate; the operator's Envoy stands beside it, accepting only the MongoDBSearch's externalHostname, in front of the same mongot pods." src="diagrams/vanity-url/vanity.light.png">
<!-- markdownlint-enable MD033 -->

The router picks a passthrough Route by the SNI the client sends and forwards the TLS stream untouched; our Envoy's
one filter chain matches the vanity name, presents the server certificate, requires the client's, and splits the gRPC
streams over the mongot pods it resolves from the headless Service. mongot checks that a client certificate is signed
by a trusted CA, not its name ([`TLS.md`](../TLS.md), "Limits worth designing around").

| Name | Address | What it is | Who answers |
|---|---|---|---|
| `<vanityHostname>:443` | the company's DNS, a CNAME to the router | the name mongod dials (`mongotHost`) | the router, by SNI, to the Route `<name>-public` |
| Route `<name>-public` | host `<vanityHostname>`, passthrough | the chart's entry (or the Route OpenShift makes from the chart's Ingress) | Service `<name>-public-lb`, port `mongot-grpc` |
| Deployment `<name>-public-lb` | 0.0.0.0:27028 in each pod | our Envoy, `server_names: [<vanityHostname>]` | mutual TLS 1.3, ALPN `h2`, then the mongot pods |
| Service `<name>-search-0-svc` | headless, one A record per mongot pod | the operator's mongot Service, dialled by STRICT_DNS | each mongot pod on 27028, round robin per request |
| Deployment `<name>-search-lb-0` | the operator's Envoy | `server_names: [externalHostname]`; untouched | the same mongot pods, for the main chart's Route |
| Job `<name>-public-preflight` | a pre-install and pre-upgrade hook | reads the two secrets, the trust bundle and the mongot Service from the API server | refuses the install with a message, or lets it through |

## Prerequisites

- `oc` logged in with rights in the namespace; `helm` 4.3.0 (the version CI pins); `openssl`.
- The main chart installed and serving in the namespace, with mutual TLS: its secrets are this chart's.
- The three names of this guide in the shell:

```bash
export NS=<the MongoDBSearch's namespace> HOST=<the vanity hostname> NAME=mongot
```

- The server certificate names the vanity hostname: `DNS:<HOST>`, or `DNS:*.` and the rest of the name for a
  one-label wildcard (the certificate is public; the key is not printed):

```bash
oc get secret ent-${NAME}-search-lb-0-cert -n $NS -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -ext subjectAltName
```

- Otherwise, a certificate from the company CA with both names, made into the secret by the main chart's script
  (which hard-codes the prefix `ent` and the name `mongot`: for another prefix or name, replace the secret the way it
  was first made), and the operator's Envoy restarted to read it:

```bash
bash chart/mongodb-search-helm/generate-mongodbsearch-prerequisites.sh --route <pem> --hostname <externalHostname> --target-namespace $NS --apply --replace
oc rollout restart deploy/${NAME}-search-lb-0 -n $NS
```

## Steps

Install through a Route, check each piece, switch mongod, then the same through an Ingress:

### 1. Install the chart

```bash
helm install ${NAME}-public chart/mongot-envoy-vanity-url-helm -n $NS --set search.name=$NAME --set vanityHostname=$HOST
```

Result: not yet recorded on OpenShift (O1 in [the record](testing-mongot-envoy-vanity-url.md)); it passes when helm
returns 0 and prints the release's notes. The preflight ran first; when it refuses, nothing was installed.

### 2. Read the preflight's verdict

```bash
oc logs -n $NS job/${NAME}-public-preflight
```

Result: on a pass the last line is `everything Envoy mounts and dials is present, and the certificate names every
server name` (recorded in the chart's image, the record's P1); a refusal names what is missing, as the chart's
[README](../chart/mongot-envoy-vanity-url-helm/README.md#troubleshooting-by-message) lists them.

### 3. Check the Envoy pods

```bash
oc get pods -n $NS -l app=${NAME}-public-lb
oc logs -n $NS deploy/${NAME}-public-lb | head -20
```

Result: two pods `1/1 Running`; the log shows `starting main dispatch loop` and `all clusters initialized` (Envoy
1.37.6 on the rendered bootstrap, 2026-10-22) and no `Failed to load` line. The operator's pods,
`-l app=${NAME}-search-lb-0`, are untouched.

### 4. Check the Route

```bash
oc get route ${NAME}-public -n $NS
oc get route ${NAME}-public -n $NS -o jsonpath='{.spec.tls.termination} {.metadata.annotations.haproxy\.router\.openshift\.io/balance} {.status.ingress[0].conditions[0].type}{"\n"}'
```

Result: not yet recorded (O2); it passes when the TERMINATION column reads `passthrough` and the second line prints
`passthrough roundrobin Admitted`. "Admitted" proves the router took the Route, not that traffic flows (main
[README, "The Route, and why Accepted proves nothing"](../README.md#the-route-and-why-accepted-proves-nothing)).

### 5. Point DNS at the router

```bash
oc get route ${NAME}-public -n $NS -o jsonpath='{.status.ingress[0].routerCanonicalHostname}{"\n"}'
dig +short $HOST
```

Result: the first line is the router's hostname, the CNAME target the DNS owner sets for `HOST`; the second then
resolves `HOST` to the router (not yet recorded; the owner's DNS).

### 6. Check the handshake from outside

```bash
openssl s_client -connect $HOST:443 -servername $HOST -alpn h2 </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -ext subjectAltName
openssl s_client -connect $HOST:443 -servername $HOST -alpn h2 </dev/null 2>&1 | grep -E 'ALPN|Protocol *:|TLSv1\.3'
```

Result: not yet recorded (O3); it passes when the subject and SANs are the company certificate's with `HOST` among the
SANs, the issuer the company CA, `ALPN protocol: h2` and `TLSv1.3`.

### 7. Check that a wrong name is still refused

```bash
openssl s_client -connect $HOST:443 -servername wrong.$HOST -alpn h2 </dev/null 2>&1 | grep -E 'subject=|ALPN'
```

Result: not yet recorded (O4); it passes when the answer is the router's default certificate and `No ALPN
negotiated`, never the company certificate (main
[README, "What a wrong SNI does, by path"](../README.md#what-a-wrong-sni-does-by-path)).

### 8. Switch mongod to the vanity name and search

On each mongod host, with the company CA trusted, set the two parameters and restart mongod; then search through it:

```bash
mongod --setParameter mongotHost=$HOST:443 --setParameter searchTLSMode=requireTLS <the host's other options>
mongosh --eval 'db.movies.aggregate([{ $search: { text: { query: "space", path: "title" } } }, { $limit: 3 }])'
oc logs -n $NS deploy/${NAME}-public-lb | grep '"logger":"access"' | tail -3
```

Result: not yet recorded (O5); it passes when results come back and each access-log line carries an `upstream_host`
that is a mongot pod IP on 27028.

### 9. Read the spread over the mongot pods

The Envoy image has no `curl`; the admin port is read through the API server's pod proxy:

```bash
for P in $(oc get pods -n $NS -l app=${NAME}-public-lb -o name); do
  oc get --raw "/api/v1/namespaces/$NS/pods/${P#pod/}:9901/proxy/stats" | grep -E '^cluster\.mongot_rs_cluster\.(membership_healthy|upstream_rq_total)'
done
```

Result: not yet recorded (O5); it passes when `membership_healthy` equals the number of mongot pods and
`upstream_rq_total` climbs with the searches. With `monitoring.serviceMonitor.enabled=true` the same counters are
scraped per pod under `job="<name>-public-envoy-stats"`; the main chart's dashboard selects `job="<name>-envoy-stats"`,
the operator's Envoy, and does not show them.

### 10. Switch to an Ingress

```bash
helm upgrade ${NAME}-public chart/mongot-envoy-vanity-url-helm -n $NS --reuse-values --set expose.type=ingress
oc get ingress ${NAME}-public -n $NS
oc get route -n $NS -o custom-columns='NAME:.metadata.name,HOST:.spec.host,TERM:.spec.tls.termination,BALANCE:.metadata.annotations.haproxy\.router\.openshift\.io/balance'
```

Result: not yet recorded (O6); it passes when the Route of step 4 is gone, the Ingress has class `openshift-default`,
and OpenShift's generated Route `${NAME}-public-<suffix>` shows `HOST`, `passthrough` and `roundrobin`. Steps 6 to 9
then pass unchanged; deleting the Ingress deletes the generated Route.

## Verify

The certificate the vanity name serves, read as a client; the company certificate, with `HOST` among its SANs:

```bash
openssl s_client -connect $HOST:443 -servername $HOST -alpn h2 </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
```

### Prove which path the traffic takes

The stat names are the ones Envoy 1.37.6 exposes for this chart's listener and cluster (read from `/stats` of the
rendered bootstrap on 2026-10-22). Our Envoy's counters, before and after a few searches through the vanity name:

```bash
P=$(oc get pods -n $NS -l app=${NAME}-public-lb -o jsonpath='{.items[0].metadata.name}')
oc get --raw "/api/v1/namespaces/$NS/pods/$P:9901/proxy/stats" | grep -E '^(listener\.0\.0\.0\.0_27028\.(downstream_cx_total|ssl\.handshake|no_filter_chain_match)|http\.ingress_rs\.downstream_rq_total|cluster\.mongot_rs_cluster\.(upstream_rq_total|upstream_cx_total|membership_healthy)): '
```

The operator's Envoy's counters over the same searches, which do not move:

```bash
Q=$(oc get pods -n $NS -l app=${NAME}-search-lb-0 -o jsonpath='{.items[0].metadata.name}')
oc get --raw "/api/v1/namespaces/$NS/pods/$Q:9901/proxy/stats" | grep -E '^(listener\.0\.0\.0\.0_27028\.downstream_cx_total|http\.ingress_rs\.downstream_rq_total|cluster\.mongot_rs_cluster\.upstream_rq_total): '
```

The same through a port-forward to the admin port of one of our pods:

```bash
oc port-forward -n $NS $P 9901:9901 &
curl -s localhost:9901/stats | grep -E '^(listener\.0\.0\.0\.0_27028\.downstream_cx_total|http\.ingress_rs\.downstream_rq_total|cluster\.mongot_rs_cluster\.upstream_rq_total): '
```

Our Envoy's access log, one line per stream, with the mongot pod that answered:

```bash
oc logs -n $NS deploy/${NAME}-public-lb --since=5m | grep '"logger":"access"' | tail -5
```

The DR toggle, the one use of `expose.enabled=false` on OpenShift: the Route goes and a mongod on the vanity name
stops reaching search (the router answers with its default certificate); back to true, the Route returns and the
search answers. The lab row is K9, the OpenShift row O7, in [the record](testing-mongot-envoy-vanity-url.md):

```bash
helm upgrade ${NAME}-public chart/mongot-envoy-vanity-url-helm -n $NS --reuse-values --set expose.enabled=false
oc get route,ingress -n $NS
mongosh --eval 'db.movies.aggregate([{ $search: { text: { query: "space", path: "title" } } }, { $limit: 1 }])'
```

```bash
helm upgrade ${NAME}-public chart/mongot-envoy-vanity-url-helm -n $NS --reuse-values --set expose.enabled=true
oc get route ${NAME}-public -n $NS
mongosh --eval 'db.movies.aggregate([{ $search: { text: { query: "space", path: "title" } } }, { $limit: 1 }])'
```

## Reference

The two Envoys, side by side:

| | The operator's Envoy | Ours (`mongot-envoy-vanity-url-helm`) |
| --- | --- | --- |
| Owner | the operator, from the MongoDBSearch | the Helm release |
| Deployment | `<name>-search-lb-0` | `<name>-public-lb` |
| Accepted SNI | `externalHostname` | `vanityHostname` (and more in `serverNames`) |
| Configuration | `bootstrap.json` + `lds.json` + `cds.json` from the operator's ConfigMap, reloaded from a watched directory | the same three, as static resources in one `bootstrap.yaml` in the chart's ConfigMap |
| Server certificate | `<prefix>-<name>-search-lb-0-cert` | the same secret |
| Client certificate to mongot | `<prefix>-<name>-search-lb-0-client-cert` | the same secret |
| Trust | `ent-trust-bundle` | the same ConfigMap |
| Upstream | `<name>-search-0-svc.<ns>.svc.cluster.local:27028`, STRICT_DNS, one host per pod, round robin | the same |
| Entry | the main chart's Route `mongot-search` on `externalHostname` | Route `<name>-public` on `vanityHostname`, or an Ingress of class `openshift-default` |

The stat names of this chart's Envoy, as Envoy 1.37.6 prints them for the rendered bootstrap (2026-10-22):

| Stat | What it counts |
|---|---|
| `listener.0.0.0.0_27028.downstream_cx_total` | connections accepted on 27028 |
| `listener.0.0.0.0_27028.ssl.handshake` | TLS handshakes completed |
| `listener.0.0.0.0_27028.no_filter_chain_match` | connections whose SNI matched no filter chain: a wrong name |
| `http.ingress_rs.downstream_rq_total` | gRPC requests received |
| `cluster.mongot_rs_cluster.upstream_rq_total` | requests sent to mongot |
| `cluster.mongot_rs_cluster.upstream_cx_total` | connections opened to mongot pods |
| `cluster.mongot_rs_cluster.membership_healthy` | mongot pods Envoy can choose between |

What the configuration keeps and what may differ, the one-name limit as measured, the values, rotation, upgrade,
uninstall and the messages: the chart's [README](../chart/mongot-envoy-vanity-url-helm/README.md).

## Troubleshooting

- The router's default certificate (`CN=*.apps…`) and no ALPN at step 6: the SNI matched no passthrough Route; the
  Route is not admitted, or DNS points at another router. Step 4, then step 5.
- `UNAVAILABLE` on every search with the pods Ready: readiness follows Envoy, not mongot; read the MongoDBSearch's
  status and `membership_healthy` (step 9).
- A refusal at step 2: the chart's [README, "Troubleshooting, by message"](../chart/mongot-envoy-vanity-url-helm/README.md#troubleshooting-by-message).

## Clean up

```bash
helm uninstall ${NAME}-public -n $NS
```

The Route (or the Ingress and its generated Route), the Deployment, its Service, budget and config go; the secrets,
the trust bundle, the MongoDBSearch and the operator's Envoy stay. mongod hosts go back to `externalHostname:443`.

## What's next

- The tests and their recorded outputs: [testing-mongot-envoy-vanity-url.md](testing-mongot-envoy-vanity-url.md).
- The chart's page: [chart/mongot-envoy-vanity-url-helm/README.md](../chart/mongot-envoy-vanity-url-helm/README.md).
- Why one name: the main [README, "What a wrong SNI does, by path"](../README.md#what-a-wrong-sni-does-by-path) and
  [`ENVOY-FLOW.md`](../ENVOY-FLOW.md).
- Per-pod scraping of our Envoy: `monitoring.serviceMonitor.enabled=true` with user workload monitoring.
- At an operator upgrade: re-read `docs/envoy/` from the operator's pod and let the render test name the differences
  (the chart's README, "Upgrade").
