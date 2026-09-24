"""
A deliberately old-fashioned service: it speaks gRPC and nothing else.

There is no HTTP server here, no JSON, no CORS, no REST router. A browser
cannot talk to it. curl cannot talk to it. That is the point - everything
modern about this service is added by the Envoy in front of it, without a
line of code changing here.

The generated stubs (inventory_pb2*.py) are committed beside this file and are
produced from proto/inventory.proto - regenerate them with the command in the
README whenever the proto changes.
"""
import os, sys, time, threading, logging
from concurrent import futures

import grpc
from grpc_reflection.v1alpha import reflection
import inventory_pb2 as pb
import inventory_pb2_grpc as rpc

logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(message)s")
log = logging.getLogger("inventory")

POD = os.environ.get("POD_NAME", "inventory")

# A small in-memory catalogue. Reserved stock is mutated by ReserveStock so the
# kiosk can show state actually changing on the server.
_LOCK = threading.Lock()
ITEMS = {
    "SKU-1001": dict(sku="SKU-1001", name="Hydraulic pump, 12L",   on_hand=42,  reserved=0, warehouse="LEEDS"),
    "SKU-1002": dict(sku="SKU-1002", name="Bearing assembly 60mm", on_hand=118, reserved=0, warehouse="LEEDS"),
    "SKU-1003": dict(sku="SKU-1003", name="Control board rev C",   on_hand=7,   reserved=0, warehouse="DERBY"),
    "SKU-1004": dict(sku="SKU-1004", name="Seal kit, nitrile",     on_hand=260, reserved=0, warehouse="DERBY"),
    "SKU-1005": dict(sku="SKU-1005", name="Drive belt 1400mm",     on_hand=0,   reserved=0, warehouse="LEEDS"),
}


class Inventory(rpc.InventoryServicer):
    def GetItem(self, request, context):
        log.info("GetItem sku=%s", request.sku)
        with _LOCK:
            it = ITEMS.get(request.sku)
        if not it:
            context.abort(grpc.StatusCode.NOT_FOUND, "no such sku: %s" % request.sku)
        return pb.Item(**it)

    def ListItems(self, request, context):
        log.info("ListItems warehouse=%r page_size=%d", request.warehouse, request.page_size)
        with _LOCK:
            rows = [v for v in ITEMS.values()
                    if not request.warehouse or v["warehouse"] == request.warehouse]
        total = len(rows)
        if request.page_size:
            rows = rows[: request.page_size]
        return pb.ListItemsResponse(items=[pb.Item(**r) for r in rows], total=total)

    def ReserveStock(self, request, context):
        log.info("ReserveStock sku=%s qty=%d order=%s", request.sku, request.quantity, request.order_id)
        with _LOCK:
            it = ITEMS.get(request.sku)
            if not it:
                context.abort(grpc.StatusCode.NOT_FOUND, "no such sku: %s" % request.sku)
            free = it["on_hand"] - it["reserved"]
            if request.quantity <= 0:
                return pb.ReserveStockResponse(sku=request.sku, reserved=it["reserved"],
                                               ok=False, message="quantity must be positive")
            if request.quantity > free:
                return pb.ReserveStockResponse(sku=request.sku, reserved=it["reserved"], ok=False,
                                               message="only %d free of %d on hand" % (free, it["on_hand"]))
            it["reserved"] += request.quantity
            return pb.ReserveStockResponse(sku=request.sku, reserved=it["reserved"], ok=True,
                                           message="reserved %d for %s" % (request.quantity, request.order_id or "-"))


def serve():
    port = os.environ.get("PORT", "50051")
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    rpc.add_InventoryServicer_to_server(Inventory(), server)
    # Reflection lets grpcurl explore the service without a local .proto copy.
    reflection.enable_server_reflection(
        (pb.DESCRIPTOR.services_by_name["Inventory"].full_name, reflection.SERVICE_NAME), server)
    server.add_insecure_port("0.0.0.0:%s" % port)
    server.start()
    log.info("gRPC only, listening on :%s as %s - no HTTP, no JSON, no CORS", port, POD)
    server.wait_for_termination()


if __name__ == "__main__":
    serve()
