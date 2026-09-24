# Deployment walkthrough — reproducing the architecture on one laptop

> **The architecture is in [README.md](README.md).** This document is the
> laptop reproduction: every command, every measurement, and the network stitching
> that only a single-machine setup requires. Nothing here is part of the target design.


Reproduces, on a single MacBook, the architecture MongoDB's vendor team specifies:
**an L7 proxy (Envoy) load-balancing gRPC across 3 `mongot` pods**, with MongoDB
itself running *outside* Kubernetes.

Every value below was verified on the running system. Nothing is estimated.

| Component | Version | Source |
|---|---|---|
| OpenShift (CRC) | 4.22.7 | `crc version` |
| Kubernetes | v1.35.6 | `oc get nodes` |
| MCK (MongoDB Controllers for Kubernetes) | 1.12.0 | OLM, `certified-operators` |
| MetalLB | 4.22.0-202609151747 | OLM, `redhat-operators` |
| MongoDB Community Server | 8.3.4-ubi9 (arm64) | Docker Hub |
| mongot | 1.70.1 | `spec.version` |

---

## Why Envoy is required at all

`mongod` opens **one long-lived TCP connection** to `mongot` and multiplexes every
search query over it as HTTP/2 streams. An L4 balancer (or a plain ClusterIP Service)
balances *connections*, so it pins that single connection to one pod and the other two
sit idle. An L7 proxy understands HTTP/2 and distributes **individual gRPC streams**,
pinning each stream to one pod only for the life of that query cursor.

`mongot` also sheds load by returning gRPC `RESOURCE_EXHAUSTED`, which the proxy is
expected to retry against a *different* replica.

## Managed vs unmanaged Envoy

`MongoDBSearch.spec.clusters[].loadBalancer` takes either:

- `managed: {}` — the operator deploys and configures Envoy itself. **Used here.**
- `unmanaged: { endpoint: "host:port" }` — you bring your own L7 (e.g. Envoy Gateway).

Managed mode was chosen because it removes Gateway API entirely: no `GatewayClass`,
no `GRPCRoute`, no `BackendTLSPolicy`, and therefore no dependency on which Gateway API
CRDs the OpenShift Ingress Operator owns (which varies 4.18 → 4.22).

The operator's Envoy config (from `envoy_config_builder.go`) includes behaviour that is
hard to reproduce by hand: retry on
`connect-failure,refused-stream,unavailable,reset,resource-exhausted`, a `previous_hosts`
predicate so a retry lands on a *different* `mongot`, 300s stream/request/route timeouts,
1 MiB HTTP/2 windows, and circuit breakers at 1024/1024/1024/3.

---

## Network layout

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/mongot-openshift/network-layout.dark.png">
  <source srcset="docs/diagrams/mongot-openshift/network-layout.light.png">
  <img alt="CRC runs behind a userspace network stack with no host interface, while colima sits on a real vmnet bridge, so the two VMs share no L2 domain and are stitched at L3 in two different directions." src="docs/diagrams/mongot-openshift/network-layout.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*CRC has **no host interface at all** — it is reached only by port-forwards over a unix
socket. colima sits on a real vmnet bridge the Mac routes to. No IP range is on-link to
both, so the path is stitched at L3, and only one direction works unaided.*


Three separate network stacks live on this Mac. Two of them cannot see each other
directly, and that constraint drives the whole design.

```
                              ┌──────────────────────── macOS host ────────────────────────┐
                              │                                                            │
                              │  en0 192.168.166.180        bridge100 192.168.64.1         │
                              │  lo0 127.0.0.1              (vmnet, host-routable)         │
                              │                                    │                       │
                              │   ┌───── gvproxy / crc daemon ─────┐│                      │
                              │   │ userspace TCP/IP stack         ││                      │
                              │   │ NO host interface exists       ││                      │
                              │   │ reached only via port-forwards ││                      │
                              │   └────────────┬───────────────────┘│                      │
                              └────────────────┼────────────────────┼──────────────────────┘
                                               │ unix socket        │ vmnet bridge
                                               │ crc-unixgram.sock  │
                    ┌──────────────────────────┴────────┐  ┌────────┴──────────────────────┐
                    │        CRC VM (OpenShift)         │  │   colima VM "bgp-fabric"      │
                    │                                   │  │                               │
                    │ br-ex   192.168.127.2/24          │  │ col0   192.168.64.4           │
                    │ eth10   192.168.126.11/24         │  │ eth0   192.168.5.3 (slirp)    │
                    │ pods    10.217.0.0/22 (OVN)       │  │                               │
                    │                                   │  │ Docker Engine 29.5.2          │
                    │ MetalLB VIP 192.168.127.100       │  │  ├─ mongo1 :27017  PRIMARY    │
                    │   └─ Envoy x2 ──▶ mongot x3       │  │  ├─ mongo2 :27018  SECONDARY  │
                    │                                   │  │  └─ mongo3 :27019  SECONDARY  │
                    └───────────────────────────────────┘  └───────────────────────────────┘
```

### Measured reachability

| From | To | Result |
|---|---|---|
| macOS | `192.168.64.4` (colima) | ✅ routed via `bridge100` |
| macOS | `192.168.126.11` / `192.168.127.2` (CRC) | ❌ **timeout — no route exists** |
| CRC node | `192.168.64.4` | ✅ `via 192.168.127.1 dev br-ex` (transits the Mac; `net.inet.ip.forwarding=1`) |
| **mongot pod** | `192.168.64.4:27017/18/19` | ✅ **all three TCP CONNECTED** |
| colima | `192.168.127.x` | ❌ no route |
| colima | `192.168.64.1:27028` (Mac forwarder) | ✅ reaches the MetalLB VIP |

**There is no IP range on-link to both CRC and colima.** CRC has no host interface at
all; colima has a real vmnet bridge. The two are stitched at L3, not L2.

### The two stitches

1. **CRC → colima** works natively: the CRC VM routes out through gvproxy, the Mac
   forwards (`net.inet.ip.forwarding=1`), and lands on `bridge100`.
2. **colima → CRC** needs one forwarder entry, using the same mechanism CRC already
   uses for `:80`/`:443`:

```bash
curl -X POST http://192.168.127.254/services/forwarder/expose \
  -d '{"local":":27028","remote":"192.168.127.100:27028","protocol":"tcp"}'
```

`"local": ":27028"` binds **all** Mac interfaces, so colima reaches the VIP at
`192.168.64.1:27028`.

---

## Data path

> **Lab 1 (MetalLB VIP) and Lab 2 (OpenShift Route) share one hostname and one certificate**,
> and differ only in the port `mongotHost` dials. A replica-set source gets exactly one SNI
> name from the operator, and both paths terminate on the same Envoy, so a second FQDN is
> neither possible nor wanted. See
> [One hostname, two entry paths](README.md#one-hostname-two-entry-paths).


<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/mongot-openshift/grpc-path.dark.png">
  <source srcset="docs/diagrams/mongot-openshift/grpc-path.light.png">
  <img alt="mongod opens one long-lived HTTP/2 connection, so Envoy is required to split individual gRPC streams across three mongot pods; the sync leg runs in the opposite direction back to the external replica set." src="docs/diagrams/mongot-openshift/grpc-path.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Every hop verified on the running cluster. `mongot-grpc-lb` is hand-written because
`ManagedLBConfig` has no Service-type field and the operator hardcodes its proxy Service
to `ClusterIP`, leaving MetalLB nothing to bind to.*


```
mongod rs0 (colima, 3 members)
  │  mongotHost = 192.168.64.1:27028
  ▼
Mac :27028  (gvproxy forwarder, all interfaces)
  ▼
MetalLB VIP 192.168.127.100:27028   (L2Advertisement on br-ex)
  ▼
Service mongot-grpc-lb  selector app=mongot-search-lb-0
  ▼
Envoy x2  (MCK-managed; STRICT_DNS + ROUND_ROBIN)
  ▼
mongot-search-0-svc  (headless -> DNS returns all 3 pod IPs)
  ▼
mongot x3   10.217.0.253 / 10.217.1.6 / 10.217.1.7
  │
  └─ sync source ──▶ 192.168.64.4:27017,27018,27019  (back to colima)
```

The sync leg runs in the **opposite** direction to the query leg. Both had to be proven
independently.

---

## Steps

### 1. Enable the certified-operators catalog

MCK ships in Red Hat's certified catalog, which CRC disables by default.

```bash
oc patch operatorhub cluster --type=merge \
  -p '{"spec":{"sources":[{"name":"certified-operators","disabled":false}]}}'
```

Verify: `oc get packagemanifest mongodb-kubernetes -n openshift-marketplace`
→ `channel=stable  csv=mongodb-kubernetes.v1.12.0`

### 2. Install MCK via OLM — `manifests/10-mck-olm.yaml`

`OperatorGroup` with `targetNamespaces: [mongodb-poc]` (MCK supports OwnNamespace,
SingleNamespace and AllNamespaces) plus a `Subscription` pinned to
`startingCSV: mongodb-kubernetes.v1.12.0`.

### 3. Install MetalLB via OLM — `manifests/05-metallb-olm.yaml`

**Gotcha:** MetalLB supports **AllNamespaces only**
(`OwnNamespace=false SingleNamespace=false AllNamespaces=true`). An OperatorGroup with
`targetNamespaces` set fails with:

```
reason=UnsupportedOperatorGroup
message=OwnNamespace InstallModeType not supported
```

The OperatorGroup must be `spec: {}`.

### 4. MetalLB pool + L2 — `manifests/06-metallb-config.yaml`

Pool `192.168.127.100-192.168.127.120` on `br-ex`, avoiding `.1` (gateway), `.2` (node)
and `.254` (gvproxy services endpoint). `autoAssign: false` so only an explicitly
annotated Service claims one.

Also confirm the node is not excluded from external load balancers:
`oc get node crc -o jsonpath='{.metadata.labels}' | grep exclude-from-external`

### 5. MongoDB replica set in colima — `mongodb/compose.yaml`

```bash
cd mongodb
DOCKER_CONTEXT=colima-bgp-fabric docker compose --env-file .env up -d
```

`network_mode: host` with three distinct ports is deliberate: replica-set members talk
to each other using the addresses in the rs config, and on a bridge with published ports
that becomes hairpin NAT. Host networking keeps member-to-member traffic direct and makes
`ADVERTISED_HOST` the single knob for relocating the whole set.

Then initiate and create users (the localhost exception allows creating the *first* user
but **not** running `usersInfo`, so the scripts attempt `createUser` and treat code 51003
as success):

```bash
docker exec -i mongo1 mongosh "mongodb://localhost:27017/admin?directConnection=true" \
  --quiet --file /dev/stdin < scripts/rs-init.js      # rs.initiate + labAdmin
docker exec -i mongo1 mongosh "mongodb://labAdmin:...@localhost:27017/admin?directConnection=true" \
  --quiet --file /dev/stdin < scripts/users.js        # search-sync-source
```

`searchCoordinator` is a **built-in role from MongoDB 8.2+**; on older servers the
operator creates it as a custom role.

### 6. MongoDBSearch — `manifests/20-search-managed-envoy.yaml`

`loadBalancer.managed` present is what triggers the Envoy Deployment. Only
`spec.clusters` is a required field; `version`, `source` and `security` are optional.

Two variants exist. Apply one:

| File | Lab |
|---|---|
| `20-search-managed-envoy.yaml` | plaintext h2c, no `security.tls` — prove the wiring first |
| `20-tls-search-managed-envoy.yaml` | the same deployment with TLS, and what is actually running |

The TLS variant sets `security.tls.certsSecretPrefix` **and**
`source.external.tls.ca`. The second is not optional: the operator gates Envoy's
certificate volume mounts on it, so setting `security.tls` alone brings the Envoy pods up
Ready with no certificates mounted and every handshake failing. See [TLS.md](TLS.md).

The operator creates:

| Object | Name |
|---|---|
| Envoy Deployment | `mongot-search-lb-0` (pod label `app=mongot-search-lb-0`) |
| Envoy config | `mongot-search-lb-0-config` (lds.json / cds.json) |
| Proxy Service | `mongot-search-0-proxy-svc` — **ClusterIP, hardcoded** |
| mongot StatefulSet | `mongot-search-0` |
| mongot headless Svc | `mongot-search-0-svc` (`clusterIP: None`) |

### 7. The LoadBalancer Service — `manifests/30-envoy-lb-service.yaml`

`ManagedLBConfig` has **no Service-type field**, and `buildProxyService()` hardcodes
`SetServiceType(corev1.ServiceTypeClusterIP)`. The operator's proxy Service can therefore
never be a LoadBalancer, so MetalLB has nothing to bind to. A hand-written Service
selecting `app: mongot-search-lb-0` is the only route.

Two caveats: it has **no ownerReference** (so it survives CR deletion and is never
reconciled), and its selector is a hand-copied operator-internal name
(`<CR name>-search-lb-<clusterIndex>`) — rename the CR and it silently blackholes.

### 8. Configure the external mongod

The operator **never touches an external `mongod`**, so these are set in `compose.yaml`:

```
--setParameter=mongotHost=192.168.64.1:27028
--setParameter=searchIndexManagementHostAndPort=192.168.64.1:27028
--setParameter=useGrpcForSearch=true
--setParameter=skipAuthenticationToSearchIndexManagementServer=false
--setParameter=searchTLSMode=disabled
```

Confirmed accepted at startup:
`"Applied --setParameter options" ... "mongotHost":{"default":"","value":"192.168.64.1:27028"}`

---

## Simulating "external to Kubernetes"

The point of the POC is that `mongod` runs **outside** the cluster — the supported
pattern where an existing database stays on VMs and only search moves to Kubernetes.

MongoDB's own compatibility matrix is explicit about editions:

| Search | mongod source | Supported |
|---|---|---|
| Community, MCK-managed | Community Server, **tarball/container** | ❌ |
| Community, MCK-managed | Community Server, **MCK-managed** | ✅ |
| Enterprise, MCK-managed | Enterprise, **external/self-hosted** | ✅ |

This lab is the first row — an *unsupported-for-production* combination, but one MongoDB
exercises in its own CI (`search_community_external_mongod_basic.py`,
`search_community_external_mongod_tls.py`). It is the right shape for rehearsing the
Enterprise-external topology.

The simulation is honest in the ways that matter: `mongod` is a real process in a
different VM, on a different network stack, not managed by the operator, reached by IP
over a routed path — and the operator genuinely refuses to configure it.

---

### Fidelity: what "three members" actually means here

The three members are **three processes on one host, separated only by port number**.
That is a deliberate, documented compromise — not an accident — and it must be stated
whenever this lab is used as evidence.

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/mongot-openshift/failure-domains.dark.png">
  <source srcset="docs/diagrams/mongot-openshift/failure-domains.light.png">
  <img alt="In production a three-member replica set is three machines in three failure domains; this lab collapses all three onto one colima VM separated only by port, which exercises process resilience but not availability." src="docs/diagrams/mongot-openshift/failure-domains.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Production puts each member in its own failure domain. This lab puts all three in one.
The gRPC path is faithful; the availability story is not.*

```text
  Production                             This lab
  three failure domains                  ONE failure domain
  ---------------------------            ------------------------------
  host A  mongod-1.corp:27017  PRIMARY   colima VM 192.168.64.4
  host B  mongod-2.corp:27017  SECONDARY   one kernel / one NIC
  host C  mongod-3.corp:27017  SECONDARY   :27017 PRIMARY    (mongo1)
  each: own kernel, NIC, power             :27018 SECONDARY  (mongo2)
                                           :27019 SECONDARY  (mongo3)

  DOES exercise                          CANNOT exercise
  - replica-set election                 - host failure (all three die together)
  - mongot reconnect after election      - network partition between members
  - quorum when one member stops         - rack / AZ / power-domain loss
  - the whole gRPC path through Envoy    - NIC saturation isolated to one member
  - SCRAM + keyfile internal auth        - availability in any real sense
```

**Why the ports differ.** Because all three share one IP, `network_mode: host` with three
distinct ports is forced: you cannot bind three `mongod` to `:27017` on one host. Putting
them on a bridge with published ports instead would make member-to-member traffic hairpin
through NAT, because members talk to each other using the addresses in the rs config.

**Why this connects to the FQDN question.** In production the seed list is real hostnames
and the replica set *advertises* those hostnames. Here it advertises IPs. That is exactly
what `mongod-external` was a first step toward, and why a seed-only change is not enough
(see below).

**The honest upgrade on this machine** — *proposed, not built*: three VMs with one member
each (two colima profiles plus a podman machine, or the CRC VM). Same manifests, same
compose; only `ADVERTISED_HOST` changes per member. It still sits on one physical machine,
so power and hardware loss remain a single domain.

## Giving the external members an in-cluster FQDN

OpenShift's DNS operator (`operator.openshift.io/v1 DNS`) exposes only `cache`,
`servers`, `upstreamResolvers` and `nodePlacement`. `servers[].forwardPlugin` is
*"proxy DNS messages to upstream resolvers"* — **zone forwarding, not static A records** —
and editing the `openshift-dns` CoreDNS ConfigMap directly is unsupported.

The native pattern is a **selector-less headless Service + hand-written EndpointSlice**
(`manifests/40-external-mongod-dns.yaml`). Verified:

```
mongod-external.mongodb-poc.svc.cluster.local -> 192.168.64.4
  :27017 CONNECTED   :27018 CONNECTED   :27019 CONNECTED
```

### The subtlety that will bite you

`spec.source.external.hostAndPorts` is only a **seed list**. The driver connects, reads
the replica-set config, and then uses the **advertised** member hostnames for all further
traffic. Pointing the seed at an FQDN while the rs config still says `192.168.64.4:27017`
changes nothing after discovery.

To genuinely use FQDNs, all three must line up:

1. `rs.reconfig()` so members advertise `mongod-external...:27017` etc.
2. `extra_hosts` in `compose.yaml` so the members resolve that name themselves
3. the Service + EndpointSlice above so `mongot` resolves it

Alternative to (3): `hostAliases` under
`spec.clusters[].statefulSet.spec.template.spec.hostAliases`, which writes `/etc/hosts`
into the mongot pods and needs no Service at all.

---

## Scaling

### More mongot

```bash
oc patch mongodbsearch mongot -n mongodb-poc --type=json \
  -p='[{"op":"replace","path":"/spec/clusters/0/replicas","value":5}]'
```

The operator grows the StatefulSet; Envoy's upstream is `STRICT_DNS` against the headless
Service, so new pod IPs are picked up on re-resolve with no Envoy change. Each replica
gets its own PVC.

**`replicas > 1` requires a load balancer** — the operator rejects the resource otherwise.

### More Envoy

```yaml
loadBalancer:
  managed:
    replicas: 2          # default is 1
```

Default 1 means a rolling restart severs every in-flight cursor. Use ≥2 in production.
`minMongotReadyReplicas` gates how many `mongot` must be ready before Envoy is promoted.

### More MongoDB members

Add a service to `compose.yaml` with the next port and `rs.add("<ADVERTISED_HOST>:27020")`.
Keep the member count odd for quorum.

### Sizing reality on CRC

`mongot` defaults to **2 CPU / 4 GiB requests each**. With 3 replicas that is 6 CPU /
12 GiB before anything else. This lab pins 200m/1Gi requests. Current node allocation is
already cpu 71% / memory 64%.

---

## Verified end to end

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/mongot-openshift/end-to-end.dark.png">
  <source srcset="docs/diagrams/mongot-openshift/end-to-end.light.png">
  <img alt="Every hop from the external MongoDB replica set through the forwarder, MetalLB VIP, Service and Envoy to three mongot pods, each with the measurement that proves it." src="docs/diagrams/mongot-openshift/end-to-end.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Each hop paired with the command output that proves it. The 404 at the VIP is Envoy
answering a non-gRPC path — a real response, not a timeout.*

```text
  HOP                                  MEASURED ON THE RUNNING SYSTEM
  ---------------------------------    ------------------------------------------------
  mongod rs0 - colima VM               rs.status() -> set: rs0  ok: 1
    3 members, keyfile auth            PRIMARY + 2 SECONDARY, health=1
        |
        v
  Mac :27028 - gvproxy forwarder       POST /services/forwarder/expose -> HTTP 200
    binds all host interfaces          {"local":":27028","remote":"192.168.127.100:27028"}
        |
        v
  MetalLB VIP 192.168.127.100          IPAllocated ["192.168.127.100"]
    L2Advertisement on br-ex           nodeAssigned - protocol "layer2"
        |
        v
  Service mongot-grpc-lb               EXTERNAL-IP 192.168.127.100
    hand-written (operator Svc is      27028:31194/TCP
    ClusterIP-only)
        |
        v
  Envoy x2 - MCK-managed               mongot-search-lb-0   2/2   Running
    the only L7 in the path            cds.json: STRICT_DNS - ROUND_ROBIN
        |
        v
  mongot-search-0-svc - headless       upstream -> mongot-search-0-svc:27028
    clusterIP: None                    resolved from cds.json
        |
        v
  mongot x3                            10.217.0.253 - 10.217.1.6 - 10.217.1.7
    each with its own PVC              endpointslice ready=true x3

  Reachability, both directions:
    VIP:27028 -> http=404 (Envoy)
    pod -> 192.168.64.4:27017/18/19 -> CONNECTED
    colima -> 192.168.64.1:27028 -> http=404

  VERIFIED: $search returns correct results, and 41 requests over ONE mongod
  connection landed on THREE mongot pods (13/14/14) - per-request distribution.
```

## Verified end state

```
mongot-search-0-0/1/2                 1/1 Running      3 mongot
mongot-search-lb-0-...-kt2cx/zcjxr    1/1 Running      2 Envoy
MongoDBSearch mongot                  phase=Running
mongot-grpc-lb                        EXTERNAL-IP 192.168.127.100
endpointslice                         10.217.0.253, 10.217.1.6, 10.217.1.7  all ready=true
rs0                                   PRIMARY + 2 SECONDARY, health=1
```

## Not yet done

- **No TLS anywhere.** `server.grpc.tls.mode: Disabled`, `searchTLSMode: disabled`.
  Setting `security.tls.certsSecretPrefix` enables TLS on **both** legs (it is not
  per-leg in managed mode) and requires three cert-manager Secrets:
  `<prefix>-mongot-search-lb-0-cert` (SAN must cover `externalHostname`),
  `<prefix>-mongot-search-lb-0-client-cert`, `<prefix>-mongot-search-cert`.
- **`$search` verified.** 40 queries distributed 13 / 14 / 14 across the three `mongot`,
  confirmed from each pod's own Prometheus counter and Envoy's `upstream_rq_total: 41`.
- `mongot-grpc-lb` has no `ownerReferences`.

---

## Diagram sources

The ten figures are hand-authored inline SVG in `docs/diagrams/mongot-openshift/source.html`,
rendered to light and dark PNGs at 2x. **The name list must match the figure
order in the page** — render.py assigns names in DOM order, so a mismatched list
silently writes each PNG under the wrong name:

```sh
python3 ~/.claude/skills/visual/render.py \
  docs/diagrams/mongot-openshift/source.html \
  docs/diagrams/mongot-openshift network-layout,grpc-path,failure-domains,end-to-end,architecture,l4-bypass,before-route-single,after-metallb-three,architecture-proposed,architecture-route-f5
```

The page, the PNGs and the ASCII twin above change together. Solid shapes are shipped
behaviour; nothing in these figures is proposed.
