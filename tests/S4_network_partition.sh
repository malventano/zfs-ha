#!/bin/sh
# S4: asymmetric network partition between nodes
#
# Proves: corosync's dual-ring + votequorum behavior when one node loses the
#         client network but keeps cluster links (and the reverse).
#
# Usage: S4_network_partition.sh <NODE_A_IP> <NODE_B_IP>
#
# Run on a THIRD machine (or via each node's BMC) to avoid cutting your own access.
set -eu

A="${1:?usage: $0 <node_a_ip> <node_b_ip>}"
B="${2:?}"

echo "=== S4: network partition ==="
echo "This test requires the ability to block traffic between the nodes."
echo "Example with nftables on an intermediate router/firewall:"
echo "  nft add table inet zfs-ha-test"
echo "  nft add chain inet zfs-ha-test drop { type filter hook forward priority 0; policy drop; }"
echo "  nft add rule inet zfs-ha-test ip saddr $A ip daddr $B drop"
echo "  nft add rule inet zfs-ha-test ip saddr $B ip daddr $A drop"
echo
echo "Expected outcomes:"
echo "  - cluster links (ring0/ring1) stay up if only the client network is cut:"
echo "    no failover, resources stay put"
echo "  - if ALL links are cut: both nodes lose quorum (two_node mode),"
echo "    no-quorum-policy=stop halts resources on both sides (split-brain safe)"
echo "  - on heal: the cluster reforms; resources restart per stickiness"
echo
echo "Verify during test:"
echo "  pcs status            # watch node states"
echo "  corosync-cfgtool -s   # watch link states"
echo "  pcs quorum status     # watch quorate flag"
