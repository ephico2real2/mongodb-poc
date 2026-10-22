# Testing: MongoDB Search on Cilium alone, without the operator's Envoy (story #132)

What was tested on `kind-mesh-cilium/` on 2026-10-21 and 2026-10-22, and how to repeat it. Every result below is in a file under
`kind-mesh-cilium/output/`. The lab it changes, and the baseline it is compared with, is in
[testing-kind-mesh.md](testing-kind-mesh.md).

The change: each cluster's MongoDBSearch keeps its two mongot but drops the operator's Envoy
(`loadBalancer.unmanaged`). `mongot-global`, the Cilium global Service every mongod dials, now points straight at the
mongot pods of the three clusters, and still prefers the local ones. mongod and mongot keep mutual TLS.

Steps 1 and 2 below were applied by hand (scripts and manifests). The search side is now installed by the lab's chart,
`kind-mesh-cilium/chart/mongodb-search-cilium`, which took over the same objects ([the lab's chart](#the-labs-chart-mongodb-search-cilium)).

## Summary

Results, a search every half second through mesh2's own member:

| mesh2 loses… | Operator's Envoy | Step 1: no Envoy | Step 2: Cilium balances each search |
| --- | --- | --- | --- |
| all its mongot | 160 of 234 failed | 0 of 237 | 0 of 235, then 0 of 236 |
| one mongot | 0 of 237 | 0 of 237 | 0 of 237 |
| when they come back | stays remote until mongod restarts | stays remote until mongod restarts | returns to mesh2 by itself |
| spread over a cluster's two mongot | Envoy's round robin | no | yes, 20 and 20 |

- **Step 1 fixed the first problem.** With the operator's Envoy gone, a cluster with no ready mongot sends its
  searches to another cluster on its own.
- **Step 2 fixed the second.** Cilium sends each search to a local mongot when one is ready, so searches go back
  without a restart. Between nodes the search hop travels inside WireGuard (`kind-mesh-cilium/output/wire-check.txt`).
- **WireGuard does not limit who connects** to mongot's cleartext port: any pod in the three clusters reached it, and so
  did a host outside WireGuard ([C7](#c7-who-can-reach-mongots-cleartext-port)). A CiliumNetworkPolicy now lets only the
  three clusters' mongod pods, and the mongot's own node, reach it. Under it the check, the one-mongot drill and the
  spread pass; when mesh2 loses all its mongot, 1 to 3 searches failed at the deletion in each of 5 runs, against 1 of 3
  runs without it ([C8](#c8-only-mongod-reaches-mongot-a-ciliumnetworkpolicy)).
- **When the primary's cluster is lost, no write is acknowledged for 10.6–11.0 s (freeze, kill) or 23.4 s
  (partition) at the defaults.** `electionTimeoutMillis=5000` with `catchUpTimeoutMillis=0` brought that to 5.2–8.2 s,
  but turned a 4.5 s link outage into an election ([election tuning](#election-tuning-after-story-131)).

## Before you start

The Envoy lab built and passing (`kind-mesh/check.sh`). Then `export KUBECONFIG=~/.kube/mongodb-mesh.config`.

## Build

| # | What | Command | Passes when | Result |
| --- | --- | --- | --- | --- |
| S1 | Swap each cluster's search | `kind-mesh-cilium/scripts/swap-search.sh` | each MongoDBSearch Running with `loadBalancer.unmanaged`; no Envoy Deployment left | Passed, about 1 min a cluster; the operator rolled each cluster's mongot onto the new spec (`step1-swap.log`) |
| S2 | The lab is healthy | `kind-mesh/check.sh` | 0 failed | 0 failed: every mongot STEADY, a search through every member (`check-step1.txt`) |

## Step 1: no Envoy, balanced per connection

Each drill searches through mesh2's own member every half second for 120 s, and counts which cluster's mongot answered,
with mongot's own search counter. Step 1's records end in `.step1.txt`.

### C1. A cluster loses all its mongot

- **Run:** `kind-mesh-cilium/drills.sh mongot mesh2 both`. It removes both of mesh2's mongot from 15 s to 75 s.
- **Passes when:** no search fails.
- **Result: passed.** 0 of 237 failed. mesh0's mongot answered from then on (its count 1 → 212); the longest search
  took 244 ms (`drill-mongot-mesh2-both.step1.txt`).
- **Envoy lab, same drill:** 160 of 234 failed.

### C2. A cluster loses the mongot its mongod is connected to

- **Run:** `kind-mesh-cilium/drills.sh mongot mesh2 one`. It finds which of mesh2's mongot answers mesh2's searches
  and removes that one from 15 s to 75 s.
- **Passes when:** no search fails.
- **Result: passed.** 0 of 237 failed. mesh2's other mongot answered (mesh2's count 4 → 212, mesh0's unchanged)
  (`drill-mongot-mesh2-one.step1.txt`).

### C3. After a failover, do the searches come back?

- **Run:** after C1, `kind-mesh-cilium/drills.sh failback mesh2`.
- **Passes when (story #132's Step 2 target):** mesh2's searches return to mesh2's mongot without a restart.
- **Result: not yet.** Before the restart, mesh2's search was answered by another cluster. After a restart of
  mesh2's mongod, by mesh2's `mongot-search-0-1` (`drill-failback-mesh2.step1.txt`). This is the expected limit of a Service
  that balances connections: mongod keeps its connection. Step 2 (per-request balancing) is for it.

## Step 2: balanced per request, cleartext gRPC inside WireGuard

### Build

| # | What | Command | Passes when | Result |
| --- | --- | --- | --- | --- |
| S3 | WireGuard and Cilium's L7 load balancer in each cluster; the search hop to cleartext; `mongot-global` balanced per request | `kind-mesh-cilium/scripts/cleartext-l7.sh` | every Cilium agent reports `Encryption: Wireguard` before the search hop changes; each cluster gets a CiliumEnvoyConfig for `mongot-global` | Passed (`step2-apply.log`). During the Cilium upgrades, 819 searches through mesh2, 0 failed (`step2-load-cilium.txt`). The cleartext switch itself was not measured: the load ran in mesh2's mongod, which the switch restarts (`step2-load-cleartext.txt` ends at 29.4 s) |
| S4 | The lab is healthy | `kind-mesh/check.sh` | 0 failed | 0 failed (`check-step2.txt`) |

### C4. A cluster loses all its mongot, then gets them back

- **Run:** `kind-mesh-cilium/drills.sh mongot mesh2 both`
- **Passes when:** no search fails, and after mesh2's mongot return its searches go back to them with no restart.
- **Result: passed, twice.** 0 of 235 and 0 of 236 failed. During the outage mesh0 and mesh1 shared mesh2's searches
  evenly (30 and 30 at 45 s in the first run). After it, mesh2's mongot answered again (51 searches in each run), and
  the drill's last search was served by mesh2 (`drill-mongot-mesh2-both.step2.txt`, `drill-mongot-mesh2-both.txt`).

<img alt="The GUI during the outage: a search through mesh2's mongod served by mesh0/1." src="screenshots/kind-mesh-cilium-gui-failover.png">

*During the outage, mesh2's search is served by `mesh0/1`. [Before](screenshots/kind-mesh-cilium-gui-before.png) and
[after](screenshots/kind-mesh-cilium-gui-after.png): `mesh2/0`, with no restart.*

<img alt="Grafana: flows to search from mesh2 split 71 and 71 to mesh0 and mesh1 during the outages, mesh2's own line stopping and resuming." src="screenshots/kind-mesh-cilium-grafana-failover.png">

*Grafana over both runs ([dark](screenshots/kind-mesh-cilium-grafana-failover.dark.png)): mesh2's searches went to mesh0
and mesh1 in equal numbers (71 and 71) during the outages, and to mesh2 the rest of the time.*

### C5. A cluster loses one of its mongot

- **Run:** `kind-mesh-cilium/drills.sh mongot mesh2 one`
- **Passes when:** no search fails.
- **Result: passed.** 0 of 237 failed; every search stayed in mesh2 (`drill-mongot-mesh2-one.step2.txt`). Searches
  are spread over the cluster's mongot: `kind-mesh-cilium/drills.sh spread mesh2` (`drill-spread-mesh2.txt`).

### C6. The search hop is encrypted between nodes

- **Run:** `kind-mesh-cilium/scripts/wire-check.sh` (needs `tcpdump` in the VM, as its header says).
- **Passes when:** no port 27028 or 27017 and no VXLAN cross the kind bridge in the clear, WireGuard does, and the search
  text is in no packet.
- **Result: passed.** 15 s of searches through the three members: 3,221 WireGuard packets; 0 on TCP 27028, 0 on TCP
  27017, 0 VXLAN; 0 packets containing "space" (`wire-check.txt`).

### C7. Who can reach mongot's cleartext port

- **Run:** from a busybox pod in mesh1's `default` namespace, `nc -z -w 3` to both of mesh0's mongot pods and to
  `mongot-global` on 27028. Then from the VM itself, which is on the nodes' network but has no WireGuard key, with a
  route to mesh0-worker's pod network added for the test and removed after it.
- **Question:** does WireGuard limit who can connect?
- **Result: no.** All three answered the pod, and mesh0's mongot answered the VM (`wireguard-reach.txt`). WireGuard
  encrypts traffic between the nodes that run it; it does not decide who may connect. The `search` namespace has no
  network policy, and Cilium's encryption strict mode is off. Cilium 1.20.2 has `--enable-encryption-strict-mode-ingress`
  ("Enable strict mode encryption enforcement for ingress traffic"), and a CiliumNetworkPolicy could allow 27028 from
  the three clusters' mongod pods only. The policy is C8; strict mode was not applied or tested.
- **Correction:** `nc -z` to `mongot-global` proves only that the L7 proxy on the client's node answered: it completes
  the TCP handshake itself. C8 repeats the test with a gRPC request, which mongot itself answered (`mongot-reach-open.txt`),
  so the result stands.

### C8. Only mongod reaches mongot: a CiliumNetworkPolicy

- **The policy** (`kind-mesh-cilium/manifests/60-mongot-ingress.yaml`, applied in every cluster): 27028 from the mongod
  pods (`app=mongo` in `mongodb`) of mesh0, mesh1 and mesh2, the cluster label named because a selector without it
  matches the local cluster only (`policy-default-local-cluster=true`); 9946 from the GUI and from the API server's
  proxy (`kube-apiserver`, `remote-node`). Written from Hubble: through `mongot-global`'s proxy the client keeps its own
  identity. What it lets in besides, stated in its header: `remote-node` is every node of the three clusters but the
  mongot's own (in mesh0-worker's ipcache the other clusters' node IPs are identity 6, `remote-node`, and
  mesh0-control-plane's is 7, `kube-apiserver` and `remote-node`), and the local host reaches every port
  (`AllowLocalhost: always`).
- **Run:** `kind-mesh-cilium/scripts/mongot-reach.sh open` without the policy and `mongot-reach.sh policy` with it in
  every cluster (the records: `policy` at 13:24Z, then `open` at 13:26Z with the policy removed): four probe pods in
  mesh1, one per combination of the `mongodb` namespace and the `app=mongo` label, send a gRPC health check to both of
  mesh0's mongot and to `mongot-global`; then the VM, outside WireGuard, opens a TCP connection to mesh0-worker's mongot
  through a route added for the test.
- **Passes when:** without the policy every probe reaches mongot; with it only the probe in `mongodb` with `app=mongo`
  does, and the VM does not.
- **Result: passed.** Without the policy, mongot answered all twelve requests and the VM connected
  (`mongot-reach-open.txt`). With it, the three other probes got no answer in 5 s on all three targets, the VM no
  connection in 5 s, and the `mongodb`/`app=mongo` probe was answered by mesh0's mongot and through `mongot-global`
  (`mongot-reach-policy.txt`). The `mongot-global` row goes to mesh1's own mongot (affinity local), so it tests mesh1's
  copy of the policy. The trust is a namespace and a label: whoever can create a pod labelled `app=mongo` in `mongodb`
  gets in.
- **What still connects** (`mongot-ingress-verdicts.txt`, Hubble policy verdicts on the six nodes during 30 searches
  and a metrics read of each mongot): only the allowed sources, all `FORWARDED`. 27028 from the mongod of the mongot's
  cluster; 9946 from the API server's proxy, as `host`+`kube-apiserver` on the control-plane nodes and `remote-node` on the
  workers; 8080, the kubelet's probes, from the local host.
- **Check and drills with the policy:** `kind-mesh/check.sh` 0 failed (`check-policy.txt`). `drills.sh mongot mesh2 one`:
  0 of 237 failed (`drill-mongot-mesh2-one-policy.txt`). `spread mesh2`: 20 and 20 over mesh2's two mongot
  (`drill-spread-mesh2-policy.txt`). `mongot mesh2 both`: mesh0 and mesh1 served mesh2's searches during the outage and
  mesh2's mongot took them back, but 1 to 3 searches failed (`HostUnreachable`) at the moment mesh2's mongot were deleted.
- **Is that failure the policy?** Run with `kind-mesh-cilium/scripts/drill-capture.sh <tag> mongot mesh2 both`: every
  Hubble drop on the six nodes during the drill, a control on each node that must be dropped (proving that node's
  stream), and Envoy's counters for `mongot-global` before and after.
  - The policy drops nothing: 0 drops besides the controls in every run, and no Envoy connect timeout in the two runs
    that read Envoy's counters (e, f); a timeout is what a silent policy drop gives (`policy-deny-response` none,
    Envoy's connect timeout 5 s; Envoy counts a timeout as a connect failure too). A disallowed pod's SYNs to the six
    mongot, directly and through the proxy, were all recorded as `Policy denied DROPPED` on the mongot's node
    (`drill-capture-ingress-control.txt`), so such a drop would have shown.
  - The failure is an immediate connect failure to a mongot being torn down: with the policy, 12 connect failures and 0
    timeouts on mongo-0's node, 3 searches failed (`drill-capture-policy-e.txt`); without it, 0 and 0, no search failed
    (`drill-capture-nopolicy-f.txt`). Each failed search took under 250 ms.
  - It happens without the policy too (`drill-mongot-mesh2-both-nopolicy-a.txt`: 1 failed). Counts: 5 of 5 runs with the
    policy had a failure, 1 of 3 without on the same day (Fisher's exact test p = 0.11). The two runs of the same setup
    on 2026-10-21, both 0 failed (`drill-mongot-mesh2-both.step2.txt`, `drill-mongot-mesh2-both.chart.txt`; step 1's run
    was another setup), make it 1 of 5 without and p = 0.048. So the policy may make that moment more likely; it is not
    settled. At the rates seen, 8 runs each would show it about 3 times in 4, 10 runs each 9 times in 10. The earlier
    records, `drill-capture-{nopolicy-a,nopolicy-b,policy-c,policy-d}.txt`, come from a first version of the capture
    with one control, on mesh2-worker only, and no Envoy counters.
- **Reviewed** by two reviewers (OB3 on the policy and the reach test, OB2 on the capture and this conclusion), who ran
  the tests on the lab; their fixes are merged and were re-run here.

### What went wrong while applying step 2

| Run | What happened | Fix, now in `cleartext-l7.sh` |
| --- | --- | --- |
| 1 | After the Helm upgrade every agent still reported `Encryption: Disabled`: the agents read Cilium's configuration only when they start. The run was stopped before the search hop changed (its log was overwritten by run 2) | restart the agents after the upgrade; a gate that stops unless every agent reports WireGuard |
| 2 | mesh0's agents did not start: with the L7 backend on, they wait for CRDs the Cilium operator registers, and the operator had not been restarted (`step2-apply.run2-failed.log`) | restart the operator first and wait for its CRDs |
| 2 | While mesh0 encrypted and mesh1 and mesh2 did not, mesh0's mongod was cut off. The replica set elected mesh2 on its own, and mesh0 took the primary back once all three encrypted, with no action (`step2-mixed-mesh-evidence.txt`) | Cilium's docs say every cluster of a mesh must have WireGuard: the gate keeps the search hop unchanged until all do |

## The lab's chart: mongodb-search-cilium

The search side of this design as a Helm chart, for this lab (`kind-mesh-cilium/chart/`, not released): the operator
through OLM pinned to 1.13.0 with an approver hook, the MongoDBSearch with no operator Envoy, and `mongot-global`.
`searchTLS.enabled` and `globalService.lbL7.enabled` choose step 1's or step 2's form; the chart refuses both on.

| # | What | Command | Passes when | Result |
| --- | --- | --- | --- | --- |
| H1 | Render tests | `kind-mesh-cilium/chart/test.sh` | 0 failed | 18 PASS, 0 failed (`chart-test.txt`) |
| H2 | The lab's search onto the chart, in place | `kind-mesh-cilium/scripts/chart-up.sh` | release `deployed` in every cluster; the MongoDBSearch's generation unchanged | Passed: generation 4 → 4, no mongot rolled (`chart-up.log`) |
| H3 | OLM manages the operator | `kubectl -n search get subscription mongodb-kubernetes` | 1.13.0 installed; any newer version waits | `UpgradePending`: 1.13.0 installed, 1.14.0 staged and not approved, in every cluster |
| H4 | The lab is healthy, the drill unchanged | `kind-mesh/check.sh`; `kind-mesh-cilium/drills.sh mongot mesh2 both` | 0 failed; no search fails | 0 failed (`check-chart.txt`); 0 of 236 searches failed, mesh2's searches came back by themselves (`drill-mongot-mesh2-both.chart.txt`) |
| H5 | The chart's CSV reclaim, nothing to clear | `kind-mesh-cilium/scripts/chart-up.sh mesh2` | the reclaim exits without deleting; the approver finds 1.13.0 installed | Passed in 7.9 s: "nothing could be orphaned, not waiting" (`chart-reclaim.txt`, R1) |
| H6 | The chart's CSV reclaim, a CSV left without its Subscription | on mesh2: `kubectl -n search delete subscription mongodb-kubernetes`, then `chart-up.sh mesh2`, with a search every 0.5 s through mesh2's member | the reclaim deletes the CSV; 1.13.0 is installed again; no search fails | Passed in 27.3 s: ResolutionFailed seen after 5 s, the CSV deleted, the approver's InstallPlan Complete 14 s later; mongot not restarted; 296 searches, 0 failed, the longest 45 ms (`chart-reclaim.txt`, R2) |

**Found on the way:** since step 1's swap, every cluster's Subscription had been `ResolutionFailed`: the CSV the
earlier chart installed blocked the new Subscription ("@existing/search//mongodb-kubernetes.v1.13.0 and
operatorhubio-catalog … provide"). The operator kept running, so every result above stands, but OLM no longer
managed it, and `swap-search.sh` checked only the CSV's phase. The first takeover failed on it
(`chart-up.run1-failed.log`). H2 passed with `chart-up.sh` deleting that CSV. The chart now does it itself, with the
main chart's csv-reclaim script unchanged (`templates/00-csv-reclaim.yaml`, H5 and H6), so a plain
`helm upgrade --install` recovers from it.

Not tested: installing the chart on a cluster that never ran steps 1 and 2 (no objects to adopt), or through Argo CD.

## Story #131: the primary's cluster is lost

What a client sees when mesh0, the primary's cluster, is lost, and which client settings help. The client is mongosh
2.6.0 (Node.js driver 6.19.0, as mongod logs it) in mesh1's member.

- **Run one:** `CLIENT_OPTS='<options>' kind-mesh-cilium/drills.sh primary freeze|kill|partition`.
  **Run all twelve:** `kind-mesh-cilium/scripts/primary-matrix.sh` (about 40 minutes; mesh0 takes the primary back
  between runs by itself, priority 2).
- **What a run does:** for 150 s, every 0.5 s, a majority write through the replica set (`wtimeout` 3 s) and a search
  through mesh1's member. From 15 s to 75 s mesh0 is lost:
  - **freeze:** `docker pause` of mesh0's two nodes. Nothing there answers, and connections hang.
  - **kill:** SIGKILL of mesh0's mongod on its node; the kubelet restarts it.
  - **partition:** a Cilium deny policy cuts mesh0's mongod off from the other clusters
    (`kind-mesh-cilium/manifests/50-partition-mesh0.yaml`); mesh0 keeps running and steps down.
- **Read afterwards:** when the new primary was elected, from its own log; and whether `lab.drill` grew by exactly the
  number of acknowledged writes. A lost or doubled write, or a failed write that committed anyway, would show as a
  mismatch.
- **Passes when:** no search fails, and every acknowledged write is there, once.

**Result: passed in all twelve runs**, one run per row (`primary-matrix.txt`; each run's record is
`drill-primary-<mode>[-<options>].txt`):

| Lost by | Client options | Writes failed | Longest write | Searches failed | New primary elected after | Acknowledged writes all there, once |
| --- | --- | --- | --- | --- | --- | --- |
| freeze | `defaults` | 0 of 220 | 37.7 s | 0 of 220 | 10.8 s (mongo-mesh2) | yes |
| freeze | `connectTimeoutMS=5000&socketTimeoutMS=5000` | 2 of 264 | 10.0 s | 0 of 264 | 10.7 s (mongo-mesh2) | yes |
| freeze | `timeoutMS=10000` | 2 of 255 | 10.0 s | 0 of 255 | 9.9 s (mongo-mesh2) | yes |
| freeze | `heartbeatFrequencyMS=2000&connectTimeoutMS=5000` | 0 of 272 | 11.5 s | 0 of 272 | 9.9 s (mongo-mesh2) | yes |
| kill | `defaults` | 0 of 274 | 10.1 s | 0 of 274 | 10.4 s (mongo-mesh2) | yes |
| kill | `connectTimeoutMS=5000&socketTimeoutMS=5000` | 0 of 273 | 10.2 s | 0 of 273 | 10.4 s (mongo-mesh2) | yes |
| kill | `timeoutMS=10000` | 1 of 274 | 10.0 s | 0 of 274 | 10.4 s (mongo-mesh1) | yes |
| kill | `heartbeatFrequencyMS=2000&connectTimeoutMS=5000` | 0 of 275 | 9.7 s | 0 of 275 | 10.0 s (mongo-mesh2) | yes |
| partition | `defaults` | 0 of 201 | 47.2 s | 0 of 201 | 16.1 s (mongo-mesh2) | yes |
| partition | `connectTimeoutMS=5000&socketTimeoutMS=5000` | 4 of 245 | 10.0 s | 0 of 245 | 15.9 s (mongo-mesh2) | yes |
| partition | `timeoutMS=10000` | 3 of 235 | 10.0 s | 0 of 235 | 16.3 s (mongo-mesh2) | yes |
| partition | `heartbeatFrequencyMS=2000&connectTimeoutMS=5000` | 0 of 249 | 22.8 s | 0 of 249 | 16.2 s (mongo-mesh2) | yes |

- No search failed: searches run on mesh1's own member and mongot, which none of the modes touch.
- A new primary was elected 9.9–10.8 s after a freeze or a kill, and 15.9–16.3 s after a partition.
- **With the defaults no write failed, but one waited 37.7 s (freeze) or 47.2 s (partition).** It was held on its
  connection to the lost primary, which has no socket timeout. A killed mongod closes its connections, so there the
  wait was the election's, 10.1 s.
- **Timeouts cap the wait at 10.0 s, and the application must retry:** with `connectTimeoutMS=5000&socketTimeoutMS=5000`
  or `timeoutMS=10000`, up to 4 writes failed per run, after a freeze or a partition (each error is listed in
  `primary-matrix.txt`).
- **`heartbeatFrequencyMS=2000&connectTimeoutMS=5000`: no write failed in any mode.** The longest waits were 11.5 s
  (freeze), 9.7 s (kill) and 22.8 s (partition). The partition's 22.8 s is the server's, not the client's: a later run
  with the election trace found the new primary accepting writes 10 s after it was elected (see
  [Election tuning](#election-tuning-after-story-131)).

### The same, with a shorter election timeout

The replica set's `electionTimeoutMillis` from 10000 (the default) to 5000, then back
(`election5s-reconfig.txt`). Run with `DRILL_TAG=election5s`, the default client and the heartbeat setting
(`primary-matrix-election5s.txt`):

| Lost by | Client options | Writes failed | Longest write | Searches failed | New primary elected after | Acknowledged writes all there, once |
| --- | --- | --- | --- | --- | --- | --- |
| freeze | `defaults` | 0 of 220 | 37.7 s | 0 of 220 | 5.2 s (mongo-mesh2) | yes |
| freeze | `heartbeatFrequencyMS=2000&connectTimeoutMS=5000` | 0 of 274 | 10.5 s | 0 of 274 | 4.8 s (mongo-mesh2) | yes |
| kill | `defaults` | 0 of 285 | 5.1 s | 0 of 285 | 5.3 s (mongo-mesh2) | yes |
| kill | `heartbeatFrequencyMS=2000&connectTimeoutMS=5000` | 0 of 286 | 4.6 s | 0 of 286 | 4.8 s (mongo-mesh2) | yes |
| partition | `defaults` | 0 of 208 | 44.6 s | 0 of 208 | 8.0 s (mongo-mesh2) | yes |
| partition | `heartbeatFrequencyMS=2000&connectTimeoutMS=5000` | 0 of 273 | 11.3 s | 0 of 273 | 7.3 s (mongo-mesh2) | yes |

- The new primary was elected in about half the time: 4.8–5.3 s after a freeze or a kill, 7.3–8.0 s after a partition.
- With the heartbeat setting no write failed, and the longest wait was 10.5 s (freeze), 4.6 s (kill) and 11.3 s
  (partition).
- With the defaults the long waits stayed (37.7 s, 44.6 s): they are the client's, not the election's.
- **Correction:** being elected is not accepting writes. After a freeze or a partition the new primary waited about
  10 s more before accepting them, which is why the longest waits stayed near 11 s. Measured in
  [Election tuning](#election-tuning-after-story-131) below.

### Found on the way: a force-deleted pod is not a crash

The first kill drill force-deleted mesh0's mongod pod. mongod still received SIGTERM, stepped down and handed the
primary to mesh1 within a second (mesh1's log: "Received replSetStepUp request"); no write failed and the longest took
58 ms (`drill-primary-forcedelete.txt`). The kill mode now sends SIGKILL on the node instead.

## Election tuning (after story #131)

Which replica set settings shorten the time without writes when the primary's cluster is lost, and what they cost.
All three clusters run in one VM: the links between them have no delay, and they share its CPU. The times below are
this lab's, a floor rather than a forecast.

What the primary drill records since this work (`kind-mesh-cilium/drills.sh primary`):
- the two other members' replication log from the moment mesh0 is lost (`election_trace`);
- when the new primary was elected, and when it **accepted writes**, both from its own log;
- each write's own `_id`, so every acknowledged write is checked by id, and the failed ones that are in the database
  anyway are counted;
- the **longest time without an acknowledged write**, the outage an application sees (a write every 0.5 s).

### What a new primary waits for

The traces of a partition and a freeze at the default settings
(`drill-primary-partition-heartbeatFrequencyMS_2000-connectTimeoutMS_5000-trace.txt`, `…-freeze-…-trace.txt`):

| | Elected | Writes accepted |
| --- | --- | --- |
| partition | 12.4 s | 22.4 s |
| freeze | 10.0 s | 10.6 s |

Between the two, the new primary is in **catch-up**: it accepts writes once it has a heartbeat result from every
member since it restarted its heartbeats ("If any heartbeat is not fresh enough, return none",
`TopologyCoordinator::latestKnownOpTimeSinceHeartbeatRestart`, mongo r8.3.4). A member that does not answer gives a
result only when it is marked down, after `heartbeatTimeoutSecs` (10 s). When heartbeats restart, a request already
sent is kept, but one only scheduled is cancelled and sent again ("Only cancel heartbeats that are scheduled",
`replication_coordinator_impl_heartbeat.cpp`). In the freeze, mesh0 was marked down 0.6 s after the election, which
fits a request already in flight. In the partition, mesh0 had been marked down at 10.6 s, before the election at
12.4 s, and writes came 10 s after the election.

`catchUpTimeoutMillis=0` skips the catch-up. MongoDB's docs: a newly elected primary catches up with "members that may
have more recent writes", which may "reduce the amount of data that the other members would need to roll back".
Without it, writes that reached another secondary but not the new primary are rolled back; with `w: 1` the client may
have been told they succeeded. A majority write is not lost either way: a member without it cannot win the vote of
the members that have it ("candidate's data is staler than mine", `TopologyCoordinator::processReplSetRequestVotes`,
mongo r8.3.4). The drill writes with `w: "majority"`, and checks every one.

### Six profiles

- **Run:** `kind-mesh-cilium/scripts/election-tuning.sh` (about 50 minutes; the replica set returns to the defaults at
  the end, also when interrupted; each reconfig is logged in `election-tuning-reconfig.txt`). The client:
  `heartbeatFrequencyMS=2000&connectTimeoutMS=5000`.
- **Passes when:** no search fails, and every acknowledged write is there, once.

**Result: passed in all 18 runs** (`election-tuning.txt`; each run's record is
`drill-primary-<mode>-heartbeatFrequencyMS_2000-connectTimeoutMS_5000-<profile>.txt`). No search failed in any run.

| Replica set settings (others default) | Lost by | Writes failed | Longest without an acknowledged write | Elected | Writes accepted |
| --- | --- | --- | --- | --- | --- |
| defaults | freeze | 0 of 275 | 11.0 s | 10.0 s | 10.7 s |
| | kill | 0 of 276 | 10.6 s | 10.3 s | 10.3 s |
| | partition | 0 of 250 | 23.4 s | 15.0 s | 23.2 s |
| `catchUpTimeoutMillis=0` | freeze | 0 of 276 | 10.7 s | 10.4 s | 10.4 s |
| | kill | 0 of 276 | 10.5 s | 10.2 s | 10.3 s |
| | partition | 0 of 265 | 15.8 s | 15.5 s | 15.5 s |
| `electionTimeoutMillis=5000` | freeze | 0 of 274 | 11.4 s | 5.1 s | 11.0 s |
| | kill | 0 of 285 | 5.5 s | 5.2 s | 5.2 s |
| | partition | 0 of 273 | 11.3 s | 7.8 s | 11.0 s |
| `electionTimeoutMillis=5000`, `catchUpTimeoutMillis=0` | freeze | 1 of 279 | 7.3 s | 5.1 s | 5.1 s |
| | kill | 0 of 285 | 5.2 s | 4.9 s | 4.9 s |
| | partition | 0 of 280 | 8.2 s | 8.0 s | 8.0 s |
| `electionTimeoutMillis=5000`, `heartbeatTimeoutSecs=5` | freeze | 0 of 283 | 6.8 s | 4.7 s | 5.5 s |
| | kill | 0 of 286 | 5.5 s | 5.1 s | 5.1 s |
| | partition | 0 of 272 | 12.6 s | 8.0 s | 12.3 s |
| `electionTimeoutMillis=2000`, `catchUpTimeoutMillis=0` | freeze | 1 of 279 | 7.3 s | 1.9 s | 1.9 s |
| | kill | 0 of 292 | 2.2 s | 1.9 s | 1.9 s |
| | partition | 0 of 279 | 9.1 s | 2.9 s | 2.9 s |

A first round of the same 18 runs, before the drill had the longest gap and the check by id
(`election-tuning-run1/`), elected and accepted writes within 0.8 s of these times in every row.

- **A partition at the defaults costs 23.2–23.5 s** (two rounds) without writes; a freeze or a kill about 11 s.
- **`catchUpTimeoutMillis=0` alone** brings the partition to 14.8–15.5 s, the election's own time.
- **`electionTimeoutMillis=5000` alone helps a kill only** (writes back after 4.9–5.2 s). After a freeze or a
  partition, writes still start about 11 s in: the catch-up still waits for the silent member's 10 s.
- **5000 with no catch-up** accepted writes 4.9–8.0 s after any of the three; the longest gap was 5.2–8.2 s.
- **5000 with `heartbeatTimeoutSecs=5`** keeps the catch-up: good after a freeze (6.8 s), but a partition still pays
  a restarted 5 s (12.6 s).
- **2000 with no catch-up** accepted writes 1.9–2.9 s in, yet the longest gap after a freeze or a partition was still
  7.3–9.1 s. That remainder is the client's: the write in flight to the lost primary waits until the driver gives it
  up (`connectTimeoutMS=5000`, heartbeat every 2 s): the longest single write was 6.8 s after the freeze, 8.6 s after
  the partition. A kill closes the connections, and there the gap was 2.2 s.
- In both rounds, the freeze runs of `electionTimeoutMillis` 5000 and 2000 with `catchUpTimeoutMillis=0` each had one
  write fail with `connect EHOSTUNREACH` to mesh0's address in the 6 s after mesh0 came back. The write was never sent.
  Not investigated.

### The cost: a short link outage becomes an election

- **Run:** `kind-mesh-cilium/scripts/blip-test.sh` (about 10 minutes). For each `electionTimeoutMillis`, mesh0's nodes
  lose every packet they send to the other clusters for 1.5 to 9 s (`scripts/wan.sh cut`, netem on the nodes' links to
  the other clusters only); nothing else changes. Then the replica set's term is read: any election moves it. Between
  cases mesh0 takes the primary back.
- **Checked first:** with `wan.sh delay mesh0 50`, mesh0's heartbeat round trips to the other members read 77 and 76 ms,
  and 12 and 8 ms after `wan.sh off` (`wan-check.txt`). The reading before the delay was 316 and 271 ms: on this VM
  the round trip alone varies that much.

**Result** (`blip-test.txt`, one run per cell):

| Outage | `electionTimeoutMillis` 10000 | 5000 | 2000 |
| --- | --- | --- | --- |
| 1.5 s | no election | no election | **election** |
| 3 s | no election | no election | **election** |
| 4.5 s | no election | **election** | **election** |
| 6 s | no election | **election** | **election** |
| 9 s | no election | **election** | **election** |

- Each election moved the term by 2 or 3: another member was elected, then mesh0 took the primary back. A needless
  election interrupts writes twice.
- 5000 did not ride out 4.5 s, less than its own timeout: the timeout counts from the last heartbeat heard, which can
  be up to 2 s before the outage starts (heartbeats every 2 s).
- 2000 did not ride out the shortest outage tried, 1.5 s.

### Found on the way: a write that failed is in the database

In the first round, `electionTimeoutMillis=2000` with no catch-up, after a freeze: 231 writes acknowledged, but
`lab.drill` grew by 234 (`election-tuning-run1/drill-primary-freeze-…-e2000-c0.txt`). Three writes had failed with
`WriteConcernTimeout`, at 12.2 s, 21.0 s and 24.5 s: the primary applied them, but a majority did not confirm them
within the drill's `wtimeout` of 3 s. MongoDB "does not undo successful data modifications performed before the write
concern exceeded the wtimeout time limit" (write concern reference). The trace shows why a majority was late: mesh1
kept fetching from the frozen mesh0 until it changed sync source, 14.9 s after the freeze, and the first majority
commit in the new term came at 16.0 s. The new primary had been elected at 2.0 s.

Not one acknowledged write was missing or doubled; the count check flagged the extra writes, as its description said
it would. The drill now gives each write an `_id` and checks every acknowledged one by id: the second round found all
of them, and of the two failed writes, neither in the database. In the second round no freeze or partition trace
shows a change of sync source within its 40 s, and no write timed out on its write concern.

## Our Cilium build: workload names for pods on another node (story #145)

Hubble 1.20.2 names the workload of a pod on the agent's own node only. Our build,
`ghcr.io/ephico2real2/cilium-dev:1.20.2-remote-workload-1d3a02ab` (cilium-implementation-poc demo 39), writes it to
the pod's CiliumEndpoint (`status.workloads`), so the other node's agent can name it too. Its scope, as reviewed: the
same cluster, CiliumEndpointSlices off (off here); not carried across Cluster Mesh. The chart stays the release's; only
the agent image changes (`CILIUM_IMAGE`, `CILIUM_CRD_URL` pinned to the build's commit, `CILIUM_CRD_SCHEMA_VERSION` in
`kind-mesh/versions.env`).

| # | What | Command | Passes when | Result |
| --- | --- | --- | --- | --- |
| W1 | The measurement on the release | `kind-mesh-cilium/scripts/cilium-build.sh measure before` | 0 failed: every agent `e0dc92bd`; no CiliumEndpoint carries the field; mongod's search flows to the mongot on the other node name nothing (to the one on its own node: `StatefulSet/mongot-search-0`, the control); replication flows to the other clusters name nothing | **Passed**, 20:01Z: 0 failed; to the mongot on the other node L3/L4 0 of 9 and L7 0 of 8 named, in each cluster (`cilium-build-before.txt`) |
| W2 | The build, one cluster at a time (mesh2, mesh1, mesh0), a search and a majority write every 0.5 s through every member | `kind-mesh-cilium/scripts/cilium-build.sh upgrade` | each cluster's gate before the next: every agent `1.20.2 1d3a02ab`, `cilium status` healthy, WireGuard on every agent, connected to both other clusters, every CiliumEndpoint of an owned pod with the field; Helm values unchanged but the image; every acknowledged write found by id | **Gates passed, searches did not**: all three on the build in 232 s; writes 0 failed of 1,091, every acknowledged write found once; searches failed (`MaxTimeMSExpired`, 10 s) 8 times through mesh0 and 9 through mesh2, 0 through mesh1, while agents were replaced: #187 (`cilium-build.log`, `cilium-build-evidence.TosUeN/`) |
| W3 | The measurement on the build | `kind-mesh-cilium/scripts/cilium-build.sh measure after` | 0 failed: the flows to the mongot on the other node name `StatefulSet/mongot-search-0`, L7 and L3/L4; replication flows to the other clusters still name nothing | **Passed in mesh0 and mesh2, 2 failed in mesh1**, 20:09Z: other-node L3/L4 9 of 9 and L7 8 of 8 named; mesh1 L3/L4 7 of 7 but no L7 flow, its searches bypassing Cilium's Envoy until mongod reconnected (#187); after that, 20 L7 flows, all named, 10 and 10 over its two mongot (`cilium-build-after.txt`, `cilium-build-mesh1-l7-after-reconnect.txt`) |
| W4 | A search across clusters | `kind-mesh-cilium/scripts/cilium-build.sh drill` (mesh2 loses its mongot, `drills.sh mongot mesh2 both`) | searches answered (1 to 3 fail at the deletion, C8); mesh2's flows to another cluster's mongot recorded, expected to name nothing | **Passed**: to another cluster L3/L4 0 of 72 and L7 0 of 161 named, as expected; 236 searches answered, 1 failed (`HostUnreachable`) at the deletion (`cilium-build-drill.txt`, `drill-mongot-mesh2-both-build-load.txt`) |
| W5 | The lab is healthy | `kind-mesh/check.sh` | 0 failed | **Passed**: 0 failed (`cilium-build-check.txt`) |

How the script runs, and what it leaves:

- **The load.** It runs in batches of `LOAD_SECONDS` (60 s by default) through every member until the last gate has
  passed; each batch checks its own acknowledged writes by id, with a majority read, and a missing one fails the run.
  The summary gives the longest wait for an acknowledged write within the batches (`gapMs`) and, apart, the longest
  time between two batches (`betweenMs`), when the harness wrote nothing. No load mode runs `drills.sh`'s restore.
- **The disk.** The image is pulled on every node first, and only while the VM's disk stays below 85% used: mongot's
  volumes are on it, and mongot stops indexing at 85% (#182).
- **The evidence.** `output/cilium-build-evidence.<random>/`: each cluster's effective Helm values before and after,
  its revision before the upgrade, the load logs, the raw Hubble flows and probe replies. The run of 2026-10-22 commits
  the upgrade's (`cilium-build-evidence.TosUeN/`); the raw flows, 1.9 MB, are summarized in the records, not committed.
- **A failure.** The script stops at the cluster that failed, with no retry and no rollback: the clusters before it
  stay on the build, that cluster may be partly rolled out (a failed `--wait` comes after Helm changed resources), and
  the clusters after it are untouched. Back to the release: `helm history`, then `helm rollback cilium <revision>
  -n kube-system --kube-context kind-<c> --wait` with the revision saved in the evidence, not the one before the last.
- **The measurement.** `measure before` saves the application pods' UID, IP, node and owner
  (`output/cilium-build-placement.json`); `measure after` refuses to run if any of them changed. A fresh gRPC health
  check from mongod's container to the mongot on the other node gives the L3/L4 flow (the L7 proxy keeps its
  connection open); the searches give the L7 flows. Both are required, read on mongod's node with the cluster named.
- **What equal values do not prove.** Equal effective values do not prove equal manifests (the Kubernetes version, a
  template's `lookup`): nothing else may change the release or the cluster during the upgrade.

### Across Cluster Mesh too (story #190)

The next build (fork branch `hubble/remote-workload-clustermesh`, commit `9e5a34a525` on `1d3a02ab1a`) names the
workload of a pod in another cluster: the clustermesh-apiserver writes a pod's workloads into its kvstore entry, and
the observing agent reads them. So both images change, and both are built in the lab VM's docker, in no registry:

- `kind-mesh/versions.env`: `CILIUM_IMAGE=quay.io/cilium/cilium-dev:remote-workload-cm-9e5a34a5`,
  `CILIUM_CLUSTERMESH_IMAGE=quay.io/cilium/clustermesh-apiserver:remote-workload-cm-9e5a34a5`, `CILIUM_IMAGES_LOCAL=1`
  (`kind load docker-image` into every node, under the same 85% disk gate, instead of a pull). The CiliumEndpoint CRD
  did not change. The chart's one key `clustermesh.apiserver.image` sets the apiserver's four containers (etcd-init,
  etcd, apiserver, kvstoremesh).
- What each side runs and names is pinned, not coded: `CILIUM_BEFORE_COMMIT=1d3a02ab` with `CILIUM_BEFORE_SCOPE=cluster`
  (#145's build), and `CILIUM_SCOPE=mesh`. Agents print a commit of the build clone's length (`9e5a34a525`), so the
  script matches the commit by prefix.
- The gate also requires the clustermesh-apiserver Deployment rolled out with every container on the new image.
- After each cluster's gate, #187's step: once `mongot-global`'s frontend on mongod's node has `l7-load-balancer`
  again (`cilium-dbg bpf lb list`), Cilium's Envoy there must count the 20 searches of `drills.sh load-only <c> 10`
  (`upstream_rq_total` of `search/mongot-global`). All harness loads are drained and paused for the check, restart,
  and recheck. This aggregate counter is a smoke test, not per-request proof: other clients, retries or fanout can
  mask bypass. If it misses, that cluster's mongod is restarted (`kubectl delete pod mongo-0`), with rs0 health
  checked after draining and again before deletion. Restarting a primary triggers an election; mesh0 is normally
  primary. Health snapshots cannot exclude a concurrent failure. A second miss stops the run with loads paused. Each check and restart goes to `output/cilium-build-l7.txt`, and `measure after` accepts
  the restarted mongod's new UID and address only.

| # | What | Command | Passes when | Result |
| --- | --- | --- | --- | --- |
| X1 | The measurement on #145's build | `kind-mesh-cilium/scripts/cilium-build.sh measure before` | 0 failed: every agent `1d3a02ab`; every CiliumEndpoint of an owned pod carries the field; flows to the mongot on the other node name it, L3/L4 and L7; replication flows to the other clusters name nothing | **Passed**, 22:20Z: 0 failed; every agent `1d3a02ab`, other-node L3/L4 9 of 9 and L7 8 of 8 named in each cluster (`cilium-build-190-before.txt`) |
| X2 | Both images, one cluster at a time (mesh2, mesh1, mesh0), under the load | `kind-mesh-cilium/scripts/cilium-build.sh upgrade 2>&1 \| tee kind-mesh-cilium/output/cilium-build-190.log` | each cluster's gate and #187's step before the next; every acknowledged write found by id | **Rolled out; the final recheck stopped on a script bug**: the images went in by `kind load` (VM disk 51% → 68%), each cluster's gate and #187's step passed with no mongod restart (Envoy counted 20 of 20 in each, `cilium-build-190-l7.txt`), writes 0 of 2,390 failed, searches failed 9 times in each cluster while agents were replaced (#187); then `cilium-dbg encrypt status \| grep -q` failed under pipefail (SIGPIPE) on an agent that reported WireGuard with 5 peers, fixed in this branch (`cilium-build-190.log`) |
| X3 | The measurement on the build | `kind-mesh-cilium/scripts/cilium-build.sh measure after` | 0 failed: as X1, and replication flows to the other clusters name `StatefulSet/mongo` | **Passed**, 22:36Z: 0 failed; other-node L3/L4 9 of 9 and L7 8 of 8 in each cluster; mongod's flows to the other clusters' mongod name `StatefulSet/mongo`: 12 of 12, 10 of 10, 14 of 14 (`cilium-build-190-after.txt`) |
| X4 | A search across clusters | `kind-mesh-cilium/scripts/cilium-build.sh drill` | mesh2's flows to another cluster's mongot, L3/L4 and L7, all name `StatefulSet/mongot-search-0` | **Passed**: to another cluster L3/L4 **72 of 72** and L7 **160 of 160** named (with #145's build: 0 of 72, 0 of 161); 237 searches answered, 0 failed (`cilium-build-190-drill.txt`) |
| X5 | The lab is healthy | `kind-mesh/check.sh` | 0 failed | **Passed**: 0 failed (`cilium-build-190-check.txt`) |

## Compared with the Envoy lab

| mesh2 loses… | With the operator's Envoy | Step 1: per connection | Step 2: per request |
| --- | --- | --- | --- |
| all its mongot | 160 of 234 searches failed | 0 of 237 | 0 of 235, and 0 of 236 |
| one mongot | 0 of 237 | 0 of 237 | 0 of 237 |
| — and when they come back | remote until mongod restarts | remote until mongod restarts | **back to mesh2 by itself** |
| searches spread over a cluster's mongot | Envoy's round robin | no: one connection, one mongot | yes: 20 and 20 |
