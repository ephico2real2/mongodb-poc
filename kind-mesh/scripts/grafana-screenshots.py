"""Screenshots of the lab's Hubble flows dashboard in Grafana (mesh0), light and dark, into docs/screenshots/.

    ~/.local/share/diagram-kit/.venv/bin/python kind-mesh/scripts/grafana-screenshots.py [--from ISO] [--to ISO]

--from and --to (UTC, e.g. 2026-10-22T19:30:00Z) fix the time range, so the pictures show a drill; the default is the
last hour. Grafana is reached through a kubectl port-forward and logged in through its /login API, which sets the
browser's session cookie (it answers a page without a session with a redirect, not a basic-auth challenge): the password
is read from the grafana-admin Secret and never printed or written. Playwright and Chromium come from diagram-kit's venv.
"""
import argparse
import base64
import datetime as dt
import json
import os
import pathlib
import socket
import subprocess
import sys
import time

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "screenshots"
KUBE = ["kubectl", "--kubeconfig", os.path.expanduser("~/.kube/mongodb-mesh.config"), "--context", "kind-mesh0",
        "-n", "observability"]
UID = "hubble-observer-23862"
PORT = 3301

# (file name, what to show): a section is the dashboard from one row's title to the next one's, drawn in a viewport tall
# enough to hold it unscrolled; a panel is Grafana's single-panel view.
SHOTS = [
    ("kind-mesh-grafana-across-clusters", {"section": "Across the clusters", "until": "Statistics"}),
    ("kind-mesh-grafana-statistics", {"section": "Statistics", "until": "History"}),
    ("kind-mesh-grafana-search-per-cluster", {"panel": 903}),
    ("kind-mesh-grafana-history", {"panel": 1}),
    ("kind-mesh-grafana-unique-flows", {"panel": 14}),
    ("kind-mesh-grafana-raw-flows", {"panel": 3}),
]


def epoch_ms(iso):
    return int(dt.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)


def wait_port(port, seconds=20):
    deadline = time.time() + seconds
    while time.time() < deadline:
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.5)
    sys.exit(f"grafana-screenshots: the port-forward to Grafana did not open on {port}")


def settle(page):
    # Grafana draws panels as their queries return; wait for the network, then for every panel's loading bar to go.
    page.wait_for_load_state("networkidle")
    page.wait_for_function("!document.querySelector('[aria-label=\"Panel loading bar\"]')", timeout=60000)
    page.wait_for_timeout(1500)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="start")
    ap.add_argument("--to", dest="end")
    ap.add_argument("--only", help="comma-separated file names from SHOTS")
    ap.add_argument("--prefix", help="file names start with this instead of kind-mesh-grafana (another test's pictures "
                                     "of the same panels, e.g. vanity-grafana for story #198)")
    ap.add_argument("--query", help="added to the dashboard URL's query: the dashboard's variables, e.g. "
                                    "var-destinationnamespace=vanity-lab to show the flows to one namespace")
    a = ap.parse_args()
    rng = (f"from={epoch_ms(a.start)}&to={epoch_ms(a.end)}" if a.start and a.end else "from=now-1h&to=now")
    if a.query:
        rng += "&" + a.query
    secret = json.loads(subprocess.check_output(KUBE + ["get", "secret", "grafana-admin", "-o", "json"]))
    password = base64.b64decode(secret["data"]["admin-password"]).decode()
    pf = subprocess.Popen(KUBE + ["port-forward", "svc/grafana", f"{PORT}:80"], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL)
    try:
        wait_port(PORT)
        base = f"http://127.0.0.1:{PORT}/d/{UID}?orgId=1&{rng}&kiosk"
        wanted = set(a.only.split(",")) if a.only else None
        with sync_playwright() as p:
            browser = p.chromium.launch()
            for theme in ("light", "dark"):
                ctx = browser.new_context(viewport={"width": 1600, "height": 900}, device_scale_factor=2)
                login = ctx.request.post(f"http://127.0.0.1:{PORT}/login",
                                         data={"user": "admin", "password": password})
                if not login.ok:
                    sys.exit(f"grafana-screenshots: Grafana refused the login: HTTP {login.status}")
                page = ctx.new_page()
                for name, spec in SHOTS:
                    if wanted and name not in wanted:
                        continue
                    suffix = "" if theme == "light" else ".dark"
                    stem = name.replace("kind-mesh-grafana", a.prefix, 1) if a.prefix else name
                    path = OUT / f"{stem}{suffix}.png"
                    if "panel" in spec:
                        page.set_viewport_size({"width": 1600, "height": 900})
                        page.goto(f"{base}&theme={theme}&viewPanel={spec['panel']}")
                        settle(page)
                        page.screenshot(path=path)
                    else:
                        page.set_viewport_size({"width": 1600, "height": 3200})
                        page.goto(f"{base}&theme={theme}")
                        settle(page)
                        top = page.get_by_text(spec["section"], exact=True).first.bounding_box()
                        end = page.get_by_text(spec["until"], exact=True).first.bounding_box()
                        page.screenshot(path=path, clip={"x": 0, "y": top["y"] - 12, "width": 1600,
                                                         "height": end["y"] - top["y"] + 4})
                    print(f"  {path.relative_to(ROOT)}")
                ctx.close()
            browser.close()
    finally:
        pf.terminate()


if __name__ == "__main__":
    main()
