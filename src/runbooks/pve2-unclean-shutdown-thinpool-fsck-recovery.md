---
title: "pve2 unclean shutdown — thin-pool + guest fsck recovery"
tags:
  - runbook
  - proxmox
  - pve2
  - lvm
  - thin-pool
  - fsck
  - containerd
  - corruption
---

# pve2 Unclean Shutdown → LVM Thin-Pool Repair → Guest Filesystem / Container-Layer Recovery

**Service:** Proxmox hypervisor pve2 (hosts all pvek8s node VMs, all Jiva replicas/controllers, dqlite, 3 Wazuh VMs)
**First observed:** 2026-09-26/27 (pve2 host wedge → forced power cycle)
**PIR:** [pve2 RAID5 Degradation, Host Wedge, and Cascading Filesystem Corruption](../incidents/2026-09-26-pve2-raid-degradation-cascading-corruption.md)

---

## Symptom

pve2 (or any single-hypervisor host backing multiple guest VMs via one LVM thin pool) is forced through a hard power cycle — either because the host wedged (ssh/management daemons dead, console unresponsive, but guests still running) or a genuine power loss — **while guest VMs were not shut down cleanly first**. On boot:

- The boot sequence drops to initramfs: `Check of pool pve/data failed (status:1). Manual repair required!`
- The **host's own root filesystem** may also need repair (`fsck exit 4`, orphan inode list corruption)
- Once the host root is up, the LVM thin pool backing guest disks shows **inactive**:
  ```
  lvs pve/data
  # LSize   Attr
  # 838.36g twi---tz--   <-- no 'a' (active); pvestatd retries activation every ~15s
  ```
- Guest VMs will not start (`start failed: volume group "pve" not found` / LV not active)
- After the pool is repaired and guests boot, **individual guests may show ext4 errors**, and **container runtimes on any k8s guest may show corrupted image layers, corrupted content-store blobs, or zeroed system files** — the corruption is not confined to one layer of the stack.

---

## Root Cause

An unclean power cycle catches the LVM thin pool's own metadata (`_tmeta`) mid-update, exactly like an unclean shutdown catches a guest filesystem's journal mid-write — except the pool sits **below** every guest, so its repair can discard writes across **every VM simultaneously**, and the guests have no way to know it happened.

**Full cascade (2026-09-26/27):**

1. pve2 userland (ssh, NRPE, pveproxy) stopped responding at 17:58 AEST while guest VMs kept running normally — a **host wedge**, not a crash. No correlated hardware event appeared in the RAID controller or server IML; the trigger for the wedge itself was never identified (see the PIR's Chain 2 — this is an open, unresolved question).
2. After ~14.5 hours with no recovery and the console dead (blinking cursor, keyboard unresponsive), the only remaining option was a **forced power cycle**. Guest VMs were shut down as gracefully as SSH still allowed immediately beforehand, but the **host itself** — and therefore the thin pool underneath every guest disk — was not.
3. On boot, both the host's own root filesystem and the `pve/data` thin pool needed repair. The pool repair (`lvconvert --repair`) rebuilds `_tmeta` from its `pmspare` copy at the pool's **last durable commit** — anything written after that commit and before the power cut is gone, with no fsck-visible trace. This incident lost ~8 GB across two guests (3.6 GB, 5.1 GB) this way.
4. Above the now-rolled-back pool, every guest's own filesystem needs its own fsck, because the guest's last known-good state (from its own journal's point of view) may still reference blocks the pool repair discarded.
5. On a Kubernetes node guest specifically, container image layers and the containerd content store are just more files on that same rolled-back/corrupted filesystem — they get exactly the same silent damage, and it surfaces as crash-looping pods with binary-execution errors (`Exec format error`, missing symbols) long after the host and pool both look healthy again.

---

## Detection

There is no dedicated alert for this — it is diagnosed by hand, in order, once a wedge/power-cycle is known to have happened. Do not assume any single check below is sufficient; each layer can be clean while the one below or above it is not.

```bash
# 1. Is the thin pool active?
ssh pve2 "lvs -a pve"
# twi---tz-- (no 'a') = inactive, needs repair before any guest can start

# 2. Once active — check container-runtime health on any k8s guest that
#    was running at power-cycle time (see Phase 4 below for the full audit)
```

---

## Recovery

### Phase 0: Do not touch the array/pool until the host root fs is sane

If the boot dropped to initramfs on the **host's own** root pool, resolve that first (`fsck -y` on the flagged LV) and confirm clean re-mount before going near `pve/data`. Note any **medium/read errors surfaced during this fsck** — on 2026-09-27 the host root fsck itself hit a critical medium error on the underlying array (a genuinely bad sector), which the fsck rewrite remapped. That is evidence about the array's health, not just the filesystem's, and belongs in the incident record.

### Phase 1: Stop retries, snapshot state, repair the pool

The pool being inactive triggers `pvestatd` to retry activation roughly every 15 seconds; each retry spawns a `thin_check` against the metadata LV, which is extra read load on an array that may itself be degraded. Stop that first.

```bash
ssh pve2 "systemctl stop pvestatd"
ssh pve2 "vgcfgbackup -f /root/pve-vg-\$(date +%Y%m%d) pve"

# Exactly ONE repair attempt. Repeated blind attempts against already-rebuilt
# metadata is how you turn a recoverable rollback into a destroyed pool.
ssh pve2 "lvconvert --repair --yes pve/data 2>&1 | tee /root/lvconvert-repair-\$(date +%Y%m%d).log; echo EXIT=\$?"

ssh pve2 "vgchange -ay pve"
ssh pve2 "lvs -a pve"   # pool and every guest LV should now show 'a' active
```

`lvconvert --repair` keeps the pre-repair metadata as `pve/data_meta0` — do not remove it until the whole cluster has been verified stable (this incident kept it for the duration of the drive-replacement program, several days).

**Quantify what was lost.** Compare each guest LV's `Data%` before/after against your last known-good baseline (Nagios perfdata, or a pre-incident `lvs -a` capture). A guest whose `Data%` dropped is one whose most recent writes were rolled back — that guest needs an ordered fsck (Phase 3), and the drop in GB is your minimum data-loss figure for the incident record, even though no single file will show as "missing" by name.

### Phase 2: Read-only triage of every guest before writing anything

Do not boot a guest and let its own kernel `fsck -fy` decide unsupervised — take a read-only look first so you know the blast radius, and take a rollback point before any guest's fsck runs with `-y`.

```bash
ssh pve2 "losetup -fr --show /dev/pve/vm-<ID>-disk-0"
LOOP=/dev/loopN   # from above
ssh pve2 "kpartx -a -r $LOOP"   # if the disk has partitions; adjust mapper path accordingly
ssh pve2 "e2fsck -fn /dev/mapper/loopNp<partition>"   # dry run, writes nothing
```

Read the dry-run output for: journal replay errors landing at a specific timestamp (compare against the wedge/power-cut window — errors *before* that window are old and unrelated), invalid extents, corrupted directories, and — on a k8s node guest specifically — where the damaged inodes actually live (`debugfs -R 'ncheck <inode>' <dev>`). Damage concentrated in `/var/lib/containerd/.../snapshots/*` or Jiva's `/var/openebs/local/*` is expected and has its own recovery path (Phase 4); damage in `/etc`, `/usr/bin`, or `/var/lib/dpkg` is a different, more serious class (Phase 5).

### Phase 3: Guest fsck, with a rollback point per guest

```bash
ssh pve2 "lvcreate -s -n vm-<ID>-prefsck pve/vm-<ID>-disk-0"   # keep until the whole cluster is verified
ssh pve2 "e2fsck -fy /dev/pve/vm-<ID>-disk-0"
ssh pve2 "e2fsck -fn /dev/pve/vm-<ID>-disk-0"   # confirm clean, exit 0
```

Anything `e2fsck -fy` moves goes to that guest's own `lost+found` — do not assume it's safe to ignore just because the fsck exit code is now clean. On this incident the heaviest-hit guest put over a thousand directories into `lost+found`, almost all of them stale containerd overlayfs image-layer content, which is safe to discard (Phase 4 re-pulls it); a smaller guest's `lost+found` included live Jiva replica snapshot images, which is not safe to discard and needs the replica wipe-and-resync path instead ([jiva-replica-corrupt-snapshot-chain.md](jiva-replica-corrupt-snapshot-chain.md)).

Boot the guests **together**, not one at a time, if they form a quorum-based cluster underneath (dqlite, in pvek8s's case) — starting them separately risks one node reaching a stale quorum decision alone.

### Phase 4: Post-boot integrity audit on every k8s guest

Do this even if every guest reports "Ready" and no pod is crash-looping yet — several of this incident's corruption instances (a corrupted microk8s snap, containerd content-store blobs, unpacked image layers) only surfaced once something tried to actually read the damaged bytes, sometimes hours later during app restore.

```bash
# microk8s snap integrity (compares against its own signed assertion)
sudo snap verify --root-hash microk8s
# or, per-node: try `containerd images check`-style access; a snap-mount
# I/O error on any file inside it means the whole snap needs replacing —
# copy a byte-identical .snap from an unaffected node if one exists and
# its hash is in the local signed assertions store, rather than
# re-downloading (faster, and works with no internet egress).

# Full containerd content-store blob rehash — the only way to find silent
# corruption that hasn't been read yet
for d in $(sudo ctr -n k8s.io content ls -q); do
  sudo ctr -n k8s.io content get "$d" 2>/dev/null | sha256sum | grep -q "${d#sha256:}" \
    || echo "CORRUPT: $d"
done

# dpkg-level file integrity — catches zeroed/truncated system files that
# don't crash anything until the specific binary or config is used
sudo dpkg -V 2>&1 | awk '$1 ~ /..5/'   # md5 mismatch specifically; ignore ..c.. (conffile edits)
```

Any corrupt blob found: `ctr -n k8s.io images rm --sync <every ref pointing at it>`, then let the workload re-pull. Any corrupt **unpacked** layer (a pod crash-looping with `Exec format error` or a missing symbol, on an image that pulled successfully) needs the same treatment — the pull succeeding tells you the blob is fine, not that the unpacked snapshot is.

### Phase 5: Zeroed or corrupted system files

Look for whole files that read back as all-NUL bytes — this incident hit `/etc/sudoers` on one node (used by kubelite via `sudo`, so the daemon simply died with no useful log line) and several core libraries plus `/var/lib/dpkg/status` on a non-Kubernetes guest (killed `python3`, `apt`, and every NRPE check that depended on them).

```bash
# A file that is entirely NUL bytes is unambiguous — but don't rely on a
# shell command-substitution scan alone: `$(...)` strips a trailing lone
# newline, which makes files that legitimately START with a blank line
# (sshd_config, sysctl.d/*, /etc/legal) look zeroed when they are not.
# Verify any hit with a byte-level read before acting:
od -An -tx1 /path/to/file | awk '{for(i=1;i<=NF;i++) if($i!="00") f=1} END{exit !f}' \
  || echo "GENUINELY ALL-NUL: /path/to/file"
```

Fix by copying the identical file from an unaffected node in the same fleet (verify md5/sha256 match first) or `apt --reinstall` the owning package. If the damage is broad enough that no clean-file source exists in the fleet (this incident's Wazuh-Server guest: multiple core libraries plus the dpkg database itself), **stop trying to hand-repair it and restore the whole guest from the last known-good backup** instead — chasing individual zeroed files at that point costs more time than a restore and still leaves you unsure what else is silently damaged.

---

## Prevention

- **Root-cause the host wedge itself** — this runbook exists because a wedge happened and had to be forced through a power cycle; it does not prevent the wedge. See the open action item on the source PIR.
- **Never treat a "host guests are fine, only ssh/console are dead" wedge as low-severity** — it is exactly the situation that ends in an unclean power cycle once patience runs out, and the guests' apparent health gives no warning that the pool underneath them is about to be rolled back.
- Keep the `_meta0`/`prefsck` snapshots from any prior repair until the fleet has been stable for a full settle window — they are the only rollback point if a later step turns out to have missed damage.
- After any repair of this kind, run the Phase 4 audit even on guests that show no symptoms — several corruption instances in this incident were silent until something specific touched the damaged bytes days into the recovery.

---

## References

- PIR: [pve2 RAID5 Degradation, Host Wedge, and Cascading Filesystem Corruption](../incidents/2026-09-26-pve2-raid-degradation-cascading-corruption.md) — Chain 2
- Related: [jiva-replica-corrupt-snapshot-chain.md](jiva-replica-corrupt-snapshot-chain.md) — recovery for Jiva replica data caught by Phase 3/4 of this runbook
- Related: [jiva-volume-ext4-corruption.md](jiva-volume-ext4-corruption.md)
- Issue: [pgmac-net/homelabia#186](https://github.com/pgmac-net/homelabia/issues/186), [#187](https://github.com/pgmac-net/homelabia/issues/187) — the pve2 RAID5 degradation that made backups (the trigger for this incident) unsafe in the first place
