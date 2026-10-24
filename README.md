# zfs-ha: Active/Standby ZFS File Server on a Shared SAS Disk Shelf

Two commodity hosts, one used SAS disk shelf, one ZFS pool that is always
imported on exactly one host at a time. NFS and Samba fail over with the
pool. Pacemaker + corosync two-node cluster. Everything here is open source
and runs on hardware you can buy used for a few hundred dollars.

```
        ┌──────────────┐          ┌──────────────┐
        │    node A    │          │    node B    │
        │  Rocky/RHEL  │          │  Rocky/RHEL  │
        └──┬───────┬───┘          └──┬───────┬───┘
           │       │                 │       │
     client net  SAS HBA        SAS HBA   client net
      + VIP      │                 │       + VIP (fails over)
           │       └───────┬─────────┘       │
           │               │                 │
           │        ┌──────┴───────┐         │
           │        │  SAS shelf   │         │
           │        │ (expander +  │         │
           │        │  SATA disks) │         │
           │        └──────────────┘         │
           │                                 │
           └────────────┬────────────────────┘
                        │
                 ┌──────┴──────┐
                 │  clients    │
                 └─────────────┘
```

This is the project I built because commercial HA-ZFS products charge
$25-30k for what two used servers, a used NetApp DS460C, and some patience
can do. The catch - and the reason this repo exists - is that the hard part
depends entirely on what kind of disks are in the shelf. This project solves
all three disk paths and documents where each one is appropriate.

**Status: working, validated end-to-end on real hardware.** The validation
record (`docs/VALIDATION.md`) covers: the STP disk-handoff primitive (SATA
affiliation release/acquire/recover, with data integrity checks, V2-V10),
the cluster stack (corosync dual-ring, two-node quorum, V7), a pacemaker
failover cutover with data verified intact on the new owner (V13 - partial:
move-back, crash takeover, and fenced takeover are still pending), the
SCSI persistent reservation path live-verified end to end (V11), the
SUSPENDED-pool wedge failure mode and its lessons (V12), the controlled
cutover protocol (three consecutive full round-trips of a 4x3TB raidz1,
documented in HOWTO §12.3), and boot-time quiesce + NFS cutover via
`sharenfs` (documented in HANDBOFF). The `null` strategy is designed, not
validated.

## Why this is subtle

The whole problem is one question: **when one host dies, how does the other
one know it is safe to touch the disks?** The answer depends on your disks:

- **SATA disks behind a SAS expander** (the common case in cheap shelves)
  use the SATA Tunneling Protocol. Each disk maintains an *affiliation* with
  exactly one initiator port - the shelf hardware enforces single-owner
  access. That is actually good (free split-brain protection at the
  hardware level), but failover requires actively releasing the affiliation,
  and a crashed owner leaves a *stale* one that must be hard-reset at the
  phy level. This is the hard path, and it is fully solved here.
- **SAS disks** (or SATA behind good interposers) have no exclusivity at
  all: both hosts can always issue I/O. You must add your own fencing, and
  the right tool is SCSI persistent reservations - the disk itself refuses
  writes from anyone but the owner, at drive-firmware level, independent of
  both operating systems.
- **Plain SATA with no transport release** (no interposers, dumb shelf) has
  nothing to release and nothing to lock. For that case there is a
  controlled cutover protocol for planned maintenance, and an honest
  warning that emergency failover has no clean answer without PR support.

## What's in the repo

```
scripts/
  smp_send.c            raw SMP frame sender via bsg (any expander, any fn)
  zfsha-pool            OCF resource agent: cluster-managed ZFS pool
                        (rescan → acquire with evidence → import on start;
                         unmount NFS → export → quiesce → release on stop)
  zfs-ha-handoff        strategy dispatcher (scripts/strategies/{stp,sas,null})
  zfs-ha-config         pool.conf reader/validator
  zfs-ha-poolconf       writes pool.conf (authoritative pool + disk list)
  zfs-ha-quiesce        OS-level device delete/rescan (anti-race primitive)
  zfs-ha-udevrule       generates the boot-time udev quiesce rule
  zfs-ha-udev-delete    udev add-hook: deletes HA devices on appearance
  zfs-ha-doctor         host posture: CLEAN/PRIMARY/SECONDARY/DIRTY
  zfs-ha-role           boot-time role arbitration (primary/secondary)
  zfs-ha-mailbox        SAS-disk heartbeat (second confirmation path)
  zfs-ha-amialone       fence-or-abstain gate (never imports)
  zfs-ha-pr             SCSI persistent reservation fencing (register/
                        reserve/release/preempt)
  zfs-ha-cutover        controlled cutover protocol (no-transport-release
                        disks, planned maintenance)
  fence_zfs_ha_stp      stonith fence agent: SAS/STP storage isolation
  check_boot_import.sh  verifies no boot-time auto-import (installed as `check_boot_import`)
  strategies/           stp/ sas/ null/ handoff strategy plugins
                        (installed to /usr/lib/zfs-ha/strategies.d/)
configs/
  pacemaker-resources.txt   resource definitions + ordering constraints
  zfs-ha-posture.service    boot-time quiesce systemd unit (template)
tests/
  write_client.py       synchronized-write client + durability verifier
  S1..S6 scenario scripts (see tests/README.md for the matrix)
utils/
  shelf-health.py       SAS shelf health/status CLI (console + --json)
  sas_topology.sh       discover shelf topology: bays, WWNs, phys, affiliations
  README.md             how to use both, with sample output
docs/
  HOWTO.md              full deployment guide
  VALIDATION.md         what was tested, on what hardware, with what results
  HANDBOFF.md           canonical handoff algorithm + operational addendum
  FENCING.md            fencing backend options and requirements
```

### What the scripts do, and how the strategies fit

Everything keys off one file, `/etc/zfs-ha/pool.conf`, written once at pool
creation by `zfs-ha-poolconf`:

```ini
pool=red3t
disks=/dev/disk/by-id/wwn-0x5000c500a1b2c3d4,/dev/disk/by-id/wwn-0x5000c500a1b2c3d5,...
strategy=sas
fencing=pr
role=primary
peer=<nodeB-ip>

# optional (zfs-ha-amialone signals; all off unless set):
# mailbox=/dev/disk/by-id/scsi-35000c9...
# interface=enp1s0
# peer_sas_addr=0x500605b0...
# peer_bmc=10.x.x.x
# peer_bmc_user=...
# peer_bmc_pass=...
```

That file is the single source of truth for the pool name, the exact disks
(by-id, never `/dev/sdX`), and - most importantly - the **handoff
strategy**, which is how the different hardware paths plug in:

| strategy | hardware | how handoff works |
|---|---|---|
| `stp` | SATA disks behind a SAS expander | SMP PHY CONTROL through the expander: release the affiliation on stop, verify it clear + re-acquire on start, phy hard reset to recover a crashed owner |
| `sas` | SAS disks, or SATA behind interposers | SCSI persistent reservations: register + reserve on start, release on stop, preempt on fenced takeover |
| `null` | shelf enforces nothing | no transport action at all; safe only with real fencing, MMP as the backstop |

`strategy=auto` probes a disk and picks (note: auto can only ever select `stp` or fall back to `null` - set `sas` explicitly for SAS/interposer disks). The dispatcher is
`zfs-ha-handoff`; each strategy implements the same six-op contract
(`probe`, `release`, `recover`, `acquire`, `quiesce`, `rescan`) and fails
closed. Adding a fourth hardware path means writing one new script under
`strategies.d/`, not touching anything else.

The **resource agent** (`zfsha-pool`, installed as `ocf:zfsha:Pool`) is what
pacemaker actually runs. On `start` it rescans, demands positive exclusivity
evidence (affiliation clear, reservation held, or fence verified - it will
not import on a guess), and imports. On `stop` it unmounts, exports,
quiesces the devices out of the OS, and releases. On `monitor` it treats a
SUSPENDED pool as not-running, which is what you want.

### Primary and secondary nodes

The two hosts are **not** symmetric, and saying so out loud avoids a lot of
confusion:

- The **primary** is the host the pool lives on when everything is healthy.
  It boots, waits for corosync/pacemaker, and starts the pool. If the
  cluster is down entirely (peer not responding), it starts the pool anyway
  - it is the designated owner, and refusing to start because the peer is
  gone would turn a one-host outage into a two-host outage.
- The **secondary** boots, waits a few minutes, checks whether the primary
  is actually up (cluster + pool), and stands down if it is. Only if the
  primary is verifiably not coming back does it take over - and takeover
  still routes through fencing, never through "I haven't heard from him in
  a while, he's probably dead".

The role is just a line in pool.conf (`role=primary` / `role=secondary`,
plus `peer=<address>` - which must match the **pcs node name** (what `pcs status` prints, i.e. what you passed to `pcs cluster setup`), not necessarily an IP), set by `zfs-ha-poolconf write ... --role primary --peer <nodeB-name>` (and the mirror on the secondary), and
enforced at boot by `zfs-ha-role`. Asymmetric fencing delays
(`pcmk_delay_max`) make the primary the deterministic survivor of a
simultaneous failure. Disable automatic failback: when the primary comes
back from maintenance, it comes back as a standby until you deliberately
move the pool back.

## Quick start

```sh
# 1. prerequisites (both nodes) - see docs/HOWTO.md for the full version
dnf install -y https://zfsonlinux.org/epel/zfs-release-2-8.el10.noarch.rpm
dnf --enablerepo=zfs-kmod install -y zfs zfs-kmod
dnf --enablerepo=highavailability install -y pacemaker corosync pcs resource-agents
dnf install -y gcc make
make install   # builds smp_send, installs all tools to /usr/lib/zfs-ha

# 2. cluster (first node only)
passwd hacluster
systemctl enable --now pcsd
firewall-cmd --permanent --add-service=high-availability && firewall-cmd --reload
pcs host auth nodeA nodeB
pcs cluster setup zfs-ha --start --enable nodeA nodeB

# 3. second corosync link (IP aliases on a private subnet work fine)
ip addr add 192.168.50.1/24 dev <nic>   # node A
ip addr add 192.168.50.2/24 dev <nic>   # node B
nmcli con mod <nic> +ipv4.addresses 192.168.50.1/24   # persistent
pcs cluster link add nodeA=192.168.50.1 nodeB=192.168.50.2
pcs cluster config update transport link_mode=active

# 4. pool (by-id, never /dev/sdX)
zpool create -o multihost=on -o cachefile=/etc/zfs/zpool.cachefile.ha <POOL> \
    /dev/disk/by-id/wwn-0x... ...

# 5. record the config + boot-time quiesce rule (run on the primary, then
#    copy /etc/zfs-ha/pool.conf to the peer and set role/peer per host)
zfs-ha-poolconf write <POOL> --strategy <stp|sas|null> --fencing <none|pr|bmc|pdu|pikvm|sbd> \
    --role primary --peer <nodeB-name>          # on the primary; peer= must match the pcs node name
zfs-ha-poolconf write <POOL> --strategy <stp|sas|null> --fencing <none|pr|bmc|pdu|pikvm|sbd> \
    --role secondary --peer <nodeA-name>        # on the secondary
zfs-ha-udevrule generate && udevadm control --reload

# 6. NFS via sharenfs (the export travels with the pool)
zfs set sharenfs="rw=@<client-net>,sync,no_root_squash" <POOL>/data
systemctl enable --now nfs-server

# 7. Samba via a clustered-safe config (see HOWTO, HA Samba section)

# 8. fencing - REQUIRED before the pool resource goes into pacemaker
# 9. resources (configs/pacemaker-resources.txt)
```

Full guide: `docs/HOWTO.md`.

## Design invariants

Non-negotiable; every scenario in `tests/` enforces one or more:

1. **No import without exclusivity.** A node imports the HA pool only after
   a verified clean release by the previous owner, or after successful
   fencing of an uncertain previous owner. The RA's acquire step demands
   positive evidence. A timeout, a failed ping, or a visible disk is not
   evidence.
2. **Fencing is verified, not requested.** "Accepted API request" is not
   proof of fencing; "power is off" (or "reservation is mine") is.
3. **Fencing precedes takeover in failure scenarios.** A hung export or a
   wedged owner routes through fencing first. The SMP operations recover
   *storage access*; fencing establishes *exclusivity*.
4. **The shelf is a shared failure domain.** Both hosts losing the shelf
   simultaneously is a whole-service outage; the design does not pretend
   otherwise.
5. **Disks are addressed by WWN/by-id, never /dev/sdX.** Enumeration differs
   between hosts and across boots.
6. **The VIP tears down before the pool.** With sharenfs, stopping the pool
   while the VIP is up gives clients ESTALE errors; the ordering constraint
   prevents this.

## Hardware notes - three paths, pick yours

This is the decision that shapes everything else, so it gets its own section
in the HOWTO with cabling diagrams. The short version:

1. **SAS + interposers (best setup).** SATA disks behind *working* SAS
   interposers present as dual-port SAS: no affiliation dance, SCSI PR
   fencing, multipath. Recommended cabling is **one host per controller** -
   each disk seen exactly once per host, no multipath needed. This is what
   I recommend for a new build.
2. **Interposer quality is everything.** Good interposers pass through the
   drive's real serial and SAS address and run at full speed. Bad ones mask
   the serial, fabricate SAS addresses, and collapse from 150 MB/s to under
   2 MB/s under sustained load with constant reset storms. In my testing,
   Emulex interposers worked; LSI ones did not. `docs/HOWTO.md` §12.2 has
   the 30-second triage.
3. **Plain SATA, single controller.** No interposers: one host cabled to one
   controller, the other controller unplugged, the `stp` strategy (if the
   shelf enforces affiliation) or the controlled cutover protocol (if it
   does not). One mailbox SAS disk in the shelf is worth having even here -
   it gives the cluster a second, disk-level confirmation path about peer
   liveness.

## Comparison with ewwhite/zfs-ha (2019)

The classic reference design (dual-port SAS, `fence_scsi`, `cachefile=none`,
`sharenfs`, 7s failover) works because SAS disks make the hard problems
disappear. This project solves those problems for SATA disks: the
affiliation handoff machinery, MMP as a corruption backstop, evidence-based
acquire, and boot-time quiesce. The `sharenfs` NFS failover approach is
adopted from that design (it's the right way). With SAS disks, this
project's `sas` strategy converges to the same simplicity.

## License

GPL-2.0-or-later (matching the Linux kernel).
