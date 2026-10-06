# mongot Route Balance Rationale

Oct 6, 2026

## Decision

The passthrough Route in front of Envoy sets the router's balance algorithm explicitly:

```yaml
metadata:
  annotations:
    haproxy.router.openshift.io/balance: roundrobin
```

| Where | Object |
| --- | --- |
| [Fresh install runbook](mongot-envoy-mtls-fresh-install-runbook.md), Step 6d | Route `mongot-search`, and the Ingress alternative |
| [`manifests/80-route-passthrough.yaml`](../manifests/80-route-passthrough.yaml) | Lab Route `mongot-grpc` |

Without the annotation a passthrough Route uses `source`. This document records why `source` is the wrong fit for this path, why `roundrobin` was chosen, and what has and has not been measured.

## The path and who balances what

```text
mongod  --one long-lived HTTP/2 connection-->  Route (HAProxy, TCP mode)
                                                 picks an Envoy pod once per CONNECTION
                                                        |
                                               Envoy, 2 pods
                                                 picks a mongot pod once per gRPC STREAM
                                                        |
                                               mongot, 3 pods
```

Two balancers sit on the path and they work on different units. The Route annotation controls only the first one.

## What the Envoy side says

The Route talks to the Envoy Service, so the choice depends on what Envoy does with a connection once it has one. The Envoy facts below are read from the config the operator generated in the lab, saved in [`envoy/cds.json`](envoy/cds.json) and [`envoy/lds.json`](envoy/lds.json). The operator owns that config, so re-dump it before relying on these files for another environment ([ENVOY-FLOW.md](../ENVOY-FLOW.md), "Getting the config out of the pod").

**1. Envoy needs no client stickiness.**

`cds.json` defines one cluster, `mongot_rs_cluster`, of type `STRICT_DNS` on the headless mongot Service. It has no `lb_policy` key, so Envoy uses its default, `ROUND_ROBIN`, and picks a mongot pod for each gRPC stream. Every Envoy pod resolves the same three mongot pods and balances across them on its own.

Lab measurement: 30 queries split 10 / 10 / 10 across the three mongot pods ([REQUEST-PATH.md](../REQUEST-PATH.md), Figure 2).

Whichever Envoy pod a connection lands on, the spread across mongot is the same. Keeping a client on the same Envoy pod, which is what `source` provides, buys nothing here.

**2. The Route only places connections, not requests.**

A passthrough Route runs HAProxy in TCP mode. The TLS stream is opaque to the router, so it cannot see the gRPC streams inside it. `balance` picks an Envoy pod once, when the TCP connection opens. Per-request spreading happens only inside Envoy, one hop later.

This is specific to passthrough. On an edge Route the router runs in HTTP mode and balances each request, which is how the lab's edge design behaves ([`manifests/77-route-edge.yaml`](../manifests/77-route-edge.yaml)).

**3. Connections are long-lived.**

mongod holds one HTTP/2 connection and sends every search over it as streams. In `lds.json` the listener's HTTP connection manager sets:

| Setting | Value | Effect |
| --- | --- | --- |
| `http2_protocol_options.connection_keepalive` | `interval: 60s`, `timeout: 10s` | Envoy pings the connection every 60s and drops it if no reply arrives within 10s |
| `stream_idle_timeout`, `request_timeout` | `300s` each | Limits on a single stream, not on the connection |
| `max_connection_duration` | not set | Envoy's documented behaviour when unset: no maximum connection lifetime |
| `idle_timeout` | not set | Envoy's documented default: a connection with no active requests for 1 hour is drained and closed |

Envoy does not recycle a busy connection on a timer. A placement made by the Route sticks until the connection is re-opened: after an Envoy pod restart or rollout, a failed keepalive, a mongod restart, or one hour with no requests. The 1-hour idle default comes from the Envoy documentation and was not timed in the lab.

## What each value does on this path

| Value | Behaviour | Evidence | Verdict |
| --- | --- | --- | --- |
| `source` (passthrough default) | Hashes the client address to pick the Envoy pod | Lab: every client reached the router as one peer address, `192.168.127.1`; one Envoy pod logged 26,605 requests and the other 0 | Not used. It gives stickiness Envoy does not need, and it collapses onto one pod whenever clients share an address |
| `roundrobin` | Hands each new connection to the next Envoy pod in turn | Lab: 10 fresh TLS connections split 5 / 5 after the switch. Asserted by `./test/run.sh` | Chosen. It is the value measured in the lab |
| `leastconn` | Hands each new connection to the Envoy pod with the fewest open connections | Not measured in the lab. The HAProxy manual recommends it "where very long sessions are expected" | Reasonable alternative; measure it before switching |
| `random` | Picks an Envoy pod at random per connection | Not measured in the lab | Not evaluated |

## Lab evidence

All measurements are from the lab cluster (CRC, namespace `mongodb-poc`, Route `mongot-grpc`, two Envoy pods, three mongot pods), not from `dvh-gp6-rnd`.

| Measurement | Result | Recorded in |
| --- | --- | --- |
| Requests per Envoy pod under `source` | 26,605 and 0 | [REQUEST-PATH.md](../REQUEST-PATH.md), Figure 1 |
| Peer addresses seen by the router | All `192.168.127.1` | [REQUEST-PATH.md](../REQUEST-PATH.md), "Where each label comes from" |
| `downstream_cx_total` per Envoy pod before the change | 4 and 0 | [README.md](../README.md#passthrough-routes-do-honour-the-balance-annotation) |
| Same stat after `roundrobin` and 10 fresh TLS connections | 9 and 5, a 5 / 5 split | [README.md](../README.md#passthrough-routes-do-honour-the-balance-annotation) |
| HAProxy backend `be_tcp:mongodb-poc:mongot-grpc` | `balance roundrobin`, 2 servers | [TESTING.md](../TESTING.md); asserted in [`test/run.sh`](../test/run.sh) |
| Queries per mongot pod, through Envoy | 10 / 10 / 10 of 30 | [REQUEST-PATH.md](../REQUEST-PATH.md), Figure 2 |

The router template reads the annotation for TCP backends before it falls back to `ROUTER_TCP_BALANCE_SCHEME`, which is why a passthrough Route honours it. The template lines are quoted in [README.md](../README.md#passthrough-routes-do-honour-the-balance-annotation).

## What the annotation does not do

- **It does not spread requests.** One mongod connection stays on one Envoy pod, and every query on that connection goes through that pod. With a single mongod connected, one Envoy pod carries all the traffic under any algorithm.
- **It does not move open connections.** Changing the annotation decides where the next connection lands. Connections already open stay where they are until they reconnect.
- **It does not change the spread across mongot.** That is Envoy's round robin and is the same under every Route algorithm.

What it does buy: the second Envoy pod takes a share of the connections when there are several (more mongod members, reconnects, other clients) instead of sitting idle.

## Not measured

- **`dvh-gp6-rnd` itself.** How many distinct source addresses the router sees there is unknown. If mongod reaches the router through a load balancer that rewrites the source address, `source` would behave as it did in the lab.
- **Several router pods.** Each router pod is its own HAProxy process and keeps its own round-robin position and connection counts. The lab's default IngressController runs one router pod, so this was not exercised there. With few connections spread over several router pods, the split across Envoy pods may be less even than the lab's 5 / 5.
- **`leastconn` and `random`.** Neither was run in the lab.
- **The split after an Envoy rollout.** Connections re-open as pods are replaced; where they end up was not measured under any algorithm.

## How to verify

Both checks were run read-only against the lab on Oct 6, 2026. The annotation printed `roundrobin`. The lab had no search traffic at the time, so both Envoy pods reported 0 connections; the counts below confirm the commands run, not a split.

The algorithm set on the Route:

```bash
oc get route mongot-search -n $NS \
  -o jsonpath='{.metadata.annotations.haproxy\.router\.openshift\.io/balance}{"\n"}'
```

Connections accepted by each Envoy pod, from Envoy's admin port. This is the stat behind the lab's 5 / 5 result:

```bash
for p in $(oc get pods -n $NS -l app=mongot-search-lb-0 -o name); do
  oc port-forward -n $NS $p 19901:9901 >/dev/null 2>&1 & PF=$!
  sleep 3
  echo "== $p"
  curl -s --max-time 5 localhost:19901/stats | grep -E '^listener\.0\.0\.0\.0_27028\.downstream_cx_(total|active)'
  kill $PF; wait $PF 2>/dev/null
done
```

`downstream_cx_active` is the number of connections open now; `downstream_cx_total` counts every connection since the pod started. The runbook's Step 7c uses a simpler check, the number of requests each Envoy pod logged, which needs only `oc logs`.

## When to revisit

- `leastconn` is measured in the lab and gives a better split after Envoy rollouts.
- The operator's Envoy config changes: a `max_connection_duration` on the listener would make connections re-open regularly, and an `lb_policy` in `cds.json` would change how streams reach mongot.
- The Route changes from passthrough to edge, where the router balances requests instead of connections.

## Sources

- [Red Hat: Configuring Routes, route-specific annotations](https://docs.redhat.com/en/documentation/openshift_container_platform/4.3/html/networking/configuring-routes)
- [HAProxy: load-balancing algorithms](https://www.haproxy.com/documentation/hapee/latest/load-balancing/load-balancing-algorithms/)
- [Envoy: HttpProtocolOptions and KeepaliveSettings](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/core/v3/protocol.proto)
- [openshift/route-controller-manager, `pkg/route/ingress/ingress.go`](https://github.com/openshift/route-controller-manager/blob/master/pkg/route/ingress/ingress.go): `newRouteForIngress` sets `Annotations: ingress.Annotations`, so an Ingress annotation reaches the generated Route
