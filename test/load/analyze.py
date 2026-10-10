#!/usr/bin/env python3
"""analyze.py <path>/<tag>: one row a step of a load run, from <tag>.load (the generator's JSON lines) and
<tag>.samples (cgroup counters read from the pods about every 6 s), both written by test/load/run.sh.

CPU is the growth of usage_usec between the first sample at or after a step's start and the last at or before its
end, over the time between those two samples. Throttled periods are the growth of nr_throttled over nr_periods in
the same window: the share of 100 ms periods in which the container was stopped at its CPU limit.
It also writes <tag>.result.json."""
import collections, datetime, json, re, sys

tag = sys.argv[1]
ts = lambda s: datetime.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()
steps = [json.loads(l) for l in open(f"{tag}.load") if l.startswith("{")]
steps = [s for s in steps if s.get("step") == "done"]
samples = collections.defaultdict(list)      # (kind, pod) -> [(t, {field: value})]
for l in open(f"{tag}.samples"):
    p = l.split()
    if len(p) < 4:
        continue
    f = dict(kv.split("=", 1) for kv in p[3:] if "=" in kv)
    try:
        samples[(p[1], p[2])].append((ts(p[0]), {k: (int(v) if v.isdigit() else v) for k, v in f.items()}))
    except ValueError:
        continue

def window(key, a, b):
    rows = [(t, f) for t, f in samples[key] if a <= t <= b and isinstance(f.get("usage_usec"), int)]
    if len(rows) < 2:
        return None
    (t0, f0), (t1, f1) = rows[0], rows[-1]
    dt = t1 - t0
    periods = f1["periods"] - f0["periods"]
    return {"cores": (f1["usage_usec"] - f0["usage_usec"]) / 1e6 / dt, "periods": periods,
            "throttled": f1["throttled"] - f0["throttled"],
            "throttled_s": (f1["throttled_usec"] - f0["throttled_usec"]) / 1e6,
            "mem": max(f["mem"] for _, f in rows), "dt": dt, "cpu_max": f1.get("cpu_max")}

print(f"run {tag}: {len(steps)} steps; pods sampled: " + ", ".join(sorted(f"{k[0]} {k[1]}" for k in samples)))
hdr = ("conc", "ok", "failed", "per s", "p50 ms", "p95 ms", "p99 ms", "envoy cores (each pod)", "envoy sum", "mcores per search/s",
       "envoy throttled periods", "envoy mem MiB", "mongot cores (each)", "mongot throttled periods", "load cores")
print(" | ".join(hdr))
out = []
for s in steps:
    a, b = ts(s["start"]), ts(s["end"])
    env = {k[1]: window(k, a, b) for k in samples if k[0] == "envoy"}
    mon = {k[1]: window(k, a, b) for k in samples if k[0] == "mongot"}
    load = [window(k, a, b) for k in samples if k[0] == "load"]
    env = {k: v for k, v in env.items() if v}
    mon = {k: v for k, v in mon.items() if v}
    esum = sum(v["cores"] for v in env.values())
    thr = "; ".join(f"{k} {v['throttled']}/{v['periods']} ({v['throttled_s']:.1f} s)" for k, v in sorted(env.items()))
    row = {"concurrency": s["concurrency"], "ok": s["ok"], "failed": s["failed"], "per_second": s["per_second"], **s["ms"],
           "envoy_cores": {k: round(v["cores"], 3) for k, v in sorted(env.items())}, "envoy_sum": round(esum, 3),
           "mcores_per_rps": round(1000 * esum / s["per_second"], 3) if s["per_second"] else None,
           "throttled": {k: [v["throttled"], v["periods"], round(v["throttled_s"], 2)] for k, v in sorted(env.items())},
           "envoy_mem_mib": {k: round(v["mem"] / 1048576, 1) for k, v in sorted(env.items())},
           "mongot_cores": {k: round(v["cores"], 2) for k, v in sorted(mon.items())},
           "mongot_throttled": [sum(v["throttled"] for v in mon.values()), sum(v["periods"] for v in mon.values())],
           "load_cores": round(load[0]["cores"], 2) if load and load[0] else None,
           "first_error": s.get("first_error", "")}
    out.append(row)
    print(" | ".join(str(x) for x in (
        s["concurrency"], s["ok"], s["failed"], s["per_second"], s["ms"]["p50"], s["ms"]["p95"], s["ms"]["p99"],
        " ".join(f"{k}={v:.3f}" for k, v in row["envoy_cores"].items()), f"{esum:.3f}", row["mcores_per_rps"], thr,
        " ".join(f"{k}={v}" for k, v in row["envoy_mem_mib"].items()),
        " ".join(f"{k}={v}" for k, v in row["mongot_cores"].items()),
        f"{row['mongot_throttled'][0]}/{row['mongot_throttled'][1]}", row["load_cores"])))
    if s.get("first_error"):
        print("    first error:", s["first_error"])
json.dump(out, open(f"{tag}.result.json", "w"), indent=1)
