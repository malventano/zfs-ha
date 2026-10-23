# ZFS-HA Cutover Test Harness
#
# Scenario matrix for validating failover behavior. Each scenario is a shell
# script that must be run against a TEST pool (never production data).
# The external client (tests/write_client.py) records synchronized writes so
# durability can be verified after each cutover.
#
# Scenarios:
#   S1  clean_move.sh      - planned handoff: export -> release -> import
#   S2  crash_owner.sh     - owner loses SAS path (driver wedge) -> hard reset recovery
#   S3  power_loss.sh      - owner power loss (requires physical action or PDU)
#   S4  network_partition.sh - asymmetric network loss between nodes
#   S5  stuck_export.sh    - export hangs (I/O in flight) -> fencing required
#   S6  simultaneous_boot.sh - both nodes boot at once
#
# Each script prints PASS/FAIL and the client's durability verdict.

See individual scenario files. Run order: S1 first (proves the primitive),
then S2/S3 (failure paths), then S4-S6 (cluster-level edge cases).
