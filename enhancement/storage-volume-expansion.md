# Volume expansion on `crc-csi-hostpath-provisioner`

**What changed (2026-09-26):** `allowVolumeExpansion: true` on the StorageClass
`crc-csi-hostpath-provisioner`, the cluster's default. Nothing else about the class
changed — it still uses `reclaimPolicy: Retain` on purpose, so a deleted claim never
takes its data with it.

**What it does, in one line:** the API server now accepts a bigger size on a claim;
nothing on this cluster actually grows a volume. Every result below was measured on this
CRC cluster (OpenShift 4.22.7).

## Before the change — the backup

Two copies, in [`backup/`](backup/):

| File | What it is |
|---|---|
| [`storageclass-crc-csi-hostpath-provisioner.as-found.yaml`](backup/storageclass-crc-csi-hostpath-provisioner.as-found.yaml) | `oc get sc … -o yaml`, exactly as the cluster returned it — sha256 `98896a7a20d7b0d0a89cc09649f8cd61136b3dd873692a0e97ac369d926911b6` |
| [`storageclass-crc-csi-hostpath-provisioner.restore.yaml`](backup/storageclass-crc-csi-hostpath-provisioner.restore.yaml) | the same class without server-set fields, ready for `oc replace` — `oc diff` against the live class returned 0 before the change |

The class was created by CRC with `kubectl apply` (it carries the last-applied
annotation) and has no owner references: no operator reconciles it, so a patch is not
reverted. Whether `crc start` re-applies it after the VM is recreated is **not known** —
check after the next `crc stop`/`crc start`:

```sh
oc get sc crc-csi-hostpath-provisioner -o jsonpath='{.allowVolumeExpansion}{"\n"}'
```

## The change

```sh
oc patch sc crc-csi-hostpath-provisioner --type=merge -p '{"allowVolumeExpansion":true}'
```

or `oc apply -f storageclass-crc-csi-hostpath-provisioner.yaml` — the desired state,
which `oc diff` confirms matches the live class. To undo:

```sh
oc replace -f backup/storageclass-crc-csi-hostpath-provisioner.restore.yaml
```

## What enabling it does — measured

The test is [`test/expansion-test.yaml`](test/expansion-test.yaml): a 1Gi claim and a pod
that writes a marker file into it, in a scratch namespace.

| | Result |
|---|---|
| a new 1Gi claim | bound; the volume reports a capacity of **119Gi** |
| resize to 2Gi, **before** the change | refused: `Forbidden: only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize` |
| resize to 2Gi, **after** | accepted: `request=2Gi`. After 60 s: capacity still 119Gi, no `allocatedResources`, no resize status, no conditions, no event |
| resize to 150Gi (above the reported 119Gi) | accepted, then event `ExternalExpanding: waiting for an external controller to expand this PVC` — and it waits for good |
| the data | `written-before-resize`, intact throughout |
| `df` inside the pod | `/dev/vda4  120G  99G  22G  83%  /data` — the whole VM disk |

Why:

- **There is no resizer.** The driver's pod (`hostpath-provisioner/csi-hostpathplugin`)
  runs `hostpath-provisioner`, `node-driver-registrar`, `liveness-probe` and
  `csi-provisioner` — no `csi-resizer` sidecar. For a CSI volume, Kubernetes hands an
  expansion to that sidecar (hence `ExternalExpanding`); without it, nothing happens.
- **A volume here is a directory, not a disk.** Every claim reports the storage pool's
  capacity (119Gi), whatever it asked for, and can use the free space of the VM's disk
  (22G at the time) — not the size it requested. There is nothing to grow.

So on this cluster:

- a resize **up to the reported 119Gi** is accepted and changes nothing — the volume
  already had that room;
- a resize **above it** stays pending forever;
- sizes are **not enforced** in either direction: 2Gi of `storage` does not stop a pod
  from filling the VM's disk.

This is a property of CRC's single-node hostpath storage, not of Kubernetes. On storage
with a real resizer (cloud block storage, ODF/Ceph RBD, most CSI drivers), the same
change makes resizes happen.

## What it means for the MongoDB operator — from its source

Read from [mongodb/mongodb-kubernetes](https://github.com/mongodb/mongodb-kubernetes)
(`upstream/master`, and v1.12.0, the version installed here); not run on the cluster.

| Resource | Resize support |
|---|---|
| `MongoDB` replica set, sharded, standalone, multi-cluster; AppDB | yes: `HandlePVCResize` (`controllers/operator/create/create.go:119`) refuses a shrink, patches every claim to the new size, waits for it to finish, then deletes the StatefulSet as an orphan and recreates it (claim templates are immutable) |
| `MongoDBSearch` | **no**: the Search controller never calls `HandlePVCResize`; it writes its StatefulSet with a plain `CreateOrUpdate` (`controllers/searchcontroller/mongodbsearch_reconcile_helper.go:1256`), and a StatefulSet's claim templates cannot be changed in place |

And one check that matters on this cluster: the resize is "finished" only when a claim's
capacity **equals** the new request exactly (`hasFinishedResizing`, `create.go:280`,
`Cmp(...) != 0`). Kubernetes allows a volume's capacity to *exceed* its request — drivers
round up — and this driver always reports 119Gi. So here, even the database resources'
resize would, by that code, never be seen as finished. Not measured: it would need a
`MongoDB` resource resized on this cluster.

## MongoDBSearch persistence — the supported fields

From the installed CRD and the operator's source:

| Field | Honoured |
|---|---|
| `clusters[].persistence.single.storage` | yes — default **16G** (`pkg/util/constants.go:241`); the CRD's description says "10GB", which is out of date |
| `clusters[].persistence.single.storageClass` | yes — the claim's `storageClassName` |
| `clusters[].persistence.single.labelSelector` | yes — the claim's `spec.selector` (`controllers/operator/construct/pvc.go:19-20`) |
| `clusters[].persistence.multiple.{data,journal,logs}` | **no** — in the schema, ignored by the Search controller (`search_construction.go:135-138`) |

The operator also fixes the mongot StatefulSet's claim retention policy to
`whenDeleted: Delete, whenScaled: Delete` (`search_construction.go:189-195`), and the
CR's `statefulSet` override cannot change it: the merge (`pkg/util/merge/merge_statefulset.go:28-58`)
does not carry `persistentVolumeClaimRetentionPolicy`. With this StorageClass's `Retain`,
deleting a `MongoDBSearch` therefore leaves its volumes **Released, with their data** — by
design — as `mongodb-poc/data-mongot-search-0-{0,1,2}` are now. Those three are annotated
`argocd.argoproj.io/sync-options: Prune=false`.

## Candidate upstream changes

Worked on in the fork, [ephico2real2/mongodb-kubernetes](https://github.com/ephico2real2/mongodb-kubernetes):

1. **`hasFinishedResizing`: `>=`, not `==`** — capacity may exceed the request.
2. **Carry `persistentVolumeClaimRetentionPolicy` in the StatefulSet merge** — so the
   `statefulSet` override can keep claims, and a re-created `MongoDBSearch` re-attaches each
   replica to its own volume without manual steps.
3. **Resize for `MongoDBSearch`** — call the existing `HandlePVCResize`.
4. **A fuller claim template for Search** (`volumeName`, `dataSource`, access modes), in the
   style of CloudNativePG's `pvcTemplate`.
5. **CRD docs** — the 16G default; `multiple` unsupported for Search.

## Re-attaching the retained mongot volumes — today, without operator changes

A StatefulSet adopts any existing claim with the name it expects. Before re-creating the
`MongoDBSearch`:

1. clear `spec.claimRef` on each retained volume (a Released volume still names its old claim);
2. create `data-mongot-search-0-{0,1,2}` in `mongodb-poc`, each with `spec.volumeName` set to
   its own volume, `storageClassName: crc-csi-hostpath-provisioner`, and the CR's `storage`.

Each replica then gets its own volume back. Because of the operator's `whenDeleted: Delete`,
deleting the CR again deletes those claims — and `Retain` keeps the volumes again.
