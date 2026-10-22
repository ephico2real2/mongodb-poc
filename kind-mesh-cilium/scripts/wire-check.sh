#!/usr/bin/env bash
# Step 2 of story #132: proves on the wire that the search hop, now cleartext gRPC, is encrypted between nodes. While
# searches run through every cluster's member, it captures 15 s on the kind bridge (every node of the three clusters
# is on it) and counts what crossed it. Passes when nothing of port 27028 or 27017 and no VXLAN crossed in the clear,
# WireGuard (UDP 51871) did, and the search text is in no packet. Needs tcpdump in the Colima VM:
#   colima ssh --profile mongodb-mesh -- sudo apt-get install -y tcpdump
#
#   kind-mesh-cilium/scripts/wire-check.sh     # writes kind-mesh-cilium/output/wire-check.txt
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/../kind-mesh/scripts/lib.sh"
lab_env
br="br-$(docker network inspect kind --format '{{.Id}}' | cut -c1-12)"
for c in mesh0 mesh1 mesh2; do "$here/drills.sh" load-only "$c" 25 >/dev/null 2>&1 & done
sleep 3
{
  echo "== wire check $(date -u +%Y-%m-%dT%H:%M:%SZ): 15 s on the kind bridge $br, searches running through mesh0, mesh1 and mesh2"
  colima ssh --profile "$COLIMA_PROFILE" -- sh -c "
    sudo timeout 15 tcpdump -i $br -nn -s 0 -w /tmp/wire-check.pcap 2>/dev/null || true
    count() { sudo tcpdump -nn -r /tmp/wire-check.pcap \"\$@\" 2>/dev/null | wc -l; }
    echo \"packets on the bridge: \$(count)\"
    echo \"UDP 51871, WireGuard: \$(count udp port 51871)\"
    echo \"TCP 27028, gRPC search in the clear: \$(count tcp port 27028)\"
    echo \"TCP 27017, mongod in the clear: \$(count tcp port 27017)\"
    echo \"UDP 8472, VXLAN in the clear: \$(count udp port 8472)\"
    echo \"packets whose bytes contain the search text 'space': \$(sudo tcpdump -nn -A -r /tmp/wire-check.pcap 2>/dev/null | grep -c space || true)\"
    sudo rm -f /tmp/wire-check.pcap"
} | tee "$here/output/wire-check.txt"
wait
