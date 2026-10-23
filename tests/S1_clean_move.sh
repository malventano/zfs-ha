#!/bin/sh
# S1: clean planned handoff (the happy path)
#
# Proves: export -> affiliation release -> import preserves all acknowledged writes.
#
# Prerequisites:
#   - test pool <POOL> imported on node A, mounted at <MOUNT>
#   - write_client running against <MOUNT>/test.dat
#   - disk_handoff.sh installed on both nodes
#
# Usage: S1_clean_move.sh <POOL> <MOUNT> <REMOTE_NODE_SSH>
set -eu

POOL="${1:?usage: $0 <POOL> <MOUNT> <REMOTE_SSH>}"
MOUNT="${2:?}"
REMOTE="${3:?}"

echo "=== S1: clean planned handoff ==="

# 1. stop the client (or let it run and accept the gap - for S1 we stop cleanly)
echo "step 1: export pool on local node"
zpool export "$POOL"

echo "step 2: release affiliations (local node, disks now idle)"
for d in $(zpool import 2>/dev/null | grep -A5 "$POOL" | grep -o '/dev/sd[a-z]*' | sort -u); do
    disk_handoff.sh release "$d" || true
done

echo "step 3: import on remote node"
ssh "$REMOTE" "disk_handoff.sh acquire is done by the RA; zpool import -f $POOL"

echo "step 4: verify writes on remote"
ssh "$REMOTE" "write_client.py verify --path $MOUNT/test.dat"

echo "=== S1 PASS if verify says PASS ==="
