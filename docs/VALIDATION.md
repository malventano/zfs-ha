# Validation Record

Hardware used for validation (reference implementation):

| Item | Detail |
|---|---|
| Hosts | 2x commodity desktop, Rocky Linux 10.2, kernel 6.12 |
| HBAs | 2x LSI SAS9300-8e (SAS3008), mpt3sas 54.100.00.00 |
| Shelf | NetApp DS460C, 60-bay, 2x IOM12 modules |
| Disks | 13x SATA (9x 3TB HDD, 2x 960GB SSD, 1TB, 480GB SSD) |
| ZFS | OpenZFS 2.2.11 (kmod) |
| Cluster | pacemaker 3.0.1, corosync 3.1.10, pcs 0.12.2 |

All tests were read-only or confined to a single sacrificial disk (bay 6,
ST3000DM001) with marker writes to sector 100 only. No filesystems or pools
were created on production data.

## V1. Shelf topology discovery

- `utils/sas_topology.sh` enumerates: 2 hosts, 1 shared IOM (both hosts
  cable into the same IOM12A; second IOM present but unconnected), 5
  downstream expanders, 13 disks with bay/WWN/phy/affiliation mapping.
- SES pages (`sg_ses`) confirm enclosure identity, slot states, PSU status.

## V2. Affiliation semantics (the core mechanism)

- `smp_rep_phy_sata` reports per-phy: `affiliations supported: 1`,
  `affiliation valid`, `affiliated STP initiator SAS address`.
- Confirmed from **both** hosts: the affiliation state is global (shelf-side),
  not per-host.
- `maximum affiliation contexts: 1` — hardware-enforced single-initiator per
  SATA disk. This is why the shelf "rejects simultaneous commands": the
  second host's I/O fails with `DID_SOFT_ERROR` and 15s stalls.

## V3. Clean handoff round-trip (S1)

| Step | Result |
|---|---|
| A writes marker to sector 100 | OK |
| Clear affiliation (PHY CONTROL op 6, from A) | `affiliation valid: 0` |
| B reads sector 100 | A's marker, byte-identical |
| B writes its own marker | OK |
| Clear affiliation (from B) | `affiliation valid: 0` |
| A reads (after `sg_reset -d`) | B's marker, byte-identical |

**Data integrity across the full A→B→A cycle: verified.**

## V4. Old-owner behavior after affiliation loss

- Old owner's reads **hang** (SCSI 180s timeout, process in D-state) rather
  than failing fast.
- Recovery requires `sg_reset -d <disk>` (SCSI device reset).
- Design consequence: the handoff procedure must quiesce I/O *before*
  releasing the affiliation (clean export does this), and the new owner must
  reset devices during acquire. A hung export in a failure scenario requires
  fencing before takeover (S5).

## V5. Crash recovery (S2) — wedged owner

Simulated owner death by unbinding the HBA driver mid-operation (driver
stuck unloading, host OS alive):

- Expander **still reports `affiliation valid: 1`** for the wedged owner —
  its phys remain electrically up.
- Clear-affiliation (op 6) from the survivor is **refused**
  (`Phy control result: Affiliation violation`, affiliation stays valid).
- **Recovery works via PHY CONTROL hard reset (op 2)** on the disk phy:
  drops the disk's link → releases the stale affiliation → survivor
  re-affiliates on its next I/O → data intact.
- `STP I_T nexus loss occurred` did **not** fire (phys stayed up) — so
  crash detection must rely on I/O failure + affiliation state, not the
  nexus-loss bit alone.

## V6. Power-loss detection (S3, partial)

- The `STP I_T nexus loss occurred` bit is the expected signal when a host
  actually loses power (phys go down). Full validation of the S3 runbook
  requires a physical power-off, which is a manual step (or PDU/BMC fencing
  agent execution) — the runbook in `tests/S3_power_loss.sh` documents the
  exact procedure and expected observations.

## V7. Cluster behavior

- Dual-ring corosync: ring 0 on the client LAN, ring 1 on a private
  192.168.50.0/24 subnet via IP aliases. Both links `connected` on both
  nodes; `link_mode=active` (both links used simultaneously).
- Two-node quorum: `two_node: 1`, `Quorate: Yes`,
  `Flags: 2Node Quorate WaitForAll`.
- Both nodes Online, DC elected, resources startable.
- S4/S6 (partition, simultaneous boot) are documented runbooks; their
  expected behavior follows from standard corosync/pacemaker semantics and
  the import-prevention configuration in HOWTO §5.

## V8. Tooling

- `smp_send` (raw SMP via bsg): validated against REPORT GENERAL, DISCOVER,
  REPORT PHY SATA, SET PHY SATA, PHY CONTROL — responses match smp_utils
  output byte-for-byte. Works from either host against any expander.
- Python ctypes bsg access **segfaults on Python 3.14** (EFAULT from the
  kernel on the same ioctl that works from C) — use the C tool.

## Known limitations

1. **Second IOM path**: the reference shelf's second IOM is not cabled to
   either host, so there is no redundant shelf path. This does not affect
   the handoff mechanism (affiliation is per-disk, not per-path) but means
   the shelf IOM is a single point of failure in the reference setup.
2. **SBD**: not validated (no SAS disk in the shelf yet). The design treats
   SBD as an optional enhancement via a dedicated SAS disk.
3. **S3/S4/S6 full execution**: runbooks documented; full automated
   execution requires power control (PDU/BMC) which is part of the fencing
   phase.
4. **SMP PHY CONTROL on live disks**: clearing an affiliation while the
   owner is doing I/O will hang the owner's I/O (see V4). Only release
   affiliations for exported/idle pools, or after fencing.

## V9. ZFS pool layouts (RAIDZ1 / RAIDZ2) with multi-GB data

Tested on host B (host A down for power cycle at the time). Disks: 4x
WD30EFRX 3TB (bays 1, 5, 7, 11), affiliation-cleared via phy hard reset
after the previous owner's stale affiliations.

### RAIDZ1 (3 of the 4 disks in a raidz1, ~5.4T usable; the 4th was used for the RAIDZ2 test below)

- Pool created with `multihost=on`, separate cachefile
  (`/etc/zfs/zpool.cachefile.ha`) for boot-import prevention.
- 5x 1GB random files written (dd from /dev/urandom), sha256 recorded.
- **All 5 files verified OK** after write.
- Pool exported → affiliations cleared → pool re-imported (with phy hard
  resets in between) → **all 5 files verified OK again**.
- During re-import the pool briefly entered **SUSPENDED** state:
  `multihost=on` MMP detected its own writes failing while the disk phys
  were being reset. `zpool clear` resumed it. This is the multihost safety
  net working as designed - it refuses to continue when it cannot prove
  exclusive ownership.

### RAIDZ2 (4 disks, ~5.2T usable)

- Same 4-disk set, `raidz2` vdev. 5x 1GB random files, sha256 verified OK.
- **Degraded-mode test**: one disk offlined (`zpool offline`) → pool DEGRADED
  → all 5 files still verified OK (2-disk parity). Disk re-onlined →
  resilvered 120K with 0 errors → pool ONLINE.

### Conclusions

- Both RAIDZ1 and RAIDZ2 layouts work correctly on the shared shelf with
  the handoff mechanism, including export/import cycles through
  affiliation churn.
- `multihost=on` MMP correctly detects ambiguous ownership during phy
  resets and suspends rather than risk corruption. Handoff procedures must
  sequence: export → clear affiliations → (phy resets settle) → import on
  the new owner, and expect a possible `zpool clear` if MMP tripped during
  the transition.
- Degraded-mode reads work as expected; resilver is clean on re-online.

## V10. Live handoff practice (both hosts up) - MMP deadlock findings

Practiced real pool handoffs with both hosts powered and contending for the
disks (the realistic failure-adjacent case). Findings that only appear when
both hosts are alive:

### 1. Alive hosts re-affiliate constantly

Any I/O from a host re-affiliates an unaffiliated disk. Background probes
(udev, SMART polling, MMP retries) grab disks within seconds. A handoff
window must be coordinated: the outgoing owner releases and the incoming
owner imports immediately. This is exactly what Pacemaker provides -
manual handoff between two live hosts is inherently racy.

### 2. An owner can clear its own affiliation (op=6)

Confirmed: a live host can release its own disks via PHY CONTROL op=6.
It cannot clear another live host's affiliation (op=6 refused), and a
wedged host's affiliation needs op=2 (hard reset) - see V5.

### 3. mpt3sas drops affiliation-conflict disks at boot

If a disk is affiliated to another host when this host boots, mpt3sas logs
"discovery errors(sata affiliation conflict)" and drops the disk from
discovery entirely - no sd node, no by-id link. Recovery requires a phy
hard reset (op=2) followed by a host-level reset (sg_reset -H) to trigger
rediscovery; a plain SCSI scan ("echo '- - -' > scan") is NOT sufficient
because the transport layer dropped the device.

### 4. MMP suspend deadlock after a failed import

If an import suspends (MMP writes failed during disk settle), the importing
host cannot export ("pool I/O is currently suspended") or clear ("pool is
imported on a different host"), and its kernel keeps retrying MMP writes -
which re-affiliates the disks, blocking the other host's import in D-state.
The deadlock breaker observed:

- The host whose MMP state matches the on-disk state imports cleanly.
- That host then exports cleanly, resetting the MMP chain.
- The other host can then import.

If neither can proceed (state mismatch + suspended import), the importing
host must be power-cycled to clear the in-kernel suspended import.

### 5. Correct handoff procedure (updated)

```
OUTGOING OWNER                          INCOMING OWNER
1. zpool export <pool>
2. release own affiliations (op=6)
3. (disks now idle - do not touch)
                                        4. verify affiliations clear
                                        5. sg_reset -d each disk
                                        6. zpool import -f <pool>
                                        7. if SUSPENDED: settle longer,
                                           retry; if MMP-deadlocked, have the
                                           old owner import+export once
```

Key: step 2 and step 6 must be close in time, and the outgoing owner must
not touch the disks after step 2 (stop smartd/udisks2 or fence it).

### 6. Data integrity

Across all the churn in this session (multiple imports/exports, phy resets,
MMP suspends, one host power cycle), every sha256 verification of the 5GB
test dataset passed. No corruption at any point.

## V11. SCSI persistent reservation fencing (sas strategy) - live verified

Date: 2026-10-23. Hardware: DS460C dual-controller cabling, WD30EFRX 3TB
disks behind interposers, one host per controller.

- `zfs-ha-pr key` produces stable per-host keys (`0x5a17` + md5(hostname)).
- `zfs-ha-pr reserve` registers and takes the type-5 (Write Exclusive,
  Registrants Only) reservation; `held` confirms; `status` shows the key
  and reservation holder.
- While host A held the reservation, host B's direct write
  (`dd oflag=direct`) failed with `Invalid exchange` - the drive-firmware
  reservation conflict, visible as `reservation conflict error` in dmesg.
  Reads still passed (type 5 semantics).
- `zfs-ha-pr release` dropped the reservation; host B's write then
  succeeded. Generation counter incremented as expected.
- Bug found and fixed during this test: `sg_persist -k` output's
  `PR generation=0xNN` line matched a naive key grep, sending register
  down the replace-existing path (refused by this shelf). The tool now
  excludes the generation line.
- Caveat: this validates the primitive and the tooling. The full
  pacemaker-driven `fencing=pr` failover matrix (preempt on dead owner,
  reservation surviving controller path failover) is still pending - the
  reference cluster's failover testing was interrupted by an unrelated
  host wedge (see V12).

## V12. SUSPENDED-pool-with-deleted-devices wedge (known failure mode)

Date: 2026-10-23. During a pacemaker `pcs resource move` cutover, the
outgoing owner's pool suspended (MMP) and the RA then deleted the devices
(quiesce) underneath the suspended pool. Result:

- `zpool export -f` and `zpool clear` wedged in D-state (txg_wait_synced
  to vdevs that no longer exist), surviving `kill -9`.
- Every subsequent `zpool` command on the host hung behind them (37+
  minutes observed before the host was taken down for a manual restart).
- The pool data itself was fine: the new owner imported it and all files
  were verified intact (marker written pre-move read back byte-identical).

Consequences for the design:

1. The RA must not quiesce devices while the pool is SUSPENDED - that
   state requires fencing escalation, not device deletion. (Not yet implemented as a check;
   current RA exports first and only quiesces after a clean export, so
   this window requires the export to have already failed/suspended.)
2. A failed stop must escalate to fencing (pacemaker does this naturally
   when stonith is configured) - the wedged host cannot clean itself.
3. D-state `zpool` processes are unkillable; the only recovery is a host
   restart. Do not burn time trying to unwedge.

## V13. Pacemaker failover cutover (partial - data path verified)

Date: 2026-10-23. Cluster: corosync dual-ring, two-node quorum,
fence_zfs_ha_stp stonith resource, ha_pool (ocf:zfsha:Pool) + ha_vip
(IPaddr2) with colocation and stop ordering.

- Cluster bring-up: both nodes online, quorate, resources started on the
  primary, VIP up on the client NIC.
- `pcs resource move ha_pool`: VIP torn down before the pool (ordering
  constraint working), pool exported on the old owner, imported on the
  new owner, data verified intact.
- Role arbitration verified live: the secondary-role host stood down
  (refused to import) while the primary held the pool, including during
  the 180s PEER_WAIT window after a peer failure.
- Incomplete: the full move matrix (move back, crash-of-owner takeover,
  fenced takeover) was interrupted by the V12 wedge and the manual host
  restart. To be completed.

## V14. Fenced takeover - found and fixed two recovery-path defects

Date: 2026-10-24. During the fenced-takeover leg of the failover matrix,
two defects surfaced that only appear when the fence fires while the
owner is live:

1. **udev quiesce rule vs. rescan race.** After the fence cleared the
   owner's affiliations, the acquiring host's rescan brought the disks
   back - and the udev quiesce rule deleted them within a second, because
   the allow-import flag was not held across the (10-30s) mpt3sas
   rediscovery window. Every device that re-attached after the RA's flag
   window expired was deleted before the import could see it. Symptom:
   endless "missing: <disk>" start failures despite the phy resets
   working. Fix: the strategy rescan ops now hold the allow-import flag
   (reference-counted) for the entire rediscovery sequence.
2. **preempt on an unregistered key.** The fence left the dead owner's PR
   registration + reservation in place. `zfs-ha-pr preempt` first tries
   to register our own key - which this shelf refuses while any
   reservation exists (the same quirk documented in §12.1c). Fix: when we
   hold no registration, preempt using the victim's own key as rk/sark,
   then register + reserve.

Also confirmed live: the fence agent itself works (fence cleared all of
the owner's disk affiliations at the shelf; the fenced host's pacemaker
self-terminated with "We were allegedly just fenced"), and the fenced
host's pool import attempt correctly failed with "pool is imported on
host 'zfs-ha-a'" - MMP refusing dual ownership.

Recovery sequence that converged (documented for operators):
phy hard reset on peer-affiliated phys -> clear the dead owner's PR
registration (clear --param-rk=<victim-key>) -> rescan with allow-import
held -> zpool import -f -> pcs resource cleanup.
