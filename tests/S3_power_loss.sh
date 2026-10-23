#!/bin/sh
# S3: owner power loss (true host death)
#
# Proves: after real power loss, the disk phys go down, the expander fires
#         STP I_T nexus loss, and the surviving node can take over.
#
# This scenario REQUIRES a physical power-off (or switched PDU / BMC power
# control). It cannot be safely automated from inside either node - by design,
# since a node that can power itself off cannot prove it is dead.
#
# Runbook (execute manually or via fencing agent):
#   1. Start write_client on the filesystem served by the owner.
#   2. Cut power to the owner node (PDU/BMC/power button).
#   3. On the survivor:
#        a. smp_rep_phy_sata --phy=<N> <bsg>   # expect nexus loss occurred: 1
#        b. zfs-ha-handoff release <disk>     # clear the stale affiliation
#        c. zfs-ha-handoff acquire <disk>     # verify + reset device
#        d. zpool import -f <POOL>
#        e. mount and verify: write_client.py verify --path <mount>/test.dat
#   4. Power the old owner back on; it must NOT import the pool on boot
#      (see docs/HOWTO.md "boot-time import prevention").
#
# Expected observations (from the reference shelf):
#   - nexus loss bit fires when the phys actually go down (unlike S2's driver
#     wedge where phys stay up)
#   - affiliation clear (op 6) succeeds once the link is gone
#   - all fsync'd writes written before power loss survive
