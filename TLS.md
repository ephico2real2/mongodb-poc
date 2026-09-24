# TLS setup guide

How to turn on TLS for MongoDB Search, with **cert-manager** or with **your own CA and
`openssl`** when certificates are issued outside OpenShift.

Verified end to end: `$search` and `$vectorSearch` over TLS, through both a MetalLB VIP
and a passthrough Route, distributing across all three `mongot`.

---

## 1. What TLS actually covers

Three legs, and they are **not** independently switchable:

```text
  mongod  --(A) TLS-->  Envoy  --(B) mTLS-->  mongot
     ^                                           |
     +---------------(C) TLS --------------------+
                     sync leg, never crosses Envoy
```

| Leg | Turned on by | Certificate |
|---|---|---|
| **A** client → Envoy | `spec.security.tls.certsSecretPrefix` | `<prefix>-<name>-search-lb-<idx>-cert` |
| **B** Envoy → `mongot` | same field — not separable | `<prefix>-<name>-search-lb-<idx>-client-cert` + `<prefix>-<name>-search-cert` |
| **C** `mongot` → `mongod` | `spec.source.external.tls.ca` | the external `mongod`'s own server cert |

**Enabling TLS changes no ports.** `EnvoyDefaultProxyPort` and `MongotDefaultGrpcPort`
are both the constant `27028` with no TLS variant; TLS is negotiated in-band over ALPN on
the same listener. No new firewall rules.

## 2. The coupling you cannot avoid (external sources)

With `spec.source.external`, **leg A requires leg C.** Envoy's certificate volumes are
gated on the *source's* TLS config:

```go
// mongodbsearchenvoy_controller.go:625
if tlsEnabled && tlsCfg != nil { /* mount envoy-server-cert, -client-cert, ca-cert */ }
// external_search_source.go:36
if r.spec.TLS == nil { return nil }       // spec.source.external.tls
```

Set `certsSecretPrefix` without `source.external.tls.ca` and the operator reports
`phase=Running` while generating an Envoy config that references cert files it never
mounts. The path dies with `upstream connect error or disconnect/reset before headers`,
and nothing in any status field says so.

You can watch the difference:

```text
without source.external.tls.ca:   envoy-config -> /etc/envoy
with it:                          envoy-config      -> /etc/envoy
                                  envoy-server-cert -> /etc/envoy/tls/server
                                  envoy-client-cert -> /etc/envoy/tls/client
                                  ca-cert           -> /etc/envoy/tls/ca
```

**Plan Envoy TLS and database TLS as one piece of work.** "Terminate at the proxy now,
secure the database later" is not available.

## 3. The Secret naming contract

Names are **derived, not chosen**. With `certsSecretPrefix: lab`, CR name `mongot`,
cluster index `0`:

| Secret | Role | SANs it must carry |
|---|---|---|
| `lab-mongot-search-lb-0-cert` | Envoy server cert | **`externalHostname`** (and the Route host, if used) |
| `lab-mongot-search-lb-0-client-cert` | Envoy → `mongot` client | none required |
| `lab-mongot-search-cert` | `mongot` server cert | the `mongot` Service FQDNs |

Each must be type `kubernetes.io/tls` with **`tls.crt`** and **`tls.key`**. Plus a
ConfigMap for the source CA, with key **`ca.crt`**.

Get a name wrong and the operator does not error — it simply does not find the Secret.

> The operator creates its own copy, `<name>-search-certificate-key`, an `Opaque` Secret
> holding a single **hash-named** `.pem` (cert and key concatenated). That is deliberate:
> changing the certificate changes the filename, which changes the pod spec, which forces
> a restart. `mongot` reads certificates only at startup.

## 4. One hostname serves both entry paths

**SNI carries the hostname only, never the port.** So one `externalHostname`, one
certificate and one Envoy filter chain cover both entry methods — only the port differs:

| `mongotHost` on the external `mongod` | Path |
|---|---|
| `grpc-search.corp.example:27028` | → MetalLB VIP → Envoy |
| `grpc-search.corp.example:443` | → router → passthrough Route → Envoy |

This matters because Envoy builds **one** filter chain matching **one** `server_names`
value, and the single-cluster spec has no room for a second `externalHostname`. If you
want both entry paths, give them **the same name on different ports**. Extra SANs on the
certificate are fine for clients that address it differently, but only the
`externalHostname` value matches the filter chain.

---

## 5. Option A — cert-manager

What this repository uses. See `manifests/70-tls-certs.yaml`.

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: mongot-selfsigned, namespace: mongodb-poc }
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: mongot-ca, namespace: mongodb-poc }
spec:
  isCA: true
  commonName: mongot-poc-ca
  secretName: mongot-ca
  privateKey: { algorithm: RSA, size: 2048 }
  issuerRef: { name: mongot-selfsigned, kind: Issuer, group: cert-manager.io }
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: mongot-ca-issuer, namespace: mongodb-poc }
spec:
  ca: { secretName: mongot-ca }
---
# Envoy server cert - secretName MUST match the derived name
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: lab-mongot-search-lb-0-cert, namespace: mongodb-poc }
spec:
  secretName: lab-mongot-search-lb-0-cert
  commonName: grpc-search.corp.example
  dnsNames:
  - grpc-search.corp.example          # == externalHostname == Route host
  - vip-grpc-search.corp.example      # optional extra SAN
  - mongot-search-0-proxy-svc.mongodb-poc.svc.cluster.local
  ipAddresses: [ "192.168.127.100" ]  # optional, if clients dial the VIP directly
  usages: [server auth, digital signature, key encipherment]
  issuerRef: { name: mongot-ca-issuer, kind: Issuer, group: cert-manager.io }
```

With a **corporate** cert-manager issuer, replace `issuerRef` with the real
`ClusterIssuer` and delete the self-signed bootstrap. Everything else is unchanged.

**In production, prefer a real issuer.** A self-signed CA created in the namespace means
the private key lives in a Secret next to the workload it signs for.

---

## 6. Option B — your own CA, signed outside OpenShift

For a corporate PKI where signing happens on an offline CA or through a ticketed process.
The cluster never sees the CA key.

### 6.1 Generate the key and CSR (per certificate)

SANs must be in the CSR, so use a config file — `-subj` alone will not carry them.

```bash
cat > envoy-server.cnf <<'EOF'
[req]
distinguished_name = dn
req_extensions     = v3_req
prompt             = no
[dn]
CN = grpc-search.corp.example
O  = Example Corp
[v3_req]
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt
[alt]
DNS.1 = grpc-search.corp.example
DNS.2 = vip-grpc-search.corp.example
DNS.3 = mongot-search-0-proxy-svc.mongodb-poc.svc.cluster.local
IP.1  = 192.168.127.100
EOF

openssl req -new -newkey rsa:2048 -nodes \
  -keyout envoy-server.key -out envoy-server.csr -config envoy-server.cnf
```

Repeat for:

| Certificate | CN | `extendedKeyUsage` | SANs |
|---|---|---|---|
| Envoy server | `grpc-search.corp.example` | `serverAuth` | as above |
| Envoy client | `envoy-client` | `clientAuth` | none required |
| `mongot` server | `mongot-search-0-svc.<ns>.svc.cluster.local` | `serverAuth, clientAuth` | that FQDN, `*.` of it, the proxy-svc FQDN |
| external `mongod` | your DB hostname | `serverAuth, clientAuth` | every name **and IP** the replica set advertises |

The `mongod` certificate must cover **exactly what `rs.conf()` advertises**. If members
advertise IPs, the certificate needs IP SANs — a DNS SAN will not match.

### 6.2 Sign on the CA

```bash
openssl x509 -req -in envoy-server.csr \
  -CA corporate-ca.crt -CAkey corporate-ca.key -CAcreateserial \
  -out envoy-server.crt -days 90 -sha256 \
  -extfile envoy-server.cnf -extensions v3_req     # <- or the SANs are dropped
```

`-extfile`/`-extensions` are not optional: without them `openssl x509` silently discards
the CSR's extensions and you get a certificate with no SANs, which fails verification in
a way that looks like a trust problem.

Verify before shipping:

```bash
openssl x509 -in envoy-server.crt -noout -subject -ext subjectAltName -dates
openssl verify -CAfile corporate-ca.crt envoy-server.crt
```

### 6.3 Load into the cluster, under the derived names

```bash
NS=mongodb-poc

oc create secret tls lab-mongot-search-lb-0-cert -n $NS \
  --cert=envoy-server.crt --key=envoy-server.key --dry-run=client -o yaml | oc apply -f -

oc create secret tls lab-mongot-search-lb-0-client-cert -n $NS \
  --cert=envoy-client.crt --key=envoy-client.key --dry-run=client -o yaml | oc apply -f -

oc create secret tls lab-mongot-search-cert -n $NS \
  --cert=mongot-server.crt --key=mongot-server.key --dry-run=client -o yaml | oc apply -f -

# the source CA - a ConfigMap, key must be ca.crt
oc create configmap external-mongod-ca -n $NS \
  --from-file=ca.crt=corporate-ca.crt --dry-run=client -o yaml | oc apply -f -
```

If the corporate CA is an intermediate, `--cert` should be the **full chain**
(leaf first, then intermediates), and `ca.crt` should contain the anchor the peer needs.

### 6.4 The external `mongod`

`mongod` wants certificate and key concatenated in one file:

```bash
cat mongod.crt mongod.key > mongod.pem     # order matters
chmod 400 mongod.pem
```

```text
--tlsMode=preferTLS                     # requireTLS once every client is ready
--tlsCertificateKeyFile=/run/lab/mongod.pem
--tlsCAFile=/run/lab/ca.crt
--setParameter=searchTLSMode=requireTLS
--setParameter=mongotHost=grpc-search.corp.example:443
```

`preferTLS` accepts both plaintext and TLS, which lets you enable TLS for `mongot`
without breaking existing clients. Move to `requireTLS` once they have all migrated.

---

## 6a. Option C — an enterprise signer

Most organisations sign through a corporate PKI rather than a namespace-local CA. Two
shapes, and both leave sections 3, 4 and 7 unchanged — only the issuer differs.

### Through cert-manager, against the enterprise CA

If a `ClusterIssuer` already exists (this cluster has `ldap-enterprise-ca`), point at it
and delete the self-signed bootstrap entirely:

```yaml
  issuerRef:
    name: ldap-enterprise-ca      # or your Venafi / ADCS / ACME ClusterIssuer
    kind: ClusterIssuer           # note: ClusterIssuer, not Issuer
    group: cert-manager.io
```

```bash
oc get clusterissuer            # what is actually available and Ready
```

This is the best of both: enterprise-signed, and still auto-renewing. Check what the
issuer will actually grant before relying on it — enterprise policy commonly caps
lifetime, restricts SAN types (IP SANs are often refused), and may ignore your requested
`extendedKeyUsage`. An IP SAN refusal matters here: it forces `mongotHost` onto a
hostname, which TLS needs anyway.

### Through a ticketed / offline signing process

When signing is a human process, generate the CSRs as in section 6.1, submit them, and
load the returned certificates as in section 6.3. The cluster never holds the CA key.

The trade-off is that **nothing renews automatically**. Section 8 applies in full: put
expiry on a calendar, because neither the operator nor OpenShift will warn you, and
`phase=Running` stays green right up to the moment handshakes start failing.

> **Ask the CA team for these specifically**, or expect a second round trip:
> `subjectAltName` entries exactly as listed in section 6.1 · `extendedKeyUsage` of
> `serverAuth` for the Envoy and `mongot` server certs, `clientAuth` for the Envoy client
> cert, and **both** for the `mongod` cert · the **full chain** if signing is via an
> intermediate · and the anchor as a separate PEM for `ca.crt`.

---

## 6b. The OpenShift Route, verified

The Route entry as actually deployed and serving traffic
(`manifests/80-route-passthrough.yaml`):

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: mongot-grpc
  namespace: mongodb-poc
spec:
  host: grpc-search.apps-crc.testing    # == externalHostname == a SAN on the Envoy cert
  to:
    kind: Service
    name: mongot-search-0-proxy-svc     # the OPERATOR's Service - no MetalLB,
    weight: 100                         # no hand-written LoadBalancer Service needed
  port:
    targetPort: 27028                   # numeric port, not a port name
  tls:
    termination: passthrough
  wildcardPolicy: None
```

```text
status.ingress[0]:  routerName=default  host=grpc-search.apps-crc.testing  Admitted=True
measured:           $search + $vectorSearch PASS, 13 / 13 / 14 of 40 across three mongot
```

Four things decide whether this works:

1. **`passthrough`, never `edge` or `reencrypt`.** Edge does not support HTTP/2 at all so
   gRPC breaks; both edge and reencrypt use `timeout server`, default **30s**, which
   severs search cursors. Passthrough uses `timeout tunnel`, default **1h**.
2. **It requires TLS.** Passthrough selects the backend by SNI. Against a plaintext Envoy
   you get `DPE`/400 — the request reaches Envoy and dies on the protocol.
3. **`host` must equal `externalHostname`** and be a SAN on the Envoy server certificate.
   One string in four places: the client's `mongotHost`, the Route `host`,
   `externalHostname`, and the certificate SAN.
4. **`Admitted=True` proves nothing about the data path.** The Route reported `Admitted`
   throughout the period when every request through it was failing. It means the router
   parsed the object.

**With an F5 in front**, keep it L4/fastL4 — never an HTTP profile, which can downgrade
to HTTP/1.1 and break gRPC. F5 CIS implements passthrough as an SNI-parsing iRule, which
is L4 and correct. The public port stays 443; 27028 never leaves the cluster.

---

## 7. The CR, either way

```yaml
spec:
  security:
    tls:
      certsSecretPrefix: lab
  source:
    external:
      hostAndPorts: ["mongod-1.corp:27017", "mongod-2.corp:27017", "mongod-3.corp:27017"]
      tls:
        ca: { name: external-mongod-ca }     # REQUIRED - see section 2
    username: search-sync-source
    passwordSecretRef: { name: mongot-search-sync-source-password }
  clusters:
  - replicas: 3
    loadBalancer:
      managed:
        externalHostname: grpc-search.corp.example
```

## 8. Handling it over time

**Rotation forces a restart.** `mongot` reads certificates only at startup. The operator
makes this deterministic: its `<name>-search-certificate-key` copy is a **hash-named**
PEM, so new content produces a new filename, a new pod spec and a rolling restart. With
`clusters[].replicas >= 2` and `loadBalancer.managed.replicas >= 2` that is absorbed for
new streams — in-flight streams on a restarting pod still break, because a response
already begun cannot be retried.

**CA rotation is a different, harder operation** than leaf renewal. Distribute the new
trust bundle to every consumer *first* — `mongot`, Envoy, and every external `mongod` —
then issue new leaves, then withdraw the old anchor. The source CA is a ConfigMap and can
hold **both** anchors during the overlap.

**Expiry is not surfaced by the operator.** With cert-manager, `Certificate` resources
renew themselves (default: 2/3 through the lifetime) — but a certificate you issued
externally has no such machinery, and `phase=Running` will not warn you. Put externally
issued certificates on a calendar, and check with:

```bash
oc get secret lab-mongot-search-lb-0-cert -n mongodb-poc -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -dates -ext subjectAltName
```

**Limits worth designing around.** `mongot` validates that a client certificate is signed
by a trusted CA but **does not validate hostname or SAN** on that leg. Minimum TLS 1.2.
No FIPS. Cipher suites are not configurable.

---

## 9. Verify

```bash
# 1. the cert volumes are actually mounted (the section-2 failure)
oc get pod -n mongodb-poc -l app=mongot-search-lb-0 \
  -o jsonpath='{range .items[0].spec.containers[0].volumeMounts[*]}{.name}{"\n"}{end}'
#   expect: envoy-config, envoy-server-cert, envoy-client-cert, ca-cert

# 2. Envoy has SNI matching and a TLS transport socket
oc get cm mongot-search-lb-0-config -n mongodb-poc -o jsonpath='{.data.lds\.json}' \
  | grep -o '"server_names":\[[^]]*\]'

# 3. mongot is serving TLS on the same port
oc get cm mongot-search-0-config -n mongodb-poc -o jsonpath='{.data.config\.yml}' | grep -A4 'grpc:'
#   expect: address: 0.0.0.0:27028  /  mode: TLS

# 4. end to end
cd mongodb && ./scripts/verify-search.sh
```

## 10. Troubleshooting

| Symptom | Cause |
|---|---|
| `upstream connect error`, status `Running` | `source.external.tls.ca` missing — cert volumes never mounted |
| `wrong version number` at the client | Envoy has no usable server cert, or you are speaking TLS to a plaintext listener |
| `DPE` / 400 in Envoy's access log | TLS `ClientHello` arrived at a plaintext h2c listener |
| Handshake fails, cert looks valid | `mongotHost` is an **IP** — TLS clients send no SNI for IP literals, so no filter chain matches |
| Certificate has no SANs | `openssl x509 -req` run without `-extfile`/`-extensions` |
| `mongot` cannot sync after enabling TLS | the `mongod` certificate does not cover what `rs.conf()` advertises |
| Operator ignores your Secret | the name does not match the derived `<prefix>-<name>-search-…` form |
