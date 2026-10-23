#!/bin/sh
# S5: stuck export (I/O in flight during handoff attempt)
#
# Proves: zpool export hangs when I/O is in flight and the disk stops answering;
#         this is why fencing must precede takeover in failure scenarios.
#
# How to induce (TEST POOL ONLY):
#   1. Start a large write to the test pool (e.g. dd from /dev/zero).
#   2. From the OTHER node, hard-reset the disk phy (S2 step 3) mid-write.
#   3. On the owner, attempt: zpool export <POOL>
#      Expected: export hangs in "unmounting" or the kernel blocks in D state.
#   4. Recovery: fence the owner (power cut), then S3-style takeover on the survivor.
#
# This scenario documents WHY the project plan requires:
#   "A hung export requires fencing before takeover."
# The Pool RA's stop action has a timeout; when it expires, Pacemaker escalates
# to fencing the node - which is the correct behavior.
#
# Expected observations:
#   - export does not complete while commands are stuck
#   - dmesg shows SCSI command timeouts on the affected disk
#   - after fencing + phy hard reset, the survivor imports cleanly
#   - all fsync'd writes from before the fault survive (verify with write_client)
