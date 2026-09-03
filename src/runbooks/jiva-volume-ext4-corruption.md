---
title: "Jiva volume ext4 corruption after unclean shutdown"
tags:
  - runbook
  - openebs
  - jiva
  - storage
  - ext4
  - sqlite
  - microk8s
---

# Jiva Volume ext4 Corruption After an Unclean Shutdown

**Service:** openebs-jiva-csi (pvek8s)
**First observed:** 2026-09-03
**PIR:** [pvek8s Total Control Plane Loss — systemd +esm4 PID 1 Segfault](../incidents/2026-09-02-systemd-esm4-pid1-segfault-control-plane-loss.md)

---

## Symptom

After a node crash, hard reset, or a `sysrq` reboot, one of two things happens to a Jiva-backed volume:

**Loud — the volume will not mount.** The pod sits in `ContainerCreating` and the kubelet logs:

```
MountVolume.MountDevice failed for volume "pvc-<id>" : rpc error: code = Internal
desc = 'fsck' found errors on device /dev/disk/by-path/ip-...-lun-0 but could not correct them:
/dev/sdX: Superblock needs_recovery flag is clear, but journal has data.
/dev/sdX: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.
```

**Quiet — the volume mounts and the app runs on damaged storage.** The CSI driver's `fsck -a` passes mild damage, so nothing complains, but:

```
EXT4-fs error (device sdX): ext4_find_extent:968: inode #NN: comm <App>:
  pblk NNNNN bad header/extent: invalid magic ...
```

and the application may report what looks like database corruption but is really a storage fault:

```
SQLiteException: disk I/O error        (SQLite IoErr code 10)
CorruptDatabaseException: Database file: /config/<app>.db is corrupt
```

> The quiet case is the dangerous one. It will not surface on its own — sweep for it after every node event.

---

## Root Cause

`kubelite` hosts the kubelet, so when it dies the kubelet dies with it — but `containerd` keeps running. Containers therefore continue **writing** to Jiva-backed ext4 with nothing supervising them, while Kubernetes considers the node `NotReady` and its pods gone. Those writes are still in flight when the node is rebooted.

`sysrq s` + `u` protects the *node's own* filesystems. It does nothing for iSCSI-attached Jiva volumes whose writers are unsupervised containers, so ext4 metadata on those volumes can be left inconsistent: dirty journals, bad extent-tree headers, wrong `i_blocks`, multiply-claimed blocks.

The Jiva CSI driver runs `fsck -a` before mounting. `fsck -a` deliberately refuses to act on a dirty journal or structural inconsistency (hence the loud case), but passes milder accounting damage (hence the quiet case).

---

## Detection

Sweep **every** volume on **every** node after a node event:

```bash
for h in k8s01 k8s02 k8s03; do
  echo "=== $h ==="
  ssh $h 'for d in $(ls /dev/disk/by-path/*iscsi*openebs* 2>/dev/null); do
      dev=$(readlink -f "$d")
      pv=$(echo "$d" | grep -o "pvc-[a-f0-9-]*" | head -1)
      st=$(sudo dumpe2fs -h "$dev" 2>/dev/null | grep -i "^Filesystem state" | sed "s/.*: *//")
      printf "  %-42s %-9s %s\n" "$pv" "$dev" "$st"
    done
    echo -n "  EXT4 errors in dmesg: "; sudo dmesg -T 2>/dev/null | grep -c "EXT4-fs error"'
done
```

Anything reporting `clean with errors` needs repair, whether or not its application is currently working. A non-zero `EXT4-fs error` count names the affected device.

---

## Recovery

The volume must be **unmounted** to repair it. `e2fsck` on a mounted filesystem will corrupt it.

### Step 1 — Stop the workload, working around ArgoCD

ArgoCD `selfHeal` reverts `kubectl scale` within ~1 minute, and patching the child Application's `syncPolicy` is undone by the app-of-apps parent. Suspend **both**, recording the originals first:

```bash
kubectl --context pvek8s get application -n argocd media  -o jsonpath='{.spec.syncPolicy}'   # record
kubectl --context pvek8s get application -n argocd $APP   -o jsonpath='{.spec.syncPolicy}'   # record

kubectl --context pvek8s -n argocd patch application media --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl --context pvek8s -n argocd patch application $APP  --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

kubectl --context pvek8s scale deploy -n $NS $APP --replicas=0
```

> In the loud case this is unnecessary — the CSI driver refuses to mount a dirty filesystem, so it stays unmounted on its own and the pod simply loops in `ContainerCreating`.

### Step 2 — Confirm the volume is fully unmounted

```bash
ssh $NODE "grep -c '$PVC_ID' /proc/mounts"    # → 0
```

If a bind mount remains after the pod is gone, kubelet's TearDown reported a false success — unmount it by hand (never force-delete the pod):

```bash
ssh $NODE "sudo fuser -vm <mountpoint>"       # expect only the kernel's globalmount reference
ssh $NODE "sudo umount <mountpoint>"
```

### Step 3 — Attach the device manually

After unmount, the CSI driver logs out of the iSCSI target and the device disappears. Re-attach it yourself so nothing races you:

```bash
IQN=$(kubectl --context pvek8s get jivavolume $PVC_ID -n openebs -o jsonpath='{.spec.iscsiSpec.iqn}')
IP=$(kubectl --context pvek8s get jivavolume $PVC_ID -n openebs -o jsonpath='{.spec.iscsiSpec.targetIP}'):3260

ssh $NODE "sudo iscsiadm -m discovery -t st -p $IP >/dev/null
           sudo iscsiadm -m node -T '$IQN' -p '$IP' --login
           sudo udevadm settle
           readlink -f /dev/disk/by-path/ip-${IP}-iscsi-${IQN}-lun-0"
# → /dev/sdX
```

> Use `udevadm settle`, not a fixed sleep — reading the symlink too early returns the by-path string itself, and `mount` will then try to interpret the colons as an NFS server.

### Step 4 — Image the device before repairing

```bash
ssh $NODE "sudo dd if=/dev/sdX bs=4M status=none | gzip -1" > ${PVC_ID}-$(date +%F).img.gz
ls -la ${PVC_ID}-*.img.gz    # must complete with no I/O error
```

A 1–2G volume compresses to tens or hundreds of MB. If `dd` reports `Input/output error`, check whether the device was detached mid-read (`dmesg` will show `Synchronizing SCSI cache`) rather than assuming bad storage.

### Step 5 — Preview, then repair

```bash
ssh $NODE 'grep -q "sdX " /proc/mounts && echo "ABORT: mounted" || sudo e2fsck -f -n /dev/sdX'
```

Read the preview before committing. `i_blocks is N, should be 0` on an inode means `e2fsck` cannot recover that file's extent tree and will truncate it — identify what that inode is and confirm a backup exists first.

```bash
ssh $NODE 'sudo e2fsck -f -y /dev/sdX'
ssh $NODE 'sudo dumpe2fs -h /dev/sdX | grep -iE "filesystem state"'
# → Filesystem state:  clean
```

### Step 6 — Repair the application database if needed

`e2fsck` fixes the filesystem, not the file contents. A SQLite database that was mid-write can still be internally damaged. Mount the volume and check:

```bash
ssh $NODE "sudo mkdir -p /mnt/repair && sudo mount /dev/sdX /mnt/repair
           sudo sqlite3 /mnt/repair/$APP.db 'PRAGMA integrity_check;'"
```

`ok` means you are done — unmount and skip to Step 7. Otherwise (`freelist size ... should be ...`, `2nd reference to page ...`) rebuild it, which preserves current data rather than losing everything since the last backup:

```bash
ssh $NODE "sudo cp -a /mnt/repair/$APP.db /mnt/repair/$APP.db.precover
           sudo sqlite3 /mnt/repair/$APP.db 'PRAGMA wal_checkpoint(TRUNCATE);'
           sudo sh -c \"sqlite3 /mnt/repair/$APP.db '.recover' | sqlite3 /tmp/recovered.db\"
           sudo sqlite3 /tmp/recovered.db 'PRAGMA integrity_check;'"
# → ok
```

Compare row and table counts against the pre-recovery copy before swapping — they should match exactly:

```bash
ssh $NODE "sudo sqlite3 /tmp/recovered.db            'select count(*) from sqlite_master where type=\"table\";'
           sudo sqlite3 /mnt/repair/$APP.db.precover 'select count(*) from sqlite_master where type=\"table\";'"
```

Swap it in with the correct ownership (match the surrounding files — typically the app's PUID:PGID), and delete the stale WAL/SHM, which belong to the old file:

```bash
ssh $NODE "sudo cp /tmp/recovered.db /mnt/repair/$APP.db.new
           sudo chown 123:132 /mnt/repair/$APP.db.new && sudo chmod 0664 /mnt/repair/$APP.db.new
           sudo mv /mnt/repair/$APP.db.new /mnt/repair/$APP.db
           sudo rm -f /mnt/repair/$APP.db-wal /mnt/repair/$APP.db-shm
           sudo sqlite3 /mnt/repair/$APP.db 'PRAGMA integrity_check;'"
# → ok
```

Applications keep their own backups under `Backups/scheduled/` on the same volume — copy them off before starting, as a fallback if `.recover` fails. Older copies also live on `macro:/usr/local/media-backups`.

### Step 7 — Detach, restart, restore ArgoCD

```bash
ssh $NODE "sudo umount /mnt/repair && sudo rmdir /mnt/repair
           sudo iscsiadm -m node -T '$IQN' -p '$IP' --logout
           sudo iscsiadm -m node -T '$IQN' -p '$IP' -o delete"

kubectl --context pvek8s scale deploy -n $NS $APP --replicas=1

# Restore BOTH syncPolicies verbatim, including any syncOptions on the parent
kubectl --context pvek8s -n argocd patch application $APP  --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl --context pvek8s -n argocd patch application media --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
```

---

## Verification

```bash
# Pod healthy
kubectl --context pvek8s get pods -n $NS | grep $APP
# → 1/1 Running

# Filesystem clean on every volume, every node (re-run the Detection sweep)
# → all "clean", none "clean with errors"

# No new kernel errors since the repair
ssh $NODE 'sudo dmesg -T | grep "EXT4-fs error" | tail -1'
# → timestamp must predate the repair

# ArgoCD restored
kubectl --context pvek8s get application -n argocd media -o jsonpath='{.spec.syncPolicy}'
# → {"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}
```

Remember to delete the `.precover` copy from the volume once satisfied — it is a full-size duplicate of the database.

---

## References

- PIR: [pvek8s Total Control Plane Loss — systemd +esm4 PID 1 Segfault](../incidents/2026-09-02-systemd-esm4-pid1-segfault-control-plane-loss.md)
- Related: [systemd-pid1-frozen-init.md](systemd-pid1-frozen-init.md) — the failure that produces these unclean shutdowns
- Related: [jiva-csi-stale-node-attachment.md](jiva-csi-stale-node-attachment.md) — mount rejections after the same reboot
- Related: [jiva-replica-corrupt-snapshot-chain.md](jiva-replica-corrupt-snapshot-chain.md) — corruption at the replica layer rather than the filesystem
- Related: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md) — iSCSI session loss driving read-only filesystems
