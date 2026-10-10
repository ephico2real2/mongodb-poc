# Diagram sources

Every figure in this repository is drawn in a `source.html` page (inline SVG, light and dark palettes) and rendered
to the PNGs beside it with [diagram-kit](https://github.com/ephico2real2/diagram-kit) (MPL-2.0). The kit writes a PNG only when the page passes its checks: a font that
did not load, a label that runs past its box, text that cannot be read in one of the two themes, a dashed arrow
with no label, a page that scrolls sideways at phone width.

The documents embed the light picture; the dark one is kept beside it. A figure, its text twin in the document and
its page change together.

## Render

```bash
# once: the kit, pinned, and its Chromium
python3 -m venv .venv
.venv/bin/pip install "diagram-kit @ git+https://github.com/ephico2real2/diagram-kit@v0.2.4"
.venv/bin/playwright install chromium

# from the repository root: a page, its folder, and its figure names in order
.venv/bin/diagram-render docs/diagrams/<page>/source.html docs/diagrams/<page> <names>
```

| Page | What it shows | Figure names, in order |
| --- | --- | --- |
| [`disruption-budgets/`](disruption-budgets/source.html) | A rolling node update on three nodes without and with a disruption budget; the same evictions measured on the lab | `rolling-update,measured` |
| [`envoy-flow/`](envoy-flow/source.html) | A request through Envoy's listener and filters; the same Envoy cluster against a headless and a ClusterIP Service | `request-lifecycle,headless-vs-clusterip` |
| [`envoy-load/`](envoy-load/source.html) | The CPU of the busy Envoy pod against its limit at seven steps of concurrency, with the default limit and with 2 CPUs, from the performance test | `cpu-against-limit` |
| [`grpc-through-envoy/`](grpc-through-envoy/source.html) | The path of a search over gRPC through Envoy | `request-path,movement` |
| [`mongot-openshift/`](mongot-openshift/source.html) | mongot on OpenShift, ten figures: the network layout, the gRPC path, failure domains, and the architecture as built, bypassed at L4, proposed, and behind a Route with F5 | `network-layout,grpc-path,failure-domains,end-to-end,architecture,l4-bypass,before-route-single,after-metallb-three,architecture-proposed,architecture-route-f5` |
| [`mongot-runbooks/`](mongot-runbooks/source.html) | The fresh install path and the TLS parties of the two runbooks | `fresh-install-path,cert-parties` |
| [`route-tls-options/`](route-tls-options/source.html) | The two Route TLS options, edge (77) and passthrough (88) | `option-77-edge,option-88-passthrough` |
| [`search-and-sync/`](search-and-sync/source.html) | A `$search` from the application through mongod to mongot; how each mongot replica replicates | `search-execution,index-sync` |
| [`storage-nfs/`](storage-nfs/source.html) | Two pods mounting one ReadWriteMany NFS claim | `nfs` |

Rendered with kit 0.2.0 on 2026-10-07, all seven pages exit 0 and all 21 light pictures are byte-identical to the
committed ones.

A new page starts from the kit's template: `.venv/bin/diagram-template docs/diagrams/<page>/source.html`.
