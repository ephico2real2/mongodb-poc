# Investigation: growing mongot's volumes from the values alone

Growing mongot's volumes takes steps by hand today: the size in the values, the sync, and then two runs of
[expand-mongot-volumes.sh](../chart/mongodb-search-helm/expand-mongot-volumes.sh), as
[volume-expansion-runbook.md](../chart/mongodb-search-helm/volume-expansion-runbook.md) describes. This page asks whether those two runs can be
taken away, so that a larger `search.persistence.storage` and a flag are all it takes, and compares two ways of doing
it: a Job in the chart, and a controller of our own with a custom resource.

It is the investigation behind `search.persistence.autoExpand` (issue 118 of the repository): why it is a Job, what
was read, and what the lab showed. It is development and test material and stays in the repository. How to use the
flag is in the chart, in the runbook, under "Letting the chart take steps 3 to 5".

## In short

- **Kubernetes still cannot do it, and will not soon.** A StatefulSet's volume claim template cannot be changed.
  The proposal to allow it has been open since 2024; both of its pull requests were closed without being merged in
  2026, and it is not in Kubernetes 1.35, which OpenShift 4.22 runs.
- **MongoDB does not support growing a search volume, and says so.** Its own open pull request for a test of the
  steps by hand: "the Search controller has no native PVC resize". The operator does grow volumes for its database
  resources, with the three steps of our runbook (grow the claims, delete the StatefulSet with the pods left in
  place, make it again); the search part of the operator does not call that code. The lasting fix is a small one,
  and it is MongoDB's.
- **A Job in the chart does it with what we already have.** It runs between the MongoDBSearch and the gate of a sync
  or an upgrade, mounts the runbook's script from the chart, and acts only when the operator has refused the new
  size. On the lab it grew the volumes from 8Gi to 9Gi with its own rights, with the same pods and every search
  answered, and then never ended, waiting inside `oc delete` for a delete that had already happened; the script no
  longer waits there, and the corrected Job is not yet run. It is one template of 178 lines, changes one flag of the script, and needs no image and no cluster-wide
  install.
- **A controller of our own would do the same three steps, at a much higher cost.** A custom resource is not
  needed at all (the size already has a place, the MongoDBSearch); what a controller adds is that it acts without
  a sync. It needs an image of ours to build, scan and keep patched, a pod that runs all year for something done a
  few times a year, and, for a custom resource, a cluster administrator to install its definition.
- **Decided (the owner, 2026-10-10):** the Job, with the flag off in production's values and set only for the
  change that grows the volumes; no controller and no custom resource of our own; a smaller volume is not
  supported, and the preflight refuses it.

## What happens today

```text
values: search.persistence.storage 300Gi -> 400Gi
  sync or upgrade        the MongoDBSearch now asks for 400Gi
  the operator           tries to change the StatefulSet; Kubernetes refuses; the resource is Failed
                         (the mongot pods run and answer as before)
  the gate               stops at once: "search.persistence.storage is now 400Gi and the StatefulSet still has 300Gi"
  by hand                expand-mongot-volumes.sh --expand                 each claim, one pod at a time
  by hand                expand-mongot-volumes.sh --recreate-statefulset   delete with --cascade=orphan; the operator makes it again
  sync or upgrade again  the gate passes
```

Run to the end four times on the lab on 2026-10-10 ([testing-mongot-storage-resize.md](../chart/mongodb-search-helm/docs/testing-mongot-storage-resize.md)).

## What Kubernetes, MongoDB and others do

| Who | What it does about a StatefulSet's volume size | Source |
| --- | --- | --- |
| Kubernetes | Nothing: the claim template cannot be changed. The proposal "StatefulSet Support for Updating Volume Claim Template" is open, marked alpha, with 1.35 written as its target. Its design pull request and its code pull request are both closed, not merged. Its author, 2026-04-14: "To be honest. We currently don't have much time for this. Sorry." | kubernetes/enhancements issue 4650 and pull request 4651; kubernetes/kubernetes pull request 126530 |
| Kubernetes 1.35.6 on the lab | The API server lists no feature gate for it | `oc get --raw /metrics`, the `kubernetes_feature_enabled` lines |
| MongoDB's operator 1.13.0, database resources | Grows the claims, waits, deletes the StatefulSet with the orphan policy, makes it again: `HandlePVCResize`, called for a standalone, a replica set, a sharded cluster, a multi-cluster replica set and the application database | `controllers/operator/create/create.go`, line 119, at tag 1.13.0 |
| MongoDB's operator 1.13.0, search | Writes the StatefulSet with a plain create-or-update, and so meets Kubernetes' refusal | `controllers/searchcontroller/mongodbsearch_reconcile_helper.go`, line 1258 |
| MongoDB, on search | "Customers need to grow mongot index storage, and the Search controller has no native PVC resize. Changing `persistence.single.storage` on the MongoDBSearch CR hits the immutable `volumeClaimTemplates` error, and the CR goes `Failed`." The pull request adds a test of the steps by hand, and is open, not merged | mongodb/mongodb-kubernetes pull request 1621, "Search: e2e verifying manual mongot PVC resize workaround", read 2026-10-10 |
| MongoDB's documentation | Describes the operator's "easy expansion" for its database resources: "The easy expansion mechanism requires the default RBAC included with the Kubernetes Operator. Specifically, it requires get, list, watch, patch and update permissions for persistantVolumeClaims." The page names neither MongoDBSearch nor mongot | "Increase Storage for Persistent Volumes" |
| Elastic's operator | The same three steps, by itself: "ECK will update the existing PersistentVolumeClaims accordingly, and recreate the StatefulSet automatically." Where the driver cannot grow a file system in use: "Pods must be manually deleted after the resize" | Elastic, "Volume claim templates" |
| VSHN's statefulset-resize-controller | Something else: for storage that cannot grow a volume, it scales the StatefulSet down, makes new claims and copies the data. Last release 2023 | its README |

Two things follow.

- **The method of our script is the method of the vendors' own operators.** Deleting the StatefulSet with the orphan
  policy is not a trick of ours.
- **MongoDB's operator differs from our script in two ways**, both to our script's side of caution: it asks every
  claim at once (the script goes one pod at a time and waits for each), and for a database it then restarts the pods
  one by one (mongot's pods are not restarted: none was in four runs).

On the lab the operator's own service account may already do what the steps need:

```console
$ oc auth can-i patch persistentvolumeclaims -n mongodb-poc --as=system:serviceaccount:mongodb-poc:mongodb-kubernetes-operator
yes
$ oc auth can-i delete statefulsets.apps -n mongodb-poc --as=system:serviceaccount:mongodb-poc:mongodb-kubernetes-operator
yes
```

## Way 1: a Job in the chart

### What it is

`search.persistence.autoExpand.enabled: true` adds five objects to the release: a ConfigMap that holds
`expand-mongot-volumes.sh` as it is in the chart, a service account, a role and its binding, and a Job.

```text
values: search.persistence.storage 300Gi -> 400Gi          (autoExpand.enabled: true)
  wave 1   the MongoDBSearch now asks for 400Gi; the operator is refused; the resource is Failed
  wave 2   the Job
             waits until the operator has seen the resource as it is now
             is the resource Failed, with Kubernetes' refusal of the StatefulSet update, and the sizes different?
               no:  "nothing to grow", and it ends well        (a first install, any other sync, any other failure)
               yes: expand-mongot-volumes.sh --check
                    expand-mongot-volumes.sh --expand --apply --yes                each claim, one pod at a time
                    expand-mongot-volumes.sh --recreate-statefulset --apply --yes  the operator makes it again
  wave 3   the gate: the resource is Running, the pods ready, the certificates mounted, the Route admitted
```

- **One signal, the gate's own.** The Job and the gate share one test (`mongodb-search-helm.volumeSizeChanged` in
  `templates/_helpers.tpl`). The Job never decides by itself that a volume should grow: it acts where the gate would
  have stopped and sent a person to the runbook.
- **The same script, not a copy.** The chart's tests compare the mounted script with the chart's file, byte for
  byte. (One flag of the script changed because of what the lab showed, below; by hand and in the Job it is the
  same file.) What the script refuses by hand it refuses here: a class that cannot grow a volume, a pod that is not
  Ready, a smaller size, a claim that belongs to another StatefulSet.
- **It retires itself.** When MongoDB's operator grows search volumes itself, the resource is never Failed for this
  reason, and the Job only ever says "nothing to grow".
- **Off, the chart is what it was.** With the flag off the render differs from chart 0.3.24 in one line: the gate's
  Helm hook weight, 0 before and 1 now, so that the gate stays the last hook.

### What it may do

Its role, in the release's namespace only:

| On | It may | Why |
| --- | --- | --- |
| The MongoDBSearch | read | the size asked for, the phase, the operator's message |
| StatefulSets | read | the size the StatefulSet has, its pods |
| The mongot StatefulSet, by name | delete | the one delete of the runbook, always with `--cascade=orphan` |
| Pods | read, list | each pod Ready before and after its claim grows; the same pods afterwards |
| Volume claims | read, list, ask for more | Kubernetes lets a claim's size only grow, and nothing else of a claim be changed |

It may not delete a pod or a claim, and it holds no right outside the namespace. Storage classes are read with what
OpenShift gives every signed-in identity (the `basic-user` cluster role, bound to `system:authenticated`).

The right that deserves thought is the delete of the StatefulSet: the script only ever sends it with the orphan
policy, but the role cannot say so, and the same delete without that policy takes the pods and, by the operator's
retention policy, the volumes with them ([volumes.md](../chart/mongodb-search-helm/volumes.md)). The chart renders the role only while the
flag is on; with the flag off again Helm removes it at the next upgrade, and Argo CD when it prunes (an Application
without automated pruning, as the lab's, keeps it until a sync with pruning).
Anyone who may create a pod in the namespace can use any of its service accounts, so the role gives nothing to a
namespace administrator that they do not have; it does give it to this one Job.

### What Argo CD and Helm promise about such a Job

| | Argo CD | Helm |
| --- | --- | --- |
| Order | "1. The phase 2. The wave they are in (lower values first) 3. By kind 4. By name" | "The library sorts hooks by weight (assigning a weight of 0 by default), by resource kind and finally by name in ascending order" |
| A Job that fails | "If any of them fails the whole sync process will be marked as failed" | "if the hook fails, the release will fail. This is a blocking operation" |
| Run again | "Hooks also run on every sync, not only when something they care about has changed [...] so whatever the hook does has to be safe to run twice" | A hook runs on every install and upgrade it names |
| How long | "the sync operation stays open for as long as the hook runs"; no time limit unless one is set (`controller.sync.timeout.seconds`, "0 means no timeout (default 0)"; the lab sets none) | Up to `--timeout`, five minutes unless given |

Two of these are limits to weigh, and Argo CD's own page says so: "Long or multi-step jobs are usually better handled
by a controller or a workflow engine that can report progress on its own."

### What was run on the lab

OpenShift Local 4.22.7, Argo CD (OpenShift GitOps 1.22.0) following the branch, three mongot pods on the NFS class
`ipsec-nas-csi`, 2026-10-10.

Three syncs ran the Job. The size was changed in git each time and nothing was done by hand to a claim or to the
StatefulSet.

| The values asked for | What the Job did | Pods and claims | Searches through mongod |
| --- | --- | --- | --- |
| 4Gi, less than the volumes' 8Gi | Refused, with the script's words, and failed the sync. Nothing was changed. (The preflight now refuses this earlier, before the MongoDBSearch is touched; that was added after this run) | The same three pods and three claims | Answered |
| 8Gi again, what the volumes have | Passed with the rest of the sync, which took 67 s. Its log was not kept | The same | Answered |
| 9Gi | Grew the three claims one pod at a time and deleted the StatefulSet with the orphan policy; the operator made it again at 9Gi, 11 s after the Job had started. **The Job then never ended** | The same three pods (no restart) and the same three claims, now 9Gi | 136 tried in the 30 minutes watched, 0 failed |

The refusal:

```text
About to grow the volume claims of StatefulSet mongot-search-0, pod 0 to 2, to 4Gi, one at a time.
expand-mongot-volumes.sh: claim data-mongot-search-0-0 already asks for 8Gi, more than 4Gi: a volume cannot be made smaller
[expand] FAILED: the volume claims were not all grown (the script ended with 1). No pod, claim or StatefulSet was
deleted, and the mongot pods run as before. [...]
```

The growth, from the Job's log, with lines left out and the long ones shortened (the service account is the Job's own):

```text
[expand 22:25:19] search.persistence.storage is now 9Gi and StatefulSet mongot-search-0 has 8Gi: taking the steps of volume-expansion-runbook.md, with its script
MongoDBSearch mongot: asks for 9Gi, is Failed
  pod 0: claim data-mongot-search-0-0 Bound, asks 8Gi, has 8Gi, class ipsec-nas-csi (expands: true), conditions [], pod Ready
[...]
pod 0: asking claim data-mongot-search-0-0 for 9Gi (it asks 8Gi, has 8Gi)
  data-mongot-search-0-0: has 9Gi
pod 0: claim data-mongot-search-0-0 has 9Gi, pod mongot-search-0-0 is Ready
[the same for pod 1 and pod 2]
About to delete StatefulSet mongot-search-0 with --cascade=orphan. Its 3 pods and their claims stay; the operator makes the StatefulSet again at 9Gi.
W1010 22:25:26 reflector.go:535] failed to list *unstructured.Unstructured: statefulsets.apps "mongot-search-0" is forbidden:
  User "system:serviceaccount:mongodb-poc:mongot-mongodb-search-helm-expand-volumes" cannot list resource "statefulsets"
[the same every 30 to 50 s, for as long as it was watched]
```

**What went wrong.** `oc delete` waits for the object to be gone, and the script let it. It first reads the
object; if it is still there it then lists and watches that name and waits for a "deleted" event, for up to a week
(`effectiveTimeout = 168 * time.Hour` in kubectl's `delete.go`; the wait is `IsDeleted` in `wait/delete.go`, at
v1.35.0). The Job's role allowed a read and the delete of the StatefulSet, and neither a list nor a watch, so the
watch never began. The delete itself was done at once: the StatefulSet's new creation time is 22:25:26Z, the second
of the first refused list.

**A first correction that was not enough.** `list` and `watch` were added to the role in the cluster at 23:04Z.
The refusals stopped, and the command still did not return: its watch began 39 minutes after the old StatefulSet
had gone, saw the new one of the same name, and waited for that to be deleted. The same can happen to anyone, with
every right, if the operator makes the StatefulSet again between the command's read and its list; on the lab the
operator did so within a second. Run by hand it had not happened in the earlier runs.

**What was changed.** The script now sends the delete with `--wait=false` and does the waiting itself, as it
already did for the next thing it needs: the new StatefulSet, for no longer than `--wait` (15 minutes). The role is
as it was: it needs neither `list` nor `watch` on StatefulSets.

**Not yet shown.** The Job with the corrected script has not run on the lab: Argo CD's sync was still waiting for
the hung Job when this was written. So the lab shows that the steps work with the Job's own rights, and that
searches are answered throughout; it does not yet show a sync that passes from the new size to the gate with nobody
touching it.

**The lab that day.** The first sync ran while the node was out of memory (about 2 GiB available, the
controller-manager restarting); the machine was then given 4 GiB and 2 CPUs more and restarted. The growth to 9Gi
ran after that, with 8.7 GiB available and no restart of the control plane during it.

### What the Job does not do

- **It does not restart a pod.** A driver that cannot grow a file system in use leaves a claim at
  `FileSystemResizePending`; the script then stops (its `--restart-if-pending` is not passed), the Job fails and says
  so, and that pod is restarted by hand, as the runbook says. vSphere's driver grows a file system in use.
- **It does not pick the size, the moment or the cluster.** It runs in a sync or an upgrade that somebody started
  by changing the values.
- **It does not report progress** beyond its log. Under Argo CD the Application reads `Progressing` while it runs.
- **It has not grown a real disk.** On NFS a claim's size is a number. How long vSphere takes for 300Gi is not
  measured; the Job allows each claim 15 minutes (`autoExpand.claimWaitSeconds`).
- **It was not run under Helm on a cluster.** The lab is run by Argo CD. Helm's order is covered by the chart's
  tests only.

## Way 2: a controller of our own

### A custom resource is not needed for it

A custom resource definition gives a new kind of object a place to state what is wanted. Here that place exists:
`spec.clusters[].persistence.single.storage` of the MongoDBSearch, filled from `search.persistence.storage`. A
resource of our own would state the same number a second time, and the two could disagree. A controller, if one
were wanted, would watch the MongoDBSearch and need no definition of its own.

A definition is also the expensive part to install: it is an object of the whole cluster, not of a namespace, so it
needs a cluster administrator on every cluster, and it outlives the chart.

### What a controller adds, and what it costs

It adds one thing: it acts when the resource changes, with or without a sync, and keeps trying. For this operation
that is little, because the size only ever changes through a sync.

Every controller, whatever it is written with, costs:

- an image of ours: built, scanned, signed, mirrored to the company's registry, and rebuilt for every base image fix;
- a pod that runs all year, with the same rights as the Job, for an operation done a few times a year;
- its own failure modes: two copies acting at once, a restart in the middle of the three steps, a watch that falls
  behind;
- tests against a real API server, a release process, and someone who knows it when it breaks.

### The frameworks, as of 2026-10-10

| Framework | You write | It needs in the cluster | Fit for "grow the claims, wait, delete with orphan, wait" | State |
| --- | --- | --- | --- | --- |
| [shell-operator](https://github.com/flant/shell-operator) (Flant) | Shell scripts, called on events. "Shell-operator is a tool for running event-driven scripts in a Kubernetes cluster." | A Deployment of its image with our script in it, a service account and role. No definition of its own | Closest: our script could be the hook, bound to the MongoDBSearch. A failed hook is run again every 5 seconds until it succeeds, which our script's refusals are not made for | 2,606 stars, v1.21.1 on 2026-10-07, Apache-2.0 |
| [kopf](https://github.com/nolar/kopf) | Python functions with decorators. "A full-featured operator in just 2 files: a Dockerfile + a Python file" | A Deployment of an image of ours | Good, in Python: the steps would be written again, not reused | 2,651 stars, 1.44.6 on 2026-06-03. "There is no active development of new major functionality" |
| [Metacontroller](https://github.com/metacontroller/metacontroller) | A web service that receives the present state as JSON and returns the wanted state | Metacontroller itself, with its own cluster-wide definitions, and our web service | Poor: it applies a wanted set of objects. "Delete this, but leave its pods" is not a wanted state | 1,010 stars, v4.17.2 on 2026-08-13 |
| [kro](https://github.com/kubernetes-sigs/kro) | A graph of objects in YAML | kro itself, with its own cluster-wide definitions | None: it creates and orders objects, and has no steps | 3,068 stars, v0.9.4 on 2026-09-04, before 1.0 |
| [Operator SDK](https://github.com/operator-framework/operator-sdk), [Kubebuilder](https://github.com/kubernetes-sigs/kubebuilder) | Go, on the controller-runtime library (Operator SDK also Ansible or Helm) | A Deployment of an image of ours; a definition if we add a kind | Full: MongoDB's operator is written on the same library (`sigs.k8s.io/controller-runtime` in its `go.mod`), and its code is where this belongs | 7,682 and 9,347 stars; v1.42.3 and v4.16.0 in 2026 |

The easiest to understand is shell-operator, because nothing would be written again. It is still a second moving
part that does what three lines of the Job's script do.

## The ways side by side

| | By hand (today) | The Job | A controller (shell-operator) | A controller with our own resource (Go, Python) | MongoDB's operator does it |
| --- | --- | --- | --- | --- | --- |
| Steps after the values change | 3 (two runs of the script, one more sync) | 0 | 0 | 0, and a second object to write | 0 |
| New code | none | one template of 178 lines; one flag changed in the script | a Deployment, an image with our script, hook bindings | a controller, its tests, its image, its release | none of ours |
| New image to own | no | no (the Jobs' `ose-cli`) | yes | yes | no |
| Runs | when a person runs it | inside a sync or an upgrade | all year | all year | all year, already |
| Cluster administrator needed to install | no | no | no | yes, for the definition | no |
| A person sees each step | yes | in the Job's log | in a pod's log | in a pod's log and the resource's status | in the operator's log and the resource's status |
| Works without a sync | yes | no | yes | yes | yes |
| Who keeps it working | us | us, in the chart | us, a second thing | us, a product | MongoDB |

## What was decided

The owner, 2026-10-10:

1. **The Job goes into the chart**, as `search.persistence.autoExpand.enabled`.
2. **The flag is `false` in production's values** and is set only when the volumes are to be grown: the larger
   `search.persistence.storage` first or with it, then the flag, which starts the Job in that sync. `false` again
   afterwards.
3. **A smaller volume is not supported.** The preflight refuses it before anything is changed.
4. **No controller and no custom resource of our own.**

Still open:

- One growth on QA, on `thin-csi`, with the flag on, before production relies on it: how long a real disk takes, and
  whether its file system grows under a running mongot. Until then the steps by hand remain the proven way, and they
  remain the way on whenever the Job stops.
- Whether the Job may restart a pod whose file system waits for it (`--restart-if-pending`): today it stops and
  says so.
- Whether to tell MongoDB that their search reconciler does not call their own resize code.

## Sources

- Kubernetes: [enhancement issue 4650](https://github.com/kubernetes/enhancements/issues/4650),
  [its design pull request](https://github.com/kubernetes/enhancements/pull/4651),
  [its code pull request](https://github.com/kubernetes/kubernetes/pull/126530), read 2026-10-10.
- kubectl: [`pkg/cmd/wait/delete.go`](https://github.com/kubernetes/kubernetes/blob/v1.35.0/staging/src/k8s.io/kubectl/pkg/cmd/wait/delete.go)
  and [`pkg/cmd/delete/delete.go`](https://github.com/kubernetes/kubernetes/blob/v1.35.0/staging/src/k8s.io/kubectl/pkg/cmd/delete/delete.go) at v1.35.0.
- MongoDB: [mongodb/mongodb-kubernetes at tag 1.13.0](https://github.com/mongodb/mongodb-kubernetes/tree/1.13.0);
  [pull request 1621](https://github.com/mongodb/mongodb-kubernetes/pull/1621);
  [Increase Storage for Persistent Volumes](https://www.mongodb.com/docs/kubernetes/current/tutorial/resize-pv-storage/).
- Elastic: [Volume claim templates](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/volume-claim-templates).
- VSHN: [statefulset-resize-controller](https://github.com/vshn/statefulset-resize-controller).
- Argo CD: [Sync phases and waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/);
  [argocd-cmd-params-cm.yaml](https://github.com/argoproj/argo-cd/blob/master/docs/operator-manual/argocd-cmd-params-cm.yaml).
- Helm: [Chart hooks](https://helm.sh/docs/topics/charts_hooks/).
- shell-operator: [HOOKS.md](https://github.com/flant/shell-operator/blob/main/docs/src/HOOKS.md). Stars and
  releases of each project: the GitHub API, 2026-10-10.
