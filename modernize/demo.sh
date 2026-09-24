#!/usr/bin/env bash
# Deploy the three layers and prove a REST client reaches a gRPC-only service.
#
#   ./demo.sh deploy     namespace, ConfigMaps, all three Deployments, the Route
#   ./demo.sh test       exercise every endpoint through Envoy
#   ./demo.sh url        print the kiosk URL
#   ./demo.sh clean      delete the namespace
set -uo pipefail
cd "$(dirname "$0")"
: "${NS:=modernize-demo}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.crc/machines/crc/kubeconfig}"

deploy() {
  oc apply -f manifests/00-namespace.yaml
  # source and the binary proto descriptor become ConfigMaps
  oc create configmap inventory-src -n "$NS" \
    --from-file=server.py=app/server.py \
    --from-file=inventory_pb2.py=app/inventory_pb2.py \
    --from-file=inventory_pb2_grpc.py=app/inventory_pb2_grpc.py \
    --dry-run=client -o yaml | oc apply -f -
  oc create configmap kiosk-src -n "$NS" \
    --from-file=index.html=kiosk/index.html --dry-run=client -o yaml | oc apply -f -
  oc create configmap envoy-proto -n "$NS" \
    --from-file=inventory.pb=proto/inventory.pb --dry-run=client -o yaml | oc apply -f -
  oc apply -f manifests/20-envoy-config.yaml -f manifests/10-inventory.yaml \
           -f manifests/30-envoy.yaml -f manifests/40-kiosk.yaml
  oc rollout status deploy/inventory -n "$NS" --timeout=300s
  oc rollout status deploy/envoy     -n "$NS" --timeout=180s
  oc rollout status deploy/kiosk     -n "$NS" --timeout=180s
  url
}

url() { echo "https://$(oc get route kiosk -n "$NS" -o jsonpath='{.spec.host}')"; }

test_all() {
  H=$(oc get route kiosk -n "$NS" -o jsonpath='{.spec.host}')
  echo "== GET /v1/items =="
  curl -sk "https://$H/v1/items" | head -12
  echo; echo "== GET /v1/items/SKU-1003 (path parameter) =="
  curl -sk "https://$H/v1/items/SKU-1003"
  echo; echo "== GET /v1/items?warehouse=DERBY (query parameter) =="
  curl -sk "https://$H/v1/items?warehouse=DERBY" | head -8
  echo; echo "== POST /v1/items/SKU-1002:reserve (JSON body) =="
  curl -sk -X POST "https://$H/v1/items/SKU-1002:reserve" \
    -H 'Content-Type: application/json' -d '{"quantity":3,"orderId":"DEMO-1"}'
  echo; echo "== gRPC NOT_FOUND becomes HTTP 404 =="
  curl -sk -o /dev/null -w "HTTP %{http_code}\n" "https://$H/v1/items/NOPE"
  echo; echo "== what the backend saw - gRPC methods only =="
  oc logs -n "$NS" -l app=inventory --tail=6 | grep -E 'GetItem|ListItems|ReserveStock'
}

case "${1:-deploy}" in
  deploy) deploy ;;
  test)   test_all ;;
  url)    url ;;
  clean)  oc delete namespace "$NS" ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
