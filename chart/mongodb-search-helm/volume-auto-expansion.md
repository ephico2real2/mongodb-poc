# Growing mongot's volumes in one sync: how the resize works

How the volumes under mongot's indexes are grown when `search.persistence.autoExpand.enabled` is set: what you
change, what the chart then does, in which order, and what it checks before and after. The steps by hand, which the
chart takes for you here, are in [volume-expansion-runbook.md](volume-expansion-runbook.md).

For chart 0.3.26 and later, operator 1.13.0 (MongoDB Controllers for Kubernetes), mongot 1.70.1.

## In short

- **You change two values and sync.** A larger `search.persistence.storage`, and
  `search.persistence.autoExpand.enabled: true` for that change. Nothing is run by hand.
- **A Job of the chart does the rest, inside that sync.** It plans, grows each volume claim, has the StatefulSet
  made again with the same pods, restarts a pod only where its volume needs it, and verifies.
- **The search answers throughout.** On the lab the same mongot pods and the same claims went through every
  growth, and every search tried during them was answered.
- **The flag is off unless you set it**, and is meant to go off again after the change.
- **A volume is never made smaller.** A smaller size is refused before anything is touched.

## Why it takes a Job at all

A mongot pod's volume is made from a template in its StatefulSet, and Kubernetes does not let that template
change. So a larger size in the MongoDBSearch cannot reach the pods: the operator tries, Kubernetes refuses, and the
resource reads `Failed` (the pods keep running and answering). MongoDB's operator has no resize for search. What
works is what the runbook does by hand, and what this Job does for you: grow each claim itself, then delete the
StatefulSet while leaving its pods in place, so that the operator makes it again at the new size.

## What you do

```yaml
search:
  persistence:
    storage: 400Gi        # was 300Gi
    autoExpand:
      enabled: true       # for this change only
```

| # | Step |
| --- | --- |
| 1 | Check before starting: step 0 of the [runbook](volume-expansion-runbook.md), all of it |
| 2 | In the values: the larger size and the flag. In one change, or the size first and the flag after |
| 3 | Sync (Argo CD) or `helm upgrade` |
| 4 | Read the Job's verdict: `oc logs job/<release>-mongodb-search-helm-expand-volumes -n <namespace>`, while the Job is there (Argo CD removes it when the sync has succeeded) |
| 5 | The flag `false` again, and sync. Under Argo CD without automated pruning, one sync with pruning removes the Job's service account, role and script |

**The size first, the flag after** also works: the first sync stops at the gate, as it does without the flag, and
the sync that carries the flag takes it from there. Under Argo CD with automated sync that second sync begins only
once the first has spent its five retries (about 11 minutes on the lab); ending the first operation in the
console brings it forward. With both in one change there is one sync and no wait.

## What happens in the sync

<!-- markdownlint-disable MD033 -->
<img alt="With autoExpand on, one Argo CD sync grows mongot's volumes: the operator is refused the new size, then the chart's Job plans, grows each claim, has the StatefulSet made again with the same pods, restarts a pod only if its volume waits for it, and verifies, before the gate passes." src="https://raw.githubusercontent.com/ephico2real2/mongodb-poc/main/docs/diagrams/volume-expansion/one-sync.light.png">
<!-- markdownlint-enable MD033 -->

*One sync, with `autoExpand` on: the operator is refused the new size, and the chart's Job plans, grows each claim,
has the StatefulSet made again with the same pods, restarts a pod only where its volume waits for it, and verifies,
before the gate passes. On the lab steps 4 to 6 and 8 ran; the restart of step 7 did not, because no volume there
ever waits for its pod.*

```text
GIT AND ARGO CD                                   THE CLUSTER
1 the values: a larger size, and the flag on
2 Argo CD syncs; wave 1: the MongoDBSearch   ->   3 the operator is refused: Kubernetes forbids a change of a
  asks for the new size                             StatefulSet's volume size. The resource is Failed; the pods answer
                                                  wave 2, the Job:
                                                  4 plans: reads the sizes, changes nothing
                                                  5 grows each claim, one pod at a time
                                                  6 deletes the StatefulSet with --cascade=orphan; the operator makes
                                                    it again at the new size; the same pods, the same claims
                                                  7 restarts a pod only if its volume waits for it, one at a time
9 wave 3: the gate passes; the sync has      <-   8 verifies: Running, every claim at the size, every pod Ready,
  Succeeded. Then the flag off, and a sync          the file system each pod sees as large as its claim
  with pruning
```

| Step | What it is | If it does not hold |
| --- | --- | --- |
| 4 Plan | The script's `--plan`: what the resource asks for, what the StatefulSet's volumes were made at, what each claim asks for and has. From them, what is to be done | Nothing to do (a first install, a sync that changes no size): the Job ends, having read only. A smaller size, or a resize the cluster reports as failed: the Job fails, nothing changed |
| 5 Grow | `--expand`: each claim is asked for the new size, the lowest pod first, and waited for before the next | It stops at that claim. No pod, claim or StatefulSet was deleted |
| 6 The StatefulSet | `--recreate-statefulset`: deleted with `--cascade=orphan`, which leaves its pods and claims; the operator makes it again and adopts them | It stops and says not to delete the pods: they run on without a StatefulSet until the operator makes it |
| 7 Restart | `--restart-pending`: a claim that has waited two minutes for its pod (`FileSystemResizePending`) has that pod deleted; the pod keeps its claim and is waited for before the next. Storage that grows a file system in use never waits, and no pod is touched | It stops before the next pod. The next sync plans again and takes up what is left |
| 8 Verify | `--verify`: the resource `Running`, the StatefulSet and every claim at the size, no resize waiting, every pod Ready, and the file system each pod sees (`df`, inside the pod) at 95% of its claim or more | The Job fails and names what is not so, each with what to do |

The Job acts in two states only: the operator has refused the new size, or the resource is `Running` and the plan
shows the end of a growth left undone. In any other state (the resource still being reconciled, or `Failed` for
another reason) it prints the plan, changes nothing, and leaves the verdict to the gate.

## By hand, and with the flag

<!-- markdownlint-disable MD033 -->
<img alt="The same steps by hand and with the flag: by hand a person runs the script up to four times and syncs twice; with autoExpand on, one sync does all of it and nobody runs anything." src="https://raw.githubusercontent.com/ephico2real2/mongodb-poc/main/docs/diagrams/volume-expansion/by-hand-and-flag.light.png">
<!-- markdownlint-enable MD033 -->

*The same steps, by hand and with the flag. By hand the sync stops at the gate and a person runs the chart's script
for each step, then syncs again; with `autoExpand` on, the chart's Job runs that script inside the one sync.*

| | By hand (the flag off) | `autoExpand.enabled: true` |
| --- | --- | --- |
| The values | the larger size | the larger size, and the flag on |
| The sync | stops at the gate, by design: the resource is `Failed` | one sync: the Job runs before the gate |
| Grow the claims | a person: `expand-mongot-volumes.sh --expand` | the Job, with the same script |
| The StatefulSet again | a person: `--recreate-statefulset` | the Job |
| A pod whose volume waits | a person, if a claim waits: `--restart-pending` | the Job, if a claim waits |
| Sync again | a second sync, by hand once the retries are spent | not needed |
| Verify | a person: `--verify` | the Job: a growth not verified fails the sync |
| Afterwards | nothing | the flag off; under Argo CD, a sync with pruning |

## What the Job may do

In the release's namespace, and only while the flag is on:

| On | It may | For |
| --- | --- | --- |
| The MongoDBSearch, by name | read | the size asked for, the phase, the operator's message |
| The mongot StatefulSet, by name | read, delete | its size; the one delete, always sent with `--cascade=orphan` |
| Pods | read, list | each pod Ready before and after |
| The mongot pods, by name | delete | step 7: a pod whose volume waits for it |
| The mongot pods, by name | run a command in | `df`, for the plan and the verification |
| Volume claims | read, list, ask for more | step 5. A claim's size can only grow |

It may not delete a claim, or touch another pod. Two of these rights are why the flag is on for one change and not
always: a role cannot say "delete the StatefulSet with the orphan option only", and a right to run a command in a
pod is a right to read what that pod mounts, the sync user's password included.

## What was run, and what was not

| What | Where | Result |
| --- | --- | --- |
| A growth with the size and the flag in one change | The lab (OpenShift Local 4.22.7, Argo CD, NFS class), 2026-10-10 and 11, several times | One sync each, 57 to 65 s; the Job itself 7 to 14 s; the same pods and claims |
| The size first, then the flag | The lab, 10Gi to 11Gi | The gate stopped the first sync; the flag's sync began once the retries were spent, and passed in 67 s |
| The plan and the verification, chart 0.3.26 | The lab, 15Gi to 16Gi | "to do, in this order: grow 3 claim(s); make the StatefulSet again"; then the steps; then "file systems compared with their claims: 0; shared exports that cannot show it: 3" |
| A sync with the flag on and nothing to do | The lab, chart 0.3.26 | The plan: "nothing to do"; nothing else was run |
| A smaller size | The lab, 4Gi asked of 8Gi volumes | Refused by the Job, nothing changed. The preflight's refusal, which now comes first, is in the chart's tests only |
| Searches during all of it | The lab, through mongod | 566 tried while the growths from 8Gi to 16Gi were watched, 0 failed |
| **A pod restarted because its volume waits (step 7)** | Nowhere | Not run on a cluster. The lab's NFS volumes never wait for a pod. In the script's tests only |
| **A file system that grows, and the verification comparing it** | Nowhere | Not run on a cluster. On the lab each pod sees the NAS export (9.7 GiB) whatever its claim says, and the verification says so |
| Under Helm, without Argo CD | Nowhere | The chart's tests cover the order of the hooks only |

Run one growth on a cluster where it costs nothing, on the storage production uses, before relying on it there:
what the lab could not show is exactly what differs on real disks. The record of the lab's runs, and why this is a
Job and not a controller, is in the repository:
[docs/investigating-automatic-volume-expansion.md](https://github.com/ephico2real2/mongodb-poc/blob/main/docs/investigating-automatic-volume-expansion.md).

## Diagram sources

The two figures are drawn in
[docs/diagrams/volume-expansion/source.html](https://github.com/ephico2real2/mongodb-poc/blob/main/docs/diagrams/volume-expansion/source.html)
and rendered with [diagram-kit](https://github.com/ephico2real2/diagram-kit);
[docs/diagrams/README.md](https://github.com/ephico2real2/mongodb-poc/blob/main/docs/diagrams/README.md) has the
command. A figure, its text twin here and its page change together. The pictures are linked, not packaged with the
chart.
