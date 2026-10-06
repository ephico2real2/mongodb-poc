# mongodb-search-helm

MongoDB Search (mongot) behind the operator-managed Envoy on OpenShift, from one values file.

The chart replaces Steps 6a, 6b and 6d of the
[fresh install runbook](../../docs/mongot-envoy-mtls-fresh-install-runbook.md) and adds the operator install.
Steps 1 to 5 of the runbook stay manual: the chart never creates a certificate, a secret or the trust bundle.

## What it does

| Order | Object | What for |
| --- | --- | --- |
| before anything | preflight Job | Fails the install if a hand-made secret or the trust bundle is missing |
| 1 | OperatorGroup, Subscription | The MongoDB operator through OLM, on Manual approval, pinned to `operator.version` |
| 1 | MongoDBSearch | The resource of runbook Step 6a |
| 1 | Route | The passthrough Route of runbook Step 6d, with `balance: roundrobin` |
| 1 | ServiceMonitors, alerts | Optional, off by default |
| 2 | csv-reclaim Job | Clears an operator CSV left behind by an earlier uninstall |
| 3 | approver Job | Approves the InstallPlan for `operator.version`, and no other |
| 4 | gate Job | Returns only when the operator, mongot, Envoy and the Route are ready |

## Before you install

The namespace must exist and hold the five objects of runbook Steps 1 to 5. With the default values
(`tls.certsSecretPrefix: ent`, `search.name: mongot`) they are:

| Object | Kind | Keys |
| --- | --- | --- |
| `ent-mongot-search-cert` | Secret | `tls.crt`, `tls.key` |
| `ent-mongot-search-lb-0-cert` | Secret | `tls.crt`, `tls.key` |
| `ent-mongot-search-lb-0-client-cert` | Secret | `tls.crt`, `tls.key` |
| `search-sync-source-password` | Secret | `password` |
| `ent-trust-bundle` | ConfigMap | `ca.crt` |

The operator finds the three TLS secrets by name and says nothing when a name is wrong. The preflight turns that
into an install error that names the missing object. It reads the five objects by name and prints their key
names, never their contents.

The `certified-operators` catalog must be enabled on the cluster.

## Install

```bash
helm install mongot chart/mongodb-search-helm -n dvh-gp6-rnd \
  -f chart/mongodb-search-helm/examples/values-dvh-gp6-rnd.yaml --timeout 20m
```

`--timeout 20m` matters: Helm waits for the gate only as long as its timeout, which defaults to 5 minutes.

Two values have no default and must be set: `loadBalancer.externalHostname` and `source.hostAndPorts`.

If a Job fails, its log says why:

```bash
oc logs -n dvh-gp6-rnd job/mongot-mongodb-search-helm-preflight   # a missing secret or key
oc logs -n dvh-gp6-rnd job/mongot-mongodb-search-helm-approver    # the InstallPlan
oc logs -n dvh-gp6-rnd job/mongot-mongodb-search-helm-wait        # which readiness check did not pass
```

Still by hand after the install, as in the runbook: point DNS for the public name at the router (Step 6d), and
have the mongod hosts trust the company CA and use the public name on port 443 (Step 6c).

## Values

| Value | Default | Runbook |
| --- | --- | --- |
| `operator.install` | `true` | `false` when an operator already serves the namespace |
| `operator.version` | `1.13.0` | The only version the approver approves |
| `operator.channel`, `.package`, `.source`, `.sourceNamespace` | `stable`, `mongodb-kubernetes`, `certified-operators`, `openshift-marketplace` | |
| `operatorGroup.create` | `true` | `false` when the namespace already has an OperatorGroup |
| `search.name` | `mongot` | Step 6a, `metadata.name` |
| `search.version` | empty | mongot follows the operator's default; set it to pin mongot |
| `search.replicas` | `3` | Step 6a |
| `search.resources` | 1 CPU / 3Gi to 3 CPU / 5Gi | Step 6a |
| `search.persistence.storage`, `.storageClass` | `10Gi`, `thin-csi` | Step 6a |
| `search.keepOnUninstall` | `false` | Keeps the resource, and so the index, on `helm uninstall` |
| `loadBalancer.externalHostname` | required | Step 6a; also the Route's host |
| `loadBalancer.replicas` | `2` | Step 6a |
| `loadBalancer.retryPolicy` | 2 retries, `60s` per try | Step 6a |
| `loadBalancer.image` | empty | Step 6a, the Envoy image override |
| `tls.certsSecretPrefix` | `ent` | Overview, the secret naming rule |
| `tls.trustBundleConfigMap` | `ent-trust-bundle` | Step 4 |
| `source.hostAndPorts` | required | Step 6a |
| `source.username` | `mongotUser` | Step 6a |
| `source.passwordSecret.name`, `.key` | `search-sync-source-password`, `password` | Step 5 |
| `observability.*` | Prometheus on 9946, forwarder `auto` | Step 6a |
| `route.enabled`, `.name` | `true`, `mongot-search` | Step 6d |
| `route.serviceName` | empty: `<search.name>-search-0-proxy-svc` | Step 6d |
| `route.targetPort` | `mongot-grpc` | Step 6d |
| `route.balance` | `roundrobin` | Step 6d; see the [rationale](../../docs/mongot-route-balance-rationale.md) |
| `monitoring.serviceMonitors.enabled` | `false` | Per-pod scraping of mongot and Envoy |
| `monitoring.alerts.enabled` | `false` | Alerts when traffic concentrates on one mongot pod |
| `preflight.enabled` | `true` | |
| `installPlanApprover.waitSeconds`, `csvReclaim.*`, `wait.*`, `jobs.*` | see `values.yaml` | |

`values.schema.json` refuses an unknown key, an IP address as hostname and a source without a port.

## Upgrades

The Subscription is on Manual approval, so the operator never upgrades by itself. To upgrade it, set
`operator.version` and run `helm upgrade`; the approver approves that version's InstallPlan.

mongot follows the operator. With `search.version` empty the operator runs its own default mongot version
(1.70.1 for operator 1.13.0), so mongot changes only when `operator.version` does. Set `search.version` to hold
mongot on one version across operator upgrades.

When you change `operator.version`, change `appVersion` in `Chart.yaml` to match and run
`scripts/refresh-mongodbsearch-crd.sh` against a cluster on that version.

## Uninstall

`helm uninstall` removes the Subscription, the MongoDBSearch, the Route and the monitoring objects.

- **The search index is deleted.** The operator sets the mongot volumes to be deleted with the resource, so a
  reinstall syncs from the source again. Set `search.keepOnUninstall=true` to leave the resource in place.
- **The operator keeps running.** OLM leaves the operator's CSV when its Subscription goes. The next install
  clears it (the csv-reclaim Job). To remove it now: `oc delete csv mongodb-kubernetes.v1.13.0 -n <namespace>`.
- **The CRDs, the hand-made secrets and the trust bundle stay.**

## Argo CD

Every hook also carries Argo CD annotations, and [`examples/argocd-application.yaml`](examples/argocd-application.yaml)
shows an Application. It sets `skipCrds: true`, so Argo CD never owns a CRD that OLM manages. Not run in the lab.

## Tests

```bash
test/chart.sh        # no cluster: lint, renders, the runbook comparison, schema refusals, the Jobs' scripts
```

## Tested

On 2026-10-06, against the CRC lab (OpenShift 4.22.7, operator 1.13.0, Helm 4.3.0):

- `test/chart.sh` passes.
- Every rendered object passes a server-side dry run against the lab's API (`oc apply --dry-run=server`).
- The preflight script, run read-only against the lab's existing secrets, passes; with a wrong prefix and a wrong
  trust bundle name it fails and names the four missing objects.
- The gate script, run read-only against the running lab, passes; told to expect three mongot pods, or another
  certificate secret name, it fails and names that check.

Not run yet:

- A real `helm install`: the Jobs in the cluster under their own Roles, the approver approving an InstallPlan,
  the csv-reclaim, and an uninstall followed by a reinstall.
- An end-to-end `$search` through the chart's Route.
- `operator.install=false`, and Argo CD.
