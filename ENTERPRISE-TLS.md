# Enterprise TLS: two options when the company CA signs only hostnames

Two ways to put MongoDB Search behind an OpenShift Route when **the company CA issues
certificates only for hostnames that clients dial**, and never for in-cluster services.
Both were deployed and measured end to end on this lab.

| | **Option 77: edge Route** | **Option 88: passthrough + internal CA** |
|---|---|---|
| Files | `manifests/77-*.yaml` | `manifests/88-*.yaml` + `80-route-passthrough.yaml` |
| Who terminates the client's TLS | the OpenShift router | Envoy |
| Encryption | mongod → router only; **plaintext** inside the cluster | **every hop** |
| mTLS | none | mongod ↔ Envoy and Envoy ↔ mongot |
| Company CA issues | the Route's hostname cert | Envoy's hostname cert + mongod's cert |
| cert-manager issues | nothing | Envoy client cert + mongot cert (namespace `Issuer`) |
| Cluster-wide change | HTTP/2 on the default IngressController | none |
| Balancing across Envoy replicas | **both** (21 / 22) | **pinned** to one (43 / 0) |
| Balancing across mongot | 12 / 14 / 14 | 13 / 13 / 14 |
| Result | **PASS** | **PASS** |

Pick **88** when policy requires encryption and mutual authentication on every hop.
Pick **77** when TLS to the cluster edge is enough and you want the fewest certificates.

> **Environment measured.** CRC on macOS, OpenShift 4.22.7, MongoDB Controllers for
> Kubernetes 1.12.0, `mongot` 1.70.1, CRC at 12 vCPU. The external replica set `rs0` runs
> in colima at `192.168.64.4`. The lab's `enterprise-ca` root stands in for the company CA.
> Every number below comes from these runs; statements taken from reading the operator
> source or the router template, rather than from a run, say so.

---

## 1. Why there are only these two

Of the three Route types (edge, passthrough, reencrypt), **passthrough** and
**reencrypt** keep traffic encrypted all the way to the pod. Only passthrough keeps the
*client's* certificate end to end, because with reencrypt the router decrypts and is the
client on the second leg.

**Reencrypt does not work with the operator's Envoy** (from code and the router template,
not run):

- Envoy's listener hardcodes `RequireClientCertificate: true`
  (`envoy_config_builder.go`, `buildDownstreamTLSTransportSocket`). No CRD field turns it off.
- The router's reencrypt backend line renders as
  `ssl alpn h2,http/1.1 … verifyhost … verify required ca-file …` — it presents **no
  client certificate** (`crt`), and the Route API has no field to give it one.

So the router would verify Envoy and then be refused for having no client certificate.
That leaves passthrough (option 88) for end-to-end, and edge (option 77) for TLS at the
router only.

## 2. One switch, one CA file

Two operator facts drive both designs (operator 1.12.0 source):

- **`spec.security.tls` is a single switch.** `IsTLSConfigured()` is just
  `Security.TLS != nil`, and it turns on TLS for Envoy's listener, Envoy's upstream to
  mongot, and mongot's listener together. They cannot be split.
- **Every verifier reads one CA file.** The ConfigMap in `spec.source.external.tls.ca`
  is mounted into Envoy as `ca-cert` and into mongot as `ca`. Envoy's listener, Envoy's
  upstream, mongot in mTLS mode, and mongot's sync leg all verify against that one
  `ca.crt`.

---

## 3. Option 77 — edge Route, TLS ends at the router

```text
mongod --TLS 1.3, ALPN h2--> router (edge, company cert) --h2c--> Envoy --h2c--> mongot :27028
   ^                                                                                  |
   +---------------------- TLS, verified with the CA ConfigMap only ------------------+
```

No certificate on Envoy or mongot. The only certificate in the cluster is the Route's.

### What makes it work

| Piece | Why | Measured |
|---|---|---|
| **HTTP/2 on the IngressController** | without it the router offers no ALPN and gRPC cannot get `h2` | before: `No ALPN negotiated`; after: `ALPN protocol: h2` |
| `appProtocol: kubernetes.io/h2c` on the Service | the router emits `proto h2` to the backend only when this is set | backend line: `… proto h2 check inter 5000ms` |
| `haproxy.router.openshift.io/timeout: 1h` | edge runs HAProxy in HTTP mode, default `timeout server 30s` | backend line: `timeout server  1h` |
| `spec.tls.externalCertificate` + Role/RoleBinding | keeps the key out of the Route; the router reads the Secret with its own service account | the Route API rejects the Route until the router can get/list/watch the Secret |
| CR with **no** `spec.security` | mongot gRPC stays `Disabled`, Envoy gets no cert mounts | mongot `mode: Disabled`, Envoy only `envoy-config`, 0 TLS sockets |
| `spec.source.external.tls.ca` kept | TLS on the sync leg only; mTLS is not switched on because gRPC is not TLS | sync `tls: enabled: true` |

**HTTP/2 is an annotation, not an env var.** The ingress operator owns the router
Deployment and turns the annotation into `ROUTER_DISABLE_HTTP2=false` (measured `true` →
`false` on the new router pod). Setting the env var yourself is reverted. There is no
per-Route switch: it covers every edge/reencrypt Route with its own certificate on that
IngressController; the default certificate stays `no-alpn`.

### Deploy

```bash
NS=mongodb-poc

# 1. HTTP/2 on the default router (cluster-wide)
oc annotate ingresscontroller default -n openshift-ingress-operator \
  ingress.operator.openshift.io/default-enable-http2=true
oc rollout status deploy/router-default -n openshift-ingress --timeout=300s
oc exec -n openshift-ingress deploy/router-default -- printenv ROUTER_DISABLE_HTTP2   # false

# 2. the company hostname certificate - a single serving cert, not a chain
oc create secret tls grpc-search-route-tls -n $NS --cert=grpc-search.crt --key=grpc-search.key

# 3. the three files - the Secret must exist first, the Route API checks it at admission
oc apply -f manifests/77-envoy-h2c-service.yaml
oc apply -f manifests/77-route-edge.yaml
oc apply -f manifests/77-search-plaintext-sync-tls.yaml
```

> **`oc apply` will not remove `spec.security` if it was added with `kubectl patch`.**
> Client-side apply deletes only fields recorded in its last-applied-configuration.
> Measured here: the apply reported `configured` and changed nothing, leaving Envoy on TLS
> behind a router sending h2c. Remove it explicitly:
>
> ```bash
> oc patch mongodbsearch mongot -n $NS --type=json -p '[{"op":"remove","path":"/spec/security"}]'
> ```

### Verify

```bash
openssl s_client -connect <router>:443 -servername grpc-search.apps-crc.testing \
  -alpn h2 -CAfile company-root.crt </dev/null 2>/dev/null | grep -E 'ALPN|Verify return'
#   ALPN protocol: h2
#   Verify return code: 0 (ok)
cd mongodb && ./scripts/verify-search.sh
```

Measured: `$search`, `$vectorSearch` and filtered `$vectorSearch` PASS; 40 queries split
**12 / 14 / 14** across mongot and **21 / 22** across the two Envoy replicas — in HTTP mode
the router balances each gRPC request, not each connection. Envoy's access log shows
`/mongodb.CommandService/UnauthenticatedCommandStream grpc_status=OK`. A query after 75s
idle (router `timeout client 30s`) succeeded in 20ms. **Not measured:** a single query
running longer than 30s.

### What it gives up

Router → Envoy → mongot is plaintext. mongod's client certificate is not checked: the
router does not request one. `IngressController.spec.clientTLS` can require client
certificates, but only per IngressController — `Required` would apply to every edge and
reencrypt Route on it.

---

## 4. Option 88 — passthrough, company cert at the edge, internal CA inside

```text
mongod --mTLS--> router (passthrough, never decrypts) --mTLS--> Envoy --mTLS--> mongot :27028
  ^                                                                                  |
  +--------------------------------- TLS (sync) -------------------------------------+
```

The same topology as `20-tls-search-managed-envoy.yaml`. The CR differs in two fields:

```text
certsSecretPrefix:           lab                -> ent
source.external.tls.ca.name: external-mongod-ca -> ent-trust-bundle
```

### Who issues what

| Secret / file | Role | Issuer |
|---|---|---|
| `ent-mongot-search-lb-0-cert` | Envoy server cert; first SAN = `externalHostname` = Route host | **company CA**, imported |
| mongod's certificate (on the mongod hosts) | server + client auth | **company CA** |
| `ent-mongot-search-lb-0-client-cert` | Envoy → mongot client | `internal-ca` (`88-internal-certs.yaml`) |
| `ent-mongot-search-cert` | mongot server | `internal-ca` |
| `ent-trust-bundle` ConfigMap, key `ca.crt` | trust for every in-cluster verifier | company root **+** internal root |

`internal-ca` is a namespace-scoped `Issuer` (`88-internal-ca.yaml`); its root never
leaves the cluster. mongod needs no change: it sees only the company-issued hostname cert.

### The trust bundle needs both roots — tested

| Root in `ent-trust-bundle` | Needed for |
|---|---|
| **the CA that signed mongod** | Envoy verifying mongod's client cert; mongot verifying mongod's server cert |
| **the internal CA** | Envoy and mongot verifying each other |

The hostname cert's CA is not needed in the bundle for its own sake — mongod verifies that
cert with its own `--tlsCAFile`. It is in the bundle here only because the same company
root also signed mongod.

Measured with **only the company root** in the bundle, after restarting Envoy and mongot:

| Hop | Result |
|---|---|
| mongod → Envoy | still works; Envoy's acceptable client CAs list only the company root |
| Envoy → mongot | **fails**: `ssl.fail_verify_error: 12`, `upstream_cx_connect_fail: 12`, `ssl.handshake: 0` |
| mongod's search | `HostUnreachable … TLS_error … CERTIFICATE_VERIFY_FAILED` |
| Envoy access log | `grpc=Unavailable flags=URX,UF` |
| Pods | **all Ready** — a trust failure never shows in pod status |

Restoring both roots and restarting brought search back.

### Deploy

```bash
NS=mongodb-poc

# 1. the internal CA and the two internal certificates
oc apply -f manifests/88-internal-ca.yaml
oc wait certificate/internal-root-ca -n $NS --for=condition=Ready --timeout=120s
oc apply -f manifests/88-internal-certs.yaml
oc wait certificate/ent-mongot-search-lb-0-client-cert certificate/ent-mongot-search-cert \
  -n $NS --for=condition=Ready --timeout=120s

# 2. the company hostname certificate, under the name the operator derives
oc create secret tls ent-mongot-search-lb-0-cert -n $NS \
  --cert=grpc-search-fullchain.crt --key=grpc-search.key

# 3. the trust bundle: company root + internal root, key ca.crt
oc get secret internal-root-ca -n $NS -o jsonpath='{.data.ca\.crt}' | base64 -d > internal-root.crt
cat company-root.crt internal-root.crt > ca.crt
oc create configmap ent-trust-bundle -n $NS --from-file=ca.crt=ca.crt

# 4. passthrough Route, then the CR
oc apply -f manifests/80-route-passthrough.yaml
oc apply -f manifests/88-tls-search-managed-envoy.yaml
oc rollout restart deploy/mongot-search-lb-0 -n $NS    # Envoy does not reload certificates
```

### Verify

```bash
# Envoy demands a client cert, and names the roots it accepts
openssl s_client -connect <router>:443 -servername grpc-search.apps-crc.testing -alpn h2 \
  </dev/null 2>/dev/null | sed -n '/Acceptable client certificate CA names/,/Requested/p'
cd mongodb && ./scripts/verify-search.sh
```

Measured: Envoy mounts `ent-mongot-search-lb-0-cert`, `ent-…-client-cert` and
`ent-trust-bundle`; mongot runs `mode: mTLS` and presents the internal-CA cert; ALPN `h2`;
**both** roots listed as acceptable client CAs; `$search`, `$vectorSearch` and filtered
`$vectorSearch` PASS; 40 queries **13 / 13 / 14** across mongot; Envoy **43 / 0** —
passthrough pins mongod's one connection to one Envoy, which still spreads requests over
every mongot. Through the search GUI (`95-search-gui.yaml`), six text queries rotated
across pods `1 → 0 → 2 → 1 → 0 → 2`.

### Risks to manage

- **Trust widening.** Envoy's listener has no SAN match, so it accepts a client cert from
  **either** root — measured: both roots listed. Anyone who can use `internal-ca` can
  connect to the front door as if they were mongod. Restrict who may create Certificates
  and use Issuers in the namespace.
- **mongod needs a client certificate** with `clientAuth`. A private company CA can issue
  it. Public CAs are dropping `clientAuth` from TLS certificates: Sectigo and DigiCert
  stopped on 2026-05-01, and the Chrome Root Program requires serverAuth-only for all new
  public TLS certificates from 2027-03-15.
- **Envoy does not reload renewed certificates.** mongot restarts on its own (hash-named
  PEM); Envoy keeps the old certificate until `oc rollout restart deploy/mongot-search-lb-0`.
  The internal certificates last one year and renew 30 days before expiry.
- **Avoiding the two-root bundle** would need the internal CA to be a subordinate of the
  company CA, so the bundle holds only the company root. Not tested.

---

## 5. Where each CA must be trusted

| Place | Option 77 | Option 88 |
|---|---|---|
| CA ConfigMap (`spec.source.external.tls.ca`) | the CA that signed mongod | the CA that signed mongod **+** the internal CA |
| mongod hosts, `--tlsCAFile` | the CA that signed the Route's hostname cert | the CA that signed Envoy's hostname cert |

## 6. Switching between them

The two options share the Route name and host (`mongot-grpc`,
`grpc-search.apps-crc.testing`), so mongod never changes: `mongotHost` stays
`grpc-search.apps-crc.testing:443` with `searchTLSMode=requireTLS`.

| From → to | Steps |
|---|---|
| 77 → 88 | the 88 deploy steps above; `oc apply -f manifests/80-route-passthrough.yaml` removes the edge-only fields |
| 88 → 77 | the 77 deploy steps, including the explicit `oc patch … remove /spec/security` |

HTTP/2 on the router does not affect a passthrough Route, so it can stay on for either.

## 7. Caveats worth knowing

- **Pod readiness does not cover TLS between tiers.** Every pod stayed Ready while search
  was down with `CERTIFICATE_VERIFY_FAILED`. Check with a query or with Envoy's
  `cluster.mongot_rs_cluster.ssl.fail_verify_error`.
- **`verify-search.sh` does not check the spread.** Its PASS line tests only
  `TOTAL >= QUERIES`, so it prints "spread across 3 pods" even when one pod got 0 —
  observed once, right after a rolling restart. Read the per-pod numbers.
- **The operator reports `Running` with 0 mongot.** `clusters[].replicas: 0` reconciles to
  a green status.

See [TLS.md](TLS.md) for the Secret naming contract, the source-TLS coupling, and
certificate rotation in general.
