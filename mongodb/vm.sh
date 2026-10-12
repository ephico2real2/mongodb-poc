#!/usr/bin/env bash
# The machine the replica set runs in: a colima profile of its own, with nothing else in it.
#
#   mongodb/vm.sh up        create or start it, and print its address
#   mongodb/vm.sh address   print its address (what ADVERTISED_HOST in .env must be)
#   mongodb/vm.sh status
#   mongodb/vm.sh down      stop it; the replica set's data stays in its volumes
#   mongodb/vm.sh delete    delete the machine and everything in it, the replica set's volumes too; colima asks first
#
# The docker context it makes is colima-<profile>: the scripts of this repository default to it.
# MONGODB_VM_PROFILE names another profile; MONGODB_VM_CPUS, MONGODB_VM_MEMORY (GiB) and MONGODB_VM_DISK (GiB)
# size it when it is first made. Three mongod at a 0.25 GiB cache each used 0.9 GiB on the lab.
set -euo pipefail
PROFILE="${MONGODB_VM_PROFILE:-mongodb-poc}"
die() { printf '%s: %s\n' "$(basename "$0")" "$*" >&2; exit 1; }
command -v colima >/dev/null 2>&1 || die "colima is not on the PATH"
# A row of `colima list` ends with the address, and with the runtime when the machine has no address: only a last
# field that is an address is printed.
address() {
  colima list 2>/dev/null |
    awk -v p="${PROFILE}" '$1 == p && $2 == "Running" && $NF ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $NF }'
}
case "${1:-}" in
  up)
    # --network-address: an address on the Mac's shared network, which the OpenShift Local node can reach.
    # colima makes its docker context the current one; the one that was current is put back.
    before="$(docker context show 2>/dev/null || true)"
    made="$(colima list 2>/dev/null | awk -v p="${PROFILE}" '$1 == p { print $2 }')"
    if [[ -n "${made}" ]]; then
      # colima applies a size it is given to a machine that exists: none is given, and it starts as it was made.
      colima start --profile "${PROFILE}"
    else
      colima start --profile "${PROFILE}" --cpu "${MONGODB_VM_CPUS:-2}" --memory "${MONGODB_VM_MEMORY:-3}" \
        --disk "${MONGODB_VM_DISK:-20}" --vm-type vz --mount-type virtiofs --network-address --runtime docker
    fi
    [[ -z "${before}" || "${before}" == "colima-${PROFILE}" ]] || docker context use "${before}" >/dev/null \
      || printf '%s: the docker context %s could not be made current again\n' "$(basename "$0")" "${before}" >&2
    a="$(address)"; [[ -n "${a}" ]] || die "profile ${PROFILE} is running without an address"
    printf 'profile %s, docker context colima-%s, address %s\n' "${PROFILE}" "${PROFILE}" "${a}"
    printf 'ADVERTISED_HOST in mongodb/.env must be %s\n' "${a}" ;;
  address)
    a="$(address)"; [[ -n "${a}" ]] || die "profile ${PROFILE} is not running, or has no address"
    printf '%s\n' "${a}" ;;
  status)  colima list 2>/dev/null | awk -v p="${PROFILE}" 'NR == 1 || $1 == p' ;;
  down)    colima stop --profile "${PROFILE}" ;;
  # --data: without it colima keeps the machine's data disk, and a machine made again finds the old volumes on it.
  delete)  colima delete --data --profile "${PROFILE}" ;;
  *)       sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 1 ;;
esac
