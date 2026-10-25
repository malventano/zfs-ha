# Disk Handoff Algorithm (Canonical)

This is the authoritative state machine for ZFS pool ownership transfer on a
shared SAS shelf with SATA (STP-affiliated) disks. Every tool and resource
agent in this repository implements a subset of this algorithm; this document
is the spec they must agree with.

## Core primitives

| Primitive | Command | Effect |
|---|---|---|
| **Quiesce (OS-level)** | `echo 1 > /sys/block/sdX/device/delete` | Removes the device from the OS entirely. No sd node, no by-id link, no udev/smartd/MMP I/O possible. **Validated: the device cannot come back except via explicit rescan.** This is the anti-race primitive. |
| **Rediscover** | `echo "- - -" > /sys/class/scsi_host/hostN/scan` | Re-adds deleted devices. |
| **Release affiliation (self)** | `smp_phy_control --phy=N --op=ca <bsg>` | A live owner clears its own disk affiliations. |
| **Release affiliation (dead/wedged owner)** | `smp_phy_control --phy=N --op=2 <bsg>` (hard reset) | Drops the disk's link, releasing a stale affiliation. Required when the owner is wedged (op=6 is refused while the owner's phys are up). |
| **Verify clear** | `smp_rep_phy_sata --phy=N <bsg>` | `affiliation valid: 0` = free. |
| **Flush stale commands** | `sg_reset -d /dev/sdX` | Clears queued commands from the previous owner's era. |
| **Neuter (BMC)** | fence_ipmilan / Redfish `PowerOff` + verify `PowerState=Off` | Cuts power to the peer. The only proof of death. |
| **Neuter (PiKVM)** | PiKVM API power-off + power-state readback | Same as BMC, via motherboard header. |

## Host states

```
CLEAN      no HA-pool devices in OS, no affiliations held, pool not imported
PRIMARY    pool imported, devices present, affiliations held
SECONDARY  devices deleted (quiesced), no affiliations, pool not imported
DIRTY      anything else: suspended import, stuck export, D-state zpool,
           devices present but pool not imported, affiliations held with no
           imported pool. MUST be reported to the operator; recovery requires
           a reboot (or targeted cleanup) before the host may rejoin the
           ownership rotation.
```

A host **checks in** via Pacemaker/Corosync after any reset: the cluster
tells it whether it is SECONDARY (normal for the former primary after
failover) or DIRTY (needs operator attention). `zfs-ha-doctor` reports this.

## The handoff (planned / clean move)

```
OUTGOING (PRIMARY)                        INCOMING (SECONDARY)
─────────────────────────────────────     ─────────────────────────────────
1. Pacemaker stop ha_pool
2. zpool export <pool>
3. release own affiliations (op=6)
4. QUIESCE: delete all HA-pool sd
   devices (echo 1 > .../delete)
5. verify: no sd nodes, no
   affiliations held
                                          6. (cluster promotes ha_pool here)
                                          7. rescan (scan host) -> devices
                                             reappear
                                          8. verify affiliations clear
                                             (op=6 was done by outgoing)
                                          9. sg_reset -d each disk
                                          10. zpool import -f <pool>
                                          11. mount, start services
```

Steps 4 and 7 are the anti-race pair: between the outgoing host's delete and
the incoming host's rescan, **no host has the devices in its OS**, so nothing
can re-affiliate them. The window is safe for arbitrarily long delays.

## The handoff (unclean: peer failure)

```
SURVIVOR
────────────────────────────────────────────────────────────
1. Detect peer loss (corosync + fencing policy)
2. FENCE: neuter peer via BMC/PiKVM
   - ensure off, VERIFY off via independent readback
   - if verification fails: STOP. Do not import. Alert operator.
3. Classify peer's storage state:
   a. peer phys DOWN (power off)  -> affiliations auto-released by shelf;
      expect nexus-loss bit in REPORT PHY SATA
   b. peer phys UP (wedged OS)    -> stale affiliations held;
      clear requires op=2 hard reset per disk
4. Release stale affiliations (op=6 if link gone, else op=2 hard reset)
5. Rescan -> devices appear
6. sg_reset -d each disk
7. zpool import -f <pool>
8. mount, start services
```

**Fencing always precedes import.** The SMP operations recover storage
*access*; fencing establishes *exclusivity*. A wedged host that still holds
the VIP or serves cached data is not safe to take over from until it is
neutered.

## The handoff (peer rebooting / maintenance)

When the peer reboots (updates, restart, kernel change), it must not disrupt
the primary. Boot-time posture:

1. **HA-pool devices are deleted at boot** (systemd unit runs the delete
   before udev settle completes) — the secondary boots with zero HA-pool
   devices in its OS. Nothing can probe them.
2. **zfs-import-cache/scan services are disabled** for the HA pool
   (separate cachefile; see HOWTO §5).
3. The host joins the cluster, checks in, and is told its role:
   - If the peer is PRIMARY: stay SECONDARY (devices stay deleted).
   - If the peer is gone: the cluster fences (already off) and promotes
     this host — rescan, import, start.
4. A host that boots and finds itself DIRTY (e.g. it was the primary and
   crashed mid-write) reports `needs-reboot` / `needs-cleanup` and waits.
   **Telling the operator "this host needs a reboot to be cleaned" is
   correct, expected behavior** — it is not an error condition.

## mpt3sas posture (the "special modprobe" question)

No special modprobe flags are needed, but the **driver posture** differs by
role:

- **SECONDARY (normal idle):** HA-pool devices deleted. mpt3sas stays loaded
  (it also serves the SES enclosure device and any non-HA disks). With no HA
  devices in the OS, ordinary operations — updates, restarts, reboots —
  cannot touch the pool. This is the whole point of the delete primitive.
- **Boot with affiliation conflicts:** if a disk is affiliated to the peer
  at boot, mpt3sas **drops it from discovery** (`discovery errors(sata
  affiliation conflict)`) — no sd node at all. This is actually *helpful*
  for a secondary (fewer devices to quiesce) but must be recovered with
  op=2 + `sg_reset -H` when the host is promoted. A plain SCSI scan is NOT
  sufficient (the transport layer dropped the device, not the SCSI layer).
- **Never unload mpt3sas on a live node** while HA disks may be affiliated:
  the unbind path hangs in `sd_sync_cache` (validated). If a host must drop
  its SAS stack, delete the devices first, then unbind is safe.

## Dirty-state detection (what `doctor` reports)

| Symptom | Diagnosis | Recovery |
|---|---|---|
| `zpool import` shows pool, `zpool list` empty, no D-state | clean secondary | none needed |
| suspended import (`zpool list` shows SUSPENDED) | MMP tripped | **reboot required** (cannot export/clear) |
| `zpool import` in D-state | disks held by peer | delete devices, wait for peer to release, rescan |
| export hangs | I/O in flight / peer interference | **fence peer**, then phy hard resets |
| affiliations held, no pool imported | stale from crash | op=2 hard resets, then delete devices |
| `discovery errors(sata affiliation conflict)` in dmesg | boot-time conflict | op=2 + `sg_reset -H` when promoted |

## Invariants

1. No import without exclusivity: verified clean release **or** verified
   fencing.
2. Fencing = ensure off + verify off via independent readback. An accepted
   API request is not proof.
3. Fencing precedes takeover in every unclean path.
4. Disks addressed by WWN/by-id only.
5. The shelf is a shared failure domain; whole-shelf loss is a whole-service
   outage.

## Boot-time device quiesce (udev rule) - validated 2026-10-11

**Problem:** at boot, both hosts probed the HA-pool disks before anything
could quiesce them, producing dmesg full of I/O errors and re-affiliating
disks racy-style.

**Solution:** a generated udev rule deletes HA-pool devices **the instant
they appear**, before any probe can touch them:

```
ACTION=="add", SUBSYSTEM=="block", ENV{ID_WWN}=="*<wwn>",
    RUN+="/usr/lib/zfs-ha/zfs-ha-udev-delete"
```

- Generated from pool.conf by `zfs-ha-udevrule generate` (one rule per WWN).
- `zfs-ha-udev-delete` checks `/run/zfs-ha/allow-import`: if present (RA is
  deliberately rescanning for an import), the device is permitted; otherwise
  it is deleted and logged (`journalctl -t zfs-ha-udev`).
- The RA's start action sets the flag before rescanning and removes it after
  import. Boot posture: no flag → all HA devices deleted on appearance.

**Validated live:** delete-on-appearance (4/4 devices removed by udev during
a scan), allow-import path (4/4 permitted with the flag set), and the
already-present quiesce (`zfs-ha-quiesce delete` for devices that existed
before the rule loaded).

**Deployment:** `zfs-ha-udevrule generate && udevadm control --reload` on
both hosts after `zfs-ha-poolconf write`. Regenerate after any pool disk
change.

## Pacemaker resource configuration (boot flow) - validated 2026-10-11

The complete boot flow is now operational:

```
BOOT:
  1. corosync + pacemaker start (systemd)
  2. udev rule deletes HA devices on appearance (no probing)
  3. pacemaker elects a host and starts ha_pool there
  4. RA start: set allow-import flag -> rescan (udev permits) ->
     acquire (evidence) -> import -> remove flag
  5. ha_vip starts on the same host (colocation + mandatory ordering)
```

Resources configured:
```
pcs resource create ha_pool ocf:zfsha:Pool pool=<POOL> \
    op start timeout=300s op stop timeout=300s op monitor timeout=30s interval=30s
pcs resource create ha_vip ocf:heartbeat:IPaddr2 ip=<VIP> cidr_netmask=<mask> nic=<nic>
pcs constraint colocation add ha_vip with ha_pool INFINITY
pcs constraint order ha_pool then ha_vip kind=Mandatory
pcs resource defaults update resource-stickiness=200
```

Validated during development: node loss (corosync stopped on primary) → pool+VIP stopped →
survivor cleaned up → RA start on survivor (rescan through udev quiesce,
acquire with evidence, import) → VIP moved → data verified (sha256).

### Operational notes from validation

- **OCF version**: pcs requires 1.0/1.1 (not 2.0) - the RA declares 1.1.
- **zpool path**: pacemaker's env may not include /usr/sbin; the RA checks
  common paths.
- **allow-import flag lifecycle**: set at start, removed ONLY on successful
  import or stop. Removing it on failure would let the udev rule delete
  devices mid-sequence (a host reset inside rescan redisCOVERS them).
- **VIP nic/cidr_netmask**: must match the actual interface config; findif
  fails with a mismatched netmask ("inet prefix is expected rather than
  scope").
- **Start timeout**: 300s minimum - the rescan may include a host reset
  (sg_reset -H, ~20s) plus udev settle per disk.
- **stonith-enabled=false** is for testing only. Production requires fencing
  configured and tested before the pool resource is created.

## NFS failover via sharenfs - validated 2026-10-11

Following the ewwhite/zfs-ha design: the `sharenfs` ZFS property handles NFS
export failover with NO separate NFS resource agents. The export travels with
the pool import/export.

```sh
zfs set sharenfs="rw=@<client-net>,sync,no_root_squash" <pool>/data
```

**RA integration:** stop = unmount sharenfs datasets + stop nfs-server +
export; start = import + start nfs-server (sharenfs datasets auto-export).

**Cutover timing (first failover, measured):** client wrote 1 record/second
to the NFS mount via the VIP. After `pcs resource ban` (the cutover trigger),
**zero gaps > 2s** in the write log - the NFS client did not stall
measurably. The kernel NFS client's graceful recovery absorbed the cutover.

**Lesson learned (second failover):** the kernel nfsd holds the sharenfs
dataset mount. Export fails with "pool or dataset is busy" unless the
datasets are unmounted and nfs-server stopped first. The RA now does this.

**Comparison with ewwhite's design** (2019, dual-port SAS):
- He: cachefile=none, fence_scsi (SCSI PRs on pool disks), no MMP,
  7s failover. Simpler because SAS disks need no affiliation dance.
- Us: cachefile=separate, MMP on, affiliation release + quiesce + udev boot
  quiesce. More machinery because SATA/STP enforces single-initiator.
- Common: sharenfs (his key trick), pcs dual-ring, stickiness, VIP.
- His fence_scsi is the model for our `sas` strategy's
  `evidence=scsi-pr-held` (SCSI persistent reservations).

## VIP teardown ordering with sharenfs (2026-10-11)

The stop sequence must tear down the VIP **before** the pool: if the VIP is
still up when the sharenfs datasets unmount, connected NFS clients get
ESTALE errors ("export vanished while server reachable") instead of a clean
connection drop. Hard-mounted clients retry connection drops silently but
surface ESTALE as I/O errors.

```
CORRECT stop order (pacemaker constraints):
  1. stop ha_vip            (clients' TCP connections drop; hard mounts retry)
  2. zfs unmount -a         (no clients connected; no ESTALE)
  3. stop nfs-server
  4. zpool export
  5. quiesce + release
```

Constraint:
```
pcs constraint order stop ha_vip then stop ha_pool
```
(The start ordering `start ha_pool then start ha_vip` is the inverse and
already existed. Both are needed.)

## Bay 5 phy wedge (2026-10-11) - shelf-side issue

During post-boot recovery, bay 5 disk (E6V977) dropped from the expander:
phy 5 shows "disabled" in DISCOVER, REPORT PHY SATA returns "Phy does not
support SATA", and SES reports the slot as Critical with Bypassed A=1,
Bypassed B=1 (both paths bypassed). PHY CONTROL op=1 (link reset) and op=2
(hard reset) return rc=0 but the phy stays disabled. The sysfs enable toggle
also has no effect.

Recovery requires a physical reseat of the bay 5 disk (pull and reinsert),
which triggers the expander to re-discover it. This is the first observed
case of a phy wedging at the shelf level (all previous drops were
affiliation-related and recoverable via op=2).

Note: the disk itself may be fine - the expander port wedged. If a reseat
does not recover it, try a different bay.
