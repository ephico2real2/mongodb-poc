# Testing: a second Envoy for a vanity hostname, `chart/mongot-envoy-vanity-url-helm` (story #198)

What was tested of the chart, where, and how to repeat it: offline in CI (`test/vanity-chart.sh`, run on
2026-10-22), on the kind lab beside the main chart with mutual TLS, and on OpenShift by the owner. The guide is
[mongot-envoy-vanity-url.md](mongot-envoy-vanity-url.md); the chart's page is its
[README](../chart/mongot-envoy-vanity-url-helm/README.md). A test marked *(run pending)* has not been run yet: its
command and pass condition are written so that the run fills the result and nothing else.

## Summary

| Where | Tests | State |
| --- | --- | --- |
| CI, offline (`test/vanity-chart.sh`) | 90 assertions: lint, the renders, the schema's refusals, the bootstrap against the operator's capture, Envoy's validation of both renders, the preflight's script against a stand-in API | **90 passed, 0 failed** on 2026-10-22 (macOS, helm v4.3.0, Envoy 1.37.6 from the chart's image, digest `sha256:ea33a83e…`): `kind-mesh/output/vanity-chart.txt` |
| The preflight's script in its image | the rendered script, run as uid 1001 in `registry.access.redhat.com/ubi9/ubi@sha256:16e9e43d…` against the same stand-in API | exit 0 with every name found; exit 1 with `MISSING … does not name other.example.com` for a name the certificate lacks (2026-10-22, docker; a container run, no cluster) |
| CI, the main chart (`test/chart.sh`) | 233 assertions, unchanged by this story | 233 passed, 0 failed on the same day |
| CI, the lab chart (`kind-mesh-cilium/chart/test.sh`) | 19 assertions, one added: the hooks' image is the one `search-up.sh` loads | 19 passed, 0 failed on the same day |
| Kind lab (mesh2, namespace `vanity-lab`, through Cilium's Ingress) | K1 to K10 below | **9 passed, K8 not run** (no Prometheus on the lab) on 2026-10-23: `kind-mesh/output/vanity-*.txt`, `vanity-lab-*.txt`, `kind-mesh-cilium/output/ingress-up-mesh2.txt` |
| OpenShift, by the owner | O1 to O7 below | *(run pending)* |

CI, offline, one row per assertion group; the commands are under "Run it" and the outputs under "What was recorded":

| # | What | Passes when | Result |
| --- | --- | --- | --- |
| C1 | Lint, and the defaults refused | lint passes; the render of the defaults alone fails on the schema (`vanityHostname` is required) | Passed |
| C2 | The objects by default | ConfigMap `mongot-public-envoy`, Deployment, Service and PodDisruptionBudget `mongot-public-lb`, Route `mongot-public`, the preflight Job with its ServiceAccount, Role and RoleBinding; nothing else | Passed: the nine objects, every name from `search.name` |
| C3 | Names | with `search.name=srch` and `expose.name=vanity`, every object renamed `srch-public…` and the Route named `vanity` | Passed |
| C4 | The Route by default | `host` = `vanityHostname`, `tls.termination: passthrough`, `wildcardPolicy: None`, `haproxy.router.openshift.io/balance: roundrobin`, to Service `mongot-public-lb` port `mongot-grpc` | Passed |
| C5 | The Ingress | with `expose.type=ingress`: an Ingress and no Route; `ingressClassName: openshift-default`, annotations `route.openshift.io/termination: passthrough` and the balance, `path: ''`, `pathType: ImplementationSpecific`, no `spec.tls`; with `expose.ingressPath=/`, class `cilium` and the annotation `ingress.cilium.io/tls-passthrough: enabled`: `path: /`, `pathType: Prefix`, the annotation passing and the host kept; an `ingressPath` other than `""` or `/` refused by the schema | Passed |
| C5b | Reserved annotations (review) | with `expose.annotations` naming the termination (`edge`), the balance (`source`), the sync-wave (`9`) and `kept=yes`: the Ingress stays `passthrough`, `roundrobin`, wave `2`, and `kept` passes; on the Route the balance key is rendered once, `roundrobin` | Passed |
| C5c | `serverNames` must hold `vanityHostname` (review) | a list without it fails the render with `serverNames must hold vanityHostname …` (the Route's clients send it; the preflight checks `serverNames` only); a name twice is refused by the schema (`uniqueItems`: Envoy refuses overlapping filter chains) | Passed |
| C6 | Derived secret names and overrides | `ent-mongot-search-lb-0-cert`, `…-client-cert`, `ent-trust-bundle` mounted at `/etc/envoy/tls/{server,client,ca}`; `tls.certsSecretPrefix=lab` and `search.name=srch` change them; a set name wins, in the Deployment and in the preflight's Role | Passed |
| C7 | The bootstrap against the operator's capture | the ConfigMap's `bootstrap.yaml` as JSON, diffed field by field with `docs/envoy/{bootstrap,lds,cds}.json` (every top-level key of the captured bootstrap but `dynamic_resources`, the listener, the cluster), twice: the only differing paths are `…filter_chain_match.server_names` (the capture's namespace and name) and, in another namespace with two server names, that plus the cluster's endpoint `address` and `sni`; one listener and one cluster, no `dynamic_resources`; a capture with more than one listener or cluster stops the comparison | Passed: 1 field differs in the first render (`server_names[0]`: `grpc-search.apps-crc.testing` → `mongot-public.example.com`); 3 in the other (`server_names`, the endpoint address and the SNI, both `srch-search-0-svc.team-a.svc.cluster.local`) |
| C8 | The values reach the bootstrap | the retry count, the per-try timeout, the four timeouts and the port sit where the operator's values sit | Passed: `5 15s 120s 121s 122s 123s 27029 27029` |
| C9 | Envoy's own validation | both rendered bootstraps, with throwaway certificate files, unpacked into the chart's image (`quay.io/ephico2real/envoy:v1.37-latest`) and validated as the image's `envoy` user: exit 0 and `configuration '/etc/envoy/bootstrap.yaml' OK` for both; a copy with an unknown filter type refused; with `CONTAINER_ENGINE` set and no engine, a `FAIL`, never a skip | Passed: `loading 1 cluster(s)`, `loading 1 listener(s)`, `configuration '/etc/envoy/bootstrap.yaml' OK`; `CONTAINER_ENGINE=nosuchengine` gives `1 failed` |
| C10 | Requests and limits on every container | every Job and Deployment container of a render with the monitor on has `requests.cpu`, `requests.memory`, `limits.cpu`, `limits.memory` | Passed: 2 containers (Envoy, the preflight), 4 of 4 each |
| C10b | `envoy.runAsUser` (review) | no `runAsUser` by default (OpenShift assigns one); with `envoy.runAsUser=101`, `runAsNonRoot: true`, `runAsUser` and `runAsGroup` 101 (the image's own user is root; its entrypoint drops to `envoy`) | Passed |
| C11 | The schema's refusals | an IP, a one-label name, an uppercase name and a trailing dot as `vanityHostname` and in `serverNames`; an unknown key at the top, under `envoy` and under `expose`; an IP in `serverNames`; a name twice; 0 replicas; `maxUnavailable: 0`; `envoy.timeouts.route=300`; a 44-character `search.name`; port 70000; an invalid namespace; resources without limits; `512MB`; `expose.type=loadbalancer`; `expose.balance=sticky`; `expose.ingressPath=/search` | Passed, 22 refusals |
| C12 | The monitoring objects | nothing by default; with `monitoring.serviceMonitor.enabled=true` a ClusterIP Service on 9901 selecting this Deployment's pods, without the main chart's `mongodb.com/search-name` label, and a ServiceMonitor on `/stats/prometheus` with the `_total` relabel; never a Route | Passed |
| C13 | The preflight's script, against a stand-in `curl` | the Job's script taken out of the render; `curl` answers `GET /api/v1/namespaces/<ns>/<kind>/<name>` from JSON files as the API server would (200, 404 NotFound, 403 Forbidden, 500 with an HTML body, curl's exit 7, or its exit 60 with the paragraph after the first line); it answers only a call with the ServiceAccount's CA (never `-k`), the token from a header file and on no command line, and `--connect-timeout` and `--max-time`, each once; a stand-in ServiceAccount directory with a token; a throwaway certificate with `DNS:mongot-public.example.com, DNS:*.apps.example.com`. Everything present: exit 0 naming the hostname and the Service; `x.apps.example.com` accepted by the wildcard; `a.b.apps.example.com` refused (one label only); `other.example.com` refused with the SANs listed and `FAILED: 1 problem`; a certificate with the hostname as CN and no SAN refused; a missing server secret named with the API's reason (`NotFound secrets "…" not found`) and the certificate then not checked; a missing client secret, trust bundle and Service counted as 3; a Forbidden reported as one; an API server that does not answer reported with curl's error, one its CA does not verify with curl's first line, and an HTTP 500 without a JSON Status as `HTTP 500` with no traceback; a secret without `tls.key`, a client secret without `tls.crt`, a trust bundle without `ca.crt` each refused; an image without `curl`, `python3` or `openssl` refused naming the image and the tool; no token file, and no CA file, refused; no certificate, key or token printed; the 4 GETs each with a connect timeout within its `--max-time`, their sum inside the Job's 180 s deadline | Passed, 22 assertions |
| C14 | The preflight script's lint | its syntax and shellcheck at warning level, both clean | Passed |
| C15 | The documents | NOTES and the README say to restart the pods after a rotation; the main README and the main chart's README link the chart and `docs/mongot-envoy-vanity-url.md` | Passed |
| P1 | The preflight's script in its image | the rendered script, as uid 1001 in the UBI 9 image by digest, against the stand-in API: exit 0 naming every server name; with a name the certificate lacks, `MISSING … does not name other.example.com (SANs: …)`, `FAILED: 1 problem`, exit 1 | Passed |

Kind lab, run on 2026-10-23 on `mesh2` (the cluster with the most headroom: its worker at 7% memory, `vanity-lab-state.txt`),
in a namespace of its own, `vanity-lab`, beside the lab's `search` release, which was not touched: the main chart
(`chart/mongodb-search-helm`, the operator's Envoy, `loadBalancer.managed`) installed there from
`kind-mesh/values/vanity-lab-search.yaml`, its mongot syncing from the lab's replica set, its five prerequisites made by
the chart's script from throwaway PEMs signed by the lab's CA, its operator a second OLM install of the same package
(OwnNamespace: the `search` release's operator watches `search` only, `WATCH_NAMESPACE` from its OperatorGroup); then
this chart with `expose.type=ingress` through Cilium's own Ingress controller (class `cilium`, `expose.ingressPath=/`,
the annotation `ingress.cilium.io/tls-passthrough: enabled`), enabled on mesh2 by `kind-mesh-cilium/scripts/ingress-up.sh`
(`ingress-up-mesh2.txt`: the agents rolled 03:17:52 to 03:18:04Z, Cilium healthy 03:19:02Z; the shared Service
`cilium-ingress` at `172.18.255.72` from `mesh-pool`). No OpenShift Route on kind. `VANITY=mongot-public.lab.example`,
`INGRESS=172.18.255.72`; the traffic came from a probe pod in the namespace (curl with HTTP/2, the client certificate
and the trust bundle mounted); the commands are under "Run it", the outputs under "What was recorded":

| # | What | Passes when | Result |
| --- | --- | --- | --- |
| K1 | The chart installs beside the main chart, through Cilium's Ingress | the preflight Job succeeds (its log ends with `the certificate names every server name`); 2 pods `1/1 Running` with `app=mongot-public-lb`; Ingress `mongot-public` of class `cilium` with an address; the operator's `mongot-search-lb-0` pod untouched | **Passed** (`vanity-install.txt`): helm exit 0; the preflight's last line as expected; pods `mongot-public-lb-7886bc55b4-v5cqd` and `-xzjrg` Running on the two nodes; the Ingress's class `cilium`, the annotation `enabled`, path `/` with `Prefix`, address `172.18.255.72`; `mongot-search-lb-0-…` Running, age 3m52s |
| K2 | A gRPC health check by the vanity name through Cilium's Ingress | with `$VANITY` as SNI at `$INGRESS:443`: TLSv1.3, ALPN h2, our server certificate, and `grpc-status: 0` with the 7-byte body `00 00 00 00 02 08 01` (HealthCheckResponse status 1, SERVING); one access-log line in our pods with an `upstream_host` that is a mongot pod | **Passed** (`vanity-reach.txt`): `SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384`, `ALPN, server accepted to use h2`, `subject: CN=mongot-search.vanity-lab.example`, `HTTP/2 200`, `grpc-status: 0`, curl's exit 0, `00 00 00 00 02 08 01`; the access log: `"upstream_host":"10.30.0.118:27028"` (mongot-search-0-1) |
| K3 | A wrong SNI refused | through the Ingress, `wrong.lab.example` gets no certificate and the handshake fails before our Envoy (its `downstream_cx_total` unchanged, no access-log line); straight at our Service, the handshake closes with no certificate and our listener's `no_filter_chain_match` goes up by one | **Passed** (`vanity-wrong-sni.txt`): through the Ingress `SSL_connect: Connection reset by peer`, curl's exit 35, `downstream_cx_total` 1 and 0 before and after; at the Service `Connection reset by peer`, curl's exit 35, `no_filter_chain_match` 1 → 2 on the pod that took the connection; 0 access-log lines mention the name |
| K4 | The spread over the mongot pods | `membership_healthy: 2`; 30 requests through the Ingress reach both pods, the counts recorded | **Passed** (`vanity-spread.txt`): 31 requests (K2's and 30), `upstream_rq_total` 14 and 17 on our two pods, `membership_healthy: 2` on both; the access log's `upstream_host`: 16 × `10.30.0.118:27028`, 15 × `10.30.1.137:27028`, the two mongot pods |
| K5 | The preflight refuses a missing secret | helm fails on the hook; the log says `MISSING: secret no-such-secret: NotFound secrets "no-such-secret" not found` and `FAILED: 1 problem`; the Deployment is unchanged | **Passed** (`vanity-preflight-missing.txt`): helm `pre-upgrade hooks failed`, the two lines as expected, `generation 1, client secret ent-mongot-search-lb-0-client-cert`, revision 2 `failed` |
| K6 | The preflight refuses a certificate without the name | the log says `its certificate does not name other.lab.example (SANs: …)`; nothing changed | **Passed** (`vanity-preflight-name.txt`): `does not name other.lab.example (SANs: mongot-search.vanity-lab.example mongot-public.lab.example)`, `FAILED: 1 problem(s)`; the Ingress's host still `mongot-public.lab.example`, revision 3 `failed` |
| K7 | The operator reconciles its own Envoy and not ours | our Deployment's generation unchanged and no ownerReference after a no-op patch of the MongoDBSearch; the operator's Deployment still its own | **Passed** (`vanity-reconcile.txt`): ours `generation 1, ownerReferences` empty before and after (`mongodbsearch.mongodb.com/mongot patched (no change)`); the operator's `generation 2, annotation test=x, ownerReferences mongot` |
| K8 | The ServiceMonitor with #191's Prometheus | the two Envoy pods scraped | **Not run**: the lab has no Prometheus (`observability` holds Grafana, Loki and the Hubble observer only). The evidence is the main chart's own dashboard (`chart/mongodb-search-helm/files/mongodb-search.json`), fed by the ServiceMonitors, with this chart's ServiceMonitor on our Envoy: pictured with #191 on kind, or on the owner's OpenShift run |
| K9 | DR toggle: traffic through the vanity hostname | with `expose.enabled=false` the Ingress is gone and the K2 check at `$INGRESS` fails; with `true` the Ingress returns and the K2 check answers again | **Passed** (`vanity-dr-toggle.txt`): after `false`, `No resources found` for ingresses and `Immediate connect fail for 172.18.255.72: No route to host`, curl's exit 7; after `true`, the Ingress back with its address, the check 4 s later curl's exit 35 (the handshake, Cilium's Envoy not yet programmed) and at 03:26:37Z `HTTP/2 200`, `grpc-status: 0`, `00 00 00 00 02 08 01` |
| K10 | Uninstall leaves the main chart's objects | everything named `mongot-public…` gone, the Ingress included; the main chart's Deployment, Services, secrets, trust bundle and MongoDBSearch as before | **Passed** (`vanity-uninstall.txt`): `release "mongot-public" uninstalled`; left: `mongodb-kubernetes-operator`, `mongot-search-lb-0`, the three Services, the three secrets, `ent-trust-bundle`, the MongoDBSearch `Running`; our two pods `Terminating`, no Ingress, no `mongot-public-lb` Service |

After K10 the main chart's release and the namespace were removed (`vanity-lab-cleanup.txt`: `release "mongot" uninstalled`,
`mongodbsearch,pvc left: 0`, `namespace "vanity-lab" deleted`); the `search` release's pods kept their ages, Cilium's
Ingress controller stays on mesh2 (`cilium-ingress 172.18.255.72`), and the lab's own check passed afterwards
(`vanity-lab-check-after.txt`: `== 0 failed`).

OpenShift, by the owner: the steps of [the guide](mongot-envoy-vanity-url.md#steps), recorded with the owner's output,
company names scrubbed; screenshots in `docs/screenshots/`, light and dark where the console has both:

| # | What | Passes when | Result |
| --- | --- | --- | --- |
| O1 | Install with a Route (guide, steps 1 to 3) | the preflight passes; 2 pods Ready | *(run pending)* |
| O2 | The Route (step 4) | `passthrough`, host `$HOST`, `roundrobin`, Admitted | *(run pending)* — screenshot `vanity-console-route.light.png`, `.dark.png` |
| O3 | The certificate served (step 6) | the company certificate with `$HOST` among its SANs, TLSv1.3, ALPN h2 | *(run pending)* |
| O4 | A wrong name refused (step 7) | the router's default certificate, no ALPN | *(run pending)* |
| O5 | `$search` through the vanity name (steps 8 and 9) | results; access-log lines in `deploy/${NAME}-public-lb` with mongot pod IPs; our Envoy's counters up, the operator's unchanged | *(run pending)* — screenshot `vanity-console-pods.light.png`, `.dark.png` |
| O6 | The same through an Ingress (step 10) | the Route of O2 gone; the Ingress of class `openshift-default`; the generated Route `${NAME}-public-<suffix>` passthrough with the balance; O3 to O5 pass again | *(run pending)* — screenshot `vanity-console-ingress.light.png`, `.dark.png` |
| O7 | DR toggle: traffic through the vanity hostname (guide, "Prove which path the traffic takes") | with `expose.enabled=false` the Route is gone and a mongod on the vanity name stops reaching search; set back to true, the Route returns and the search answers | *(run pending)* |

## Files

| File | What |
| --- | --- |
| `test/vanity-chart.sh` | the CI suite: lint, renders, schema refusals, the bootstrap against `docs/envoy/`, Envoy's validation, the preflight's script against the stand-in API |
| `kind-mesh/output/vanity-chart.txt` | the CI suite's output of 2026-10-22, written by the command under "Run it" (exit 0) |
| `docs/envoy/bootstrap.json`, `lds.json`, `cds.json` | the operator's Envoy configuration the bootstrap is compared with |
| `kind-mesh/output/vanity-lab-state.txt`, `vanity-lab-prerequisites.txt`, `vanity-lab-main-chart.txt` | the lab before (headroom, the operator's scope, the pool), the five prerequisites made by the chart's script, the main chart's install in `vanity-lab` |
| `kind-mesh-cilium/output/ingress-up-mesh2.txt`, `ingress-up-mesh2.run1-no-restart.txt` | Cilium's Ingress controller on mesh2: the run with the agents' restart, and the first run without it |
| `kind-mesh/output/vanity-install.txt`, `vanity-reach.txt`, `vanity-wrong-sni.txt`, `vanity-spread.txt`, `vanity-preflight-missing.txt`, `vanity-preflight-name.txt`, `vanity-reconcile.txt`, `vanity-dr-toggle.txt`, `vanity-uninstall.txt` | the kind rows K1 to K10, one file each (K8 not run) |
| `kind-mesh/output/vanity-lab-cleanup.txt`, `vanity-lab-check-after.txt` | the clean-up of `vanity-lab`, and the lab's own check afterwards (`== 0 failed`) |
| `kind-mesh/values/vanity-lab-search.yaml`, `kind-mesh-cilium/cilium/values-ingress.yaml`, `kind-mesh-cilium/scripts/ingress-up.sh` | the main chart's values for `vanity-lab`; Cilium's Ingress values and the script that adds them |
| `docs/screenshots/vanity-console-*.png` | the owner's OpenShift screenshots *(to be taken)* |

## Run it

The CI suite, from the repository's root, its output to the record file (docker, or podman, for Envoy's validation;
with `CONTAINER_ENGINE` set and no engine answering, the suite fails on that check rather than skipping it):

```bash
CONTAINER_ENGINE=docker bash test/vanity-chart.sh > kind-mesh/output/vanity-chart.txt 2>&1; echo "exit=$?"
grep -c '^ok' kind-mesh/output/vanity-chart.txt
```

The main chart's suite and the lab chart's suite, unchanged by this story but run after it:

```bash
bash test/chart.sh
bash kind-mesh-cilium/chart/test.sh
```

The preflight's script in its own image (P1), against the stand-in API of the suite, from a scratch directory
holding the rendered script as `preflight.sh`, the stand-in `curl` under `bin/`, the fixtures under `cluster/` and a
token under `sa/` (what the suite makes under its temporary directory):

```bash
tar -cf - . | docker run --rm -i --user 1001 -e CLUSTER=/tmp/work/cluster -e SA_DIR=/tmp/work/sa -e NAMESPACE=mongodb-poc \
  -e SERVER_SECRET=ent-mongot-search-lb-0-cert -e CLIENT_SECRET=ent-mongot-search-lb-0-client-cert -e TRUST_CM=ent-trust-bundle \
  -e MONGOT_SERVICE=mongot-search-0-svc -e JOB_IMAGE=ubi9 -e SERVER_NAMES="mongot-public.example.com x.apps.example.com" \
  registry.access.redhat.com/ubi9/ubi@sha256:16e9e43d99e181463513cc84a514859b1abb9460f1c4d9e208da4b4e51cd5cc3 \
  bash -c 'mkdir -p /tmp/work && cd /tmp/work && tar -xf - && PATH=/tmp/work/bin:$PATH bash preflight.sh; echo "exit=$?"'
```

The kind lab, in order, as it was run on 2026-10-23 (the `VM` had 10,840 MiB available of 23,981 and every node was at or
below 12% memory before the install, `vanity-lab-state.txt`). First, Cilium's Ingress controller on mesh2 (it restarts
the cluster's Cilium agents: #187, search on that cluster runs without Cilium's L7 proxy for about a minute):

```bash
export KUBECONFIG=~/.kube/mongodb-mesh.config
kind-mesh-cilium/scripts/ingress-up.sh mesh2 2>&1 | tee kind-mesh-cilium/output/ingress-up-mesh2.txt
```

Then the main chart in a namespace of its own, `vanity-lab`, its five prerequisites made by the chart's script from
throwaway PEMs signed by the lab's CA (`mesh-root-ca` in `cert-manager`; the PEMs and the CA key in a 700 scratch
directory outside the repository, deleted afterwards; the sync user's password copied from the `search` namespace's
Secret). Each PEM holds the key, the leaf and the CA; the mongot certificate names `mongot-search-0-svc.vanity-lab.svc.cluster.local`,
its wildcard and the proxy Service; the server certificate names `mongot-search.vanity-lab.example` (the main chart's
`externalHostname`) and `VANITY`; the script runs with a kubeconfig copy whose current context is `kind-mesh2`:

```bash
kubectl --context kind-mesh2 create namespace vanity-lab
mkdir -m 700 vanity-lab
bash chart/mongodb-search-helm/generate-mongodbsearch-prerequisites.sh --trustca ca.crt --target-namespace vanity-lab --apply --yes
bash chart/mongodb-search-helm/generate-mongodbsearch-prerequisites.sh --mongot mongot.pem --target-namespace vanity-lab --apply --yes
bash chart/mongodb-search-helm/generate-mongodbsearch-prerequisites.sh --envoy envoy.pem --target-namespace vanity-lab --apply --yes
bash chart/mongodb-search-helm/generate-mongodbsearch-prerequisites.sh --route route.pem --hostname mongot-search.vanity-lab.example --target-namespace vanity-lab --apply --yes
bash chart/mongodb-search-helm/generate-mongodbsearch-prerequisites.sh --dbcred --username search-sync-source --password-file dbpw --target-namespace vanity-lab --apply --yes
helm install mongot chart/mongodb-search-helm -n vanity-lab --kube-context kind-mesh2 -f kind-mesh/values/vanity-lab-search.yaml --timeout 20m
```

K1, the install through Cilium's Ingress (kind assigns no uid, and both images' own user is root, so both `runAsUser`
values are set; the UBI 9 image is pulled from Red Hat's public registry), the Ingress's address, and the probe pod
(`quay.io/mongodb/mongodb-community-server:8.3.4-ubi9`, curl with HTTP/2, the client certificate's Secret and the trust
bundle mounted under `/tls`):

```bash
helm install mongot-public chart/mongot-envoy-vanity-url-helm -n vanity-lab --kube-context kind-mesh2 \
  --set vanityHostname=$VANITY --set expose.type=ingress --set expose.ingressClassName=cilium --set expose.ingressPath=/ \
  --set 'expose.annotations.ingress\.cilium\.io/tls-passthrough=enabled' --set envoy.runAsUser=101 --set jobs.runAsUser=1001
kubectl --context kind-mesh2 -n vanity-lab logs job/mongot-public-preflight
kubectl --context kind-mesh2 -n vanity-lab get pods -l 'app in (mongot-public-lb, mongot-search-lb-0)' -o wide
kubectl --context kind-mesh2 -n vanity-lab get ingress mongot-public
INGRESS=$(kubectl --context kind-mesh2 -n vanity-lab get ingress mongot-public -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
kubectl --context kind-mesh2 -n vanity-lab apply -f vanity-probe.yaml
```

The address comes from the lab's LoadBalancer block (`172.18.255.0/24`, pool `mesh-pool`); the Mac reaches it through
the route `up.sh` prints once per VM start (`kind-mesh/scripts/lib.sh`, "for the Mac to reach the clusters'
LoadBalancer addresses"), the probe pod reaches it from inside the cluster. There is no port-forward fallback: Cilium's
shared Ingress Service `cilium-ingress` has no selector, and kubectl refuses a port-forward to a Service without one.

K2, the health check by the vanity name through Cilium's Ingress, from the probe pod, with the empty gRPC frame
(5 zero bytes) and `te: trailers`:

```bash
kubectl --context kind-mesh2 -n vanity-lab exec vanity-probe -- bash -c "printf '\000\000\000\000\000' > /tmp/empty-frame; curl -sv --http2 --cacert /tls/ca/ca.crt --cert /tls/client/tls.crt --key /tls/client/tls.key --resolve $VANITY:443:$INGRESS -o /tmp/health.bin https://$VANITY:443/grpc.health.v1.Health/Check -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @/tmp/empty-frame; echo \"curl exit=\$?\"; od -An -tx1 /tmp/health.bin"
kubectl --context kind-mesh2 -n vanity-lab logs -l app=mongot-public-lb --tail=-1 | grep '"logger":"access"' | tail -3
```

K3, a wrong SNI: through the Ingress, and straight at our Service (its ClusterIP, port 27028), the stats of our pods
read before and after through the API server's pod proxy (the Envoy image has no `curl`):

```bash
for P in $(kubectl --context kind-mesh2 -n vanity-lab get pods -l app=mongot-public-lb -o name); do
  kubectl --context kind-mesh2 -n vanity-lab get --raw "/api/v1/namespaces/vanity-lab/pods/${P#pod/}:9901/proxy/stats" | grep -E '^(listener\.0\.0\.0\.0_27028\.(downstream_cx_total|ssl\.handshake|no_filter_chain_match)|http\.ingress_rs\.downstream_rq_total|cluster\.mongot_rs_cluster\.(membership_healthy|upstream_rq_total|upstream_cx_total)): '
done
kubectl --context kind-mesh2 -n vanity-lab exec vanity-probe -- curl -sv --http2 --cacert /tls/ca/ca.crt --cert /tls/client/tls.crt --key /tls/client/tls.key --resolve wrong.lab.example:443:$INGRESS https://wrong.lab.example:443/grpc.health.v1.Health/Check -H 'content-type: application/grpc' --data-binary @/tmp/empty-frame
SVC=$(kubectl --context kind-mesh2 -n vanity-lab get svc mongot-public-lb -o jsonpath='{.spec.clusterIP}')
kubectl --context kind-mesh2 -n vanity-lab exec vanity-probe -- curl -sv --http2-prior-knowledge --cacert /tls/ca/ca.crt --cert /tls/client/tls.crt --key /tls/client/tls.key --resolve wrong.lab.example:27028:$SVC https://wrong.lab.example:27028/grpc.health.v1.Health/Check -H 'content-type: application/grpc' --data-binary @/tmp/empty-frame -o /dev/null
kubectl --context kind-mesh2 -n vanity-lab logs -l app=mongot-public-lb --tail=-1 | grep -c 'wrong.lab.example'
```

K4, 30 health checks as K2, then the stats of each of our pods as in K3 and the access log's `upstream_host` counted,
12 s later (the access log flushes every 10 s):

```bash
for i in $(seq 30); do kubectl --context kind-mesh2 -n vanity-lab exec vanity-probe -- curl -s --http2 --cacert /tls/ca/ca.crt --cert /tls/client/tls.crt --key /tls/client/tls.key --resolve $VANITY:443:$INGRESS https://$VANITY:443/grpc.health.v1.Health/Check -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @/tmp/empty-frame -o /dev/null -w '%{http_code} '; done
sleep 12
kubectl --context kind-mesh2 -n vanity-lab logs -l app=mongot-public-lb --tail=-1 | grep -o '"upstream_host":"[^"]*"' | sort | uniq -c
kubectl --context kind-mesh2 -n vanity-lab get pods -l app=mongot-search-0-svc -o wide
```

K5 and K6, the preflight's refusals:

```bash
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n vanity-lab --kube-context kind-mesh2 --reuse-values --set tls.clientCertSecret=no-such-secret
kubectl --context kind-mesh2 -n vanity-lab logs job/mongot-public-preflight
kubectl --context kind-mesh2 -n vanity-lab get deploy mongot-public-lb -o jsonpath='generation {.metadata.generation}, client secret {.spec.template.spec.volumes[?(@.name=="envoy-client-cert")].secret.secretName}{"\n"}'
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n vanity-lab --kube-context kind-mesh2 --reuse-values --set vanityHostname=other.lab.example
kubectl --context kind-mesh2 -n vanity-lab logs job/mongot-public-preflight
kubectl --context kind-mesh2 -n vanity-lab get ingress mongot-public -o jsonpath='{.spec.rules[0].host}{"\n"}'
helm --kube-context kind-mesh2 -n vanity-lab history mongot-public
```

K7, the operator reconciling its own Envoy and not ours:

```bash
kubectl --context kind-mesh2 -n vanity-lab get deploy mongot-public-lb -o jsonpath='generation {.metadata.generation}, ownerReferences {.metadata.ownerReferences}{"\n"}'
kubectl --context kind-mesh2 -n vanity-lab annotate deploy/mongot-search-lb-0 test=x --overwrite
kubectl --context kind-mesh2 -n vanity-lab patch mongodbsearch mongot --type json -p '[{"op":"add","path":"/spec/clusters/0/loadBalancer/managed/replicas","value":1}]'
sleep 20
kubectl --context kind-mesh2 -n vanity-lab get deploy mongot-public-lb -o jsonpath='generation {.metadata.generation}, ownerReferences {.metadata.ownerReferences}{"\n"}'
kubectl --context kind-mesh2 -n vanity-lab get deploy mongot-search-lb-0 -o jsonpath='generation {.metadata.generation}, annotation test={.metadata.annotations.test}, ownerReferences {.metadata.ownerReferences[*].name}{"\n"}'
```

K9, the DR toggle: the Ingress removed, the K2 check failing, the Ingress back, the K2 check answering (the first
check 4 s after the Ingress returned failed at the handshake; the follow-up, a retry every 5 s, answered at once):

```bash
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n vanity-lab --kube-context kind-mesh2 --reuse-values --set expose.enabled=false
kubectl --context kind-mesh2 -n vanity-lab get ingress
kubectl --context kind-mesh2 -n vanity-lab exec vanity-probe -- curl -sv --http2 --cacert /tls/ca/ca.crt --cert /tls/client/tls.crt --key /tls/client/tls.key --resolve $VANITY:443:$INGRESS https://$VANITY:443/grpc.health.v1.Health/Check -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @/tmp/empty-frame --max-time 15 -o /tmp/health.bin
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n vanity-lab --kube-context kind-mesh2 --reuse-values --set expose.enabled=true
kubectl --context kind-mesh2 -n vanity-lab get ingress mongot-public
kubectl --context kind-mesh2 -n vanity-lab exec vanity-probe -- curl -sv --http2 --cacert /tls/ca/ca.crt --cert /tls/client/tls.crt --key /tls/client/tls.key --resolve $VANITY:443:$INGRESS https://$VANITY:443/grpc.health.v1.Health/Check -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @/tmp/empty-frame -o /tmp/health.bin
```

K10, the uninstall, then the clean-up of the main chart's release and the namespace, and the lab's own check:

```bash
kubectl --context kind-mesh2 -n vanity-lab delete pod vanity-probe
helm uninstall mongot-public -n vanity-lab --kube-context kind-mesh2
kubectl --context kind-mesh2 -n vanity-lab get deploy,svc,ingress,secret,configmap,mongodbsearch,pods
helm uninstall mongot -n vanity-lab --kube-context kind-mesh2
kubectl --context kind-mesh2 delete namespace vanity-lab --timeout=5m
kind-mesh/check.sh
```

OpenShift: the guide's steps as written, O7 being its "Prove which path the traffic takes".

## What was recorded

The CI suite's output is `kind-mesh/output/vanity-chart.txt`; each block below quotes its lines for that test. The
render of every test is the chart with `vanityHostname=mongot-public.example.com` in namespace `mongodb-poc`, the
capture's own namespace and search name, so that the bootstrap must equal the capture everywhere but `server_names`.

### C1. Lint, and the defaults refused

```bash
helm lint chart/mongot-envoy-vanity-url-helm --set vanityHostname=mongot-public.example.com
helm template x chart/mongot-envoy-vanity-url-helm -n x
```

```text
ok    helm lint
ok    the defaults alone are refused (no vanityHostname)
ok    renders with vanityHostname alone
ok    .helmignore keeps keys, certificates and pictures out of the package; the README travels with it
```

### C2. The objects by default, and C3, the names

```bash
helm template mongot-public chart/mongot-envoy-vanity-url-helm -n mongodb-poc --set vanityHostname=mongot-public.example.com | yq -N '.kind + "/" + .metadata.name'
```

```text
ok    by default: the config, the Deployment, its Service and budget, the Route and the preflight, every name from search.name
ok    search.name renames everything; expose.name names the Route
ok    expose.enabled=false: no Route and no Ingress, the Service stays
ok    preflight.enabled=false renders no Job and no RBAC
ok    the budget can be turned off
ok    no ClusterRole or ClusterRoleBinding anywhere
ok    the namespace value places every object, whatever -n says
ok    an empty namespace value falls back to -n
```

### C4. The Route, and C5, the Ingress and the reserved annotations

```bash
helm template mongot-public chart/mongot-envoy-vanity-url-helm -n mongodb-poc --set vanityHostname=mongot-public.example.com -s templates/20-route.yaml
helm template mongot-public chart/mongot-envoy-vanity-url-helm -n mongodb-poc --set vanityHostname=mongot-public.example.com --set expose.type=ingress
```

```text
ok    the Route: host vanityHostname, passthrough, no wildcard, balance roundrobin, to the chart's own Service
ok    expose.balance, annotations and labels reach the Route
ok    expose.type=ingress: an Ingress and no Route
ok    the Ingress: class openshift-default, the passthrough and balance annotations, path '' with ImplementationSpecific, no spec.tls
ok    expose.name and expose.ingressClassName reach the Ingress
ok    expose.ingressPath=/ renders path / with pathType Prefix (Cilium), the Cilium annotation passing, the host kept
ok    expose.ingressPath empty keeps path '' with ImplementationSpecific
ok    the schema refuses an expose.ingressPath other than '' or /
ok    the schema refuses an expose.type that is neither route nor ingress
ok    the schema refuses a balance the router does not know
ok    expose.annotations cannot replace the Ingress's termination, balance or sync-wave; other keys pass
ok    expose.annotations cannot replace the Route's balance, and the key is rendered once
```

### C6. The secrets, the mounts, the Service, the Deployment

```bash
helm template mongot-public chart/mongot-envoy-vanity-url-helm -n mongodb-poc --set vanityHostname=mongot-public.example.com -s templates/11-deployment.yaml
```

```text
ok    the secrets derive as the main chart's helpers (<prefix>-<name>-search-lb-0-cert, -client-cert, ent-trust-bundle) and mount where the operator's Envoy mounts them
ok    tls.certsSecretPrefix and search.name change the derived secret names
ok    tls.serverCertSecret, clientCertSecret and trustBundleConfigMap override the derived names
ok    the preflight's Role and env follow the override
ok    the Service is ClusterIP, port mongot-grpc 27028, selecting this Deployment's pods only
ok    Envoy: the quay.io image, 2 replicas, readiness on admin /ready
ok    the budget selects the Deployment's pods, maxUnavailable 1, AlwaysAllow
ok    a changed bootstrap changes the pod template (checksum/config), so the pods restart
```

### C7. The bootstrap against the operator's capture, and C8, the values in it

```bash
helm template mongot-public chart/mongot-envoy-vanity-url-helm -n mongodb-poc --set vanityHostname=mongot-public.example.com -s templates/10-envoy-config.yaml | yq -N '.data["bootstrap.yaml"]' | yq -o=json .
```

```text
bootstrap.json: 1 field(s) differ from the capture: ['.static_resources.listeners[0].filter_chains[0].filter_chain_match.server_names[0]']
bootstrap-other.json: 3 field(s) differ from the capture: ['.static_resources.clusters[0].load_assignment.endpoints[0].lb_endpoints[0].endpoint.address.socket_address.address', '.static_resources.clusters[0].transport_socket.typed_config.sni', '.static_resources.listeners[0].filter_chains[0].filter_chain_match.server_names']
ok    the bootstrap equals the operator's captured config except server_names (and, in another namespace, the endpoint and SNI)
ok    the retry, timeout and port values reach the bootstrap where the operator's values sit
```

### C9. Envoy's own validation

```bash
tar -C "$tmp/envoy" -cf - . | docker run --rm -i --user 0 --entrypoint sh quay.io/ephico2real/envoy:v1.37-latest -c \
  'tar -xf - -C /etc/envoy && chmod -R a+rX /etc/envoy && su-exec envoy envoy --mode validate -c /etc/envoy/bootstrap.yaml'
```

```text
ok    envoy --mode validate accepts the rendered bootstrap (configuration '/etc/envoy/bootstrap.yaml' OK)
ok    envoy --mode validate accepts the render for another namespace with two server names
ok    envoy --mode validate refuses a broken bootstrap
```

### C10. Requests and limits, and the uid

```bash
helm template mongot-public chart/mongot-envoy-vanity-url-helm -n mongodb-poc --set vanityHostname=mongot-public.example.com --set monitoring.serviceMonitor.enabled=true | yq -N 'select(.kind == "Job" or .kind == "Deployment") | .spec.template.spec.containers[].resources'
```

```text
ok    every container (Envoy, the preflight) requests and limits CPU and memory
ok    no runAsUser by default (OpenShift assigns one); envoy.runAsUser sets the user and group
ok    the schema refuses an Envoy memory limit that is not a Kubernetes quantity (512MB)
ok    the schema refuses Envoy resources without limits
```

### C11. The schema's refusals

```bash
helm template mongot-public chart/mongot-envoy-vanity-url-helm -n mongodb-poc --set vanityHostname=10.0.0.1
```

```text
ok    the schema refuses an uppercase vanityHostname
ok    the schema refuses a trailing dot in vanityHostname
ok    the schema refuses an uppercase server name
ok    the schema refuses a trailing dot in a server name
ok    the schema refuses an IP as vanityHostname
ok    the schema refuses a one-label vanityHostname
ok    the schema refuses an unknown top-level key
ok    the schema refuses an unknown key under envoy
ok    the schema refuses an unknown key under expose
ok    the schema refuses a serverNames entry that is an IP
ok    the schema refuses 0 Envoy replicas
ok    the schema refuses a maxUnavailable of 0 (every drain would block)
ok    the schema refuses a timeout that is not an Envoy duration
ok    the schema refuses a search.name of 44 characters
ok    the schema refuses a mongot.port above 65535
ok    the schema refuses an invalid namespace
ok    the schema refuses a server name given twice (Envoy refuses overlapping filter chains)
ok    a serverNames list without vanityHostname is refused, by name
```

### C12. The monitoring objects

```bash
helm template mongot-public chart/mongot-envoy-vanity-url-helm -n mongodb-poc --set vanityHostname=mongot-public.example.com --set monitoring.serviceMonitor.enabled=true -s templates/30-monitoring.yaml
```

```text
ok    no stats Service and no ServiceMonitor by default
ok    the stats Service is ClusterIP 9901 on this Deployment's pods
ok    the ServiceMonitor scrapes /stats/prometheus on admin with the main chart's _total relabel, and selects only this chart's stats Service
ok    the stats Service does not carry mongodb.com/search-name, so the main chart's monitor does not adopt it
ok    never a Route to the admin port
```

### C13. The preflight's script against the stand-in API, and C14, its lint

```bash
helm template mongot-public chart/mongot-envoy-vanity-url-helm -n mongodb-poc --set vanityHostname=mongot-public.example.com -s templates/00-preflight.yaml
```

```text
ok    bash -n preflight
ok    shellcheck preflight
ok    preflight: everything present and the certificate naming the hostname passes
ok    the preflight prints names and keys' names, never a certificate, a key or the token
ok    preflight: its 4 GETs each bounded, the connect timeout within --max-time, together inside the Job's 180 s deadline
ok    preflight: a one-label wildcard SAN covers x.apps.example.com
ok    preflight: a wildcard covers one label only; a.b.apps.example.com is refused
ok    preflight: a certificate without the name is refused, the message naming the SANs it has
ok    preflight: a missing server secret is refused by name with the API's reason, and its certificate is not then checked
ok    preflight: a missing client secret, trust bundle and mongot Service are each named, and counted
ok    preflight: a Forbidden reads as one, not as missing
ok    preflight: an API server that does not answer is reported with curl's error, for each object
ok    preflight: an API server its CA does not verify is refused with curl's first line, the error's name
ok    preflight: a secret without tls.key is refused
ok    preflight: a certificate with the hostname as CN and no SAN is refused
ok    preflight: a client secret without tls.crt is refused
ok    preflight: a trust bundle without ca.crt is refused
ok    preflight: a server secret without tls.key is refused
ok    preflight: an image without curl is refused, naming the image and the tool
ok    preflight: an image without python3 is refused, naming the image and the tool
ok    preflight: an image without openssl is refused, naming the image and the tool
ok    preflight: without a ServiceAccount token it refuses, never guesses
ok    preflight: a ServiceAccount directory without the API server's CA is refused, by name
ok    preflight: an HTTP 500 with a non-JSON body is reported as HTTP 500, for each object, with no traceback
```

### C15. The documents

```bash
grep -c 'rollout restart' chart/mongot-envoy-vanity-url-helm/templates/NOTES.txt chart/mongot-envoy-vanity-url-helm/README.md
```

```text
ok    NOTES and the README say to restart the pods after a certificate rotation
ok    the main README and the main chart's README link the chart and its document
```

### P1. The preflight's script in its image

```bash
tar -cf - . | docker run --rm -i --user 1001 -e CLUSTER=/tmp/work/cluster -e SA_DIR=/tmp/work/sa -e NAMESPACE=mongodb-poc \
  -e SERVER_SECRET=ent-mongot-search-lb-0-cert -e CLIENT_SECRET=ent-mongot-search-lb-0-client-cert -e TRUST_CM=ent-trust-bundle \
  -e MONGOT_SERVICE=mongot-search-0-svc -e JOB_IMAGE=ubi9 -e SERVER_NAMES="mongot-public.example.com x.apps.example.com" \
  registry.access.redhat.com/ubi9/ubi@sha256:16e9e43d99e181463513cc84a514859b1abb9460f1c4d9e208da4b4e51cd5cc3 \
  bash -c 'mkdir -p /tmp/work && cd /tmp/work && tar -xf - && PATH=/tmp/work/bin:$PATH bash preflight.sh; echo "exit=$?"; echo "uid=$(id -u)"'
```

```text
[preflight 02:03:52] checking what Envoy for mongot-public.example.com x.apps.example.com mounts and dials in mongodb-poc
[preflight 02:03:52] ok: secret ent-mongot-search-lb-0-client-cert (tls.crt tls.key)
[preflight 02:03:52] ok: configmap ent-trust-bundle (ca.crt)
[preflight 02:03:52] ok: service mongot-search-0-svc (the mongot pods Envoy dials)
[preflight 02:03:52] ok: secret ent-mongot-search-lb-0-cert (tls.crt tls.key)
[preflight 02:03:52] secret ent-mongot-search-lb-0-cert names: mongot-public.example.com *.apps.example.com
[preflight 02:03:52] ok: mongot-public.example.com is a name of the certificate in ent-mongot-search-lb-0-cert
[preflight 02:03:52] ok: x.apps.example.com is a name of the certificate in ent-mongot-search-lb-0-cert
[preflight 02:03:52] everything Envoy mounts and dials is present, and the certificate names every server name
exit=0
uid=1001
```

With `SERVER_NAMES=other.example.com`:

```text
[preflight] MISSING: secret ent-mongot-search-lb-0-cert: its certificate does not name other.example.com (SANs: mongot-public.example.com *.apps.example.com); every client would refuse it. Issue a certificate with that name, or set vanityHostname to one it has
[preflight] FAILED: 1 problem(s). The secrets and the trust bundle are the main chart's (its generate-mongodbsearch-prerequisites.sh makes them); nothing was installed.
exit=1
```

### L0. The lab before, and Cilium's Ingress controller on mesh2

```bash
kind-mesh-cilium/scripts/ingress-up.sh mesh2 2>&1 | tee kind-mesh-cilium/output/ingress-up-mesh2.txt
```

From `vanity-lab-state.txt` and `kind-mesh-cilium/output/ingress-up-mesh2.txt` (the first run, `ingress-up-mesh2.run1-no-restart.txt`,
showed the upgrade alone left the agents' pods as they were; the script then gained the restart):

```text
mesh2-control-plane   137m         1%       2968Mi          12%
mesh2-worker          61m          0%       1801Mi          7%
mongot-mongodb-search-helm targets ["search"]
installModes OwnNamespace=true SingleNamespace=true MultiNamespace=false AllNamespaces=true
  start 2026-10-23T03:17:50Z
  helm done 2026-10-23T03:17:51Z
deployment "cilium-operator" successfully rolled out
daemon set "cilium" successfully rolled out
  agents rolled 2026-10-23T03:18:04Z
  cilium healthy 2026-10-23T03:19:02Z
  keys that differ: none
  ingressController: {"default": false, "enabled": true, "loadbalancerMode": "shared"}
cilium   cilium.io/ingress-controller   <none>       2m21s
cilium-ingress   LoadBalancer   10.31.129.141   172.18.255.72   80:31058/TCP,443:31603/TCP   2m21s
```

### L1. The main chart in vanity-lab

```bash
helm install mongot chart/mongodb-search-helm -n vanity-lab --kube-context kind-mesh2 -f kind-mesh/values/vanity-lab-search.yaml --timeout 20m
```

From `vanity-lab-prerequisites.txt` and `vanity-lab-main-chart.txt`:

```text
ent-trust-bundle (ConfigMap, key ca.crt) for vanity-lab: 1 CA certificate(s)
  CN=mongodb-mesh-root-ca  (expires Oct 18 23:43:36 2036 GMT)
ent-mongot-search-lb-0-cert (Secret, kubernetes.io/tls) for vanity-lab
  subject   CN=mongot-search.vanity-lab.example
  names     mongot-search.vanity-lab.example mongot-public.lab.example
search-sync-source-password (Secret, key password) for vanity-lab: 48 bytes, for search-sync-source
exit=0 at 2026-10-23T03:19:29Z
mongodbsearch.mongodb.com/mongot   Running   1.70.1    Running        Running            2m6s
pod/mongot-search-0-0                              1/1     Running     0          112s
pod/mongot-search-0-1                              1/1     Running     0          85s
pod/mongot-search-lb-0-6fd8d5568d-gvgzp            1/1     Running     0          112s
```

### K1. The chart installs beside the main chart, through Cilium's Ingress

```bash
helm install mongot-public chart/mongot-envoy-vanity-url-helm -n vanity-lab --kube-context kind-mesh2 --set vanityHostname=mongot-public.lab.example --set expose.type=ingress --set expose.ingressClassName=cilium --set expose.ingressPath=/ --set 'expose.annotations.ingress\.cilium\.io/tls-passthrough=enabled' --set envoy.runAsUser=101 --set jobs.runAsUser=1001
```

From `vanity-install.txt`:

```text
exit=0
[preflight 03:21:15] secret ent-mongot-search-lb-0-cert names: mongot-search.vanity-lab.example mongot-public.lab.example
[preflight 03:21:15] ok: mongot-public.lab.example is a name of the certificate in ent-mongot-search-lb-0-cert
[preflight 03:21:15] everything Envoy mounts and dials is present, and the certificate names every server name
mongot-public-lb-7886bc55b4-v5cqd     1/1     Running   0          11s     10.30.1.173   mesh2-worker          <none>           <none>
mongot-public-lb-7886bc55b4-xzjrg     1/1     Running   0          11s     10.30.0.158   mesh2-control-plane   <none>           <none>
mongot-search-lb-0-6fd8d5568d-gvgzp   1/1     Running   0          3m52s   10.30.1.68    mesh2-worker          <none>           <none>
cilium enabled mongot-public.lab.example / Prefix 172.18.255.72
```

### K2. A gRPC health check by the vanity name through Cilium's Ingress

```bash
kubectl --context kind-mesh2 -n vanity-lab exec vanity-probe -- bash -c "curl -sv --http2 --cacert /tls/ca/ca.crt --cert /tls/client/tls.crt --key /tls/client/tls.key --resolve mongot-public.lab.example:443:172.18.255.72 -o /tmp/health.bin https://mongot-public.lab.example:443/grpc.health.v1.Health/Check -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @/tmp/empty-frame; echo \"curl exit=\$?\"; od -An -tx1 /tmp/health.bin"
```

From `vanity-reach.txt`:

```text
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* ALPN, server accepted to use h2
*  subject: CN=mongot-search.vanity-lab.example
< HTTP/2 200 
< grpc-status: 0
curl exit=0
 00 00 00 00 02 08 01
{"bytes_in":5,"bytes_out":7,"client_id":null,"duration_ms":80,"grpc_status":"OK","level":"info","logger":"access","message":"stream upstream=10.30.0.118:27028 path=/grpc.health.v1.Health/Check resp=200 grpc=OK flags=- dur=80ms","path":"/grpc.health.v1.Health/Check","response_code":200,"response_flags":"-","time":"2026-10-23T03:21:49.418+00:00","upstream_host":"10.30.0.118:27028"}
```

### K3. A wrong SNI refused

```bash
kubectl --context kind-mesh2 -n vanity-lab exec vanity-probe -- curl -sv --http2 --cacert /tls/ca/ca.crt --cert /tls/client/tls.crt --key /tls/client/tls.key --resolve wrong.lab.example:443:172.18.255.72 https://wrong.lab.example:443/grpc.health.v1.Health/Check -H 'content-type: application/grpc' --data-binary @/tmp/empty-frame
```

From `vanity-wrong-sni.txt` (the stats before, the two refusals, the stats after):

```text
listener.0.0.0.0_27028.downstream_cx_total: 1
listener.0.0.0.0_27028.no_filter_chain_match: 0
listener.0.0.0.0_27028.downstream_cx_total: 0
listener.0.0.0.0_27028.no_filter_chain_match: 1
== 2026-10-23T03:22:13Z a wrong SNI through the Ingress: wrong.lab.example at 172.18.255.72
* OpenSSL SSL_connect: Connection reset by peer in connection to wrong.lab.example:443 
curl exit=35
== 2026-10-23T03:22:13Z a wrong SNI straight at our Service, from the probe pod (the ClusterIP of mongot-public-lb:27028)
* OpenSSL SSL_connect: Connection reset by peer in connection to wrong.lab.example:27028 
curl exit=35
listener.0.0.0.0_27028.downstream_cx_total: 1
listener.0.0.0.0_27028.no_filter_chain_match: 0
listener.0.0.0.0_27028.downstream_cx_total: 0
listener.0.0.0.0_27028.no_filter_chain_match: 2
== 2026-10-23T03:22:13Z access-log lines mentioning wrong.lab.example
0
```

### K4. The spread over the mongot pods

```bash
kubectl --context kind-mesh2 -n vanity-lab logs -l app=mongot-public-lb --tail=-1 | grep -o '"upstream_host":"[^"]*"' | sort | uniq -c
```

From `vanity-spread.txt`:

```text
--- mongot-public-lb-7886bc55b4-v5cqd
cluster.mongot_rs_cluster.membership_healthy: 2
cluster.mongot_rs_cluster.upstream_rq_total: 14
listener.0.0.0.0_27028.downstream_cx_total: 14
--- mongot-public-lb-7886bc55b4-xzjrg
cluster.mongot_rs_cluster.membership_healthy: 2
cluster.mongot_rs_cluster.upstream_rq_total: 17
listener.0.0.0.0_27028.downstream_cx_total: 17
  16 "upstream_host":"10.30.0.118:27028"
  15 "upstream_host":"10.30.1.137:27028"
mongot-search-0-0   1/1     Running   0          5m10s   10.30.1.137   mesh2-worker          <none>           <none>
mongot-search-0-1   1/1     Running   0          4m43s   10.30.0.118   mesh2-control-plane   <none>           <none>
```

### K5. The preflight refuses a missing secret, and K6, a certificate without the name

```bash
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n vanity-lab --kube-context kind-mesh2 --reuse-values --set tls.clientCertSecret=no-such-secret
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n vanity-lab --kube-context kind-mesh2 --reuse-values --set vanityHostname=other.lab.example
```

From `vanity-preflight-missing.txt` and `vanity-preflight-name.txt` (the history line's tabs as spaces):

```text
[preflight] MISSING: secret no-such-secret: NotFound secrets "no-such-secret" not found
[preflight] FAILED: 1 problem(s). The secrets and the trust bundle are the main chart's (its generate-mongodbsearch-prerequisites.sh makes them); nothing was installed.
generation 1, client secret ent-mongot-search-lb-0-client-cert
2         Thu Oct 22 22:22:47 2026  failed    mongot-envoy-vanity-url-helm-0.1.0  1.37         Upgrade "mongot-public" failed: pre-upgrade hooks failed: resource Job/vanity-lab/mongot-public-preflight not ready. status: Failed, message: Job Failed. failed: 1/1
[preflight] MISSING: secret ent-mongot-search-lb-0-cert: its certificate does not name other.lab.example (SANs: mongot-search.vanity-lab.example mongot-public.lab.example); every client would refuse it. Issue a certificate with that name, or set vanityHostname to one it has
mongot-public.lab.example
```

### K7. The operator reconciles its own Envoy and not ours

```bash
kubectl --context kind-mesh2 -n vanity-lab patch mongodbsearch mongot --type json -p '[{"op":"add","path":"/spec/clusters/0/loadBalancer/managed/replicas","value":1}]'
```

From `vanity-reconcile.txt`:

```text
== 2026-10-23T03:22:54Z K7: our Deployment before
generation 1, ownerReferences 
deployment.apps/mongot-search-lb-0 annotated
mongodbsearch.mongodb.com/mongot patched (no change)
== 2026-10-23T03:23:14Z our Deployment after
generation 1, ownerReferences 
== 2026-10-23T03:23:14Z the operator's Deployment
generation 2, annotation test=x, ownerReferences mongot
```

### K9. DR toggle: traffic through the vanity hostname

```bash
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n vanity-lab --kube-context kind-mesh2 --reuse-values --set expose.enabled=false
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n vanity-lab --kube-context kind-mesh2 --reuse-values --set expose.enabled=true
```

From `vanity-dr-toggle.txt` (the last line's carriage returns, curl's, dropped here):

```text
== 2026-10-23T03:24:12Z the Ingress
No resources found in vanity-lab namespace.
== 2026-10-23T03:24:17Z the health check at 172.18.255.72, by the vanity name
* Immediate connect fail for 172.18.255.72: No route to host
curl exit=7
== 2026-10-23T03:24:21Z the Ingress
mongot-public   cilium   mongot-public.lab.example   172.18.255.72   80      0s
== 2026-10-23T03:24:21Z the health check again
curl exit=35
03:26:37Z try 1: < HTTP/2 200  < grpc-status: 0 curl exit=0  00 00 00 00 02 08 01
```

### K10. Uninstall leaves the main chart's objects

```bash
helm uninstall mongot-public -n vanity-lab --kube-context kind-mesh2
```

From `vanity-uninstall.txt` and `vanity-lab-cleanup.txt`:

```text
release "mongot-public" uninstalled
deployment.apps/mongodb-kubernetes-operator   1/1     1            1           9m52s
deployment.apps/mongot-search-lb-0            1/1     1            1           9m51s
service/mongot-search-0-proxy-svc             ClusterIP   10.31.159.91   <none>        27028/TCP                     9m51s
service/mongot-search-0-svc                   ClusterIP   None           <none>        27028/TCP,9946/TCP,8080/TCP   9m51s
mongodbsearch.mongodb.com/mongot   Running   1.70.1    Running        Running            10m
pod/mongot-public-lb-7886bc55b4-v5cqd             1/1     Terminating   0          6m10s
release "mongot" uninstalled
03:28:17Z mongodbsearch,pvc left: 0
namespace "vanity-lab" deleted
cilium-ingress   LoadBalancer   10.31.129.141   172.18.255.72   80:31058/TCP,443:31603/TCP   13m
```

## Checks

The suite's last line and the counts on 2026-10-22, from `kind-mesh/output/vanity-chart.txt`:

```text
all vanity chart tests passed
exit=0
ok lines: 90
```

The main chart's suite: `all chart tests passed`, 233 ok, exit 0. The lab chart's suite: `== 0 failed`, 19 PASS,
exit 0. The negative control of C9, `CONTAINER_ENGINE=nosuchengine`: `1 failed`, exit 1.

## What is deliberately not here

- The owner's OpenShift run (O1 to O7): pending, its commands and pass conditions above; nothing of its results is
  written before it runs.
- K8, the ServiceMonitor with Prometheus: not run, the lab has no Prometheus (`observability` holds Grafana, Loki and
  the Hubble observer). Its screenshots are the main chart's dashboard (`files/mongodb-search.json`), with #191 on kind
  or on the owner's OpenShift run, not the lab's Hubble flows dashboard: the observer collects only `mongodb` and
  `search`.
- The kind run reached the vanity name from a probe pod inside the cluster, through the Ingress's LoadBalancer address;
  not from the Mac (the route `up.sh` prints was not added on this machine).
- A certificate rotation under traffic: the chart's answer is a rollout restart (the README), as for the operator's
  Envoy; not timed here.
- More than one name in `serverNames` on a cluster: rendered and validated by Envoy (C7, C9), not dialled.
- A router timeout annotation on an Ingress reaching the generated Route: not documented by Red Hat, not set, not
  tested.
- `ose-cli` as an override `jobs.image`: not measured (it needs a login); OKD's `origin-cli` 4.17 was, and has `curl`,
  `python3` and `openssl`.

## Open

- #198: the owner's OpenShift run (O1 to O7); the figure keeps the OpenShift Route and the `openshift-default` Ingress
  dashed until it passes.

## Clean up

On the lab, K10 above removes the release, then the main chart's release and the namespace `vanity-lab` go too
(`vanity-lab-cleanup.txt`); Cilium's Ingress controller stays on mesh2, now part of the lab (step 17 of
[building-the-kind-mesh-lab.md](building-the-kind-mesh-lab.md)). The CI suite leaves nothing behind (its temporary
directory is removed on exit).
