#!/usr/bin/env bash
# Starts the Colima VM the three kind clusters run in (profile COLIMA_PROFILE in versions.env), creating it the first
# time, and raises its inotify limits. The active docker context is left as it is (--activate=false).
#
#   kind-mesh/scripts/colima-up.sh      # idempotent: a running VM is kept
#   kind-mesh/scripts/colima-down.sh    # stops it
#
# vz and --network-address as cilium-implementation-poc's poc1 profile: the address is what a Mac route to the
# clusters' LoadBalancer block goes through (printed by up.sh). CPU and memory can be changed later with
# `colima start --cpu --memory`; the VM type and a smaller disk cannot.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

status=$(colima list --json 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    if line.strip():
        d = json.loads(line)
        if d.get("name") == sys.argv[1]:
            print(d.get("status", "")); break' "$COLIMA_PROFILE")

case "$status" in
  Running) echo "Colima profile $COLIMA_PROFILE is running" ;;
  "")
    say "create Colima profile $COLIMA_PROFILE: ${COLIMA_CPUS} CPUs, ${COLIMA_MEMORY_GIB} GiB, ${COLIMA_DISK_GIB} GiB disk"
    colima start --profile "$COLIMA_PROFILE" --vm-type vz --runtime docker --network-address --activate=false \
      --cpu "$COLIMA_CPUS" --memory "$COLIMA_MEMORY_GIB" --disk "$COLIMA_DISK_GIB" ;;
  *)
    say "start Colima profile $COLIMA_PROFILE (was $status)"
    colima start --profile "$COLIMA_PROFILE" --activate=false ;;
esac

# Ubuntu's fs.inotify.max_user_instances is 128; a second kind cluster in one VM died on it in cilium-implementation-poc
# ("inotify_init: too many open files"), and one cluster with Cilium held 219 instances there. 512 is kind's own
# known-issues value; six nodes here.
say "inotify limits in the VM"
have=$(colima ssh --profile "$COLIMA_PROFILE" -- sysctl -n fs.inotify.max_user_instances)
if [ "$have" -lt 512 ]; then
  colima ssh --profile "$COLIMA_PROFILE" -- sudo sh -c "printf 'fs.inotify.max_user_instances = 512\nfs.inotify.max_user_watches = 1048576\n' > /etc/sysctl.d/99-kind-inotify.conf && sysctl -q -p /etc/sysctl.d/99-kind-inotify.conf"
fi
colima ssh --profile "$COLIMA_PROFILE" -- sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
colima list --profile "$COLIMA_PROFILE"
