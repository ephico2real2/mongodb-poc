# Storage for the lab: volume expansion, and shared NFS volumes

Two questions this lab answers on the CRC cluster, step by step:

- **Part A — can a volume grow?** On the cluster's default storage class,
  `crc-csi-hostpath-provisioner`: enable volume expansion to see what it really does — then
  put the class back exactly as CRC made it.
- **Part B — shared storage that can grow.** Run an NFSv4 server inside the cluster, backed
  by a volume of that default class, and serve `ReadWriteMany` volumes from it through the
  Kubernetes NFS CSI driver — volumes several pods can write at once, and that resize. It is
  a **second** storage class, `nfs-csi`: the default stays `crc-csi-hostpath-provisioner`.

Every command below was run on CRC (OpenShift 4.22.7, arm64), and the output under each
one is what it printed. Run them from this folder: `cd enhancement`.

What the MongoDB operator does with volume sizes and retained volumes is in
[`mongodb-operator-storage.md`](mongodb-operator-storage.md).

## Before you start

- A CRC cluster, logged in as `kubeadmin` (`oc whoami` prints `kube:admin`): Part A changes
  a StorageClass, Part B installs a CSI driver and grants one `privileged` SCC.
- `helm` v3 or later (`helm version`).
- About 25 GiB free on the CRC VM's disk — every volume here is a directory on it.

---

## Part A — can a volume grow?

### Step A1 — look at the default storage class

```console
$ oc get sc crc-csi-hostpath-provisioner -o 'custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,EXPANSION:.allowVolumeExpansion'
NAME                           PROVISIONER                        RECLAIM   EXPANSION
crc-csi-hostpath-provisioner   kubevirt.io.hostpath-provisioner   Retain    <none>
$ oc get pods -n hostpath-provisioner -o jsonpath='{range .items[*]}{.metadata.name}: {range .spec.containers[*]}{.name} {end}{"\n"}{end}'
csi-hostpathplugin-b7nb9: hostpath-provisioner node-driver-registrar liveness-probe csi-provisioner 
```

**What just happened:** the class keeps a volume's data when its claim is deleted
(`RECLAIM Retain` — on purpose, so nothing is lost by accident), and it does not allow
expansion (`EXPANSION <none>`). The second command lists the containers of its CSI driver:
a provisioner, a registrar, a probe — and **no `csi-resizer`**. Keep that in mind for
step A5.

### Step A2 — back the class up

Save it exactly as the cluster has it, before changing anything:

```console
$ oc get sc crc-csi-hostpath-provisioner -o yaml > backup/my-crc-csi-hostpath-provisioner.yaml
$ oc diff -f backup/storageclass-crc-csi-hostpath-provisioner.restore.yaml; echo "oc diff exit code $?"
oc diff exit code 0
```

**What just happened:** `backup/my-crc-csi-hostpath-provisioner.yaml` is your own copy.
[`backup/storageclass-crc-csi-hostpath-provisioner.restore.yaml`](backup/storageclass-crc-csi-hostpath-provisioner.restore.yaml)
is the class as CRC creates it, stripped of server-set fields so it can be restored;
`oc diff` exit code `0` means it matches your live class exactly — step A6 uses it to put
the class back.

### Step A3 — try to grow a volume

[`manifests/01-expansion-test.yaml`](manifests/01-expansion-test.yaml) makes a namespace, a
1 GiB claim, and a pod that writes a marker file into it:

```console
$ oc apply -f manifests/01-expansion-test.yaml
namespace/sc-expansion-test created
persistentvolumeclaim/resize-me created
pod/user created
$ oc wait -n sc-expansion-test pod/user --for=condition=Ready --timeout=180s
pod/user condition met
$ oc get pvc resize-me -n sc-expansion-test -o jsonpath='request={.spec.resources.requests.storage} capacity={.status.capacity.storage}{"\n"}'
request=1Gi capacity=149Gi
```

The claim asked for 1Gi, and the volume reports 149Gi — this class hands every volume a
directory on the VM's disk and reports the size of its storage pool (here a 150 GiB disk;
see "Growing the storage behind NFS"). Now ask for 2Gi:

<!-- walkthrough: expect-exit 1 -->
```console
$ oc patch pvc resize-me -n sc-expansion-test --type=merge -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
Error from server (Forbidden): persistentvolumeclaims "resize-me" is forbidden: only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize
```

**What just happened:** refused, by the API server — the class does not allow expansion.

### Step A4 — allow expansion

`allowVolumeExpansion` is one of the few StorageClass fields that can be changed in place:

```console
$ oc patch sc crc-csi-hostpath-provisioner --type=merge -p '{"allowVolumeExpansion":true}'
storageclass.storage.k8s.io/crc-csi-hostpath-provisioner patched
$ oc get sc crc-csi-hostpath-provisioner -o 'custom-columns=NAME:.metadata.name,RECLAIM:.reclaimPolicy,EXPANSION:.allowVolumeExpansion'
NAME                           RECLAIM   EXPANSION
crc-csi-hostpath-provisioner   Retain    true
```

### Step A5 — try again

```console
$ oc patch pvc resize-me -n sc-expansion-test --type=merge -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
persistentvolumeclaim/resize-me patched
$ sleep 30; oc get pvc resize-me -n sc-expansion-test -o jsonpath='request={.spec.resources.requests.storage} capacity={.status.capacity.storage} conditions={.status.conditions[*].type}{"\n"}'
request=2Gi capacity=149Gi conditions=
```

Accepted — and after 30 seconds nothing has changed: no condition, the same capacity. Ask
for more than the 149Gi the volume reports:

```console
$ oc patch pvc resize-me -n sc-expansion-test --type=merge -p '{"spec":{"resources":{"requests":{"storage":"150Gi"}}}}'
persistentvolumeclaim/resize-me patched
$ sleep 30; oc get events -n sc-expansion-test --field-selector involvedObject.name=resize-me -o 'custom-columns=REASON:.reason,MESSAGE:.message' | grep -E 'REASON|Expand'
REASON                  MESSAGE
ExternalExpanding       waiting for an external controller to expand this PVC
$ oc exec -n sc-expansion-test user -- sh -c 'cat /data/marker; df -h /data | tail -1'
written-before-resize
/dev/vda4       150G  100G   50G  67% /data
```

**What just happened:** `allowVolumeExpansion` is **permission, not capability**. It lets
the API server accept a bigger size; the work is done by a `csi-resizer` next to the
driver, and this driver has none (step A1). So a request above the reported size waits
for good — `ExternalExpanding: waiting for an external controller to expand this PVC` —
and one below it changes nothing. The data is untouched, and `df` shows why size never
mattered: the volume is a directory on the VM's whole disk.

On storage with a resizer — cloud disks, OpenShift Data Foundation, and the NFS driver in
Part B — the same change makes resizes happen.

### Step A6 — clean up, and put the class back

The class keeps volumes (`Retain`), so deleting the namespace would leave this test
volume behind. Switch it to `Delete` first, so it goes with its claim:

```console
$ PV=$(oc get pvc resize-me -n sc-expansion-test -o jsonpath='{.spec.volumeName}'); oc patch pv "$PV" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' && oc delete namespace sc-expansion-test --wait=true && sleep 5 && echo "volume $PV: $(oc get pv "$PV" -o name 2>&1)"
persistentvolume/pvc-bce409c5-dbb2-4671-bce4-00b2424c33b4 patched
namespace "sc-expansion-test" deleted
volume pvc-bce409c5-dbb2-4671-bce4-00b2424c33b4: Error from server (NotFound): persistentvolumes "pvc-bce409c5-dbb2-4671-bce4-00b2424c33b4" not found
```

The volume is gone (`NotFound`). Now put the class back exactly as CRC made it — expansion
was only turned on to see what it does:

```console
$ oc replace -f backup/storageclass-crc-csi-hostpath-provisioner.restore.yaml
storageclass.storage.k8s.io/crc-csi-hostpath-provisioner replaced
$ oc get sc crc-csi-hostpath-provisioner -o 'custom-columns=NAME:.metadata.name,RECLAIM:.reclaimPolicy,EXPANSION:.allowVolumeExpansion'
NAME                           RECLAIM   EXPANSION
crc-csi-hostpath-provisioner   Retain    <none>
```

---

## Part B — shared storage that can grow

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/storage-nfs/nfs.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="../docs/diagrams/storage-nfs/nfs.light.png">
  <img alt="Two pods in namespace nfs-test mount the same ReadWriteMany claim, shared-nfs-pvc, of StorageClass nfs-csi. The NFS CSI driver in kube-system - its controller with a csi-resizer, and a node plugin that does the mount - turns that claim into a sub-directory of the export of the NFSv4 server in namespace nfs-server, reached at nfs-server.nfs-server.svc.cluster.local. The server's data lives on its own claim, nfs-data, on the default class crc-csi-hostpath-provisioner, which is a directory on the CRC VM's disk." src="../docs/diagrams/storage-nfs/nfs.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

### Where the NFS server runs — Option A, and why

Two ways were considered to serve NFS to the cluster:

- **Option A — inside the cluster (used).** An NFSv4 server as a Deployment in its own
  namespace, its data on a claim of the default class — steps B2 to B4.
- **Option B — on the MacBook (documented, not used).** macOS's own `nfsd` exporting a
  folder to the CRC VM through gvproxy.
  [`options/macbook-nfs/`](options/macbook-nfs/) has its setup script and StorageClass;
  both were written and checked (script syntax, a dry-run apply) but **never run**.

We went with Option A for these reasons:

| | Option A — in the cluster | Option B — on the Mac |
|---|---|---|
| where the data lives | a claim of the default class — CRC-managed storage, grown with the CRC VM's disk | a folder on the Mac, outside the cluster |
| NFS version | v4.1 (and v3) — the kernel's `nfsd` | **v3 only**: macOS's `nfsd` implements version 3 (`man nfsd`) |
| changes to the Mac | none | `sudo`: edits `/etc/exports`, and `/etc/nfs.conf` to accept mounts from non-reserved ports |
| network path | pod to Service, inside the cluster | through gvproxy's NAT to the Mac's `127.0.0.1` — file locking (NLM) would not cross it, so `nolock` |
| lifecycle | `oc apply` / `oc delete`, with the rest of the lab | a system service on the laptop, managed separately |
| what it costs | one `privileged` grant to one ServiceAccount (step B3), and a Kubernetes test image | root on the Mac |

To try Option B instead: run `sudo options/macbook-nfs/mac-nfs-server.sh` on the Mac, then
apply [`options/macbook-nfs/storageclass-nfs-csi-macbook.yaml`](options/macbook-nfs/storageclass-nfs-csi-macbook.yaml)
in place of steps B2 to B5. Both classes are named `nfs-csi`; use one or the other.

### Step B1 — install the NFS CSI driver

The Kubernetes NFS CSI driver, from its own Helm repository, pinned to one version:

```console
$ helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
"csi-driver-nfs" already exists with the same configuration, skipping
$ helm repo update csi-driver-nfs
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "csi-driver-nfs" chart repository
Update Complete. ⎈Happy Helming!⎈
$ helm upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs --version 4.13.4 --namespace kube-system
Release "csi-driver-nfs" does not exist. Installing it now.
NAME: csi-driver-nfs
LAST DEPLOYED: Sat Sep 26 09:52:20 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
TEST SUITE: None
NOTES:
The CSI NFS Driver is getting deployed to your cluster.

To check CSI NFS Driver pods status, please run:

  kubectl --namespace=kube-system get pods --selector="app.kubernetes.io/instance=csi-driver-nfs" --watch
$ oc rollout status deploy/csi-nfs-controller -n kube-system --timeout=300s
Waiting for deployment "csi-nfs-controller" rollout to finish: 0 of 1 updated replicas are available...
deployment "csi-nfs-controller" successfully rolled out
$ oc rollout status ds/csi-nfs-node -n kube-system --timeout=300s
daemon set "csi-nfs-node" successfully rolled out
$ oc get deploy csi-nfs-controller -n kube-system -o jsonpath='{range .spec.template.spec.containers[*]}{.name} {end}{"\n"}'
csi-provisioner csi-resizer csi-snapshotter liveness-probe nfs 
```

**What just happened:** two parts. The **controller** creates and deletes volumes — and
has a **`csi-resizer`**, which the default class's driver lacks. The **node plugin**, one
per node, does the mounting. Both run in `kube-system`, as the chart intends.

### Step B2 — an NFSv4 server, inside the cluster

[`manifests/10-nfs-server.yaml`](manifests/10-nfs-server.yaml): a namespace `nfs-server`;
a ServiceAccount; a claim `nfs-data` on the default class, where the shared data lives —
its 20Gi is a record, not a limit: like every volume of that class it is a directory on
the CRC VM's disk, so it never needs resizing; a Service on port 2049; and a one-replica Deployment running Kubernetes' own
test NFS server (the kernel's `nfsd`, Fedora's `nfs-utils`), pinned by digest to a
multi-arch image — this node is arm64:

```console
$ oc apply -f manifests/10-nfs-server.yaml
namespace/nfs-server created
serviceaccount/nfs-server created
persistentvolumeclaim/nfs-data created
service/nfs-server created
Warning: would violate PodSecurity "restricted:latest": privileged (container "nfs-server" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "nfs-server" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nfs-server" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nfs-server" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nfs-server" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment.apps/nfs-server created
```

`oc apply` warns `would violate PodSecurity "restricted:latest"` for the Deployment: the pod
is privileged. It is a warning — the namespace does not enforce that profile — and whether
the pod may run is decided by OpenShift's SCCs, the next step.

Why not `kube-system` for the server too? On OpenShift, `kube-system` is exempt from SCC
admission — measured: the driver's pods there run with no SCC at all. A privileged server
there would skip OpenShift's check entirely. In its own namespace it runs only because of
one explicit grant — the next step — and the whole server deletes as a unit.

### Step B3 — let the server run (privileged)

An NFS server has to start the kernel's `nfsd`, which only a **privileged** pod can do.
[`manifests/11-privileged-scc.yaml`](manifests/11-privileged-scc.yaml) lets exactly one
ServiceAccount, `nfs-server/nfs-server`, use OpenShift's `privileged` SCC. **Read it before
you apply it** — a privileged pod can do anything on its node:

```console
$ oc apply -f manifests/11-privileged-scc.yaml
rolebinding.rbac.authorization.k8s.io/nfs-server-privileged-scc created
```

Then restart the Deployment, so its pod is created now rather than after the ReplicaSet's
back-off from the refusals before the grant:

```console
$ oc rollout restart deploy/nfs-server -n nfs-server
deployment.apps/nfs-server restarted
$ oc rollout status deploy/nfs-server -n nfs-server --timeout=300s
Waiting for deployment "nfs-server" rollout to finish: 0 of 1 updated replicas are available...
deployment "nfs-server" successfully rolled out
```

### Step B4 — is it serving?

```console
$ oc get pods -n nfs-server -o 'custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,SCC:.metadata.annotations.openshift\.io/scc'
NAME                          READY   SCC
nfs-server-75d5c778dc-tzmg8   true    privileged
$ oc logs -n nfs-server deploy/nfs-server | grep -E 'Serving|NFS started'
Serving /exports
NFS started
$ oc exec -n nfs-server deploy/nfs-server -- cat /proc/fs/nfsd/versions
+3 +4 +4.1 +4.2
```

**What just happened:** the pod runs under the `privileged` SCC, exports `/exports` (its
claim, `nfs-data`), and the kernel serves the NFS versions listed — a `+` means enabled.

### Step B5 — the StorageClass

[`manifests/20-storageclass-nfs-csi.yaml`](manifests/20-storageclass-nfs-csi.yaml) points
the driver at the server's Service, share `/` (the export's NFSv4 root), NFS 4.1. It keeps
data on delete (`Retain`) like the default class, and allows expansion:

```console
$ oc apply -f manifests/20-storageclass-nfs-csi.yaml
storageclass.storage.k8s.io/nfs-csi created
$ oc get sc
NAME                                     PROVISIONER                        RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
crc-csi-hostpath-provisioner (default)   kubevirt.io.hostpath-provisioner   Retain          WaitForFirstConsumer   false                  58d
nfs-csi                                  nfs.csi.k8s.io                     Retain          Immediate              true                   0s
```

**What just happened:** `nfs-csi` is a **second** class, next to the default. A claim that
names no class still gets `crc-csi-hostpath-provisioner` (`(default)`); a claim gets NFS only
by asking for `storageClassName: nfs-csi`, as the next step's does.

### Step B6 — one volume, two pods writing to it

[`manifests/30-shared-claim.yaml`](manifests/30-shared-claim.yaml): a 5 GiB
**`ReadWriteMany`** claim, and a Deployment of two pods that each append a line to the same
file on it:

```console
$ oc apply -f manifests/30-shared-claim.yaml
namespace/nfs-test created
persistentvolumeclaim/shared-nfs-pvc created
deployment.apps/writer created
$ oc rollout status deploy/writer -n nfs-test --timeout=300s
Waiting for deployment "writer" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "writer" rollout to finish: 1 of 2 updated replicas are available...
deployment "writer" successfully rolled out
$ oc get pvc shared-nfs-pvc -n nfs-test -o 'custom-columns=NAME:.metadata.name,STATUS:.status.phase,ACCESS:.spec.accessModes[0],CAPACITY:.status.capacity.storage,CLASS:.spec.storageClassName'
NAME             STATUS   ACCESS          CAPACITY   CLASS
shared-nfs-pvc   Bound    ReadWriteMany   5Gi        nfs-csi
$ oc get pods -n nfs-test -l app=writer -o name
pod/writer-5dc646876d-4hz79
pod/writer-5dc646876d-hmzd5
$ oc exec -n nfs-test deploy/writer -- cat /data/writers.log
writer-5dc646876d-4hz79 14:52:32
writer-5dc646876d-hmzd5 14:52:33
```

**What just happened:** both pods mounted the same volume at once, and the file holds one
line from each — something the default class cannot do (`ReadWriteOnce` only).

### Step B7 — grow it

```console
$ oc patch pvc shared-nfs-pvc -n nfs-test --type=merge -p '{"spec":{"resources":{"requests":{"storage":"10Gi"}}}}'
persistentvolumeclaim/shared-nfs-pvc patched
$ sleep 15; oc get pvc shared-nfs-pvc -n nfs-test -o jsonpath='request={.spec.resources.requests.storage} capacity={.status.capacity.storage}{"\n"}'
request=10Gi capacity=10Gi
$ oc get events -n nfs-test --field-selector involvedObject.name=shared-nfs-pvc -o 'custom-columns=REASON:.reason,MESSAGE:.message' | grep -E 'REASON|Resiz'
REASON                   MESSAGE
Resizing                 External resizer is resizing volume pvc-03e7c357-7682-4b88-8401-396080b4d523
VolumeResizeSuccessful   Resize volume succeeded
```

**What just happened:** this time the resize completed — the driver's `csi-resizer` did the
work step A5 had no one for. That is what this lab uses NFS for: a storage class that
behaves like real storage when a claim grows, so resizes can be tried end to end. Under
it, no size is enforced anywhere — a volume is a directory on the export, the export
is the server's claim `nfs-data`, and that is a directory on the CRC VM's disk. The one
real limit is that disk; the next section shows how to grow it.

### Step B8 — where the data really is

```console
$ oc exec -n nfs-server deploy/nfs-server -- ls /exports
index.html
pvc-03e7c357-7682-4b88-8401-396080b4d523
$ oc exec -n nfs-server deploy/nfs-server -- sh -c 'cat /exports/pvc-*/writers.log'
writer-5dc646876d-4hz79 14:52:32
writer-5dc646876d-hmzd5 14:52:33
```

**What just happened:** the driver made one sub-directory per volume, named after it, on
the server's export — and the two writers' lines are in it.

### Step B9 — clean up the test

Like Part A, switch the test volume to `Delete` so it goes with its claim — the driver then
deletes its directory on the export:

```console
$ PV=$(oc get pvc shared-nfs-pvc -n nfs-test -o jsonpath='{.spec.volumeName}'); oc patch pv "$PV" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' && oc delete namespace nfs-test --wait=true && sleep 5 && echo "volume $PV: $(oc get pv "$PV" -o name 2>&1)"
persistentvolume/pvc-03e7c357-7682-4b88-8401-396080b4d523 patched
namespace "nfs-test" deleted
volume pvc-03e7c357-7682-4b88-8401-396080b4d523: Error from server (NotFound): persistentvolumes "pvc-03e7c357-7682-4b88-8401-396080b4d523" not found
$ oc exec -n nfs-server deploy/nfs-server -- ls /exports
index.html
```

The NFS server, its StorageClass and the driver stay — ready for real volumes.

---

## Growing the storage behind NFS — the CRC VM's disk

Everything NFS serves, and every volume of the default class, shares one pool: the CRC
VM's disk. How big it is, and how full:

```console
$ crc config get disk-size
disk-size : 150
$ oc exec -n nfs-server deploy/nfs-server -- df -h /exports
Filesystem      Size  Used Avail Use% Mounted on
/dev/vda4       150G  100G   50G  67% /exports
```

**What just happened:** `disk-size` is the VM disk's size in GiB, and `df` on the NFS
server's export shows that same disk — `/dev/vda4` — with the space every volume shares.
When `Avail` runs low, grow the disk. It restarts the cluster, so do it only when needed.
Pick a bigger number (`crc config --help`: "Total size in GiB of the disk", at least 31),
set it, and restart CRC for it to apply. Run this lab's way, from 120 to 150 GiB:

<!-- walkthrough: skip -->
```console
$ crc config set disk-size 150
Changes to configuration property 'disk-size' are only applied when the CRC instance is started.
If you already have a running CRC instance, then for this configuration change to take effect, stop the CRC instance with 'crc stop' and restart it with 'crc start'.
$ crc stop
level=info msg="Stopping the instance, this may take a few minutes..."
Stopped the instance
$ crc start
…
The server is accessible via web console at:
  https://console-openshift-console.apps-crc.testing
…
$ crc config get disk-size
disk-size : 150
$ crc status | grep -E 'OpenShift|Disk'
OpenShift:       Running (v4.22.7)
Disk Usage:      106.6GB of 160.5GB (Inside the CRC VM)
```

(`crc start`'s output is shortened here: it ends with the cluster's login details.)

**What just happened:** `crc stop` took 6 s and `crc start` 184 s. The VM disk went from
120G with 21G free to **150G with 51G free** — measured on the node as `/dev/vda4 150G
100G 51G 67%`, where it had been `120G 100G 21G 83%`. Nothing was lost: every volume, of
either class, is a directory on that disk, so all of them — and the NFS server's export —
simply have more room. Only ever raise the size.

---

## Removing everything

The server's own claim is `Retain` too: deleting the namespace leaves its volume, with the
shared data, **Released**. Switch it to `Delete` first only if you mean to lose that data.

<!-- walkthrough: skip -->
```console
$ oc delete sc nfs-csi
$ oc delete -f manifests/11-privileged-scc.yaml
$ oc delete -f manifests/10-nfs-server.yaml
$ helm uninstall csi-driver-nfs --namespace kube-system
```

The default class needs nothing: step A6 already put it back.

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| a resize `Forbidden … the storageclass that provisions the pvc must support resize` | `allowVolumeExpansion` is not set — the default class, as CRC makes it | use `nfs-csi` (Part B); step A4 shows what enabling it on the default class does |
| a resize accepted, then `ExternalExpanding: waiting for an external controller` forever | the class's driver has no `csi-resizer` (the default class) | use a class whose driver has one — Part B |
| the NFS server's pod never appears; `FailedCreate … unable to validate against any security context constraint` | the privileged grant is missing | step B3, then restart the Deployment |
| a claim of `nfs-csi` stays `Pending` | the server is not ready, or the driver cannot reach it | step B4; `oc logs -n kube-system deploy/csi-nfs-controller -c nfs` |
| a pod stuck `ContainerCreating` with a mount error | the node plugin could not mount the export | `oc logs -n kube-system ds/csi-nfs-node -c nfs` |
| a volume keeps using space after its claim is gone | the class is `Retain`, as designed | delete the Released volume if you mean to; steps A6 and B9 show how |
| writes fail with `No space left on device` | the CRC VM's disk is full — every volume shares it, whatever their sizes say | grow it: "Growing the storage behind NFS" |

## References

- [Kubernetes NFS CSI driver](https://github.com/kubernetes-csi/csi-driver-nfs)
- [Kubernetes — expanding persistent volume claims](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims)
- [Kubernetes CSI — volume expansion](https://kubernetes-csi.github.io/docs/volume-expansion.html)
- [OpenShift — managing security context constraints](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/authentication_and_authorization/managing-pod-security-policies)
- [Kubernetes e2e test images — volume/nfs](https://github.com/kubernetes/kubernetes/tree/master/test/images/volume/nfs)
