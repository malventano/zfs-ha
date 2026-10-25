#!/bin/sh
# S1: clean planned handoff (the happy path)
#
# Proves: export -> release -> import preserves all acknowledged writes.
#
# Prerequisites:
#   - test pool <POOL> imported on the local node, mounted at <MOUNT>
#   - write_client.py running against <MOUNT>/test.dat (or verify after)
#   - zfs-ha tools installed on both nodes (make install)
#   - pool.conf present on both nodes with the same pool + disk list
#
# Usage: S1_clean_move.sh <POOL> <MOUNT> <REMOTE_NODE_SSH>
#   e.g. S1_clean_move.sh testpool /testpool nodeB
set -eu

POOL="${1:?usage: $0 <POOL> <MOUNT> <REMOTE_SSH>}"
MOUNT="${2:?}"
REMOTE="${3:?}"

echo "=== S1: clean planned handoff ==="

# 1. export the pool on the local node (quiesces I/O, flushes caches)
echo "step 1: export pool on local node"
zpool export "$POOL"

# 2. release transport access on the local node, per pool.conf's strategy.
#    (stp: SMP affiliation clear; sas: PR release; null: quiesce only)
echo "step 2: release transport access (local node, disks now idle)"
for d in $(zfs-ha-config get disks | tr ',' ' '); do
    zfs-ha-handoff release "$d" || true
done

# 3. acquire + import on the remote node. In a real cluster the RA does
#    this (rescan -> acquire with evidence -> import); here we drive the
#    same steps by hand so the primitive is tested independently of
#    pacemaker.
echo "step 3: rescan + acquire + import on remote node (RA order: rescan, then acquire)"
ssh "$REMOTE" "for d in \$(zfs-ha-config get disks | tr ',' ' '); do
                   zfs-ha-handoff rescan \"\$d\" || exit 1
                   zfs-ha-handoff acquire \"\$d\" || exit 1
               done
               zpool import -f $POOL"

echo "step 4: verify writes on remote"
# NOTE: write_client.py must exist at the same relative path on the remote
# node (or adjust the path below). It is not installed by `make install`.
ssh "$REMOTE" "python3 $(dirname "$0")/write_client.py verify --path $MOUNT/test.dat"

echo "=== S1 PASS if verify says PASS ==="
