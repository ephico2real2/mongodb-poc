# Envoy performance testing

A load test of search on the lab, run on 2026-10-10, to see how the Envoy that the operator puts in front of mongot
behaves under concurrent searches: its CPU for each search, whether its CPU limit holds it back, its memory, and how
mongod's connection lands on the Envoy pods. It was run with the operator's default resources for Envoy and with the
starting point [production-settings.md](../chart/mongodb-search-helm/production-settings.md) gives for production.
The tool is in [test/load/](../test/load/), so the same test can be run on another cluster.

## The result

- **The default CPU limit holds Envoy back.** With the operator's half a CPU, the Envoy pod that carried the
  searches began to be throttled at 8 searches at once (1,000 a second, 3% of periods) and was
  throttled in 28 to 34% of periods from 16 at once. With a limit of 2 CPUs it was never throttled.
- **Up to 32 at once, searches were faster with 2 CPUs**: at 32 the 95th percentile was 24 ms where it was
  37 ms, and 2,250 searches a second where there were 1,879.
- **At 64 at once they were slower**: 2,032 a second and 72 ms, against 2,452 and 52 ms. With Envoy
  no longer holding the load back, mongot reached its own limit of 1 CPU and was throttled in 22% of periods
  (2% in the run at half a CPU). Raising one limit moved the load to the next.
- **One mongod sends every search through one Envoy pod.** Each Envoy pod held one connection from mongod, and
  all the searches went down one of them. The other Envoy pod used 0.005 to 0.014 CPUs. A second or third
  Envoy pod stands by for that mongod; it does not add capacity for it.
- **Envoy's cost**: about 0.4 CPUs at 1,000 searches a second, each returning ten results. For each search a
  second it used 0.7 to 0.9 thousandths of a CPU at the lowest rate and 0.2 to 0.3 at the highest.
- **Envoy's memory stayed small**: 42 MiB at most by its cgroup's count, 36 MiB of working set.
- **Nothing failed**: 927,899 searches in the two runs, 0 failed, no retry by Envoy.

<!-- markdownlint-disable MD033 -->
<img alt="The CPU of the Envoy pod that carried the searches, at seven steps of concurrency from 1 to 64, in two runs on the lab. With the default limit of half a CPU it rose to the limit and was throttled in 3 per cent of periods at 8 searches at once and in 28 to 34 per cent from 16 on. With a limit of 2 CPUs it was never throttled and used up to 0.60 CPUs; the 95th percentile of the search time at 32 at once was 24 ms where it was 37, and at 64 at once 72 ms where it was 52." src="diagrams/envoy-load/cpu-against-limit.light.png">
<!-- markdownlint-enable MD033 -->

*With the operator's default limit the busy Envoy pod was held at half a CPU from 16 searches at once and throttled in up to 34% of periods. With 2 CPUs it was never throttled and used up to 0.60 CPUs: searches were faster at 16 and 32 at once, and slower at 64, where mongot was then the limit. Measured on the lab, where one mongod connection carries every search.*

```text
At once                    1           2           4           8           16          32          64
Limit half a CPU
  busy Envoy pod, CPUs     0.14        0.18        0.27        0.39        0.47        0.48        0.49
  periods throttled        0%          0%          0%          3%          28%         32%         34%
  searches a second        168         319         590         1,000       1,325       1,879       2,452
  95th percentile          9 ms        10 ms       10 ms       12 ms       24 ms       37 ms       52 ms
Limit 2 CPUs
  busy Envoy pod, CPUs     0.13        0.19        0.26        0.38        0.47        0.60        0.47
  periods throttled        0%          0%          0%          0%          0%          0%          0%
  searches a second        191         326         577         916         1,436       2,250       2,032
  95th percentile          8 ms        9 ms        10 ms       15 ms       21 ms       24 ms       72 ms
```

## The setup

| | |
| --- | --- |
| Cluster | OpenShift Local 4.22.7, one node of 12 CPUs, namespace `mongodb-poc` |
| Search | Chart `mongodb-search-helm` 0.3.23 under Argo CD, operator 1.13.0, mongot 1.70.1: three mongot pods (1 CPU at most each), two Envoy pods (Envoy 1.37.6) |
| Source | A replica set of three mongod on a virtual machine of the same workstation |
| Data | `sample_mflix.movies`: 20,024 documents, made by `mongodb/scripts/generate-bulk.py`; the index `default` |
| The searches | `$search` for one of eight words the collection holds, over every field; the first 10 results, two fields of each. The generator counted 10 results a search |
| The generator | One pod in the namespace: one `mongosh` that keeps N searches in flight through the driver, N stepping 1, 2, 4, 8, 16, 32, 64, for 60 s a step with 15 s between |
| Read while it ran | From every Envoy pod, mongot pod and the generator, about every 6 s: the CPU time used, the periods and the throttled periods of the container, and its memory, from its cgroup. From Prometheus afterwards: Envoy's own counters |

The time of a search is as the generator saw it: through mongod, Envoy and mongot and back. A period is a tenth of
a second; a throttled period is one in which the container had used its share and was stopped until the next.

## The two runs

```bash
export TargetNamespace=mongodb-poc URI_SECRET=mongot-gui-mongo-uri
test/load/run.sh C-default 1,2,4,8,16,32,64 60 15        # Envoy at the operator's defaults
# loadBalancer.resources in git: 250m and 256Mi requested, 2 CPUs and 1Gi at most; Argo CD rolled the Envoy pods
test/load/run.sh D-production 1,2,4,8,16,32,64 60 15
python3 test/load/analyze.py C-default
```

### Envoy at the operator's defaults: 100m and 128Mi requested, 500m and 512Mi at most

19:31Z to 19:40Z. What the generator printed:

```console
{"step":"start","steps":[1,2,4,8,16,32,64],"seconds":60,"terms":8,"limit":10,"at":"2026-10-10T19:31:22.035Z"}
{"step":"done","concurrency":1,"start":"2026-10-10T19:31:22.035Z","end":"2026-10-10T19:32:22.038Z","ok":10098,"failed":0,"per_second":168.3,"docs":100980,"docs_per_search":10,"ms":{"p50":5.3,"p95":9.3,"p99":17.7,"max":51.1},"first_error":""}
{"step":"done","concurrency":2,"start":"2026-10-10T19:32:37.241Z","end":"2026-10-10T19:33:37.247Z","ok":19157,"failed":0,"per_second":319.3,"docs":191570,"docs_per_search":10,"ms":{"p50":5.8,"p95":9.5,"p99":17.6,"max":118.1},"first_error":""}
{"step":"done","concurrency":4,"start":"2026-10-10T19:33:52.569Z","end":"2026-10-10T19:34:52.576Z","ok":35412,"failed":0,"per_second":590.1,"docs":354120,"docs_per_search":10,"ms":{"p50":6.4,"p95":10,"p99":16.5,"max":107.9},"first_error":""}
{"step":"done","concurrency":8,"start":"2026-10-10T19:35:08.726Z","end":"2026-10-10T19:36:08.731Z","ok":59993,"failed":0,"per_second":999.8,"docs":599930,"docs_per_search":10,"ms":{"p50":7.5,"p95":11.8,"p99":18.6,"max":140.4},"first_error":""}
{"step":"done","concurrency":16,"start":"2026-10-10T19:36:24.742Z","end":"2026-10-10T19:37:24.749Z","ok":79495,"failed":0,"per_second":1324.8,"docs":794950,"docs_per_search":10,"ms":{"p50":10.4,"p95":23.5,"p99":34,"max":230.2},"first_error":""}
{"step":"done","concurrency":32,"start":"2026-10-10T19:37:41.223Z","end":"2026-10-10T19:38:41.232Z","ok":112765,"failed":0,"per_second":1879.1,"docs":1127650,"docs_per_search":10,"ms":{"p50":13.5,"p95":37.4,"p99":50.3,"max":225.6},"first_error":""}
{"step":"done","concurrency":64,"start":"2026-10-10T19:38:58.218Z","end":"2026-10-10T19:39:58.230Z","ok":147138,"failed":0,"per_second":2451.8,"docs":1471380,"docs_per_search":10,"ms":{"p50":21.4,"p95":51.5,"p99":67.1,"max":236.8},"first_error":""}
{"step":"end","at":"2026-10-10T19:40:16.562Z"}
```

| At once | Searches | Failed | A second | p50 | p95 | p99 | Busy Envoy pod, CPUs | Other Envoy pod | Envoy periods throttled | Envoy memory, most | Each mongot pod, CPUs | mongot periods throttled | Generator, CPUs |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 10,098 | 0 | 168.3 | 5.3 ms | 9.3 ms | 17.7 ms | 0.142 | 0.006 | 0 of 535 (0%) | 34.3 MiB | 0.16 0.16 0.16 | 0 of 1604 (0%) | 0.12 |
| 2 | 19,157 | 0 | 319.3 | 5.8 ms | 9.5 ms | 17.6 ms | 0.185 | 0.005 | 0 of 528 (0%) | 34.4 MiB | 0.23 0.23 0.24 | 0 of 1584 (0%) | 0.16 |
| 4 | 35,412 | 0 | 590.1 | 6.4 ms | 10 ms | 16.5 ms | 0.269 | 0.005 | 0 of 594 (0%) | 38.6 MiB | 0.37 0.36 0.37 | 2 of 1789 (0%) | 0.27 |
| 8 | 59,993 | 0 | 999.8 | 7.5 ms | 11.8 ms | 18.6 ms | 0.390 | 0.006 | 14 of 542 (3%) | 42.0 MiB | 0.55 0.55 0.55 | 2 of 1625 (0%) | 0.39 |
| 16 | 79,495 | 0 | 1,324.8 | 10.4 ms | 23.5 ms | 34 ms | 0.465 | 0.006 | 159 of 565 (28%) | 35.6 MiB | 0.69 0.68 0.69 | 40 of 1695 (2%) | 0.57 |
| 32 | 112,765 | 0 | 1,879.1 | 13.5 ms | 37.4 ms | 50.3 ms | 0.477 | 0.006 | 180 of 558 (32%) | 38.4 MiB | 0.73 0.72 0.72 | 19 of 1674 (1%) | 0.72 |
| 64 | 147,138 | 0 | 2,451.8 | 21.4 ms | 51.5 ms | 67.1 ms | 0.486 | 0.006 | 188 of 545 (34%) | 35.3 MiB | 0.79 0.78 0.78 | 40 of 1636 (2%) | 0.89 |

### Envoy with 250m and 256Mi requested, 2 CPUs and 1Gi at most

19:42Z to 19:51Z.

```console
{"step":"start","steps":[1,2,4,8,16,32,64],"seconds":60,"terms":8,"limit":10,"at":"2026-10-10T19:42:30.453Z"}
{"step":"done","concurrency":1,"start":"2026-10-10T19:42:30.454Z","end":"2026-10-10T19:43:30.455Z","ok":11472,"failed":0,"per_second":191.2,"docs":114720,"docs_per_search":10,"ms":{"p50":4.8,"p95":7.7,"p99":13.8,"max":74.9},"first_error":""}
{"step":"done","concurrency":2,"start":"2026-10-10T19:43:45.668Z","end":"2026-10-10T19:44:45.675Z","ok":19589,"failed":0,"per_second":326.4,"docs":195890,"docs_per_search":10,"ms":{"p50":5.9,"p95":9,"p99":13.6,"max":61.4},"first_error":""}
{"step":"done","concurrency":4,"start":"2026-10-10T19:45:00.973Z","end":"2026-10-10T19:46:00.979Z","ok":34644,"failed":0,"per_second":577.3,"docs":346440,"docs_per_search":10,"ms":{"p50":6.5,"p95":10.4,"p99":17.4,"max":127.9},"first_error":""}
{"step":"done","concurrency":8,"start":"2026-10-10T19:46:16.722Z","end":"2026-10-10T19:47:16.728Z","ok":54987,"failed":0,"per_second":916.4,"docs":549870,"docs_per_search":10,"ms":{"p50":8,"p95":14.5,"p99":22.6,"max":138.7},"first_error":""}
{"step":"done","concurrency":16,"start":"2026-10-10T19:47:32.738Z","end":"2026-10-10T19:48:32.743Z","ok":86173,"failed":0,"per_second":1436.1,"docs":861730,"docs_per_search":10,"ms":{"p50":9.6,"p95":20.8,"p99":34.9,"max":191.2},"first_error":""}
{"step":"done","concurrency":32,"start":"2026-10-10T19:48:49.795Z","end":"2026-10-10T19:49:49.809Z","ok":135045,"failed":0,"per_second":2250.2,"docs":1350450,"docs_per_search":10,"ms":{"p50":12.8,"p95":24.1,"p99":37.1,"max":248.9},"first_error":""}
{"step":"done","concurrency":64,"start":"2026-10-10T19:50:07.928Z","end":"2026-10-10T19:51:07.939Z","ok":121931,"failed":0,"per_second":2031.8,"docs":1219310,"docs_per_search":10,"ms":{"p50":24,"p95":71.5,"p99":145.5,"max":928.6},"first_error":""}
{"step":"end","at":"2026-10-10T19:51:25.257Z"}
```

| At once | Searches | Failed | A second | p50 | p95 | p99 | Busy Envoy pod, CPUs | Other Envoy pod | Envoy periods throttled | Envoy memory, most | Each mongot pod, CPUs | mongot periods throttled | Generator, CPUs |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 11,472 | 0 | 191.2 | 4.8 ms | 7.7 ms | 13.8 ms | 0.129 | 0.006 | 0 of 527 (0%) | 29.3 MiB | 0.15 0.14 0.15 | 0 of 1581 (0%) | 0.12 |
| 2 | 19,589 | 0 | 326.4 | 5.9 ms | 9 ms | 13.6 ms | 0.193 | 0.006 | 0 of 529 (0%) | 30.4 MiB | 0.23 0.22 0.23 | 0 of 1585 (0%) | 0.17 |
| 4 | 34,644 | 0 | 577.3 | 6.5 ms | 10.4 ms | 17.4 ms | 0.264 | 0.006 | 0 of 547 (0%) | 29.9 MiB | 0.33 0.33 0.33 | 0 of 1630 (0%) | 0.27 |
| 8 | 54,987 | 0 | 916.4 | 8 ms | 14.5 ms | 22.6 ms | 0.382 | 0.007 | 0 of 544 (0%) | 30.0 MiB | 0.48 0.48 0.48 | 0 of 1636 (0%) | 0.39 |
| 16 | 86,173 | 0 | 1,436.1 | 9.6 ms | 20.8 ms | 34.9 ms | 0.475 | 0.009 | 0 of 565 (0%) | 27.6 MiB | 0.65 0.64 0.64 | 4 of 1696 (0%) | 0.61 |
| 32 | 135,045 | 0 | 2,250.2 | 12.8 ms | 24.1 ms | 37.1 ms | 0.598 | 0.007 | 0 of 550 (0%) | 29.3 MiB | 0.86 0.85 0.86 | 188 of 1654 (11%) | 0.87 |
| 64 | 121,931 | 0 | 2,031.8 | 24 ms | 71.5 ms | 145.5 ms | 0.465 | 0.014 | 0 of 547 (0%) | 28.9 MiB | 0.75 0.75 0.77 | 354 of 1635 (22%) | 0.85 |

The control plane's restart counts were read by hand before and after each of the two runs and did not move.

**A third run is not used.** The run at the defaults was repeated straight after, from 19:53Z. During it the
lab's kube-controller-manager restarted four times, the readings of the pods failed from the second step, and the
searches a second fell to a tenth. The workstation that holds the cluster, mongod and the generator was at a load
average of 14 to 16 by then, after six runs in a day. No search failed in it either; its figures say nothing of
Envoy.

## What Envoy's own counters say

Read from Prometheus over each run's window, for the listener mongod connects to:

| Run | Envoy pod | Requests in the run | Connections from mongod open at once, most | Retries | Memory in use, most (working set) |
| --- | --- | --- | --- | --- | --- |
| Half a CPU | `mongot-search-lb-0-778dd7bffc-8rw7d` | 464,058 | 1 | 0 | 35.8 MiB |
| Half a CPU | `mongot-search-lb-0-778dd7bffc-tjssz` | 15 | 1 | 0 | 24.5 MiB |
| 2 CPUs | `mongot-search-lb-0-677f86f645-ck8ff` | 463,841 | 1 | 0 | 24.1 MiB |
| 2 CPUs | `mongot-search-lb-0-677f86f645-wtszj` | 15 | 1 | 0 | 27.6 MiB |

The requests of the busy pod are the searches of the run, to the last one. The other pod's 15 are not searches:
about one every 40 s.

## What the console showed

<!-- markdownlint-disable MD033 -->
<img alt="The MongoDB Search dashboard in the OpenShift console over the two runs, 14:28 to 14:53 local time. Searches per second per mongot pod: two humps, the three pods in equal bands, a third each. Requests per second to mongot per Envoy pod: two humps, each of one Envoy pod only. Open connections from mongod per Envoy pod: 1 on each. Retries per second: none. Responses from mongot: all 2xx. Envoy to mongot latency, 95th percentile: up to about 7 ms in the first run and about 9 ms at the end of the second." src="screenshots/envoy-load-dashboard.png">
<!-- markdownlint-enable MD033 -->

*The dashboard over the two runs: the first hump is the run at half a CPU, the second the run at 2 CPUs. Each hump of requests is one Envoy pod; each Envoy pod holds one connection from mongod; the three mongot pods take a third of the searches each; no retries.*

<!-- markdownlint-disable MD033 -->
<img alt="The OpenShift console, the Metrics tab of the pod mongot-search-lb-0-778dd7bffc-8rw7d, an Envoy pod, in the project mongodb-poc, as the user developer. Memory usage: a flat line near the bottom, under the dotted line of its request and far under the dashed box of its limit. CPU usage: a line that rises in steps from near zero to between 300m and 400m, toward the dashed box of its limit of 500m; the dotted line is its request, 100m. The time axis shows 1:55 PM and 2:00 PM." src="screenshots/envoy-load-pod-metrics.png">
<!-- markdownlint-enable MD033 -->

*An Envoy pod at the default limit, in the console, during a run of the first set (18:52Z to 19:01Z; the console shows local time): its CPU climbs toward its limit, the dashed box. The console draws an average over minutes, so it reads lower than the counts in the tables. Its memory does not move.*

## The first set of runs

Three runs earlier that day, 18:28Z to 19:01Z, with eight words of which six match nothing in the collection: a
search returned 2.5 results on average. They are lighter searches, so the rates are higher; the pattern is the
same, and the default limit was run twice.

| At once | Half a CPU, first run | Half a CPU, second run | 2 CPUs |
| --- | --- | --- | --- |
| 1 | 182 a second, p95 8 ms, 0.11 CPUs, throttled 0% | 191 a second, p95 8 ms, 0.11 CPUs, throttled 0% | 189 a second, p95 8 ms, 0.11 CPUs, throttled 0% |
| 2 | 327 a second, p95 10 ms, 0.19 CPUs, throttled 0% | 371 a second, p95 8 ms, 0.18 CPUs, throttled 0% | 364 a second, p95 9 ms, 0.19 CPUs, throttled 0% |
| 4 | 626 a second, p95 11 ms, 0.29 CPUs, throttled 0% | 734 a second, p95 8 ms, 0.28 CPUs, throttled 0% | 746 a second, p95 8 ms, 0.28 CPUs, throttled 0% |
| 8 | 1,250 a second, p95 10 ms, 0.40 CPUs, throttled 4% | 1,083 a second, p95 13 ms, 0.41 CPUs, throttled 6% | 1,103 a second, p95 13 ms, 0.41 CPUs, throttled 0% |
| 16 | 1,715 a second, p95 20 ms, 0.48 CPUs, throttled 33% | 1,664 a second, p95 20 ms, 0.49 CPUs, throttled 29% | 1,809 a second, p95 16 ms, 0.53 CPUs, throttled 0% |
| 32 | 2,232 a second, p95 38 ms, 0.48 CPUs, throttled 32% | 1,941 a second, p95 39 ms, 0.47 CPUs, throttled 32% | 2,736 a second, p95 20 ms, 0.66 CPUs, throttled 0% |
| 64 | 2,600 a second, p95 53 ms, 0.49 CPUs, throttled 27% | 2,536 a second, p95 54 ms, 0.48 CPUs, throttled 26% | 3,035 a second, p95 39 ms, 0.68 CPUs, throttled 0% |

- **The throttling repeated**: 26 to 33% of periods from 16 at once in both runs at half a CPU, none with 2 CPUs.
- **Two runs of the same thing differ**: by 3 to 17% in searches a second at the same step. A difference of
  that size between two settings proves little; the throttled periods and the 95th percentile are what to read.
- **With these lighter searches 2 CPUs was faster at 64 at once too**, although mongot was throttled in 41% of
  periods there.
- 1,646,462 searches, 0 failed.

## What it means

1. **Envoy's CPU limit, not its request, is the number to set.** The operator's default limit is half a CPU. On the
   lab Envoy began to be throttled at about 1,000 searches a second and was throttled in about a third
   of periods from 16 at once, while searches waited. `loadBalancer.resources` with a limit of 2 CPUs removed it.
2. **Raise mongot's CPU with it.** Envoy at its limit was also a brake on what reached mongot. Without it, the lab's
   mongot pods, at 1 CPU each, were the next to be throttled, and the heaviest step got slower, not faster.
3. **More Envoy pods do not help one mongod.** mongod holds one connection to the load balancer's address and sends
   every search over it, so every search of that mongod goes through the one Envoy pod the connection landed on
   ([mongot-route-balance-rationale.md](mongot-route-balance-rationale.md)). The second Envoy pod is what takes the
   connection when the first goes: see [disruption-budgets.md](../chart/mongodb-search-helm/disruption-budgets.md).
4. **In principle one Envoy pod can use about one CPU for one mongod**: Envoy keeps a connection on one of its
   worker threads (its documentation). That was not reached on the lab: the busy pod used 0.68 CPUs at most,
   with mongot and the generator as the limits. A limit of 2 leaves room for that thread and the rest of the
   process.
5. **Each mongot pod took a third of the searches** at every step: Envoy's round robin, as before.

## What this test does not show

- **A production capacity.** The indexes are 16 MiB a pod, a search returns ten small results, and mongod, the
  cluster and the generator share one workstation. The rates are the lab's, and so is the finding that 2 CPUs were
  enough for Envoy: it holds for this load, one connection and these results.
- **Envoy's ceiling.** With 2 CPUs Envoy was not the limit; mongot at 1 CPU and the generator, one `mongosh`, were.
- **How much of a gain in searches a second is the limit's.** See the first set: two runs of the same setting
  differed by up to 17%. Each setting was run once with ten results a search.
- **More than one connection.** One mongod answered every search. Searches sent to several members, or through
  several `mongos`, come over several connections and may land on different Envoy pods.
- **Large results, vector searches, or a node with many more CPUs**, where Envoy starts one worker thread for each.

The repository's older [`mongodb/scripts/load-test.sh`](../mongodb/scripts/load-test.sh) is another test: it runs
`mongosh` workers from the workstation inside the lab's mongod container, and reports the latency and the spread
over the mongot pods. This one runs in the cluster and reads what Envoy and mongot use.

## Running it elsewhere

```bash
export TargetNamespace=<the namespace>
export URI_SECRET=<a Secret there whose key "uri" is a connection string of the source deployment>
DB=<database> COLL=<collection> INDEX=<search index> TERMS=<word,word,...> test/load/run.sh first 1,2,4,8,16 60 15
python3 test/load/analyze.py first
```

It creates one Job and one ConfigMap, `search-load`, and reads the pods' counters with `cat`. Give it words the
collection holds: the generator prints `docs_per_search`, and searches that return nothing measure little. Start
with a few steps: it is a real load on the source deployment and on mongot, and on a small cluster on everything
else. The connection string stays in the Secret.

## Diagram sources

The figure is drawn in [diagrams/envoy-load/source.html](diagrams/envoy-load/source.html) from the two runs'
result files and rendered with [diagram-kit](https://github.com/ephico2real2/diagram-kit); [diagrams/README.md](diagrams/README.md)
has the command. The figure, its text twin here and its page change together.
