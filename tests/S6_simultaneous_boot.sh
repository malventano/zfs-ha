#!/bin/sh
# S6: simultaneous boot of both nodes
#
# Proves: neither node auto-imports the HA pool at boot; the cluster decides
#         ownership after quorum.
#
# Prerequisites (see docs/HOWTO.md "boot-time import prevention"):
#   - zfs-import-cache.service disabled or cachefile excludes the HA pool
#   - zfs-import-scan.service disabled
#   - no zpool.cachefile entry pointing at the HA pool
#   - systemd unit ordering: pacemaker starts before any local import attempt
#
# Runbook:
#   1. Power both nodes off.
#   2. Power both on simultaneously (or as close as possible).
#   3. After boot, verify on each node:
#        zpool list            # HA pool must NOT be imported on either
#        pcs status            # cluster forms; pool resource starts on exactly one
#   4. Verify the pool resource started on the node with higher stickiness/priority.
#
# Expected: exactly one node imports the pool, via Pacemaker, after quorum.
# A node that finds the pool already imported by the other must NOT force-import
# (the Pool RA's acquire step refuses when affiliation is valid).
