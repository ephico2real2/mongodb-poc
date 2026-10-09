#!/usr/bin/env python3
"""Publishes one series per search index of the source deployment, so a dashboard can show an index by its name.

mongot's own metrics name an index by its id only (the label indexId_logString). The names are in the source
deployment: $listSearchIndexes returns the id, the name and the definition of every index of a collection. This
server asks for them and serves them as Prometheus metrics, with the id under the same label name as mongot's, so a
query joins the two without relabelling.

It runs on the stock mongodb-community-server image and needs nothing installed: python3's standard library for the
server, mongosh for the listing. Nothing is collected on a timer: a scrape asks the source, and the answer is kept
for CACHE_SECONDS. When the source cannot be asked the scrape is answered 503, so that it fails: a page of old
names answered 200 would look healthy.

The database user needs listDatabases on the cluster, and listCollections and listSearchIndexes on every database.
It needs no right to read a document, and should have none.
"""
import json
import os
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOSTS = os.environ["SOURCE_HOSTS"]                                     # host:port, comma separated
USERNAME = os.environ["SOURCE_USERNAME"]
PASSWORD_FILE = os.environ.get("SOURCE_PASSWORD_FILE", "/etc/index-info/password")
CA_FILE = os.environ.get("SOURCE_CA_FILE", "/etc/source-ca/ca.crt")
URI_OPTIONS = os.environ.get("SOURCE_URI_OPTIONS", "")                 # for example replicaSet=rs0
LIST_SCRIPT = os.environ.get("LIST_SCRIPT", "/app/index-info-list.js")
CACHE_SECONDS = float(os.environ.get("CACHE_SECONDS", "60"))
TIMEOUT_SECONDS = float(os.environ.get("TIMEOUT_SECONDS", "20"))
PORT = int(os.environ.get("PORT", "9947"))
PREFIX = "mongodb_search_index"


def source_uri():
    # Read at every collection: a rotated Secret is picked up without a restart.
    with open(PASSWORD_FILE, encoding="utf-8") as f:
        password = f.read().strip("\r\n")
    quote = lambda s: urllib.parse.quote(s, safe="")
    options = f"tls=true&tlsCAFile={quote(CA_FILE)}&appName=search-index-info" + (f"&{URI_OPTIONS}" if URI_OPTIONS else "")
    return f"mongodb://{quote(USERNAME)}:{quote(password)}@{HOSTS}/admin?{options}"


def collect():
    """The source's search indexes, from mongosh: {"collections": n, "indexes": [...]}. Raises when it cannot ask."""
    # The connection string goes in the environment of the one child process, not in an argument list.
    env = dict(os.environ, SOURCE_URI=source_uri(), HOME=os.environ.get("HOME", "/tmp"))
    done = subprocess.run(["mongosh", "--nodb", "--quiet", "--norc", "--file", LIST_SCRIPT], env=env, capture_output=True,
                          text=True, timeout=TIMEOUT_SECONDS)
    for line in done.stdout.splitlines():
        if line.startswith("RESULT "):
            return json.loads(line[len("RESULT "):])
    # mongosh's own words say why (a refused login, an unknown host), and never hold the password.
    said = (done.stderr or done.stdout).strip().splitlines()
    raise RuntimeError(said[-1][:300] if said else f"mongosh ended with {done.returncode} and said nothing")


def label(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def page(found, taken, seconds):
    lines = [f"# HELP {PREFIX}_info A search index of the source deployment, as $listSearchIndexes lists it. The value is 1.",
             f"# TYPE {PREFIX}_info gauge"]
    for i in found["indexes"]:
        lines.append(f'{PREFIX}_info{{indexId_logString="{label(i["id"])}",database="{label(i["database"])}",collection="{label(i["collection"])}",'
                     f'index_name="{label(i["name"])}",stored_source="{label(i["storedSource"])}"}} 1')
    lines += [f"# HELP {PREFIX}_stored_source_paths Field paths the index's stored source includes or excludes; 0 when it stores all or none.",
              f"# TYPE {PREFIX}_stored_source_paths gauge"]
    lines += [f'{PREFIX}_stored_source_paths{{indexId_logString="{label(i["id"])}"}} {i["storedSourcePaths"]}' for i in found["indexes"]]
    lines += [f"# HELP {PREFIX}_listed_hosts mongot hosts the source deployment lists for the index. 0 while searches work means the hosts' heartbeats are lost.",
              f"# TYPE {PREFIX}_listed_hosts gauge"]
    lines += [f'{PREFIX}_listed_hosts{{indexId_logString="{label(i["id"])}"}} {i["hosts"]}' for i in found["indexes"]]
    lines += [f"# HELP {PREFIX}_info_collections Collections that were asked for their search indexes.",
              f"# TYPE {PREFIX}_info_collections gauge", f"{PREFIX}_info_collections {found['collections']}",
              f"# HELP {PREFIX}_info_collect_timestamp_seconds When the source deployment was last asked.",
              f"# TYPE {PREFIX}_info_collect_timestamp_seconds gauge", f"{PREFIX}_info_collect_timestamp_seconds {taken:.0f}",
              f"# HELP {PREFIX}_info_collect_duration_seconds How long asking the source deployment took.",
              f"# TYPE {PREFIX}_info_collect_duration_seconds gauge", f"{PREFIX}_info_collect_duration_seconds {seconds:.3f}"]
    return "\n".join(lines) + "\n"


class Cache:
    def __init__(self):
        self.lock, self.text, self.taken = threading.Lock(), None, 0.0

    def metrics(self):
        with self.lock:                                               # one collection at a time, whoever asks
            if self.text is None or time.time() - self.taken >= CACHE_SECONDS:
                self.text = None                                      # never serve what a failed collection left
                started = time.time()
                found = collect()
                self.taken = time.time()
                self.text = page(found, self.taken, self.taken - started)
            return self.text


CACHE = Cache()


class Handler(BaseHTTPRequestHandler):
    def answer(self, status, body, kind="text/plain; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":                                   # the process is up; the source is the scrape's business
            return self.answer(200, "ok\n")
        if self.path != "/metrics":
            return self.answer(404, "not found\n")
        try:
            self.answer(200, CACHE.metrics(), "text/plain; version=0.0.4; charset=utf-8")
        except Exception as e:                                        # 503: the scrape fails, which is the signal
            print(f"the source deployment could not be asked: {type(e).__name__}: {e}", flush=True)
            self.answer(503, f"the source deployment could not be asked: {type(e).__name__}\n")

    def log_message(self, *args):                                     # a line per scrape would bury the failures
        pass


if __name__ == "__main__":
    print(f"serving {PREFIX}_info on :{PORT}/metrics; the source is asked at most every {CACHE_SECONDS:g} s", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
