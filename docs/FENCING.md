# Fencing Backends

Fencing is the mechanism by which the cluster *proves* a failed node is
powerless before another node takes over its storage. Without verified
fencing, automatic takeover must not proceed — a node that is merely
unresponsive (not off) can wake up and corrupt the pool.

## Requirement

Every fencing backend must implement **idempotent "ensure off and verify
off"**:

- *ensure off*: if the node is on, turn it off; if already off, do nothing.
- *verify off*: confirm via an independent channel (BMC power status, PDU
  metering, IPMI chassis status) that the node is actually off.

An accepted API request is **not** proof of fencing. A fenced node that is
still drawing power is not fenced.

## Options

### 1. BMC / IPMI / Redfish (recommended default)

Every node needs a BMC on an independent network. Pacemaker ships
`fence_ipmilan` which does ensure-off + verify-off.

```sh
pcs stonith create fence_a fence_ipmilan ip=<bmc_a> username=<u> password=<p> \
    lanplus=1 pcmk_host_list=nodeA op monitor interval=60s
```

Pros: cheap, ubiquitous, independent of the host OS.
Cons: BMC shares the node's power supply (a node with dead PSUs may not
respond to BMC commands — pair with a PDU for critical deployments).

### 2. Switched PDU

Network-controlled power strips. `fence_pdu` / vendor agents (APC, Eaton).
Covers the BMC's blind spot: cutting power at the wall works even when the
BMC is dead. **Account for all power feeds** — dual-PSU nodes need both
outlets switched.

### 3. PiKVM / motherboard-header power control

A PiKVM wired to the node's front-panel header can press the power button
and read power state. Independent of the host OS and of the BMC. Use a
custom fence agent wrapping `pikvm` API calls with verification via the
`/api/hardware/info` power-state readback.

### 4. SBD (shared-block watchdog fencing)

Requires a small block device visible to **both** nodes simultaneously.
On a SATA-behind-expander shelf this is **not possible** — the affiliation
model gives single-owner access. Options:

- A dedicated **SAS** disk in the shelf (SAS supports multiple initiator
  ports natively). *Optional nice-to-have; the project treats this as an
  add-on, not a requirement.*
- A separate tiny shared-storage device (iSCSI LUN from a third box, NVMe-oF,
  or a partition on a different shelf).

SBD watches a shared "message block": a node that cannot renew its watchdog
gets self-fenced by its hardware watchdog. Combined with Pacemaker's
`SBD_SYNC_RESOURCE_STARTUP` it gives the fastest, most deterministic fencing.

### 5. SAS expander isolation (experimental, NOT recommended)

Theoretically the shelf could disable the failed node's PHYs, isolating it
from the disks. Validated findings on the reference shelf:

- The IOM12 exposes no documented third-party API for affiliation or zoning
  control; SES vendor pages are opaque.
- Even if PHY disabling worked, it **leaves the old OS running** — it can
  still hold the VIP and serve stale data. Storage isolation is not fencing.

Treat any expander-isolation scheme as an experiment, never as the primary
fencing method.

## 6. fence_zfs_ha_stp - the shipped storage-isolation agent (experimental)

This repo ships `fence_zfs_ha_stp` (installed by `make install`), a stonith
agent that fences the peer **at the shelf level**: it hard-resets the phys
currently affiliated to the peer's HBA SAS address and clears those
affiliations, so the peer loses all access to the shared pool disks.

Understand what it is and is not:

- It is a **storage fence, not a power fence**. The peer OS keeps running -
  it can still hold the VIP and serve cached data. Pair it with the VIP
  teardown ordering and MMP (`multihost=on`), and prefer a real power fence
  (BMC/PDU/PiKVM) when the hardware has one.
- It only applies to the `stp` path (SATA disks with STP affiliations). The
  `sas` path fences with SCSI persistent reservations instead (`zfs-ha-pr`).
- **Exercised live in the V15 failover matrix**: the fence cleared all of
  the owner's disk affiliations and the fenced host's pacemaker
  self-terminated as designed. The mandatory test below still applies to
  *your* hardware - a fence agent that has never been tested on your shelf
  is a liability, not a safety net.

Setup:

```sh
# find the peer's HBA SAS address (run on either node):
sudo sas_topology        # or: cat /sys/class/sas_host/*/device/*/*/sas_address

pcs stonith create fence_stp fence_zfs_ha_stp \
    peer_sas=<peer-hba-sas-address> \
    pcmk_host_list=<peer-node-name> op monitor interval=60s
pcs property set stonith-enabled=true
```

Test it before trusting it (mandatory, per the rule below):

```sh
pcs stonith fence <peer-node-name>   # peer must lose disk access; verify
                                     # with smp_rep_phy_sata from either node
```

## Two-node specifics

- `two_node: 1` in corosync quorum config (set automatically by
  `pcs cluster setup` with two nodes).
- `no-quorum-policy=stop` — when quorum is lost, stop resources rather than
  continue (prevents split-brain).
- Fencing delays: in a two-node cluster, the surviving node fences the other
  one. Configure `pcmk_delay_max` asymmetrically (e.g. 0s on node A, 15s on
  node B) so that a transient simultaneous failure has a deterministic
  survivor.

## Testing your fencing (mandatory)

```sh
# 1. verify the agent can power the node off and confirm off:
pcs stonith fence nodeB          # node B must actually lose power
# 2. verify the cluster recovers:
pcs status                       # node B eventually rejoins; resources move
# 3. verify the fence fires during a real failure:
#    (crash node B's kernel or pull its power; watch pcs status)
```

A fence agent that has never been tested under a real failure is a liability,
not a safety net.
