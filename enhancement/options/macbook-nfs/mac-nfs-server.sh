#!/usr/bin/env bash
# OPTION B (NOT USED, NOT RUN) - serve an NFS share from this Mac to the CRC cluster.
# The lab uses Option A, an NFS server inside the cluster - see ../../README.md, Part B,
# "Where the NFS server runs". Kept as the documented alternative; it was written and
# syntax-checked, never executed. Run it yourself, it needs sudo:  sudo ./mac-nfs-server.sh
#
# What it does, and why:
#   1. creates the share directory, owned by you;
#   2. exports it in /etc/exports - to localhost only: the CRC VM reaches this Mac through
#      gvproxy (192.168.127.254 inside the VM), which opens its connections from 127.0.0.1;
#      -mapall maps every client user to you, so pods (any UID) can write; -alldirs lets the
#      CSI driver mount the sub-directories it creates, one per volume;
#   3. sets nfs.server.mount.require_resv_port = 0 in /etc/nfs.conf - it defaults to 1, and
#      connections through gvproxy do not come from reserved (< 1024) ports;
#   4. restarts nfsd and shows the export.
# macOS's nfsd serves NFS version 3 (man nfsd) - the StorageClass must use nfsvers=3.
#
# Existing /etc/exports and /etc/nfs.conf are copied to *.before-crc-nfs first.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }
OWNER=${SUDO_USER:?run with sudo from your own account}
UID_=$(id -u "$OWNER"); GID_=$(id -g "$OWNER")
SHARE=/Users/Shared/crc-nfs
EXPORT_PATH=/System/Volumes/Data$SHARE      # the real path behind the /Users firmlink

mkdir -p "$SHARE" && chown "$UID_:$GID_" "$SHARE"
for f in /etc/exports /etc/nfs.conf; do [ -f "$f" ] && cp -p "$f" "$f.before-crc-nfs"; done

LINE="$EXPORT_PATH -alldirs -mapall=$UID_:$GID_ localhost"
touch /etc/exports
grep -qxF "$LINE" /etc/exports || echo "$LINE" >> /etc/exports
touch /etc/nfs.conf
grep -q '^nfs.server.mount.require_resv_port' /etc/nfs.conf \
  || echo 'nfs.server.mount.require_resv_port = 0' >> /etc/nfs.conf

nfsd checkexports
nfsd enable
nfsd restart
sleep 2
nfsd status
showmount -e localhost
