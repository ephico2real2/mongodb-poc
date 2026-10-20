# mongot's own settings

What `search.advancedMongotConfigs` and `search.jvmFlags` set, how the MongoDBSearch resource carries them to mongot,
how mongot works out each default, what each has to do with the pod's CPU and memory, and how to change them. For
operator 1.13.0 (MongoDB Controllers for Kubernetes) and mongot 1.70.1; every default and meaning below is read from
their source at those versions.

## In short

- **Every value is optional, and null by default.** A null is left out and mongot works out its own default; with
  every value null the chart renders no `advancedMongotConfigs` at all.
- **The operator does not read the block.** It writes it, as it is, under `advancedConfigs` in mongot's config file.
  mongot checks it when it starts: a count that is not a whole number above 0, and it does not start; a key it does
  not know, and it starts without it, with a warning in its log. The chart's schema accepts only mongot's keys at
  the top, under `replication` and under `replication.mongodb`.
- **Three of the five concurrency defaults rise with the CPU count, and a fourth up to 2 CPUs**; the CPU count mongot
  sees is the pod's CPU **limit**, never the request. None of the five follows memory.
- **A change restarts every mongot pod**, one at a time, and interrupts every index being built: change them when
  every index is `STEADY`. mongot resumes an interrupted build from the progress it last committed, when it
  committed any (`ReplicationIndexManager.java:484-491`; read from the source, not run).
- **The one worth changing is `numConcurrentInitialSyncs`**, for a faster rebuild of many indexes. The others are
  sized by the CPU limit already.

## From the values to mongot

| Step | What happens | Source |
| --- | --- | --- |
| 1. The values | `search.advancedMongotConfigs`, with the five counts below present as nulls | `values.yaml` |
| 2. The chart | Leaves out every null in a map, and every map left empty, then writes the rest under `spec.clusters[0].advancedMongotConfigs`. The schema accepts only mongot's keys at the top (eight), under `replication` (one) and under `replication.mongodb` (ten), and the counts only as whole numbers from 1 to 2147483647 | `templates/_helpers.tpl` (`withoutNulls`), `values.schema.json` |
| 3. The resource | `advancedMongotConfigs` is "an opaque block of mongot settings rendered verbatim under the advancedConfigs key of this cluster's mongot config file. The operator neither reads nor modifies it". The CRD types it as an object and keeps every key in it | `crds/mongodbsearch.mongodb.com.yaml`, `x-kubernetes-preserve-unknown-fields: true` |
| 4. The operator | Writes mongot's `config.yml` in a ConfigMap with the block under `advancedConfigs`. An empty block is left out of the file, but a block of empty maps is not, which is why step 2 removes them | `mongodbsearch_reconcile_helper.go:1406-1416` |
| 5. The restart | Hashes the config file into the pods' `mongotConfigHash` annotation, so any change to the block changes the pod template and Kubernetes restarts the pods one at a time | `mongodbsearch_reconcile_helper.go:780-782`, `1341`, `1435-1443` |
| 6. mongot | Parses the file at start. A value of the wrong type, or a count not above 0, stops it: "failed to parse config file". An unknown field does not: the parse is permissive, and mongot logs `Ignoring unrecognized field(s) in mongot config file: ...` and goes on. Each count is an `intField().mustBePositive()`. For each count not given it works out a default, and logs it for three: `numConcurrentInitialSyncs not configured, defaulting to 2.`; never for `numIndexingThreads` or `numConcurrentSynonymSyncs` | `CommunityConfig.java:100-108`, `PermissiveBsonParseContext.java:48-55`, `CommunityMongotBootstrapper.java:124-126`, `:156-157`, `:929-938`, `CommunityReplicationConfig.java:21-107`, `MongoDbReplicationConfig.java:201-203`, `:270-337` |

## The CPU count mongot works from

mongot's `Runtime.getNumCpus()` is Java's `availableProcessors()`. In a container, JDK 21 (adoptium
`jdk-21.0.11+10`, `cgroupUtil_linux.cpp:28-49`) counts:

| The pod has | CPUs counted |
| --- | --- |
| A CPU limit | The limit, rounded up (`ceil(quota / period)` from cgroup v2's `cpu.max`), at most the node's CPUs. A limit of `1500m` counts 2 |
| No CPU limit | Every CPU of the node |
| `-XX:ActiveProcessorCount=N` in `search.jvmFlags` | N, whatever the limit (`os_linux.cpp:4943-4962`) |
| Only a CPU request | The request is never read: as with no limit, every CPU of the node |

With a CPU limit of 6, the defaults mongot logs at start are worked out from 6 CPUs: 2 initial syncs, 12
change streams and 3 decoding threads (the table below).

## The five settings

All five are under `replication.mongodb`. Each is a whole number: a YAML integer, not quoted. mongot reads each as
an integer that must be above 0; the chart refuses `0`, `"3"`, `[]` and `{}` before anything reaches mongot.

| Setting | What it is (mongot's words) | Default | At 2 CPUs | At 6 CPUs | At 8 CPUs |
| --- | --- | --- | --- | --- | --- |
| `numConcurrentInitialSyncs` | "The number of initial syncs that are allowed to be run concurrently": how many indexes are built from the collection at once. Further indexes wait in a queue | The CPUs, at most 2: `min(CPUs, 2)` | 2 | 2 | 2 |
| `numConcurrentChangeStreams` | "The number of steady state change streams that are allowed to have outstanding getMores issued at any given time": how many indexes can be fetching changes from the source at once, once built | 2 per CPU: `CPUs × 2` | 4 | 12 | 16 |
| `numIndexingThreads` | "The number of indexing threads to use in the scheduler": the threads that write documents into the indexes | One per CPU: `CPUs`. Community mongot fills it in before the common default of half the CPUs applies, so mongot logs no default line for it | 2 | 6 | 8 |
| `numChangeStreamDecodingThreads` | "The number of change-stream batches decoding threads. Used in steady-state replication" | Half the CPUs, at least 1: `max(1, floor(CPUs / 2))` | 1 | 3 | 4 |
| `numConcurrentSynonymSyncs` | "The number of synonym sync operations that are allowed to be run concurrently": synonym collections, for indexes that define synonyms | 2, whatever the CPUs. mongot logs no default line for it | 2 | 2 | 2 |

Sources: meanings `MongoDbReplicationConfig.java:30-58`; defaults `:24-25`, `:201-202`, `:270-337`; `numIndexingThreads`
in community `MongoDbReplicationConfigMapper.java:57-60`, called from `CommunityMongotBootstrapper.java:955`.

## What they have to do with CPU and memory

**CPU.** Three of the five rise with the CPU count (`numConcurrentChangeStreams`, `numIndexingThreads`,
`numChangeStreamDecodingThreads`), so the pod's CPU limit already sizes them: raise the limit and they rise at the next
start. `numConcurrentInitialSyncs` follows the count only up to 2 CPUs, and stays 2 above. Setting one by hand fixes
it, and it no longer follows the limit. `-XX:ActiveProcessorCount` in `search.jvmFlags` moves all four at once, along
with every other thread pool the JVM and mongot size from the CPU count.

**Memory.** None of the five reads the memory. Memory is set apart:

| What | Where it comes from |
| --- | --- |
| The JVM heap | The operator sets `-Xms` and `-Xmx` to half of the memory **request**, at most 30Gi, unless `search.jvmFlags` holds a flag that starts with `-Xms` or `-Xmx` (`search_construction.go:64-66`, `:272-293`) |
| Everything above the heap, up to the memory limit | The JVM's own memory outside the heap, and the file-system cache that holds the index |

More initial syncs or change streams at once means more work in flight in the heap. How much more was not measured:
read *JVM heap used* on the dashboard during a rebuild before raising them.

**Disk.** `numConcurrentInitialSyncs` counts builds at once: each takes one of N permits (`InitialSyncQueue.java:638`),
and the same generation of an index is never queued twice (`:431-433`, a check that throws).
A rebuild of an index that exists keeps its old copy serving until the new one is ready (MongoDB plans 125% of an
index's size for it), so with 4, four different indexes each have a new copy beside the old one at the same time.
A new index, or a pod on an empty volume, builds the only copy. mongot pauses initial syncs at 85% of the disk; the
chart's alerts start at 70%.

**The source.** Each initial sync scans a collection on the source, and each change stream holds a cursor there.
More of either is more load on the replica set.

## How to change them

In the values file of the release (in git, under Argo CD):

```yaml
search:
  advancedMongotConfigs:
    replication:
      mongodb:
        numConcurrentInitialSyncs: 3
```

Only the value given is rendered:

```yaml
spec:
  clusters:
    - advancedMongotConfigs:
        replication:
          mongodb:
            numConcurrentInitialSyncs: 3
```

1. **Wait until every index is `STEADY`** on every pod. A restart interrupts every build in progress; mongot resumes
   one from the progress it last committed, when it committed any.
2. **Sync the Application** (or `helm upgrade` with the release's values file). The pods restart one at a time,
   each on its volume.
3. **Read mongot's log on each pod.** `Ignoring unrecognized field(s) in mongot config file` names a key mongot did
   not take; it started without it. `numConcurrentInitialSyncs`, `numConcurrentChangeStreams` and
   `numChangeStreamDecodingThreads`, once given, no longer appear in the "not configured, defaulting to" lines; the
   other two never do. A pod that does not start has refused a value: its log says why.

Back to the default: set the value back to empty (null), and sync. The pods restart once more.

Before raising `numConcurrentInitialSyncs`, three things should hold during a rebuild at the default: CPU under 80%
(MongoDB's threshold to scale up), disk room for the extra copies under 85%, and a source that carries the load.

Other mongot settings, beyond the five (`ftdc`, `cursor`, `diskMonitor` and the rest), can be added under their
top-level key and are passed through as written. Below those keys neither the chart nor mongot refuses a misspelled
name: mongot logs `Ignoring unrecognized field(s) in mongot config file` and goes on without it.

## `search.jvmFlags`

A list of strings, each one flag, rendered in order to `spec.clusters[0].jvmFlags`. The operator accepts a flag that
starts with `-X`, `-XX:` or `-D`, with no space, and only the characters `a-z A-Z 0-9 . _ + : = -`
(`mongodbsearch_validation.go:29`, `:425-437`); the schema holds the same rule, and refuses a bare `-X` or `-D` as
well, which the operator lets through (`-X` alone asks java for the help on its extra options).

```yaml
search:
  jvmFlags: ["-Xms6g", "-Xmx6g"]
```

| Use | Flag | Effect |
| --- | --- | --- |
| A heap of your own | `-Xms6g`, `-Xmx6g` | The operator then sets no heap. MongoDB: a heap "below about 30GB allows the JVM to use compressed object pointers" |
| A CPU count of your own | `-XX:ActiveProcessorCount=4` | mongot counts 4 CPUs, whatever the limit, and its four CPU-based defaults follow |

Empty (`[]`, the default): the operator's heap, and the CPU count from the limit. A change restarts every mongot pod,
like the block above.

## What has and has not run

| | |
| --- | --- |
| Run | The chart's tests: nulls and empty maps render nothing, a value renders alone, other mongot keys pass through, wrong types and unknown keys at the top, under `replication` and under `replication.mongodb` are refused (`test/chart.sh`) |
| Not run | No value of `advancedMongotConfigs` has been applied to a cluster yet: the lab is down. The first change on QA is the first proof that mongot reads it as the source says |
