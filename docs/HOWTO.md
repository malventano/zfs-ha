# Deployment HOWTO

This guide is shelf-agnostic. Anything marked *reference implementation* is
what was validated on the test hardware (NetApp DS460C, IOM12, LSI SAS3008
HBAs, Rocky Linux 10.2, OpenZFS 2.2.11, pacemaker 3.0.1 / corosync 3.1.10);
the steps themselves apply to any SAS expander shelf.

This how-to assumes you already have Rocky Linux installed and OpenZFS +
Cockpit working (there are plenty of how-tos for those; this guide starts
where they stop). It covers:

- [§1](#1-install-packages) package installs
- [§2](#2-network) network layout
- [§3](#3-cluster-bring-up) cluster bring-up + Cockpit HA Cluster Management
- [§4](#4-pool-creation) pool creation
- [§5](#5-boot-time-import-prevention--device-quiesce) boot-time import prevention
- [§6](#6-fencing-required-before-production) fencing
- [§7](#7-resources) pacemaker resources
- [§8](#8-the-handoff-step-by-step) what the handoff actually does
- [§9](#9-testing) the test harness
- [§10](#10-ha-nfs) HA NFS
- [§11](#11-ha-samba) HA Samba
- [§12](#12-hardware-setup-the-three-paths) the three hardware paths
  (SAS+interposers, interposer quality, plain SATA)
- [§13](#13-witness-qnetd-and-two-node-quorum) witness/qnetd
- [§14](#14-operations) operations
- [§15](#15-field-notes-for-anyone-attempting-this-hard-won) field notes

---

## 1. Install packages

On **both** nodes:

```sh
# ZFS (kmod variant avoids DKMS rebuilds on kernel updates)
dnf install -y https://zfsonlinux.org/epel/zfs-release-2-8.el10.noarch.rpm
dnf --enablerepo=zfs-kmod install -y zfs zfs-kmod
modprobe zfs

# cluster stack (EL10: highavailability repo, disabled by default)
dnf --enablerepo=highavailability install -y pacemaker corosync pcs resource-agents

# Cockpit + the HA cluster management add-on (see §3)
dnf --enablerepo=highavailability install -y cockpit cockpit-ha-cluster
systemctl enable --now cockpit.socket
firewall-cmd --permanent --add-service=cockpit && firewall-cmd --reload

dnf install -y sg3_utils lsscsi

# smp_utils is NOT packaged for EL10/Rocky 10 - build it
dnf install -y gcc make
curl -skL https://sg.danny.cz/sg/p/smp_utils-0.99.tgz | tar xz -C /tmp
cd /tmp/smp_utils-0.99 && ./configure --prefix=/usr/local && make -j4 && make install

# this project's tools (builds smp_send, installs everything)
make install
```

Notes from the reference build:

- The kmod package is named `kmod-zfs` (the `zfs-kmod` repo provides both
  names; `dnf install zfs-kmod` also resolves to the kmod build). Kernel
  6.12 requires ZFS ≥ 2.2.
- The upstream ClusterLabs `ocf:heartbeat:ZFS` agent exists but is omitted
  from RHEL/Rocky's resource-agents build. You don't need it: this
  project's `zfsha-pool` installs as `ocf:zfsha:Pool` and is
  affiliation-aware (the upstream agent knows nothing about disk handoff).
- Keep ZFS versions **identical** on both nodes. Pool feature flags must
  match for a handoff to work.

## 2. Network

- **Client network**: one interface per node, normal LAN. The floating VIP
  (service address) lives here and moves with the pool.
- **Cluster links**: corosync wants at least one dedicated link; two is
  better. Options, in order of preference:
  1. Dedicated NICs on a private subnet (e.g. 192.168.50.0/24).
  2. IP aliases on the existing NICs, on a **different subnet** from the
     LAN (validated configuration: aliases `192.168.50.1/24` and `.2/24`
     on the client NICs; `nmcli con mod <if> +ipv4.addresses 192.168.50.1/24`).
  3. A crossover cable between the two nodes.

  Aliases are a functional fallback, not a substitute for real redundancy:
  they share the NIC's failure domain. Use dedicated NICs for production.
  A direct 1 Gb crossover heartbeat is the cheapest real second link.

- **Passwordless SSH between the hosts** (required by `zfs-ha-cutover` and
  the peer preflight checks):

  ```sh
  ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
  ssh-copy-id <user>@<peer>          # both directions
  # if the tooling runs under sudo, also copy the key to /root/.ssh/
  sudo cp ~/.ssh/id_ed25519* /root/.ssh/ && sudo chown root:root /root/.ssh/id_ed25519*
  ```

  Note: sshd's per-source penalty (OpenSSH 9.8+) temporarily blocks a host
  after repeated failed auths - always use an explicit `user@host`, and
  never let scripts hammer ssh with bad credentials.

## 3. Cluster bring-up

```sh
passwd hacluster                      # same password on both nodes
systemctl enable --now pcsd
firewall-cmd --permanent --add-service=high-availability && firewall-cmd --reload

# from node A:
pcs host auth nodeA nodeB
pcs cluster setup zfs-ha --start --enable nodeA nodeB

# second ring (if using aliases or a second NIC):
pcs cluster link add nodeA=<addr1> nodeB=<addr2>
pcs cluster config update transport link_mode=active   # use both links
```

`pcs cluster setup` with two nodes sets `two_node: 1` quorum automatically.
`link_mode=active` uses both links simultaneously (knet aggregates them);
`passive` keeps link 1 as a hot standby. Active is the better mirror of real
dual-NIC redundancy.

Verify: `pcs status` (both nodes online), `corosync-cfgtool -s` (all links
`connected`), `pcs quorum status` (Quorate: Yes, flags include `TwoNode`).

### Cockpit: HA Cluster Management

The Cockpit HA Cluster Management page does **not** auto-discover an
existing cluster - you must connect it manually:

1. Browse to `https://<node>:9090` and log in with a system account in the
   `wheel` group (root is in Cockpit's disallowed-users by default on
   Rocky 10).
2. Navigate to **HA Cluster Management** in the left menu.
3. Click **Add existing cluster**: node name = either node's IP, hacluster
   password = the one set during cluster setup, port 2224.
4. Click **Check authentication** - it must succeed before proceeding.

Before this works, pcsd authentication must be established on both nodes
(re-run if the nodes were rebooted):

```sh
echo '<hacluster-password>' | pcs host auth <nodeA> <nodeB> -u hacluster
pcs pcsd status    # both nodes must show Online
```

**What you'll see in the GUI, and what it means:**

- *No fencing configured / Stonith is not enabled* - expected until fencing
  is set up. Do not create the pool resource until fencing is configured
  and tested.
- *ha_pool (blocked)* - the resource failed to start and pacemaker has
  blocked further attempts. Common causes: a pool disk is missing (check
  `zfs-ha-quiesce status` and the expander phy states), or the MMP state on
  disk does not match this host. Fix the underlying issue, then
  `pcs resource cleanup ha_pool`.
- The GUI is good for: node status at a glance, watching a failover happen,
  moving a resource for planned maintenance, and reading the last failure
  reason without digging through logs. The CLI (`pcs`) is still what you
  use for anything nontrivial.

## 4. Pool creation

```sh
# Identify disks by WWN - NEVER /dev/sdX (enumeration differs per host
# and across boots).
ls -l /dev/disk/by-id/ | grep wwn

zpool create -o multihost=on -o cachefile=/etc/zfs/zpool.cachefile.ha <POOL> \
    /dev/disk/by-id/wwn-0x... /dev/disk/by-id/wwn-0x... ...
```

- `multihost=on` enables ZFS's own import-time protection (MMP) -
  supplementary to fencing, not a replacement.
- A **separate cachefile** keeps the HA pool out of the default
  `zpool.cachefile`, so boot-time auto-import won't grab it.

After creating the pool, record the authoritative config and generate the
boot-time quiesce rule. **Run this on the primary, then copy
`/etc/zfs-ha/pool.conf` to the peer** (scp it, or let your config
management do it) and set the per-host role:

```sh
# on the primary:
zfs-ha-poolconf write <POOL> --strategy <stp|sas|null> --fencing <none|pr|bmc|pdu|pikvm|sbd> \
    --role primary --peer <nodeB-name>
scp /etc/zfs-ha/pool.conf <nodeB>:/etc/zfs-ha/pool.conf

# on the secondary (after copying):
zfs-ha-poolconf write <POOL> --strategy <stp|sas|null> --fencing <none|pr|bmc|pdu|pikvm|sbd> \
    --role secondary --peer <nodeA-name>

# on both:
zfs-ha-udevrule generate && udevadm control --reload
```

`pool.conf` is the single source of truth for every tool. `role=` and
`peer=` are **required** - the resource agent runs `zfs-ha-role` on every
start, and it refuses (exit 2) without them.

> [!NOTE]
> **Role arbitration adds a delay to failover, by design.** On every pool
> start, `zfs-ha-role` checks the peer: a *secondary-role* host waits up to
> 180 s (`PEER_WAIT`, tunable via env) for the primary to come up before
> importing, so two hosts booting simultaneously don't race for the disks.
> That wait happens inside the pacemaker start action - keep the start
> timeout at 300 s or higher (the resource template already uses 300 s).
> A *primary-role* host starts immediately. If you want faster failovers
> and accept the simultaneous-boot race handled purely by pacemaker +
> fencing, lower `PEER_WAIT` (e.g. `PEER_WAIT=30 pcs resource ...` via the
> RA's environment is not supported - edit the default in
> `scripts/zfs-ha-role`).

> [!WARNING]
> `zpool create` can hang indefinitely on a shelf with marginal disks (it
> probes every disk's tail for labels). Run long zpool operations detached
> with output to a log (`nohup ... > /tmp/x.log 2>&1 &`) and poll the log -
> never let them block your shell or an SSH session, which kills them
> mid-write.

## 5. Boot-time import prevention + device quiesce

The HA pool must never be imported by initramfs/systemd at boot, and the
booting host must not probe the pool disks:

```sh
# keep the HA pool out of the default cache
zpool set cachefile=/etc/zfs/zpool.cachefile.ha <POOL>

# ensure the default import service doesn't scan for it
systemctl disable zfs-import-scan.service 2>/dev/null || true

# generate the udev quiesce rule (deletes HA devices on appearance)
zfs-ha-udevrule generate && udevadm control --reload
```

The udev rule is the primary defense: HA-pool devices are deleted the
instant they appear, before blkid/SMART/udev probes can touch them. The
allow-import flag (set by the RA during a deliberate import) permits devices
through when the cluster promotes this host.

Verify after a reboot: `zpool list` shows the HA pool **not imported** on
either node until Pacemaker starts it, `zfs-ha-quiesce status` shows 0/N
devices present, and `journalctl -t zfs-ha-udev` shows the deletions.
`check_boot_import <POOL>` runs the whole check for you (installed as `check_boot_import`).

Optionally, install the boot-time posture unit as a second layer (it
deletes all HA-pool devices before the ZFS import services run):

```sh
install -m644 configs/zfs-ha-posture.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable zfs-ha-posture.service
```

Why this matters so much: a host that boots while the peer owns the disks
gets I/O errors against them, and mpt3sas **drops the disks from discovery
entirely** ("sata affiliation conflict") - no sd node, no by-id link.
Recovery then needs a phy hard reset plus a host-level reset to trigger
rediscovery. Deleting the devices before anything probes them avoids the
whole mess.

## 6. Fencing (required before production)

See `docs/FENCING.md` for the full options discussion (BMC/IPMI, switched
PDU, PiKVM, SBD, and why SAS expander isolation is not fencing), and
§12.1c for the SCSI persistent reservation path. The rule: **do not create
the pool resource until fencing is configured and *tested*** (power a node
off via the fence agent and confirm the cluster recovers).

Minimum viable setups by hardware path:

```sh
# BMC-based (any hardware path; needs a BMC on an independent network)
pcs stonith create fence_a fence_ipmilan ip=<bmc_a> username=<u> password=<p> \
    lanplus=1 pcmk_host_list=nodeA op monitor interval=60s
pcs stonith create fence_b fence_ipmilan ip=<bmc_b> username=<u> password=<p> \
    lanplus=1 pcmk_host_list=nodeB op monitor interval=60s
pcs property set stonith-enabled=true

# SCSI persistent reservations (SAS disks or SATA behind interposers)
# - handled by the sas strategy + zfs-ha-pr; set fencing=pr in pool.conf.
#   A stonith resource is still recommended for power-level fencing.
```

Two-node specifics: `no-quorum-policy=stop`, and asymmetric fencing delays
(`pcmk_delay_max` 0s on the primary, 15s on the secondary) so a
simultaneous failure has a deterministic survivor.

## 7. Resources

```sh
pcs resource create ha_pool ocf:zfsha:Pool pool=<POOL> \
    op start timeout=300s op stop timeout=300s op monitor timeout=30s interval=30s
pcs resource create ha_vip ocf:heartbeat:IPaddr2 ip=<VIP> nic=<NIC> cidr_netmask=<mask>
pcs constraint colocation add ha_vip with ha_pool INFINITY
pcs constraint order start ha_pool then start ha_vip kind=Mandatory
pcs constraint order stop ha_vip then stop ha_pool
pcs resource defaults update resource-stickiness=200
```

The stop ordering is critical for sharenfs: the VIP must be DOWN before the
pool stops, so NFS clients see a connection drop (silently retried by hard
mounts) instead of ESTALE errors from the export vanishing while the VIP
still answers.

## 8. The handoff, step by step

What the Pool RA does on `start` (import) and `stop` (export), and what you
would do manually:

**Clean move (planned) - what the RA does automatically:**
1. Stop ha_vip (constraint ordering) - NFS/SMB clients see a connection drop.
2. `zfs unmount -a` + stop nfs-server - release sharenfs exports.
3. `zpool export` - quiesces I/O, flushes caches.
4. `zfs-ha-handoff quiesce` + `release` for each disk - deletes devices from
   the OS (anti-race) and releases transport access (SMP affiliation clear
   for `stp`, PR release for `sas`).
5. On the new owner: rescan + acquire - devices reappear (udev rule permits
   via allow-import flag), exclusivity evidence verified (affiliation clear
   or reservation held). If the previous owner had in-flight I/O, flush the
   stale queued commands manually per `docs/HANDBOFF.md` (`sg_reset -d` on
   each disk) before the import - a clean export means there is usually
   nothing to flush.
6. `zpool import -f` + start nfs-server - sharenfs exports follow.

**Crash of the owner (SAS stack wedged, host still powered):**
1. The expander still reports `affiliation valid: 1` for the dead owner's
   SAS address, and **clear-affiliation (op 6) is refused** - the owner's
   phys are still electrically up.
2. Recovery: **hard reset the disk phy** -
   `smp_phy_control --phy=<N> --op=2 /dev/bsg/expander-<h>:<id>`.
   This drops the disk's link, which releases the stale affiliation.
3. The survivor re-affiliates automatically on its first I/O; then flush
   the stale queued commands (`sg_reset -d` per disk), verify, and import.

**Power loss of the owner:**
1. The disk phys go down; the expander reports `STP I_T nexus loss occurred: 1`.
2. `zfs-ha-handoff release` (op 6 now succeeds - the link is gone).
3. `acquire`, import, verify.

**In every failure scenario, fencing still comes first.** The SMP operations
recover *storage access*; fencing establishes *exclusivity*. A wedged host
that still holds the VIP or serves cached data is not safe to take over from
until it is fenced.

## 9. Testing

Run the scenario matrix in `tests/` against a **test pool**:

| Scenario | What it proves |
|---|---|
| S1 clean move | export→release→import preserves acknowledged writes |
| S2 crash owner | stale affiliation + phy hard reset recovery |
| S3 power loss | nexus-loss detection + clean takeover |
| S4 network partition | quorum behavior under link loss |
| S5 stuck export | why fencing must precede takeover |
| S6 simultaneous boot | no auto-import; cluster decides ownership |

`tests/write_client.py` writes fsync'd records during the fault and verifies
afterward: contiguous sequence, no gaps, all hashes valid.

## 10. HA NFS

The `sharenfs` ZFS property handles NFS export failover with no separate
NFS resource agents - the export travels with the pool import/export:

```sh
zfs set sharenfs="rw=@<client-net>,sync,no_root_squash" <pool>/data
systemctl enable --now nfs-server   # on both nodes
```

The RA handles the rest: stop = unmount sharenfs datasets + stop
nfs-server + export; start = import + start nfs-server.

Measured cutover: **zero gaps > 2s** in a 1-record/second NFS client write
log across a failover - the kernel NFS client absorbs the cutover
gracefully. Use hard mounts (`hard,intr`) on clients; soft mounts will
return errors during the window.

Notes:

- NFSv4.1/4.2 over TCP. The grace/lock reclaim path works because the
  server identity (and the export) is stable across nodes - keep
  `/etc/idmapd.conf` identical on both.
- UID/GID mappings must match on both nodes (same users, or central
  identity). NFS does not carry ownership across a server that maps
  differently.
- Do not run NFS from both nodes at once for the same export; the pool is
  only imported on one, and sharenfs follows it.

## 11. HA Samba

Samba failover is the same pattern: the pool carries the share, the VIP
carries the address, and clients reconnect/reopen after a cutover.

```sh
# both nodes: identical /etc/samba/smb.conf
dnf install -y samba

cat > /etc/samba/smb.conf <<'EOF'
[global]
    workgroup = WORKGROUP
    server string = zfs-ha
    security = user
    map to guest = Bad User
    server min protocol = SMB2

[pool]
    path = /<POOL>/data
    browseable = yes
    writable = yes
EOF

# the share path lives on the pool, so it only exists when the pool is
# imported - which is exactly when this node is the active server.
systemctl enable --now smb nmb
```

Put `smb` into the resource ordering so it starts with the pool and stops
before the export:

```sh
pcs resource create ha_smb systemd:smb
pcs constraint order start ha_pool then start ha_smb kind=Mandatory
pcs constraint order stop ha_smb then stop ha_pool
pcs constraint colocation add ha_smb with ha_pool INFINITY
```

Honest limitations, so you know what you're buying:

- **Client recovery is reconnect/reopen, not transparent.** Open handles do
  not survive the cutover. Upstream Samba's durable handles are in-memory
  and do not survive a server switch; cross-host persistent-handle /
  continuous-availability machinery (the stuff a real clustered Samba or a
  commercial NAS does) is out of scope here. Files that were closed are
  fine; an application holding a file open across the cutover will see the
  handle die and must reopen.
- **Locking state does not transfer.** SMB byte-range locks are dropped at
  cutover. For homelab workloads (media, backups, bulk storage) this is a
  non-issue; for a database file it would be.
- **Credentials/state**: use identical user accounts (or winbind/SSSD
  against the same backend) on both nodes so the SID mapping is stable.
  Keep `smbpasswd` entries in sync.
- If you want SMB with RDMA (SMB Direct), `ksmbd` is the kernel server that
  supports it; the same pool/VIP pattern applies, but validate the floating
  IP behavior with your actual RDMA NIC/driver first - a shared MAC does not
  preserve RDMA sessions either.
- NFS and Samba can both serve the same pool, but **not coherently** - there
  is no cross-protocol locking. Pick one protocol per dataset.

## 12. Hardware setup: the three paths

This is the decision that shapes everything else. The `stp` path and the
controlled cutover protocol are fully validated (see `docs/VALIDATION.md`);
the `sas`/PR path is live-verified end to end (VALIDATION.md V11), though
the full pacemaker-driven failover matrix for it is still pending (V11
caveat, V13); the `null` path is designed, not validated. They are not
equally proven, and the docs say which is which.

### 12.1 SAS + interposers - the best setup (recommended)

SATA disks behind *working* SAS interposers present as dual-port SAS: no
affiliation dance, SCSI persistent reservation fencing, multipath. This is
what I recommend for a new build.

**Recommended cabling: one host per controller.**

```
host A ──────────── controller A ──┐
                                   ├── shared disks
host B ──────────── controller B ──┘
```

With this topology:

- each host sees each physical disk **exactly once** - no multipath needed,
  no same-disk-twice hazard, no dm layer between ZFS and the disk
- both hosts still reach every disk (through their own controller), so
  failover works: the acquiring host simply talks to the disk via its
  controller
- the controllers arbitrate the fabric; a disk is reachable through either
  controller, but each initiator port has one path

**We experimented with both hosts connected to both controllers** (each
host dual-cabled). That works, but it makes multipath a concern: every
physical disk appears twice per host (two sd devices, two SAS port
addresses, one WWN), which is the single biggest source of "why do I see 10
disks for 5 bays" confusion and is dangerous - handing ZFS the same
physical disk twice silently corrupts the pool. **We do not recommend this
topology.** If you must dual-cable (e.g. to survive a controller failure
without failing over the whole host), §12.1b is mandatory.

With the recommended topology, set in pool.conf:

```ini
strategy=sas
fencing=pr
```

and the `sas` strategy handles everything: register + reserve on start,
release on stop, preempt on fenced takeover. ZFS uses plain
`/dev/disk/by-id/` paths - no multipath, no partitions needed.

#### 12.1b Multipath (only for the dual-cabled topology)

Configure device-mapper multipath to collapse each disk to one dm map:

```sh
mpathconf --enable
cat > /etc/multipath.conf <<'EOF'
defaults {
	user_friendly_names yes
	find_multipaths on
}
blacklist {
	# only multipath the shelf disks; everything else stays single-path
	wwid .*
}
blacklist_exceptions {
	# one WWN per shelf disk (scsi-350000c9... by-id, no leading 3)
	wwid 350000c9000385e04
	wwid 350000c90005793e8
	wwid 350000c90003fc194
	wwid 350000c900043ce30
	wwid 350000c9000331cbc
}
EOF
systemctl enable --now multipathd
multipath -ll        # one mpathX per disk, active+enabled paths
```

Notes validated on the reference shelf:

- `find_multipaths on` + explicit `blacklist_exceptions` is the safest
  combination: the OS disk, SATA SSDs and anything not listed never gets a
  dm map.
- ZFS must then use **`/dev/mapper/mpathX`** paths (or `mpathXp1` for
  partitions). Do NOT mix `/dev/sd*` and `/dev/mapper/*` for the same disk.
- multipathd does not auto-create partition maps on all distros. After
  partitioning, run `kpartx -a /dev/mapper/mpathX` (or restart multipathd)
  so `mpathXp1` appears.
- If a host is cabled to only ONE controller (the recommended topology),
  it sees each disk once and multipath does not apply at all - skip this
  section entirely.

#### 12.1c Fencing with SCSI persistent reservations (fencing=pr)

Real SAS disks on a dual-controller shelf have **no transport exclusivity**:
both hosts can always issue I/O regardless of cabling. The SAS best practice
is to let **the disk itself** enforce single ownership with persistent
reservations:

- every host REGISTERS a unique 64-bit key with each disk
- the owner holds a RESERVATION (type 5 = Write Exclusive, Registrants Only)
- every WRITE from a non-registrant gets `RESERVATION CONFLICT` at the
  drive firmware level - independent of both operating systems

`zfs-ha-pr` implements this (installed by `make install`):

```sh
zfs-ha-pr key                        # this host's key (stable: 0x5a17+md5(host))
zfs-ha-pr reserve  <by-id>           # register + take the reservation
zfs-ha-pr held    <by-id>            # rc=0 if we hold it
zfs-ha-pr status  <by-id>            # who is registered / who holds
zfs-ha-pr release <by-id>            # planned handoff: drop reservation
zfs-ha-pr preempt <by-id> <victim-key>   # FENCED takeover from a dead owner
```

Live-verified on the reference shelf (VALIDATION.md V11); the full
pacemaker-driven failover matrix (preempt on dead owner, reservation
surviving controller path failover) is still pending (V11 caveat, V13):

- Peer reads succeed while the owner holds the reservation (type 5 allows
  reads); peer writes fail with `reservation conflict` in dmesg and ZFS
  faults the vdev with "too many errors" if you import anyway. That is the
  fencing working - clear the reservation before acquiring, or preempt.
- **Live-verified end to end (2026-10-23):** reserve on host A → peer's
  `dd oflag=direct` write fails with `Invalid exchange` (reservation
  conflict at drive firmware, visible as `reservation conflict error` in
  dmesg) → release on A → peer write succeeds again. The full
  register/reserve/held/status/release cycle works through the
  dual-controller shelf.
- **Gotcha: `PR generation=0xNN` looks like a key.** `sg_persist -k`
  output's generation line matches a naive `0x...` grep, which sent
  `zfs-ha-pr register` down the replace-existing-key path (refused by this
  shelf). Fixed in the tool; if you roll your own parsing, exclude the
  generation line.
- **Shelf quirk (DS460C + interposers):** `REGISTER` with `--param-sark`
  (replace existing key) fails with a conflict while any reservation
  exists. `zfs-ha-pr reserve` handles this by falling back to
  `clear -> register(0) -> reserve`. `release` tolerates a failed
  de-register (a stale registration is harmless).
- Reservations survive controller path failover: the reservation is a
  property of the LU, not the path.

### 12.2 Interposer quality: Emulex vs LSI

SATA disks in a SAS shelf sit behind interposers (SATA-to-SAS bridges).
Bad interposers are the #1 source of "flaky shelf" symptoms. Fast triage:

```sh
cat /sys/block/sdX/device/sas_address   # fabricated OUI = bad interposer
smartctl -i /dev/sdX | grep -i serial   # masked serial = bad interposer
dd if=/dev/sdX of=/dev/null bs=1M count=1024 iflag=direct   # speed test
```

| Symptom | Good interposer | Bad interposer |
|---|---|---|
| SAS address | real drive OUI (e.g. `0x50000c9...` for WD) | fabricated (`0x500605ba...` on the reference shelf) |
| Serial number | passes through | masked/empty |
| Sequential read | 140-160 MB/s | starts OK then collapses to <2 MB/s |
| dmesg | clean | storms of `Power-on or device reset occurred` |
| Tail sectors | readable | slow/timeouts (interposer metadata zone) |

In my testing, **Emulex interposers worked and LSI ones did not.** A disk
that reads 150 MB/s cold then drops to kB/s under sustained load is an
interposer problem, not a disk problem. Replace the interposer (or move the
disk to a known-good caddy) and re-test before blaming the drive.

### 12.3 Plain SATA, single controller - the controlled-cutover path

Plain SATA disks (no interposers) have **no transport-level release**.
There is no affiliation to drop and, without PR support, no disk-side lock.
The only thing a host controls is **its own OS device view**.

Setup: **one controller cabled to one host, the other controller
unplugged** (or cabled to the other host - but only one host talks to the
disks at a time either way, and with a single active path per host this is
the same picture as §12.1 with the interposers removed). The shelf enforces
single-initiator access at the expander level if it does affiliation at
all; if it does not, the OS device view is all you have.

For this class of hardware the project provides a **controlled cutover
protocol** (`zfs-ha-cutover`): a deliberate, ordered release/acquire with
settle delays, used when BOTH hosts are healthy (planned maintenance, load
migration). It is NOT an emergency-failover tool - if the owner is dead or
wedged, use the fencing path instead.

**The protocol** - owner (`zfs-ha-cutover release`):

1. preflight: peer reachable via ping+ssh, pool healthy here, peer does
   NOT have the pool imported (hard stop otherwise)
2. `zfs unmount -a` + stop nfs-server (data path down first)
3. `zpool export` (clean labels, MMP release)
4. quiesce each disk: delete the sd device from OUR kernel, **with a
   settle delay per disk** (default 2s). Deleting all at once races the
   peer's scan: the peer can re-attach devices to the wrong host (observed
   on the reference shelf).
5. write a `released` marker to `/run/zfs-ha/cutover.state`
6. final settle + `udevadm settle`

Peer (`zfs-ha-cutover acquire`):

1. preflight: peer reachable, pool NOT imported locally, peer pool empty
2. confirm the peer's `released` marker (corroborating evidence - the
   protocol continues on peer-pool-empty alone, but logs a warning)
3. rescan each missing disk (host scan + settle, 3 attempts)
4. **verify ALL disks present - a planned cutover never imports partial**
5. `zpool import`, mount, start nfs-server

Usage:

```sh
# on the current owner
zfs-ha-cutover status        # shows both sides' view; check before acting
zfs-ha-cutover release

# on the peer
ZFS_HA_PEER=<owner-ip> zfs-ha-cutover acquire
```

Tunables (env): `ZFS_HA_SETTLE` (per-disk settle seconds, default 2),
`ZFS_HA_QUIESCE=0` to skip device deletion (export-only cutover),
`ZFS_HA_PEER_USER` (ssh user, default `w`). Requirements: passwordless ssh
between the hosts for the configured user.

Validated: three consecutive full round-trips of the 4x3TB raidz1 pool
between the two hosts, each direction verified with data written on one
host and read on the other. Total cutover time ~30-40 s per direction
(dominated by the settle delays; deliberately conservative). Also
validated live under pacemaker: a `pcs resource move` cutover with the
pool data verified intact on the new owner afterwards (marker file
written pre-move read back byte-identical post-move).

**One mailbox SAS disk helps clustering here.** A dedicated SAS disk
(dual-port, no STP affiliation) visible to both hosts can act as a
"mailbox": each host writes a heartbeat record to its own slot; each host
reads the peer's slot. A peer that stops refreshing its slot is
presumed dead-or-wedged - **corroborating** evidence, never sole proof.
`zfs-ha-mailbox` implements this, and `zfs-ha-amialone` consumes it as one
signal among several (corosync link state, carrier state, mailbox
freshness, peer storage activity, BMC power readback - a decision is only
made when multiple signals agree). The mailbox disk is itself a single
point of failure, which is exactly why it is never a sole dependency. Even
on a plain-SATA shelf, adding one SAS disk for the mailbox is worth it.

Setup (both hosts, after the disk is visible to both):

```sh
# once, from either host - records the mailbox device and node names in
# pool.conf (the node names make slot assignment deterministic):
zfs-ha-mailbox init /dev/disk/by-id/scsi-35000c9... <nodeA-name> <nodeB-name>

# heartbeat, every 2-5s (a systemd timer or a cron line):
zfs-ha-mailbox beat
zfs-ha-mailbox read       # dump both slots; peer slot age is the signal
```

`zfs-ha-amialone` also reads optional keys from pool.conf that enable its
carrier and BMC signals (all optional; the gate abstains on signals it
cannot read):

```ini
interface=enp1s0            # NIC whose carrier state is checked
peer_sas_addr=0x500605b0... # peer HBA SAS address (affiliation signal)
peer_bmc=10.x.x.x           # peer BMC (the only death proof)
peer_bmc_user=...
peer_bmc_pass=...           # pool.conf is mode 600 for this reason
```

## 13. Witness (qnetd) and two-node quorum

A two-node cluster has a fundamental problem: when the nodes lose contact
with each other, **neither** can know whether the other is dead. Corosync
solves the arithmetic with a third vote:

- **Without a witness** (default): `two_node: 1` + `wait_for_all` semantics.
  Both nodes together are quorate; a partitioned single node is not, and
  stops its resources (`no-quorum-policy=stop`). Safe, but a network
  partition stops *both* sides until contact is restored.
- **With a qnetd witness**: a tiny third arbiter (it runs nothing but the
  quorum algorithm) gives one side a majority during a partition, so the
  healthy side keeps running and only the loser side stops. Technically
  better in every way that matters.

The witness is cheap: a Raspberry Pi, an LXC container, any always-on
little box on a network path independent of the storage network.

```sh
# on the witness host:
dnf install -y corosync-qnetd
systemctl enable --now corosync-qnetd

# on a cluster node:
pcs qdevice setup model net --enable --start
pcs quorum device add model net host <witness-host> algorithm lms
pcs quorum status   # should show the qdevice
```

> [!IMPORTANT]
> A qnetd witness participates in **quorum arbitration** - it is not an
> NFS/SMB health-check VM, and it is not a "monitoring" node. External
> service probes are a separate monitoring/testing function. The witness
> votes on who may run resources; it knows nothing about your data.

With three votes you can drop `two_node` semantics, but keep fencing:
quorum decides *who may run*, fencing decides *who is safe to run*. They
are different questions and you need both answered.

## 14. Operations

- **Planned maintenance**: `pcs resource move ha_pool` (or `standby` the
  node) - the RA does export → release; the other node acquires and
  imports. Disable automatic failback; move the pool back deliberately.
- **Kernel updates**: update one node at a time; move resources off first.
  Keep ZFS versions identical across nodes (pool feature flags must match).
- **Adding disks**: create the pool with all disks it will ever need, or
  add vdevs while both hosts can see the new disks (they will - the shelf
  is shared). Never split a pool across shelves.
- **Monitoring**: `zpool status -x`, `pcs status`, `corosync-cfgtool -s`,
  SES enclosure health (`utils/shelf-health.py`), and the topology
  (`utils/sas_topology.sh`) when a disk misbehaves.

## 15. Field notes for anyone attempting this (hard-won)

These are the failure modes and traps encountered during the reference
implementation that cost the most time. Read before your first cutover.

**Hardware / shelf**

- *Disks vanish and never come back.* A disk whose link negotiates but
  never spawns an end_device (phy shows a rate, `lsblk` shows nothing) is
  a dead drive, dead interposer, or dead bay. Host-side resets
  (`hard_reset`, `link_reset`, phy enable/disable, host scans) do NOT
  recover it - stop after 2-3 attempts and reseat the disk physically.
  The reference build lost four disks this way across the session; every
  one recovered only after a physical reseat or shelf power-cycle.
- *One bad disk can wedge the whole host.* A SUSPENDED pool with a
  missing member leaves `zpool` processes in D-state that survive SIGKILL.
  If `pgrep zpool` shows stuck processes and `zpool clear` hangs, the only
  clean fix is a host restart. Restarting is safe: pools with valid labels
  auto-import, and the D-state processes die with the kernel.
- *Restarts re-enumerate everything.* Device names (sdX) shuffle on every
  restart and every cutover. Never hardcode sdX anywhere - by-id paths in
  pool.conf only.
- *Reseat disks one at a time and re-inventory after each.* Serials and
  bay positions are the only reliable identity; `lsblk -o NAME,SIZE,
  MODEL,SERIAL` after each change.
- *Marginal shelves eat disks.* Budget for this when buying used hardware.

**ZFS / pool operations**

- *`zpool create` can hang indefinitely* on a shelf with marginal disks.
  Always run long zpool operations detached with output to a log and poll
  the log - never let them block your shell or an SSH session.
- *`zpool labelclear` fails on disks with truncated/corrupt labels*
  ("failed to unpack label"). Zero the first and last 1-2 MB with dd
  instead, then `wipefs -a`.
- *Old GPT backup headers resurrect stale partition tables.* If
  `partprobe` says "backup GPT table is corrupt", the on-disk table is
  fine but the kernel cache is stale - zero the last 34 sectors, rewrite
  the table, `partprobe`, and verify with `sfdisk -l` (not `lsblk`,
  which can show a cached view).
- *`zdb -l /dev/sdX` fails on whole disks when the pool lives in a
  partition* - the labels are in `sdX1`. This is normal, not corruption.
- *MMP suspension after a cutover is expected.* `zpool clear` resumes it
  once you have confirmed sole ownership. Setting
  `zfs_multihost_fail_intervals=0` disables the suspension entirely but
  also disables the split-brain backstop - not recommended.
- *A SUSPENDED pool with its devices deleted underneath it is the worst
  state.* If the pool suspends and the devices then disappear (quiesce,
  udev rule, peer takeover), `zpool export` and `zpool clear` wedge in
  D-state waiting on a txg sync to vdevs that no longer exist. `kill -9`
  does nothing to D-state processes. Every subsequent `zpool` command on
  the host hangs behind them. The only clean fix is a host restart - do
  not burn an hour trying to unwedge it (measured: 37 minutes of D-state
  before giving in). This is why the RA must never quiesce devices before
  a SUSPENDED pool is resolved, and why fencing escalation on a failed
  stop matters.
- *MMP suspend deadlock after a failed import.* If an import suspends
  (MMP writes failed during disk settle), the importing host cannot export
  or clear, and its kernel keeps retrying MMP writes - which re-affiliates
  the disks, blocking the other host's import in D-state. The deadlock
  breaker: the host whose MMP state matches the on-disk state imports
  cleanly, then exports cleanly, resetting the MMP chain; the other host
  can then import. If neither can proceed, power-cycle the importing host.

**Multipath (dual-cabled hosts only)**

- *multipathd hides partitions.* After partitioning an mpath device, run
  `kpartx -a /dev/mapper/mpathX` or the `mpathXp1` nodes never appear and
  `zpool import` finds nothing.
- *A leftover PR reservation makes the peer's import come up DEGRADED
  with "too many errors".* That is fencing working correctly. Release the
  reservation on the old owner, then `zpool clear` on the new owner.

**Operational discipline**

- *Passwordless SSH between hosts is a hard requirement* for the cutover
  tooling - and note that sshd's per-source penalty (OpenSSH 9.8+) will
  temporarily block a host after repeated failed auths. Use an explicit
  `user@host`, and never let scripts hammer ssh with bad credentials.
- *Check `zfs-ha-cutover status` before every release/acquire.* It shows
  both sides' view; if the peer is UNREACHABLE or already has the pool,
  stop and investigate - do not force.
- *Do not loop.* If a recovery attempt fails twice or three times, the
  cause is almost always physical. Escalate to hands-on instead of
  repeating the same command.
