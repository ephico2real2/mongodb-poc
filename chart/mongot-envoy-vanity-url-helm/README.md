# mongot-envoy-vanity-url-helm

A second Envoy for a vanity (public) hostname in front of the mongot pods that
[mongodb-search-helm](../mongodb-search-helm/README.md) runs, beside the operator's Envoy, which this chart never
touches. The design, the measured facts behind it and the step-by-step install on OpenShift are in
[`docs/mongot-envoy-vanity-url.md`](../../docs/mongot-envoy-vanity-url.md); this page is the chart's operating
document and travels with the package.

<!-- markdownlint-disable MD033 -->
<img alt="mongod dials the vanity hostname; the OpenShift router picks the passthrough Route by SNI and forwards the TLS stream to the chart's Envoy, which accepts the vanity server name, presents the existing server certificate, and balances the gRPC streams over the mongot pods with the existing client certificate; the operator's Envoy stands beside it, accepting only the MongoDBSearch's externalHostname, in front of the same mongot pods." src="../../docs/diagrams/vanity-url/vanity.light.png">
<!-- markdownlint-enable MD033 -->

## What it is for

The operator's Envoy accepts exactly one TLS server name: its single filter chain has
`server_names: [externalHostname]` (operator 1.13.0; [`docs/envoy/lds.json`](../../docs/envoy/lds.json), line 15).
A client that dials any other name sends that name as SNI, and the two entry paths refuse it differently (the main
[README, "What a wrong SNI does, by path"](../../README.md#what-a-wrong-sni-does-by-path)): on a VIP straight to
Envoy the handshake closes with no certificate served; through a passthrough Route the router never classifies the
connection as passthrough, terminates it itself with its default certificate and no ALPN, and the request never
reaches the search tier. The operator reconciles its own Envoy, so its configuration cannot be edited. mongot checks
only that a client certificate is signed by a trusted CA, not its name ([`TLS.md`](../../TLS.md), "Limits worth
designing around").

So this chart runs its own Envoy with the operator's own configuration
([`docs/envoy/`](../../docs/envoy/), read from its running pod), changed in one place: the accepted server name is
the vanity hostname. It mounts the secrets that already exist and dials the same headless mongot Service, so each
request lands on a mongot pod by Envoy's round robin, as it does behind the operator's Envoy.

## What it does

| Order | Object | Name | What for |
| --- | --- | --- | --- |
| before anything | preflight Job | `<search.name>-public-preflight` | Fails the install when a secret or the trust bundle is missing or lacks a key, when the server certificate does not name a server name, or when the mongot Service does not exist |
| 0 | ConfigMap | `<search.name>-public-envoy` | Envoy's bootstrap: the operator's configuration as static resources |
| 1 | Deployment | `<search.name>-public-lb` | Envoy, 2 pods, readiness on its admin `/ready` |
| 1 | Service | `<search.name>-public-lb` | ClusterIP, port `mongot-grpc` 27028, this Deployment's pods only |
| 1 | PodDisruptionBudget | `<search.name>-public-lb` | A node drain takes one Envoy pod at a time |
| 2 | Route, or Ingress | `<search.name>-public` | Passthrough, host `publicHostname`, `balance: roundrobin` |
| 1 | Service, ServiceMonitor | `<search.name>-public-envoy-stats`, `<search.name>-public-envoy` | Per-pod scraping of Envoy's admin port; off by default |

What it does not create: a certificate, a secret, the trust bundle, a MongoDBSearch, or anything of the operator's.

## Install

The main chart installed and serving in the namespace, with mutual TLS (its secrets are this chart's), and a
server certificate whose SANs hold the vanity hostname: the company issues it with every name, and the main chart's
`generate-mongodbsearch-prerequisites.sh --route <pem> --hostname <name>` makes the secret from it (a one-label
wildcard counts there as it does in the preflight).

```bash
helm install mongot-public chart/mongot-envoy-vanity-url-helm -n <namespace> \
  --set publicHostname=mongot-search.example.com
```

The release's notes print where to read the preflight's verdict, the pods and the entry. Then, by hand: point DNS
for the hostname at the router (`oc get route <search.name>-public -o jsonpath='{.status.ingress[0].routerCanonicalHostname}'`
prints it), and set `mongotHost=<hostname>:443` on the mongod hosts, with the company CA trusted.

With Argo CD: the preflight and its RBAC are PreSync hooks; the objects sync in waves 0 to 2. The chart's own
objects are all namespaced; there is no ClusterRole.

## Values

| Value | Default | What |
| --- | --- | --- |
| `namespace` | empty: the namespace given with `-n` | Where every object goes: the MongoDBSearch's, which holds the secrets and the mongot Service |
| `search.name` | `mongot` | The MongoDBSearch's name; every name of this chart, of the secrets and of the mongot Service derives from it |
| `publicHostname` | required | The vanity hostname: the Route's host and the TLS server name Envoy accepts. A DNS name of two labels or more, never an IP |
| `serverNames` | `[]`: `[publicHostname]` | Every server name Envoy accepts, when one release serves more aliases; each must be a SAN of the server certificate |
| `tls.certsSecretPrefix` | `ent` | The main chart's prefix: the two secrets below derive from it |
| `tls.serverCertSecret` | empty: `<prefix>-<search.name>-search-lb-0-cert` | The server certificate Envoy presents to mongod |
| `tls.clientCertSecret` | empty: `<prefix>-<search.name>-search-lb-0-client-cert` | The client certificate Envoy presents to mongot |
| `tls.trustBundleConfigMap` | `ent-trust-bundle` | The ConfigMap with `ca.crt`, trusted on both legs |
| `mongot.service` | empty: `<search.name>-search-0-svc` | The headless mongot Service Envoy resolves to one host per pod |
| `mongot.port` | `27028` | mongot's gRPC port, and the port Envoy listens on |
| `envoy.image` | `quay.io/ephico2real/envoy:v1.37-latest` | The main chart's Envoy image: a copy of the operator's `envoyproxy/envoy:v1.37-latest` (1.37.6 on 2026-10-22) |
| `envoy.replicas` | `2` | One stays through a node drain. A second pod is a standby, not capacity: one mongod sends every search through one connection |
| `envoy.resources` | requests `100m`, `128Mi`; limits `500m`, `512Mi` | The operator's own defaults for its Envoy. Every request and limit is set |
| `envoy.retryPolicy.numRetries`, `.perTryTimeout` | `2`, `60s` | The operator's: a failed stream is retried on another mongot pod |
| `envoy.timeouts.route`, `.streamIdle`, `.request`, `.upstreamIdle` | `300s` each | The operator's |
| `envoy.podDisruptionBudget.enabled`, `.maxUnavailable` | `true`, `1` | The main chart's pattern for its Envoy pods |
| `expose.enabled` | `true` | `false`: no Route and no Ingress (a cluster without the OpenShift router, or a port-forward) |
| `expose.type` | `route` | `route` or `ingress`: see below |
| `expose.name` | empty: `<search.name>-public` | The Route's or Ingress's name |
| `expose.balance` | `roundrobin` | The router's balance annotation; its passthrough default `source` sent every connection to one Envoy pod ([rationale](../../docs/mongot-route-balance-rationale.md)) |
| `expose.ingressClassName` | `openshift-default` | The Ingress's class: OpenShift's own router |
| `expose.annotations`, `.labels` | `{}` | Added to the Route or Ingress |
| `preflight.enabled` | `true` | |
| `monitoring.serviceMonitor.enabled`, `.interval`, `.labels` | `false`, `15s`, `{}` | Per-pod scraping of Envoy's `/stats/prometheus`, with the main chart's `_total` relabelling; needs user workload monitoring |
| `jobs.image.repository`, `.tag` | `registry.redhat.io/openshift4/ose-cli`, `latest` | The preflight's image: a shell, `oc` and `openssl` (the certificate check). The main chart's default |
| `jobs.resources`, `.ttlSecondsAfterFinished` | see `values.yaml` | |

`values.schema.json` refuses an unknown key, an IP or a one-label name as hostname, a timeout that is not an Envoy
duration, resources without limits, and an `expose.type` other than `route` or `ingress`.

## Route or Ingress

Both are passthrough: the router forwards the TLS stream untouched, Envoy matches the SNI and presents the server
certificate itself, and mutual TLS 1.3 with ALPN `h2` ends at Envoy.

- **Route** (`expose.type: route`, the default): `host: publicHostname`, `tls.termination: passthrough`,
  `wildcardPolicy: None`, and `haproxy.router.openshift.io/balance: roundrobin`. The passthrough default, `source`,
  hashes every connection from one peer address onto the same Envoy pod: one Envoy had 26,605 requests and the other
  0 in the lab (main [README](../../README.md#passthrough-routes-do-honour-the-balance-annotation)).
- **Ingress** (`expose.type: ingress`): `ingressClassName: openshift-default`, the annotations
  `route.openshift.io/termination: passthrough` and the balance, one rule for the host with `path: ''` and
  `pathType: ImplementationSpecific`, no `spec.tls`. OpenShift makes a Route from it, named `<ingress>-<suffix>` and
  deleted with it, and copies the Ingress's annotations onto that Route, so the generated Route is passthrough with
  the balance ([the route controller's `newRouteForIngress`](../../docs/mongot-route-balance-rationale.md#sources)).
  Without the termination annotation OpenShift makes an edge Route: no HTTP/2 to Envoy, and the router's 30 s
  `timeout server` cuts a search cursor.

No router timeout annotation is set: a passthrough Route's `timeout tunnel` default (1 h) covers the 300 s streams.

## Certificate rotation

Envoy reads the certificate files once, at start, and nothing it watches changes when a Secret is rotated
([`ENVOY-FLOW.md`](../../ENVOY-FLOW.md), "watched_directory matters"). After a rotation of the server certificate,
the client certificate or the trust bundle:

```bash
oc rollout restart deploy/<search.name>-public-lb -n <namespace>
```

The operator's own Envoy needs the same (`deploy/<search.name>-search-lb-0`, [`TLS.md`](../../TLS.md)). The new
certificate must still name every server name: the preflight checks it at the next upgrade, not at the rotation.

## Upgrade

```bash
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n <namespace> --reuse-values --set ...
```

The preflight runs again before anything changes. A changed bootstrap (a timeout, a server name, the port) restarts
the Envoy pods one at a time: the pod template carries the config's checksum. A changed `envoy.image` does the same.

**At an operator upgrade:** the bootstrap is a copy of the operator's configuration, and an operator that changes
its Envoy configuration is not followed automatically. Re-read the three files from the operator's running Envoy
into `docs/envoy/` (the commands in [`ENVOY-FLOW.md`](../../ENVOY-FLOW.md), "Getting the config out of the pod");
`test/vanity-chart.sh` then reports every field where the chart's bootstrap differs from the new capture, and the
template is changed to match.

## Uninstall

```bash
helm uninstall mongot-public -n <namespace>
```

Removes the Route (or Ingress and its generated Route), the Deployment, its Service, budget and config, and the
monitoring objects. The secrets, the trust bundle, the MongoDBSearch and the operator's Envoy are not the
release's and stay.

## Troubleshooting, by message

| Where | Message | Meaning |
| --- | --- | --- |
| preflight log | `MISSING: secret <name>: Error from server (NotFound)` | The secret is not in the namespace: a wrong `search.name`, `tls.certsSecretPrefix` or `namespace`, or the main chart's prerequisites not made |
| preflight log | `MISSING: secret <name>: no key tls.key` | The secret exists with other keys: it is not a `kubernetes.io/tls` secret of the prerequisites script |
| preflight log | `MISSING: secret <name>: its certificate does not name <host> (SANs: ...)` | The server certificate has no SAN for the hostname: issue one with it, or set `publicHostname` to a name it has |
| preflight log | `MISSING: service <name>-search-0-svc` | The operator has not made the mongot Service here: the MongoDBSearch is not installed, or `search.name` is wrong |
| preflight log | `REFUSED: the Job image ... has no openssl` | `jobs.image` names an image without `openssl`, so the certificate cannot be checked; it is never skipped |
| Envoy pod | `CreateContainerConfigError`, `secret "..." not found` | A secret was deleted after the preflight passed |
| Envoy log | `Failed to load certificate chain` | A rotated secret with a key that does not match its certificate; restart after the fix |
| client | handshake closed, no certificate served | The client's SNI is not in `serverNames`, or it dialled an IP and sent none |
| client | the router's default certificate (`CN=*.apps...`), no ALPN | Through the Route, the SNI matches no passthrough Route's host: the Route is not admitted, or DNS points at another router |
| client | `UNAVAILABLE` on every search | Envoy is up and mongot is not: readiness follows Envoy, not mongot. `oc get mongodbsearch`, and Envoy's `/stats` for `membership_healthy` |

Envoy's admin port answers `/ready`, `/stats`, `/logging` and `/drain_listeners`, and nothing else, as the
operator's; `/config_dump` returns 403. `membership_healthy` under `cluster.mongot_rs_cluster` is the number of mongot
pods Envoy can choose between.

## What it does not do

- Readiness follows Envoy, not mongot: a pod is Ready when Envoy's admin answers, as the operator's Envoy is.
- It does not watch the secrets: rotate, then restart (above).
- It does not follow the operator's Envoy configuration: the bootstrap is a copy, refreshed at operator upgrades.
- It serves no Route to the admin port, and the admin port is restricted to the four paths above.

## Tests

```bash
CONTAINER_ENGINE=docker test/vanity-chart.sh   # no cluster: lint, the renders, the schema's refusals, the bootstrap against docs/envoy/, envoy --mode validate, the preflight script against a stand-in oc
```

The lab run and the owner's OpenShift run are recorded in
[`docs/testing-mongot-envoy-vanity-url.md`](../../docs/testing-mongot-envoy-vanity-url.md).
