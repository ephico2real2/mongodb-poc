# Design notes and findings

Decisions taken while building this, and the things that were only discovered by
reading the Operator source or by running it. Kept because each one cost time.

See [README.md](README.md) for the architecture and [DEPLOYMENT.md](DEPLOYMENT.md) for
the full walkthrough.

---

## 1. Managed vs unmanaged Envoy

`MongoDBSearch.spec.clusters[].loadBalancer` takes exactly one of:

| Mode | Meaning |
|---|---|
| `managed: {}` | The Operator deploys and configures Envoy itself. **Chosen here.** |
| `unmanaged: { endpoint: "host:port" }` | You bring your own L7 — Envoy Gateway, a mesh, anything. |

**Why managed.** It removes Gateway API from the picture entirely: no `GatewayClass`,
no `GRPCRoute`, no `BackendTLSPolicy`, and therefore no dependency on which Gateway API
CRDs the OpenShift Ingress Operator owns — which differs by release:

| OpenShift | Gateway API | Platform-managed CRDs | `BackendTLSPolicy` managed |
|---|---|---|---|
| 4.18 | v1.0.0 | 4 — featuregate off by default | no |
| 4.19 | v1.2.1 | 5 (+ `GRPCRoute`) | no |
| 4.20 | v1.4.0 | 5 | no |
| 4.21 | v1.4.1 | 5 | no |
| 4.22 | v1.4.1 | **6** | **yes** |

Read from `managedCRDs` in `cluster-ingress-operator` per release branch. Note the
Operator overwrites a pre-existing CRD's spec unconditionally — `crdChanged()` does
`updated.Spec = expected.Spec` with no version comparison — so installing your own
Gateway API CRDs on 4.18 creates an upgrade landmine at 4.19.

**What managed gives you for free.** From `envoy_config_builder.go`:

- retry on `connect-failure,refused-stream,unavailable,reset,resource-exhausted`
- a **`previous_hosts` predicate** so a retry lands on a *different* `mongot`
- `stream_idle_timeout`, `request_timeout` and route timeout all 300s
- 1 MiB HTTP/2 initial stream and connection windows, keepalive 60s/10s
- circuit breakers at 1024 / 1024 / 1024 / 3

Envoy Gateway's `BackendTrafficPolicy` can express the retry *triggers* but has **no
field for the host predicate**, so a BYO proxy can retry onto the pod that just shed
load. Closing that gap needs an `EnvoyPatchPolicy`.

---

## 2. What actually triggers the Envoy deployment

Only `spec.clusters` is `+kubebuilder:validation:Required`. `version`, `source` and
`security` are all `+optional`. **The presence of `loadBalancer.managed` is what creates
Envoy**, producing:

| Object | Name |
|---|---|
| Envoy Deployment | `<name>-search-lb-<idx>` — pod label `app=<name>-search-lb-<idx>` |
| Envoy config | `<name>-search-lb-<idx>-config` (lds.json / cds.json) |
| Proxy Service | `<name>-search-<idx>-proxy-svc` — **ClusterIP, hardcoded** |
| `mongot` StatefulSet | `<name>-search-<idx>` |
| `mongot` headless Service | `<name>-search-<idx>-svc` (`clusterIP: None`) |

The proxy Service's selector **starts pointed at `mongot`** and only flips to Envoy once
the load-balancer substatus reports Ready. Inspect it too early and it looks unwired
when it is merely unpromoted.

---

## 3. `externalHostname` is inert without TLS

`externalHostname` is required by the validator for an external source with a managed
load balancer, and the error says why: *"Envoy needs the hostname for SNI matching."*

But SNI matching only happens when TLS is on. From `buildFilterChain`:

```go
if tlsEnabled {
    chain.FilterChainMatch = &listenerv3.FilterChainMatch{ServerNames: []string{route.SNIHostname}}
    ts, err := buildDownstreamTLSTransportSocket(caKeyName)
}
```

No TLS → no `FilterChainMatch`, no SNI, no certificate. The field is still **mandatory**,
still validated, and completely inert. Plan around this: a plaintext deployment must
still supply a hostname it does not use.

When TLS *is* on, `externalHostname` overrides the default SNI hostname:

```go
sniHostname := fmt.Sprintf("%s.%s.svc.cluster.local", sniServiceName, namespace)
if endpoint := search.GetManagedLBEndpointForClusterShard(clusterName, shardName); endpoint != "" {
    sniHostname = endpoint
}
```

so `mongod`'s SNI, the Route host (if any) and `externalHostname` must all be the same
string, and Envoy's server certificate must carry it as a SAN.

---

## 4. Fields that are optional but should not be omitted

| Field | If omitted |
|---|---|
| `spec.source.username` / `passwordSecretRef` | Defaults to user `search-sync-source` and Secret `{name}-{username}-password`. That Secret must exist or reconcile fails. |
| `spec.source.external.tls.ca` | If the external `mongod` requires TLS, `mongot` has no CA to validate it and the sync leg never connects. |
| `spec.version` | Falls back to the Operator's built-in default. Pin it. |
| `metadata.namespace` | Lands in whatever namespace is current. |

---

## 5. `hostAndPorts` is a seed list, not the traffic path

The driver connects to a seed, reads the replica-set configuration, then uses the
**advertised** member hostnames for everything afterwards. Pointing the seed at an FQDN
while the set still advertises IPs changes nothing after the first round trip.

Running on names requires three things to agree:

1. `rs.reconfig()` so members advertise the FQDN
2. name resolution on the `mongod` side (`extra_hosts`, or real DNS)
3. name resolution inside the cluster

For (3), **OpenShift's DNS operator cannot create static A records.** Its only fields are
`cache`, `servers`, `upstreamResolvers` and `nodePlacement`, and `servers[].forwardPlugin`
is *"proxy DNS messages to upstream resolvers"* — zone forwarding only. Editing the
`openshift-dns` CoreDNS ConfigMap is unsupported.

The supported pattern is a **selector-less headless Service plus a hand-written
EndpointSlice** (`manifests/40-external-mongod-dns.yaml`), or `hostAliases` under
`spec.clusters[].statefulSet.spec.template.spec.hostAliases`.

---

## 6. The Operator will never give you a LoadBalancer

`ManagedLBConfig` has no Service field at all:

```go
type ManagedLBConfig struct {
	ExternalHostname       string
	RouterHostname         string
	Replicas               *int32
	ResourceRequirements   *corev1.ResourceRequirements
	Deployment             *v1.DeploymentConfiguration
	RetryPolicy            *EnvoyRetryPolicy
	MinMongotReadyReplicas *int32
}
```

and `buildProxyService()` hardcodes `SetServiceType(corev1.ServiceTypeClusterIP)`. A
hand-written Service selecting `app=<name>-search-lb-<idx>` is the only way to expose
Envoy. It carries two hazards: **no `ownerReference`** (survives CR deletion, never
reconciled) and a selector copied from an Operator-internal naming convention.

---

## 7. Operational findings

**MetalLB supports `AllNamespaces` only.** An `OperatorGroup` with `targetNamespaces` set
fails the CSV with:

```
reason=UnsupportedOperatorGroup
message=OwnNamespace InstallModeType not supported, cannot configure to watch own namespace
```

The `OperatorGroup` must be `spec: {}`. Deleting a failed CSV by hand also strands the
Subscription in `UpgradePending` — delete and recreate the Subscription to recover.

**MCK ships in the certified catalog**, which is disabled by default on some clusters:

```bash
oc patch operatorhub cluster --type=merge \
  -p '{"spec":{"sources":[{"name":"certified-operators","disabled":false}]}}'
```

**The localhost exception permits `createUser` but not `usersInfo`.** A script that checks
`getUser()` before creating the first user fails with *not authorized*. Attempt the
create and treat code `51003` as success.

**`searchCoordinator` is built in from MongoDB 8.2+.** On older servers the Operator
creates it as a custom role.

**`mongod` accepts the search parameters at startup.** Confirmed in the log:

```
"Applied --setParameter options" ... "mongotHost":{"default":"","value":"..."},
"searchTLSMode":{"default":"globalTLS","value":"disabled"},
"useGrpcForSearch":{"default":false,"value":true}
```

---

## 8. TLS on an external source is not per-leg (solved — here is the recipe)

Attempting to enable TLS so a passthrough `Route` could be tested produced a
**status-green, config-valid, completely broken** data path. Worth knowing before
planning a TLS rollout.

### What happens

Set `spec.security.tls.certsSecretPrefix` with `spec.source.external` and no
`spec.source.external.tls`, and the operator will:

- generate an Envoy listener with `tls_inspector`, an SNI `filter_chain_match` and a
  `transport_socket` referencing `/etc/envoy/tls/server/tls.crt`, `.../tls.key`
  and `/etc/envoy/tls/ca/ca-pem`
- switch `mongot` to `server.grpc.tls.mode: TLS` and roll the StatefulSet
- **never mount those cert files into the Envoy pods** — the Deployment stays at
  `generation=1` with only `envoy-config -> /etc/envoy`
- report `phase=Running` with no warning, and log
  `Envoy Deployment created/updated` as though it had

The result: `mongod` gets `upstream connect error or disconnect/reset before headers`,
and a TLS client gets `wrong version number`, while every status field says healthy.

### Why

Three lines, in three files:

```go
// mongodbsearchenvoy_controller.go:625 - the cert volumes are gated on tlsCfg
if tlsEnabled && tlsCfg != nil { /* mount envoy-server-cert, -client-cert, ca-cert */ }

// external_search_source.go:36 - tlsCfg is nil unless the SOURCE has TLS
func (r *externalSearchResource) TLSConfig() *TLSSourceConfig {
    if r.spec.TLS == nil { return nil }     // spec.source.external.tls

// mongodbsearch_reconcile_helper.go:2022 - and setting it turns on the sync leg
scramTLS := &mongot.ScramAuthTLS{ Enabled: true, CertificateAuthorityFile: ... }
```

So Envoy's **downstream** TLS (client → Envoy) is gated on the **source's** TLS config
(`mongot` → `mongod`) — two unrelated legs coupled through one nil check.

### What it means in practice

**For an external source you cannot TLS one leg without the other.** Enabling
`security.tls` obliges you to also:

1. set `spec.source.external.tls.ca` to a ConfigMap holding `ca.crt`, and
2. actually run the external `mongod` with TLS, because that CA now makes `mongot`
   connect to it over TLS

A plan that says "terminate TLS at Envoy first, secure the database later" is not
available here. Budget both together, or stay plaintext deliberately.

### The working configuration

Both fields together, plus TLS on the external `mongod` itself. Verified end to end:

```yaml
spec:
  security:
    tls:
      certsSecretPrefix: lab              # -> lab-mongot-search-cert
                                          #    lab-mongot-search-lb-0-cert
                                          #    lab-mongot-search-lb-0-client-cert
  source:
    external:
      hostAndPorts: ["192.168.64.4:27017", "...:27018", "...:27019"]
      tls:
        ca: { name: external-mongod-ca }  # ConfigMap with ca.crt - REQUIRED, or the
                                          # Envoy cert volumes are never mounted
  clusters:
  - loadBalancer:
      managed:
        externalHostname: grpc-search.apps-crc.testing
```

and on the external `mongod`:

```text
--tlsMode=preferTLS                       # mongot now connects over TLS
--tlsCertificateKeyFile=/run/lab/mongod.pem
--tlsCAFile=/run/lab/ca.crt
--setParameter=searchTLSMode=requireTLS
--setParameter=mongotHost=grpc-search.apps-crc.testing:443
```

Applying `spec.source.external.tls.ca` is what flips the Deployment:

```text
before:  envoy-config -> /etc/envoy
after:   envoy-config       -> /etc/envoy
         envoy-server-cert  -> /etc/envoy/tls/server
         envoy-client-cert  -> /etc/envoy/tls/client
         ca-cert            -> /etc/envoy/tls/ca
```

### One hostname serves both entry paths

**SNI carries the hostname only — never the port.** So a single `externalHostname`, a
single certificate and a single filter chain serve the VIP and the Route; only the port
differs:

| `mongotHost` | Path |
|---|---|
| `grpc-search.apps-crc.testing:27028` | → MetalLB VIP → Envoy |
| `grpc-search.apps-crc.testing:443` | → router → passthrough Route → Envoy |

Both verified, each distributing across all three `mongot` (13/13/14 and 14/13/13 of 40).

That matters because Envoy builds **one** filter chain matching **one**
`server_names` value. Two different hostnames would need two `externalHostname` values,
which the single-cluster spec has no room for — so if you want both entry paths, give
them the same name and different ports. The certificate may still carry extra SANs
(`vip-grpc-search.apps-crc.testing`, the VIP IP) for clients that address it differently,
but only the `externalHostname` value will match the filter chain.

### Consequence for Routes

A passthrough `Route` routes on SNI, and SNI exists only in a TLS `ClientHello` — so a
Route needs Envoy TLS, which needs source TLS, which needs a TLS-enabled `mongod`.
**Route, Envoy TLS and database TLS are one decision, not three.** Once TLS is in place
the Route works exactly as well as the VIP — both were measured distributing across all
three `mongot`. The VIP simply does not *force* the decision.

The certificate manifests are kept in `manifests/70-tls-certs.yaml` with the correct
derived Secret names, ready for when the source is TLS-enabled too.

---

## 8. Edition support

MongoDB's compatibility matrix is explicit, and it is about **editions**, not topology:

| Search | `mongod` source | Supported |
|---|---|---|
| Community, MCK-managed | Community Server, tarball/container | ❌ |
| Community, MCK-managed | Community Server, MCK-managed | ✅ |
| Enterprise, MCK-managed | Enterprise, external / self-hosted | ✅ |

The external-`mongod` *pattern* is first-class — `spec.source.external` exists precisely
for it, and MongoDB's own CI exercises it. What is unsupported for production is the
**Community + external** combination specifically. Rehearsing the Enterprise-external
topology on Community is a reasonable lab; shipping it is not.
