
Verified against the CRD and the validators. Yes — it will deploy Envoy. Only clusters is +kubebuilder:validation:Required; version, source and security are all +optional, and loadBalancer.managed being present is what triggers the Deployment, ConfigMap and proxy Service. It also passes the validators that apply (replicas: 3 has an LB; external source has externalHostname).

But it won't work end to end — and one of my own comments on it was wrong.

The bug in my snippet

I annotated externalHostname as "SNI match + cert SAN". With no spec.security.tls, neither happens. From buildFilterChain:

if tlsEnabled {
    chain.FilterChainMatch = &listenerv3.FilterChainMatch{ServerNames: []string{route.SNIHostname}}
    ts, err := buildDownstreamTLSTransportSocket(caKeyName)
    ...
}

No TLS → no FilterChainMatch, no SNI, no certificate. externalHostname is still required by the validator, but it's inert. The whole path would be plaintext h2c, and searchTLSMode: disabled. Sorry — that comment was carried over from the passthrough design where TLS was implied.

What else is missing

┌──────────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                 Gap                  │                                                     Consequence                                                      │
├──────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ spec.source.username /               │ Defaults to user search-sync-source + Secret mongot-search-sync-source-password ({name}-{username}-password). That   │
│ passwordSecretRef                    │ Secret must exist or reconcile fails                                                                                 │
├──────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ spec.source.external.tls.ca          │ If the external mongod requires TLS, mongot has no CA to validate it — sync fails                                    │
├──────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ spec.version                         │ Optional; falls back to the operator's built-in default. Pin it                                                      │
├──────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ metadata.namespace                   │ Lands in whatever namespace is current                                                                               │
└──────────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

Plus, outside the CR: you create the searchCoordinator user on the external mongod yourself, and set mongotHost / searchIndexManagementHostAndPort / useGrpcForSearch there — the operator never touches an external mongod.

Corrected

apiVersion: mongodb.com/v1
kind: MongoDBSearch
metadata:
  name: mongot
  namespace: mongodb
spec:
  version: "1.70.1"
  source:
    external:
      hostAndPorts: ["mongod-1.corp:27017", "mongod-2.corp:27017", "mongod-3.corp:27017"]
      tls:
        ca:
          name: external-mongod-ca      # ConfigMap holding ca.crt
    username: search-sync-source
    passwordSecretRef:
      name: mongot-search-sync-source-password
    tls:
      clientCertificateSecretRef:
        name: mongot-sync-client        # mTLS to the external mongod
  security:
    tls:
      certsSecretPrefix: lab            # ← this is what turns TLS + SNI on
  clusters:
  - replicas: 3
    loadBalancer:
      managed:
        externalHostname: grpc-search.corp.example
        replicas: 2
        retryPolicy:
          numRetries: 2
          perTryTimeout: 60s

certsSecretPrefix: lab then makes the operator expect three cert-manager Secrets:

┌────────────────────────────────────┬───────────────────────┬──────────────────────────┐
│               Secret               │         Role          │      Required SANs       │
├────────────────────────────────────┼───────────────────────┼──────────────────────────┤
│ lab-mongot-search-lb-0-cert        │ Envoy server cert     │ grpc-search.corp.example │
├────────────────────────────────────┼───────────────────────┼──────────────────────────┤
│ lab-mongot-search-lb-0-client-cert │ Envoy → mongot client │ —                        │
├────────────────────────────────────┼───────────────────────┼──────────────────────────┤
│ lab-mongot-search-cert             │ mongot server cert    │ mongot Svc FQDNs         │
└────────────────────────────────────┴───────────────────────┴──────────────────────────┘

Worth deciding deliberately: with certsSecretPrefix set, TLS is on for both legs (client→Envoy and Envoy→mongot) — it's not per-leg in managed mode. Leaving security out gives you plaintext everywhere, which is a legitimate Phase-A choice to prove the data path before adding certs, as long as it's a choice rather than an accident.

Want me to write this out in mongodb-poc along with the MetalLB Service, pool, and the cert-manager Certificate resources?

✻ Baked for 1m 10s · done 9:38 PM

❯ I need envoy

Then let's deploy it. Getting the real Subscription values first — no guessed channel names.

  Ran 2 shell commands

❯ test it here now

Explicit go-ahead — deploying to a dedicated namespace so it's trivially removable. Writing the manifests to mongodb-poc first, then applying.

  Ran 2 shell commands

MCK 1.12.0 installed via OLM in 25 seconds, operator Running, mongodbsearch.mongodb.com CRD present. Now the CR that deploys Envoy — sized for CRC's ~7 GiB headroom.

  Ran 1 shell command

❯ install metallb as well and you need to figure the mongodb runing in colima - you did some network research earlier

Dry run passed. Applying it, installing MetalLB, and checking what's actually in colima — in parallel.

  Ran 2 shell commands

Envoy is up. 45 seconds after applying the CR:

NAME                 READY   UP-TO-DATE   AVAILABLE
mongot-search-lb-0   2/2     2            2          ← the managed Envoy, 2 replicas

pod/mongot-search-lb-0-58bfb4678c-kt2cx   1/1  Running
pod/mongot-search-lb-0-58bfb4678c-zcjxr   1/1  Running
pod/mongot-search-0-0                     0/1  Running   ← mongot, not ready (no MongoDB to sync from yet)

And colima isn't empty — it's a containerlab BGP fabric: FRR agents (spine, leaf1, leaf2, edge, isp1, isp2, companya, companyb) plus a BGP dashboard, on 10.0.x.x/29 links and 172.22.20.254/24. No MongoDB there yet.

Installing MetalLB and pulling Envoy's generated config to confirm what it's actually pointed at:

  Ran 2 shell commands

❯ no bgp mode - pls select an IP ranges available to both crc and colima on this host for metallb pool

First, the Envoy config confirms it's wired correctly:

cluster: mongot_rs_cluster | type: STRICT_DNS
   upstream -> mongot-search-0-svc.mongodb-poc.svc.cluster.local:27028   ← the headless Svc
mongot-search-0-svc   ClusterIP  None   ← headless, so DNS returns all 3 pod IPs
mongot-search-0-proxy-svc  selector={"app":"mongot-search-lb-0"}         ← already promoted to Envoy

Now, on the IP range — I have to give you a straight answer: there is no range that is on-link to both CRC and colima on this host. They sit in disjoint L2 domains, and that's structural, not a config oversight:

┌────────┬─────────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────┐
│        │                      Network stack                      │                       Host interface?                       │
├────────┼─────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ CRC    │ gvisor-tap-vsock over a unix socket (crc-unixgram.sock) │ none — 192.168.126/127.x appear nowhere in ifconfig/netstat │
├────────┼─────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ colima │ vmnet → bridge100                                       │ yes — 192.168.64.1, Mac routes to .4 directly               │
└────────┴─────────────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────┘

Measured, both directions: colima → 192.168.127.2:443 connect failed; Mac → 192.168.126.11:6443 timed out. A MetalLB L2 VIP must live on a subnet where a CRC node interface lives (br-ex 192.168.127.2 or eth10 192.168.126.11) because the speaker answers ARP there — and neither is visible from colima's side.

So: pool on CRC's L2, one stitch to colima

apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: mongot-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.127.100-192.168.127.120     # br-ex subnet; clear of .1 gw, .2 node, .254 host alias
  autoAssign: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: mongot-l2
  namespace: metallb-system
spec:
  ipAddressPools: [mongot-pool]
  interfaces: [br-ex]

Then one forwarder entry bridges the two stacks — the same mechanism CRC already uses for :80/:443:

POST http://192.168.127.254/services/forwarder/expose
{"local":":27028","remote":"192.168.127.100:27028","protocol":"tcp"}

local: ":27028" binds all Mac interfaces (that's why the existing :443 entry has no IP), so colima reaches it at 192.168.64.1:27028. MetalLB genuinely owns and advertises the VIP; the forward is just the L3 stitch. mongotHost on the colima mongod becomes 192.168.64.1:27028.

The unproven bit is whether gvproxy's forwarder will dial a VIP other than the VM's own .2 — every existing entry targets 192.168.127.2. It should ARP for .100 and MetalLB's speaker should answer, but I haven't proven it and won't claim it.

Worth knowing: if mongod ran in podman inside the CRC VM instead, it'd be on 192.168.127.0/24 directly — MetalLB works natively, zero stitching. The cost is CRC's memory instead of colima's 6 GiB.

Let me check MetalLB finished installing, then I'll create the pool and test the forwarder POST so we know for sure rather than guess.

✻ Churned for 5m 46s · done 9:43 PM

❯ what network is crc using on the macbook ? how i am able to access crc ? if you know then create the network in podman what is being used?

Let me answer precisely, because the third part has a hard technical answer.

  Ran 2 shell commands

⏺ Background command "Install MetalLB operator via OLM" completed (exit code 0)

MetalLB CSV came back Failed — diagnosing that before anything else.

  Ran 1 shell command

My error — the OperatorGroup. MetalLB doesn't support OwnNamespace:

reason=UnsupportedOperatorGroup
message=OwnNamespace InstallModeType not supported, cannot configure to watch own namespace

I gave it targetNamespaces: [metallb-system], which is OwnNamespace. MetalLB needs AllNamespaces (empty targetNamespaces). Fixing:

  Ran 2 shell commands

While MetalLB installs, here are your three answers — all from evidence on this machine.

1. What network CRC uses

Look at how vfkit attaches the NIC:

/usr/local/crc/vfkit --cpus 10 --memory 28672 \
  --device virtio-net,unixSocketPath=/Users/olasumbo/.crc/sockets/crc-unixgram.sock,mac=5a:94:ef:e4:0c:ee

The VM's network card is a unix datagram socket, not a bridge or vmnet device. The other end is crc daemon — a Go userspace TCP/IP stack (gvisor-tap-vsock). Inside the VM:

br-ex   192.168.127.2/24     default via 192.168.127.1
eth10   192.168.126.11/24
DNS     192.168.127.1        services API at 192.168.127.254

It even serves its own DNS zones: apps-crc.testing. → 192.168.127.2; crc.testing. with host→.254, gateway→.1, api→.2; plus containers.internal./docker.internal. → .254.

Critically: there is no host interface. Your Mac has only lo0, bridge100 (192.168.64.1 — that's colima's vmnet), and en0. Nothing on 192.168.126/127.x.

2. How you're able to access it

Not by routing — by port forwards the daemon publishes, plus DNS aimed at loopback:

127.0.0.1:6443 → 192.168.127.2:6443      oc / kubectl
127.0.0.1:2222 → 192.168.127.2:22        ssh
        :443   → 192.168.127.2:443       all interfaces (ingress)
        :80    → 192.168.127.2:80        all interfaces (ingress)
~/.crc/machines/crc/docker.sock → ssh-tunnel → core@192.168.127.2:22 → /run/podman/podman.sock

with api.crc.testing and *.apps-crc.testing both resolving to 127.0.0.1. That's the whole answer to why oc works fine but ping 192.168.126.11 times out: you never route to CRC, you connect to loopback and the daemon relays it over the socket.

3. Creating that network in podman — you can't, but here's what you want instead

There's nothing to attach to. The network lives inside crc daemon as userspace state behind a unix socket — no bridge, no tap, no vmnet device on the Mac. A podman network create --subnet 192.168.127.0/24 would build a separate L2 that merely reuses the subnet number; it wouldn't connect to CRC, and it'd create a routing conflict for anything trying to reach both.

But the thing you're reaching for already exists. CRC publishes the VM's podman socket, so you can create networks and run containers inside the CRC VM — on CRC's actual network:

podman --url unix:///Users/olasumbo/.crc/machines/crc/docker.sock info
  → crc | linux/arm64
  → networks: podman (bridge) 10.88.0.0/16 gw 10.88.0.1

Run MongoDB there with --network=host and it binds on 192.168.127.2 / 192.168.126.11 — the same L2 the MetalLB VIP will live on. No forwarder entry, no stitching, no disjoint-L2 problem. And you still drive it from your Mac with an ordinary docker compose (the compose plugin already talks to that socket, and the bundle's compose file is already network_mode: host).

That's the version where MetalLB does its real job with zero tricks. The tradeoff remains CRC's ~7 GiB headroom instead of colima's separate 6 GiB — and with 3 mongot pods already sized at 1 GiB each, that needs watching.

Want me to stand MongoDB up inside the CRC VM that way once MetalLB finishes?

✻ Cogitated for 3m 30s · done 9:49 PM

⏺ Background command "Wait for MetalLB operator to install" completed (exit code 0)

  Read 1 file, ran 1 shell command

OperatorGroup is now correct (targetNs=[""] = AllNamespaces), but deleting the CSV by hand left the Subscription stranded — state=UpgradePending with installedCSV pointing at a CSV that no longer exists. Recreating it so OLM re-resolves:

  Ran 1 shell command

MetalLB Succeeded. Now the MetalLB instance, pool, and the LoadBalancer Service in front of Envoy:

  Ran 2 shell commands

VIP assigned: 192.168.127.100:27028. Now the test that actually matters — is MetalLB L2 functional on br-ex against a userspace network stack?

  Ran 1 shell command

MetalLB works on CRC. Proof:

IPAllocated    Assigned IP ["192.168.127.100"]
nodeAssigned   announcing from node "crc" with protocol "layer2"
TCP 192.168.127.100:27028 -> connected (http_code=404)

That 404 is Envoy answering — it returns 404 for a non-gRPC path, so the full chain VIP → Envoy is live. (The ClusterIP line "FAILED" is just the node not using cluster DNS — not a real failure.)

Now the one genuinely unproven piece: whether gvproxy's forwarder will bridge that VIP out to colima.

  Ran 1 shell command

❯ how we address the metalLP pools and make it accessible between the mongo DB i.e
  podman --url unix:///Users/olasumbo/.crc/machines/crc/docker.sock info
    → crc | linux/arm64
    → networks: podman (bridge) 10.88.0.0/16 gw 10.88.0.1

Forwarder POST worked — HTTP=200, and the table now carries {"local":":27028","remote":"192.168.127.100:27028","protocol":"tcp"}. So that stitch is real, not theoretical.

Now to your question — testing both addressing paths for MongoDB:

  Ran 2 shell commands

Both paths work. That's the question answered empirically:

A) podman container on 10.88.0.0/16 INSIDE the CRC VM  → 192.168.127.100:27028 → connected http=404
B) colima VM → 192.168.64.1:27028 (Mac forwarder)      → 192.168.127.100:27028 → connected http=404

Both reach Envoy. Last unknown is the return leg — mongot pods reaching mongod:

  Ran 1 shell command

That test is ambiguous — -w prints even when curl fails, so "connected (http=000)" and "unreachable" both fired. Redoing with explicit exit codes, which distinguish couldn't connect (7) from connected but bad response (52/56):

  Ran 1 shell command

Clean results now — and both MongoDB placements are viable. From a pod inside the cluster:

┌──────────────────────────────────────┬───────────────────────────────────────────────────────────────────┐
│                Target                │                              Result                               │
├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
│ 192.168.64.4:22 (colima VM)          │ connected — curl exit 1 = non-HTTP data back, i.e. the SSH banner │
├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
│ 192.168.127.2:443 (CRC node, br-ex)  │ TCP connected                                                     │
├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
│ 192.168.126.11:443 (CRC node, eth10) │ TCP connected                                                     │
├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
│ 192.168.127.100:27028 (MetalLB VIP)  │ HTTP OK — Envoy answering                                         │
└──────────────────────────────────────┴───────────────────────────────────────────────────────────────────┘

Answering the addressing question

The pool lives on br-ex, the CRC node's own L2 — 192.168.127.100-120. How MongoDB reaches it depends only on where MongoDB runs, and both are now proven:

MongoDB inside the CRC VM (podman via ~/.crc/machines/crc/docker.sock)
container 10.88.0.x ──▶ gw 10.88.0.1 ──▶ br-ex ──ARP──▶ 192.168.127.100:27028 ──▶ Envoy
Ordinary routing. No forwarder entry needed. Works on the default podman bridge and with --network=host (which binds straight onto 192.168.127.2/192.168.126.11). Return leg: mongot pods → node IP ✅

MongoDB in colima
container ──▶ colima VM ──▶ bridge100 ──▶ Mac:27028 ──gvproxy fwd──▶ 192.168.127.100:27028 ──▶ Envoy
Needs the one forwarder entry (now live, HTTP=200). Return leg: mongot pods → 192.168.64.4 ✅

So the earlier "no shared IP range exists" still holds — but it stopped mattering, because the VIP is reachable from both sides by different means.

Where things stand on your cluster

┌───────────────────────────────────────┬─────────────────────────────────────────────────────────────────┐
│               Component               │                              State                              │
├───────────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
│ MCK 1.12.0 (OLM, certified-operators) │ ✅ Succeeded, operator Running                                  │
├───────────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
│ Envoy (mongot-search-lb-0)            │ ✅ 2/2 Running, STRICT_DNS → headless mongot-search-0-svc:27028 │
├───────────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
│ MetalLB (OLM)                         │ ✅ Succeeded, speaker announcing layer2                         │
├───────────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
│ VIP 192.168.127.100:27028             │ ✅ assigned, Envoy answering                                    │
├───────────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
│ gvproxy forwarder :27028 → VIP        │ ✅ live                                                         │
├───────────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
│ mongot StatefulSet                    │ ⚠️ 0/3 ready — no MongoDB to sync from                          │
├───────────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
│ MongoDB                               │ ❌ not deployed                                                 │
└───────────────────────────────────────┴─────────────────────────────────────────────────────────────────┘

One thing to plan for: my throwaway test pod tripped PodSecurity "restricted:latest" warnings. MongoDB containers in-cluster would need a proper securityContext; running them in the CRC VM's podman sidesteps PSA entirely.

Which home do you want for MongoDB — inside the CRC VM (simpler, no forwarder, costs CRC's ~7 GiB) or colima (separate 6 GiB, uses the forwarder)? I'll stand up the 3-member replica set there and wire mongotHost to the matching address.

✻ Sautéed for 4m 19s · done 9:55 PM

❯ did you create a custom "mongot-grpc-lb"
                                                                                                                            ✔ Update installed · Restart to update
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ yes add the ownerReferences
──────────────────────────