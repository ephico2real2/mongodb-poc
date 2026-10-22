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
| 3. Drills | `kind-mesh-cilium/drills.sh mongot mesh2 both`, `mongot mesh2 one`, `failback mesh2` |

## Files

| Path | What |
| --- | --- |
| `manifests/39-operator-olm.yaml` | The operator's OperatorGroup and Subscription, kept when the chart is uninstalled (1.13.0, Manual approval) |
| `manifests/40-mongot-certificate.yaml` | mongot's certificate, now also for `mongot-global`, the name mongod dials |
| `manifests/41-mongodbsearch.yaml` | The MongoDBSearch without the operator's Envoy |
| `manifests/42-mongot-global.yaml` | `mongot-global` over the mongot pods |
| `scripts/swap-search.sh`, `drills.sh`, `output/` | The swap, the drills, the recorded runs |

The chart is not changed: it always renders the operator's Envoy. If this design is kept, a chart option to leave it
out is a separate story.
