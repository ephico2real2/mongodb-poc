# What happens to mongot's volumes

Each mongot pod keeps its indexes on a volume of its own. This page says which actions keep that volume and which
delete it, what a deleted volume costs, and what this chart does about it. It applies to the operator this chart
installs, MongoDB Controllers for Kubernetes 1.13.0, and was measured on the lab on 2026-10-09.

## In short

- **Deleting or restarting a pod keeps its volume.** The pod comes back on it and goes on from where it was.
- **Lowering the number of mongot pods deletes the volume of every pod that goes**, at once. So does deleting the
  StatefulSet, deleting the MongoDBSearch, and `helm uninstall`.
- **A pod without its volume builds every index again from the collection.** The owner's figures for a QA cluster:
  about 180 to 190 GB of indexes a pod, and 4 to 5 hours for one pod to build them (2026-10-08, VMware, `thin-csi`).
- **Nothing in the MongoDBSearch resource turns this off** in operator 1.13.0. The chart refuses the upgrade that
  would do it by accident, and says how to do it on purpose.

## Which action does what

| Action | The pod's volume claim | Seen on the lab |
| --- | --- | --- |
| A pod is deleted or restarted (`oc delete pod`, a rolling restart, an eviction) | Kept | The pod came back on the same claim (the same uid), Ready 24 s after it started, with nothing to build |
| The node of a pod fails | Kept | Not run. Kubernetes: "if a Pod associated with a StatefulSet fails due to node failure, and the control plane creates a replacement Pod, the StatefulSet retains the existing PVC" |
| `search.replicas` lowered (the resource's `spec.clusters[].replicas`) | **Deleted**, for each pod that goes | 3 to 2: the claim of the third pod was gone within 10 s. Back to 3: a new claim, and its 8 indexes built again |
| The StatefulSet scaled by hand (`oc scale statefulset`) | **Deleted**, although the operator undoes the scaling | The operator set 3 again within 5 s; the pod was already going and its claim was deleted 8 s after the command. The pod was away 7 min 11 s, then came back on a new volume |
| `search.replicas` set to 0 | **Deleted**, every one | Not run. MongoDB: at 0 "the Kubernetes Operator scales the StatefulSet to zero pods" |
| The StatefulSet deleted, without `--cascade=orphan` | **Deleted**, every one | Not run |
| The StatefulSet deleted **with** `--cascade=orphan` | Kept | The operator made the StatefulSet again within a second; the three pods were adopted without a restart and the three claims kept their uids |
| The MongoDBSearch deleted, or `helm uninstall` | **Deleted**, every one | Not run today. `search.keepOnUninstall: true` makes `helm uninstall` leave the resource, and so the volumes, in place |

## Why

Kubernetes keeps a StatefulSet's volume claims by default: "The default for policies is `Retain`, matching the
StatefulSet behavior before this new feature"
([StatefulSets, PersistentVolumeClaim retention](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#persistentvolumeclaim-retention)).
The operator sets the other policy on the mongot StatefulSet, on both counts:

```yaml
persistentVolumeClaimRetentionPolicy:
  whenDeleted: Delete
  whenScaled: Delete
```

It does so on purpose; since operator 1.9.0, by MongoDB's account in its pull request 1621. Its source, `controllers/searchcontroller/search_construction.go` at
tag 1.13.0: "The index is rebuildable, so freeing the storage immediately is safe — a later scale-up reindexes from
mongod." The pull request that added it calls it a product decision: "immediate PVC reclaim on scale-down. This
deviates from the Kubernetes default (`Retain`)"
([mongodb/mongodb-kubernetes #1273](https://github.com/mongodb/mongodb-kubernetes/pull/1273)).

Kubernetes applies the policy only "when Pods are being removed due to the StatefulSet being deleted or scaled
down", which is why a deleted pod keeps its volume.

## What a deleted volume costs

A pod that comes back without its volume starts with nothing: it builds every index again from the collection,
and until it has, it answers no search from them. The time depends on the data, the indexes and the storage, and
varies from one build to the next.

| Where | Indexes on a pod | One pod builds everything again in |
| --- | --- | --- |
| The owner's QA cluster, as the owner reports it (2026-10-08) | About 180 to 190 GB | 4 to 5 hours |
| The lab (2026-10-09) | 16 MiB, 8 indexes | 44 s from the pod's creation |

- **One pod loses its volume**: that pod answers nothing from its indexes for that long, and the source carries an
  initial sync of every index while it serves its own load.
- **Every pod loses its volume** (0 replicas, the StatefulSet or the MongoDBSearch deleted, an uninstall): no pod
  answers a search for that long, and the source carries the initial syncs of every pod at once.

## What was tried to turn it off

| Tried on the lab | Result |
| --- | --- |
| The resource's own override, `spec.clusters[].statefulSet.spec.persistentVolumeClaimRetentionPolicy` with `Retain` on both, which the pull request above names as the way ("Overridable per cluster via the existing `clusters[].statefulSet` path") | The StatefulSet's policy stayed `Delete` on both, and **every mongot pod was restarted** by the change. The operator's merge of an override (`pkg/util/merge/merge_statefulset.go`, `StatefulSetSpecs`, at tag 1.13.0 and on `master` that day) copies the replicas, the selector, the pod management policy, the revision history limit, the update strategy, the service name, the template and the volume claim templates, and not this field |
| The policy set on the StatefulSet itself, which Kubernetes allows | The operator put `Delete` back on both within 11 s |

So this chart has no value that keeps a volume through a scale-down: there is nothing for it to set.

## What protects a volume today

1. **The chart refuses fewer pods unless they are asked for by name.** Its preflight, which runs before an upgrade
   and before an Argo CD sync, reads the number of pods the resource has. An upgrade that lowers `search.replicas`
   stops there, with nothing changed:

   ```text
   [preflight] REFUSED: search.replicas would go from 3 to 2. The operator deletes the volume of every mongot pod
   that is scaled away, and a pod that comes back builds every index again from the collection ...
   ```

   To do it knowingly, set `search.allowVolumeLoss: true` for that one upgrade, and take it out again after.
2. **Never scale the StatefulSet by hand**, and never delete it without `--cascade=orphan`. It is the operator's:
   see [scaling.md](scaling.md) for how mongot is scaled.
3. **`search.keepOnUninstall: true`** if an uninstall must not take the indexes with it. `helm uninstall` then
   leaves the MongoDBSearch, its pods and its volumes; they are removed by hand when that is meant.
4. **Change the resource through the values only.** A field of the MongoDBSearch that was patched by hand stays
   owned by that patch: on the lab, Helm 4 then refused the next upgrade that changed it ("conflict with
   \"kubectl-patch\"") until it was run with `--force-conflicts`.
5. **Volumes that are retained.** What happens to the disk when its claim is deleted is the volume's reclaim
   policy, and that is the one protection nothing undoes. Kubernetes: with `Retain`, "When the PersistentVolumeClaim
   is deleted, the PersistentVolume still exists and the volume is considered \"released\""; with `Delete`, "deletion
   removes both the PersistentVolume object from Kubernetes, as well as the associated storage asset in the external
   infrastructure"
   ([Persistent Volumes, Reclaiming](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#reclaiming)).
   OpenShift's `thin-csi` class for vSphere ships with `reclaimPolicy: Delete`: there the disk and its index go with
   the claim. The policy of a volume that exists can be changed, by a cluster administrator, once for each mongot
   volume
   ([Change the Reclaim Policy of a PersistentVolume](https://kubernetes.io/docs/tasks/administer-cluster/change-pv-reclaim-policy/)):

   ```bash
   bash expand-mongot-volumes.sh --check --statefulset <search name>-search-0     # prints each volume and its policy
   oc patch persistentvolume <the volume's name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
   ```

   A volume added later (a new pod) starts with the class's policy again. A retained volume is not removed when it
   is no longer wanted: that is then done by hand. On the lab, whose class is `Retain`, every claim deleted in the
   tests above left its volume `Released`, with its files. Binding a released volume to a returning pod, so that it
   goes on without a rebuild, is a procedure by hand that this repository has not run yet.

## Growing a volume

Raising `search.persistence.storage` does not grow a volume that exists, and never deletes one. The steps are in
[volume-expansion-runbook.md](volume-expansion-runbook.md).
