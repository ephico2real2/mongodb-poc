#!/usr/bin/env bash
# Checks and unit-tests the chart's alert rules with promtool, run from a container image so nothing has to be
# installed. Run from anywhere: test/alerts.sh. Needs helm, and podman or docker (CONTAINER_ENGINE picks one).
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
# By digest (the index: each platform takes its own image): a release of Prometheus must not be able to fail, or
# pass, a pull request that did not touch the rules. v3.15.0, 2026-10-07.
IMAGE="quay.io/prometheus/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The rules as the chart renders them. A PrometheusRule's spec is a plain Prometheus rule file: everything under
# "spec:" of that one document.
helm template mongot chart/mongodb-search-helm -n dvh-gp6-rnd -f chart/mongodb-search-helm/examples/values-dvh-gp6-rnd.yaml \
    -s templates/30-monitoring.yaml \
  | awk '/^---/ {doc = 0; spec = 0} /^kind: PrometheusRule$/ {doc = 1} doc && /^spec:$/ {spec = 1; next} spec {sub(/^  /, ""); print}' \
  > "${work}/rules.yaml"
[[ -s "${work}/rules.yaml" ]] || { echo "the chart rendered no PrometheusRule" >&2; exit 1; }
# The same rules with three values changed: the levels of MongotDataPathFillingUp are values of the chart.
helm template mongot chart/mongodb-search-helm -n dvh-gp6-rnd -f chart/mongodb-search-helm/examples/values-dvh-gp6-rnd.yaml \
    --set monitoring.alerts.dataPathUsed.info=null --set monitoring.alerts.dataPathUsed.warning=60 --set monitoring.alerts.dataPathUsed.critical=75 \
    -s templates/30-monitoring.yaml \
  | awk '/^---/ {doc = 0; spec = 0} /^kind: PrometheusRule$/ {doc = 1} doc && /^spec:$/ {spec = 1; next} spec {sub(/^  /, ""); print}' \
  > "${work}/rules-other-levels.yaml"
[[ -s "${work}/rules-other-levels.yaml" ]] || { echo "the chart rendered no PrometheusRule with other levels" >&2; exit 1; }
cp test/alerts.test.yaml test/alerts.other-levels.test.yaml "${work}/"
chmod -R a+rX "${work}"

"${ENGINE}" run --rm -v "${work}:/w:ro" --workdir /w --entrypoint promtool "${IMAGE}" check rules rules.yaml
"${ENGINE}" run --rm -v "${work}:/w:ro" --workdir /w --entrypoint promtool "${IMAGE}" test rules alerts.test.yaml
"${ENGINE}" run --rm -v "${work}:/w:ro" --workdir /w --entrypoint promtool "${IMAGE}" test rules alerts.other-levels.test.yaml
