#!/usr/bin/env bash
# Generates the Perses dashboard from the Grafana one, so the two stay one dashboard:
#   chart/mongodb-search-helm/files/mongodb-search.json  --perses-dashboard-->
#   chart/mongodb-search-helm/files/mongodb-search.perses.json   (the chart's PersesDashboard spec.config)
# Run from anywhere after changing mongodb-search.json:  scripts/perses-dashboard.sh
#
# The Grafana JSON is the only source; never edit the .perses.json by hand. Both files carry the tokens
# __NAMESPACE__ and __SEARCH__, which the chart replaces with its namespace and search.name when it renders.
#
# The conversion is diagram-kit's perses-dashboard (https://github.com/ephico2real2/diagram-kit, MPL-2.0; v0.2.0 or
# later): it runs percli migrate from the Perses image with podman or docker, refuses a panel that became a
# placeholder or a query that differs from the Grafana one, and adds what percli leaves out. Install it once:
#   python3 -m venv .venv && .venv/bin/pip install "diagram-kit @ git+https://github.com/ephico2real2/diagram-kit@v0.2.0"
# It is taken from PERSES_DASHBOARD, from the PATH, or from .venv/bin. The image must be Perses 0.54.0, the version
# in COO 1.5.2's and 1.5.3's go.mod:
#   PERSES_DASHBOARD=perses-dashboard  PERSES_IMAGE=docker.io/persesdev/perses:v0.54.0
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${PERSES_IMAGE:-docker.io/persesdev/perses:v0.54.0}"
GRAFANA=chart/mongodb-search-helm/files/mongodb-search.json
CONFIG=chart/mongodb-search-helm/files/mongodb-search.perses.json

CONVERT="${PERSES_DASHBOARD:-$(command -v perses-dashboard || true)}"
[[ -n "${CONVERT}" ]] || CONVERT=.venv/bin/perses-dashboard
[[ -x "${CONVERT}" ]] || { echo "perses-dashboard not found: install diagram-kit (see the top of this script) or set PERSES_DASHBOARD" >&2; exit 1; }

# Every query names the datasource the chart creates beside the dashboard, <search.name>-thanos.
exec "${CONVERT}" "${GRAFANA}" "${CONFIG}" --datasource __SEARCH__-thanos --image "${IMAGE}"
