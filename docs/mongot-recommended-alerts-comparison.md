# Comparison: MongoDB's recommended alerts for mongot, and this chart's

MongoDB publishes [Recommended Alerts for mongot](https://www.mongodb.com/docs/search/self-managed/current/monitoring/recommended-alerts/)
for self-managed search. This page puts each of them beside the alerts of
[mongodb-search-helm](../chart/mongodb-search-helm/README.md#alerts): which the chart has, which it has in another form,
which it lacks and why, and whether mongot 1.70.1, the version the chart pins, emits the metric each one reads.

It is the record of issue #89 (epic #67). It is development material and stays in the repository; the chart's README
links it from *Alerts*.

**Sources and dates.** MongoDB's page shows no date and no version; it was read on 2026-10-22 from the `current`
documentation, in its Markdown form (the same address ending in `recommended-alerts.md`). The metrics were read on
2026-10-22, at 18:04Z and again at 18:34Z, from the six mongot 1.70.1 pods of the kind mesh lab, two in each of three
clusters. The chart's rules are those of `main` at `2e84a6b`, chart 0.3.34.

## In short

- **MongoDB lists 28 entries**: 6 in the Page tier, 8 in Ticket, 6 in Watch and 8 under *Search Availability and
  Envoy Routing*. The chart has 10 alerts, in 12 rules: `MongotDataPathFillingUp` is one rule for each of its three levels.
- **4 are covered** by the chart: the disk cascade (other thresholds, by the owner's decision), a forced index status
  transition (two alerts), and the two entries on free disk space of the Watch tier and of the Envoy section.
- **2 are left out by decision**: replication lag, in the Page tier and as a fleet rule (#85, 2026-10-09).
- **16 are not in the chart**, in 13 proposals below, each a story under epic #167 (decided 2026-10-22). The first matters most:
  **no alert of this chart is about a mongot pod that is down**, or that restarts in a loop.
- **1 does not apply**: xDS connections. The operator's Envoy reads its configuration from files, so it has no xDS
  cluster. **5** are Watch entries, which MongoDB says need no paging.
- **Each metric of mongot that MongoDB's entries name was seen on the lab, but one**: `mongot_mongot_ftdc_executor_failure_total`,
  which MongoDB says is off by default. Two Watch expressions are not PromQL as written. The open file descriptors entry
  names `mongot_process_*`, which holds no metric about files.
- **Two expressions count more on 1.70.1 than the page says.** The executor queue rule counts, on two pools, one
  waiting task for each index at rest, so on a pod with more than 10 indexes it is true while no work waits. The
  steady-state exception counter also counts the transient errors that mongot recovers from by itself.

## The comparison

Ids: P for the Page tier, T for Ticket, W for Watch, E for the Envoy section. Expressions are MongoDB's, with
whitespace normalized; a repeated expression is written "the same", and "..." marks words left out of a quotation.
"Not in the chart" without a decision named means not decided yet: the chart's first nine alerts were designed (#74)
before this page was found on 2026-10-09, in the research for the volume alert (#84), and this is the first comparison
with it. "Seen" means on all six pods, under that exact name; the lines read are quoted under
[What the lab showed](#what-the-lab-showed). G1 to G13 are the proposals of [For the owner to decide](#for-the-owner-to-decide).

| # | MongoDB's alert, tier | MongoDB's expression and threshold | In this chart | Metric on mongot 1.70.1 |
| --- | --- | --- | --- | --- |
| P1 | mongot Process Is Down, Page | `up{job="mongot"} == 0`, "Set the duration to one minute" | Not in the chart. G1 | `up` is made by Prometheus for each target, not by mongot: not measurable on the lab, which has no Prometheus. The chart's mongot job is its Service, `<search.name>-search-0-svc` |
| P2 | Crash Loop, Page | `changes(mongot_process_start_time_seconds[10m]) > 3` | Not in the chart. G2 | Seen |
| P3 | Replication Lag Growing Unboundedly, Page | `max(mongot_index_stats_indexing_replicationLagMs) > 60000`, or `deriv(max(mongot_index_stats_indexing_replicationLagMs)[15m:1m]) > 500` | Not in the chart, by the owner's decision of 2026-10-09 (#85): the dashboard draws lag, and `MongotIndexNotFollowing` fires once a pod has stopped following | Seen |
| P4 | Sync Exceptions Occurring, Page | `increase(mongot_index_stats_indexing_steadyStateExceptions_total[10m]) > 0`; `increase(mongot_index_stats_indexing_initialSyncExceptions_total[10m]) > 0` | Initial sync, in another form: `MongotIndexBuildRetrying`, `max by (indexId_logString, pod) (mongot_index_stats_indexing_consecutiveInitialSyncResyncExceptions) > 0` for 15 m. Steady state: not in the chart, G3 | Both seen |
| P5 | Heap Exhaustion Imminent, Page | `sum(mongot_jvm_memory_used_bytes{area="heap"}) / sum(mongot_jvm_memory_max_bytes{area="heap"} > 0) > 0.85`, five minutes; after garbage collection, `mongot_jvm_gc_live_data_size_bytes / mongot_jvm_gc_max_data_size_bytes > 0.85` | Not in the chart; the dashboard draws *JVM heap used, percent of limit*. G4 | All four seen |
| P6 | Disk Fill and mongot Self-Protection Cascade: 85% Ticket, 90% Page, 95% Page | `(1 - mongot_system_disk_space_data_path_free_bytes / mongot_system_disk_space_data_path_total_bytes) >= 0.85`, the same at 0.90 and 0.95 | In another form: `MongotDataPathFillingUp`, `mongot:data_path_used:ratio >= 0.7` for 30 m (info), `>= 0.8` for 15 m (warning), `>= 0.9` for 5 m (critical), with handoff conditions quoted below, by the owner's decision (#84). The record is the same quantity per pod: `max by (namespace, pod) (1 - mongot_system_disk_space_data_path_free_bytes / mongot_system_disk_space_data_path_total_bytes)`. No level at 95%: mongot exits there, and the alert then has no series to read and resolves (see below the table) | Seen |
| T1 | Sustained Query Latency Degradation, Ticket | `max(mongot_command_searchCommandTotalLatency_seconds{quantile="0.99"}) > <your-SLO-threshold>`; per index, `max(mongot_index_stats_query_searchResultBatchLatencies_seconds{quantile="0.99"}) by (indexId_logString) > <your-SLO-threshold>`. "A common starting point is ... 500 milliseconds for `$search` and one second for `$vectorSearch`" | Not in the chart: it needs a service level objective. The dashboard draws averages (*Average search latency, per mongot pod*, the batch time of each index) and Envoy's 95th percentile. G5 | Both seen, with the quantiles 0.5, 0.75, 0.9 and 0.99 |
| T2 | Executor Pool Saturation, Ticket | `max({__name__=~"mongot_.+_executor_queued_tasks"}) > 10`, five minutes | Not in the chart. As written it is true at rest on a pod with more than 10 indexes (see the lab). G6 | 34 names match on every pod, 35 on one; the five pools MongoDB names are seen |
| T3 | Storage Advisory: Sustained IOPS, Ticket | `rate(mongot_system_disk_reads_events{name="<dataPath device>"}[5m]) > 1000`, 15 minutes | Not in the chart. The counter has one series for each block device of the node, and nothing in mongot's metrics says which one holds the data path. G7 | Seen, one series per device |
| T4 | Storage Advisory: Page Fault Rate, Ticket | `rate(mongot_system_process_majorPageFaults_operations[5m]) > 1000` | Not in the chart. G8 | Seen |
| T5 | Indexing Failures Nonzero, Ticket | `increase(mongot_lifecycle_failedInitializationIndexes_total[10m]) > 0`, or the same of `mongot_indexing_steadyStateChangeStream_unexpectedBatchFailures_total`, or of `mongot_index_stats_indexing_invalidGeometryField_total` | Not in the chart. G9 | All three seen, with no index label |
| T6 | Embedding-Channel Disruption, Ticket | `increase(mongot_indexing_steadyStateChangeStream_rescheduledEmbeddingGetMores_total[10m]) > 0`, or the same of `mongot_initialsync_queue_requeuedEmbeddingInitialSyncs_total` | Not in the chart. G10 | Both seen, at 0 |
| T7 | Forced Index Status Transition, Ticket | `count by (status) (mongot_index_stats_indexStatusCode{status!="STEADY"} == 1) > 0`; "A sustained count greater than zero" in `FAILED`, `RECOVERING_NON_TRANSIENT` or `STALE` "indicates a problem" | In another form: `MongotIndexFailed`, `max by (indexId_logString, pod) (mongot_index_stats_indexStatusCode{status="FAILED"}) == 1` for 1 m (critical), and `MongotIndexNotFollowing`, the same with `status=~"STALE\|RECOVERING_NON_TRANSIENT"` for 10 m (warning). MongoDB's expression counts every state but `STEADY`, a build included; the page names those three as a problem, and calls a few seconds of `RECOVERING_TRANSIENT` normal | Seen, with nine states |
| T8 | FTDC Executor Failure, Ticket | `mongot_mongot_ftdc_executor_failure_total > 0`, five minutes. "This metric is gated behind the `ftdcExecutorMetricsToPrometheus` feature flag" | Not in the chart: the flag is off by default, and the operator's resource has no field for it. G11 | Not seen, on any of the six pods |
| W1 | Heap Utilization (post-GC), Watch | `sum(mongot_jvm_gc_live_data_size_bytes) / sum(mongot_jvm_gc_max_data_size_bytes)`; look into it "if the metric climbs over weeks" | No alert. Of the Watch tier MongoDB says: "None of these metrics require paging." The dashboard draws the heap in use at each reading, which includes what the next collection frees | Seen |
| W2 | GC Pause Time, Watch | `max(mongot_jvm_gc_pause_seconds_max)`; look into it "if this metric is sustained over 100 ms" | No alert. The dashboard draws the share of time paused, not the longest pause | Seen |
| W3 | Open File Descriptors, Watch | `mongot_process_*`; look into it "if this metric is over 80%" | No alert, not on the dashboard. Not PromQL as written | No `mongot_process_*` metric counts files. The open count is `mongot_system_process_openFileDescriptors_objects`; no limit was seen |
| W4 | Cursor Timeouts, Watch | `rate(mongot_cursorManager_trackedCursors[5m])`, "Purely informational" | No alert, not on the dashboard | Seen |
| W5 | Connection Pool Wait, Watch | `mongot_mongoClient_connectionPool_connectionsCheckedOut approaching _maxSize`; investigate "if the metric is sustained and greater than zero" | No alert, not on the dashboard. Not PromQL as written | Both seen, one series for each client |
| W6 | Disk Free Percentage, Watch | `mongot_system_disk_space_data_path_free_bytes / mongot_system_disk_space_data_path_total_bytes`; "below 30% free, consider having a planning conversation" | Covered: the info level of `MongotDataPathFillingUp`, the info rule below for 30 m (30% free or less, including equality); higher usage hands off to warning and critical | Seen |
| E1 | Search Availability Below 70%, "a high-severity alert" | `1 - (Envoy failed requests + mongot internal failures) / Envoy total requests`, from `envoy_mongorpc_grpc_transcode_request_failed_total`, `envoy_mongorpc_grpc_transcode_request_total` and `mongot_index_stats_query_internallyFailedQueries_total`; a sustained value below `0.70` is high severity | Not in the chart. The operator's Envoy has one HTTP filter, the router, and no transcoding filter that would make these Envoy counters. G12 | mongot's counter seen, for the whole pod. The Envoy counters are not mongot's; the lab runs no operator Envoy |
| E2 | High Request-Failure Rate, no tier | `rate(envoy_mongorpc_grpc_transcode_request_failed_total[5m]) / rate(envoy_mongorpc_grpc_transcode_request_total[5m]) > 0.10` "on at least 20% of active instances with more than 1 QPS, and at least 10 instances meet the QPS condition" | Not in the chart: a rule for a fleet of at least 10 Envoy; the chart runs 3. G12 | Not mongot's metrics; not measurable on the lab |
| E3 | Too Few xDS Connections, no tier | `envoy_cluster_upstream_rq_active{envoy_cluster_name="xds_cluster"}`; alert when "fewer than 70% of Search Envoy instances are connected to the Search xDS server" | Does not apply: the operator's Envoy reads `lds.json` and `cds.json` from files and has no xDS cluster | Not mongot's metric |
| E4 | Short-Lived Envoy Instances, "a supporting signal" | `envoy_server_uptime < 1800` on "more than 20% of Envoy instances" | Not in the chart. G12 | Not mongot's metric; not measurable on the lab |
| E5 | mongot Process Silence, no tier | `absent_over_time(mongot_process_uptime_seconds[15m])` "for an instance that is expected to be running and scraped" | Not in the chart. G1 | Seen |
| E6 | Low Data-Path Disk Space, no tier | `mongot_system_disk_space_data_path_free_bytes / mongot_system_disk_space_data_path_total_bytes < 0.10` | Covered: the critical level of `MongotDataPathFillingUp`, `mongot:data_path_used:ratio >= 0.9` for 5 m, which is 10% free or less | Seen |
| E7 | Replication Lag, no tier | Above 1800000 ms (30 minutes) "and rising" is an early warning; escalate above 7200000 ms (2 hours) "when the value continues to rise" | Not in the chart, by decision (#85) | Seen |
| E8 | Fleet-Wide Native Memory Pressure, no tier | Memory outside the heap, from `mongot_system_memory_phys_inUse_bytes`, `mongot_jvm_memory_used_bytes{area="heap"}` and `mongot_system_memory_phys_total_bytes`: "more than 5% of `mongot` instances exceed 50% native-memory usage for 55 minutes" | Not in the chart. G13 | All three seen |

**Disk rule expressions.** With the example values, the rendered `MongotDataPathFillingUp` rules are:

```promql
# info, for 30m
mongot:data_path_used:ratio >= 0.7
and (mongot:data_path_used:ratio < 0.8 or mongot:data_path_used:ratio offset 15m < 0.8)
# warning, for 15m
mongot:data_path_used:ratio >= 0.8
and (mongot:data_path_used:ratio < 0.9 or mongot:data_path_used:ratio offset 5m < 0.9)
# critical, for 5m
mongot:data_path_used:ratio >= 0.9
```

The offset clauses keep the lower level eligible during the higher level's hold. W6 and E6 are
covered in practice, with different boundaries and holds: MongoDB says strictly below 30% and
10% free, respectively; the chart includes equality and applies its configured holds.

**Nothing in the chart alerts on a mongot pod that is down (P1, E5).** Every alert on mongot reads series that the
pod's own mongot exports. A mongot that is not running exports none: its alerts have nothing to read, and one that was
firing for it, such as the volume alert at 90% and above, resolves. `MongotTrafficNotDistributed` and
`MongotPodReceivingNoTraffic` compare the pods that report: with one of three pods gone, the other two share the
searches, and neither fires. `MongotEnvoyRetriesElevated` reads Envoy's retries, which a pod that is down may cause
or not: not measured. Whether the cluster's own rules cover a pod of this namespace was not checked.

## What the lab showed

The lab: the kind mesh lab, mongot `quay.io/mongodb/mongodb-search:1.70.1`, two pods in namespace `search` of each of
`mesh0`, `mesh1` and `mesh2`, each pod with two indexes, one search and one vector, both `STEADY`. It runs no operator
Envoy, no Prometheus and no Prometheus Operator. Each pod's `/metrics` was read at 18:04:28Z and at 18:34:41Z: 790
metric families on five pods and 801 on the sixth, both times.

The lines below are those of `mongot-search-0-0` in `mesh0` at 18:04:28Z. Every one of these names was on all six
pods, except the FTDC counter, which was on none.

```text
# P2
mongot_process_start_time_seconds{Scope="jvm"} 1.792688251604E9
# P3, E7
mongot_index_stats_indexing_replicationLagMs{generationId_logString="6ad9531ffe10033fb85d1155-f6-u0-a0",indexId_logString="6ad9531ffe10033fb85d1155",indexType="search"} 0.0
# P4
mongot_index_stats_indexing_steadyStateExceptions_total{generationId_logString="6ad9531ffe10033fb85d1155-f6-u0-a0",indexFeatureVersion="4",indexId_logString="6ad9531ffe10033fb85d1155"} 0.0
mongot_index_stats_indexing_initialSyncExceptions_total{generationId_logString="6ad9531ffe10033fb85d1155-f6-u0-a0",indexFeatureVersion="4",indexId_logString="6ad9531ffe10033fb85d1155"} 0.0
# P5, W1, E8
mongot_jvm_memory_used_bytes{Scope="jvm",area="heap",id="G1 Eden Space"} 2.16006656E8
mongot_jvm_memory_max_bytes{Scope="jvm",area="heap",id="G1 Eden Space"} -1.0
mongot_jvm_memory_max_bytes{Scope="jvm",area="heap",id="G1 Old Gen"} 5.36870912E8
mongot_jvm_gc_live_data_size_bytes{Scope="jvm"} 5.0341968E7
mongot_jvm_gc_max_data_size_bytes{Scope="jvm"} 5.36870912E8
# P6, W6, E6
mongot_system_disk_space_data_path_free_bytes 1.2257857536E10
mongot_system_disk_space_data_path_total_bytes 6.3088406528E10
# T1
mongot_command_searchCommandTotalLatency_seconds{timeUnit="seconds",quantile="0.99"} 0.0
mongot_command_vectorSearchCommandTotalLatency_seconds{timeUnit="seconds",quantile="0.99"} 0.0
mongot_index_stats_query_searchResultBatchLatencies_seconds{generationId_logString="6ad9531ffe10033fb85d1155-f6-u0-a0",indexFeatureVersion="4",indexId_logString="6ad9531ffe10033fb85d1155",timeUnit="milliseconds",quantile="0.99"} 0.0
# T2
mongot_decoding_executor_queued_tasks{name="executorMetrics"} 0.0
mongot_change_stream_sync_dispatcher_executor_queued_tasks{name="executorMetrics"} 0.0
mongot_indexing_work_executor_queued_tasks{name="executorMetrics"} 0.0
mongot_indexing_lifecycle_executor_queued_tasks{name="executorMetrics"} 0.0
mongot_index_commit_executor_queued_tasks{name="executorMetrics"} 2.0
mongot_index_refresh_executor_queued_tasks{name="executorMetrics"} 2.0
# T3
mongot_system_disk_reads_events{name="/dev/vda"} 9167.0
mongot_system_disk_reads_events{name="/dev/vdb"} 3938875.0
mongot_system_disk_reads_events{name="/dev/vdc"} 347.0
# T4
mongot_system_process_majorPageFaults_operations 224.0
# T5
mongot_lifecycle_failedInitializationIndexes_total 0.0
mongot_indexing_steadyStateChangeStream_unexpectedBatchFailures_total 0.0
mongot_index_stats_indexing_invalidGeometryField_total 0.0
# T6
mongot_indexing_steadyStateChangeStream_rescheduledEmbeddingGetMores_total 0.0
mongot_initialsync_queue_requeuedEmbeddingInitialSyncs_total 0.0
# T7
mongot_index_stats_indexStatusCode{generationId_logString="6ad9531ffe10033fb85d1155-f6-u0-a0",indexFeatureVersion="4",indexId_logString="6ad9531ffe10033fb85d1155",status="STEADY"} 1.0
# T8: mongot_mongot_ftdc_executor_failure_total, not on any of the six pods
# W2
mongot_jvm_gc_pause_seconds_max{Scope="jvm",action="end of minor GC",cause="G1 Evacuation Pause",gc="G1 Young Generation"} 0.002
# W3: the four mongot_process_* names are cpu_time_ns_total, cpu_usage, start_time_seconds and uptime_seconds
mongot_system_process_openFileDescriptors_objects 160.0
# W4
mongot_cursorManager_trackedCursors 0.0
# W5
mongot_mongoClient_connectionPool_connectionsCheckedOut{Scope="replication",clientName="mongot AutoEmbedding Materialized View Collection Resolver"} 0.0
mongot_mongoClient_connectionPool_maxSize{Scope="replication",clientName="mongot AutoEmbedding Materialized View Collection Resolver"} 3.0
# E1
mongot_index_stats_query_internallyFailedQueries_total{indexFeatureVersion="4"} 0.0
# E5
mongot_process_uptime_seconds{Scope="jvm"} 4016.905
# E8
mongot_system_memory_phys_inUse_bytes 7.479296E8
mongot_system_memory_phys_total_bytes 2.147483648E9
```

The metrics the chart's own alerts read were all seen too, on all six pods:
`mongot_command_searchCommandTotalLatency_seconds_count`, `mongot_command_vectorSearchCommandTotalLatency_seconds_count`,
`mongot_index_stats_indexStatusCode`, `mongot_index_stats_indexing_consecutiveInitialSyncResyncExceptions`,
`mongot_index_stats_indexSizeBytes`, `mongot_index_stats_numLuceneDocs`, `mongot_index_stats_query_failedQueries_total`
and the two data path gauges. The Envoy counters the chart reads were not measured: the lab runs no operator Envoy.

What the readings say about MongoDB's expressions:

- **The executor queue rule (T2) counts indexes at rest.** On every pod `mongot_index_commit_executor_queued_tasks`
  and `mongot_index_refresh_executor_queued_tasks` read 2, the number of indexes, at both readings, while the insert,
  update and delete counters of both indexes read 0. Both pools are scheduled executors that hold a periodic task for
  each index: mongot 1.70.1 makes `index-commit` with `Executors.fixedSizeThreadScheduledExecutor`
  (`MongoDbReplicationManager.java`, lines 402 to 404) and gives every index generation a committer that calls
  `scheduleWithFixedDelay` on it (`ReplicationIndexManager.java`, lines 239 and 240; `PeriodicIndexCommitter.java`,
  lines 69 to 84). It makes `index-refresh` the same way (`LuceneIndexFactory.java`, lines 106 to 108), and a
  `PeriodicLuceneIndexRefresher` schedules itself on it (`PeriodicLuceneIndexRefresher.java`, line 42). The gauge is
  Micrometer's `executor.queued`, `getQueue().size()`, and the queue of a scheduled
  executor holds its waiting periodic tasks: "Each element of this queue is a `ScheduledFuture`" (Java 21,
  `ScheduledThreadPoolExecutor.getQueue`). So `max({__name__=~"mongot_.+_executor_queued_tasks"}) > 10` holds at rest on
  a pod with more than 10 index generations, less any of those tasks that runs at that instant. The four other pools
  MongoDB names read 0.
- **The steady-state exception counter (P4) counts every kind.** In mongot 1.70.1 the counter is incremented before
  the kind of the exception is looked at (`ReplicationIndexManager.java`, lines 929 to 933). The kinds include
  `TRANSIENT`, after which mongot logs "Witnessed transient error. Trying to resume in {} milliseconds." and resumes by itself, and
  `INVALIDATED` and `RENAMED`, after which it resumes at once. mongot also counts each exception by kind, in a counter
  `exceptions` of the metrics factory `replicationIndexManager` (`recordReplicationExceptionMetric`, lines 865 to 903,
  called at line 835). That counter is made at the first exception, and the lab had none: not seen. By the name of its
  sibling `mongot_replicationIndexManager_transitionState_total`, which the lab does show, it would be
  `mongot_replicationIndexManager_exceptions_total`.
- **The two heap expressions (P5) read differently at the same instant.** The first, computed for each pod, read 0.098
  to 0.666 on the six pods at 18:04Z; the one after garbage collection read 0.089 to 0.094. The first includes what the
  next collection frees. As MongoDB writes it, it also adds every pod's heap together, so one pod near its limit beside
  two idle ones reads as their average. On the lab the heap is 512 MiB (`-Xmx512m` in the pod's command, half its 1Gi
  memory request), which `mongot_jvm_gc_max_data_size_bytes` and the `G1 Old Gen` maximum both read.
- **The device counters (T3) are the node's.** `mongot_system_disk_reads_events` has one series for each block device
  of the node, `/dev/vda`, `/dev/vdb` and `/dev/vdc` on the lab, and the six pods, on six nodes, read the same
  3,938,875 for `/dev/vdb` at the same second: the disk of the VM the lab runs in. Which device holds a pod's data path
  is not in mongot's metrics. Its type is `gauge` and its name does not end in `_total`, which is what draws, on
  `rate()`, the notice the chart README describes under *Envoy counters without `_total`*. The same holds for
  `mongot_system_process_majorPageFaults_operations` (T4).
- **The FTDC counter (T8) is off unless a flag is set.** mongot 1.70.1 declares
  `FTDC_EXECUTOR_METRICS_TO_PROMETHEUS("ftdcExecutorMetricsToPrometheus", State.DISABLED)` (`Feature.java`, line 71).
  The resource of operator 1.13.0 has one feature flag, `enableOverloadRetrySignal`
  ([`crds/mongodbsearch.mongodb.com.yaml`](../chart/mongodb-search-helm/crds/mongodbsearch.mongodb.com.yaml), under
  `featureFlags`); no other way to set this one through the chart was found.
- **The embedding counters (T6) are there without automated embedding.** MongoDB's metrics reference says these
  "Appear only when you configure Automated Embedding". The repository's lab charts set none (no `autoEmbed` or
  `embedding` under `kind-mesh/` or `kind-mesh-cilium/`, in any of the repository's branches), and both counters were
  on every pod, at 0.
- **The indexing failure counters (T5) name no index.** MongoDB's first response is to "Inspect labels for the
  affected index and reason"; on 1.70.1 the three counters carry no label of their own.
- **mongot's part of the availability formula (E1) is for the whole pod.**
  `mongot_index_stats_query_internallyFailedQueries_total` carries only `indexFeatureVersion`, not an index.
- **The per-index batch time (T1) is in seconds.** It is a Micrometer timer with the percentiles 0.5, 0.75, 0.9 and
  0.99 and a fixed tag `timeUnit="milliseconds"` (`PerIndexMetricsFactory.java`, lines 432 to 443). Micrometer's
  Prometheus registry reports timers in seconds (its `getBaseTimeUnit()` returns `SECONDS`), as the name says.
- **`mongot_system_memory_phys_total_bytes` (E8) reads the pod's limit**: 2147483648, the 2Gi memory limit of the
  lab's mongot container. Memory outside the heap read 16.5% to 31.6% of it on the six pods at 18:04Z.
- **The operator's Envoy (E1 to E4)**: operator 1.13.0 builds Envoy's bootstrap with `cds.json` and `lds.json` as
  file sources (`controllers/operator/envoy_config_builder.go`, lines 89 to 92) and gives the listener one HTTP filter,
  the router (lines 310 to 315). The copy read from a running proxy in [`docs/envoy/`](envoy/) has the same: no xDS
  cluster and no transcoding filter.

**Not PromQL as written.** MongoDB's expressions were put into rule files and parsed with promtool 3.15.0, from the
image `test/alerts.sh` pins. Every one parses except W3, `mongot_process_*` (`parse error: unexpected end of input`),
and W5, `... approaching _maxSize` (`unexpected identifier "approaching"`). E1, E7 and E8 are given in words only. In
T1 the placeholder `<your-SLO-threshold>` was replaced with 0.5 for the check.

### How to repeat the reading

With the lab running:

```bash
export KUBECONFIG=~/.kube/mongodb-mesh.config
for ctx in kind-mesh0 kind-mesh1 kind-mesh2; do
  for pod in $(kubectl --context "${ctx}" -n search get pods -l app=mongot-search-0-svc -o jsonpath='{.items[*].metadata.name}'); do
    kubectl --context "${ctx}" get --raw "/api/v1/namespaces/search/pods/${pod}:9946/proxy/metrics" > "/tmp/${ctx}_${pod}.prom"
  done
done
# One count a pod: 1 means the name is there, 0 that it is not
grep -c '^mongot_process_start_time_seconds' /tmp/kind-mesh*.prom
grep -c '^mongot_mongot_ftdc_executor_failure_total' /tmp/kind-mesh*.prom
# The queue of the two scheduled pools, and the number of indexes, on each pod
grep -H -E '^mongot_index_(commit|refresh)_executor_queued_tasks' /tmp/kind-mesh*.prom
grep -c -E '^mongot_index_stats_indexStatusCode\{.*status="STEADY"\} 1' /tmp/kind-mesh*.prom
```

Passes when, for each of the six files, the start time counts 1, the FTDC counter 0, both pools read 2.0 and the
indexes count 2.

## For the owner to decide

One proposal for each gap, as the chart would render it for `search.name: mongot` (its mongot job is
`mongot-search-0-svc`) and `search.replicas: 3`. Severities follow MongoDB's tiers: Page is `critical`, Ticket is
`warning`. A hold marked "to decide" has no figure from MongoDB. The owner decided on 2026-10-22 that each proposal
becomes a story, under epic #167: a rule with its promtool tests, or for G7 and G11 a reason written down.

| # | MongoDB's entries | Proposed alert and expression | Hold, severity | To find out first | Decision |
| --- | --- | --- | --- | --- | --- |
| G1 | P1, E5 | `MongotDown`: `up{job="mongot-search-0-svc"} == 0`. `MongotPodsMissing`: `(count(up{job="mongot-search-0-svc"} == 1) or vector(0)) < 3`, 3 being `search.replicas`: fewer pods answer than the chart deploys, also when a pod is no longer a target | 1 m and 15 m, critical | On a cluster with Prometheus: whether a pod that is not Ready stays a target and reads `up` 0; that a restart one pod at a time (README, *Replication lag*) fires neither | A story, #168 |
| G2 | P2 | `MongotCrashLooping`: `max by (namespace, pod) (changes(mongot_process_start_time_seconds{job="mongot-search-0-svc"}[30m])) > 3`. 30 minutes and not 10: the kubelet waits 10 s before a restart, twice as long each time, up to 300 s, so a pod in a steady loop starts at most twice in 10 minutes and MongoDB's rule holds only in the loop's first minutes | none, critical | A start that ends before its first scrape (15 s) is not seen; G1 is what fires then | A story, #169 |
| G3 | P4 | `MongotIndexSyncErrors`: `sum by (namespace, pod, indexId_logString) (increase(mongot_index_stats_indexing_steadyStateExceptions_total{job="mongot-search-0-svc"}[10m])) > 0` | none, warning: MongoDB says Page, but transient errors are counted too | What a lost primary (`kind-mesh-cilium/drills.sh primary kill`) does to this counter and to the counter by kind, read as above | A story, #170 |
| G4 | P5 | `MongotHeapNearlyFull`: `max by (namespace, pod) (mongot_jvm_gc_live_data_size_bytes{job="mongot-search-0-svc"} / mongot_jvm_gc_max_data_size_bytes{job="mongot-search-0-svc"}) > 0.85`: MongoDB's form after garbage collection, per pod | 5 m, critical | How often the value changes when only young collections run | A story, #171 |
| G5 | T1 | `MongotSearchLatencyHigh`: `max by (namespace, pod) (mongot_command_searchCommandTotalLatency_seconds{job="mongot-search-0-svc",quantile="0.99"}) > 0.5`; for vector search the same of `mongot_command_vectorSearchCommandTotalLatency_seconds`, `> 1` | to decide, warning | The service level objective to use in place of MongoDB's starting points | A story, #172 |
| G6 | T2 | `MongotExecutorQueueing`: `max by (namespace, pod) ({__name__=~"mongot_(decoding\|change_stream_sync_dispatcher\|indexing_work\|indexing_lifecycle)_executor_queued_tasks",job="mongot-search-0-svc"}) > 10`: the four pools that read 0 at rest, and not `index_commit`, which holds a task for each index | 5 m, warning | Whether these queues grow under a load test (`test/load/`) | A story, #173 |
| G7 | T3 | None: nothing in mongot's metrics says which device holds a pod's data path, and the counter is the node's | | | A story, #174 |
| G8 | T4 | `MongotMajorPageFaultsHigh`: `max by (namespace, pod) (rate(mongot_system_process_majorPageFaults_operations{job="mongot-search-0-svc"}[5m])) > 1000` | to decide, warning | | A story, #175 |
| G9 | T5 | `MongotIndexingFailures`: `(sum by (namespace, pod) (increase(mongot_lifecycle_failedInitializationIndexes_total{job="mongot-search-0-svc"}[10m])) > 0) or (sum by (namespace, pod) (increase(mongot_indexing_steadyStateChangeStream_unexpectedBatchFailures_total{job="mongot-search-0-svc"}[10m])) > 0) or (sum by (namespace, pod) (increase(mongot_index_stats_indexing_invalidGeometryField_total{job="mongot-search-0-svc"}[10m])) > 0)`, by pod: the counters name no index | none, warning | | A story, #176 |
| G10 | T6 | `MongotEmbeddingStalled`: `(sum by (namespace, pod) (increase(mongot_indexing_steadyStateChangeStream_rescheduledEmbeddingGetMores_total{job="mongot-search-0-svc"}[10m])) > 0) or (sum by (namespace, pod) (increase(mongot_initialsync_queue_requeuedEmbeddingInitialSyncs_total{job="mongot-search-0-svc"}[10m])) > 0)` | none, warning | Of use only where an index uses automated embedding | A story, #177 |
| G11 | T8 | None: the metric is off by default and the chart cannot turn it on | | | A story, #178 |
| G12 | E1, E2; E4 remains without a proposed rule | With the operator Envoy's own counters, as the dashboard reads them: `MongotEnvoyFailuresHigh`, `sum(rate(envoy_cluster_upstream_rq_xx_total{envoy_cluster_name="mongot_rs_cluster",envoy_response_code_class="5"}[5m])) / sum(rate(envoy_cluster_upstream_rq_total{envoy_cluster_name="mongot_rs_cluster"}[5m])) > 0.10`. It counts 5xx responses only; what MongoDB's transcoding counters count was not established | to decide, warning | With the operator's Envoy, which the lab now does not run: what a failed search does to these counters | A story, #179 |
| G13 | E8 | `MongotNativeMemoryHigh`: `(max by (namespace, pod) (mongot_system_memory_phys_inUse_bytes{job="mongot-search-0-svc"}) - sum by (namespace, pod) (mongot_jvm_memory_used_bytes{job="mongot-search-0-svc",area="heap"})) / max by (namespace, pod) (mongot_system_memory_phys_total_bytes{job="mongot-search-0-svc"}) > 0.5`: per pod, since one pod is more than 5% of three | 55 m, warning | | A story, #180 |

The 13 proposed rules parse with promtool 3.15.0. G9 and G10 take each counter on its own and join the results with
`or`: their counters carry the same labels, and `increase` over one selector that matches several of their names drops
the names and leaves series with equal labels, which Prometheus refuses unless the name's removal is delayed
([feature flags](https://prometheus.io/docs/prometheus/latest/feature_flags/)). A promtool unit test on 2026-10-22
showed both: the one-selector form of G9 fails with `vector cannot contain metrics with the same labelset`, and the
form above fires for the counter that rose, as G10 does, and G10 stays quiet before its counter rises. None is in the
chart. G1's `up` is made by Prometheus, and G12's Envoy counters are not in mongot's metrics: both are to be checked
on a cluster that has them.

## Sources

| What | Where | Read |
| --- | --- | --- |
| The recommended alerts | [Recommended Alerts for mongot](https://www.mongodb.com/docs/search/self-managed/current/monitoring/recommended-alerts/) | 2026-10-22; no date or version on the page |
| What each metric is | [Metrics Reference for mongot](https://www.mongodb.com/docs/search/self-managed/current/monitoring/metrics-reference/); its one "Alert on this metric" is `mongot_system_disk_space_data_path_free_bytes`, which the chart alerts on | 2026-10-22 |
| The signals of a healthy deployment | [Monitor mongot Deployment](https://www.mongodb.com/docs/search/self-managed/current/deployment/monitoring/): "Executor pool queue depth is consistently near zero" | 2026-10-22 |
| The restart back-off | [Kubernetes, Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/): "an exponential backoff delay (10s, 20s, 40s, …), that is capped at 300 seconds (5 minutes)" | 2026-10-22 |
| mongot's source | [mongodb/mongot](https://github.com/mongodb/mongot) at tag `v1.70.1`: `MongoDbReplicationManager.java`, `ReplicationIndexManager.java`, `PeriodicIndexCommitter.java`, `LuceneIndexFactory.java`, `PeriodicLuceneIndexRefresher.java`, `Feature.java`, `PerIndexMetricsFactory.java` | 2026-10-22 |
| The operator's Envoy | [mongodb/mongodb-kubernetes](https://github.com/mongodb/mongodb-kubernetes) at tag `1.13.0`: `controllers/operator/envoy_config_builder.go` | 2026-10-22 |
| The queue gauge and timer units | Micrometer, at the commit mongot's `NamedExecutorService.java` names (`311efdb`): `ExecutorServiceMetrics.java`, `PrometheusMeterRegistry.java`; Java 21, [`ScheduledThreadPoolExecutor.getQueue`](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/ScheduledThreadPoolExecutor.html#getQueue()) | 2026-10-22 |
