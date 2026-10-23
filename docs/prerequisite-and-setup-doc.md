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

The table lists the keys the script writes. The TLS secrets' `ca.crt` is a harmless extra; Operator 1.13.0 reads peer trust from the source CA ConfigMap (`ent-trust-bundle` here). See the [runbook's operator source references](mongot-envoy-mtls-fresh-install-runbook.md#step-5-create-the-secrets).

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

The namespace is never assumed. Name it on each command as a plain word (`--check dvh-gp6-rnd`) or with `--target-namespace <namespace>`, or once for the session with `export TargetNamespace=<namespace>`; with none, every command refuses, and two that differ are refused.

```bash
NS=dvh-gp6-rnd                            # Part 2 uses $NS

# The script is a file of the chart. From a checkout of this repository, at its root:
PREREQ=chart/mongodb-search-helm/generate-mongodbsearch-prerequisites.sh
# From the published chart, with no clone (chart 0.3.3 and later):
#   helm pull https://github.com/ephico2real2/mongodb-poc/releases/download/mongodb-search-helm-0.3.35/mongodb-search-helm-0.3.35.tgz --untar
#   PREREQ=mongodb-search-helm/generate-mongodbsearch-prerequisites.sh

mkdir -m 700 $NS                          # the script never creates it
cp /path/to/mongot.pem /path/to/envoy.pem /path/to/public.pem "$NS/"   # or leave them in the current directory
bash $PREREQ --check $NS
```

The script finds each PEM that is not named, and prints the file chosen with its leaf's subject and names before any passphrase is asked:

1. A path named on the command line (`--mongot <pem>`, `--envoy <pem>`, `--route <pem>`), or in the environment (`MONGOT_PEM`, `ENVOY_PEM`, `ROUTE_PEM`).
2. The certificate's common name, as the company names its PEM files (the [runbook](mongot-envoy-mtls-fresh-install-runbook.md), Step 1), in `./$NS/` (if it holds no PEM, in the current directory): `mongot-search-0-svc.dvh-gp6-rnd.svc.cluster.local.pem`, `mongot-search-0-proxy-svc.dvh-gp6-rnd.svc.cluster.local.pem`, and `<fqdn>.pem` for the public certificate when `--hostname <fqdn>` is given. For other names set `MONGOT_PEM_NAME`, `ENVOY_PEM_NAME` or `ROUTE_PEM_NAME`, with the tokens `{search}`, `{ns}` and `{hostname}`. A file found by its name must still fit its step.
3. Otherwise the one `*.pem` in `./$NS/` (if it holds none, in the current directory) whose certificate fits the step: mongot's names mongot's service and allows server and client authentication; Envoy's allows client authentication; the public one allows server authentication and names one public hostname. No PEM, or two, for a step is refused; a PEM that fits two steps is given to neither. Name the PEM to settle it.

Discovery follows a PEM that is a symbolic link, and prints the path it chose. A public certificate, or a client
certificate with no name, cannot show which namespace it was issued for: keep only this installation's PEMs where the
script looks, or name the PEMs and give `--hostname`. A plain word that is an existing file is taken as a file, not a
namespace: name the namespace with `--target-namespace` then. A PEM path that begins with `-` is written `./-…`, so
that it is not read as an option.

Every command below takes the PEMs this way, and each still takes a PEM by its path, as `--check --mongot <mongot PEM> --envoy <Envoy client PEM> --route <public hostname PEM> $NS`.

Run it with `bash`: helm stores a chart's files without the executable bit. Run it from a directory outside the chart: helm packages every file under a chart's directory and keeps it in each release, so the script refuses to write there.

The files the script writes go into that folder, in the directory you run it from. `--check` asks for no passphrase. It reports the folder, the tools, the cluster you are logged in to, which of the five objects are there, and for each PEM its subject, names, expiry and whether it fits its step. It ends with `0 problem(s)` when you can go on.

The script refuses to write a file that git would track: this repository ignores `*.secret.yaml`, `*.configmap.yaml`, `*.pem`, `*.key` and `*.pass`.

Steps 2 to 4 in one command, each step as it runs alone, stopping at the first one refused. What the steps before it made stays; a step that fails while applying also leaves its own file:

```bash
bash $PREREQ --all --dry-run --username mongotuser $NS
bash $PREREQ --all --apply --username mongotuser $NS     # the namespace typed for each object, the three passphrases, the password twice
```

With `--passin-file`, the one file must open all three keys; when their passphrases differ, run the three commands of Step 3 one by one, each with its own file.

### Step 2: Create the trust bundle

From the CA certificates in the three PEMs, found as in Step 1, or in the PEMs you name. No passphrase is asked: a CA certificate is not encrypted.

```bash
bash $PREREQ --trustca --dry-run $NS                  # the CA certificates of the three PEMs found
bash $PREREQ --trustca --apply $NS
# or from the PEMs you name: bash $PREREQ --trustca <mongot PEM> [<other PEM>...] --dry-run $NS
```

If the source mongod has another CA, name every PEM, since none is found once one is named: `--trustca <mongot PEM> <Envoy client PEM> <public hostname PEM> <source CA PEM>`. `--check-source <host:port>` also proves that the source mongod presents a certificate the bundle trusts (runbook Step 4).

### Step 3: Create the three TLS secrets

Each command asks for the passphrase of the key in its PEM.

```bash
# mongot: server and client auth
bash $PREREQ --mongot --dry-run $NS                   # or --mongot <mongot PEM>
bash $PREREQ --mongot --apply $NS

# Envoy: the client cert it presents to mongot
bash $PREREQ --envoy --dry-run $NS                    # or --envoy <Envoy client PEM>
bash $PREREQ --envoy --apply $NS

# Envoy: the server cert for the public hostname. It is mounted in the Envoy pods; the Route is passthrough and
# holds no certificate, and the chart creates it.
bash $PREREQ --route --dry-run $NS                    # or --route <public hostname PEM>, or --hostname <fqdn>
bash $PREREQ --route --apply $NS
```

`--route` prints the hostname for the values file (`loadBalancer.externalHostname`). When the certificate names several, say which with `--hostname <fqdn>`; the script then also looks for the file `<fqdn>.pem`.

If the Envoy client certificate also allows server authentication, or has no EKU, it is told from the public certificate by the route PEM found, which stands for `--route-reference`. When none is found, add `--route-reference <public PEM>` on each `--envoy` run, including `--apply` and `--check --envoy`; the reference must identify a distinct public certificate with a valid chain.

What `--apply` does, each time:

- It reads the PEM again and asks for the passphrase again, so what goes to the cluster is what the PEM holds.
- It prints the cluster, the user and the namespace, and asks you to type the namespace. `--yes` skips that.
- It uses `oc create`, never `oc apply`: `apply` copies the whole secret, key included, into an annotation on the object.
- It refuses to touch an object that is already there. `--replace` replaces it, and the script restarts nothing. What then restarts is in [TLS.md](../TLS.md), section 8: the operator restarts mongot by itself when mongot's certificate has changed, and Envoy keeps serving the old certificate until it is restarted by hand.

### Step 4: Create the sync password secret

It asks for the password twice, without showing it. The secret holds the key `password` only; the user name goes in the values file as `source.username`.

```bash
bash $PREREQ --dbcred --username mongotuser --dry-run $NS
bash $PREREQ --dbcred --username mongotuser --apply $NS
```

### Step 5: Check all five, then remove the key files

```bash
bash $PREREQ --check $NS
```

Expected under `cluster`: `tls.crt`, `tls.key` and `ca.crt` on the three TLS secrets, `password` on the password secret, `ca.crt` on the ConfigMap. The chart checks the same five objects before it installs; of a TLS secret it asks for `tls.crt` and `tls.key` only. `--check` also prints the lines for the values file of Step 6.

The `*.secret.yaml` files hold keys with no password. Once the objects are in the cluster, remove them:

```bash
bash $PREREQ --clean $NS
```

It removes a file only when its secret is in the cluster. The files are unlinked, not overwritten: on current macOS `rm -P` does nothing, and no tool can overwrite a file in place on a solid-state or copy-on-write disk. Keep the folder on an encrypted disk.

For automation, the passphrase and the password may come from a file only you can read: `--passin-file <file>` and `--password-file <file>`. Never put either on a command line.

To make the five objects with `oc` alone, see [Part 1 by hand](#part-1-by-hand).

## Part 2: Install the chart

With Argo CD, which is how this is meant to be run: [`argocd.md`](../chart/mongodb-search-helm/argocd.md), beside the chart, after Part 1. The steps below install the same chart by hand with Helm.

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
  https://github.com/ephico2real2/mongodb-poc/releases/download/mongodb-search-helm-0.3.35/mongodb-search-helm-0.3.35.tgz \
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

**Upgrade the operator.** The Subscription is on Manual approval, so the operator never upgrades by itself. Set `operator.version` and run the same `helm upgrade`; the approver approves that version only. mongot does not move with it: `search.version` is `1.70.1` by default, so mongot is changed as a step of its own. With `search.version` empty mongot would run the operator's default version and move whenever the operator does.

**Publish the index names as metrics (optional).** mongot's metrics name a search index by its id only. `monitoring.indexInfo.enabled=true` adds a small exporter that asks the source deployment for the names; it needs a sixth hand-made object, the password of a database user that may only list. The user, the Secret and what is published are in the chart's README, [Index names, as metrics](../chart/mongodb-search-helm/README.md#index-names-as-metrics).

**Release a new chart version.** Change `version` in `chart/mongodb-search-helm/Chart.yaml`, and the version in the install commands of this document and of the chart's README, in one pull request. When it is merged and the checks on `main` have passed, the `release` job of [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) packages the chart and publishes it as the release `mongodb-search-helm-<version>`, with notes made from the pull requests since the last one. A version that is already released is left alone, so a merge that does not change the version publishes nothing.

**Uninstall.**

```bash
helm uninstall mongot -n $NS
```

- **The search index is kept.** `search.keepOnUninstall` is `true` by default: the resource, its pods and its volumes stay, and the Route goes. With `search.keepOnUninstall=false` the operator deletes the mongot volumes with the resource, so a reinstall syncs from the source again ([volumes.md](../chart/mongodb-search-helm/volumes.md)).
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
NS=dvh-gp6-rnd                            # as in Step 1

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

The messages are quoted in part: `<…>` and `...` stand for what the script prints there.

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| The script says `no namespace` | No namespace was named: no plain word, no `--target-namespace`, and `TargetNamespace` is not exported | Step 1; there is no default |
| The script says `which one?` | Two of the plain word, `--target-namespace` and `TargetNamespace` name different namespaces | Name it one way, or unset `TargetNamespace` |
| The script says `which role is <file>?` | A PEM was given with no option before it | Put `--mongot`, `--envoy`, `--route` or `--trustca` before it |
| The script says `is not a namespace name (lower-case letters, digits and '-'), nor a file here` | A word that is not a file is read as the namespace: most likely a PEM path mistyped | Check the path; a PEM goes after its option, as `--mongot <pem>` |
| The script says `two namespaces were given: <first> and <second>` | Two words that are not files, each read as the namespace (a PEM path mistyped, or a second namespace), or two `--target-namespace` that differ | Check the paths; name one namespace |
| The script says `an empty argument (an unset variable?)` | A word was empty, as `"$x"` is when `x` is not set | Set the variable, or leave the word out |
| The script says `no PEM for the <step> role` | No PEM was named, no file has the step's name, and there is no `*.pem` in the folder or in the current directory | Step 1: put the PEMs in the folder, or name each with `--<step> <pem>` |
| The script says `no PEM fits the <step> role in <folder> (...)` | No PEM in the folder (or, when the folder holds none, in the current directory) fits that step; the message says why for each file | Put the step's PEM there, or name it with `--<step> <pem>` |
| The script says `two PEMs fit the <step> role` | Two PEMs could serve that step: the script does not choose | Name one with `--<step> <pem>`, or name the files by their common name (Step 1) |
| The script says `it fits mongot and envoy, and is given to neither` | One certificate could serve two steps | Name it with the option of its step |
| The script says `found by its name (MONGOT_PEM_NAME), is not the mongot certificate for <namespace>` (or Envoy's, the route's) | A file has the name the script looks for, but its certificate does not fit that step | Rename the file, or name the right PEM with `--<step> <pem>` |
| The script says `--all stopped at --<step> (step N of 5)` | That step refused, for the reason that follows, or a command it ran failed (`(exit status N)`, after that command's own message); the steps before it were made, the ones after were not; a step that failed while applying also leaves its own file | Fix what it says and run `--all` again (with `--apply`, add `--replace` for the objects already created) |
| The script says `is not the mongot certificate for <namespace>` | The PEM was issued for another namespace, or it is another step's PEM | Give each step its own PEM; ask the signer for one issued for this namespace |
| The script says `a certificate allowing both server and client authentication, or with no EKU, cannot be distinguished from the public certificate` | The Envoy candidate also permits server authentication, names alone cannot establish its role, and no public PEM was found to tell it from (none, or two) | Put the one public PEM in the folder, where it is found and taken as the reference, or add `--route-reference <public PEM>` to `--envoy` (also with `--check`). The reference must have one public leaf, a valid chain, and a different fingerprint. Use `--hostname` if it has several public names. A generated route Secret is never taken as the reference. A public PEM found in the folder standing for `--route-reference` is new with chart 0.3.35 (#196) and replaces #61's rule that the public PEM be named on the run |
| The script says `this is the public certificate named by --route-reference` | The Envoy candidate and the explicit public reference have the same leaf fingerprint | Give `--envoy` its own client PEM; keep the public PEM as the reference |
| The script says `its basic constraints do not say CA:TRUE` | The root is version 3 and its basic constraints say `CA:FALSE`, or it has no basic constraints and neither a Certificate Sign key usage nor a Netscape CA type. OpenSSL 3 refuses such a root as `invalid CA certificate` (error 79), and LibreSSL accepts most of them; the script refuses them on every build. Roots with `CA:TRUE`, with no basic constraints but Certificate Sign key usage, or of version 1 are accepted | Ask the CA owner for a root with `basicConstraints = critical, CA:TRUE` and replace the rejected root in the PEM |
| The script says `wrong passphrase` | The passphrase typed is not the key's | Run the step again |
| The script says `this openssl (<version>) cannot read the key in <file>: <reason>` | The key's encryption is one this openssl build does not have | Set `OPENSSL` to another build, for example `OPENSSL=/opt/homebrew/bin/openssl` |
| The script says `git would track` | The folder is inside a repository that does not ignore it | Add the line it prints to `.gitignore` |
| The script says `inside the Helm chart` | It was run from the chart's directory, or below it | Run it from another directory, for example the repository's root |
| Install stops at once; `preflight` log says `MISSING: secret …` | A prerequisite is absent, misnamed or lacks a key | Part 1; compare the names with the Overview table |
| `preflight` log says `OperatorGroup … already exists` | The namespace already has an OperatorGroup | Set `operatorGroup.create=false` |
| `exists and cannot be imported into the current release` | The object was applied by hand | Delete it first (see above) |
| `approver` log says OLM staged an InstallPlan for another version | `operator.version` is not what the catalog offers | Set `operator.version` to a version in the channel |
| `wait` log stops at `mongot …: N ready` | mongot pods are not Ready | `oc get pods -n $NS`; `oc describe pod`; check storage class and memory |
| `wait` log stops at `Envoy mounts …` | The operator did not find the TLS secrets | Check `tls.certsSecretPrefix` and `search.name` against the secret names |
| Helm reports a timeout while the Jobs are still running | `--timeout` too short | Rerun with `--timeout 20m` |
| `$listSearchIndexes` reports every index `PENDING` and not queryable, or lists it on fewer hosts than there are mongot pods, while searches return results | A mongot pod sent no heartbeat to the source for over 2 hours (every pod of a suspended lab; one pod cut off from the source). Another pod then removes its heartbeat row, and mongot 1.70.1 does not write it again while it runs: the pod logs `Failed to update server state entry` every 30 seconds. Reproduced on the lab on Oct 9, 2026 by removing one pod's row: not written again in 12 minutes, the index listed on 2 hosts of 3 | Restart the pods that log the warning, one at a time, each Ready, `STEADY` on every index and caught up before the next: `oc delete pod <name>-search-0-0 -n $NS`, and so on. A pod that restarts on its volume has nothing to sync: on the lab it was Ready in 24 seconds and listed again half a minute later. A pod that has to sync from scratch is another matter: 4 to 5 hours for about 180 to 190 GB a pod on the owner's QA cluster, as the owner reports it (see *Replication lag* in the chart's README). mongot's own state of an index, on the dashboard, was right throughout |

To read any Job's log:

```bash
oc logs -n $NS job/mongot-mongodb-search-helm-preflight -c preflight
oc logs -n $NS job/mongot-mongodb-search-helm-csv-reclaim -c reclaim
oc logs -n $NS job/mongot-mongodb-search-helm-approver -c approve
oc logs -n $NS job/mongot-mongodb-search-helm-wait -c wait
```

## Tested on CRC

Oct 6, 2026, namespace `mongodb-poc`, OpenShift 4.22.7, Helm 4.3.0, with [`examples/values-crc.yaml`](../chart/mongodb-search-helm/examples/values-crc.yaml) as it then was (2Gi, 1Gi requested, no monitoring values). The five prerequisites were the ones already in the lab, used as they were.

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

The script's own tests ([`test/prerequisites.sh`](../test/prerequisites.sh), 183 checks, no cluster) pass with OpenSSL 3.6.4, OpenSSL 4.0.3 and LibreSSL 3.3.6, under bash 5.3.20 and under bash 3.2.57, in all six pairings (Oct 22, 2026, chart 0.3.35).

Not tested:

- A cluster where the operator is installed by someone else (`operator.install=false`).
- What [`argocd.md`](../chart/mongodb-search-helm/argocd.md) lists as not run under Argo CD: a change of `operator.version`, a namespace shared with other operators' Subscriptions, `selfHeal`, and an application controller that is not a cluster administrator.
- Anything in `dvh-gp6-rnd`.
