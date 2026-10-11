# Production settings

Which values MongoDB Search runs with in production, and why. The MongoDBSearch resource and its operator
(MongoDB Controllers for Kubernetes 1.13.0) leave several things that cannot be set, or cannot be changed once the
search exists. So the first values an install is given decide more here than they would elsewhere.

Each line says where it comes from: **lab** (measured on the lab by this repository), **MongoDB** (its documents,
its CRD or its operator's source), **Kubernetes**, **OpenShift**, **the chart** (its `values.yaml` and templates),
**not run** (nobody has shown it), or **to decide** (yours: a number or a name this repository does not have).
[examples/values-production.yaml](examples/values-production.yaml) is the same as a file. It does not install as
it is: `search.resources` holds the word `TO-DECIDE`, which the chart refuses, until the numbers are yours.

## In short

- **Size the volumes once, with room.** The operator cannot grow a volume. Growing one is a runbook, by hand or by
  the chart's own Job when `search.persistence.autoExpand.enabled` is set for that change. A volume is never made
  smaller: the preflight refuses a smaller size.
- **Keep the search through an uninstall**: `search.keepOnUninstall: true`. Without it an uninstall, a prune or
  the deletion of the Application deletes every index.
- **Never lower `search.replicas` in passing.** The volume of every pod that goes is deleted.
- **Keep the two disruption budgets on.** They are what makes a node drain take one mongot pod and one Envoy pod
  at a time.
- **Name every version**: the operator's, mongot's, Envoy's image and the Jobs' image.
- **Sync by hand, from a release tag.**
- **Keep the production values where the real names may be written**: not in this repository, which is public.

## What the resource does not let you do

| The limit | Where it is seen | What covers it |
| --- | --- | --- |
| **A volume cannot be grown through the resource.** A new size goes into the StatefulSet's volume claim template, which Kubernetes does not let change; the MongoDBSearch reads `Failed` and the operator can change nothing on mongot until the StatefulSet is made again. The pods keep answering | lab; Kubernetes; [mongodb-kubernetes #1621](https://github.com/mongodb/mongodb-kubernetes/pull/1621) | `search.persistence.storage` sized for growth (below). The chart's gate stops the sync and names the runbook: [volume-expansion-runbook.md](volume-expansion-runbook.md) with `expand-mongot-volumes.sh`. With `search.persistence.autoExpand.enabled: true`, set for that one change, a Job of the chart takes the runbook's steps by hand itself. `false` in the production example |
| **The storage class cannot be changed** on a search that exists: it is in the same template | Kubernetes. Not run: on the lab it was changed only after the search had been deleted | `search.persistence.storageClass` chosen once: a class that allows expansion |
| **The volume of a pod that is scaled away is deleted, and every volume when the resource is deleted.** The operator sets `whenScaled: Delete` and `whenDeleted: Delete` on the StatefulSet, and puts them back when they are changed; the resource's own override of them is ignored | lab; the operator's source: [volumes.md](volumes.md) | `search.keepOnUninstall: true`; `search.allowVolumeLoss: false`, with the preflight refusing fewer pods; the volumes set to `Retain` by a cluster administrator |
| **One volume a pod.** `persistence.multiple` (data, journal, logs) is in the schema and ignored for search | MongoDB: the operator's source at tag 1.13.0, `controllers/searchcontroller/search_construction.go`, lines 135 to 141, reads the single volume only | `search.persistence` has the single volume only |
| **No autoscaling.** The resource has no `scale` subresource, and the StatefulSet is the operator's | lab: [scaling.md](scaling.md) | `search.resources` and `search.replicas`, by hand, through git |
| **The heap is half of the memory request**, unless JVM flags say otherwise; this chart does not pass JVM flags | MongoDB; lab: a request of 1100Mi gave `-Xmx550m -Xms550m` | Size the heap through `search.resources.requests.memory` |
| **Argo CD cannot tell a failing search from a healthy one.** It has no health check for the resource: the Application read `Synced` and `Healthy` while the MongoDBSearch read `Failed` | lab: [argocd.md](argocd.md) | The chart's gate fails the sync; read the operation and the resource, not the Application's two words |
| **mongot's version follows the operator's** when the resource names none | The chart; MongoDB | `search.version` named |
| **Pods are spread over nodes by preference only, and the operator creates no PodDisruptionBudget.** It gives the mongot pods and the Envoy pods a preferred anti-affinity on the node's name, weight 100; nothing requires it. MongoDB's documents say nothing on node drains | lab, read from the StatefulSet and the Deployment; MongoDB: the operator's source at 1.13.0 | The chart's two budgets, `search.podDisruptionBudget` and `loadBalancer.podDisruptionBudget`: [disruption-budgets.md](disruption-budgets.md). A required spread is not settable through the chart |
| **Envoy's defaults are small and its image is a moving tag**: requests 100m and 128Mi, limits 500m and 512Mi, image `envoyproxy/envoy:v1.37-latest`. MongoDB states the defaults and gives no sizing for Envoy | lab, read from the Deployment; MongoDB | `loadBalancer.resources`, with the numbers below; `loadBalancer.image` named by digest |
| **Each Envoy pod runs one worker thread for every CPU of its node, whatever its CPU limit.** The operator starts Envoy without `--concurrency`, and Envoy 1.37 then "defaults to the number of hardware threads on the machine". On the lab: 12 worker threads on a node of 12 CPUs, under a limit of half a core | lab; the operator's source at 1.13.0; Envoy's documentation at v1.37.0 | A CPU limit of a core or more (below). The number of workers itself is not settable through the chart |

## The values

### The search

| Value | Production | Why | From |
| --- | --- | --- | --- |
| `search.name` | `mongot`, chosen before the certificates are made | The names of the three TLS secrets and of every object the operator makes derive from it, and the preflight looks the secrets up by those names. It is not changed on a search that exists | The chart |
| `search.replicas` | `3` | Each pod holds every index; three leave two answering while one restarts or rebuilds. More pods add searches a second, and add one change stream an index a pod to the source | MongoDB; lab |
| `search.allowVolumeLoss` | `false`, always in git | It is the switch that lets a scale-down delete volumes. Set it for the one sync that needs it and take it out with the next commit | lab |
| `search.podDisruptionBudget` | `enabled: true`, `maxUnavailable: 1`, the chart's | A node drain takes one mongot pod at a time and waits for it to be Ready again. On the lab the same evictions failed 37 of 195 searches without it and none of 191 with it | lab; Kubernetes |
| `search.keepOnUninstall` | `true` | Keeps the MongoDBSearch, its pods and its volumes through `helm uninstall`, an Argo CD prune and the deletion of the Application | lab |
| `search.version` | The mongot version, named: `"1.70.1"` with operator 1.13.0 | An operator upgrade then does not move mongot by itself | The chart |
| `search.persistence.storageClass` | `thin-csi` | It allows expansion as it ships, so the runbook can be used. Its reclaim policy is `Delete`: see the volumes below | OpenShift; to confirm on the cluster: `oc get storageclass thin-csi -o jsonpath='{.allowVolumeExpansion} {.reclaimPolicy}'` |
| `search.persistence.storage` | **To decide.** At least 1.47 times the indexes of one pod; for 190 GB of indexes, `300Gi` | Below | MongoDB; the arithmetic is this repository's |
| `search.resources` | **To decide**, from QA | Below | MongoDB |

**The volume's size.** mongot builds no index above 85% used, stops following the source above 90% and exits at
95%; MongoDB: "Plan for roughly 125% of the expected steady-state footprint during a rebuild." A rebuild of
everything on a volume therefore fits only while the indexes are under 68% of it (0.85 / 1.25), and the chart's
first alert is at 70%. Growing the volume later is the runbook, by hand or with `autoExpand`; neither has been run on vSphere yet.

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

- the memory request is twice the heap that is wanted, and not above about 56Gi, where the heap reaches 30 GB;
- the memory limit is the ceiling for the heap, the JVM's own memory outside the heap and the file system's cache
  together, since Linux counts a pod's cache in its memory: what the limit leaves after the first two is the most
  cache the pod can have. A limit equal to the request means the pod is promised all it runs with. (All of this
  bullet: Kubernetes and Linux; not measured here.);
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
| `loadBalancer.replicas` | `2` or more; `3` to keep two through a drain | MongoDB: "If you deploy multiple `mongot` replicas behind the load balancer and also run more than one Envoy replica, queries continue to run while the `mongot` or Envoy deployments undergo rolling restarts. With a single replica, queries see a brief gap until the pod is ready again." Its default is 1, and it names no number beyond "more than one". Two against three, measured: [disruption-budgets.md](disruption-budgets.md). One mongod sends every search over one connection, through one Envoy pod: under load on the lab the other Envoy pod carried no searches, so more pods are standby for a mongod and not capacity | MongoDB; lab |
| `loadBalancer.podDisruptionBudget` | `enabled: true`, `maxUnavailable: 1`, the chart's | A node drain takes one Envoy pod at a time. Without it both went at once on the lab, and no Envoy pod was Ready for about 10 s | lab; Kubernetes |
| `loadBalancer.externalHostname` | **To decide**: the public name mongod connects to | It is the Route's host and must be a name in the `...-search-lb-0-cert` certificate. A hostname, never an address | The chart |
| `loadBalancer.resources` | Requests `250m` and `256Mi`; limits `2` CPUs and `1Gi`. **A starting point**, to be read against QA | Below | What the projects that ship Envoy use; Envoy's documentation; lab |
| `loadBalancer.image` | A named Envoy image **by digest**, from a registry the cluster may pull from | The operator's own default is the moving tag `envoyproxy/envoy:v1.37-latest` | lab |
| `loadBalancer.retryPolicy` | The chart's: 2 retries, 60 s a try | Unchanged from the install runbook | The chart |
| `route.balance` | `roundrobin` | A passthrough Route defaults to `source`, which sent every connection to one Envoy pod | lab: [mongot-route-balance-rationale.md](../../docs/mongot-route-balance-rationale.md) |
| `route.name`, `route.enabled` | The chart's | | |

**Envoy's CPU and memory.** Neither MongoDB nor Envoy gives a number. MongoDB states the operator's defaults and
no rule; Envoy: "we do not currently publish any official benchmarks. We encourage users to benchmark Envoy in
their own environments with a configuration similar to what they plan on using in production." So the numbers
are taken from what the projects that ship Envoy on Kubernetes set, and from two facts about this Envoy.

| Who | CPU requested | CPU limit | Memory requested | Memory limit |
| --- | --- | --- | --- | --- |
| MongoDB's operator 1.13.0, for this Envoy | 100m | 500m | 128Mi | 512Mi |
| Istio 1.31.1, its gateway and its sidecar | 100m | 2000m | 128Mi | 1024Mi |
| Envoy Gateway 1.9.2 | 100m | none | 512Mi | none |
| Kuma 2.14.5, its sidecar | 50m | none | 64Mi | 512Mi |
| Emissary-ingress 4.1.0 (Envoy and its control plane in one pod) | 200m | none | 300Mi | 600Mi |

- **The CPU limit is a core or more, here 2.** Envoy keeps every search of one connection on one worker thread:
  "Envoy will allocate all streams for a given connection to a single worker thread." mongod holds a few
  long-lived connections, so one busy connection is one busy thread, and a limit of half a core lets it run half
  of every tenth of a second. The operator's 500m is the only limit under a core in the table. 2 is Istio's.
  **Measured on the lab**: with the default limit the Envoy pod that carried the searches began to be throttled at
  about 1,000 searches a second and was throttled in 28 to 34% of periods from about 1,300; with 2 CPUs it was
  never throttled, and at 32 searches at once the 95th percentile was 24 ms where it was 37 ms
  ([docs/envoy-performance-testing.md](docs/envoy-performance-testing.md)).
- **Raise mongot's CPU with it.** In the same test, with Envoy at 2 CPUs, the lab's mongot pods at 1 CPU each were
  throttled in 11% of periods at 32 searches at once and 22% at 64, where with Envoy at its default they were
  throttled in 1 to 2%: Envoy at its limit had been a brake on what reached mongot.
- **The limit also has to carry the idle workers**: one for every CPU of the node, above. Istio, which sets the
  number of workers from the CPU limit, says why: "If we are running on a 100 core machine, but with only 2 CPUs
  allocated, we want to have 2 threads, not 100, or we will get excessively throttled." This chart cannot set
  that number; a generous limit is what is left.
- **The CPU request, 250m**, is above Istio's measured cost of a proxy. At "1000 http requests per second
  containing 1 KB of payload each", "a single sidecar proxy with 2 worker threads consumes about 0.20 vCPU and 60
  MB of memory." That is Istio 1.24, and by the same page's test set-up HTTP/1.1 with small payloads and mutual
  TLS between sidecars, not searches streamed over gRPC: a guide, not a measurement of this load. On the lab,
  with searches of ten small results, the Envoy pod that carried them used about 0.4 CPUs at 1,000 searches a
  second; the two Envoy pods together used 0.7 to 0.9 thousandths of a CPU for each search a second at the lowest
  rate, 0.2 to 0.3 at the highest.
- **Memory, 256Mi requested and 1Gi at most.** On the lab no Envoy pod used more than 32 MiB over a day, near
  idle, and 36 MiB under load (42 MiB by its cgroup's count, which adds its cache). 1Gi is Istio's limit; Emissary's documentation says to "keep ... memory usage below 50% of the pod's
  limit". The limit is the only guard: the operator's Envoy has no overload manager, so a pod that reaches it is
  killed, not slowed.
- **What decides it is QA**, on the dashboard's Envoy section and these two: the share of periods in which the
  pod was throttled, `rate(container_cpu_cfs_throttled_periods_total[5m]) / rate(container_cpu_cfs_periods_total[5m])`
  for the Envoy container, which should stay near zero; and `container_memory_working_set_bytes` against the
  limit. On the lab, near idle, one period in about 2,500 was throttled on one of two pods, at its start, and
  the share read 0 after.

Where the table and the quotes are from: the operator's `controllers/operator/mongodbsearchenvoy_controller.go`
at tag 1.13.0; Istio's [gateway chart](https://github.com/istio/istio/blob/1.31.1/manifests/charts/gateway/values.yaml),
its `pilot/cmd/pilot-agent/config/config.go` and its
[Performance and Scalability](https://istio.io/latest/docs/ops/deployment/performance-and-scalability/) page;
Envoy Gateway's [`api/v1alpha1/shared_types.go`](https://github.com/envoyproxy/gateway/blob/v1.9.2/api/v1alpha1/shared_types.go);
Kuma's [`pkg/config/plugins/runtime/k8s/config.go`](https://github.com/kumahq/kuma/blob/v2.14.5/pkg/config/plugins/runtime/k8s/config.go);
Emissary-ingress's [chart values](https://github.com/emissary-ingress/emissary/blob/v4.1.0/charts/emissary-ingress/values.yaml)
and its documentation's [scaling page](https://github.com/datawire/ambassador-docs/blob/master/docs/emissary/latest/topics/running/scaling.md); Envoy's documentation at v1.37.0, `operations/cli`, `faq/performance/how_fast_is_envoy` and
`faq/performance/how_to_benchmark_envoy`. All read on 2026-10-10.

What is given in `loadBalancer.resources` replaces the operator's defaults whole. A change restarts the Envoy
pods one at a time, a new pod Ready before an old one stops: on the lab 139 searches were tried through such a
change, one a second, and all were answered.

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
| `jobs.resources` | The chart's, or what the namespace's quota asks for | A namespace whose ResourceQuota requires requests refuses a Job without them | The chart |
| `jobs.ttlSecondsAfterFinished` | `600` or longer | A failed hook's reason is only in its Job's log, and the log goes with the Job | lab |
| `wait.waitSeconds` | **To show on QA.** The chart's is 900 | The gate waits for every mongot pod to be Ready. On the lab that is under 2 minutes; whether a pod with 190 GB to build is Ready before or after its indexes are built decides this number, and was not measured | Not run |

## The Application

| Setting | Production | Why |
| --- | --- | --- |
| `targetRevision` | A release tag, `mongodb-search-helm-<version>` | A sync then changes only when that line does |
| `helm.releaseName` | `mongot` | The chart's object names start with it, and Helm can take over if it must |
| `helm.skipCrds` | `true` | The CRD is OLM's |
| `search.keepOnUninstall` | `true`, in the values or as a parameter | Above |
| `syncPolicy` | `{}`: sync by hand | A change of size stops at the gate by design, and automated sync then tries it five more times before it gives up, over about 11 minutes on the lab (7 when it is the preflight that refuses); a corrected commit waits for those. By hand there is one sync before the steps of the runbook and one after |
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
| The number of Envoy's worker threads (`--concurrency`) | None. It would be an argument of the Envoy container, through `clusters[].loadBalancer.managed.deployment`, which would have to restate the operator's own arguments | One worker for every CPU of the node |
| JVM flags, a heap that is not half the request | `clusters[].jvmFlags` | Half the request |
| mongot's log level | `logLevel` | The operator's default |
| How many mongot pods must be Ready before Envoy sends to them | `clusters[].loadBalancer.managed.minMongotReadyReplicas` | Not set. The CRD: "Defaults to 1 if not specified". The operator's source at 1.13.0 applies it to the shards of a sharded source only |

## To decide

| # | Decision | What it rests on |
| --- | --- | --- |
| 1 | `search.persistence.storage`: 300Gi or more | How much the indexes will grow, and whether "190 GB" is GB or GiB |
| 2 | `search.resources` | What QA's pods use: heap, CPU, lag, latency |
| 3 | `source.hostAndPorts`, `loadBalancer.externalHostname`, the namespace | Yours |
| 4 | Where the production values live | A repository of your own; then one run of that on the lab or on QA |
| 5 | The images by digest: Envoy, the Jobs, the index names exporter | Your registry |
| 6 | The first volume alert at 70 or 75 | 70 is this page's |
| 7 | Envoy's CPU and memory: the starting point above, or other numbers | What QA's Envoy pods use, and whether they are throttled |
| 8 | Two Envoy pods or three | Three keep two through a drain; the cost is one more pod's request |

## To show on QA first

None of these can be shown on the lab, whose indexes are 16 MiB a pod on one node.

- **A first install with the real data**: how long until every pod is Ready and every index `STEADY`, and whether
  the gate's 900 s are enough.
- **A volume that grows on vSphere**: the runbook with `--pod 0` first, by hand. On the lab's NFS class a claim's
  size is a number; a disk that takes time, a file system that waits for its pod, and *Data volume used* falling
  were not seen. Then one growth with `search.persistence.autoExpand.enabled: true`, before production relies on it:
  how long the Job takes on real disks, and that its sync passes.
- **One pod deleted**: that it comes back on its volume and goes on, with 190 GB.
- **A node drained**, with the two disruption budgets: that one mongot pod and one Envoy pod go at a time, how long a
  mongot pod with its vSphere disk takes to be Ready on another node, and so how long a node update takes.
- **Envoy under a real load**: its CPU against its limit and the share of throttled periods, with one worker thread
  for every CPU of a production node; its memory against its limit. `test/load/run.sh` in the repository is the
  test that was run on the lab. Where the namespace has a ResourceQuota or a
  LimitRange, the Envoy pods' requests and limits count against it.
- **A change of `operator.version`** under Argo CD.
