---
title: 2026-08-15 hal NFS handle invalidation
date: 2026-08-15
severity: P2
resolution: Resolved
duration: ~2d 16h 38m (03:12 AEST 16 Aug → 19:50 AEST 18 Aug); undetected throughout, ~17m active remediation
impact: >-
  Permanent loss of ~2.7 days of Home Assistant recorder history; sabnzbd
  history unusable; all three services reported 1/1 Running the entire time.
tags:
  - k8s01
  - k8s02
  - k8s03
  - nfs
  - hal
  - storage
  - monitoring
  - microk8s
  - openebs
  - jiva
  - argocd
---

# Post Incident Review: hal NFS Handle Invalidation — Silent SQLite Failures Across Three Services and a 2.7-Day Detection Gap

## Executive Summary

Between 2026-08-15 and 2026-08-18, three applications backed by `nfs-csi` PVCs on hal silently lost the ability to use their SQLite databases while continuing to report as healthy. Home Assistant's recorder stopped writing state history entirely, sabnzbd failed every history query, and Tautulli stopped writing its log files. No alert fired, no pod restarted, and every Kubernetes and NFS-level health signal stayed green. The failure was found only because sabnzbd's log noise was noticed and investigated directly.

The root cause was hal invalidating previously-issued NFS file handles. Unlike the [2026-08-01 incident](2026-08-01-hal-nfs-export-failure-stale-mounts.md), the RPC layer survived: `rpcbind`, `mountd`, `nfsd`, `nlockmgr` and `statd` all stayed registered and answering, exports listed normally, and mounts kept working. What broke was narrower and far quieter — every file descriptor a long-lived process already held became `ESTALE` permanently. A fresh `open()` on the same path succeeded; the running process simply never performed one. SQLite surfaces `ESTALE` on read as `sqlite3.OperationalError: disk I/O error`, which reads like corruption and is not.

Diagnosis turned on one observation: from inside the failing sabnzbd pod, `df`, `touch` and a brand-new SQLite connection to the same database file all succeeded (2866 rows, `PRAGMA quick_check` = `ok`), while the running process held ten descriptors on `/config/admin/history1.db` that all returned `Stale file handle`. That distinction — healthy path, dead descriptors — is what separates this failure mode from both corruption and a stale mount.

Remediation was a pod restart for each affected service, since nothing else re-opens the descriptors. All three recovered immediately. sabnzbd's config volume was then migrated off NFS onto block storage (`openebs-jiva-csi-default`) to remove the exposure permanently, which also eliminated a second, chronic problem: `database is locked` errors caused by SQLite's byte-range locking running over NLM on NFSv3.

Two secondary findings emerged. Both existing monitoring checks from the 2026-08-01 PIR — hal RPC service checks and the node-side stale-mount sweep — are structurally incapable of detecting this variant, because the RPC layer is genuinely healthy and the sweep validates mountpoints rather than open descriptors. Separately, the `openebs-jiva-default` StorageClass turned out to be unable to provision new volumes at all: its provisioner has been removed from the cluster, leaving four media PVCs alive but unrecreatable.

---

## Timeline (AEST — UTC+10)

| Time | Event |
| ---- | ----- |
| **~17:14 AEST, 15 Aug** | Tautulli rotates `plex_websocket.log` for the last time (`plex_websocket.log.1` mtime). |
| **~17:27 AEST, 15 Aug** | Last successful write to Tautulli's active `plex_websocket.log`. File logging dead from here; its `RotatingFileHandler` begins throwing `OSError: [Errno 116] Stale file handle` on every emit. Tautulli's database is unaffected and keeps working. |
| **~03:12 AEST, 16 Aug** | Home Assistant records its final state row (`MAX(last_updated_ts)` = `1786813882`). Recorder begins failing `CommitTask()` with `disk I/O error` and retrying every 3 seconds. No state history recorded from this point. |
| **~00:34 AEST, 18 Aug** | Earliest `disk I/O error` still present in sabnzbd's container log. The log had already rotated, so the true start is earlier and unrecoverable. |
| **12:35:38 AEST, 18 Aug** | sabnzbd's last successful history `INSERT` — a thread with a fresh connection still wrote while the ten cached read descriptors were dead. |
| **~19:33 AEST, 18 Aug** | Investigation starts. sabnzbd log shows `sqlite3.OperationalError: disk I/O error` on every history query, ~2 per 30s. |
| **19:34 AEST** | `df -h /config` healthy (`172.22.22.2:/k8s-pvc/pvc-15f91def-...`, 11T, 77% used). Config PVC identified as `nfs-csi`. |
| **19:35 AEST** | Key diagnostic: fresh SQLite connection inside the pod reads 2866 rows, `PRAGMA quick_check` = `ok`; `touch /config/admin/.writetest` succeeds. Corruption and mount failure both ruled out. |
| **19:35 AEST** | `/proc/7/fd` shows **10 descriptors** on `/config/admin/history1.db (deleted)`; `dd` against each returns `Stale file handle`. Root cause confirmed. |
| **19:36 AEST** | `kubectl rollout restart deployment/sabnzbd`. New pod on k8s01 — `disk I/O error` count 0. |
| **~19:39–19:42 AEST** | New error class appears on the restarted pod: `database is locked` on history `INSERT`/`DELETE` during a post-processing burst. Verified as NLM lock latency, not a stale handle (`BEGIN IMMEDIATE` on a fresh connection succeeds). |
| **19:42 AEST** | Blast radius search: Tautulli (`Errno 116` on log rollover) and `hass-home-assistant-0` (`disk I/O error` on recorder commits, still retrying) both confirmed affected. |
| **19:45 AEST** | Read-only probe confirms Home Assistant's DB is intact (10030 rows in `states`) — the running process's handle is dead, the file is not. |
| **19:49 AEST** | Home Assistant pod deleted; Tautulli deployment restarted. |
| **19:50 AEST** | Both recovered. HA checkpoints its WAL (4.3 MB → 8 KB), `home-assistant_v2.db` mtime current; Tautulli log writing again. **Incident resolved.** |
| **~20:02 AEST** | Migration of sabnzbd's config PVC off NFS begins: ArgoCD auto-sync paused on `media` and `sabnzbd`, old PV set to `Retain`. |
| **~20:06 AEST** | sabnzbd scaled to 0; quiesced backup taken from the unmounted volume via a helper pod. |
| **~20:09 AEST** | New PVC on `openebs-jiva-default` sits `Pending` — legacy provisioner absent from the cluster. Target changed to `openebs-jiva-csi-default`. |
| **~20:12 AEST** | PVC Bound (`pvc-0e4b60f3-...`, `/dev/sdd`); config restored and verified by md5 against the backup. |
| **20:16 AEST** | sabnzbd running on block storage — `disk I/O error`, `database is locked` and `Stale file handle` all 0. |
| **20:20 AEST** | pgmac-net/pgk8s#674 merged; auto-sync resumed on both Applications. |
| **~20:21 AEST** | ArgoCD adopts the hand-created PVC without recreating it. `media` and `sabnzbd` both `Synced / Healthy`. |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: Every SQLite Query Failing on a Healthy Mount — Stale File Descriptors

##### How did sabnzbd fail every history query with `disk I/O error`?

The SQLite connections it was using returned `ESTALE` on every read. Python's `sqlite3` reports an underlying I/O failure as `sqlite3.OperationalError: disk I/O error`, which is why the log looked like corruption. `PRAGMA quick_check` on a fresh connection returned `ok`, so the database file itself was never damaged.

##### How did those connections return `ESTALE` while the same file was readable?

The process held ten file descriptors on `/config/admin/history1.db`, all pointing at an inode the NFS server no longer recognised — `/proc/7/fd` listed them as `(deleted)`, and `dd` against each returned `Stale file handle`. A *fresh* `open()` of the same path performed a new lookup, received a new valid handle, and worked. Path resolution and descriptor validity are independent on NFS.

##### How did previously-valid file handles stop being recognised?

hal invalidated the handles it had previously issued. On a QNAP appliance this happens when `nfsd` re-exports its filesystems — the export generation changes, and every handle issued under the old generation becomes `ESTALE`. Unlike the 2026-08-01 failure, `rpcbind`, `mountd` and `nfsd` all stayed up, so mounts never broke and nothing needed remounting.

##### How did the applications not recover once fresh lookups worked again?

Nothing makes a long-lived process re-open a file it already has open. SQLite holds its database descriptor for the life of the connection; Python's `RotatingFileHandler` holds its stream for the life of the handler. Both retry the *operation*, not the `open()`. Home Assistant's recorder retried the identical `CommitTask()` every 3 seconds for ~2.7 days against a descriptor that could never succeed.

##### How was the failure not detected during those 2.7 days?

Every signal that is monitored stayed green. The pods stayed `1/1 Running` with passing liveness and readiness probes, because TCP and HTTP probes against a long-running process never touch the filesystem. hal's `nfs-rpcbind`, `nfs-mountd` and `nfs-nfsd` checks passed because the RPC layer genuinely was healthy. The `microk8s-nfs-stale-mounts` NRPE check passed because it runs `stat` against the *mountpoint* — a fresh lookup, which succeeds by definition in this failure mode.

##### How was there no check capable of seeing it?

The monitoring built after the 2026-08-01 incident (pgmac-net/nagios-config#32, pgmac-net/ansible#243) was designed against that incident's signature: a dead RPC layer and mounts that fail at the mount level. Both assumptions are false here. No check inspects `/proc/*/fd` for stale descriptors, and no check tests application-level database liveness — so a failure that lives entirely inside a running process's descriptor table is invisible by construction.

→ **ACTIONABLE ROOT CAUSE:** Monitoring validates mounts and RPC services, never open descriptors or application database writes. Action: add fd-level stale-handle detection and a recorder write-staleness check.

---

#### Chain 2: SQLite Databases on NFS — An Exposure That Should Not Exist

##### How were three SQLite databases exposed to NFS handle invalidation at all?

Their config volumes were provisioned from the `nfs-csi` StorageClass, backed by hal. sabnzbd's `admin/history1.db`, Home Assistant's `home-assistant_v2.db` and Tautulli's `tautulli.db` all lived on NFSv3 exports rather than block storage.

##### How did config volumes end up on NFS when sibling services use block storage?

The choice was per-service and never standardised. sonarr, radarr, readarr and calibre-web use `openebs-jiva-default`; seerr uses `openebs-jiva-csi-default`; searxng uses `microk8s-hostpath`; sabnzbd and Tautulli use `nfs-csi`. sabnzbd's PVC was 3 years old and predates any convention. Because bulk media and downloads legitimately belong on hal, putting the config volume there too was an easy and unexamined default.

##### How did that choice stay unexamined after the 2026-08-01 incident?

That PIR's action items focused on detection and recovery — hal service checks, a stale-mount sweep, a runbook. Its recovery procedure even documents integrity-checking `home-assistant_v2.db`, `tautulli.db` and `admin/history1.db` by name, which means the exposure was known and worked around rather than removed. No action item proposed moving SQLite off NFS.

##### How did running SQLite on NFSv3 cause a second, separate failure?

SQLite coordinates access with byte-range locks. On NFSv3 with `local_lock=none`, every lock is a round trip to hal's NLM lock manager. That latency is high enough that concurrent history writes exceeded Python's 5-second default busy timeout, producing `database is locked` on `INSERT INTO history` during post-processing bursts — a chronic, low-grade write-loss problem entirely separate from the stale-handle incident, and only visible once the stale handles were fixed.

##### How was that chronic write loss not noticed before?

`database is locked` failures are intermittent, appear only under concurrent write load, and are logged at the same severity as everything else sabnzbd logs. Nothing aggregates or alerts on application error rates, so a steady trickle of lost history writes looks identical to normal log noise.

→ **ACTIONABLE ROOT CAUSE:** No standard governs which StorageClass a config volume uses, so databases landed on a backend that cannot safely host them. Action: migrate remaining SQLite configs to block storage and set a convention.

---

## Impact

### Services Affected

| Service | Impact | Duration |
| ------- | ------ | -------- |
| home-assistant (`netconnectors`) | Recorder wrote no state history; identical `CommitTask()` retried every 3s. **Permanent data loss** — that history cannot be reconstructed | ~2d 16h 38m |
| sabnzbd (`media`) | Every history query failed; history unreadable in the UI. Downloads and post-processing continued | ≥19h (true start unrecoverable — container log had rotated) |
| tautulli (`media`) | File logging dead (`Errno 116` on every log emit). Database and Plex tracking unaffected | ~3d 2h |
| sabnzbd (`media`) — secondary | `database is locked` on history writes during post-processing bursts (NLM lock latency) | Chronic; pre-dated and outlived the incident until migration |

### Duration

- **Total incident window:** ~2d 16h 38m (first data loss → last service recovered)
- **Undetected:** the entire window — no alert fired at any point
- **Active remediation:** ~17m (19:33 → 19:50 AEST)
- **Follow-on migration:** ~18m (20:02 → 20:20 AEST)
- **Expected recovery time (with this runbook):** ~5 min — identify stale descriptors, restart the affected pods

### Scope

- **Nodes:** k8s01 (home-assistant), k8s02 (tautulli), k8s03 (sabnzbd, original pod) — the failure follows the PVC, not the node
- **Data loss:** **Yes** — ~2.7 days of Home Assistant recorder state history, permanently. sabnzbd lost an unknown number of history rows to `database is locked`. No database was corrupted; no file was damaged
- **Not affected:** linkace, vaultwarden, trivy-server, n8n and the rest of the `nfs-csi` estate — services that do not hold long-lived descriptors on NFS-backed database files. Bulk media and downloads volumes were never impaired. The control plane was not involved
- **User-visible:** minimal during the incident — every affected UI stayed up. The loss surfaces later, as a 2.7-day hole in Home Assistant history

---

## Resolution Steps Taken

### Phase 1: Diagnosis

1. Confirmed the error signature and its rate in sabnzbd's log:

   ```bash
   kubectl --context pvek8s -n media logs sabnzbd-5c5bfd4f4-tcxbm --tail=3000 \
     | grep -iE "sql|database|sqlite|lock|disk i/o|corrupt"
   # → sqlite3.OperationalError: disk I/O error, ~2 per 30s, every history query
   ```

2. Established that the mount was **not** the problem — this is the step that redirected the whole investigation:

   ```bash
   kubectl --context pvek8s -n media exec $POD -- df -h /config
   # → 172.22.22.2:/k8s-pvc/pvc-15f91def-...  11T  77% /config   (healthy)

   kubectl --context pvek8s -n media exec $POD -- sh -c 'touch /config/admin/.writetest && echo WRITE OK'
   # → WRITE OK
   ```

3. Proved the database was intact by opening a **fresh** connection inside the same pod:

   ```bash
   kubectl --context pvek8s -n media exec $POD -- python3 -c "
   import sqlite3
   c=sqlite3.connect('/config/admin/history1.db')
   print(c.execute('SELECT COUNT(*) FROM history').fetchone())
   print(c.execute('PRAGMA quick_check').fetchone())"
   # → (2866,)  ('ok',)
   ```

   A healthy read on the exact path that the running process could not read is the signature of this failure mode.

4. Confirmed the stale descriptors directly:

   ```bash
   kubectl --context pvek8s -n media exec $POD -- sh -c 'ls -l /proc/7/fd | grep history1'
   # → 10 × "/config/admin/history1.db (deleted)"

   kubectl --context pvek8s -n media exec $POD -- dd if=/proc/7/fd/11 bs=16 count=1
   # → dd: failed to open '/proc/7/fd/11': Stale file handle
   ```

5. Ruled out the 2026-08-01 failure mode by checking hal's RPC layer — all registered and answering, exports listing normally. This is a different variant, not a recurrence.

### Phase 2: Fix

6. Restarted sabnzbd. Nothing short of a restart clears the descriptors:

   ```bash
   kubectl --context pvek8s -n media rollout restart deployment/sabnzbd
   kubectl --context pvek8s -n media rollout status deployment/sabnzbd --timeout=180s
   ```

7. Swept for other victims and found two more, on two other nodes:

   ```bash
   kubectl --context pvek8s -n media logs $TAUTULLI --tail=400 | grep -i "stale file handle"
   # → OSError: [Errno 116] Stale file handle  (RotatingFileHandler.shouldRollover)

   kubectl --context pvek8s -n netconnectors logs hass-home-assistant-0 | grep -ci "disk I/O error"
   # → 162, still retrying every 3s
   ```

8. Verified Home Assistant's database before restarting it, read-only so as not to trigger WAL recovery:

   ```bash
   kubectl --context pvek8s -n netconnectors exec hass-home-assistant-0 -c home-assistant -- python3 -c "
   import sqlite3
   c=sqlite3.connect('file:/config/home-assistant_v2.db?mode=ro', uri=True, timeout=5)
   print(c.execute('SELECT COUNT(*) FROM states').fetchone()[0])"
   # → 10030   (intact)
   ```

9. Restarted both remaining services:

   ```bash
   kubectl --context pvek8s -n netconnectors delete pod hass-home-assistant-0
   kubectl --context pvek8s -n media rollout restart deployment/tautulli
   ```

### Phase 3: Removing the Exposure (sabnzbd)

10. Paused ArgoCD auto-sync on both `media` and `sabnzbd` — both carry `prune: true, selfHeal: true`, and would otherwise fight the migration or prune the PVC:

    ```bash
    kubectl --context pvek8s -n argocd patch app media   --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
    kubectl --context pvek8s -n argocd patch app sabnzbd --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
    ```

11. Set the old PV to `Retain` before touching the claim — `nfs-csi` reclaim policy is `Delete`, so deleting the PVC would otherwise destroy the data on hal.

12. Scaled sabnzbd to 0, then took a quiesced backup from the unmounted volume via a helper pod (the earlier backup was taken from a live SQLite and is not authoritative).

13. Deleted the old claim, created the replacement, and hit the second finding: a PVC on `openebs-jiva-default` stayed `Pending` — that provisioner no longer exists in the cluster. Retargeted to `openebs-jiva-csi-default`, which bound immediately as `/dev/sdd`.

14. Restored the config and verified by checksum rather than by eye:

    | File | md5 | Match |
    | ---- | --- | ----- |
    | `admin/history1.db` | `a1423224e5194d2d50a30ef0b3b443d5` | ✅ |
    | `sabnzbd.ini` | `ba7ff71266ac80314c9ab71da003aa93` | ✅ |

15. Created the PVC with the chart's exact labels and `argocd.argoproj.io/tracking-id` so ArgoCD would **adopt** it rather than see drift and recreate it. Merged pgmac-net/pgk8s#674, resumed auto-sync, and confirmed adoption — same PVC UID, pod never disturbed.

---

## Verification

```bash
# No stale descriptors in any affected pod
kubectl --context pvek8s -n media exec deployment/sabnzbd -- sh -c 'ls -l /proc/7/fd | grep -c "(deleted)"'
# → 0

# No error signatures since restart, all three services
kubectl --context pvek8s -n media logs deployment/sabnzbd | grep -cE "disk I/O error|database is locked|Stale file"
# → 0
kubectl --context pvek8s -n netconnectors logs hass-home-assistant-0 -c home-assistant | grep -ci "disk I/O error"
# → 0
kubectl --context pvek8s -n media logs deployment/tautulli | grep -ci "stale file handle"
# → 0

# sabnzbd config is on block storage, no NFS in the database path
kubectl --context pvek8s -n media exec deployment/sabnzbd -- df -h /config
# → /dev/sdd  974M  33M  925M  4% /config

# History database intact and readable on the new volume
kubectl --context pvek8s -n media exec deployment/sabnzbd -- python3 -c \
  "import sqlite3;c=sqlite3.connect('/config/admin/history1.db');\
print(c.execute('SELECT COUNT(*) FROM history').fetchone()[0], c.execute('PRAGMA quick_check').fetchone()[0])"
# → 2862 ok

# Home Assistant is writing again (WAL checkpointed on restart: 4.3 MB → 8 KB)
kubectl --context pvek8s -n netconnectors exec hass-home-assistant-0 -c home-assistant -- ls -la /config/home-assistant_v2.db
# → mtime current, not frozen at Aug 15

# ArgoCD back under automation and clean
kubectl --context pvek8s -n argocd get app media sabnzbd \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers
# → media Synced Healthy / sabnzbd Synced Healthy
```

---

## Preventive Measures

### Immediate Actions Required

1. **Add fd-level stale NFS handle detection** (High)
    - Closes the Chain 1 root cause. Every existing check passed throughout a 2.7-day failure. Detection must inspect `/proc/*/fd` for stale descriptors into NFS-backed paths, or probe application databases directly — validating the mountpoint cannot work, because fresh lookups succeed by definition.
    - Issue: [pgmac-net/ansible#263](https://github.com/pgmac-net/ansible/issues/263)

2. **Move home-assistant and tautulli SQLite configs off `nfs-csi`** (High)
    - Closes the Chain 2 root cause for the two remaining exposed services. Home Assistant is the priority: it holds the highest write volume, runs SQLite in WAL mode on NFS (which upstream does not support), and was the only service to suffer permanent data loss.
    - Issue: [pgmac-net/pgk8s#675](https://github.com/pgmac-net/pgk8s/issues/675)

3. **Alert on Home Assistant recorder write staleness** (High)
    - Chain 1 detection from the application side. A check on the age of the newest `states` row would have fired within minutes of 16 Aug 03:12 and converted 2.7 days of silent data loss into a same-morning alert. It also covers future recorder failures unrelated to NFS.
    - Issue: [pgmac-net/nagios-config#49](https://github.com/pgmac-net/nagios-config/issues/49)

### Longer-Term Improvements

4. **Migrate the four remaining `openebs-jiva-default` volumes to CSI** (Medium)
    - Discovered during remediation, unrelated to the trigger but latent and serious: that StorageClass can no longer provision. sonarr, radarr, readarr and calibre-web keep working only because their controller and replica deployments outlived the provisioner's removal. Any one of those volumes is **unrecreatable** if lost.
    - Issue: [pgmac-net/pgk8s#677](https://github.com/pgmac-net/pgk8s/issues/677)

5. **Document the handle-invalidation failure mode in the hal runbook** (Medium)
    - The existing runbook covers only the RPC-layer variant and would have misdirected an on-call here — its first instruction is to restore NFS on hal, which was already healthy. Satisfied by this PIR: `hal-nfs-export-failure.md` has been promoted to a multi-mode runbook.
    - Issue: [pgmac-net/incidents#70](https://github.com/pgmac-net/incidents/issues/70)

---

## Lessons Learned

### What Went Well

- **The one diagnostic that mattered was run early.** Opening a fresh SQLite connection inside the failing pod — and having it succeed — immediately falsified both "the database is corrupt" and "the mount is dead", which are the two obvious readings of `disk I/O error`. Everything after that was confirmation.
- **The blast-radius sweep was done before declaring victory.** Restarting sabnzbd fixed the reported problem. Checking the other `nfs-csi` consumers is what found Home Assistant losing recorder data, which was the far more serious failure and was not what anyone was looking for.
- **Data was protected before anything destructive.** The PV was set to `Retain` and a quiesced backup taken *before* the PVC was deleted, and the restore was verified by md5 rather than by directory listing. The migration touched a live database with no data at risk at any point.
- **The PVC was crafted to be adopted, not recreated.** Cloning the chart's labels and `argocd.argoproj.io/tracking-id` meant ArgoCD took ownership on resume with zero disruption — no drift, no PVC churn, no pod restart.

### What Didn't Go Well

- **Detection was entirely absent.** The incident was found by reading logs, not by an alert. Home Assistant recorded nothing for 2.7 days while presenting as healthy, and that data is gone permanently.
- **sabnzbd's true start time is unrecoverable.** The container log had already rotated past the first error, so the failure is only bounded as "≥19h". Longer log retention on chatty pods would have dated it precisely.
- **The 2026-08-01 PIR knew about the SQLite-on-NFS exposure and worked around it instead of removing it.** Its recovery procedure names all three databases explicitly. Had an action item moved them to block storage then, this incident would have been limited to Tautulli's log file.
- **The migration was planned against a StorageClass that cannot provision.** `openebs-jiva-default` was chosen because four sibling services use it — a reasonable-looking inference that was wrong. Checking that the provisioner was actually running would have caught it before the PVC was created and deleted.
- **The first backup was taken from a live SQLite database.** Harmless in the end, but it had to be retaken from the quiesced volume before it could be trusted.

### Surprise Findings

- **A healthy mount and a working file are not enough for a process to recover.** `df` works, `touch` works, a new `open()` works — and the running process still fails forever. Descriptor validity and path resolution are independent on NFS, and nothing in the stack re-opens on `ESTALE`.
- **`disk I/O error` from SQLite usually means neither disk nor corruption.** On NFS it is the standard presentation of `ESTALE` on a cached descriptor. `PRAGMA quick_check` returning `ok` on a fresh connection is the fastest way to tell the difference.
- **Liveness and readiness probes are blind to dead storage.** A pod with completely unusable persistent storage reports `1/1 Running` indefinitely, because TCP and HTTP probes never touch the filesystem. This was also the central finding of the 2026-08-01 PIR, and it caught us again.
- **`openebs-jiva-default` is a zombie StorageClass.** Its volumes run, its provisioner does not exist. Nothing surfaces this until a new PVC hangs `Pending` — and the four services relying on it have no idea their volumes cannot be rebuilt.
- **Fixing one failure exposed another.** The chronic `database is locked` write loss was completely masked while every query was failing outright, and only became visible once the stale handles were cleared.

---

## Action Items

| # | Action | Priority | GitHub |
| - | ------ | -------- | ------ |
| 1 | Add fd-level stale NFS handle detection (mountpoint `stat` cannot see it) | High | [pgmac-net/ansible#263](https://github.com/pgmac-net/ansible/issues/263) |
| 2 | Move home-assistant and tautulli SQLite configs off `nfs-csi` | High | [pgmac-net/pgk8s#675](https://github.com/pgmac-net/pgk8s/issues/675) |
| 3 | Alert on Home Assistant recorder write staleness | High | [pgmac-net/nagios-config#49](https://github.com/pgmac-net/nagios-config/issues/49) |
| 4 | Migrate the four remaining `openebs-jiva-default` volumes to CSI before one is lost | Medium | [pgmac-net/pgk8s#677](https://github.com/pgmac-net/pgk8s/issues/677) |
| 5 | Document the handle-invalidation mode in the hal runbook | Medium | [pgmac-net/incidents#70](https://github.com/pgmac-net/incidents/issues/70) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03)
- **Storage backend:** `hal.int.pgmac.net` (172.22.22.2), QNAP NAS, NFSv3, StorageClass `nfs-csi` (`nfs.csi.k8s.io`)
- **Mount options observed:** `vers=3,rsize=32768,wsize=32768,hard,proto=tcp,timeo=600,retrans=2,sec=sys,mountvers=3,mountport=30000,mountproto=udp,local_lock=none`
- **sabnzbd:** `ghcr.io/home-operations/sabnzbd:5.0.4`, chart `sabnzbd-9.4.2`
- **New sabnzbd config volume:** `openebs-jiva-csi-default` (`jiva.csi.openebs.io`), `pvc-0e4b60f3-2d9d-40b5-bf33-e0d96e91166c`
- **Retained old volume:** `pvc-15f91def-6bb1-49dc-a7d2-5fb2b4beaf86` (`Retain` / `Released`)

### Key Error Signatures

sabnzbd — every history query:

```
  File "/app/sabnzbd/database.py", line 154, in execute
    self.cursor.execute(command, args)
sqlite3.OperationalError: disk I/O error
```

Home Assistant — recorder, retried every 3s:

```
sqlalchemy.exc.OperationalError: (sqlite3.OperationalError) disk I/O error
[SQL: UPDATE states SET last_reported_ts=? WHERE states.state_id = ?]
Error in database connectivity during commit: ... (retrying in 3 seconds)
```

Tautulli — every log emit:

```
  File "/usr/local/lib/python3.13/logging/handlers.py", line 200, in shouldRollover
    pos = self.stream.tell()
OSError: [Errno 116] Stale file handle
```

The defining signature — stale descriptors on a healthy mount:

```
$ ls -l /proc/7/fd | grep history1
lrwx------ 1 ntp 132 64 Aug 18 19:35 11 -> /config/admin/history1.db (deleted)
...  (10 in total)

$ dd if=/proc/7/fd/11 bs=16 count=1
dd: failed to open '/proc/7/fd/11': Stale file handle
```

Secondary, post-restart, caused by NLM lock latency rather than stale handles:

```
sqlite3.OperationalError: database is locked
[SQL: INSERT INTO history (completed, name, nzb_name, category, ...)]
```

Legacy StorageClass with no provisioner:

```
Waiting for a volume to be created either by the external provisioner
'openebs.io/provisioner-iscsi' or manually by the system administrator.
```

### Triage: Is This a Stale Descriptor or a Stale Mount?

```bash
POD=<affected-pod>; NS=<namespace>

# 1. Is the mount alive? If both succeed, this is NOT the 2026-08-01 failure mode.
kubectl --context pvek8s -n $NS exec $POD -- df -h /config
kubectl --context pvek8s -n $NS exec $POD -- sh -c 'touch /config/.writetest && echo WRITE OK'

# 2. Is the database actually damaged? A fresh connection tells you in one command.
kubectl --context pvek8s -n $NS exec $POD -- python3 -c \
  "import sqlite3;c=sqlite3.connect('<db-path>');print(c.execute('PRAGMA quick_check').fetchone())"
# → ('ok',)  = file is fine, the process's descriptors are not

# 3. Confirm the stale descriptors.
kubectl --context pvek8s -n $NS exec $POD -- sh -c \
  'for p in $(ls /proc | grep -E "^[0-9]+$"); do
     ls -l /proc/$p/fd 2>/dev/null | grep "(deleted)" && echo "  ^ pid=$p"; done'

# 4. Fix: restart. Nothing else re-opens the descriptors.
kubectl --context pvek8s -n $NS rollout restart deployment/<name>
```

### Sweeping for Other Victims

```bash
# Every PVC on the NFS StorageClass, cluster-wide
kubectl --context pvek8s get pvc -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName --no-headers | grep nfs-csi

# Then check each consumer's logs for the three signatures
kubectl --context pvek8s -n <ns> logs <pod> | grep -ciE "stale file handle|Errno 116|disk I/O error"
# → anything above 0 needs a restart
```

---

## References

- Issue: [pgmac-net/ansible#263](https://github.com/pgmac-net/ansible/issues/263) — fd-level stale handle detection
- Issue: [pgmac-net/pgk8s#675](https://github.com/pgmac-net/pgk8s/issues/675) — move hass/tautulli SQLite off `nfs-csi`
- Issue: [pgmac-net/nagios-config#49](https://github.com/pgmac-net/nagios-config/issues/49) — Home Assistant recorder write-staleness check
- Issue: [pgmac-net/pgk8s#677](https://github.com/pgmac-net/pgk8s/issues/677) — migrate the remaining `openebs-jiva-default` volumes
- Issue: [pgmac-net/incidents#70](https://github.com/pgmac-net/incidents/issues/70) — promote the hal runbook to multi-mode
- PR: [pgmac-net/pgk8s#674](https://github.com/pgmac-net/pgk8s/pull/674) — sabnzbd config PVC migrated to `openebs-jiva-csi-default` (merged)
- Runbook: [hal NFS Failure — Export Loss and Handle Invalidation](../runbooks/hal-nfs-export-failure.md)
- Related incident: [hal NFS Export Failure — Cluster-Wide Stale Mounts and a 7h Detection Gap](2026-08-01-hal-nfs-export-failure-stale-mounts.md)

---

## Reviewers

- @pgmac
