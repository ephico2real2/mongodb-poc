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
| Kind lab | K1 to K10 below | *(run pending)* |
| OpenShift, by the owner | O1 to O6 below | *(run pending)* |

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

Kind lab, on `kind-mesh/` (one cluster is enough, `mesh0`): the main chart installed by `kind-mesh/scripts/search-up.sh`
in namespace `search` with mutual TLS from the lab's cert-manager root (`kind-mesh/manifests/20-search-certificates.yaml`);
this chart with `expose.type=ingress` through Cilium's own Ingress controller (class `cilium`, `expose.ingressPath=/`,
the annotation `ingress.cilium.io/tls-passthrough: enabled`), which the lab step enables (Cilium's Helm value
`ingressController.enabled=true`; measured on 2026-10-22: mesh0 to mesh2 have no IngressClass, and `cilium-config`
has `kube-proxy-replacement=true`, `enable-l7-proxy=true` and no `enable-ingress-controller`). No OpenShift Route
on kind. `VANITY=mongot-public.lab.example`; `INGRESS` is the Ingress's address; the commands are under "Run it":

| # | What | Passes when | Result |
| --- | --- | --- | --- |
| K1 | The chart installs beside the main chart, through Cilium's Ingress | the preflight Job succeeds (its log ends with `the certificate names every server name`); 2 pods `1/1 Running` with `app=mongot-public-lb`; Ingress `mongot-public` of class `cilium` with an address; the operator's `mongot-search-lb-0` pods untouched (same age) | *(run pending)* — `vanity-install.txt` |
| K2 | A gRPC health check by the vanity name through Cilium's Ingress | with `$VANITY` as SNI at `$INGRESS:443`: TLSv1.3, ALPN h2, our server certificate's SANs holding `$VANITY`, and `grpc-status: 0` with the 7-byte body `00 00 00 00 02 08 01` (a gRPC frame holding HealthCheckResponse status 1, SERVING; curl prints the bytes, not the word); one access-log line in our pods with an `upstream_host` that is a mongot pod (its downstream address is Cilium's Envoy, as Cilium's docs say) | *(run pending)* — `vanity-reach.txt` |
| K3 | A wrong SNI refused | through the Ingress, `wrong.lab.example` gets no certificate and the handshake fails before our Envoy (its `downstream_cx_total` unchanged, no access-log line: Cilium's passthrough has no rule for the name); straight at our Service through a port-forward, the handshake closes with no certificate and our listener's `no_filter_chain_match` goes up by one | *(run pending)* — `vanity-wrong-sni.txt` |
| K4 | The spread over the mongot pods | `membership_healthy: 2` (the lab's two mongot); 30 requests through the Ingress reach both pods, the counts recorded (round robin per Envoy pod gives about half each; retries and a pod change move it) | *(run pending)* — `vanity-spread.txt`; screenshot `vanity-envoy-stats.png` |
| K5 | The preflight refuses a missing secret | helm fails on the hook; the log says `MISSING: secret no-such-secret: NotFound secrets "no-such-secret" not found` and `FAILED: 1 problem`; the Deployment is unchanged | *(run pending)* — `vanity-preflight-missing.txt` |
| K6 | The preflight refuses a certificate without the name | the log says `its certificate does not name other.lab.example (SANs: …)`; nothing changed | *(run pending)* — `vanity-preflight-name.txt` |
| K7 | The operator reconciles its own Envoy and not ours | our Deployment's generation unchanged and no ownerReference after a no-op reconcile of the MongoDBSearch; the operator's Deployment still its own | *(run pending)* — `vanity-reconcile.txt` |
| K8 | The ServiceMonitor with #191's Prometheus (if up) | the two Envoy pods scraped; `envoy_cluster_upstream_rq_total{envoy_cluster_name="mongot_rs_cluster"}` per pod | *(run pending, optional)* — screenshots `vanity-grafana-envoy.light.png`, `.dark.png` |
| K9 | DR toggle: traffic through the vanity hostname | with `expose.enabled=false` the Ingress `mongot-public` is gone and the K2 check at `$INGRESS` fails (the connection refused, or the handshake closed with no certificate); with `true` the Ingress returns with its address and the K2 check answers `SERVING` again | *(run pending)* — `vanity-dr-toggle.txt` |
| K10 | Uninstall leaves the main chart's objects | everything named `mongot-public…` gone, the Ingress included; `mongot-search-lb-0`, `mongot-search-0-svc`, the three secrets, `ent-trust-bundle` and the MongoDBSearch as before; a search through the operator's Envoy still answers | *(run pending)* — `vanity-uninstall.txt` |

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
| `kind-mesh/output/vanity-install.txt` … `vanity-uninstall.txt` | the kind lab's outputs, one per K row *(to be written by the run)* |
| `docs/screenshots/vanity-*.png` | the lab's and the owner's screenshots, named in the rows above *(to be taken)* |

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

The kind lab, in order. Before K1, two things the lab step does (not this page's commands): Cilium's Ingress controller
is enabled (its Helm value `ingressController.enabled=true` in the lab's Cilium values, which creates the IngressClass
`cilium`), and the lab's server certificate is reissued with `VANITY` added to the `dnsNames` of
`ent-mongot-search-lb-0-cert` in `kind-mesh/manifests/20-search-certificates.yaml` (cert-manager reissues on the
change), the operator's Envoy restarted to read it. This chart's preflight needs no `oc` image (it runs Red Hat's
public UBI 9, by digest, and reads the API server with `curl`); the lab's own `oc` image stays as it is:

K1, K7 and K10 need the main chart with the operator's Envoy (`loadBalancer.managed`). Measured on 2026-10-22, mesh0
runs the lab chart instead: release `mongot-search` of `mongodb-search-cilium-0.1.0`, `loadBalancer.unmanaged` with
endpoint `mongot-global.search.svc.cluster.local:27028`, no Deployment `mongot-search-lb-0`, and neither `-lb-0`
secret. The first three commands below show which one is installed; the run starts only when they show the main
chart, `managed` and the Deployment:

```bash
export KUBECONFIG=~/.kube/mongodb-mesh.config VANITY=mongot-public.lab.example
helm --kube-context kind-mesh0 -n search list
kubectl --context kind-mesh0 -n search get mongodbsearch mongot -o jsonpath='{.spec.clusters[0].loadBalancer}{"\n"}'
kubectl --context kind-mesh0 -n search get deploy mongot-search-lb-0
kubectl --context kind-mesh0 get ingressclass
kubectl --context kind-mesh0 -n search apply -f kind-mesh/manifests/20-search-certificates.yaml
kubectl --context kind-mesh0 -n search rollout restart deploy/mongot-search-lb-0
```

K1, the install through Cilium's Ingress (kind assigns no uid, and both images' own user is root, so both `runAsUser`
values are set; the UBI 9 image is pulled from Red Hat's public registry), then the Ingress's address:

```bash
helm install mongot-public chart/mongot-envoy-vanity-url-helm -n search --kube-context kind-mesh0 \
  --set vanityHostname=$VANITY --set expose.type=ingress --set expose.ingressClassName=cilium --set expose.ingressPath=/ \
  --set 'expose.annotations.ingress\.cilium\.io/tls-passthrough=enabled' --set envoy.runAsUser=101 --set jobs.runAsUser=1001 \
  | tee kind-mesh/output/vanity-install.txt
kubectl --context kind-mesh0 -n search logs job/mongot-public-preflight | tee -a kind-mesh/output/vanity-install.txt
kubectl --context kind-mesh0 -n search get pods -l 'app in (mongot-public-lb, mongot-search-lb-0)' | tee -a kind-mesh/output/vanity-install.txt
kubectl --context kind-mesh0 -n search get ingress mongot-public | tee -a kind-mesh/output/vanity-install.txt
INGRESS=$(kubectl --context kind-mesh0 -n search get ingress mongot-public -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

The address comes from the lab's LoadBalancer block (`172.18.255.0/24`, pool `mesh-pool`); the Mac reaches it through
the route `up.sh` prints once per VM start (`kind-mesh/scripts/lib.sh`, "for the Mac to reach the clusters'
LoadBalancer addresses"). There is no port-forward fallback: Cilium's shared Ingress Service `cilium-ingress` has no
selector (its EndpointSlice is a placeholder, `192.192.192.192`), and kubectl refuses a port-forward to a Service
without one (`error: cannot attach to *v1.Service: invalid service '…': Service is defined without a selector`).

K2, the health check by the vanity name through Cilium's Ingress, from the host, with the lab root as `ca.crt`, the
client certificate and key of `ent-mongot-search-lb-0-client-cert` written to `client.crt` and `client.key` (never
printed), and the empty gRPC frame:

```bash
printf '\000\000\000\000\000' > empty-frame
curl -sv --http2 --cacert ca.crt --cert client.crt --key client.key --resolve $VANITY:443:$INGRESS -o health.bin \
  https://$VANITY:443/grpc.health.v1.Health/Check -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @empty-frame 2>&1 | tee kind-mesh/output/vanity-reach.txt
od -An -tx1 health.bin | tee -a kind-mesh/output/vanity-reach.txt
```

K3, a wrong SNI: through the Ingress, and straight at our Service through a port-forward:

```bash
curl -sv --http2 --cacert ca.crt --cert client.crt --key client.key --resolve wrong.lab.example:443:$INGRESS \
  https://wrong.lab.example:443/grpc.health.v1.Health/Check -H 'content-type: application/grpc' --data-binary @empty-frame 2>&1 | tee kind-mesh/output/vanity-wrong-sni.txt
kubectl --context kind-mesh0 -n search port-forward svc/mongot-public-lb 27028:27028 &
curl -sv --http2-prior-knowledge --cacert ca.crt --cert client.crt --key client.key --resolve wrong.lab.example:27028:127.0.0.1 \
  https://wrong.lab.example:27028/grpc.health.v1.Health/Check -H 'content-type: application/grpc' --data-binary @empty-frame 2>&1 | tee -a kind-mesh/output/vanity-wrong-sni.txt
```

K4, 30 health checks as K2, then the stats of each of our pods through the API server's pod proxy (the image has no
`curl`) and the access log's `upstream_host` counted:

```bash
for i in $(seq 30); do curl -s --http2 --cacert ca.crt --cert client.crt --key client.key --resolve $VANITY:443:$INGRESS https://$VANITY:443/grpc.health.v1.Health/Check -H 'content-type: application/grpc' --data-binary @empty-frame -o /dev/null; done
for P in $(kubectl --context kind-mesh0 -n search get pods -l app=mongot-public-lb -o name); do
  kubectl --context kind-mesh0 -n search get --raw "/api/v1/namespaces/search/pods/${P#pod/}:9901/proxy/stats" | grep -E '^(listener\.0\.0\.0\.0_27028\.(downstream_cx_total|no_filter_chain_match)|cluster\.mongot_rs_cluster\.(membership_healthy|upstream_rq_total|upstream_cx_total))'
done | tee kind-mesh/output/vanity-spread.txt
kubectl --context kind-mesh0 -n search logs -l app=mongot-public-lb --tail=-1 | grep -o '"upstream_host":"[^"]*"' | sort | uniq -c | tee -a kind-mesh/output/vanity-spread.txt
```

K5 and K6, the preflight's refusals:

```bash
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n search --kube-context kind-mesh0 --reuse-values --set tls.clientCertSecret=no-such-secret 2>&1 | tee kind-mesh/output/vanity-preflight-missing.txt
kubectl --context kind-mesh0 -n search logs job/mongot-public-preflight | tee -a kind-mesh/output/vanity-preflight-missing.txt
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n search --kube-context kind-mesh0 --reuse-values --set vanityHostname=other.lab.example 2>&1 | tee kind-mesh/output/vanity-preflight-name.txt
kubectl --context kind-mesh0 -n search logs job/mongot-public-preflight | tee -a kind-mesh/output/vanity-preflight-name.txt
```

K7, the operator reconciling its own Envoy and not ours:

```bash
kubectl --context kind-mesh0 -n search get deploy mongot-public-lb -o jsonpath='{.metadata.generation} {.metadata.ownerReferences}{"\n"}' | tee kind-mesh/output/vanity-reconcile.txt
kubectl --context kind-mesh0 -n search annotate deploy/mongot-search-lb-0 test=x
kubectl --context kind-mesh0 -n search patch mongodbsearch mongot --type json -p '[{"op":"add","path":"/spec/clusters/0/loadBalancer/managed/replicas","value":1}]'
kubectl --context kind-mesh0 -n search get deploy mongot-public-lb -o jsonpath='{.metadata.generation} {.metadata.ownerReferences}{"\n"}' | tee -a kind-mesh/output/vanity-reconcile.txt
```

K8, optional, with #191's Prometheus:

```bash
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n search --kube-context kind-mesh0 --reuse-values --set monitoring.serviceMonitor.enabled=true
```

K9, the DR toggle: the Ingress removed, the K2 check failing, the Ingress back, the K2 check answering:

```bash
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n search --kube-context kind-mesh0 --reuse-values --set expose.enabled=false 2>&1 | tee kind-mesh/output/vanity-dr-toggle.txt
kubectl --context kind-mesh0 -n search get ingress 2>&1 | tee -a kind-mesh/output/vanity-dr-toggle.txt
curl -sv --http2 --cacert ca.crt --cert client.crt --key client.key --resolve $VANITY:443:$INGRESS https://$VANITY:443/grpc.health.v1.Health/Check -H 'content-type: application/grpc' --data-binary @empty-frame 2>&1 | tee -a kind-mesh/output/vanity-dr-toggle.txt
helm upgrade mongot-public chart/mongot-envoy-vanity-url-helm -n search --kube-context kind-mesh0 --reuse-values --set expose.enabled=true 2>&1 | tee -a kind-mesh/output/vanity-dr-toggle.txt
kubectl --context kind-mesh0 -n search get ingress mongot-public 2>&1 | tee -a kind-mesh/output/vanity-dr-toggle.txt
curl -sv --http2 --cacert ca.crt --cert client.crt --key client.key --resolve $VANITY:443:$INGRESS https://$VANITY:443/grpc.health.v1.Health/Check -H 'content-type: application/grpc' --data-binary @empty-frame 2>&1 | tee -a kind-mesh/output/vanity-dr-toggle.txt
```

K10, the uninstall:

```bash
helm uninstall mongot-public -n search --kube-context kind-mesh0 | tee kind-mesh/output/vanity-uninstall.txt
kubectl --context kind-mesh0 -n search get deploy,svc,ingress,secret,configmap,mongodbsearch | tee -a kind-mesh/output/vanity-uninstall.txt
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

- The kind lab run (K1 to K10) and the owner's OpenShift run (O1 to O7): pending, their commands and pass conditions
  above; nothing of their results is written before they run.
- A certificate rotation under traffic: the chart's answer is a rollout restart (the README), as for the operator's
  Envoy; not timed here.
- More than one name in `serverNames` on a cluster: rendered and validated by Envoy (C7, C9), not dialled.
- A router timeout annotation on an Ingress reaching the generated Route: not documented by Red Hat, not set, not
  tested.
- `ose-cli` as an override `jobs.image`: not measured (it needs a login); OKD's `origin-cli` 4.17 was, and has `curl`,
  `python3` and `openssl`.

## Open

- #198: the kind lab run and the owner's OpenShift run; the figure is drawn dashed (proposed) until they pass.

## Clean up

On the lab, K10 above removes the release; the main chart's objects stay. The CI suite leaves nothing behind (its
temporary directory is removed on exit).
