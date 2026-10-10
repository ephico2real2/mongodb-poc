# Production settings

Which values MongoDB Search runs with in production, and why. The MongoDBSearch resource and its operator
(MongoDB Controllers for Kubernetes 1.13.0) leave several things that cannot be set, or cannot be changed once the
search exists. So the first values an install is given decide more here than they would elsewhere.

Each line says where it comes from: **lab** (measured on the lab by this repository), **MongoDB** (its documents or
its operator's source), **Kubernetes**, or **to decide** (yours: a number or a name this repository does not have).
[examples/values-production.yaml](examples/values-production.yaml) is the same as a file.

## In short

- **Size the volumes once, with room.** The operator cannot grow a volume; growing one is a runbook by hand.
- **Keep the search through an uninstall**: `search.keepOnUninstall: true`. Without it an uninstall, a prune or
  the deletion of the Application deletes every index.
- **Never lower `search.replicas` in passing.** The volume of every pod that goes is deleted.
- **Name every version**: the operator's, mongot's, Envoy's image and the Jobs' image.
- **Sync by hand, from a release tag.**
- **Keep the production values where the real names may be written**: not in this repository, which is public.

## What the resource does not let you do

| The limit | Where it is seen | What covers it |
| --- | --- | --- |
| **A volume cannot be grown through the resource.** A new size goes into the StatefulSet's volume claim template, which Kubernetes does not let change; the MongoDBSearch reads `Failed` and the operator can change nothing on mongot until the StatefulSet is made again. The pods keep answering | lab; Kubernetes; [mongodb-kubernetes #1621](https://github.com/mongodb/mongodb-kubernetes/pull/1621) | `search.persistence.storage` sized for growth (below). The chart's gate stops the sync and names the runbook: [volume-expansion-runbook.md](volume-expansion-runbook.md) with `expand-mongot-volumes.sh` |
| **The storage class cannot be changed** on a search that exists: it is in the same template | Kubernetes. Not run: on the lab it was changed only after the search had been deleted | `search.persistence.storageClass` chosen once: a class that allows expansion |
| **The volume of a pod that is scaled away is deleted, and every volume when the resource is deleted.** The operator sets `whenScaled: Delete` and `whenDeleted: Delete` on the StatefulSet, and puts them back when they are changed; the resource's own override of them is ignored | lab; the operator's source: [volumes.md](volumes.md) | `search.keepOnUninstall: true`; `search.allowVolumeLoss: false`, with the preflight refusing fewer pods; the volumes set to `Retain` by a cluster administrator |
| **One volume a pod.** `persistence.multiple` (data, journal, logs) is in the schema and ignored for search | The operator's source, read at 1.12.0: [mongodb-operator-storage.md](../../enhancement/mongodb-operator-storage.md) | `search.persistence` has the single volume only |
| **No autoscaling.** The resource has no `scale` subresource, and the StatefulSet is the operator's | lab: [scaling.md](scaling.md) | `search.resources` and `search.replicas`, by hand, through git |
| **The heap is half of the memory request**, unless JVM flags say otherwise; this chart does not pass JVM flags | MongoDB; lab: 1100Mi gave `-Xms550m -Xmx550m` | Size the heap through `search.resources.requests.memory` |
| **Argo CD cannot tell a failing search from a healthy one.** It has no health check for the resource: the Application read `Synced` and `Healthy` while the MongoDBSearch read `Failed` | lab: [argocd.md](argocd.md) | The chart's gate fails the sync; read the operation and the resource, not the Application's two words |
| **mongot's version follows the operator's** when the resource names none | The chart; MongoDB | `search.version` named |
| **Pods are spread over nodes by preference only**, and there is no PodDisruptionBudget. The operator gives the mongot pods and the Envoy pods a preferred anti-affinity on the node's name, weight 100; nothing requires it | lab, read from the StatefulSet and the Deployment. What a node drain then does was not run: the lab has one node | Nothing in the chart today. See "Not settable through the chart" |
| **Envoy's defaults are small and its image is a moving tag**: requests 100m and 128Mi, limits 500m and 512Mi, image `envoyproxy/envoy:v1.37-latest` | lab, read from the Deployment | `loadBalancer.image` named by digest. Its resources: not settable through the chart today |

## The values

### The search

| Value | Production | Why | From |
| --- | --- | --- | --- |
| `search.replicas` | `3` | Each pod holds every index; three leave two answering while one restarts or rebuilds. More pods add searches a second, and add one change stream an index a pod to the source | MongoDB; lab |
| `search.allowVolumeLoss` | `false`, always in git | It is the switch that lets a scale-down delete volumes. Set it for the one sync that needs it and take it out with the next commit | lab |
| `search.keepOnUninstall` | `true` | Keeps the MongoDBSearch, its pods and its volumes through `helm uninstall`, an Argo CD prune and the deletion of the Application | lab |
| `search.version` | The mongot version, named: `"1.70.1"` with operator 1.13.0 | An operator upgrade then does not move mongot by itself | The chart |
| `search.persistence.storageClass` | `thin-csi` | It allows expansion as it ships, so the runbook can be used. Its reclaim policy is `Delete`: see the volumes below | OpenShift; to confirm on the cluster: `oc get storageclass thin-csi -o jsonpath='{.allowVolumeExpansion} {.reclaimPolicy}'` |
| `search.persistence.storage` | **To decide.** At least 1.47 times the indexes of one pod; for 190 GB of indexes, `300Gi` | Below | MongoDB; the arithmetic is this repository's |
| `search.resources` | **To decide**, from QA | Below | MongoDB |

**The volume's size.** mongot builds no index above 85% used, stops following the source above 90% and exits at
95%; MongoDB: "Plan for roughly 125% of the expected steady-state footprint during a rebuild." A rebuild of
everything on a volume therefore fits only while the indexes are under 68% of it (0.85 / 1.25), and the chart's
first alert is at 70%. Growing the volume later is the runbook, which has not been run on vSphere yet.

| Indexes on one pod | The smallest volume a full rebuild fits on | On `300Gi` | On `400Gi` |
| --- | --- | --- | --- |
| 190 GB (177 GiB), the larger of the owner's two figures for QA | 260 GiB | 59% used; a full rebuild peaks at 74% | 44%; 55% |
| 250 GB (233 GiB) | 342 GiB | 78%: no room for a full rebuild, the info alert firing | 58%; 73% |

So `300Gi` holds today's indexes with a rebuild, and its room for a full rebuild ends at about 219 GB of indexes
(204 GiB), 15% above today's. If the indexes are expected to grow by more than that, choose the larger size now. The figures take
the owner's "180 to 190 GB" as decimal gigabytes; if they were read from `df`, they are GiB and every size above
is 7% short.

**CPU and memory.** MongoDB gives the rule, not the number: "As an estimate, allocate 50% of the total available
system memory, without exceeding a maximum of approximately 30GB" to the heap, the rest being the file system's
cache, on which "query latency and throughput heavily depend"; and for CPU, a first estimate of "10 QPS per CPU
core", with "Consistently seeing CPU usage above 80% suggests a need to scale up". With this chart the heap is half
of the memory request, so:

- the memory request is twice the heap that is wanted, and not above 60Gi, where the heap reaches 30 GB;
- the memory limit is the ceiling for the heap and the file system's cache together, since Linux counts a pod's
  cache in its memory: what lies between the heap and the limit is the most cache the pod can have. A limit equal
  to the request means the pod is promised all it runs with (Kubernetes; not measured here);
- take the numbers from QA's dashboard, section *How is each mongot pod doing?*: *JVM heap used, percent of
  limit*, *CPU used*, *Replication lag*, *Average search latency*.

The chart's defaults (1 CPU and 3Gi requested) are the install runbook's, for a small deployment. They are not a
proposal for 190 GB of indexes.

### The volumes themselves

Not a value of the chart: a step for a cluster administrator, once for each mongot volume, after the install and
after every pod that is added.

```bash
bash expand-mongot-volumes.sh --check --statefulset <search name>-search-0     # prints each volume and its policy
oc patch persistentvolume <the volume's name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

With `thin-csi` as it ships, a deleted claim takes its disk and its index with it. `Retain` keeps the disk whatever
deletes the claim: it is the one protection that nothing in the operator undoes. A retained disk is then removed by
hand when it is no longer wanted. Binding a retained disk back to a returning pod has not been run by this
repository.

### Envoy and the Route

| Value | Production | Why | From |
| --- | --- | --- | --- |
| `loadBalancer.replicas` | `2` or more | The operator's default is 1, and a restart then cuts every search in flight | MongoDB |
| `loadBalancer.externalHostname` | **To decide**: the public name mongod connects to | It is the Route's host and must be a name in the `...-search-lb-0-cert` certificate. A hostname, never an address | The chart |
| `loadBalancer.image` | A named Envoy image **by digest**, from a registry the cluster may pull from | The operator's own default is the moving tag `envoyproxy/envoy:v1.37-latest` | lab |
| `loadBalancer.retryPolicy` | The chart's: 2 retries, 60 s a try | Unchanged from the install runbook | The chart |
| `route.balance` | `roundrobin` | A passthrough Route defaults to `source`, which sent every connection to one Envoy pod | lab: [mongot-route-balance-rationale.md](../../docs/mongot-route-balance-rationale.md) |
| `route.name`, `route.enabled` | The chart's | | |

### The source

| Value | Production | Why | From |
| --- | --- | --- | --- |
| `source.hostAndPorts` | **Every member** of the replica set, one `host:port` each | mongot then keeps following when one member is down. One host is one point of failure | The chart |
| `source.username`, `source.passwordSecret` | The sync user and its Secret, made by `generate-mongodbsearch-prerequisites.sh` | The chart never reads or creates the password | The chart |
| `tls.certsSecretPrefix`, `tls.trustBundleConfigMap` | As the prerequisites were made: `ent`, `ent-trust-bundle` | A wrong prefix is not an error to the operator: the preflight is what catches it | The chart |

### The operator

| Value | Production | Why | From |
| --- | --- | --- | --- |
| `operator.install` | `true`, unless an operator already serves the namespace | | The chart |
| `operator.version` | Named: `"1.13.0"` | It is the only version the chart's approver approves; the Subscription is on manual approval, so a newer version waits for this value to change | lab |
| `operatorGroup.create` | `true`, unless the namespace has an OperatorGroup | OLM allows one a namespace; the preflight refuses a second | The chart |
| `csvReclaim`, `installPlanApprover`, `preflight` | The chart's, all on | The preflight is what refuses a scale-down and a missing prerequisite | lab |

### Monitoring

| Value | Production | Why | From |
| --- | --- | --- | --- |
| `monitoring.serviceMonitors.enabled` | `true` | Needs user workload monitoring on the cluster | The chart |
| `monitoring.alerts.enabled` | `true` | Twelve alerts; the first fires when one pod serves over 90% of the searches | lab |
| `monitoring.alerts.dataPathUsed` | `info: 70`, `warning: 80`, `critical: 90` | 70 is beside the 68% above which a full rebuild no longer fits; MongoDB's own are one step later (85, 90, 95), where mongot already acts | MongoDB; **to decide**: 70 or 75 for the first |
| `monitoring.alerts.runbookUrl` | A page your on-call can open | The default points into this public repository | To decide |
| `monitoring.persesDashboard.enabled` | `true` where the Cluster Observability Operator (1.5 or later) is installed; `false` elsewhere | Without it the kinds do not exist and the install fails | The chart |
| `monitoring.grafanaDashboard` | `true` only where a Grafana sidecar reads such ConfigMaps | | The chart |
| `monitoring.indexInfo.enabled` | `true`, with its own database user | Without it an index is a 24-character id on the dashboard. It needs a user that may list indexes and read no document, and its password in a Secret made by hand | lab |
| `monitoring.indexInfo.image` | The image by digest, from a registry the cluster may pull from | The default is on quay.io | The chart |

### The Jobs and the gate

| Value | Production | Why | From |
| --- | --- | --- | --- |
| `jobs.image` | `ose-cli` at a named tag or digest, matching the cluster's version | The default tag is `latest` | The chart |
| `jobs.ttlSecondsAfterFinished` | `600` or longer | A failed hook's reason is only in its Job's log, and the log goes with the Job | lab |
| `wait.waitSeconds` | **To show on QA.** The chart's is 900 | The gate waits for every mongot pod to be Ready. On the lab that is under 2 minutes; whether a pod with 190 GB to build is Ready before or after its indexes are built decides this number, and was not measured | Not run |

## The Application

| Setting | Production | Why |
| --- | --- | --- |
| `targetRevision` | A release tag, `mongodb-search-helm-<version>` | A sync then changes only when that line does |
| `helm.releaseName` | `mongot` | The chart's object names start with it, and Helm can take over if it must |
| `helm.skipCrds` | `true` | The CRD is OLM's |
| `search.keepOnUninstall` | `true`, in the values or as a parameter | Above |
| `syncPolicy` | `{}`: sync by hand | A change of size stops at the gate by design, and automated sync then tries it five more times over about 11 minutes before it gives up; a corrected commit waits for those. By hand there is one sync before the steps of the runbook and one after |
| Prune, `selfHeal` | Neither | A prune skips the MongoDBSearch only while `search.keepOnUninstall` is set. `selfHeal` was not run |
| `ignoreDifferences` | The Route's `/status` | The router writes it |
| The values | In a repository of your own, not in this one | This repository is public, and the values hold your host names. **Not run**: every run on the lab read its values from this repository. A second source, or `valuesObject` in the Application, are among Argo CD's ways |

[examples/argocd-application.yaml](examples/argocd-application.yaml) is this Application for the R&D namespace.

## Not settable through the chart today

The resource has a field for each; the chart has no value for it. Each would be a change to the chart, not a
setting.

| Wanted | The resource's field | Today |
| --- | --- | --- |
| mongot pods on different nodes, as a rule | `clusters[].nodeAffinity` places pods on kinds of node; a required pod anti-affinity would go through `clusters[].statefulSet` | The operator's preferred anti-affinity only. An override through `statefulSet` restarted every mongot pod on the lab when one was tried |
| A PodDisruptionBudget for mongot and for Envoy | None: it is an object of its own | None exists. A node drain is not held back |
| Envoy's CPU and memory | `loadBalancer.managed.resourceRequirements` | The operator's defaults: 100m and 128Mi requested, 500m and 512Mi at most |
| JVM flags, a heap that is not half the request | `clusters[].jvmFlags` | Half the request |
| mongot's log level | `logLevel` | The operator's default |
| How many mongot pods must be Ready before Envoy sends to them | `loadBalancer.managed.minMongotReadyReplicas` | Not set |

## To decide

| # | Decision | What it rests on |
| --- | --- | --- |
| 1 | `search.persistence.storage`: 300Gi or more | How much the indexes will grow, and whether "190 GB" is GB or GiB |
| 2 | `search.resources` | What QA's pods use: heap, CPU, lag, latency |
| 3 | `source.hostAndPorts`, `loadBalancer.externalHostname`, the namespace | Yours |
| 4 | Where the production values live | A repository of your own; then one run of that on the lab or on QA |
| 5 | The images by digest: Envoy, the Jobs, the index names exporter | Your registry |
| 6 | The first volume alert at 70 or 75 | 70 is this page's |
| 7 | Whether the chart should gain the values of "Not settable" before production | Mostly the disruption budget and Envoy's resources |

## To show on QA first

None of these can be shown on the lab, whose indexes are 16 MiB a pod on one node.

- **A first install with the real data**: how long until every pod is Ready and every index `STEADY`, and whether
  the gate's 900 s are enough.
- **A volume that grows on vSphere**: the runbook with `--pod 0` first. On the lab's NFS class a claim's size is a
  number; a disk that takes time, a file system that waits for its pod, and *Data volume used* falling were not
  seen.
- **One pod deleted**: that it comes back on its volume and goes on, with 190 GB.
- **A node drained**, with three mongot pods and two Envoy pods and no disruption budget.
- **A change of `operator.version`** under Argo CD.
