# Scaling mongot

How mongot is given more room with this chart, what each change does to the pods and their volumes, and why the
StatefulSet is never scaled by hand. For operator 1.13.0 (MongoDB Controllers for Kubernetes) and mongot 1.70.1;
the lab's measurements are of 2026-10-09.

## In short

- **Nothing scales mongot by itself.** The operator has no autoscaling, and an autoscaler of Kubernetes cannot
  drive it. Scaling is a change of the chart's values.
- **More CPU and memory for each pod is the first step**, by MongoDB's own advice: `search.resources`.
- **More pods add capacity for searches, not for indexing**, and each new pod builds every index from the
  collection before it serves: `search.replicas`.
- **Fewer pods delete volumes.** See [volumes.md](volumes.md).

## There is no autoscaling

| Looked at | Found |
| --- | --- |
| The MongoDBSearch resource on the lab | Its only subresource is `status`. A HorizontalPodAutoscaler needs a `scale` subresource on what it drives, so it cannot drive the resource |
| MongoDB's reference for the resource ([MongoDBSearch settings](https://www.mongodb.com/docs/kubernetes/current/reference/k8s-operator-search-specification/)) | Nothing on autoscaling, a HorizontalPodAutoscaler or a VerticalPodAutoscaler. Scaling is `spec.clusters[].replicas` and `spec.clusters[].resourceRequirements` |
| An autoscaler aimed at the StatefulSet instead | Not tried, and not to be: the StatefulSet is the operator's, which puts its own replica count back within seconds, after the pod and its volume are already gone (below) |
| MongoDB's sizing pages | Nothing on autoscaling. They give the signals to act on by hand (below) |

## What to change, and when

MongoDB's guidance, quoted from [Hardware Considerations for mongot Deployments](https://www.mongodb.com/docs/search/self-managed/current/resource-planning-sizing/hardware/)
and [Resource Allocation Considerations](https://www.mongodb.com/docs/search/self-managed/current/resource-planning-sizing/resource-allocation/):

| Signal | MongoDB's words | Change |
| --- | --- | --- |
| CPU of the pods | "Consistently seeing CPU usage above 80% suggests a need to scale up (add CPU cores), while consistently below 20% may indicate an opportunity to scale down (reduce CPU cores)." | `search.resources` |
| Replication lag that grows | "Monitor the `mongot` process's CPU utilization and disk I/O queue length. If these metrics are consistently high and replication lag is growing, you need to scale up your hardware." | `search.resources`; see *Replication lag* in the README |
| Memory | "As an estimate, allocate 50% of the total available system memory, without exceeding a maximum of approximately 30GB" to the heap; the rest is the file system's cache, on which "query latency and throughput heavily depend" | `search.resources`. The operator sets the heap to half of the memory request by itself |
| Searches wait, latency rises | "Vertical scaling primarily impacts query latency by being able to serve more queries in parallel and reducing query request queuing." | `search.resources` |
| More searches a second than the pods can take | "Horizontal scaling (adding more `mongot` nodes) increases total CPU to increase QPS." A first estimate is "10 QPS per CPU core" | `search.replicas`, upward |
| What more pods cost | "Horizontal scaling adds additional load to a replica set because each `mongot` needs to replicate index data from a source collection. Each search or vector search index creates a new change stream per `mongot`" | Count it before adding pods |

The dashboard has the signals per pod: *CPU used*, *JVM heap used, percent of limit*, *Replication lag* and
*Average search latency*.

## More CPU or memory: `search.resources`

```yaml
search:
  resources:
    requests: {cpu: "2", memory: 8Gi}
    limits: {cpu: "4", memory: 12Gi}
```

Then `helm upgrade` with the release's values file, or an Argo CD sync. The operator changes the StatefulSet's pod
template, and Kubernetes restarts the pods one at a time, the highest number first, each Ready before the next.

- **Each pod comes back on its own volume**, with its indexes, and goes on from where it was: nothing is built
  again, provided the source's oplog still reaches back to when the pod stopped.
- **The heap follows the memory request**: without `-Xms` or `-Xmx` among the JVM flags the operator sets both
  "to half of `spec.clusters[].resourceRequirements.requests.memory`".
- **The other pods stay up while one restarts.**

Measured on the lab: the memory request raised from 1Gi to 1100Mi with `helm upgrade`. The three pods were restarted
one at a time, 32 seconds apart, the third first; the upgrade and its gate took 118 seconds; each pod kept its
volume claim (the same three uids before and after); and the pods then ran with `-Xms550m -Xmx550m`.

## More pods: `search.replicas`, upward

```yaml
search:
  replicas: 4
```

A new pod gets a new, empty volume and builds every index from the collection before it serves it. On a large
deployment that is hours (4 to 5 for about 180 GB, as the owner reports for QA), during which the source carries
that pod's initial sync. Add pods one upgrade at a time, and wait for each to be `STEADY` on every index.

## Fewer pods: `search.replicas`, downward

The operator deletes the volume of every pod that goes, at once; a pod that is added back later starts from
nothing. The chart's preflight refuses the upgrade unless `search.allowVolumeLoss: true` is set for it.
[volumes.md](volumes.md) has the whole of it.

## Scaling a StatefulSet by hand, and why not here

In Kubernetes a StatefulSet that you own is scaled with one of these
([Scale a StatefulSet](https://kubernetes.io/docs/tasks/run-application/scale-stateful-set/)):

```bash
kubectl scale statefulsets <stateful-set-name> --replicas=<new-replicas>
kubectl patch statefulsets <stateful-set-name> -p '{"spec":{"replicas":<new-replicas>}}'
kubectl edit statefulsets <stateful-set-name>        # and change .spec.replicas
```

and its pods are given other resources by changing the pod template, which restarts them one by one:

```bash
kubectl set resources statefulset <stateful-set-name> -c <container> --requests=cpu=2,memory=8Gi --limits=cpu=4,memory=12Gi
kubectl rollout status statefulset <stateful-set-name>
```

Kubernetes adds two cautions: scale only when "your stateful application cluster is completely healthy", and "You
cannot scale down a StatefulSet when any of the stateful Pods it manages is unhealthy."

**None of this is for mongot's StatefulSet.** It belongs to the operator, which writes it from the MongoDBSearch
resource and undoes what was changed by hand. On the lab:

| Done by hand | What followed |
| --- | --- |
| `oc scale statefulset mongot-search-0 --replicas=2` | The operator set 3 again within 5 s. The third pod was already terminating, and its volume claim was deleted 8 s after the command. The StatefulSet then ran with 2 pods for 7 min 11 s before the third came back, on a new volume, and built its indexes again |
| The volume retention policy patched on the StatefulSet | Put back by the operator within 11 s |

So a change made on the StatefulSet does not last, and a scale-down made there costs a volume all the same. The
one thing done to this StatefulSet by hand is the delete with `--cascade=orphan` of the
[volume expansion runbook](volume-expansion-runbook.md), which keeps every pod and every volume.

## Where the values go

| Value of the chart | Field of the MongoDBSearch | What the operator does with a change |
| --- | --- | --- |
| `search.replicas` | `spec.clusters[].replicas` | Scales the StatefulSet. Downward it deletes volumes |
| `search.resources` | `spec.clusters[].resourceRequirements` | Changes the pod template: a rolling restart, each pod on its volume |
| `search.persistence.storage` | `spec.clusters[].persistence.single.storage` | Cannot apply it to a running StatefulSet: the resource is `Failed` until the [runbook](volume-expansion-runbook.md) is done |
| `loadBalancer.replicas` | `spec.clusters[].loadBalancer.managed.replicas` | Scales the Envoy Deployment. Envoy has no volume |
