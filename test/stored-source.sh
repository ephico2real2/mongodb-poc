#!/usr/bin/env bash
# Unit-tests the five queries of the dashboard's table "What stored source adds" with promtool, on series made up
# for it: an index is one row whatever the data, two candidates of exactly the same size included. The queries are
# read from the Grafana source, so what is tested is what the chart ships. Run from anywhere: test/stored-source.sh.
# Needs python3, and podman or docker (CONTAINER_ENGINE picks one).
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
# The image of test/alerts.sh, by digest for the same reason. v3.15.0, 2026-10-07.
IMAGE="quay.io/prometheus/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

python3 - chart/mongodb-search-helm/files/mongodb-search.json "${work}/stored-source.test.yaml" <<'EOF'
import json
import sys

dashboard = json.load(open(sys.argv[1]))
panel = next(q for p in dashboard["panels"] for q in [p, *p.get("panels", [])] if q.get("title") == "What stored source adds")
queries = [t["expr"].replace("__NAMESPACE__", "ns").replace("__SEARCH__", "mongot") for t in panel["targets"]]
assert len(queries) == 5, "the table has five queries: what it stores, its size, without it, what it adds, per document"
SVC, INFO, NONE_KNOWN = 'namespace="ns",job="mongot-search-0-svc"', 'namespace="ns",job="mongot-index-info"', "no index is known to store fields"


def index(id, where, name, stored, kind="search", size=None, docs=100, info=True, named=True, sizes=None):
    database, collection = where.split(".")
    return dict(id=id, db=database, coll=collection, name=name, stored=stored, kind=kind, docs=docs, info=info, named=named,
                sizes=sizes or {(pod, "a0"): size for pod in (0, 1, 2)})


# What each test is about, its indexes, and the names of two candidates of the same size where it has such a pair.
TESTS = [
    ("two collections, each with its own candidate, and search apart from vector", None, [
        index("a1", "sample_mflix.movies", "default", "none", size=3514585, docs=20024),
        index("a2", "sample_mflix.movies", "vector_index", "none", "vector_search", size=1255266, docs=20024),
        index("a3", "sample_mflix.movies", "ss_include", "include", size=4236233, docs=20024),
        index("a4", "sample_mflix.movies", "ss_vector", "include", "vector_search", size=1749579, docs=20024),
        index("a5", "sample_mflix.movies", "ss_all", "all", size=5900487, docs=20024),
        index("b1", "shop.orders", "plain", "none", size=1000), index("b2", "shop.orders", "kept", "exclude", size=1600)]),
    ("two candidates of exactly the same size: one row, naming one of the two", ("base_a", "base_b"), [
        index("c1", "db.c", "base_a", "none", size=5000), index("c2", "db.c", "base_b", "none", size=5000),
        index("c3", "db.c", "stores", "include", size=8000), index("c4", "db.c", "stores_all", "all", size=9000)]),
    ("three candidates: the smallest is named, and it is not the first", None, [
        index("d1", "db.c", "big", "none", size=9000), index("d2", "db.c", "small", "none", size=4000),
        index("d3", "db.c", "medium", "none", size=7000), index("d4", "db.c", "stores", "include", size=8000)]),
    ("a collection with no candidate: the row is there, compared with nothing", None, [
        index("e1", "db.c", "stores", "include", size=8000), index("e2", "db.c", "vectors", "none", "vector_search", size=100),
        index("e3", "db.d", "plain", "none", size=1000), index("e4", "db.d", "kept", "include", size=1500)]),
    ("the exporter off: the one row that says no index is known to store fields", None, [
        index("f1", "db.c", "base", "none", size=5000, info=False), index("f2", "db.c", "stores", "include", size=8000, info=False)]),
    ("a candidate with no name is shown by its id", None, [
        index("g1", "db.c", "", "none", size=5000, named=False), index("g2", "db.c", "stores", "include", size=8000)]),
    ("two generations of one index: one row, one candidate, the largest reading of each", None, [
        index("h1", "db.c", "base", "none", sizes={(0, "a0"): 5000, (1, "a0"): 5000, (2, "a1"): 5100}),
        index("h2", "db.c", "stores", "include", sizes={(0, "a0"): 8000, (1, "a1"): 8200, (2, "a1"): 8200})]),
]


def series(indexes):
    for i in indexes:
        for (pod, generation), size in sorted(i["sizes"].items()):
            labels = f'{SVC},indexId_logString="{i["id"]}",generationId_logString="{i["id"]}-f6-u0-{generation}",pod="mongot-search-0-{pod}"'
            yield f"mongot_index_stats_indexSizeBytes{{{labels}}}", size
            yield f'mongot_index_stats_indexing_insert_total{{{labels},indexType="{i["kind"]}"}}', 0
            yield f"mongot_index_stats_numLuceneDocs{{{labels}}}", i["docs"]
        if i["info"]:
            name = f',index_name="{i["name"]}"' if i["named"] else ""
            yield (f'mongodb_search_index_info{{{INFO},indexId_logString="{i["id"]}",database="{i["db"]}",collection="{i["coll"]}"'
                   f'{name},stored_source="{i["stored"]}"}}'), 1


def rows(indexes, tie):
    """What the table must show, worked out from the indexes and not from the queries: for each query {labels: value},
    and the name of every row."""
    size = lambda i: max(i["sizes"].values())
    known = [i for i in indexes if i["info"]]
    want, shown = [{} for _ in queries], []
    for row in (i for i in known if i["stored"] != "none"):
        candidates = [c for c in known if c["stored"] == "none" and (c["db"], c["coll"], c["kind"]) == (row["db"], row["coll"], row["kind"])]
        least = min(map(size, candidates), default=None)
        chosen = sorted(c["name"] if c["named"] else c["id"] for c in candidates if size(c) == least)
        assert len(chosen) <= 1 or tuple(chosen) == tie, chosen
        compared = f', compared_with="{" or ".join(chosen)}"' if chosen else ""
        shown.append(f'{row["db"]}.{row["coll"]} / {row["name"]}')
        labels = f'{{index="{shown[-1]}"{compared}}}'
        want[0][labels] = {"include": 1, "exclude": 2, "all": 3}[row["stored"]]
        want[1][labels] = size(row)
        if chosen:
            want[2][labels], want[3][labels], want[4][labels] = least, size(row) - least, (size(row) - least) / row["docs"]
    if not shown:
        shown.append(NONE_KNOWN)
        want[0][f'{{index="{NONE_KNOWN}"}}'] = 0
    return want, shown


out = ["rule_files: []", "evaluation_interval: 1m", "tests:"]
for about, tie, indexes in TESTS:
    out += [f"  - name: {json.dumps(about)}", "    interval: 1m", "    input_series:"]
    for name, value in series(indexes):
        out += [f"      - series: '{name}'", f"        values: '{value}x10'"]
    out.append("    promql_expr_test:")
    # Of two candidates of the same size either may be named: the two names become one text here. Were an index two
    # rows, one for each name, they would be two series of the same labels, which Prometheus refuses.
    either = (lambda q: f'label_replace({q}, "compared_with", "{" or ".join(tie)}", "compared_with", "{"|".join(tie)}")') if tie else (lambda q: q)
    want, shown = rows(indexes, tie)
    for query, samples in zip(queries, want):
        out += [f"      - expr: {json.dumps(either(query))}", "        eval_time: 5m", "        exp_samples:" + ("" if samples else " []")]
        for labels, value in samples.items():
            out += [f"          - labels: '{labels}'", f"            value: {value}"]
    # The table joins the rows of its five queries by all their labels: the five must agree on them, index by index.
    together = " or ".join(f"({q})" for q in queries)
    out += [f"      - expr: {json.dumps(f'count by (index) ({together})')}", "        eval_time: 5m", "        exp_samples:"]
    for name in shown:
        out += [f"          - labels: '{{index=\"{name}\"}}'", "            value: 1"]
open(sys.argv[2], "w").write("\n".join(out) + "\n")
EOF
chmod -R a+rX "${work}"

"${ENGINE}" run --rm -v "${work}:/w:ro" --workdir /w --entrypoint promtool "${IMAGE}" test rules stored-source.test.yaml
