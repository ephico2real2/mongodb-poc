# Running the chart with Argo CD

This is how the chart is meant to be run: an Argo CD Application of it, the values in git, and a sync. This page
says what to put in the Application, what a sync does and in which order, what to do day to day, and what each
Argo CD operation did to the search and its volumes when it was run. Helm by hand is the same chart and remains
possible; it is not the subject here.

Everything under "run" below was run on the lab on 2026-10-10: OpenShift Local 4.22.7, OpenShift GitOps 1.22.0
(Argo CD 3.5.3), the published chart 0.3.17 (0.3.18 for "Changing, scaling and growing"), mongot 1.70.1 x3,
operator 1.13.0. The lab's indexes are 16 MiB a
pod: its times are the chart's and the operator's, not those of building large indexes.

## In short

- **One sync installs everything**, from a namespace with nothing of the chart in it: 127 s on the lab.
- **Set `search.keepOnUninstall: true` in the Application.** It keeps the MongoDBSearch, and so every mongot volume,
  through a prune and through the deletion of the Application. Both were run. Without it Argo CD deletes the
  MongoDBSearch like any other resource (not run), and a deleted MongoDBSearch takes every volume with it within
  seconds (run).
- **A change is a change in git, then a sync.** Never patch the MongoDBSearch by hand.
- **Argo CD does not stop** `oc delete mongodbsearch`, a sync with `Force` or `Replace`, or a lower
  `search.replicas` (the chart's preflight refuses that one: [volumes.md](volumes.md)).

## Before the first sync

1. **The five prerequisites** are in the namespace: the trust bundle, the three TLS secrets and the sync password
   secret. [`generate-mongodbsearch-prerequisites.sh`](generate-mongodbsearch-prerequisites.sh) makes them; the
   chart's preflight stops the sync if one is missing. Argo CD does not manage them.
2. **Argo CD may act in the namespace.** On the lab its application controller is a cluster administrator. A
   controller that gets its rights from the namespace (the label `argocd.argoproj.io/managed-by`) was not tried
   here: it needs to create and delete Roles and RoleBindings, an OperatorGroup, a Subscription, the MongoDBSearch,
   a Route, Jobs, ServiceMonitors, a PrometheusRule and the Perses objects there.
3. **The platform** is as for Helm: OLM with the certified catalog, user workload monitoring, and the Cluster
   Observability Operator for the console dashboard.

## The Application

[`examples/argocd-application.yaml`](examples/argocd-application.yaml) is the one to copy;
[`examples/argocd-application-crc.yaml`](examples/argocd-application-crc.yaml) is the lab's.

| Field | Value | Why |
| --- | --- | --- |
| `source.targetRevision` | A release tag, `mongodb-search-helm-<version>` | A sync then changes only when the tag is changed in git. The lab's follows `main` |
| `source.helm.releaseName` | `mongot` | The names of the OperatorGroup and of the hooks' objects start with the release name. Without it Argo CD uses the Application's name, and they would not be the ones a Helm release `mongot` made |
| `source.helm.skipCrds` | `true` | The MongoDBSearch CRD comes from OLM. Argo CD must not own it, or delete it with the Application |
| `source.helm.valueFiles` | The values file of the cluster | The values in git are the source of truth |
| `source.helm.parameters` | `search.keepOnUninstall=true` | Keeps the search through a prune and an Application delete. It may be set in the values file instead |
| `ignoreDifferences` | The Route's `/status` | The router writes it |
| `syncPolicy` | `{}`, `automated: {}` or `automated: {prune: true}` | All three were run with `search.keepOnUninstall=true`: below |

**What `search.keepOnUninstall: true` renders** on the MongoDBSearch: `helm.sh/resource-policy: keep`, which Argo
CD takes as `Delete=false`, and `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true,Prune=false,Delete=false`.
Argo CD reads both from the live object, so they hold after the resource has left the manifests.

**Which sync policy.** By hand (`{}`), a change waits for someone to press sync. `automated: {}` syncs every new
revision by itself and never prunes. `automated: {prune: true}` also removes what leaves the manifests, except the
MongoDBSearch, which it skips. `selfHeal` was not run. A `retry` policy is not needed from chart 0.3.17 on
for the ClusterServiceVersion an uninstall leaves.

## What a sync does, in order

| Phase and wave | What | Notes |
| --- | --- | --- |
| PreSync | The preflight Job, with its own ServiceAccount, Role and RoleBinding | Stops the sync if a prerequisite is missing, or if `search.replicas` would go down |
| Sync, wave -3 | The csv-reclaim Job and its access | Removes the operator's ClusterServiceVersion a previous uninstall left, when the namespace holds no Subscription of the operator's package. Otherwise it exits at once |
| Sync, wave -2 | The OperatorGroup; the access of the approver and of the gate | |
| Sync, wave -1 | The Subscription; the approver Job | The Subscription is on Manual approval; the approver approves the InstallPlan of `operator.version`, and no other |
| Sync, wave 0 | ServiceMonitors, the alert rules, the index info exporter, the Grafana ConfigMap | |
| Sync, wave 1 | The MongoDBSearch; the Perses dashboard and datasource | The operator makes the mongot StatefulSet, the Envoy Deployment and their Services |
| Sync, wave 2 | The Route | |
| Sync, wave 3 | The gate Job | Ends only when the operator, the mongot pods, Envoy and the Route are ready. It does not wait for the indexes to be built |

**The csv-reclaim hook under Argo CD.** The csv-reclaim hook runs in wave -3, ahead of the
OperatorGroup (-2) and the Subscription (-1), where under Helm it runs after them. Under Helm it deletes the
ClusterServiceVersion an uninstall left behind once OLM reports `ResolutionFailed` on the new Subscription. Argo CD
reads that condition as a Degraded Subscription and fails the sync, so there the hook acts earlier and on other
evidence: the namespace holds no Subscription of the operator's package. It deletes the same ClusterServiceVersion
(of this package, not a copy, without an owner, referenced by no Subscription, settled) and ends when it is gone.
A list of Subscriptions that fails, a Subscription of the package under another name and a Subscription whose
package cannot be read are not that evidence: nothing is deleted then. [`test/csv-reclaim.sh`](../../test/csv-reclaim.sh)
runs the hook's script against a stand-in `oc`. The hook removes one cause of `ResolutionFailed`, the left-behind
ClusterServiceVersion; a Subscription that cannot be resolved for another reason (a catalog that does not answer)
still fails the sync. And a sync that fails in wave -2, after the hook, leaves the namespace with no operator until
the next sync (from the order above; not run): before 0.3.17 the hook had not run by then, and the left-behind
operator went on running. The mongot pods go on running either way; nothing reconciles the MongoDBSearch until
the operator is back.

The Jobs are Argo CD hooks. After a sync that succeeds, the preflight Job and its ServiceAccount, Role and
RoleBinding stay until the next sync; Argo CD lists them as requiring pruning and the Application reads `Synced`
with them. The csv-reclaim, approver and gate Jobs are deleted when they succeed and stay only after a sync that
failed at them; every Job has `ttlSecondsAfterFinished` 600 s. By Argo CD's source (read, not run) a sync with
prune does not prune a live hook object.

## Day to day

Each of these starts in git and ends with a check.

| To do | In git | Then | Check |
| --- | --- | --- | --- |
| Install | The Application, the values file | Sync | The Application `Synced` and `Healthy`. `oc logs -n <namespace> job/mongot-mongodb-search-helm-wait` reads the gate only while it runs or after it failed: Argo CD deletes the Job when it succeeds |
| Change a value | The values file | Sync | The same. A change to the MongoDBSearch's resources restarts the mongot pods one at a time, each on its volume |
| Take a newer chart | `targetRevision` to the newer tag | Sync | The same |
| More mongot pods | `search.replicas` up | Sync | The new pod comes on a new volume claim and builds every index from the collection ([scaling.md](scaling.md), measured with `helm upgrade`; under Argo CD, Ready within 32 s on the lab's indexes) |
| Fewer mongot pods | `search.replicas` down and `search.allowVolumeLoss: true` for that sync | Sync | The preflight refuses it without the second value: each pod that goes loses its volume. [volumes.md](volumes.md). Take `search.allowVolumeLoss` out with the next commit: left in git it lets every later scale-down through |
| Bigger volumes | `search.persistence.storage` up | Sync, which stops at the gate by design, then the steps by hand. A retry of that sync passes if one is still to come; once the retries are spent, a sync by hand | [volume-expansion-runbook.md](volume-expansion-runbook.md) |
| Remove the Application and keep the search | Nothing | Delete the Application | The MongoDBSearch, its pods and its volumes stay. The Route, the Subscription and the monitoring go: below |
| Bring it back | The Application again | Sync | One sync adopts the search that was kept: 63 to 72 s on the lab |
| Remove the search for good | Take the Application out | Delete the Application, then `oc delete mongodbsearch <search.name> -n <namespace>` | Every mongot volume goes with it. Then `oc delete csv mongodb-kubernetes.v<version> -n <namespace>` removes the operator |

Every row was run under Argo CD (below), except the last row's `oc delete csv`.

**When a sync fails at a hook**, these were seen on the lab.

- **The reason is in the Job's log, not in Argo CD's message.** Argo CD says "Job has reached the specified backoff
  limit". A Job that failed is kept until the next attempt replaces it, and for `jobs.ttlSecondsAfterFinished`
  (600 s) after the last one ended: `oc logs -n <namespace> job/mongot-mongodb-search-helm-preflight`, or
  `...-wait` for the gate. After that only Argo CD's message is left; the hooks run again on a new commit or a
  sync by hand.
- **Automated sync tries a failed sync again, five times.** With `automated: {}` and no `retry` of its own, Argo CD
  gives the sync a retry limit of 5 with a back-off of 5 s doubling to 3 minutes (its source, not its
  documentation; a sync by hand retries only with `--retry-limit`). Each attempt runs every hook again and begins
  later than the time in Argo CD's message, up to 1.5 minutes on the lab: the refused scale-down was retried at
  08:16:52, 08:17:30, 08:18:30, 08:20:07 and 08:23:02, the stopped volume change at 08:30:32, 08:31:57, 08:33:41,
  08:35:59 and about 08:39:45. The operation reads `Running` the whole time, 7 and 11 minutes on the lab, with the
  message "one or more synchronization tasks completed unsuccessfully. Retrying attempt #N at ..."; it reads
  `Failed` only once the five are spent, and that revision is not synced again by itself: a new commit, or a sync
  by hand. Run on the lab with a volume change whose five retries were left to run out (15:29:35Z to 15:40:34Z,
  the retries beginning about 15:30:46, 15:32:08, 15:33:45, 15:36:03 and 15:39:37): no new operation in the
  200 s after a refresh, nor in the 210 s after the cause had been cleared and the MongoDBSearch read `Running`.
  The Application read `Synced` all the while, so automated sync had nothing to do.
- **A commit that corrects it waits for those attempts to end.** Argo CD starts no sync while an operation is in
  progress, and the retries keep the revision that failed. On the lab the corrected scale-down was synced 49 s
  after its push and the back-out 7 s after its, both pushed near the end of the fifth attempt; a push right after
  the first failure waits for all five.
- **`Synced` and `Healthy` do not mean the sync passed.** While the gate was failing on a changed volume size the
  Application read `Synced` and `Healthy`, and the MongoDBSearch read `Failed`: Argo CD has no health check for a
  MongoDBSearch. While the preflight was refusing a scale-down it read `OutOfSync` and `Healthy`. Read the
  operation's phase and message, `oc get application <name> -n <argo cd's namespace> -o
  jsonpath='{.status.operationState.phase}: {.status.operationState.message}'`, and the resource's own, `oc get
  mongodbsearch -n <namespace>`, with `-o jsonpath='{.status.message}'` for the reason when it reads `Failed`.
  `Pending` is its phase while a change is in progress, through every rolling restart and scale below. The first
  40 s of a sync are the hooks; the MongoDBSearch changes after them.

While the MongoDBSearch is live and no longer in the manifests, the Application stays `OutOfSync` and a sync with
prune reports it as "ignored (no prune)".

## What each operation did

All with `search.keepOnUninstall=true` and `examples/values-crc.yaml`, on the published chart 0.3.17 except where
a commit is named. The control plane's restart counts were read before and after every step of the two tables
below and did not move; the 0.3.15 row further down is from the earlier run that night, whose counts were not
read. Times are UTC, 2026-10-10. Until 15:16Z that day the lab's mongot volumes were on its hostpath class, which
retains a volume and cannot grow one; after it, on an NFS class (driver `nfs.csi.k8s.io`), where the last table's
rows were run.

### Installing and syncing

| Operation | Result |
| --- | --- |
| **A first install**: the namespace with the prerequisites and nothing of the chart; one sync by hand | `Succeeded` in 127 s (07:22:12Z to 07:24:19Z). 31 resources. The Subscription read `UpgradePending`, then `AtLatestKnown`. Argo CD created the MongoDBSearch; the three mongot pods started 25 to 28 s apart. A search through mongod answered within 15 s of the sync's end; `test/run.sh search` passed 15 of 15; at 07:29Z, after the Application had been deleted and Helm had taken the resource over, the same three pods each read all 8 indexes `STEADY` |
| **Taking over from a Helm release**: `helm uninstall` with the value set, then the Application and one sync | `Succeeded` in 68 to 72 s, three times (one of them, 71 s, from the chart's commit `954968f` before its release). The MongoDBSearch read `Synced` before the first sync: the live object is what the chart renders. The same pods and volumes, no restart |
| **A sync with nothing to change** | `Succeeded` in 55 s, from the chart's commit `71e6fc8` before its release: the hooks run each time. A sync that moved the chart from 0.3.16 to 0.3.17: 49 s |
| **Automated sync** (`automated: {}`), the Application created over a search that was kept | Argo CD started one sync by itself: `Succeeded` in 63 s |
| **Another storage class**: the MongoDBSearch deleted by hand (the row under *Pruning and deleting*), then `search.persistence.storageClass` changed in git, chart 0.3.19 | Argo CD started one sync by itself within seconds of being pointed at the commit: `Succeeded` in 118 s (15:17:56Z to 15:19:54Z). A new MongoDBSearch, three new claims `Bound` on the new class. A search through mongod answered at the reading 74 s after the sync began, the three before it did not; the resource read `Running` after 107 s. `test/run.sh search` passed 15 of 15, and at 15:21Z each pod read all 8 indexes `STEADY` |

In every one of these the Subscription and the ClusterServiceVersion were read every 3 to 4 s, and
`ResolutionFailed` was `True` in none of the readings.

### Pruning and deleting

| Operation | Result |
| --- | --- |
| **Automated sync with prune** (`automated: {prune: true}`), the Application pointed at a revision of the chart without the MongoDBSearch template | Argo CD started one sync by itself: `Succeeded` in 52 s. The MongoDBSearch: `PruneSkipped`, "ignored (no prune)". Watched for 330 s: no second sync. The Application stayed `OutOfSync` |
| **A sync of the whole Application with prune, by hand**, at that revision | `Succeeded` in 53 s. The MongoDBSearch: `PruneSkipped`, "ignored (no prune)" |
| **The Application deleted** with the finalizer `resources-finalizer.argocd.argoproj.io` | Gone after 36 s, each of five times. Deleted: the Route, the OperatorGroup, the Subscription, the monitoring objects. Kept: the MongoDBSearch, its three mongot pods and its volumes. The operator's pod kept running and its ClusterServiceVersion read `Failed`, `NoOperatorGroup`, within 2 minutes. Searches through mongod went on being answered each time they were tried; after a `helm uninstall`, which removes the same Route, a new connection to the Route's host got no answer ([volumes.md](volumes.md)) |
| **The MongoDBSearch deleted by hand**, `oc delete mongodbsearch` | The StatefulSet gone after 1 s; the three mongot pods and their three volume claims after 12 s; the two Envoy pods after 62 s. The volumes read `Released`: the lab's storage class retains them. On a class whose reclaim policy is `Delete`, `thin-csi` among them, the disks go with the claims (not run: the lab's class retains). Run again at 15:16Z with `automated: {}` and no `selfHeal`: Argo CD did not make the resource again. The Application read `OutOfSync` and started no operation in the minute and a half until it was pointed at a new commit |

### Changing, scaling and growing

Each as a commit to the values file on the branch the lab's Application followed, synced by Argo CD itself
(`automated: {}`), chart 0.3.18. A search through mongod was tried every 6 to 7 s throughout, 252 in all, and
every one was answered with its 8 results; each search goes to one mongot pod, so this says the search kept
answering, not that every pod did.

| Operation | Result |
| --- | --- |
| **A value changed**: the mongot memory request, 1100Mi to 1200Mi | One sync, `Succeeded` in 144 s (08:12:19Z to 08:14:43Z). The three mongot pods were restarted one at a time, the highest number first, about 33 s each, every one on its own volume claim. 28 searches tried |
| **Fewer mongot pods** (`search.replicas` 3 to 2), without `search.allowVolumeLoss` | The sync failed at the preflight. Its log: "REFUSED: search.replicas would go from 3 to 2 ... To do it knowingly, set search.allowVolumeLoss=true for this one upgrade. Nothing was changed". The same three pods and claims. 46 searches tried |
| **Fewer mongot pods**, with `search.allowVolumeLoss: true` | One sync, `Succeeded` in 65 s. The third pod and its volume claim were gone 13 s after the pod began to go. The preflight's log: "the volumes of the pods that go are deleted". 24 searches tried |
| **More mongot pods**: back to 3 | One sync, `Succeeded` in 71 s. The third pod came back on a new volume claim and was Ready within 32 s of appearing. 17 searches tried |
| **Bigger volumes**: `search.persistence.storage` 4Gi to 5Gi | The sync failed at the gate, as it is meant to. Its log: "STOPPED: search.persistence.storage is now 5Gi and the StatefulSet mongot-search-0 still has 4Gi. Nothing is broken: the mongot pods run and answer as before ... Next: volume-expansion-runbook.md in the chart". The MongoDBSearch read `Failed`; the same pods and claims. 92 searches tried in the 10 minutes it was left that way |
| **The back-out**: the old size in git | One sync, `Succeeded` in 60 s; the MongoDBSearch `Running` again 54 s after the push; no pod restarted. 17 searches tried |

### Growing the volumes to the end

[volume-expansion-runbook.md](volume-expansion-runbook.md), steps 0 to 6, with the chart's script for every step
by hand. Chart 0.3.19 and the lab's values on a branch, `automated: {}`; the mongot volumes on an NFS class
(`nfs.csi.k8s.io`, csi-driver-nfs 4.13.4) that allows expansion. A search through mongod was tried every 5 to
6 s, 252 in all (by chance the morning's count too), and every one was answered with its 8 results. The three mongot pods were the same pods from the
install to the end, with no restart, on the same three claims.

| Operation | Result |
| --- | --- |
| **Values first**, 4Gi to 5Gi: the size in git | The sync began at 15:25:54Z, after a refresh, and stopped at the gate about 50 s later (its Job failed at 15:26:47Z), the MongoDBSearch `Failed`. The claims were grown from 15:27:00Z, each within a second of being asked; the StatefulSet was made again from 15:27:24Z to 15:27:31Z and the resource read `Running`. Argo CD's first retry, already running, passed the gate: `Succeeded` at 15:27:58Z, retry count 1, with no sync by hand |
| **Volumes first**, 5Gi to 6Gi: the claims grown before anything in git | The resource stayed `Running` at 5Gi and the Application `Synced`: Argo CD does not track the claims. Then the size in git, pushed at 15:29:33Z: the sync stopped at the gate as before |
| **The retries left to run out**, the StatefulSet step held back | `Failed` at 15:40:34Z, 10 min 59 s after it began. The StatefulSet made again at 15:44:40Z, 2 s, the resource `Running`. Argo CD started nothing. One sync by hand at 15:48:29Z: `Succeeded` in 63 s |

On that class a claim's size is a number: [the runbook's last table](volume-expansion-runbook.md#what-was-run-and-where)
says what it could not show.

### Charts before 0.3.17

| Operation | Result |
| --- | --- |
| Chart 0.3.15: the first sync over the operator's ClusterServiceVersion an uninstall had left | `Failed`. The operator was installed, and Argo CD failed the Subscription's task on its health, `ResolutionFailed \| True`: the condition the csv-reclaim hook then waited for. A second sync passed. [Issue #101](https://github.com/ephico2real2/mongodb-poc/issues/101) |
| Chart 0.3.16, automated sync with `retry: {limit: 3}`, the same situation | The first attempt failed the same way, Argo CD retried once, and the sync `Succeeded` after 106 s in all |
| Chart 0.3.17, the same situation | One sync, `Succeeded` in 63 to 72 s, five times (two of them from the chart's commits `954968f` and `71e6fc8` before its release): the hook runs in wave -3 and removes the ClusterServiceVersion before the Subscription is made |

## Between Helm and Argo CD

A cluster run by Argo CD does not need this. It is here for a cluster that was installed with Helm.

- **From a Helm release to Argo CD**: `helm upgrade` with `search.keepOnUninstall=true`, `helm uninstall` (Helm
  answers "These resources were kept due to the resource policy: [MongoDBSearch] mongot"), then the Application
  with the same `releaseName`, and one sync (two with chart 0.3.15: the table above). Run four times, the first with chart 0.3.15: the same pods and volumes
  each time.
- **From Argo CD back to a Helm release**, when Argo CD created the MongoDBSearch: `helm install` refuses it
  ("invalid ownership metadata", in 2 s, nothing changed). `helm install --take-ownership` with the same values
  adopted it in 45 s, and left Argo CD's `tracking-id` and `last-applied-configuration` annotations on it. The first upgrade that changes a field of it then fails on a conflict with
  `argocd-controller` until it is run with `--force-conflicts`.
- **`helm install` over an operator ClusterServiceVersion that was left behind** takes Helm's path, as before:
  the hook waits for `ResolutionFailed`, removes it, and the install goes through in one go (40 to 103 s).
- **After that, do not trust the live annotation.** The MongoDBSearch went on carrying `helm.sh/resource-policy:
  keep`, which Argo CD's controller also owns, after the release had `search.keepOnUninstall: false`. Helm goes by
  the release's own manifest: `helm uninstall` deleted the MongoDBSearch and its volumes within 11 s. Read
  `helm get values`, not the object.

## Not run

- A change of `operator.version` under Argo CD.
- A volume with a file system of its own growing, as a vSphere disk does. The runbook was run to the end on an
  NFS class, where a claim's size is a number: the driver answers a resize within a second and the pods see the
  NAS export, the same before and after. So the wait for a disk to grow, `FileSystemResizePending`, a pod started
  again for it and *Data volume used* falling were not seen.
- A change of `search.persistence.storageClass` on a search that exists. The class is in the StatefulSet's volume
  claim template, which Kubernetes does not let change, so it was changed only after the search had been deleted.
- A namespace that also holds Subscriptions of other operators: the chart's hooks are tested for it against a
  stand-in only ([`test/csv-reclaim.sh`](../../test/csv-reclaim.sh)).
- `selfHeal`, and a sync with `Force` or `Replace`: what [volumes.md](volumes.md) says of those is from Argo CD's
  documentation and source.
- An application controller that is not a cluster administrator.
- Values kept outside this repository (a second source, or `valuesObject` in the Application).
- A cluster other than the lab. There a first install, a pod without its volume and a scale-up build indexes for
  as long as the data takes: on the owner's QA cluster, about 180 to 190 GB a pod, 4 to 5 hours for one pod.

An earlier run that night (03:14Z to 04:00Z) coincided with the lab's control plane restarting; its durations were
many times longer and are not used here.
