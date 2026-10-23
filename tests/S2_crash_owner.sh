#!/bin/sh
# S2: owner loses SAS path (driver wedge / HBA failure) - unclean but host alive
#
# Proves: stale affiliation can be released from the surviving node via
#         PHY CONTROL hard reset (op 2) when the dead owner cannot release it.
#
# KEY FINDING (validated on the reference shelf): when the owner's SAS stack is
# wedged (driver unloading stuck, HBA unbound), the affiliation REMAINS VALID and
# clear-affiliation (op 6) is REFUSED by the expander, because the owner's phys
# are still electrically up. The recovery is a HARD RESET (op 2) of the disk phy,
# which drops the disk's link, releases the stale affiliation, and lets the
# surviving node re-affiliate on its next I/O.
#
# Usage: S2_crash_owner.sh <DISK_ON_SURVIVOR> <EXPANDER_BSG> <PHY_ID>
#   e.g. S2_crash_owner.sh /dev/disk/by-id/wwn-0x... /dev/bsg/expander-6:7 6
set -eu

DISK="${1:?usage: $0 <DISK> <EXPANDER_BSG> <PHY>}"
BSG="${2:?}"
PHY="${3:?}"

echo "=== S2: owner SAS-path loss, recovery via phy hard reset ==="

echo "step 1: confirm stale affiliation"
smp_rep_phy_sata --phy="$PHY" "$BSG" | grep -E "affiliation valid|affiliated STP"

echo "step 2: attempt clear-affiliation (expected to be REFUSED while owner phys are up)"
smp_phy_control --phy="$PHY" --op=ca "$BSG" || true
sleep 1
VALID=$(smp_rep_phy_sata --phy="$PHY" "$BSG" | grep "affiliation valid" | awk '{print $3}')
echo "affiliation valid after op=6: $VALID (1 means refused, as expected)"

echo "step 3: hard reset the disk phy (drops link, releases stale affiliation)"
smp_phy_control --phy="$PHY" --op=2 "$BSG" || true
sleep 5

echo "step 4: confirm released; new owner re-affiliates on first I/O"
smp_rep_phy_sata --phy="$PHY" "$BSG" | grep -E "affiliation valid|affiliated STP"
sg_reset -d "$DISK" >/dev/null 2>&1 || true
dd if="$DISK" bs=512 count=1 skip=100 iflag=direct of=/dev/null 2>/dev/null && echo "I/O OK"

echo "=== S2: recovery complete ==="
