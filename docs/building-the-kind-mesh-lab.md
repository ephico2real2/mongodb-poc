# Building the kind mesh lab, one setting at a time

How the lab in `kind-mesh/` and `kind-mesh-cilium/` is built, setting by setting: what each one sets and why, the
command that sets it (the repository's own script, or a manifest), how to see that it worked, and what it changes
on the wire or in Hubble. The order is the one the lab was built in; every result cited is in a recorded run under
`kind-mesh/output/` or `kind-mesh-cilium/output/`, and the numbers are in the testing records,
[testing-kind-mesh.md](testing-kind-mesh.md) (the Envoy lab) and
[testing-kind-mesh-cilium.md](testing-kind-mesh-cilium.md) (Cilium alone, story #132 and after). The design and the
reasons for it: [the reference architecture](reference-architecture-search-on-cluster-mesh.md).

One command runs the whole order after deleting what is there: `kind-mesh/scripts/rebuild.sh --yes`
([Tear down and rebuild](#tear-down-and-rebuild)). Lab commands below run from the repository's root (the image build commands explicitly enter the Cilium clone); for your
own `kubectl`, `export KUBECONFIG=~/.kube/mongodb-mesh.config` first (the scripts set it themselves).

| # | Setting | Command | Assumes |
| --- | --- | --- | --- |
| 0 | [Our Cilium images](#0-our-cilium-images-in-the-vms-docker) in the VM's docker | the build commands in [testing-kind-mesh-cilium.md](testing-kind-mesh-cilium.md#across-cluster-mesh-too-story-190) | the VM |
| 1 | [The VM](#1-the-vm) | `kind-mesh/scripts/colima-up.sh` | Colima installed |
| 2 | [Clusters and Cilium](#2-the-clusters-and-cilium) | `kind-mesh/scripts/up.sh` (one script for 2 to 5) | 0, 1 |
| 3 | [cert-manager and the shared CA](#3-cert-manager-and-the-shared-ca) | (`up.sh`) | 2 |
| 4 | [Hubble and Cluster Mesh](#4-hubble-and-cluster-mesh) | (`up.sh`) | 3, in every cluster |
| 5 | [OLM](#5-olm) | (`up.sh`) | 2 |
| 6 | [The replica set](#6-the-replica-set) | `kind-mesh/scripts/mongo-up.sh` | 3, 4 |
| 7 | [Search, with the operator's Envoy](#7-search-with-the-operators-envoy) | `kind-mesh/scripts/search-up.sh` | 5, 6 |
| 8 | [The sample data and its indexes](#8-the-sample-data-and-its-indexes) | `kind-mesh/scripts/data-load.sh` | 7 |
| 9 | [The search GUI](#9-the-search-gui) | `kind-mesh/scripts/gui-up.sh` | 8 |
| 10 | [Flows in Grafana](#10-flows-in-grafana) | `kind-mesh/scripts/observability-up.sh` | 3, 4 |
| 11 | [Step 1: no Envoy](#11-step-1-search-without-the-operators-envoy) | `kind-mesh-cilium/scripts/swap-search.sh` | 7's objects |
| 12 | [Step 2: WireGuard, Cilium's L7 load balancer, the hop in cleartext](#12-step-2-wireguard-ciliums-l7-load-balancer-the-search-hop-in-cleartext) | `kind-mesh-cilium/scripts/cleartext-l7.sh` | 2's release, 11, 8 |
| 13 | [The lab's chart](#13-the-labs-chart) | `kind-mesh-cilium/scripts/chart-up.sh` | 11, 12 |
| 14 | [Who may connect to mongot](#14-who-may-connect-to-mongot) | `kubectl apply -f kind-mesh-cilium/manifests/60-mongot-ingress.yaml`, in every cluster | 13 |
| 15 | [Our Cilium build](#15-our-cilium-build-stories-145-and-190-and-187s-check) | in `up.sh` on a fresh lab; `kind-mesh-cilium/scripts/cilium-build.sh` on a running one | 0 |
| 16 | [The proofs](#16-the-proofs) | `kind-mesh/check.sh` | all |

## 0. Our Cilium images in the VM's docker

- **Sets:** the two images the lab's Cilium runs, `CILIUM_IMAGE` (the agent) and `CILIUM_CLUSTERMESH_IMAGE` (the
  mesh apiserver) in `kind-mesh/versions.env`, built from the operator's fork and present only in the VM's docker
  (`CILIUM_IMAGES_LOCAL=1`: no registry holds them).
- **Why:** the release agent names the workload (`StatefulSet/mongot-search-0`) only for a pod on its own node; our
  build names it for a pod on another node (#145) and in another cluster of the mesh (#190), so the flows dashboard
  can say what talked to what across the mesh. The chart stays the release's; only the images change.
- **Command:** the build commands under "Across Cluster Mesh too" in
  [testing-kind-mesh-cilium.md](testing-kind-mesh-cilium.md#across-cluster-mesh-too-story-190): a clone of the fork at
  the pinned commit, `DOCKER_HOST` at the VM's socket, `make dev-docker-image` and
  `make docker-clustermesh-apiserver-image`.
- **See it worked:** `DOCKER_HOST=unix://$HOME/.colima/mongodb-mesh/docker.sock docker image inspect
  quay.io/cilium/cilium-dev:remote-workload-cm-9e5a34a5 quay.io/cilium/clustermesh-apiserver:remote-workload-cm-9e5a34a5
  --format '{{.RepoTags}}'` lists both; `DOCKER_HOST=unix://$HOME/.colima/mongodb-mesh/docker.sock docker run --rm --entrypoint cilium-agent quay.io/cilium/cilium-dev:remote-workload-cm-9e5a34a5 --version` prints
  `1.20.2 9e5a34a525`. `up.sh` and `rebuild.sh` refuse, naming the image, when one is missing (`lib.sh`,
  `cilium_images_local`).
- **Hubble:** nothing yet; the images are not running. What they change is step 15.

## 1. The VM

- **Sets:** one Colima VM, `mongodb-mesh` (`COLIMA_PROFILE`), 8 CPUs, 24 GiB, a 100 GiB docker disk (`versions.env`),
  with the docker context left inactive and the inotify limits raised; on a restart, each kind node back on the
  address it had.
- **Why:** the three clusters, their volumes and images all live in this VM's docker. One VM means the clusters
  share one kernel and have no real network between them, which the testing records say when it matters (the
  election times are "a floor rather than a forecast"). 16 GiB left 2,086 MiB available before the restart
  (`kind-mesh/output/restart-2026-10-22/vm-before.txt`); the 60 GiB disk reached 80% used
  (`kind-mesh/output/disk-grow-2026-10-22/vm-before.txt`). Mongot stops indexing above 85%
  ([resource record](testing-kind-mesh.md#resources), #182).
- **Command:** `kind-mesh/scripts/colima-up.sh`. Idempotent: a running VM is reported, not resized.
- **See it worked:** it prints `colima list` and, on a VM it started, `df -h /var/lib/docker`; with no clusters yet it
  ends with "no kind nodes yet: kind-mesh/scripts/up.sh creates the clusters". Recorded: the first lines of
  `kind-mesh/output/phase0-up.log`; a restart, `kind-mesh/output/restart-2026-10-22/colima-up.txt`.
- **On the wire:** nothing yet. The VM's address (`colima list`) is where a Mac route to the clusters' LoadBalancer
  block goes, later.

## 2. The clusters and Cilium

- **Sets:** the docker network `kind` with a fixed subnet (`LAB_SUBNET`, containers in its lower half); three kind
  clusters `mesh0`, `mesh1`, `mesh2` (`kind-mesh/clusters/`: a control plane and a worker each, `kubeProxyMode:
  none`, disjoint pod and Service ranges); in each, Cilium 1.20.2 with `kubeProxyReplacement`, `ipam.mode:
  kubernetes`, L2 announcements and the cluster's own LoadBalancer block (`cilium/values.yaml`, `values-<c>.yaml`,
  `lb-ippool-<c>.yaml`), the agent and mesh apiserver images from step 0, our build's CiliumEndpoint CRD, CoreDNS on
  public resolvers, metrics-server.
- **Why:** Cilium does every Service's load balancing, global Services included, so kube-proxy is off from the
  start. The cluster name and id are part of every security identity Cilium issues, so they are set at install and
  never change. The subnet is pinned because the LoadBalancer blocks are. A kind node resolves through Docker's own
  loopback, which a pod cannot reach, so CoreDNS is given upstreams. The CRD goes on first because the API server
  drops a status field the CRD does not declare, silently (`lib.sh`, `cilium_build_crd`).
- **Command:** `kind-mesh/scripts/up.sh` (its first part; steps 3 to 5 are the rest of the same script). Idempotent:
  an existing network, cluster or release is kept.
- **See it worked:** after each cluster, `cilium status` healthy, every node Ready, "resolved: Address: …" from a
  probe pod, and the LoadBalancer pool printed. Recorded: `kind-mesh/output/phase0-up.log`.
- **Hubble:** not on yet: its certificates need cert-manager (step 3), so the install turns Hubble off and step 4
  turns it on.

## 3. cert-manager and the shared CA

- **Sets:** cert-manager v1.21.1 in every cluster; one root CA, made in mesh0 (`manifests/00-root-ca.yaml`) and copied
  to the others as a Secret (name, namespace, type and data only); `ClusterIssuer mesh-ca` in each.
- **Why:** every certificate of the lab (mongod's, mongot's, Envoy's, Hubble's, the mesh apiserver's) is signed by
  the same root, so a mongod in one cluster trusts a mongot in another with nothing more to configure. The mesh
  apiservers trust each other the same way.
- **Command:** (`up.sh`).
- **See it worked:** `up.sh` prints the root's fingerprint for each cluster, the same in all three, and "issuer
  Ready"; it refuses to go on if the three fingerprints differ. Recorded: `phase0-up.log`, lines "root CA
  9E:48:06:4F:…, issuer Ready".
- **On the wire:** nothing yet; what will use TLS does so from step 6.

## 4. Hubble and Cluster Mesh

- **Sets:** Hubble with its relay, mutual TLS from `mesh-ca`, the Hubble UI in mesh0 (`cilium/values-mesh.yaml`,
  `values-mesh0.yaml`); the clustermesh apiserver on a NodePort in each cluster, with every member declared by name
  and control-plane address, then an agent restart (Hubble lives in `cilium-config`, read at start).
- **Why:** Cluster Mesh is what makes one Service name (`mongo-mesh1`, `mongot-global`) reach pods in another
  cluster; Hubble is the evidence of which cluster answered. Both need the shared CA, so they come after step 3.
- **Command:** (`up.sh`).
- **See it worked:** `cilium clustermesh status --context kind-mesh0` reports each other cluster "2/2 configured,
  2/2 connected" (`phase0-up.log`). `hubble list nodes` through the relay shows the six nodes Connected (the command
  and its record: [T10 in testing-kind-mesh.md](testing-kind-mesh.md#t10-hubble-sees-all-three-clusters)).
- **Hubble:** from here every flow carries a source and a destination cluster; the dashboard of step 10 is built on
  that.

## 5. OLM

- **Sets:** OLM v0.46.0 from its release files, server-side applied, and OperatorHub's catalog, in every cluster.
- **Why:** both charts install the MongoDB operator through OLM (a Subscription, Manual approval, pinned to 1.13.0);
  their preflight and gate need the ClusterServiceVersion OLM makes.
- **Command:** (`up.sh`; its last part, then the Mac's route to the LoadBalancer block, printed and never run).
- **See it worked:** `up.sh` waits for OLM's packageserver to reach `Succeeded` (it stops otherwise), prints the
  catalog's name, image and connection state per cluster, then "platform up" (`phase0-up.log`; its 2026-10-21 run
  predates the catalog line). Time for steps 2 to 5 together: see the bring-up table in `kind-mesh/README.md`.

## 6. The replica set

- **Sets:** one mongod in each cluster (`manifests/13-mongod.yaml`), a member of `rs0` reached by its own global
  Service `mongo-<c>` (`11-member-services.yaml`); the keyfile and the passwords as Secrets shared by the three
  clusters; mesh0's member at priority 2; the users `labAdmin` and `search-sync-source` (role `searchCoordinator`).
  Each mongod starts with its search parameters already set: `mongotHost=mongot-global.search.svc.cluster.local:27028`,
  `useGrpcForSearch`, `searchTLSMode=requireTLS`, so that search needs no restart later.
- **Why:** a member per cluster is the design: the primary in mesh0 while it is up, a majority elsewhere when it is
  not. The members talk TLS with certificates from `mesh-ca`; a client without a certificate may connect and logs in
  by password. Passwords exist only as Secrets, never in a file or an argument.
- **Command:** `kind-mesh/scripts/mongo-up.sh`. Idempotent: Secrets, members and users are kept.
- **See it worked:** each member prints the set as it sees it: one PRIMARY (mesh0) and two SECONDARY, health 1.
  Recorded: `kind-mesh/output/phase1-mongo.log`, and a second run `phase1-mongo-rerun.log`.
- **On the wire:** replication between the members crosses the mesh over TLS on 27017. In Hubble, flows from
  `mongodb/mongo-0` to the other clusters' `mongo-0` on port 27017.

## 7. Search, with the operator's Envoy

- **Sets:** in every cluster, the repository's chart `chart/mongodb-search-helm` (release `mongot`, `values/search.yaml`):
  the operator through OLM, a MongoDBSearch with two mongot and the operator's Envoy in front of them; three TLS
  Secrets and the trust bundle (the shared root) from `mesh-ca`; the Jobs' `oc` image, built in the VM and loaded
  into every node; and `mongot-global` (`manifests/22-mongot-global.yaml`), a Cilium global Service with affinity
  local over every cluster's Envoy: the one name every mongod dials.
- **Why:** this is the Envoy lab, the baseline: search as the chart ships it, with the mesh only adding that
  `mongot-global` reaches another cluster's Envoy when the local one is gone. Two mongot a cluster so that Envoy's
  retry has somewhere to go.
- **Command:** `kind-mesh/scripts/search-up.sh`, after step 6 (it needs the sync user's Secret).
- **See it worked:** `STATUS: deployed` for each cluster, then `cilium-dbg service list` showing `mongot-global`'s
  backends from each. Recorded: `kind-mesh/output/phase2-search.log`, `phase2-search-two-mongot.log`.
- **On the wire:** mongod to Envoy, and Envoy to mongot, both TLS (mutual on the second leg). Cilium balances
  connections: mongod keeps its one gRPC connection, so a failover lasts until mongod reconnects
  ([T3, T4](testing-kind-mesh.md#t3-a-cluster-that-loses-its-envoy-keeps-searching)).

## 8. The sample data and its indexes

- **Sets:** `sample_mflix.movies` from `mongodb/data/movies.json`, and its two search indexes (`default`, a text index;
  `vector_index`), created through the replica set.
- **Why:** creating a search index is not local to mongod: it is forwarded to `mongotHost`. A success here is the
  first proof that a mongod reaches a mongot over the mesh, and the indexes are what every later check and drill
  searches.
- **Command:** `kind-mesh/scripts/data-load.sh`. It drops and reloads the collection and its indexes.
- **See it worked:** "documents loaded: 24", both indexes requested, then "queryable after N s: default,
  vector_index" (`kind-mesh/output/phase2-data.log`).
- **Hubble:** the first flows from `mongodb/mongo-0` to the `search` namespace on 27028, and mongot's own
  connections back to the members on 27017 (its sync from the replica set).

## 9. The search GUI

- **Sets:** the repository's GUI (`app/gui/server.py`) in mesh0, with `MEMBERS` (a search through any cluster's
  member) and `MONGOT_TARGETS` (every mongot's metrics, through one global Service each,
  `manifests/30-mongot-metrics.yaml`); its own read-only user `search-gui`; a LoadBalancer address.
- **Why:** to see, by hand, which cluster's mongot answered a search made through a given member; the records'
  screenshots come from it.
- **Command:** `kind-mesh/scripts/gui-up.sh`, after step 8.
- **See it worked:** it prints the GUI's address (`http://172.18.255.200/` on the lab) and the port-forward
  alternative (`kind-mesh/output/gui-up.log`). A vector search through each member names that member's own cluster
  ([T2](testing-kind-mesh.md#t2-each-clusters-searches-are-answered-by-its-own-mongot)).

## 10. Flows in Grafana

- **Sets:** in mesh0, namespace `observability`: Loki (one process, 6 h of flows, a 2Gi volume), hubble-observer
  reading mesh0's relay with a client certificate from `mesh-ca`, an OpenTelemetry collector per node shipping the
  observer's log to Loki (`observability/20-otel-collector.yaml`, with #184's queue and batch limits), Grafana with
  the flows dashboard (grafana.com 23862 from the operator's fork, with the clusters named on every flow; #185's
  fixes).
- **Why:** mesh0's relay reaches every node of the mesh, so one observer sees the three clusters' flows between
  `mongodb` and `search`; the dashboard is where "mesh2's searches went to mesh0 and mesh1 during the outage" is
  read off.
- **Command:** `kind-mesh/scripts/observability-up.sh`.
- **See it worked:** five pods Running and Grafana's address (`http://172.18.255.201/d/hubble-observer-23862`, user
  `admin`, the password in Secret `observability/grafana-admin`); `kind-mesh/output/observability-up.log`. The
  dashboard's rows: [T11](testing-kind-mesh.md#t11-the-flows-dashboard-names-each-flows-clusters) and the screenshots
  under `docs/screenshots/kind-mesh-grafana-*.png`.
- **Hubble:** nothing changes in the flows; this is where they become visible.

## 11. Step 1: search without the operator's Envoy

- **Sets:** in each cluster, in place: the chart's release uninstalled with its OperatorGroup and Subscription kept
  (`manifests/39-operator-olm.yaml`), the MongoDBSearch re-declared with `loadBalancer.unmanaged`
  (`41-mongodbsearch.yaml`: no Envoy, the endpoint is `mongot-global`), mongot's certificate now also for the name
  mongod dials (`40-mongot-certificate.yaml`), what Envoy left removed, and `mongot-global` moved onto the mongot pods
  themselves (`42-mongot-global.yaml`). The mongot and their volumes stay.
- **Why:** with the operator's Envoy, a cluster that loses all its mongot keeps sending searches to its own Envoy,
  which stays ready with nothing behind it: 160 of 234 searches failed
  ([T6](testing-kind-mesh.md#t6-a-cluster-that-loses-all-its-mongot)). With `mongot-global` straight over the mongot
  pods, a cluster with no ready mongot is served by another cluster's on its own.
- **Command:** `kind-mesh-cilium/scripts/swap-search.sh`. It assumes step 7's objects (the release `mongot`, the
  OperatorGroup `mongot-mongodb-search-helm`, the Subscription), which a fresh lab has only after `search-up.sh`.
- **See it worked:** each MongoDBSearch Running, its two mongot Running and the Envoy pod Terminating
  (`kind-mesh-cilium/output/step1-swap.log`); then `kind-mesh/check.sh` 0 failed (`check-step1.txt`). The drill:
  [C1 to C3](testing-kind-mesh-cilium.md#step-1-no-envoy-balanced-per-connection), 0 of 237 failed, and the searches
  still stay remote until mongod restarts (per connection).
- **On the wire:** mongod to mongot directly, mutual TLS, no Envoy hop. In Hubble, `mongodb/mongo-0` to
  `search/mongot-search-0-<n>` on 27028, in the same or another cluster.

## 12. Step 2: WireGuard, Cilium's L7 load balancer, the search hop in cleartext

Three settings, one script, in the order the script enforces (A, C, B):

- **A. Sets:** in each cluster's Cilium release, `encryption.enabled: true, type: wireguard` and
  `loadBalancer.l7.backend: envoy` (`kind-mesh-cilium/cilium/values-step2.yaml`, `helm upgrade --reuse-values`), then
  the operator restarted (it registers the CiliumEnvoyConfig CRDs the agents wait for), then the agents. A gate: every
  agent of the three clusters must report `Encryption: Wireguard` before anything else changes.
  **Why:** Cilium's L7 proxy reads cleartext only, so the hop must drop MongoDB's own TLS; WireGuard encrypts
  everything between nodes, across the mesh too, so the hop loses nothing on the wire. Every cluster of a mesh must
  encrypt (Cilium's docs), and the record of a mixed mesh shows why: mesh0's member was cut off and the set elected
  mesh2 ([what went wrong](testing-kind-mesh-cilium.md#what-went-wrong-while-applying-step-2)).
- **C. Sets:** the MongoDBSearch without `spec.security.tls` (`45-mongodbsearch-cleartext.yaml`: mongot serves
  cleartext gRPC), then each mongod with `searchTLSMode=disabled`, secondaries first, one at a time.
  **Why:** both ends of the hop must agree before the proxy is put in the path.
- **B. Sets:** `mongot-global` annotated `service.cilium.io/lb-l7: enabled` (`44-mongot-global-l7.yaml`): Cilium's
  Envoy, on the client's node, balances each gRPC request, local mongot first.
  **Why:** per request, not per connection: a search that follows a failover goes back to a local mongot as soon as
  one is ready, with no restart; and a cluster's searches are spread over its two mongot.
- **Command:** `kind-mesh-cilium/scripts/cleartext-l7.sh`. It assumes the Cilium release `up.sh` made (it adds to
  it), step 11's MongoDBSearch, and step 8's data: it runs a search load through mesh2 during A and C, recorded in
  `kind-mesh-cilium/output/step2-load-*.txt` (a rerun rewrites those files). **After this step, never run `up.sh`
  again on the lab:** it would render the release without these values; since #193 it refuses, naming #166.
- **See it worked:** `Encryption: Wireguard` for each cluster, "every agent of the three clusters reports WireGuard
  encryption", each MongoDBSearch Running "mongot without TLS", each mongod "with searchTLSMode=disabled, back as
  SECONDARY", and a `CiliumEnvoyConfig` named `cilium-envoy-lb-mongot-global` per cluster
  (`kind-mesh-cilium/output/step2-apply.log`); `check.sh` 0 failed (`check-step2.txt`).
- **On the wire:** `kind-mesh-cilium/scripts/wire-check.sh` on the kind bridge: WireGuard packets on UDP 51871, none on TCP 27028 or
  27017, no VXLAN, the search text in no packet
  ([C6](testing-kind-mesh-cilium.md#c6-the-search-hop-is-encrypted-between-nodes), `wire-check.txt`). WireGuard does
  not decide who may connect: a pod anywhere, and a host outside WireGuard, reached mongot's port
  ([C7](testing-kind-mesh-cilium.md#c7-who-can-reach-mongots-cleartext-port), `wireguard-reach.txt`); step 14 is
  for that.
- **Hubble:** the flows now carry L7 (gRPC) verdicts as well as L3/L4, since Envoy sees each request; mesh2's
  searches during an outage split evenly between mesh0 and mesh1 and return to mesh2 by themselves
  ([C4](testing-kind-mesh-cilium.md#c4-a-cluster-loses-all-its-mongot-then-gets-them-back), the Grafana screenshot
  there). One thing to know (#187): an agent restart writes `mongot-global`'s frontend as plain L4 for about a
  minute, and a connection mongod opens then goes straight to one mongot, past Envoy, until mongod reconnects; step
  15 says how that is checked.

## 13. The lab's chart

- **Sets:** the search side as one Helm release per cluster, `mongot-search`, from
  `kind-mesh-cilium/chart/mongodb-search-cilium` with `chart/values-lab.yaml` (step 2's form: `searchTLS.enabled:
  false`, `globalService.lbL7.enabled: true`): the operator through OLM with an approver hook pinned to 1.13.0, the
  MongoDBSearch with no Envoy, `mongot-global` with its annotations. On a lab where steps 11 and 12 made these objects
  by hand, the release adopts them (Helm's ownership labels first), so nothing is recreated and no mongot rolls.
- **Why:** so the design is installable as a chart, not a history of `kubectl apply`; and because since step 11 OLM
  had stopped managing the operator (the old CSV blocked the Subscription), which the chart's own hook clears
  ([found on the way](testing-kind-mesh-cilium.md#the-labs-chart-mongodb-search-cilium)).
- **Command:** `kind-mesh-cilium/scripts/chart-up.sh` (its render tests first: `kind-mesh-cilium/chart/test.sh`).
- **See it worked:** "adopted …" for the four objects, "release deployed revision 1", "MongoDBSearch generation N -> N
  (spec unchanged: no mongot rolled)", the approver's InstallPlan Complete (`kind-mesh-cilium/output/chart-up.log`);
  `kubectl -n search get subscription mongodb-kubernetes` shows 1.13.0 installed and 1.14.0 waiting
  ([H1 to H6](testing-kind-mesh-cilium.md#the-labs-chart-mongodb-search-cilium)). Not tested: the chart on a cluster
  that never ran steps 11 and 12 (nothing to adopt).
- **On the wire / Hubble:** nothing changes: the rendering equals the live objects.

## 14. Who may connect to mongot

- **Sets:** a CiliumNetworkPolicy on the mongot pods, in every cluster (`kind-mesh-cilium/manifests/60-mongot-ingress.yaml`):
  27028 from the `mongodb`/`app=mongo` pods of mesh0, mesh1 and mesh2 (the cluster label named, since a selector
  without it matches the local cluster only); 9946 from the GUI and from the API server's proxy (`kube-apiserver`,
  `remote-node`). Everything else dropped; the local host allowed on every port by Cilium itself.
- **Why:** step 12's finding: WireGuard encrypts, it does not authorize. The trust is now a namespace and a label.
- **Command:** `for c in mesh0 mesh1 mesh2; do kubectl --context kind-$c apply -f kind-mesh-cilium/manifests/60-mongot-ingress.yaml; done`
  (no script of its own; `rebuild.sh`'s `mongot-ingress` phase runs exactly this).
- **See it worked:** `kind-mesh-cilium/scripts/mongot-reach.sh policy`: of four probe pods only the one in `mongodb`
  with `app=mongo` is answered, directly and through `mongot-global`; the VM gets no connection
  (`mongot-reach-policy.txt`; `kind-mesh-cilium/scripts/mongot-reach.sh open` without the policy answers all,
  [C8](testing-kind-mesh-cilium.md#c8-only-mongod-reaches-mongot-a-ciliumnetworkpolicy)). `check.sh` 0 failed under it
  (`check-policy.txt`).
- **Hubble:** policy verdicts: only the allowed sources, all `FORWARDED` (`mongot-ingress-verdicts.txt`); a
  disallowed pod's connections show as `Policy denied DROPPED` on the mongot's node (`drill-capture-ingress-control.txt`).

## 15. Our Cilium build (stories #145 and #190), and #187's check

- **Sets:** every agent and every mesh apiserver on the images of step 0, with the build's CiliumEndpoint CRD and
  its schema label (`CILIUM_CRD_URL`, `CILIUM_CRD_SCHEMA_VERSION`).
- **Why:** Hubble names the workload behind a destination pod on another node (#145) and in another cluster (#190):
  the clustermesh-apiserver writes a pod's workloads into its kvstore entry and the observing agent reads them.
- **Command, on a fresh lab:** none beyond `up.sh`: `versions.env` pins the images and `lib.sh` passes them to every
  Helm install and upgrade (`cilium_image_args`), loading them into each node first (`cilium_load_local`) and applying
  the CRD after the install (`cilium_build_crd`). **On a running lab:** `kind-mesh-cilium/scripts/cilium-build.sh
  measure before`, `upgrade`, `measure after`, `drill`: one cluster at a time under a search and write load, the CRD
  first, then a Helm upgrade that changes the images and nothing else, then step 2's gate, then #187's step. Not for
  a fresh lab: `measure before` expects the previous build's agents (`CILIUM_BEFORE_COMMIT`), and `measure after`
  compares the pods with the placement `measure before` recorded. For a rebuilt lab use:

  ```sh
  export CILIUM_OUTPUT_DIR="$(mktemp -d "$PWD/kind-mesh-cilium/output/rebuilt.XXXXXX")"
  CILIUM_PLACEMENT=fresh kind-mesh-cilium/scripts/cilium-build.sh measure after
  kind-mesh-cilium/scripts/cilium-build.sh drill
  ```

  `fresh` records that it skipped the old baseline comparison; it still checks placement stability during the
  measurement, agent versions, CEPs and attribution at `CILIUM_SCOPE=mesh` from `versions.env`. The separate output
  directory preserves the historical records and is also used by the drill.
- **#187's check:** after an agent restart, once `mongot-global`'s frontend on mongod's node is an L7 load balancer
  again, Cilium's Envoy there must count 20 searches through that mongod; if it does not, that mongod is restarted
  (`cilium-build.sh`, `l7_after_restart`; its record `cilium-build-190-l7.txt`: 20 of 20 in each cluster). It runs
  inside `cilium-build.sh upgrade` only. On a fresh lab, step 12 is the last agent restart and happens before
  `mongot-global` is annotated L7, so the same question exists there; the drill `kind-mesh-cilium/drills.sh mongot
  mesh2 both` answers it for mesh2 (searches return to mesh2 by themselves only through Envoy), and the GUI's
  "served by" for each member.
- **See it worked:** `kind-mesh-cilium/scripts/cilium-build.sh measure after` (on a lab with a baseline): every agent on `9e5a34a5`, every
  CiliumEndpoint of an owned pod carrying `status.workloads`, flows to the mongot on the other node named, flows to
  the other clusters' mongod named `StatefulSet/mongo` (`cilium-build-190-after.txt`); `kind-mesh-cilium/scripts/cilium-build.sh drill`: mesh2's
  search flows to another cluster's mongot all named, L3/L4 and L7 (`cilium-build-190-drill.txt`;
  [X1 to X5](testing-kind-mesh-cilium.md#across-cluster-mesh-too-story-190)). Without a baseline: `kubectl --context
  kind-mesh0 -n kube-system exec ds/cilium -c cilium-agent -- cilium-agent --version` prints `1.20.2 9e5a34a525`, and
  `kubectl get ciliumendpoints -A -o jsonpath='{.items[*].status.workloads}'` is not empty.
- **Hubble:** a flow's `destination.workloads` names `StatefulSet/mongot-search-0` or `StatefulSet/mongo` wherever
  the pod runs; the "Across the clusters" row of the dashboard depends on it.

## 16. The proofs

- **Command:** `kind-mesh/check.sh`: the mesh, the replica set, a `w: 3` write through the replica set, read on every member, every MongoDBSearch
  Running, every mongot holding both indexes STEADY, `$search` through every member, no volume over 10Gi. The exit
  code is the number of FAILs.
- **See it worked:** `== 0 failed`: 22 rows with two mongot per cluster, the policy and the observability stack
  (`kind-mesh-cilium/output/check-policy.txt`, `cilium-build-190-check.txt`; 19 rows with one mongot,
  `kind-mesh/output/check.txt`).
- **Optional examples, each with evidence in the testing records:**
  `kind-mesh-cilium/drills.sh mongot mesh2 both`, `kind-mesh-cilium/drills.sh spread mesh2`,
  `kind-mesh-cilium/drills.sh primary freeze`, `kind-mesh-cilium/scripts/wire-check.sh`,
  `kind-mesh-cilium/scripts/mongot-reach.sh policy`, `kind-mesh-cilium/scripts/cilium-build.sh drill`,
  `kind-mesh-cilium/scripts/primary-matrix.sh`, `kind-mesh-cilium/scripts/election-tuning.sh`
  (the replica set goes back to the defaults at its end: no profile is part of the lab),
  `kind-mesh-cilium/scripts/blip-test.sh`.

## Tear down and rebuild

`kind-mesh/scripts/rebuild.sh` runs steps 2 to 14 and 16 in this order, through the scripts named above, after
deleting the three clusters with `kind-mesh/scripts/down.sh`. It is orchestration only: each phase is one of the
scripts above (the policy, the `kubectl apply` of step 14), timed and logged to `kind-mesh/output/rebuild-<date>.XXXXXX/`,
and the run stops at the first failure, naming the phase.

- Without `--yes` it prints what a rebuild deletes, keeps and runs, and changes nothing. With `--yes` it first checks
  what it cannot make (the VM running, the tools, step 0's images in the VM's docker, both charts' local rendering, the kind network subnet, and the disk budget) and
  refuses before any deletion when one is missing.
- **Lost:** the replica set's data and search indexes (loaded again from the sample data), everything written since
  (`lab.drill`, `lab.probe`), mongot's indexes (rebuilt from the set), Loki's flows, Grafana's state, every Secret and
  user the scripts made (new passwords), the nodes' recorded addresses. **Kept:** the VM, the kind network, the
  images in the VM's docker, the recorded runs (the replay sets `CILIUM_OUTPUT_DIR` to its unique log directory, including the step-2 loads).
- `--reclaim-docker` (requires `--yes`, after the build) removes the VM docker's build cache and the images no
  container uses, never `localhost/kind-mesh/oc`, the two Cilium images or kind's node image; `docker rmi` is called
  without `-f`, so an image a container uses is kept and reported.
- Disk admission reserves `REBUILD_DISK_BUDGET_KIB` (default 12582912 KiB, a conservative budget, not a measured
  bound) below the 85% limit before deletion, without credit for deleted data. Increase it for larger images/data;
  later downloads, cluster readiness and concurrent disk writes can still fail after deletion.
- The VM is not touched: a stopped one is started with `kind-mesh/scripts/colima-up.sh` first.

The run on the lab, its times and checks: [testing-kind-mesh-cilium.md](testing-kind-mesh-cilium.md#rebuilt-from-scratch-story-193).
