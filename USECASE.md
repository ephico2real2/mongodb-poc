# The use case: searching your own incident history

The movie corpus proves the *plumbing*. It does not show why anyone would pay for a search
tier. This one does: **20 platform incidents across 6 failure domains**, in
`platform_ops.incidents`, with both a text index and a vector index over the same documents.

```bash
cd mongodb && ./scripts/load-incidents.sh
```

```text
incidents loaded: 20
index requested: incidents_text (search)
index requested: incidents_vector (vectorSearch)
QUERYABLE: incidents_text, incidents_vector
```

Each incident carries a title, a symptom, a diagnosis, a resolution, a `component`
(the failure domain), a `severity`, and a hand-set 6-dimension embedding:

```text
[ scheduling, network, storage, tls, auth, performance ]
```

Six dimensions, set by hand, is not a production embedding — it is small enough to read and
reason about, which is the point for a POC. Several incidents are real findings from building
this deployment: INC-1030 (TLS configured but no certificates mounted), INC-1032 (the proxy
still serving a retired CA after rotation), INC-1051 (one replica serving all traffic).

## The question the corpus is built to answer

An engineer at 2am does not remember the words the last person used. They type what they see.

> *"everything hitting a single instance"*

There is an incident that is exactly this — **INC-1051, "One replica serving all traffic"**.
It shares no distinctive vocabulary with the query.

## What each index actually returns

Four paraphrases, three results each, with the failure domain of every hit:

| Query | Keyword (`$search`) |
|---|---|
| `everything hitting a single instance` | INC-1052 `[performance]`, INC-1002 `[scheduling]`, INC-1042 `[auth]` |
| `uneven workload spread` | INC-1042 `[auth]`, INC-1012 `[network]` |
| `one box doing all the work` | INC-1051 `[performance]`, INC-1032 `[tls]`, INC-1031 `[tls]` |
| `why is throughput dropping` | INC-1013 `[network]`, INC-1050 `[performance]` |

Against the same corpus, one vector probe pointed at the performance dimension:

```text
$vectorSearch  queryVector [0.4, 0.4, 0, 0, 0, 0.95]
   INC-1051  One replica serving all traffic          [performance]  0.981
   INC-1050  p99 latency collapses under concurrency  [performance]  0.967
   INC-1052  Slow queries after a large data load     [performance]  0.936
```

## Reading that honestly

**Keyword search is not useless here, and it does not "fail".** On *"one box doing all the
work"* it ranked INC-1051 — the right answer — first. It returns results for every probe.

What it cannot do reliably is **stay inside the right failure domain**. Across those four
paraphrases it returned **3 of 10 results from the performance domain**; the other seven were
auth, network, TLS and scheduling incidents that happened to share ordinary words like
*pods*, *single*, *dropping*. On *"uneven workload spread"* it returned **nothing** from the
right domain, and on *"everything hitting a single instance"* it missed INC-1051 entirely.

The vector index returned **3 of 3**, correctly ordered, and they are precisely the three
performance incidents in the corpus.

That is the claim this corpus supports, stated no more strongly than the data allows:

> Keyword search returns plausible-looking hits from the wrong failure domain. Vector search
> returns the right domain, correctly ranked. On a corpus of past incidents, that is the
> difference between a search box someone trusts at 2am and one they stop opening.

The test suite asserts both halves of this, so a regression in either is a failure, not a
surprise:

```text
PASS  keyword finds an exact term                    INC-1002
PASS  keyword misses the paraphrase                  got INC-1052,INC-1002,INC-1042
PASS  vector finds it from intent alone              INC-1051
PASS  vector recall@3 for 'performance'              3/3
```

## Filters are the other half

Semantic similarity alone is not enough — an engineer looking at a storage incident does not
want a TLS incident that happens to be nearby in vector space. Both `component` and `severity`
are declared as `filter` paths in `incidents-vector.json`, so they narrow the candidate set
*before* ranking:

```javascript
{ $vectorSearch: {
    index: 'incidents_vector', path: 'embedding',
    queryVector: [0.3, 0, 0.95, 0, 0, 0.05],
    numCandidates: 50, limit: 5,
    filter: { component: { $eq: 'storage' } }
} }
```

The suite checks that this genuinely excludes other components, and that an unsatisfiable
filter returns nothing rather than quietly ignoring the filter — a failure mode that looks
like working search until someone checks the results.

## Trying it

```bash
./app/trace-query.sh -m vector -d performance     # and see which pod answered
./app/trace-query.sh "CrashLoopBackOff"
./test/run.sh search
```

Domains for `-d`: `scheduling`, `network`, `storage`, `tls`, `auth`, `performance`.
