# MongoDB Search: Prerequisites and Setup

Oct 6, 2026; Part 1 by script since Oct 8, 2026

## Overview

Two parts, in this order:

1. **Prerequisites.** Five objects that hold certificates, a password and the CA. A script makes them from the company's PEM files: [`generate-mongodbsearch-prerequisites.sh`](../chart/mongodb-search-helm/generate-mongodbsearch-prerequisites.sh), which is packaged with the chart.
2. **The chart.** `helm install` of [`chart/mongodb-search-helm`](../chart/mongodb-search-helm/) installs the operator, the `MongoDBSearch` resource and the Route, using those five objects as they are.

The chart never creates, changes or deletes the five objects. Before it installs anything, it checks that they exist and stops if one is missing.

| Object | Kind | Keys | Used by |
| --- | --- | --- | --- |
| `ent-trust-bundle` | ConfigMap | `ca.crt` | mongot and Envoy, to check the certs they receive |
| `ent-mongot-search-cert` | Secret | `tls.crt`, `tls.key`, `ca.crt` | mongot |
| `ent-mongot-search-lb-0-client-cert` | Secret | `tls.crt`, `tls.key`, `ca.crt` | Envoy, as the client to mongot |
| `ent-mongot-search-lb-0-cert` | Secret | `tls.crt`, `tls.key`, `ca.crt` | Envoy, serving the public hostname |
| `search-sync-source-password` | Secret | `password` | mongot, to sign in to the source mongod |

The three TLS secret names are fixed by the operator: `<prefix>-<name>-search-cert`, `<prefix>-<name>-search-lb-0-client-cert` and `<prefix>-<name>-search-lb-0-cert`, where the prefix is `tls.certsSecretPrefix` (`ent`) and the name is `search.name` (`mongot`).

**Before you start**

- [ ] Logged in with `oc`, and able to create secrets, ConfigMaps and operators in the namespace
- [ ] The namespace exists
- [ ] `helm` 3.17 or later (tested with 4.3.0)
- [ ] The `certified-operators` catalog is enabled on the cluster
- [ ] The Cluster Observability Operator is installed, for the dashboard in the console; if it is not, set `monitoring.persesDashboard.enabled: false` in the values file
- [ ] The three PEM files from the company signer and the passphrase of each. Each holds the encrypted key, the CA bundle and the leaf certificate
- [ ] The mongot PEM was issued for this namespace: its name is `mongot-search-0-svc.<namespace>.svc.cluster.local`, so a certificate made for `dvh-gp6-rnd` cannot serve another namespace
- [ ] `openssl` (OpenSSL 3, or the LibreSSL that macOS ships) and `bash` 3.2 or later

## Part 1: Create the prerequisites

The script turns each PEM into one object. It removes the key's password, finds the leaf by its key, puts the chain in order, and checks the certificate before anything is written: the chain, the dates, what the certificate may be used for, and the names it carries. A PEM given to the wrong step, or one issued for another namespace, is refused.

Every step has two forms. `--dry-run` writes the YAML file and contacts no cluster. `--apply` writes it and creates the object.

### Step 1: Name the namespace and make its folder

The namespace is never assumed. Name it once for the session, or pass `--target-namespace <namespace>` on each command; with neither, every command refuses.

```bash
export TargetNamespace=dvh-gp6-rnd
NS=$TargetNamespace                       # Part 2 uses $NS

# The script is a file of the chart. From a checkout of this repository, at its root:
PREREQ=chart/mongodb-search-helm/generate-mongodbsearch-prerequisites.sh
# From the published chart, with no clone (chart 0.3.3 and later):
#   helm pull https://github.com/ephico2real2/mongodb-poc/releases/download/mongodb-search-helm-0.3.5/mongodb-search-helm-0.3.5.tgz --untar
#   PREREQ=mongodb-search-helm/generate-mongodbsearch-prerequisites.sh

mkdir -m 700 $TargetNamespace             # the script never creates it
bash $PREREQ --check \
  --mongot <mongot PEM> --envoy <Envoy client PEM> --route <public hostname PEM>
```

Run it with `bash`: helm stores a chart's files without the executable bit. Run it from a directory outside the chart: helm packages every file under a chart's directory and keeps it in each release, so the script refuses to write there.

The files the script writes go into that folder, in the directory you run it from. `--check` asks for no passphrase. It reports the folder, the tools, the cluster you are logged in to, which of the five objects are there, and for each PEM its subject, names, expiry and whether it fits its step. It ends with `0 problem(s)` when you can go on.

The script refuses to write a file that git would track: this repository ignores `*.secret.yaml`, `*.configmap.yaml`, `*.pem`, `*.key` and `*.pass`.

### Step 2: Create the trust bundle

From the CA certificates in the mongot PEM. No passphrase is asked: a CA certificate is not encrypted.

```bash
bash $PREREQ --trustca <mongot PEM> --dry-run
bash $PREREQ --trustca <mongot PEM> --apply
```

If the public hostname certificate, or the source mongod, has another CA, add its PEM with a second `--trustca`. `--check-source <host:port>` also proves that the source mongod presents a certificate the bundle trusts (runbook Step 4).

### Step 3: Create the three TLS secrets

Each command asks for the passphrase of the key in its PEM.

```bash
# mongot: server and client auth
bash $PREREQ --mongot <mongot PEM> --dry-run
bash $PREREQ --mongot <mongot PEM> --apply

# Envoy: the client cert it presents to mongot
bash $PREREQ --envoy <Envoy client PEM> --dry-run
bash $PREREQ --envoy <Envoy client PEM> --apply

# Envoy: the server cert for the public hostname. It is mounted in the Envoy pods; the Route is passthrough and
# holds no certificate, and the chart creates it.
bash $PREREQ --route <public hostname PEM> --dry-run
bash $PREREQ --route <public hostname PEM> --apply
```

`--route` prints the hostname for the values file (`loadBalancer.externalHostname`). When the certificate names several, say which with `--hostname <fqdn>`.

What `--apply` does, each time:

- It reads the PEM again and asks for the passphrase again, so what goes to the cluster is what the PEM holds.
- It prints the cluster, the user and the namespace, and asks you to type the namespace. `--yes` skips that.
- It uses `oc create`, never `oc apply`: `apply` copies the whole secret, key included, into an annotation on the object.
- It refuses to touch an object that is already there. `--replace` replaces it, and the script restarts nothing. What then restarts is in [TLS.md](../TLS.md), section 8: the operator restarts mongot by itself when mongot's certificate has changed, and Envoy keeps serving the old certificate until it is restarted by hand.

### Step 4: Create the sync password secret

It asks for the password twice, without showing it. The secret holds the key `password` only; the user name goes in the values file as `source.username`.

```bash
bash $PREREQ --dbcred --username mongotuser --dry-run
bash $PREREQ --dbcred --username mongotuser --apply
```

### Step 5: Check all five, then remove the key files

```bash
bash $PREREQ --check
```

Expected under `cluster`: `tls.crt`, `tls.key` and `ca.crt` on the three TLS secrets, `password` on the password secret, `ca.crt` on the ConfigMap. The chart checks the same five objects before it installs; of a TLS secret it asks for `tls.crt` and `tls.key` only. `--check` also prints the lines for the values file of Step 6.

The `*.secret.yaml` files hold keys with no password. Once the objects are in the cluster, remove them:

```bash
bash $PREREQ --clean
```

It removes a file only when its secret is in the cluster. The files are unlinked, not overwritten: on current macOS `rm -P` does nothing, and no tool can overwrite a file in place on a solid-state or copy-on-write disk. Keep the folder on an encrypted disk.

For automation, the passphrase and the password may come from a file only you can read: `--passin-file <file>` and `--password-file <file>`. Never put either on a command line.

To make the five objects with `oc` alone, see [Part 1 by hand](#part-1-by-hand).

## Part 2: Install the chart

### Step 6: Write the values file

`--check` prints the namespace, the hostname and the user name as the script found them. Set the namespace, and the two values that have no default: the public hostname and the source mongod. Everything else defaults to the runbook's values; the full list is in the [chart README](../chart/mongodb-search-helm/README.md#values).

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
  https://github.com/ephico2real2/mongodb-poc/releases/download/mongodb-search-helm-0.3.5/mongodb-search-helm-0.3.5.tgz \
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

**Release a new chart version.** Change `version` in `chart/mongodb-search-helm/Chart.yaml`, and the version in the install commands of this document and of the chart's README, in one pull request. When it is merged and the checks on `main` have passed, the `release` job of [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) packages the chart and publishes it as the release `mongodb-search-helm-<version>`, with notes made from the pull requests since the last one. A version that is already released is left alone, so a merge that does not change the version publishes nothing.

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

## Part 1 by hand

What the script does, as `oc` commands. First split and verify the PEMs as in Steps 1 to 3 of the [fresh install runbook](mongot-envoy-mtls-fresh-install-runbook.md): for each of `mongot`, `envoy-client` and `lb` you then have `<name>.crt` (leaf, then chain), `<name>.key` (no password) and `<name>-ca.crt`, and `trust-bundle.pem` from its Step 4.

```bash
NS=$TargetNamespace

oc create configmap ent-trust-bundle --from-file=ca.crt=trust-bundle.pem -n $NS

oc create secret generic ent-mongot-search-cert --type=kubernetes.io/tls \
  --from-file=tls.crt=mongot.crt --from-file=tls.key=mongot.key --from-file=ca.crt=mongot-ca.crt -n $NS
oc create secret generic ent-mongot-search-lb-0-client-cert --type=kubernetes.io/tls \
  --from-file=tls.crt=envoy-client.crt --from-file=tls.key=envoy-client.key --from-file=ca.crt=envoy-client-ca.crt -n $NS
oc create secret generic ent-mongot-search-lb-0-cert --type=kubernetes.io/tls \
  --from-file=tls.crt=lb.crt --from-file=tls.key=lb.key --from-file=ca.crt=lb-ca.crt -n $NS

# The password: not shown, and kept out of shell history. "IFS= read -r" keeps a backslash and the spaces at
# either end, which are part of a password; printf '%s' adds no newline.
printf 'mongotuser password: '; stty -echo; IFS= read -r SYNC_PW; stty echo; echo
printf '%s' "$SYNC_PW" | oc create secret generic search-sync-source-password --from-file=password=/dev/stdin -n $NS
unset SYNC_PW
```

Then delete the decrypted key files (runbook Step 7d).

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| The script says `no namespace` | `TargetNamespace` is not exported and `--target-namespace` was not given | Step 1; there is no default |
| The script says `is not the mongot certificate for <namespace>` | The PEM was issued for another namespace, or it is another step's PEM | Give each step its own PEM; ask the signer for one issued for this namespace |
| The script says `wrong passphrase` | The passphrase typed is not the key's | Run the step again |
| The script says `this openssl ... cannot read the key` | The key's encryption is one this openssl build does not have | Set `OPENSSL` to another build, for example `OPENSSL=/opt/homebrew/bin/openssl` |
| The script says `git would track` | The folder is inside a repository that does not ignore it | Add the line it prints to `.gitignore` |
| The script says `inside the Helm chart` | It was run from the chart's directory, or below it | Run it from another directory, for example the repository's root |
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

Monitoring (the ServiceMonitors and the alerts are on by default; both need user workload monitoring on the cluster):

- Prometheus scrapes all five pods: `up` is 1 for the three mongot pods and the two Envoy pods.
- The rule group `mongot.distribution` is loaded and healthy: three recording rules and four alerts, none firing.
- The recorded share of search traffic is 0.33 for each mongot pod.

### Part 1, by the script

Oct 8, 2026, namespace `dvh-vectordb-qa` created for this on the same lab, OpenSSL 3.6.4 and bash 5.3.20. The PEMs were made for the test: a throwaway root and issuing CA, three leaf certificates for that namespace, each key encrypted (PKCS#8, AES-256) with a passphrase, in the company's layout.

| Run | Result |
| --- | --- |
| Any command with no namespace named | Refused: `no namespace: export TargetNamespace=<namespace>, or pass --target-namespace <namespace>` |
| `--check` before the folder exists | `1 problem(s)`: it says `mkdir -m 700 dvh-vectordb-qa`, and creates nothing |
| `--check` with the three PEMs | Each `fits` its step; `0 problem(s)`; no passphrase asked |
| The five steps with `--dry-run`, the passphrase and the password typed at the prompts | Five files, mode 600, in a folder of mode 700; nothing typed was shown; no object in the cluster |
| The five steps with `--apply`, the namespace typed back for two of them | Five objects created with `oc create` |
| A second `--apply` of one secret | Refused: already there; with `--replace`, replaced |
| The objects in the cluster | The three secrets hold `ca.crt tls.crt tls.key`, type `kubernetes.io/tls`; each leaf is the PEM's; each key starts `-----BEGIN PRIVATE KEY-----` and is its leaf's; each leaf verifies against the secret's `ca.crt` and against the ConfigMap; the password is the 18 bytes given |
| The key in an annotation | None: the objects carry only the script's own notes (when it was made, the leaf's subject, expiry and fingerprint). A probe secret made with `oc apply` did carry its value in `last-applied-configuration` |
| The chart's own preflight script, run against the namespace | `all hand-made objects are present` |
| `helm install --dry-run=server` with `namespace: dvh-vectordb-qa` | Accepted; no release was created |
| `--clean` | Removed the four secret files; kept the ConfigMap file |

mongot was not installed there: the lab node was at 90% memory.

The script's own tests ([`test/prerequisites.sh`](../test/prerequisites.sh), 105 checks, no cluster) pass with OpenSSL 3.6.4 and with LibreSSL 3.3.6, under bash 5.3.20 and under bash 3.2.57, in all four pairings.

Not tested:

- A cluster where the operator is installed by someone else (`operator.install=false`).
- Argo CD.
- Anything in `dvh-gp6-rnd`.
