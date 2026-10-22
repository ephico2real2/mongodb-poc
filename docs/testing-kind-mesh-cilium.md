# Testing: MongoDB Search on Cilium alone, without the operator's Envoy (story #132)

What was tested on `kind-mesh-cilium/` on 2026-10-21, and how to repeat it. Every result below is in a file under
`kind-mesh-cilium/output/`. The lab it changes, and the baseline it is compared with, is in
[testing-kind-mesh.md](testing-kind-mesh.md).

The change: each cluster's MongoDBSearch keeps its two mongot but drops the operator's Envoy
(`loadBalancer.unmanaged`). `mongot-global`, the Cilium global Service every mongod dials, now points straight at the
mongot pods of the three clusters, and still prefers the local ones. mongod and mongot keep mutual TLS.

## Before you start

The Envoy lab built and passing (`kind-mesh/check.sh`). Then `export KUBECONFIG=~/.kube/mongodb-mesh.config`.

## Build

| # | What | Command | Passes when | Result |
| --- | --- | --- | --- | --- |
| S1 | Swap each cluster's search | `kind-mesh-cilium/scripts/swap-search.sh` | each MongoDBSearch Running with `loadBalancer.unmanaged`; no Envoy Deployment left | Passed, about 1 min a cluster; the operator rolled each cluster's mongot onto the new spec (`step1-swap.log`) |
| S2 | The lab is healthy | `kind-mesh/check.sh` | 0 failed | 0 failed: every mongot STEADY, a search through every member (`check-step1.txt`) |

## Test cases

Each drill searches through mesh2's own member every half second for 120 s, and counts which cluster's mongot answered,
with mongot's own search counter.

### C1. A cluster loses all its mongot

- **Run:** `kind-mesh-cilium/drills.sh mongot mesh2 both`. It removes both of mesh2's mongot from 15 s to 75 s.
- **Passes when:** no search fails.
- **Result: passed.** 0 of 237 failed. mesh0's mongot answered from then on (its count 1 → 212); the longest search
  took 244 ms (`drill-mongot-mesh2-both.txt`).
- **Envoy lab, same drill:** 160 of 234 failed.

### C2. A cluster loses the mongot its mongod is connected to

- **Run:** `kind-mesh-cilium/drills.sh mongot mesh2 one`. It finds which of mesh2's mongot answers mesh2's searches
  and removes that one from 15 s to 75 s.
- **Passes when:** no search fails.
- **Result: passed.** 0 of 237 failed. mesh2's other mongot answered (mesh2's count 4 → 212, mesh0's unchanged)
  (`drill-mongot-mesh2-one.txt`).

### C3. After a failover, do the searches come back?

- **Run:** after C1, `kind-mesh-cilium/drills.sh failback mesh2`.
- **Passes when (story #132's Step 2 target):** mesh2's searches return to mesh2's mongot without a restart.
- **Result: not yet.** Before the restart, mesh2's search was answered by another cluster. After a restart of
  mesh2's mongod, by mesh2's `mongot-search-0-1` (`drill-failback-mesh2.txt`). This is the expected limit of a Service
  that balances connections: mongod keeps its connection. Step 2 (per-request balancing) is for it.

## Compared with the Envoy lab

| mesh2 loses… | With the operator's Envoy | On Cilium alone |
| --- | --- | --- |
| all its mongot | 160 of 234 searches failed | **0 of 237** |
| one mongot (Envoy lab: either; here: the one serving) | 0 of 237 | 0 of 237 |
| — and when they come back | remote until mongod restarts | remote until mongod restarts |
