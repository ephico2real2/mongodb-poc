# Testing: a second Envoy for a vanity hostname, `chart/mongot-envoy-vanity-url-helm` (story #198)

What was tested of the chart, where, and how to repeat it: offline in CI (`test/vanity-chart.sh`), on the kind lab
beside the main chart with mutual TLS, and on OpenShift by the owner. The design is in
[mongot-envoy-vanity-url.md](mongot-envoy-vanity-url.md); the chart's page is its
[README](../chart/mongot-envoy-vanity-url-helm/README.md). Each row: what, the command, when it passes, and the
result with its output file. A row marked *(run pending)* has not been run yet: its command and pass condition are
written so that the run fills the result and nothing else.

## Summary

| Where | Tests | State |
| --- | --- | --- |
| CI, offline (`test/vanity-chart.sh`) | 64 assertions: lint, the renders, the schema's refusals, the bootstrap against the operator's capture, `envoy --mode validate`, the preflight's script | **64 passed, 0 failed** on 2026-10-22 (macOS, helm v4.3.0, Envoy 1.37.6 from the chart's image) |
| CI, the main chart (`test/chart.sh`) | 233 assertions, unchanged by this story | 233 passed, 0 failed on the same day |
| Kind lab | K1 to K9 below | *(run pending)* |
| OpenShift, by the owner | O1 to O6 below | *(run pending)* |

## CI, offline

Run from the repository's root: `CONTAINER_ENGINE=docker test/vanity-chart.sh`. The run of 2026-10-22 is in
`kind-mesh/output/vanity-chart.txt` *(copied into the repository with the lab run; until then the output below is the
record)*. Every assertion prints `ok` or `FAIL`; the script exits 1 on any `FAIL`.

| # | What | Command | Passes when | Result |
| --- | --- | --- | --- | --- |
| C1 | Lint, and the defaults refused | `helm lint chart/mongot-envoy-vanity-url-helm --set publicHostname=…`; `helm template x chart/mongot-envoy-vanity-url-helm -n x` | lint passes; the second fails on the schema (`publicHostname` is required) | Passed: `ok helm lint`, `ok the defaults alone are refused (no publicHostname)` |
| C2 | The objects by default | `helm template … --set publicHostname=mongot-public.example.com` | ConfigMap `mongot-public-envoy`, Deployment, Service and PodDisruptionBudget `mongot-public-lb`, Route `mongot-public`, the preflight Job with its ServiceAccount, Role and RoleBinding; nothing else | Passed: the nine objects, every name from `search.name` |
| C3 | Names | `--set search.name=srch --set expose.name=vanity` | every object renamed `srch-public…`; the Route named `vanity` | Passed |
| C4 | The Route by default | `-s templates/20-route.yaml` | `host` = `publicHostname`, `tls.termination: passthrough`, `wildcardPolicy: None`, `haproxy.router.openshift.io/balance: roundrobin`, to Service `mongot-public-lb` port `mongot-grpc` | Passed |
| C5 | The Ingress | `--set expose.type=ingress` | an Ingress and no Route; `ingressClassName: openshift-default`, annotations `route.openshift.io/termination: passthrough` and the balance, `path: ''`, `pathType: ImplementationSpecific`, no `spec.tls` | Passed |
| C6 | Derived secret names and overrides | the Deployment's volumes with the defaults, with `tls.certsSecretPrefix=lab search.name=srch`, and with the three names set | `ent-mongot-search-lb-0-cert`, `…-client-cert`, `ent-trust-bundle` mounted at `/etc/envoy/tls/{server,client,ca}`; the prefix and name change them; a set name wins, in the Deployment and in the preflight's Role | Passed |
| C7 | The bootstrap against the operator's capture | the ConfigMap's `bootstrap.yaml` as JSON, diffed field by field with `docs/envoy/{bootstrap,lds,cds}.json` (`node`, `admin`, `layered_runtime`, the listener, the cluster), twice: with the capture's namespace and name, and with another namespace and two server names | the only differing paths are `…filter_chain_match.server_names` (first render) and, in the other namespace, that plus the cluster's endpoint `address` and `sni`; `static_resources` holds one listener and one cluster and there is no `dynamic_resources` | Passed. First render: 1 field differs (`server_names[0]`: `grpc-search.apps-crc.testing` → `mongot-public.example.com`). Other namespace: 3 fields differ (`server_names`, the endpoint address and the SNI, both `srch-search-0-svc.team-a.svc.cluster.local`) |
| C8 | The values reach the bootstrap | `--set envoy.retryPolicy.numRetries=5 … --set mongot.port=27029` | the retry count, the per-try timeout, the four timeouts and the port sit where the operator's values sit | Passed: `5 15s 120s 121s 122s 123s 27029 27029` |
| C9 | Envoy's own validation | the rendered `bootstrap.yaml` and throwaway certificate files, unpacked into the chart's image (`quay.io/ephico2real/envoy:v1.37-latest`); `envoy --mode validate -c /etc/envoy/bootstrap.yaml` as the image's user | exit 0 and `configuration '/etc/envoy/bootstrap.yaml' OK`; and a copy with an unknown filter type refused | Passed: `loading 1 cluster(s)`, `loading 1 listener(s)`, `configuration '/etc/envoy/bootstrap.yaml' OK`; the broken copy refused |
| C10 | Requests and limits on every container | every Job and Deployment container of a render with the monitor on | each has `requests.cpu`, `requests.memory`, `limits.cpu`, `limits.memory` | Passed: 2 containers (Envoy, the preflight), 4 of 4 each |
| C11 | The schema's refusals | `--set publicHostname=10.0.0.1`, a one-label name, an unknown key at the top, under `envoy` and under `expose`, an IP in `serverNames`, 0 replicas, `maxUnavailable: 0`, `envoy.timeouts.route=300`, a 44-character `search.name`, port 70000, an invalid namespace, resources without limits, `512MB`, `expose.type=loadbalancer`, `expose.balance=sticky` | each refused by the schema's own message | Passed, 16 refusals |
| C12 | The monitoring objects | off by default; `--set monitoring.serviceMonitor.enabled=true …` | nothing by default; then a ClusterIP Service on 9901 selecting this Deployment's pods, without the main chart's `mongodb.com/search-name` label, and a ServiceMonitor on `/stats/prometheus` with the `_total` relabel; never a Route | Passed |
| C13 | The preflight's script, against a stand-in `oc` | the Job's script taken out of the render; `oc` answers from files; a throwaway certificate with `DNS:mongot-public.example.com, DNS:*.apps.example.com` | everything present: exit 0 naming the hostname and the Service; `x.apps.example.com` accepted by the wildcard; `a.b.apps.example.com` refused (one label only); `other.example.com` refused with the SANs listed and `FAILED: 1 problem`; a missing server secret named and the certificate then not checked; a missing client secret, trust bundle and Service counted as 3; a secret without `tls.key` refused; an image without `openssl` refused by name; no certificate or key printed | Passed, 9 assertions |
| C14 | The preflight script's lint | `bash -n`; `shellcheck -S warning -s bash` | both clean | Passed |
| C15 | The documents | grep | NOTES and the README say `rollout restart` after a rotation; the main README and the main chart's README link the chart and `docs/mongot-envoy-vanity-url.md` | Passed |

`test/chart.sh` after the change: 233 passed (the main chart's README gained a paragraph; its claims check still
passes).

## Kind lab *(run pending)*

On `kind-mesh/` (one cluster is enough: `mesh0`), the main chart installed by `kind-mesh/scripts/search-up.sh` in
namespace `search` with mutual TLS from the lab's cert-manager root (`kind-mesh/manifests/20-search-certificates.yaml`),
Route off (kind has no router). `export KUBECONFIG=~/.kube/mongodb-mesh.config`. The vanity name for the lab:
`VANITY=mongot-public.lab.example`. Records go to `kind-mesh/output/vanity-*.txt`; screenshots to
`docs/screenshots/vanity-*.png`.

Before K1: the lab's `oc` image was rebuilt with `openssl` for the preflight (`kind-mesh/images/oc/Containerfile`,
tag `4.20.42-1` in `kind-mesh/values/search.yaml`; `search-up.sh` builds a tag it does not find), and the server
certificate `ent-mongot-search-lb-0-cert` was reissued with `VANITY` added to its `dnsNames` in
`20-search-certificates.yaml` (cert-manager reissues on the change; the operator's Envoy then needs
`kubectl -n search rollout restart deploy/mongot-search-lb-0`).

| # | What | Command | Passes when | Result |
| --- | --- | --- | --- | --- |
| K1 | The chart installs beside the main chart | `helm install mongot-public chart/mongot-envoy-vanity-url-helm -n search --kube-context kind-mesh0 --set publicHostname=$VANITY --set expose.enabled=false --set jobs.image.repository=localhost/kind-mesh/oc --set jobs.image.tag=4.20.42-1` (the lab's `oc` image, as `kind-mesh/values/search.yaml` gives it to the main chart) | the preflight Job succeeds (`kubectl -n search logs job/mongot-public-preflight` ends with `the certificate names every server name`); 2 pods `1/1 Running` with `app=mongot-public-lb`; the operator's `mongot-search-lb-0` pods untouched (same age) | *(run pending)* — `vanity-install.txt` |
| K2 | A gRPC health check through our Envoy with the vanity SNI | `kubectl -n search port-forward svc/mongot-public-lb 27028:27028 &`; from a pod with `curl` and HTTP/2 (`quay.io/mongodb/mongodb-community-server:8.3.4-ubi9`, as `kind-mesh-cilium/scripts/mongot-reach.sh` uses) or the host: `curl -sv --http2-prior-knowledge --cacert ca.crt --cert client.crt --key client.key --resolve $VANITY:27028:127.0.0.1 https://$VANITY:27028/grpc.health.v1.Health/Check -H 'content-type: application/grpc' --data-binary @empty-frame` with the client certificate from `ent-mongot-search-lb-0-client-cert` | TLSv1.3, ALPN h2, the server certificate's SANs holding `$VANITY`, and `grpc-status: 0` with a `SERVING` body from mongot; one access-log line in `deploy/mongot-public-lb` with an `upstream_host` that is a mongot pod | *(run pending)* — `vanity-reach.txt` |
| K3 | A wrong SNI refused | the same with `--resolve wrong.lab.example:27028:127.0.0.1 https://wrong.lab.example:27028/…` | the handshake closes with no certificate (`unexpected eof` / `SSL_ERROR_SYSCALL`); no access-log line | *(run pending)* — `vanity-wrong-sni.txt` |
| K4 | The spread over the mongot pods | 30 health checks as in K2; then `kubectl -n search exec deploy/mongot-public-lb -- curl -s localhost:9901/stats \| grep -E '^cluster\.mongot_rs_cluster\.(membership_healthy\|upstream_rq_total\|upstream_cx_total)'` and the access log's `upstream_host` counted with `sort \| uniq -c` | `membership_healthy: 2` (the lab's two mongot); the 30 requests split over both pods (15/15 under round robin) | *(run pending)* — `vanity-spread.txt`; screenshot `vanity-envoy-stats.png` |
| K5 | The preflight refuses a missing secret | `helm upgrade … --set tls.clientCertSecret=no-such-secret` | helm fails on the hook; the log says `MISSING: secret no-such-secret: Error from server (NotFound)` and `FAILED: 1 problem`; the Deployment is unchanged | *(run pending)* — `vanity-preflight-missing.txt` |
| K6 | The preflight refuses a certificate without the name | `helm upgrade … --set publicHostname=other.lab.example` | the log says `its certificate does not name other.lab.example (SANs: …)`; nothing changed | *(run pending)* — `vanity-preflight-name.txt` |
| K7 | The operator reconciles its own Envoy and not ours | `kubectl -n search annotate deploy/mongot-search-lb-0 test=x` (the operator reverts or keeps it; what matters is ours) and `kubectl -n search get deploy mongot-public-lb -o jsonpath='{.metadata.generation} {.metadata.ownerReferences}'` before and after a `kubectl -n search patch mongodbsearch mongot --type merge -p '{"spec":{"clusters":[{"loadBalancer":{"managed":{"replicas":1}}}]}}'` no-op reconcile | our Deployment's generation unchanged, no ownerReference; the operator's Deployment still its own | *(run pending)* — `vanity-reconcile.txt` |
| K8 | The ServiceMonitor with #191's Prometheus (if up) | `helm upgrade … --set monitoring.serviceMonitor.enabled=true`; Prometheus targets | the two Envoy pods scraped; `envoy_cluster_upstream_rq_total{envoy_cluster_name="mongot_rs_cluster"}` per pod | *(run pending, optional)* — screenshots `vanity-grafana-envoy.light.png`, `.dark.png` |
| K9 | Uninstall leaves the main chart's objects | `helm uninstall mongot-public -n search`; `kubectl -n search get deploy,svc,secret,configmap,mongodbsearch` | everything named `mongot-public…` gone; `mongot-search-lb-0`, `mongot-search-0-svc`, the three secrets, `ent-trust-bundle` and the MongoDBSearch as before; a search through the operator's Envoy still answers | *(run pending)* — `vanity-uninstall.txt` |

## OpenShift, by the owner *(run pending)*

The steps of [mongot-envoy-vanity-url.md, "Install on OpenShift"](mongot-envoy-vanity-url.md#install-on-openshift-step-by-step),
recorded with the owner's output, company names scrubbed. Screenshots in `docs/screenshots/`, light and dark where
the console has both.

| # | What | Command | Passes when | Result |
| --- | --- | --- | --- | --- |
| O1 | Install with a Route | `helm install ${NAME}-public … --set publicHostname=$HOST` | the preflight passes; 2 pods Ready | *(run pending)* |
| O2 | The Route | `oc get route ${NAME}-public` | `passthrough`, host `$HOST`, `roundrobin`, Admitted | *(run pending)* — screenshot `vanity-console-route.light.png`, `.dark.png` |
| O3 | The certificate served | `openssl s_client -connect $HOST:443 -servername $HOST -alpn h2` | the company certificate with `$HOST` among its SANs, TLSv1.3, ALPN h2 | *(run pending)* |
| O4 | A wrong name refused | `openssl s_client -connect $HOST:443 -servername wrong.$HOST` | the router's default certificate, no ALPN | *(run pending)* |
| O5 | `$search` through the vanity name | a mongod with `mongotHost=$HOST:443`; `db.<coll>.aggregate([{$search: …}])` | results; access-log lines in `deploy/${NAME}-public-lb` with mongot pod IPs | *(run pending)* — screenshot `vanity-console-pods.light.png`, `.dark.png` |
| O6 | The same through an Ingress | `helm upgrade … --set expose.type=ingress`; `oc get ingress,route` | the Route of O2 gone; the Ingress of class `openshift-default`; the generated Route `${NAME}-public-<suffix>` passthrough with the balance; O3 to O5 pass again | *(run pending)* — screenshot `vanity-console-ingress.light.png`, `.dark.png` |

## Not tested

- A certificate rotation under traffic: the chart's answer is a rollout restart (the README), as for the operator's
  Envoy; not timed here.
- More than one name in `serverNames` on a cluster: rendered and validated by Envoy (C7, C9), not dialled.
- A router timeout annotation on an Ingress reaching the generated Route: not documented by Red Hat, not set, not
  tested.
