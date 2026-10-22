# kind mesh lab on Cilium alone (story #132)

The `kind-mesh/` lab with the operator's Envoy removed: each cluster's MongoDBSearch uses `loadBalancer.unmanaged`,
and `mongot-global`, the Cilium global Service every mongod dials, points straight at the mongot pods of the three
clusters, local first. Results: [docs/testing-kind-mesh-cilium.md](../docs/testing-kind-mesh-cilium.md).

## Install the search side: the lab's chart

`chart/mongodb-search-cilium` (not released) installs, in one cluster: the MongoDB operator through OLM (1.13.0,
Manual approval, approved by a hook), the MongoDBSearch without the operator's Envoy, and `mongot-global`. A hook
first clears a CSV that would stop the Subscription from resolving (`templates/00-csv-reclaim.yaml`). Run in every
cluster, from the repository's root:

```sh
kind-mesh-cilium/chart/test.sh          # render tests, no cluster needed
kind-mesh-cilium/scripts/chart-up.sh    # helm upgrade --install mongot-search in mesh0, mesh1, mesh2
```

`chart-up.sh` adopts the objects steps 1 and 2 made, so nothing is recreated. The values for this lab are in
`chart/values-lab.yaml`: `searchTLS.enabled: false` with `globalService.lbL7.enabled: true` is step 2's form;
`searchTLS.enabled: true` with `lbL7.enabled: false` is step 1's. The chart refuses both on.

The chart does not make what it depends on. Step 2's form needs, in every cluster:
- Cilium with WireGuard and the L7 backend (`cilium/values-step2.yaml`, applied by `scripts/cleartext-l7.sh`);
- each mongod with `searchTLSMode=disabled` (also `cleartext-l7.sh`);
- the sync user's password Secret, `search-sync-source-password` (`kind-mesh/scripts/mongo-up.sh`), and the members'
  CA, ConfigMap `ent-trust-bundle` (`kind-mesh/scripts/search-up.sh`).

Not tested: installing the chart on a cluster that never ran steps 1 and 2 (no adoption), or through Argo CD.

## How the lab was built: steps 1 and 2

On a lab built and passing with `kind-mesh/` (its README). These steps applied the design by hand, before the
chart existed; they are how the results in the testing record were produced.

| Step | Command |
| --- | --- |
| 1. Swap each cluster's search (in place: mongot and their volumes stay) | `kind-mesh-cilium/scripts/swap-search.sh` |
| 2. Check | `kind-mesh/check.sh` |
| 3. Drills (step 1) | `kind-mesh-cilium/drills.sh mongot mesh2 both`, `mongot mesh2 one`, `failback mesh2` |
| 4. Step 2: WireGuard, Cilium's L7 load balancer, the search hop in cleartext | `kind-mesh-cilium/scripts/cleartext-l7.sh` |
| 5. Check, drills (step 2), the wire | `kind-mesh/check.sh`; `drills.sh mongot mesh2 both`, `mongot mesh2 one`, `spread mesh2`; `scripts/wire-check.sh` |
| 6. The search side onto the chart | `kind-mesh-cilium/scripts/chart-up.sh` |
| 7. Story #131: the primary's cluster lost, under four client settings | `kind-mesh-cilium/scripts/primary-matrix.sh` (or one run: `CLIENT_OPTS='…' drills.sh primary freeze\|kill\|partition`) |
| 8. Election tuning: the same drills under six replica set profiles; then how long a link outage each election timeout rides out | `kind-mesh-cilium/scripts/election-tuning.sh`; `kind-mesh-cilium/scripts/blip-test.sh` |
| 9. Who may connect to mongot: reach test, the policy in every cluster, reach test again, check and drills | `kind-mesh-cilium/scripts/mongot-reach.sh open`; `kubectl --context kind-meshN apply -f kind-mesh-cilium/manifests/60-mongot-ingress.yaml`; `mongot-reach.sh policy`; `kind-mesh/check.sh`; `DRILL_TAG=policy drills.sh mongot mesh2 one`, `mongot mesh2 both`, `spread mesh2`; `scripts/drill-capture.sh <tag> mongot mesh2 both` with and without the policy |

## Files

| Path | What |
| --- | --- |
| `manifests/39-operator-olm.yaml` | Step 1: the operator's OperatorGroup and Subscription, kept when the Envoy chart is uninstalled (1.13.0, Manual approval) |
| `manifests/40-mongot-certificate.yaml` | Step 1: mongot's certificate, now also for `mongot-global`, the name mongod dials |
| `manifests/41-mongodbsearch.yaml` | Step 1: the MongoDBSearch without the operator's Envoy |
| `manifests/42-mongot-global.yaml` | Step 1: `mongot-global` over the mongot pods |
| `cilium/values-step2.yaml` | Step 2's Cilium settings: WireGuard, the L7 backend |
| `manifests/44-mongot-global-l7.yaml`, `45-mongodbsearch-cleartext.yaml` | Step 2: `mongot-global` balanced per request; the MongoDBSearch without TLS on the search hop |
| `scripts/swap-search.sh`, `scripts/cleartext-l7.sh`, `scripts/wire-check.sh`, `drills.sh`, `output/` | The two steps, the wire check, the drills, the recorded runs |
| `chart/mongodb-search-cilium/`, `chart/values-lab.yaml`, `chart/test.sh`, `scripts/chart-up.sh` | The lab's chart, its values, its render tests, its install in every cluster |
| `manifests/50-partition-mesh0.yaml`, `scripts/primary-matrix.sh` | Story #131: the Cilium deny policy that cuts mesh0's mongod off from the other clusters; the drill matrix and its table |
| `scripts/election-tuning.sh`, `scripts/blip-test.sh`, `scripts/rs-lib.sh`, `scripts/wan.sh` | Election tuning: the replica set profiles; the link outage test; their shared reconfig; a delayed, lossy or cut link between one cluster and the others (netem), since the clusters share one VM |
| `manifests/60-mongot-ingress.yaml`, `scripts/mongot-reach.sh`, `scripts/drill-capture.sh` | Who may connect to mongot: the CiliumNetworkPolicy (27028 from the three clusters' mongod only; 9946 from the GUI and the API server's proxy, which as `remote-node` is every node of the mesh); the probes that send mongot a gRPC request from four kinds of pod, and a TCP connection from the VM; a drill with every Hubble drop on the six nodes recorded, a control per node and Envoy's counters |

The repository's main chart (`chart/mongodb-search-helm`) is not changed: it always renders the operator's Envoy.
