# MongoDB Search: Prerequisites and Setup

Oct 6, 2026

## Overview

Two parts, in this order:

1. **Prerequisites, by hand.** Five objects that hold certificates, a password and the CA. You create them with `oc`.
2. **The chart.** `helm install` of [`chart/mongodb-search-helm`](../chart/mongodb-search-helm/) installs the operator, the `MongoDBSearch` resource and the Route, using those five objects as they are.

The chart never creates, changes or deletes the five objects. Before it installs anything, it checks that they exist and stops if one is missing.

| Object | Kind | Keys | Used by |
| --- | --- | --- | --- |
| `ent-trust-bundle` | ConfigMap | `ca.crt` | mongot and Envoy, to check the certs they receive |
| `ent-mongot-search-cert` | Secret | `tls.crt`, `tls.key` | mongot |
| `ent-mongot-search-lb-0-client-cert` | Secret | `tls.crt`, `tls.key` | Envoy, as the client to mongot |
| `ent-mongot-search-lb-0-cert` | Secret | `tls.crt`, `tls.key` | Envoy, serving the public hostname |
| `search-sync-source-password` | Secret | `password` | mongot, to sign in to the source mongod |

The three TLS secret names are fixed by the operator: `<prefix>-<name>-search-cert`, `<prefix>-<name>-search-lb-0-client-cert` and `<prefix>-<name>-search-lb-0-cert`, where the prefix is `tls.certsSecretPrefix` (`ent`) and the name is `search.name` (`mongot`).

**Before you start**

- [ ] Logged in with `oc`, and able to create secrets, ConfigMaps and operators in the namespace
- [ ] The namespace exists
- [ ] `helm` 3.17 or later (tested with 4.3.0)
- [ ] The `certified-operators` catalog is enabled on the cluster
- [ ] The certificate files are split and verified as in Steps 1 to 3 of the [fresh install runbook](mongot-envoy-mtls-fresh-install-runbook.md): for each of `mongot`, `envoy-client` and `lb` you have `<name>.crt` (leaf, then chain), `<name>.key` (no password) and `<name>-ca.crt`

## Part 1: Create the prerequisites

### Step 1: Set variables

Run every later step in the same terminal session.

```bash
NS=dvh-gp6-rnd
TRUST_CM=ent-trust-bundle
MONGOT_SECRET=ent-mongot-search-cert
ENVOY_CLIENT_SECRET=ent-mongot-search-lb-0-client-cert
LB_SECRET=ent-mongot-search-lb-0-cert
SYNC_PW_SECRET=search-sync-source-password
```

### Step 2: Create the trust bundle

`trust-bundle.pem` holds the company CA. If the public hostname cert has a different CA, put both in the file (runbook Step 4).

```bash
oc create configmap $TRUST_CM --from-file=ca.crt=trust-bundle.pem -n $NS
```

### Step 3: Create the three TLS secrets

```bash
# mongot: server and client auth
oc create secret generic $MONGOT_SECRET --type=kubernetes.io/tls \
  --from-file=tls.crt=mongot.crt \
  --from-file=tls.key=mongot.key \
  --from-file=ca.crt=mongot-ca.crt -n $NS

# Envoy: client cert it presents to mongot
oc create secret generic $ENVOY_CLIENT_SECRET --type=kubernetes.io/tls \
  --from-file=tls.crt=envoy-client.crt \
  --from-file=tls.key=envoy-client.key \
  --from-file=ca.crt=envoy-client-ca.crt -n $NS

# Envoy: server cert for the public hostname
oc create secret generic $LB_SECRET --type=kubernetes.io/tls \
  --from-file=tls.crt=lb.crt \
  --from-file=tls.key=lb.key \
  --from-file=ca.crt=lb-ca.crt -n $NS
```

### Step 4: Create the sync password secret

This prompts for the password without showing it and keeps it out of shell history.

```bash
printf 'mongotUser password: '; stty -echo; read SYNC_PW; stty echo; echo
printf '%s' "$SYNC_PW" | oc create secret generic $SYNC_PW_SECRET \
  --from-file=password=/dev/stdin -n $NS
unset SYNC_PW
```

### Step 5: Check all five

This prints the key names of each object, never the contents. It is the same check the chart makes before it installs.

```bash
for s in $MONGOT_SECRET $LB_SECRET $ENVOY_CLIENT_SECRET $SYNC_PW_SECRET; do
  echo "$s: $(oc get secret $s -n $NS -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}')"
done
echo "$TRUST_CM: $(oc get configmap $TRUST_CM -n $NS -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}')"
```

Expected: `tls.crt` and `tls.key` on the three TLS secrets, `password` on the password secret, `ca.crt` on the ConfigMap. Then delete the decrypted key files (runbook Step 7d).

## Part 2: Install the chart

### Step 6: Write the values file

Set the namespace, and the two values that have no default: the public hostname and the source mongod. Everything else defaults to the runbook's values; the full list is in the [chart README](../chart/mongodb-search-helm/README.md#values).

```yaml
# my-values.yaml
namespace: dvh-gp6-rnd                              # where everything goes; must hold the five prerequisites
loadBalancer:
  externalHostname: mongot-search-rnd.company.net   # also the Route's host; must be a SAN of the lb cert
  image: quay.io/ephico2real/envoy:v1.37-latest      # optional Envoy image override
source:
  hostAndPorts:
    - abc234.uat.company.net:26018
```

That file is [`examples/values-dvh-gp6-rnd.yaml`](../chart/mongodb-search-helm/examples/values-dvh-gp6-rnd.yaml). If your secret names differ from the table in the Overview, set `tls.certsSecretPrefix`, `search.name`, `tls.trustBundleConfigMap` and `source.passwordSecret.name` to match.

### Step 7: Dry run

Nothing is changed. It validates the values and every object against the cluster.

```bash
helm install mongot chart/mongodb-search-helm -n $NS -f my-values.yaml --dry-run=server
```

### Step 8: Install

From the published package, with no clone of the repository:

```bash
helm install mongot \
  https://github.com/ephico2real2/mongodb-poc/releases/download/mongodb-search-helm-0.1.0/mongodb-search-helm-0.1.0.tgz \
  -n $NS -f my-values.yaml --timeout 20m
```

Or from a checkout:

```bash
helm install mongot chart/mongodb-search-helm -n $NS -f my-values.yaml --timeout 20m
```

`--timeout 20m` matters: Helm waits for the last check only as long as its timeout, which defaults to 5 minutes.

Every object goes to the `namespace` in the values file. Pass the same namespace with `-n`, so Helm's own record of the release sits beside what it installed.

What happens, in order:

| Order | Job or object | What it does |
| --- | --- | --- |
| 1 | `preflight` Job | Checks the five objects; stops the install if one is missing |
| 2 | OperatorGroup, Subscription, MongoDBSearch, Route | Created together |
| 3 | `csv-reclaim` Job | Removes an operator left over from an earlier uninstall |
| 4 | `approver` Job | Approves the operator's InstallPlan, for the pinned version only |
| 5 | `wait` Job | Returns when the operator, mongot, Envoy and the Route are ready |

### Step 9: Verify

```bash
# What each Job did
oc logs -n $NS job/mongot-mongodb-search-helm-approver -c approve
oc logs -n $NS job/mongot-mongodb-search-helm-wait -c wait

# The operator is on Manual approval and installed
oc get subscription,installplan,csv -n $NS

# The resource, the workloads and the Route
oc get mongodbsearch,statefulset,deployment,route -n $NS
```

Expected last line of the `wait` log:

```text
MongoDB Search is ready: operator mongodb-kubernetes.v1.13.0, mongot 1.70.1 x3, Envoy x2
```

Then run a `$search` query against a collection that has a search index (runbook Step 7c).

### Step 10: Finish by hand

As in the runbook:

- [ ] DNS for the public hostname points at the router (runbook Step 6d)
- [ ] The mongod hosts trust the company CA and use the public hostname on port 443 for search (runbook Step 6c)

## Changing, upgrading and removing

**Change a value.** Edit the values file, then:

```bash
helm upgrade mongot chart/mongodb-search-helm -n $NS -f my-values.yaml --timeout 20m
```

**Upgrade the operator.** The Subscription is on Manual approval, so the operator never upgrades by itself. Set `operator.version` and run the same `helm upgrade`; the approver approves that version only. mongot follows the operator: with `search.version` empty it runs the operator's default mongot version, so it moves only when the operator does.

**Uninstall.**

```bash
helm uninstall mongot -n $NS
```

- **The search index is deleted.** The operator deletes the mongot volumes with the resource, so a reinstall syncs from the source again. Set `search.keepOnUninstall=true` to keep the resource.
- **The operator keeps running.** OLM leaves it when its Subscription goes. The next `helm install` removes it and installs it again. To remove it now: `oc delete csv mongodb-kubernetes.v1.13.0 -n $NS`.
- **The five prerequisites stay**, along with the CRDs.

**Replace a setup that was applied by hand.** Helm refuses to install over objects it does not own. Delete them first; the five prerequisites stay.

```bash
oc delete mongodbsearch/mongot -n $NS
oc delete route/<route name> -n $NS
oc delete subscription/mongodb-kubernetes csv/mongodb-kubernetes.v1.13.0 -n $NS
oc delete operatorgroup/<operatorgroup name> -n $NS    # or keep it and set operatorGroup.create=false
```

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Install stops at once; `preflight` log says `MISSING: secret …` | A prerequisite is absent, misnamed or lacks a key | Part 1; compare the names with the Overview table |
| `preflight` log says `OperatorGroup … already exists` | The namespace already has an OperatorGroup | Set `operatorGroup.create=false` |
| `exists and cannot be imported into the current release` | The object was applied by hand | Delete it first (see above) |
| `approver` log says OLM staged an InstallPlan for another version | `operator.version` is not what the catalog offers | Set `operator.version` to a version in the channel |
| `wait` log stops at `mongot …: N ready` | mongot pods are not Ready | `oc get pods -n $NS`; `oc describe pod`; check storage class and memory |
| `wait` log stops at `Envoy mounts …` | The operator did not find the TLS secrets | Check `tls.certsSecretPrefix` and `search.name` against the secret names |
| Helm reports a timeout while the Jobs are still running | `--timeout` too short | Rerun with `--timeout 20m` |

To read any Job's log:

```bash
oc logs -n $NS job/mongot-mongodb-search-helm-preflight -c preflight
oc logs -n $NS job/mongot-mongodb-search-helm-csv-reclaim -c reclaim
oc logs -n $NS job/mongot-mongodb-search-helm-approver -c approve
oc logs -n $NS job/mongot-mongodb-search-helm-wait -c wait
```

## Tested on CRC

Oct 6, 2026, namespace `mongodb-poc`, OpenShift 4.22.7, Helm 4.3.0, with [`examples/values-crc.yaml`](../chart/mongodb-search-helm/examples/values-crc.yaml). The five prerequisites were the ones already in the lab, used as they were.

| Run | Result | Helm time |
| --- | --- | --- |
| Hand-applied setup deleted, then `helm install` | Preflight passed; approver approved InstallPlan `install-g2sw5` for 1.13.0; gate passed | 46 s |
| `helm uninstall`, then `helm install` | The leftover operator CSV was removed; approver approved `install-c7qvw`; gate passed | 34 s |
| `helm upgrade --set search.replicas=3` | Three mongot pods Ready; gate passed | 111 s |
| `helm upgrade` with unchanged values | Nothing changed; no pod restarted | 33 s |
| `helm upgrade` naming a trust bundle that does not exist | Stopped by the preflight, which named the missing ConfigMap; the resource was not changed | 9 s |

Search against the external replica set, through the chart's Route:

- Text and vector queries returned results, for example "The Karate Kid" for `karate`.
- 30 text queries split 10 / 10 / 10 across the three mongot pods.
- Envoy logged 37 requests, all gRPC `OK`, split 12 / 12 / 13 across mongot. One Envoy pod carried all 37: the replica set holds one connection, and the Route places connections, not requests.

Monitoring (`monitoring.serviceMonitors.enabled` is on by default; the lab values also switch on `monitoring.alerts.enabled`; both need user workload monitoring on the cluster):

- Prometheus scrapes all five pods: `up` is 1 for the three mongot pods and the two Envoy pods.
- The rule group `mongot.distribution` is loaded and healthy: three recording rules and four alerts, none firing.
- The recorded share of search traffic is 0.33 for each mongot pod.

Not tested:

- **Part 1 on this date.** The commands are the runbook's Steps 4 and 5. They were not rerun, because recreating the lab's secrets would mean writing its private keys to disk; the existing objects were used.
- A cluster where the operator is installed by someone else (`operator.install=false`).
- Argo CD.
- Anything in `dvh-gp6-rnd`.
