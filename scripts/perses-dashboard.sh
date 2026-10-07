#!/usr/bin/env bash
# Generates the Perses dashboard from the Grafana one, so the two stay one dashboard:
#   chart/mongodb-search-helm/files/mongodb-search.json  --percli migrate + the fixes below-->
#   chart/mongodb-search-helm/files/mongodb-search.perses.json   (the chart's PersesDashboard spec.config)
# Run from anywhere after changing mongodb-search.json:  scripts/perses-dashboard.sh
#
# The Grafana JSON is the only source; never edit the .perses.json by hand. Both files carry the tokens
# __NAMESPACE__ and __SEARCH__, which the chart replaces with its namespace and search.name when it renders.
#
# percli must be 0.54.0, the Perses version in COO 1.5.2's and 1.5.3's go.mod. It is taken from PATH when its
# unpacked plugins are at PERSES_PLUGINS; otherwise it runs from the official image with podman or docker:
#   PERCLI=percli  PERSES_PLUGINS=~/.local/share/perses/plugins  PERSES_IMAGE=docker.io/persesdev/perses:v0.54.0
# https://github.com/ephico2real2/openshift-coo-helm/blob/main/docs/percli.md
set -euo pipefail
cd "$(dirname "$0")/.."

PERCLI="${PERCLI:-percli}"
PLUGINS="${PERSES_PLUGINS:-${HOME}/.local/share/perses/plugins}"
IMAGE="${PERSES_IMAGE:-docker.io/persesdev/perses:v0.54.0}"
GRAFANA=chart/mongodb-search-helm/files/mongodb-search.json
CONFIG=chart/mongodb-search-helm/files/mongodb-search.perses.json
# A run that stops early leaves no half-written file in the chart: helm would package it.
trap 'rm -f "${CONFIG}.tmp"' EXIT

migrate() {
  if command -v "${PERCLI}" >/dev/null && [[ -d "${PLUGINS}" ]] && ! ls "${PLUGINS}"/*.tar.gz >/dev/null 2>&1; then
    "${PERCLI}" migrate -f "${GRAFANA}" --format native --plugin.path "${PLUGINS}" --use-default-datasource -o json
    return
  fi
  local engine work rc=0 name="percli-convert-$$"      # its own name: two runs at once must not remove each other's
  engine="$(command -v podman || command -v docker)" || { echo "no percli with unpacked plugins, and no podman or docker" >&2; exit 1; }
  work="$(mktemp -d)"; cp "${GRAFANA}" "${work}/dashboard.json"; chmod -R a+rX "${work}"
  # The image ships its plugins packed; the server unpacks them at start, so start it and wait.
  "${engine}" run -d --name "${name}" -v "${work}:/work" "${IMAGE}" >/dev/null
  sleep 8
  "${engine}" exec "${name}" /bin/percli migrate -f /work/dashboard.json --format native \
    --plugin.path /etc/perses/plugins --use-default-datasource -o json || rc=$?
  "${engine}" rm -f "${name}" >/dev/null; rm -rf "${work}"
  return "${rc}"
}

# percli logs "failed query migration: no plugins found matching target" once per query and still carries every
# expression over unchanged; the check below compares them with the Grafana ones.
migrate 2>/dev/null | python3 -c '
import json, re, sys
grafana = json.load(open(sys.argv[1]))
spec = json.load(sys.stdin)["spec"]
panels = spec["panels"]
def fail(msg): sys.exit("perses-dashboard: " + msg)

# percli exits 0 even when it converted nothing (plugins not unpacked): refuse placeholders.
bad = [k for k, p in panels.items() if p["spec"]["plugin"]["kind"] == "Markdown"]
if bad: fail(f"panels {bad} are placeholders: percli needs its plugins unpacked")

want = {p["title"]: [t["expr"] for t in p["targets"]] for p in grafana["panels"] if p["type"] != "row"}
got = {p["spec"]["display"]["name"]: [q["spec"]["plugin"]["spec"]["query"] for q in p["spec"]["queries"]] for p in panels.values()}
if got != want: fail(f"the converted panels or queries differ from the Grafana ones: {sorted(set(want) ^ set(got)) or [t for t in want if want[t] != got[t]]}")
rows = [p["title"] for p in grafana["panels"] if p["type"] == "row"]
if [l["spec"].get("display", {}).get("title") for l in spec["layouts"]] != rows: fail("the sections differ from the Grafana rows")

# Every query names the datasource the chart creates beside the dashboard: a namespace may hold several, and
# its default one need not be ours.
for p in panels.values():
    for q in p["spec"]["queries"]:
        q["spec"]["plugin"]["spec"]["datasource"] = {"kind": "PrometheusDatasource", "name": "__SEARCH__-thanos"}
# Colours. Perses fixes a colour per query, not per series, which is why the Grafana source has one query per
# mongot pod, coloured by an override on its refId. percli carries those over itself, with the shade and the line
# style: a time series panel needs nothing here. What follows is what percli leaves out for the other kinds, each
# read from the Grafana source (issue #35).
by_title = {p["title"]: p for p in grafana["panels"]}
def luminance(colour):
    if re.fullmatch("#[0-9a-fA-F]{3}", colour): colour = "#" + "".join(c * 2 for c in colour[1:])
    if not re.fullmatch("#[0-9a-fA-F]{6}", colour): fail(f"{colour!r} is not a hex colour: a Perses cell takes #rgb or #rrggbb only")
    channels = [int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    r, g, b = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
def contrast(one, other):
    light, dark = sorted((luminance(one), luminance(other)), reverse=True)
    return (light + 0.05) / (dark + 0.05)
for p in panels.values():
    chart = p["spec"]["plugin"]
    source = by_title[p["spec"]["display"]["name"]]
    if chart["kind"] == "PieChart":
        # A Perses pie takes its colours as a list and gives them out by position, not by query: the list follows
        # the order of the queries, and the source keeps each pie query to one series so that the two agree.
        by_ref = {o["matcher"]["options"]: prop["value"]["fixedColor"] for o in source["fieldConfig"]["overrides"]
                  if o["matcher"]["id"] == "byFrameRefID" for prop in o["properties"] if prop["id"] == "color"}
        missing = [t["refId"] for t in source["targets"] if t["refId"] not in by_ref]
        title = source["title"]
        if missing: fail(f"the pie {title!r} has no fixed colour for its queries {missing}: a Perses pie takes one per query")
        chart["spec"]["colorPalette"] = [by_ref[t["refId"]] for t in source["targets"]]
        # Labels on the slices only when the source asks for them: on a small pie they run over each other.
        chart["spec"]["showLabels"] = bool(source["options"].get("displayLabels"))
        continue
    if chart["kind"] == "Table":
        # The table is about the pods: their column first. percli puts a renamed column after the others, and hides
        # the sample time itself; the hidden column is kept, at the front.
        columns = [c for c in chart["spec"].get("columnSettings", []) if c["name"] != "timestamp"]
        columns.sort(key=lambda c: c["name"] != "pod")   # the pod first: it is what each row is about
        chart["spec"]["columnSettings"] = [{"name": "timestamp", "hide": True}] + columns
        # The name of each pod on the colour of its line. percli carries the colour of a value over and drops a
        # mapping by pattern (the pods after the third), so that one is added here. Perses keeps the text in the
        # colour of the theme, white on yellow in the dark one: the text is set to black or white, whichever is
        # further from the background (WCAG contrast ratio).
        renamed = {c.get("header", c["name"]): c for c in columns}
        for o in source["fieldConfig"]["overrides"]:
            mappings = [m for prop in o["properties"] if prop["id"] == "mappings" for m in prop["value"]]
            if not mappings:
                continue
            title, name = source["title"], o["matcher"]["options"]
            column = renamed.get(name)
            if column is None: fail(f"the table {title!r} maps values of {name!r}, which no column is called: {sorted(renamed)}")
            cells = column.setdefault("cellSettings", [])
            for m in mappings:
                if m["type"] != "regex":
                    continue                                # percli carried the mappings by value over
                cell = {"condition": {"kind": "Regex", "spec": {"expr": m["options"]["pattern"]}}}
                if "text" in m["options"]["result"]: cell["text"] = m["options"]["result"]["text"]
                if "color" in m["options"]["result"]: cell["backgroundColor"] = m["options"]["result"]["color"]
                cells.append(cell)
            for cell in cells:
                if "backgroundColor" in cell:
                    cell["textColor"] = max("#000000", "#ffffff", key=lambda text: contrast(text, cell["backgroundColor"]))
        continue
    if chart["kind"] == "StatusHistoryChart":
        # An open-ended range comes over with "to": null, which Perses refuses: an absent bound is the open one.
        for m in chart["spec"].get("mappings", []):
            m["spec"] = {k: v for k, v in m["spec"].items() if v is not None}
        continue
# The Grafana datasource input is not used once the datasource is named.
spec["variables"] = [v for v in spec.get("variables", []) if v["spec"]["name"] != "DS_PROMETHEUS"]
json.dump(spec, sys.stdout, indent=2); print()
' "${GRAFANA}" > "${CONFIG}.tmp"
mv "${CONFIG}.tmp" "${CONFIG}"
echo "wrote ${CONFIG} ($(grep -c '"kind": "Panel"' "${CONFIG}") panels)"
