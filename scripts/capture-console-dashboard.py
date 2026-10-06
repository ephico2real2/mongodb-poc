#!/usr/bin/env python3
"""Open the MongoDB Search dashboard inside the OpenShift console as a viewer, check it, and capture it.

    python3 scripts/capture-console-dashboard.py https://<console host> <namespace> <out-dir> <light|dark> [dashboard]

It logs in through the OpenShift login (OC_USER / OC_PASSWORD on the identity provider OC_PROVIDER; by default
OpenShift Local's own `developer` user), opens Observe -> Dashboards (Perses) for the namespace, and saves
<out-dir>/dashboard-console.<theme>.png. It prints what a reader of the page would check: the sections, any
panel that says "No data", "NaN" or "Forbidden", any warning sign, and every response of 400 or above after
the login. Needs Playwright with Chromium.

The theme: the console draws in the theme the user chose under User Preferences, and follows the browser only
when that is "System default". The script asks the browser for <light|dark> and reports what the console drew.

The viewer needs `view`, `persesdashboard-viewer-role` and `persesdatasource-viewer-role` in the namespace, and
`cluster-monitoring-view` for the data.
"""
import os
import pathlib
import sys

from playwright.sync_api import sync_playwright

console, namespace, out, theme = sys.argv[1].rstrip("/"), sys.argv[2], pathlib.Path(sys.argv[3]), sys.argv[4]
dashboard = sys.argv[5] if len(sys.argv) > 5 else "mongot-search"
out.mkdir(parents=True, exist_ok=True)
url = f"{console}/monitoring/v2/dashboards/view?dashboard={dashboard}&project={namespace}&start=15m"

with sync_playwright() as p:
    browser = p.chromium.launch()
    # Tall enough for the whole dashboard: Perses draws a panel only once it is in view.
    ctx = browser.new_context(viewport={"width": 1600, "height": int(os.environ.get("CAPTURE_HEIGHT", "5000"))}, device_scale_factor=1,
                              ignore_https_errors=True, color_scheme=theme)
    page = ctx.new_page()
    page.goto(url, wait_until="networkidle", timeout=90000)
    # The login page lists the identity providers when there are several, and is the form itself when there is one.
    provider = page.get_by_role("link", name=os.environ.get("OC_PROVIDER", "developer"), exact=True)
    provider.or_(page.locator("#inputUsername")).first.wait_for(timeout=60000)
    if provider.count():
        provider.first.click()
        page.locator("#inputUsername").wait_for(timeout=60000)
    page.fill("#inputUsername", os.environ.get("OC_USER", "developer"))
    page.fill("#inputPassword", os.environ.get("OC_PASSWORD", "developer"))
    page.click("button[type=submit]")
    page.wait_for_load_state("networkidle", timeout=90000)
    print("after the login, the browser is at:", page.url.split("?")[0])

    # Counted from here: before the login every request of the console is refused, as it should be.
    bad = []
    page.on("response", lambda r: r.status >= 400 and bad.append(f"{r.status} {r.url.split('?')[0][len(console):][:140]}"))

    page.goto(url, wait_until="networkidle", timeout=90000)
    # A first visit offers a tour of the console; it covers the page.
    for name in ("Skip tour", "Close"):
        button = page.get_by_role("button", name=name)
        if button.count():
            button.first.click()
    page.wait_for_timeout(12000)
    text = page.inner_text("body")
    drew = "dark" if "theme-dark" in page.evaluate("document.documentElement.className") else "light"
    print(f"user {page.locator('[data-test=user-dropdown-toggle], [data-test=username]').first.inner_text().strip()}, "
          f"project {namespace}, console theme drawn: {drew}")
    sections = ("Is search up?", "Is traffic spread across the mongot pods?", "Is Envoy healthy?", "How is each mongot pod doing?",
                "Does every mongot pod hold the same data?")
    print(f"the page names the dashboard: {'MongoDB Search' in text}; sections found: {sum(s in text for s in sections)} of {len(sections)}")
    print(f"'No data': {text.count('No data')}; 'NaN': {text.count('NaN')}; 'Forbidden': {text.count('Forbidden')}; "
          f"warning signs: {page.locator('[data-testid=WarningIcon], [data-testid=AlertIcon], [data-testid=ErrorIcon]').count()}")
    page.screenshot(path=str(out / f"dashboard-console.{drew}.png"), full_page=True)
    print(f"captured dashboard-console.{drew}.png")

    print("responses of 400 or above:", sorted(set(bad)) or "none")
    browser.close()
