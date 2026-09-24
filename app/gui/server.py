#!/usr/bin/env python3
"""Search GUI that shows WHICH mongot pod served your query.

Runs inside OpenShift on the mongodb-community-server image, so it needs nothing
installed: python3 stdlib for the server, mongosh for the query, urllib for metrics.

It talks ONLY to MongoDB. It never addresses mongot, Envoy or the VIP - mongod forwards
the $search stage over gRPC. The per-pod attribution is done by reading each mongot's
Prometheus counter immediately before and after the query, so the pod whose counter
moved is the pod that served it.
"""
import html, json, os, re, subprocess, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

MONGO_URI = os.environ["MONGO_URI"]
DB        = os.environ.get("DB", "sample_mflix")
COLL      = os.environ.get("COLL", "movies")
SVC       = os.environ.get("MONGOT_SVC", "mongot-search-0-svc")
REPLICAS  = int(os.environ.get("MONGOT_REPLICAS", "3"))
PODS      = [f"mongot-search-0-{i}" for i in range(REPLICAS)]

TEXT_METRIC = "mongot_command_searchCommandTotalLatency_seconds_count"
VEC_METRIC  = "mongot_command_vectorSearchCommandTotalLatency_seconds_count"

THEMES = {
    "underdog": [0.9, 0.1, 0, 0.05, 0], "karate": [0.9, 0.1, 0, 0.05, 0],
    "americana": [0, 0.9, 0, 0, 0],     "baseball": [0, 0.9, 0, 0, 0],
    "creature": [0, 0, 0.9, 0, 0],      "horror": [0, 0, 0.9, 0, 0],
    "space": [0, 0, 0, 0.92, 0],        "astronaut": [0, 0, 0, 0.92, 0],
    "noir": [0, 0, 0, 0, 0.92],         "detective": [0, 0, 0, 0, 0.92],
}

def counters(metric):
    """Per-pod counter, read straight from each mongot's Prometheus endpoint."""
    out = {}
    for p in PODS:
        try:
            with urllib.request.urlopen(f"http://{p}.{SVC}:9946/metrics", timeout=4) as r:
                body = r.read().decode()
            m = re.search(rf"^{metric}\{{[^}}]*\}}\s+([0-9.]+)", body, re.M) \
                or re.search(rf"^{metric}\s+([0-9.]+)", body, re.M)
            out[p] = float(m.group(1)) if m else 0.0
        except Exception:
            out[p] = None
    return out

def run_query(q, mode):
    if mode == "vector":
        vec = THEMES.get(q.lower().strip(), [0.2, 0.2, 0.2, 0.2, 0.2])
        stage = (f'{{$vectorSearch:{{index:"vector_index",path:"plot_embedding",'
                 f'queryVector:{json.dumps(vec)},numCandidates:200,limit:8}}}}')
        meta = "vectorSearchScore"
    else:
        safe = q.replace('"', '\\"')
        stage = (f'{{$search:{{index:"default",text:{{query:"{safe}",'
                 f'path:{{wildcard:"*"}}}}}}}}')
        meta = "searchScore"
    js = (f'const r=db.getSiblingDB("{DB}").{COLL}.aggregate([{stage},'
          f'{{$project:{{title:1,year:1,genre:1,score:{{$meta:"{meta}"}}}}}},'
          f'{{$limit:8}}]).toArray(); print(JSON.stringify(r));')
    p = subprocess.run(["mongosh", MONGO_URI, "--quiet", "--eval", js],
                       capture_output=True, text=True, timeout=45)
    line = [l for l in p.stdout.strip().split("\n") if l.startswith("[")]
    if not line:
        return None, (p.stderr or p.stdout or "no output").strip()[:400]
    return json.loads(line[-1]), None

CSS = """
:root{--bg:#0e131a;--card:#151c25;--ink:#e5e9ef;--mut:#9aa5b3;--ru:#2a3440;
--ok:#3fcfc0;--hot:#f0a53c;--bad:#f2857c}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);
font:15px/1.5 'IBM Plex Sans',system-ui,sans-serif}
.wrap{max-width:1000px;margin:0 auto;padding:32px 18px 60px}
h1{font-size:25px;margin:0 0 4px}.sub{color:var(--mut);margin:0 0 24px;font-size:14px}
form{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:22px}
input[type=text]{flex:1;min-width:230px;padding:11px 14px;border-radius:8px;
border:1px solid var(--ru);background:var(--card);color:var(--ink);font-size:15px}
select,button{padding:11px 16px;border-radius:8px;border:1px solid var(--ru);
background:var(--card);color:var(--ink);font-size:15px;cursor:pointer}
button{background:var(--ok);color:#06231f;font-weight:600;border:0}
.card{background:var(--card);border:1px solid var(--ru);border-radius:10px;
padding:18px 20px;margin-bottom:18px}
.card h2{font-size:15px;margin:0 0 14px;color:var(--mut);font-weight:600;
letter-spacing:.06em;text-transform:uppercase}
table{width:100%;border-collapse:collapse;font-size:14px}
th{text-align:left;color:var(--mut);font-size:11px;text-transform:uppercase;
letter-spacing:.06em;padding:0 10px 8px}
td{padding:8px 10px;border-top:1px solid var(--ru)}
.mono{font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:13px}
.bar{height:22px;border-radius:5px;background:var(--ok);min-width:3px}
.bar.zero{background:var(--ru)}
.served{color:var(--hot);font-weight:600}
.pill{display:inline-block;padding:2px 9px;border-radius:99px;font-size:11.5px;
background:#122a28;color:var(--ok);border:1px solid var(--ok)}
.err{color:var(--bad)}.path{color:var(--mut);font-size:12.5px;line-height:1.9}
.path b{color:var(--ink)}
"""

def page(q, mode, rows, err, delta, totals, ms):
    def esc(x): return html.escape(str(x))
    out = [f"<!doctype html><meta charset=utf-8><title>mongot search</title>",
           "<link rel=stylesheet href='https://fonts.googleapis.com/css2?"
           "family=IBM+Plex+Sans:wght@400;600&family=IBM+Plex+Mono&display=swap'>",
           f"<style>{CSS}</style><div class=wrap>",
           "<h1>MongoDB Search &mdash; who served it?</h1>",
           "<p class=sub>This page queries <b>MongoDB only</b>. mongod forwards the "
           "search over gRPC through Envoy to the mongot pods. The pod whose counter "
           "moved is the one that answered.</p>",
           f"<form method=get action='/'>"
           f"<input type=text name=q value='{esc(q)}' placeholder='detective, karate, space…' autofocus>"
           f"<select name=mode>"
           f"<option value=text {'selected' if mode=='text' else ''}>$search (text)</option>"
           f"<option value=vector {'selected' if mode=='vector' else ''}>$vectorSearch</option>"
           f"</select><button type=submit>Search</button></form>"]

    if err:
        out.append(f"<div class=card><h2>Error</h2><div class='mono err'>{esc(err)}</div></div>")

    if delta is not None:
        served = [p for p, d in delta.items() if d and d > 0]
        out.append("<div class=card><h2>Which mongot served this query</h2><table>")
        mx = max([d for d in delta.values() if d] or [1])
        for p in PODS:
            d = delta.get(p)
            tot = totals.get(p)
            w = int(100 * (d or 0) / mx) if mx else 0
            cls = "bar" if d else "bar zero"
            name = f"<span class=served>{esc(p)}</span>" if d else esc(p)
            out.append(f"<tr><td class=mono style='width:210px'>{name}</td>"
                       f"<td style='width:120px'><div class='{cls}' style='width:{max(w,3)}%'></div></td>"
                       f"<td class=mono style='width:90px'>{'+' + str(int(d)) if d else '—'}</td>"
                       f"<td class=mono style='color:#9aa5b3'>lifetime {int(tot) if tot is not None else '?'}</td></tr>")
        out.append("</table>")
        if served:
            out.append(f"<p class=sub style='margin:12px 0 0'>Served by "
                       f"<span class=pill>{esc(', '.join(served))}</span> &nbsp;&middot;&nbsp; "
                       f"{ms} ms round trip</p>")
        out.append("</div>")

    if rows is not None:
        out.append(f"<div class=card><h2>Results &mdash; {len(rows)}</h2><table>"
                   "<tr><th>Title</th><th>Year</th><th>Genre</th><th>Score</th></tr>")
        for r in rows:
            out.append(f"<tr><td>{esc(r.get('title',''))}</td>"
                       f"<td class=mono>{esc(r.get('year',''))}</td>"
                       f"<td class=mono>{esc(r.get('genre',''))}</td>"
                       f"<td class=mono>{r.get('score',0):.4f}</td></tr>")
        out.append("</table></div>")

    out.append("<div class=card><h2>The path this query took</h2><div class=path>"
               "<b>this page</b> &rarr; <b>mongod</b> (outside the cluster) &rarr; one "
               "long-lived HTTP/2 connection &rarr; <b>Envoy</b> &rarr; one of "
               f"<b>{REPLICAS} mongot pods</b><br>"
               "The app never addresses mongot. Envoy splits <i>individual gRPC "
               "streams</i>, which is why repeated searches land on different pods."
               "</div></div></div>")
    return "".join(out)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/healthz":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok"); return
        qs = parse_qs(u.query)
        q = (qs.get("q", [""])[0]).strip()
        mode = qs.get("mode", ["text"])[0]
        rows = err = delta = None; totals = {}; ms = 0
        if q:
            metric = VEC_METRIC if mode == "vector" else TEXT_METRIC
            before = counters(metric)
            import time; t0 = time.time()
            rows, err = run_query(q, mode)
            ms = int((time.time() - t0) * 1000)
            after = counters(metric)
            delta = {p: (None if after.get(p) is None or before.get(p) is None
                         else after[p] - before[p]) for p in PODS}
            totals = after
        body = page(q, mode, rows, err, delta, totals, ms).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
