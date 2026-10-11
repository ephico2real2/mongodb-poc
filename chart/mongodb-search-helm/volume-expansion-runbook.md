# Runbook: growing mongot's volumes

How the volumes under mongot's indexes are grown with this chart: the size is changed in the values, synced, and
then the volumes themselves are grown by hand with the script beside this file. Nothing in it deletes a volume or
rebuilds an index, and searches are answered throughout.

For operator 1.13.0 (MongoDB Controllers for Kubernetes), mongot 1.70.1, OpenShift 4.20 to 4.22. What was run
where, and what was not run anywhere, is at the end.

## Why it takes steps by hand

| Fact | Source |
| --- | --- |
| The operator has no resize. A new size in the MongoDBSearch would have to change the StatefulSet's volume claim template, and Kubernetes forbids that: "updates to statefulset spec for fields other than 'replicas', 'ordinals', 'template', 'updateStrategy', 'revisionHistoryLimit', 'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden" | The lab, 2026-10-09; Kubernetes 1.35 `ValidateStatefulSetUpdate`; [mongodb/mongodb-kubernetes #1621](https://github.com/mongodb/mongodb-kubernetes/pull/1621) |
| So after the size changes in the values, the MongoDBSearch is `Failed` and the operator can change nothing on mongot until the StatefulSet is made again. **The pods run and answer as before** | The lab: a search returned its 20,024 documents while the resource was `Failed` |
| A volume claim itself can be grown while its pod runs, when its storage class allows it | Kubernetes, [Expanding Persistent Volumes Claims](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims); OpenShift, [Expanding persistent volumes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/storage/expanding-persistent-volumes) |
| A StatefulSet deleted with `--cascade=orphan` leaves its pods and claims in place, and the operator makes it again at the new size and adopts them | The lab, four times: made again within 2 s, the same pods (no restart), the same claims |
| A StatefulSet deleted **without** `--cascade=orphan` takes every pod and, by the operator's policy for it, every volume | [volumes.md](volumes.md) |

## The whole of it

| # | Step | Where | Changes |
| --- | --- | --- | --- |
| 0 | Check before starting | The cluster, read only | Nothing |
| 1 | Change `search.persistence.storage` in the values, in git | Git | The values |
| 2 | Sync (Argo CD) or `helm upgrade`. **It stops at the gate, by design** | Argo CD or Helm | The MongoDBSearch asks for the new size and is `Failed`. Pods untouched |
| 3 | Grow each volume claim, one pod at a time: `--expand` | The script | Each claim, and the volume behind it |
| 4 | Make the StatefulSet again: `--recreate-statefulset` | The script | The StatefulSet object only |
| 5 | Sync or upgrade again: the gate passes | Argo CD or Helm | Nothing new |
| 6 | Verify and write down | The cluster, read only | Nothing |

Allow an hour without hurry. On the lab the whole of it took 2 min 4 s under Argo CD, from the start of the first
sync to its retry passing, on an NFS class where a claim grows within a second because only its number changes. How
long a disk takes to grow on your storage is not known here.

```bash
export TargetNamespace=<the namespace>
X=<the chart>/expand-mongot-volumes.sh       # helm pull <chart> --untar, or a clone
STS=<search name>-search-0                   # mongot-search-0 with the chart's default name
```

## Letting the chart take steps 3 to 5: `search.persistence.autoExpand`

With `search.persistence.autoExpand.enabled: true` a Job of the chart takes steps 3 and 4 itself, with the same
script, and the gate passes in that same sync or upgrade: step 5 is not needed. The flag is `false` in the chart and
is meant to stay `false` in git: it is set for the change that grows the volumes, and taken out after.

| # | Step | Changes |
| --- | --- | --- |
| 0 | Check before starting: step 0 below, all of it | Nothing |
| 1 | In the values: the larger `search.persistence.storage` | The values |
| 2 | In the values: `search.persistence.autoExpand.enabled: true`. In the same change as the size, or in a later one | The values |
| 3 | Sync, or `helm upgrade`. The Job runs after the MongoDBSearch and before the gate | Each claim, one pod at a time; then the StatefulSet object |
| 4 | Verify: step 6 below | Nothing |
| 5 | `autoExpand.enabled: false` again, and sync or upgrade | The Job's service account, role and script are removed (under Argo CD without automated pruning: by a sync with pruning) |

```yaml
search:
  persistence:
    storage: 400Gi        # was 300Gi
    autoExpand:
      enabled: true       # for this change only
```

**Either order works.** With the size and the flag in one change, one sync does everything. With the size first, that
sync stops at the gate as in step 2 below, the resource is `Failed`, and the sync that carries the flag finds it so
and goes on from there.

**Under Argo CD, what starts that sync.** A hook Job is not an object Argo CD compares, so the flag alone starts
a sync only through the Job's four other objects: its script (a ConfigMap), service account, role and binding. Set
after the size, on a cluster that never had them, they are new and the Application is `OutOfSync`. Where an earlier
growth left them (an Application without automated pruning), the size written on the script's ConfigMap is what
differs. If the Application still reads `Synced` after the flag is in git (the same size as the last time it was
on), sync it by hand: a hook runs in every sync. With automated sync, a sync that stopped at the gate is first
tried again five times (11 minutes on the lab) before the one that carries the flag begins; ending that operation
in the console brings it forward.

**What the Job acts on.** One state only: the MongoDBSearch is `Failed`, the operator names Kubernetes' refusal of
the StatefulSet update, and the two sizes differ. On a first install, on a sync that changes no size and on any
other failure it prints "nothing to grow" and ends well; the script is not run.

**What the Job may do.** In the release's namespace: read the MongoDBSearch, the StatefulSet, the pods and the
claims; ask a claim for more; and delete the mongot StatefulSet, by name. It may not delete a pod or a claim. The
delete of the StatefulSet is the one the script sends with `--cascade=orphan`; a role cannot say "with that flag
only", which is why the flag is on for one change and not always.

**When the Job fails**, the sync or upgrade fails with it, nothing has been deleted unless its log says the
StatefulSet was, and the pods run as before. Its log holds the script's own words: the tables of steps 3 and 4 below
say what each means. Put right what it names and sync again, or go on by hand from step 3: the script does not
repeat what is done.

```bash
oc logs job/<release>-mongodb-search-helm-expand-volumes -n $TargetNamespace
```

It does not restart a pod: a claim that waits for its pod (`FileSystemResizePending`, step 3) stops the Job, and
that pod is deleted by hand as step 3 says, before the next sync.

## 0. Before starting

All of these must hold. Stop if one does not.

| Check | How | Must be |
| --- | --- | --- |
| Every mongot pod is Ready, and the resource is `Running` | `bash $X --check --statefulset $STS` | "3 of 3 pods ready"; "MongoDBSearch ... is Running" |
| Every index is `STEADY` on every pod | The dashboard: *Indexes not STEADY* is green; *Indexes being built* is 0 | No build or recovery under way |
| The operator runs | `oc get pods -n <the operator's namespace> \| grep mongodb-kubernetes-operator` | `1/1 Running`. It is what makes the StatefulSet again in step 4 |
| The storage class can grow a volume | The same `--check`: "(expands: true)" on every line | `true`. OpenShift's `thin-csi` for vSphere ships with `allowVolumeExpansion: true`; a cluster may have changed it. `true` says the class permits it, not that its driver can: step 3's table has what a driver without a resizer does |
| The new size is larger than what every claim has | The same `--check`: "has ..." | A volume cannot be made smaller, ever, and the chart does not support it: the preflight refuses a size under the one the StatefulSet's volumes were made at, before anything is changed |
| No claim is being resized | The same `--check`: "conditions []" | Empty |
| No snapshot of the disks | Ask the vSphere administrator | VMware: "Expanding volume is not supported when volume snapshot is present, and when a Node VM snapshot is present with the volume attached to it" |
| The datastore has room for the growth of every pod's volume | Ask the vSphere administrator: it cannot be seen from the cluster | Pods times (new size less old size) |
| vSphere is new enough to grow a disk in use | Ask the vSphere administrator | OpenShift: "Online expansion is supported from VMware vSphere version 8.0 Update 1 and later, or VVF 9, or VCF 9." Older: the file system grows when the pod is started again (step 3) |
| Nobody else is changing this release | Your change process | One change at a time |

Write down what `--check` prints. It is the "before".

**Recommended on `thin-csi`: keep the disks whatever happens.** That class ships with `reclaimPolicy: Delete`: if a
volume claim is ever deleted, its disk and its index go with it. The reclaim policy of a volume that exists can be
changed, and `Retain` keeps the disk when its claim is deleted
([Change the Reclaim Policy of a PersistentVolume](https://kubernetes.io/docs/tasks/administer-cluster/change-pv-reclaim-policy/)).
It needs a cluster administrator, once for each mongot volume; `--check` prints each volume's name and its policy:

```bash
oc patch persistentvolume <the volume's name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

A retained volume is not removed when it is no longer wanted: that is then done by hand.

## 1. Change the size in the values

```yaml
search:
  persistence:
    storage: 300Gi        # was 250Gi
```

Nothing else in the same change: not the replicas, not the resources, not the chart's version.

## 2. Sync, or upgrade

With Argo CD, sync the application. With Helm:

```bash
helm upgrade <release> <chart> -n $TargetNamespace -f my-values.yaml --timeout 20m
```

**The sync or the upgrade ends as failed, within about a minute, and that is expected.** The chart's gate (a
Sync hook in the last wave in Argo CD, a post-upgrade hook in Helm) stops with:

```text
[wait] STOPPED: search.persistence.storage is now 300Gi and the StatefulSet mongot-search-0 still has 250Gi.
[wait] Nothing is broken: the mongot pods run and answer as before. The operator cannot change the size of a running StatefulSet.
[wait] Next: volume-expansion-runbook.md in the chart, from "After the sync". Then sync or upgrade again, and this gate passes.
```

| Now | State |
| --- | --- |
| The MongoDBSearch | Asks for the new size; `status.phase` is `Failed`, with Kubernetes' "Forbidden" sentence above in `status.message`. The operator tries again every few seconds, and fails the same way |
| The StatefulSet, the pods, the claims | Exactly as before. Searches are answered |
| The release | Helm: `failed`. Argo CD: the sync failed at its hook |
| What does not work until step 4 | Any other change to mongot through the operator: resources, version, an operator upgrade |

Do not try to mend the `Failed` resource in any other way. In particular **do not delete the StatefulSet with a
plain `oc delete`, and do not scale it**: either deletes volumes.

**Under Argo CD with automated sync, the failed sync is tried again by itself**, five times, over 11 minutes on
the lab; each attempt stops at the gate in the same way. If steps 3 and 4 are finished before the last attempt,
that attempt passes and step 5 is done for you: on the lab the first retry passed, 27 s after step 4. Once the
five are spent the operation reads `Failed` and Argo CD does not sync that revision again by itself, not after
step 4 either: the Application reads `Synced`, so there is nothing for it to do. Step 5 is then a sync by hand.
On a real cluster, where a disk takes time to grow, expect that.

To back out here: put the old size back in the values and sync. The resource returns to `Running` and the gate passes: on the lab, 32 seconds, with the StatefulSet and the pods untouched.

## After the sync

### 3. Grow the volume claims, one pod at a time

First what it would do, changing nothing:

```bash
bash $X --expand --statefulset $STS --dry-run
```

It reads the size from the MongoDBSearch, which now holds what the values ask for, so the size is typed nowhere
twice. For each pod it prints the one request it would send. Then:

```bash
bash $X --expand --statefulset $STS --apply
```

It asks for the namespace to be typed back, then takes the pods in order, the lowest first. For each: it asks the
claim for the new size, waits until the claim has it and no resize is under way, checks that the pod is Ready, and
prints the size of the file system the pod sees. Only then the next pod. Where the pods share one file system (an
NFS export, a hostpath provisioner), that last figure is the shared file system's and stays as it was: the claim's
size is then a number and nothing more. It prints, for example:

```text
pod 0: asking claim data-mongot-search-0-0 for 300Gi (it asks 250Gi, has 250Gi)
  data-mongot-search-0-0: has 250Gi, conditions [Resizing]
  data-mongot-search-0-0: has 300Gi
pod 0: claim data-mongot-search-0-0 has 300Gi, pod mongot-search-0-0 is Ready; the pod's file system: 300G at /mongot/data, 61% used
pod 1: asking claim data-mongot-search-0-1 for 300Gi ...
```

To take the pods one by one yourself, with a look at the dashboard between them:

```bash
bash $X --expand --statefulset $STS --pod 0 --apply
bash $X --expand --statefulset $STS --pod 1 --apply
bash $X --expand --statefulset $STS --pod 2 --apply
```

It can be run again at any point: a claim that has the size is skipped, and one that was asked already is waited
for, not asked twice.

**mongot needs no restart for this.** It reads the size of its file system every 5 seconds (`PeriodicDiskMonitor`
in its source), so *Data volume used* on the dashboard falls within a scrape or two. If mongot had stopped
following the source because the volume was over 90% used, it starts again by itself once the use is under 85%.

| If it stops with | It means | Do |
| --- | --- | --- |
| `allowVolumeExpansion is false` | The storage class cannot grow a volume. Nothing was changed | A cluster administrator sets `allowVolumeExpansion: true` on the class, if its driver supports it. Then run again |
| `FileSystemResizePending for ... s`, exit 3 | The disk has grown, and its file system grows only when the pod starts again: a driver or a vSphere without online expansion | Run again with `--restart-if-pending`. It deletes that one pod, which keeps its claim and comes back on it, and waits for it. One pod at a time, as before |
| `the resize has failed [... Error]`, exit 2 | The storage refused: usually no room on the datastore, or a snapshot | `oc describe pvc <claim> -n $TargetNamespace` says why. Clear the cause; Kubernetes tries again by itself. A size that can never be met is withdrawn by asking the claim for a smaller size that is still above what it has (Kubernetes, "Recovering from Failure when Expanding Volumes"), and by putting that size in the values |
| `not at ... within 900 s`, exit 2 | Slow, or stuck without saying so | Look at the claim's events (`oc describe pvc`). Run again to go on waiting: the request stands. `--wait <seconds>` allows more. A class that allows expansion over a driver with no resizer ends here, with the one event `ExternalExpanding`, "waiting for an external controller to expand this PVC", for good: seen on the lab's hostpath class ([enhancement/README.md](../../enhancement/README.md), step A5) |
| `pod ... is not Ready` | A pod is not healthy | Find out why first. Nothing was changed for that pod's claim |

It stops before the next pod in every one of these, so at most one volume is ever mid-way.

There is no way back in this step: a volume that has grown stays grown. A run that stopped with some pods done and
others not leaves the cluster safe as it is, since a larger volume harms nothing. Clear the cause and finish the
remaining pods.

### 4. Make the StatefulSet again

Every claim now has the new size; the StatefulSet's template still names the old one, and the resource is still
`Failed`.

```bash
bash $X --recreate-statefulset --statefulset $STS --dry-run
bash $X --recreate-statefulset --statefulset $STS --apply
```

It refuses unless every pod is Ready and every claim has the size the resource asks for. Then it runs one command,
`oc delete statefulset <name> -n <namespace> --cascade=orphan --wait=false`, waits itself for the operator to make
the StatefulSet again (no longer than `--wait`), and compares the pods and the claims with what they were. It does
not let `oc` do the waiting: `oc` waits for a StatefulSet of that name to be gone, and the operator makes one of the
same name within a second.

```text
StatefulSet mongot-search-0 was made again at 300Gi; MongoDBSearch mongot is Running
the pods are the same pods: none was restarted
the volume claims are the same claims
done. Sync or upgrade the chart again: its gate passes now
```

| If it says | It means | Do |
| --- | --- | --- |
| `grow the claims first` | A claim does not have the size yet | Step 3 |
| `the operator has not made StatefulSet ... again within ... s` | The operator is down or stuck. **The pods run on without a StatefulSet and nothing is lost** | Look at the operator's pod and its log. When it runs, it makes the StatefulSet. Do not delete the pods, and do not create a StatefulSet by hand |
| `NOTE: the pods are not the same as before` | The operator's new StatefulSet differs from the old one in more than the size, and Kubernetes is restarting the pods one at a time, each on its claim | Wait for the three to be Ready. Seen on the lab once, after a setting had been patched by hand earlier |
| `WARNING: the volume claims ... are not the same as before` | A claim was replaced. This should not happen | Stop. `oc get pvc,pv` and the events of the namespace; if the volumes were retained (step 0), their disks are still there |

**Never do this step by hand without `--cascade=orphan`.**

### 5. Sync or upgrade again

The same sync, or the same `helm upgrade` with the same values. Nothing changes in the cluster; the gate runs and
passes, and the release is `deployed` again. Under Argo CD: a sync by hand, unless a retry of the first sync has
passed already (step 2). Check the operation, not the Application's `Synced` and `Healthy`, which it showed all
through the failed attempts:

```bash
oc get application <name> -n <argo cd's namespace> -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}'
```

`Succeeded: successfully synced (no more tasks)`.

### 6. Verify, and write down

```bash
bash $X --check --statefulset $STS
```

| Must be | |
| --- | --- |
| The StatefulSet's template, the MongoDBSearch and every claim name the new size | "volume claim template data at 300Gi"; "asks for 300Gi, is Running"; "asks 300Gi, has 300Gi" three times |
| Every pod is Ready, on a file system of the new size | "pod Ready"; "the pod's file system: 300G ..." |
| The dashboard | *Data volume used* lower on every pod; *Indexes not STEADY* green; *Replication lag* as before |
| The volume alert, if it was firing | Resolves when the use is under its level |

Keep the "before" and the "after" of `--check` with the change.

## Never, during this

- `oc scale statefulset ...`, or a change of `search.replicas`: a pod that is scaled away loses its volume.
- `oc delete statefulset ...` without `--cascade=orphan`: every pod and every volume go.
- `helm uninstall`, or deleting the MongoDBSearch.
- `oc patch` or `oc edit` on the MongoDBSearch: the size goes in through the values. A field patched by hand stays
  owned by that patch, and the next sync or upgrade that changes it is refused with a conflict.
- `oc rollout restart statefulset ...`: three restarts for nothing.
- A second change in the same sync.

## The other order: the volumes first, the values after

MongoDB's own procedure grows the claims first and records the size afterwards. It works with this chart too, and
keeps the resource `Running` for longer; the values in git then lag behind the cluster for the length of step 3,
which is why this runbook has the values first.

```bash
bash $X --expand --statefulset $STS --size 300Gi --apply     # the resource still asks for the old size: name the new one
# then steps 1 and 2 (the sync stops at the gate), then 4, 5 and 6
```

## What was run, and where

One run from start to finish, with every command's output and the OpenShift console at each stage:
[docs/testing-mongot-storage-resize.md](docs/testing-mongot-storage-resize.md).

| What | Where | Result |
| --- | --- | --- |
| Steps 1 and 2: the size changed in the values, the gate | The lab, 2026-10-09, with `helm upgrade` | The resource `Failed` with the "Forbidden" sentence; the gate stopped in 32 s with the message above; the pods untouched; a search answered |
| The same before the gate knew this state | The lab | The gate waited out the upgrade's 4 minutes and the release was `failed`: why the gate now says what it is |
| Step 4: `oc delete statefulset --cascade=orphan` | The lab, four times | Made again within 2 s at the new size; the resource `Running` within 6 s; the same three pods, not restarted; the same three claims |
| Step 5: the same upgrade again | The lab | Passed in 31 and 36 s; the release `deployed` |
| Backing out of step 2: the old size put back | The lab | The resource `Running` again and the upgrade passed in 32 s; the StatefulSet and the pods untouched |
| A pod deleted keeps its claim | The lab | The same claim, Ready in 24 s |
| The script | `test/expand-volumes.sh`, 53 checks against a stand-in `oc`, under bash 5 and bash 3.2, in CI on Linux and macOS | Every refusal changes nothing; one claim at a time; a pending or failed resize stops before the next pod; the one delete always has `--cascade=orphan` |
| The script's `--check` and `--dry-run` | The lab | Read the three sizes, the class, the volumes and the pods' file systems |
| A class that does not allow expansion | The lab: its NFS class as it was found, 2026-10-10, and its hostpath class the day before | The API refused: "only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize". On the NFS class the script refused first: "allowVolumeExpansion is false: Kubernetes will not grow it. Nothing was changed for this claim" |
| **The whole runbook, steps 0 to 6, under Argo CD**, 4Gi to 5Gi | The lab, 2026-10-10, 15:25Z to 15:28Z, on an NFS class (driver `nfs.csi.k8s.io`, csi-driver-nfs 4.13.4 with csi-resizer 2.2.0) once `allowVolumeExpansion: true` had been set on it; automated sync | The sync stopped at the gate about 50 s after it began. `--expand --pod 0`, then `--expand` for the rest: each claim had 5Gi within a second of being asked, with the events `Resizing` and `VolumeResizeSuccessful`. `--recreate-statefulset`, 7 s: "made again at 5Gi; MongoDBSearch mongot is Running", "the pods are the same pods: none was restarted", "the volume claims are the same claims". Argo CD's first retry passed the gate: `Succeeded` 2 min 4 s after the sync began (15:25:54Z to 15:27:58Z), with no sync by hand. 27 searches through mongod were tried, one every 5 to 6 s, and all were answered |
| `--recreate-statefulset` before every claim has grown | The lab, in that run | Refused: "claim data-mongot-search-0-1 has 4Gi, less than 5Gi: grow the claims first (--expand)" |
| **The other order**, 5Gi to 6Gi: `--expand --size 6Gi` one pod at a time, then the values | The lab, 15:29Z to 15:50Z, the same class | The three claims had 6Gi within 5 s in all; the resource stayed `Running` at 5Gi and the Application `Synced`. `--size 4Gi` was refused: "a volume cannot be made smaller". Then the size in git: the sync stopped at the gate |
| **The steps by hand outlasting Argo CD's retries** | The lab, in that run: step 4 was held back on purpose | Five retries, each stopped at the gate; the operation `Failed` 10 min 59 s after it began, the Application `Synced` and `Healthy` throughout. No new operation in the 200 s after a refresh. Step 4, 2 s, the resource `Running`: still no operation in 210 s. A sync by hand: `Succeeded` in 63 s. 225 searches tried in the 21 minutes, all answered; the same pods, not restarted, and the same claims from the first install to the end |
| **The same again, recorded**, 6Gi to 7Gi, values first | The lab, 15:56Z to 16:01Z, the same class | [docs/testing-mongot-storage-resize.md](docs/testing-mongot-storage-resize.md). Argo CD's second retry passed the gate, 3 min 36 s after the push; 42 searches tried, all answered; the same pods and claims |
| **What that class cannot show** | | An NFS volume is a directory of an export. The driver's answer to a resize is the size it was asked for and nothing else (its `ControllerExpandVolume`; its node part has no expansion), so only the claim's number changed: the pods read "9.8G at /mongot/data, 20% used" before and after, and *Data volume used* did not fall. A disk that takes time to grow, `FileSystemResizePending`, `--restart-if-pending` and a failed resize were **run nowhere by this repository**: they rest on Kubernetes', OpenShift's and VMware's documents below, on MongoDB's own test of the same steps (pull request 1621, open), and on the script's tests against a stand-in |
| Argo CD | Everything above. The back-out of step 2 was run under Argo CD earlier that day: [argocd.md](argocd.md). The hooks carry Argo CD's annotations (PreSync, and Sync at waves -3, -1 and 3) | |

Run step 3 first on a cluster where losing time costs nothing, and `--pod 0` before the rest: what the lab could
not show is exactly what differs on vSphere.

## Sources

- Kubernetes: [Expanding Persistent Volumes Claims](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims), with "Resizing an in-use PersistentVolumeClaim" and "Recovering from Failure when Expanding Volumes"; [StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/).
- OpenShift 4.20: [Expanding persistent volumes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/storage/expanding-persistent-volumes); [CSI drivers supported](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/storage/using-container-storage-interface-csi) for the vSphere versions.
- VMware: *Expanding a Volume with vSphere Container Storage Plug-in* (3.0), on techdocs.broadcom.com.
- MongoDB: [mongodb/mongodb-kubernetes pull request 1621](https://github.com/mongodb/mongodb-kubernetes/pull/1621), the manual resize it tests; [pull request 1273](https://github.com/mongodb/mongodb-kubernetes/pull/1273), the volume policy.
- mongot 1.70.1: `PeriodicDiskMonitor.java`, `HysteresisGate.java`, `DiskMonitorConfig.java`.
- csi-driver-nfs 4.13.4: `pkg/nfs/controllerserver.go`, `ControllerExpandVolume`; `pkg/nfs/nodeserver.go`,
  `NodeExpandVolume` ("Unimplemented").
