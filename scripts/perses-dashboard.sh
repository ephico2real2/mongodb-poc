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

migrate() {
  if command -v "${PERCLI}" >/dev/null && [[ -d "${PLUGINS}" ]] && ! ls "${PLUGINS}"/*.tar.gz >/dev/null 2>&1; then
    "${PERCLI}" migrate -f "${GRAFANA}" --format native --plugin.path "${PLUGINS}" --use-default-datasource -o json
    return
  fi
  local engine work
  engine="$(command -v podman || command -v docker)" || { echo "no percli with unpacked plugins, and no podman or docker" >&2; exit 1; }
  work="$(mktemp -d)"; cp "${GRAFANA}" "${work}/dashboard.json"; chmod -R a+rX "${work}"
  "${engine}" rm -f percli-convert >/dev/null 2>&1 || true
  # The image ships its plugins packed; the server unpacks them at start, so start it and wait.
  "${engine}" run -d --name percli-convert -v "${work}:/work" "${IMAGE}" >/dev/null
  sleep 8
  "${engine}" exec percli-convert /bin/percli migrate -f /work/dashboard.json --format native \
    --plugin.path /etc/perses/plugins --use-default-datasource -o json
  "${engine}" rm -f percli-convert >/dev/null
  rm -rf "${work}"
}

# percli logs "failed query migration: no plugins found matching target" once per query and still carries every
# expression over unchanged; the check below compares them with the Grafana ones.
migrate 2>/dev/null | python3 -c '
import json, sys
grafana = json.load(open(sys.argv[1]))
spec = json.load(sys.stdin)["spec"]
panels = spec["panels"]
def fail(msg): sys.exit("perses-dashboard: " + msg)

# percli exits 0 even when it converted nothing (plugins not unpacked): refuse placeholders.
bad = [k for k, p in panels.items() if p["spec"]["plugin"]["kind"] == "Markdown"]
if bad: fail(f"panels {bad} are placeholders: percli needs its plugins unpacked")

want = {p["title"]: p["targets"][0]["expr"] for p in grafana["panels"] if p["type"] != "row"}
got = {p["spec"]["display"]["name"]: p["spec"]["queries"][0]["spec"]["plugin"]["spec"]["query"] for p in panels.values()}
if got != want: fail(f"the converted panels or queries differ from the Grafana ones: {sorted(set(want) ^ set(got)) or [t for t in want if want[t] != got[t]]}")
rows = [p["title"] for p in grafana["panels"] if p["type"] == "row"]
if [l["spec"].get("display", {}).get("title") for l in spec["layouts"]] != rows: fail("the sections differ from the Grafana rows")

# Every query names the datasource the chart creates beside the dashboard: a namespace may hold several, and
# its default one need not be ours.
for p in panels.values():
    for q in p["spec"]["queries"]:
        q["spec"]["plugin"]["spec"]["datasource"] = {"kind": "PrometheusDatasource", "name": "__SEARCH__-thanos"}
# The Grafana datasource input is not used once the datasource is named.
spec["variables"] = [v for v in spec.get("variables", []) if v["spec"]["name"] != "DS_PROMETHEUS"]
json.dump(spec, sys.stdout, indent=2); print()
' "${GRAFANA}" > "${CONFIG}.tmp"
mv "${CONFIG}.tmp" "${CONFIG}"
echo "wrote ${CONFIG} ($(grep -c '"kind": "Panel"' "${CONFIG}") panels)"
