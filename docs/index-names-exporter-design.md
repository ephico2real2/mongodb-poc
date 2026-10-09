# Design: index names on the MongoDB Search dashboard

Oct 9, 2026

This document says how the dashboard comes to show a search index by its name, why it is built the way it is, which limitations it removes and which it leaves. It covers the optional exporter of the chart (`monitoring.indexInfo`) and the dashboard panels that read it. How to turn it on is in the chart's README, [Index names, as metrics](../chart/mongodb-search-helm/README.md#index-names-as-metrics).

**Status.** Built and measured on the lab (OpenShift Local 4.22.7, mongot 1.70.1, mongod 8.3.4). Off by default. Tracked by epic #67, issues #72 and #73.

## The problem

The dashboard's index panels read mongot's per-index metrics, `mongot_index_stats_*`. Those name an index by one label, `indexId_logString`, a 24 character id.

| What a reader wants | What mongot's metrics give | Where that was established |
| --- | --- | --- |
| The index by name: database, collection, index | The id only: `6ab4bc25d292ce5f25d1b708` | One pod emitted 1,017 metric names; none has a label for a name, a database or a collection (lab, Oct 8) |
| A setting that adds the name | None. The labels are fixed in mongot's code, and the operator's `MongoDBSearch` has no field for it | mongot's source at tag `v1.70.1`, `PerIndexMetricsFactory`; the operator's types at 1.13.0 |
| Which indexes define stored source | Nothing. Two counters count the queries that ask for it, for the whole pod | Three test indexes that define it added no metric name and no label (lab, Oct 8) |
| Whether the source deployment sees the index as ready | Nothing in mongot's metrics, and the source's own answer can be wrong | `$listSearchIndexes` said `PENDING` for two days while searches worked (lab, Oct 7 to 9) |

The names exist in one place: the source deployment. `$listSearchIndexes` on a collection returns, for each of its indexes, the `id` mongot's metrics carry, the `name`, and the definition with its `storedSource`.

## The design

<!-- markdownlint-disable MD033 -->
<img alt="How the dashboard gets an index's name. Prometheus scrapes the index info exporter on port 9947 every 60 seconds. The exporter, one pod in the release's namespace, asks the source replica set outside OpenShift over TLS, with a database user of its own that may list and may not read, for names only: $listSearchIndexes. It answers one series per index, or 503 when the source cannot be asked, so that the scrape fails and no old name is served. Prometheus also scrapes each mongot pod every 15 seconds; an index is an id there, with no name and no collection. Prometheus holds both: the sizes by id and the names by id. The dashboard, in the console and in Grafana, asks Prometheus with one query that joins the sizes to the names on the id. Where a name is there, with the exporter on, the reader sees sample_mflix.movies / ss_all and what it stores; with the exporter off, or for an index not listed yet, every panel falls back to the id." src="diagrams/index-info-exporter/name-path.light.png">
<!-- markdownlint-enable MD033 -->

*Figure 1. The path of a name. The exporter adds the one fact mongot does not emit; the dashboard joins it to mongot's metrics on the id, and shows the id where no name is there.*

```text
OUTSIDE OPENSHIFT
  source replica set (mongod): holds each index's name and definition
        ^
        | (2) asks over TLS, names only: $listSearchIndexes
NAMESPACE OF THE RELEASE
  index info exporter, one pod: a Python server that runs mongosh when scraped;
                                its own database user, may list, may not read
        ^  (3) answers one series per index; source cannot be asked -> 503, the scrape fails
        | (1) scraped on port 9947, every 60 s
  mongot pods: mongot_index_stats_*{indexId_logString}, an id, no name
        ^
        | (4) scraped every 15 s
OPENSHIFT-USER-WORKLOAD-MONITORING
  Prometheus: holds both, the sizes by id and the names by id
        ^
        | (5) asks
WHO READS IT
  the dashboard, console and Grafana: one query joins the sizes to the names on the id
        a name is there  -> sample_mflix.movies / ss_all, and what it stores
        no name          -> 6ac852ebd65a7a3f117a6fb1; every panel falls back to the id
```

### What happens on one scrape

1. Prometheus asks the exporter for `/metrics`.
2. If its last answer is older than `cacheSeconds` (60), the exporter runs `mongosh` with the listing script. The connection string is built from the hosts and the CA the `MongoDBSearch` uses and from the exporter's own user and password, and goes to that one child process in its environment.
3. The script asks for the databases, for the collections of each, and for `$listSearchIndexes` of each collection. It skips `admin`, `local`, `config`, mongot's own `__mdb_internal_search`, views and time series collections. It prints one line of JSON.
4. The exporter serves one series per index. If the script could not ask, it answers 503 and serves nothing.

### What the chart adds

<!-- markdownlint-disable MD033 -->
<img alt="The objects of the index info exporter. A Deployment of one pod runs the server and mongosh, unprivileged, with read-only files. It mounts three things: a ConfigMap with the two scripts, made by the chart, so that nothing is built; a Secret with the database user's password, made by hand and checked by the preflight; and the ConfigMap with the source's CA, made by hand, the same one mongot uses. A ClusterIP Service on port 9947 selects the pod and is never given a Route. A ServiceMonitor names that Service's port and tells Prometheus, in user workload monitoring, where to scrape, every 60 seconds. All of it is rendered only when monitoring.indexInfo.enabled is true." src="diagrams/index-info-exporter/exporter-objects.light.png">
<!-- markdownlint-enable MD033 -->

*Figure 2. The objects. The chart makes four; the Secret and the CA are made by hand, like the chart's other prerequisites.*

```text
mounted into the pod                        the pod                       how it is reached
  ConfigMap, the two scripts   (chart)  ->  Deployment, one pod      <-  Service, ClusterIP, port 9947 (selects it)
  Secret, the user's password  (hand)   ->  the server, and mongosh        ^ ServiceMonitor names its port, every 60 s
  ConfigMap, the source's CA   (hand)   ->  unprivileged, read-only  <-  Prometheus scrapes it
All rendered only when monitoring.indexInfo.enabled is true.
```

| Object | What it is for |
| --- | --- |
| ConfigMap `<search.name>-index-info` | Holds the two scripts, `index-info-exporter.py` and `index-info-list.js`. The pod mounts them, so there is no image to build |
| Deployment `<search.name>-index-info` | One pod running the Python server. Unprivileged, read-only file system. Mounts the scripts, the password Secret and the CA bundle |
| Service `<search.name>-index-info` | ClusterIP only, port 9947, so nothing outside the cluster reaches it |
| ServiceMonitor `<search.name>-index-info` | Tells Prometheus to scrape it, every 60 s |
| Secret `search-index-info-password` | The password of the exporter's database user. Made by hand; the preflight checks it when the exporter is on |
| ConfigMap `tls.trustBundleConfigMap` | The CA of the source deployment. Already a prerequisite of the chart |

### What it publishes

| Metric | Labels | Value |
| --- | --- | --- |
| `mongodb_search_index_info` | `indexId_logString`, `database`, `collection`, `index_name`, `stored_source` | 1 |
| `mongodb_search_index_stored_source_paths` | `indexId_logString` | The field paths the stored source includes or excludes |
| `mongodb_search_index_listed_hosts` | `indexId_logString` | The mongot hosts the source lists for the index |
| `mongodb_search_index_info_collections`, `..._collect_timestamp_seconds`, `..._collect_duration_seconds` | | How many collections were asked, when, and how long it took |

### How the dashboard uses it

Every per-index query of the dashboard is wrapped the same way. With `Q` a query that gives one series per index id:

```promql
max by (index) (
    label_join(label_join(
        (Q) * on (indexId_logString) group_left (database, collection, index_name) <the names>,
        "ns", ".", "database", "collection"), "index", " / ", "ns", "index_name")
  or on (indexId_logString)
    label_replace(Q, "index", "$1", "indexId_logString", "(.*)")
)
```

The first half gives each index that has a name the label `index`, as `database.collection / index`. The second half, after `or on (indexId_logString)`, adds the indexes that have none, with their id as `index`. Each index is there once.

**The names are read at the end of the range the page shows** (`@ end()` on the names). Read along the range, a chart carried an index twice whenever its name came or went inside the range, once by its id and once by its name: seen on the lab when the exporter was switched off, with 16 bars for 8 indexes, and it is the same for a new index, which mongot reports before the source lists it. The size chart reads its sizes at the end of the range too, so that an index that is gone has no bar.

The panels show `index`:

| Panel | With the exporter | Without it |
| --- | --- | --- |
| *Each index*, *Each index, now*, *Each index, in the last hour* | A row per index, by name; *Each index* also shows the id and what the index stores | A row per index, by id; *Stored source* is empty |
| *Size of each index* | A bar per index, by name | A bar per index, by id |
| *Indexes not STEADY, per index* | A row per index, by name | A row per index, by id |
| *Indexes with a name*, *Indexes with stored source*, *Indexes with no host listed* | 8, 3 and 0 on the lab | 0, 0 and 0 |
| *What stored source adds* | A row per index that stores fields: its size, the smallest index of its collection and type that stores nothing, and the difference | One row that says no index is known to store fields |

## Why it is built this way

| Decision | Chosen | Considered instead | Why |
| --- | --- | --- | --- |
| Where the names come from | `$listSearchIndexes`, the documented command | Reading mongot's catalog, `__mdb_internal_search.indexCatalog`: one read for every index | The catalog is internal to mongot and can change with a release; reading it needs `find` on a database of mongot's |
| Which user asks | One of its own: `listDatabases`, `listCollections`, `listSearchIndexes` | The sync user the chart already has | The sync user's role may read every collection and write mongot's catalog. A tool that publishes names should not hold that. Measured: the list-only user listed everything, and `find` and `insert` were refused to it |
| When it asks | When scraped, the answer kept for 60 s | A timer of its own, writing a file | Prometheus asks exporters not to collect on a timer of their own; and a timer needs a second signal for staleness |
| When the source cannot be asked | 503, and no names | Serving the last answer | A page of old names answered 200 looks healthy. A failed scrape shows as `up` 0 |
| The image | The stock MongoDB Community Server image: `python3` and `mongosh` | An image of its own with a MongoDB driver | Nothing to build, publish or patch here; the lab's search GUI already runs this way. Its cost: about 1 GB, and a server image used for two programs |
| How the script reaches the pod | A ConfigMap, mounted | Baked into an image | Follows from the choice of image; a changed script is a new pod through a checksum |
| The label of the id | `indexId_logString`, as mongot spells it | `index_id`, as Prometheus would name it | The two join without a relabelling in every query |
| The status of an index | Not published | Publishing `status` and `queryable` | The source's status was wrong on the lab for two days. The number of hosts it lists is published instead, which is what goes wrong |
| On by default | No | Yes | It needs a database user and a Secret made by hand; the chart must install without them |
| The dashboard with the exporter off | The same panels, by id | A second set of panels, or a second dashboard | One dashboard to keep; and an index not listed yet must show too, which is the same case |
| The name of a bar in Grafana | Above the bar | On its left | On the left Grafana cut a 24 character id in 12 pixel type; above, a name is whole whatever its length |

## Limitations it removes

| Before | Now |
| --- | --- |
| An index was a 24 character id on every panel | `sample_mflix.movies / ss_all` in the three tables, on the size chart and in the state history |
| Nothing said which index defines stored source | A *Stored source* column (none, some fields, all but some, all fields) and a count; 3 of 8 on the lab |
| The cost of stored source showed only to someone who knew which ids were alike | *What stored source adds* compares each index that stores fields with the one of its collection and type that stores nothing: 721,648 and 2,385,902 bytes on the lab's `movies` |
| The source could report every index `PENDING` for days, and nothing showed it | *Indexes with no host listed* goes above 0 |
| Names could only be had by giving a tool the right to read data | A user that may list and may not read |
| A names service would be one more image to build and patch | Two scripts in a ConfigMap, on an image MongoDB publishes |
| A stopped names service would leave old names in place | The scrape fails, and the panels fall back to ids |
| Panels made for names would be empty without the exporter | The same panels work with it off |

## Limitations that remain

- **A new index is shown by its id at first**: until the next question to the source (kept for 60 s) and the next scrape (every 60 s). How long that is was not measured.
- **A long name can be cut in a table cell.** The *Index* column is 290 pixels, the widest that lets every table fit a console page 1,280 pixels wide. The size chart and the state history show the whole name.
- **The bytes of stored source are still not measured**, by anything. The dashboard compares two indexes; whatever else differs between their definitions is in the difference too, and a collection with no index that stores nothing has nothing to compare with.
- **One question per collection.** Measured with 3 collections: 0.49 s. Not measured with thousands, where `cacheSeconds` and `interval` should be raised.
- **Views and time series collections are not asked.**
- **Whoever can read the namespace's metrics can read the names** of its indexes, collections and databases.
- **The image is large, about 1 GB, and referenced by tag.** Where outside registries are closed it must be mirrored and `monitoring.indexInfo.image` set.
- **A source that cannot be reached was tested with a stand-in `mongosh`**, not on the lab.

## Measured on the lab

Oct 9, 2026, namespace `mongodb-poc`, 8 indexes in 3 collections.

| Measured | Result |
| --- | --- |
| The list-only user lists every index | 8 indexes, 0.49 s |
| The same user reads or writes a document | Refused: `Unauthorized` |
| The first `up` of 1 after the upgrade | Under 2 minutes |
| Series the exporter serves | 27 |
| Memory of the pod between scrapes | 9 Mi |
| The 33 queries of the two index sections, exporter on | 33 answer, none empty; 8 rows by name |
| The same 33 with no names in Prometheus | 33 answer; 8 rows by id; one empty, the *Stored source* column |
| An index in the charts when its name comes or goes inside the range shown | Once: 8 bars by id just after the exporter was switched off, 8 by name just after it was switched on. Before the names were read at the end of the range: 16 |
| The Grafana form, exporter on | 52 panels in 7 rows listed; 135 of 135 queries answered; no "No data" in either theme |

## Tests

`test/chart.sh` renders the exporter on and off, checks its connection settings, its security context, the preflight and two refusals of the schema, and runs the server against a stand-in `mongosh`: the page, one listing for several scrapes, the password in no argument, 503 on failure, recovery. It also checks that every per-index query of the dashboard has the two halves above. Five deliberate breakages of the exporter were each caught.

## Diagram sources

The two figures come from `diagrams/index-info-exporter/source.html`, rendered to a light and a dark PNG with diagram-kit (https://github.com/ephico2real2/diagram-kit, MPL-2.0); this document embeds the light ones. The page holds two figures, in this order: `name-path` and `exporter-objects`.

```bash
~/.local/share/diagram-kit/.venv/bin/diagram-render docs/diagrams/index-info-exporter/source.html docs/diagrams/index-info-exporter name-path,exporter-objects
```

To change a figure, edit the page, render both PNGs again, and update its `alt` text and its `text` twin in the same commit.
