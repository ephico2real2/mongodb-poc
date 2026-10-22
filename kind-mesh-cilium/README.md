# kind mesh lab on Cilium alone (story #132)

The `kind-mesh/` lab with the operator's Envoy removed: each cluster's MongoDBSearch uses `loadBalancer.unmanaged`,
and `mongot-global`, the Cilium global Service every mongod dials, points straight at the mongot pods of the three
clusters, local first. Results: [docs/testing-kind-mesh-cilium.md](../docs/testing-kind-mesh-cilium.md).

## Run it

On a lab built and passing with `kind-mesh/` (its README), from the repository's root:

| Step | Command |
| --- | --- |
| 1. Swap each cluster's search (in place: mongot and their volumes stay) | `kind-mesh-cilium/scripts/swap-search.sh` |
| 2. Check | `kind-mesh/check.sh` |
| 3. Drills (step 1) | `kind-mesh-cilium/drills.sh mongot mesh2 both`, `mongot mesh2 one`, `failback mesh2` |
| 4. Step 2: WireGuard, Cilium's L7 load balancer, the search hop in cleartext | `kind-mesh-cilium/scripts/cleartext-l7.sh` |
| 5. Check, drills (step 2), the wire | `kind-mesh/check.sh`; `drills.sh mongot mesh2 both`, `mongot mesh2 one`, `spread mesh2`; `scripts/wire-check.sh` |

## Files

| Path | What |
| --- | --- |
| `manifests/39-operator-olm.yaml` | The operator's OperatorGroup and Subscription, kept when the chart is uninstalled (1.13.0, Manual approval) |
| `manifests/40-mongot-certificate.yaml` | mongot's certificate, now also for `mongot-global`, the name mongod dials |
| `manifests/41-mongodbsearch.yaml` | The MongoDBSearch without the operator's Envoy |
| `manifests/42-mongot-global.yaml` | `mongot-global` over the mongot pods |
| `cilium/values-step2.yaml` | Step 2's Cilium settings: WireGuard, the L7 backend |
| `manifests/44-mongot-global-l7.yaml`, `45-mongodbsearch-cleartext.yaml` | Step 2: `mongot-global` balanced per request; the MongoDBSearch without TLS on the search hop |
| `scripts/swap-search.sh`, `scripts/cleartext-l7.sh`, `scripts/wire-check.sh`, `drills.sh`, `output/` | The two steps, the wire check, the drills, the recorded runs |

The chart is not changed: it always renders the operator's Envoy. If this design is kept, a chart option to leave it
out is a separate story.
