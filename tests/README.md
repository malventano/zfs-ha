# ZFS-HA Cutover Test Harness
#
# Scenario matrix for validating failover behavior. Each scenario is a shell
# script that must be run against a TEST pool (never production data).
# The external client (tests/write_client.py) records synchronized writes so
# durability can be verified after each cutover.
#
# Scenarios (files are S<N>_<name>.sh):
#   S1_clean_move.sh          - planned handoff: export -> release -> import
#   S2_crash_owner.sh         - owner loses SAS path (driver wedge) -> hard reset recovery
#   S3_power_loss.sh          - owner power loss (requires physical action or PDU)
#   S4_network_partition.sh   - asymmetric network loss between nodes
#   S5_stuck_export.sh        - export hangs (I/O in flight) -> fencing required
#   S6_simultaneous_boot.sh   - both nodes boot at once
#
# Execution status, honestly:
#   S1-S3 are executable scripts that drive the handoff primitives directly.
#   S4-S6 are documented RUNBOOKS (procedures + expected observations), not
#   automated tests - they require power control (PDU/BMC) or manual action
#   that cannot be scripted safely. Only S1 prints a PASS line; for S2/S3
#   you verify with write_client.py verify afterward and judge the output.
#
# Run order: S1 first (proves the primitive), then S2/S3 (failure paths),
# then S4-S6 (cluster-level edge cases).
