---
tags:
  - k8s02
  - k8s03
  - dqlite
  - openebs
  - jiva
  - iscsi
  - ro-filesystem
  - ext4
  - kubelet
  - argocd
  - storage
---

# Post Incident Review: pvek8s Read-Only Volume Cascade — dqlite Storm, iSCSI Starvation, and a 17-Hour Action Gap

**Date:** 2026-08-06
**Duration:** ~17h 57m (~03:03 AEST → ~21:00 AEST)
**Severity:** High (two services fully down, four more silently failing writes, ~17h of unsaved game-server state discarded)
**Status:** Resolved

---

## Executive Summary

At 03:03 AEST a dqlite write-contention storm began simultaneously on k8s02 and k8s03. Within two minutes the kernel iSCSI initiators on both nodes started missing their 5-second keepalive deadlines to the OpenEBS Jiva targets. After the 120-second session-recovery timeout expired, the ext4 journals aborted and the kernel force-remounted six PVCs read-only across the two nodes: `media/readarr-config`, `media/sonarr-config`, `media/radarr-config`, `media/seerr-seerr-chart-config` on k8s02, and `minecraft/survive-minecraft-datadir`, `minecraft/borked-craft-minecraft-datadir` on k8s03.

Monitoring worked exactly as designed. `microk8s-jiva-csi-mounts` went WARNING at 03:15, `microk8s-ro-pvc-mounts` went CRITICAL on both nodes by 03:22, and the alerts named every affected PVC. The `readarr` host went DOWN at 03:28 and `sonarr` at 06:29. Nagios then sent 17–19 notifications per service over the following seventeen hours. Nothing acted on them. The incident's dominant cost was not detection and not diagnosis — it was that a correctly-firing, correctly-attributed CRITICAL alert sat unactioned overnight while four applications silently failed every write.

The watch-cache auto-remediation fired as intended on both nodes, and this had mixed results. On k8s03 it succeeded at 03:22. On k8s02 its post-restart verification canary timed out at 03:33 and the script exited 2, leaving `watch-cache-remediate.service` in a `failed` state. Its own kubelite restarts then produced a secondary symptom — 16x stacked duplicate bind mounts on the two CSI-backed volumes — meaning the remediation attempt manufactured a new problem while fixing the one it was scoped to. k8s02 was also found uncordoned despite the script's failure path claiming it leaves the node cordoned, with the read-only mounts still unaddressed.

Recovery required correcting the documented procedure. The runbook's fast path (cordon, then `kubectl delete pod`) assumes the replacement lands on a different node. That was not viable here, and a plain delete was verified insufficient: the ReplicaSet recreated the pod within seconds and it re-bound the stale read-only global mount. The procedure that worked was to scale the workload to zero, wait for the volume to become fully unreferenced so kubelet unmounts *and logs out the iSCSI session*, then scale back up so a fresh login replays the journal. For one CSI volume even that was not enough — the superblock retained `clean with errors` and `needs_recovery`, requiring an explicit `e2fsck -f -y`.

All six volumes were confirmed writable by live write test at approximately 21:00 AEST. The chronic `microk8s-image-gc` CRITICAL on k8s02 was investigated, found to predate this incident by 34–35 days, and split out as a separate issue.

---

## Timeline (AEST — UTC+10)

| Time | Event |
| --- | --- |
| **03:03:22 AEST** | k8s02 dqlite begins logging `database is locked` on `/registry/leases/kube-system/kube-controller-manager` at `try: 500` |
| **03:04:26 AEST** | k8s03 dqlite begins the same write-contention signature |
| **03:05:38 AEST** | k8s02 kernel: `connection23:0: ping timeout of 5 secs expired` → `detected conn error (1022)` — first iSCSI symptom |
| **03:09 AEST** | k8s03 kernel: same ping-timeout pattern begins on `connection29:0` |
| **03:12–03:13 AEST** | Both nodes: `detected conn error (1020)` across multiple connections — hard session errors |
| **03:14:44 AEST** | Both nodes: `session recovery timed out after 120 secs` → `blk_update_request: I/O error` → `Aborting journal on device sdX-8` → **`EXT4-fs (sdX): Remounting filesystem read-only`** |
| **03:14:49 AEST** | k8s03 `sdg` (borked-craft) remounted ro |
| **03:15:29 AEST** | Nagios: k8s03 `microk8s-jiva-csi-mounts` → WARNING (first alert of the incident) |
| **03:16:16–03:21:19 AEST** | k8s03 second wave hits `sdc` (survive); k8s02 `sde`, `sdd`, `sdc`, `sdb` all remount ro |
| **03:18:10 AEST** | k8s03 `watch-cache-remediate.sh` auto-fires: freeze confirmed → cordon → restart dqlite + kubelite |
| **03:21:11 AEST** | Nagios: k8s02 `microk8s-jiva-csi-mounts` → WARNING |
| **03:22:31 AEST** | Nagios: k8s03 `microk8s-ro-pvc-mounts` → CRITICAL, naming both PVCs |
| **03:22:47 AEST** | Nagios: k8s02 `microk8s-ro-pvc-mounts` → CRITICAL, naming all four PVCs |
| **03:22:52 AEST** | k8s03 remediation canary SUCCEEDS; node uncordoned |
| **03:24:24 AEST** | k8s02 `watch-cache-remediate.sh` auto-fires; freeze confirmed 03:25:08; cordoned 03:26:15 |
| **03:26:22–03:26:42 AEST** | k8s02 dqlite restarted, then kubelite restarted — **this restart creates the 16x duplicate bind mounts** |
| **03:27:03 AEST** | k8s02 node Ready |
| **03:28:40 AEST** | Nagios: `readarr` host → DOWN (HTTP 503; SQLite migration cannot write to ro `/config`) |
| **03:33:40 AEST** | k8s02 remediation **canary FAILS** — "did not complete within 180s"; script exits 2, leaving `watch-cache-remediate.service` failed |
| **03:34–05:14 AEST** | k8s03 logs 9x `REFUSED: remediation ran Xm ago (<2h)` as the rate-limit guard suppresses repeat freeze detections |
| **03:38:57 AEST** | Nagios: k8s02 `microk8s-watch-cache-remediation-health` → CRITICAL |
| **03:51:26 AEST** | Nagios: k8s02 `microk8s-image-gc` → CRITICAL (later determined pre-existing and unrelated) |
| **~03:33–20:19 AEST** | k8s02 found uncordoned out-of-band, with ro mounts and duplicate bind mounts never addressed |
| **05:25:10 AEST** | k8s03 second genuine freeze; self-remediates successfully (`wcr-canary-k8s03`) |
| **05:26:19 AEST** | Nagios: k8s02 `microk8s-deployments` → degraded, `media/readarr (0/1)` |
| **06:29:10 AEST** | Nagios: `sonarr` host → DOWN (socket timeout — 3h after readarr, writes had been failing silently) |
| **~06:30–20:19 AEST** | **17-hour gap.** Nagios sends 17–19 notifications per affected service. No action taken. |
| **20:19 AEST** | Investigation begins. `get_unhandled_problems` returns 2 hosts down, 6 services degraded |
| **20:20 AEST** | Nagios state-change timestamps reconstructed; k8s03 shown leading k8s02 by 4–6 min, mount duplication preceding the ro remount — indicates cluster-wide trigger, not per-node disk failure |
| **20:31 AEST** | Root cause confirmed from kernel/dqlite journals: dqlite storm → iSCSI timeout → EXT4 abort. iSCSI sessions and JivaVolume CRs verified healthy |
| **20:35 AEST** | `readarr` pod deleted — **volume still `ro,relatime`**; plain-delete approach disproven |
| **20:37 AEST** | Scale-to-0 applied to readarr; volume fully unmounted, `/dev/sde` disappears; scale-to-1 remounts **rw** |
| **20:40 AEST** | sonarr + radarr recovered via same procedure (rescheduled to k8s01, mounted rw) |
| **20:44 AEST** | seerr teardown wedges kubelet: `GetDeviceMountRefs check failed ... still mounted by other references`; manual `umount` of orphaned bind mount releases it |
| **20:48 AEST** | seerr recovered **rw**, single mount, no duplication |
| **20:52 AEST** | minecraft pods force-deleted; 4 orphaned mounts cleared manually |
| **20:55 AEST** | `e2fsck -f -y /dev/sdg` on borked-craft: journal recovered, `Filesystem state: clean`, 789 files intact |
| **20:56 AEST** | Both minecraft servers Running; logs confirm `All dimensions are saved` |
| **20:58 AEST** | `systemctl reset-failed watch-cache-remediate.service` on k8s02, after independently verifying watch cache healthy (RV advancing, lag 214 → 91 → 52) |
| **~21:00 AEST** | All six volumes confirmed RW-OK by live write test. Nagios `microk8s-ro-pvc-mounts` and `microk8s-jiva-csi-mounts` clear on both nodes; `readarr` and `sonarr` hosts UP |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: Six PVCs Remounted Read-Only — dqlite Storm Starves the iSCSI Initiator

##### How did six PVCs across two nodes remount read-only within seven minutes of each other?

The kernel force-remounted each filesystem after its ext4 journal aborted:

```
Aug 05 17:14:44 k8s02 kernel: Aborting journal on device sde-8.
Aug 05 17:14:44 k8s02 kernel: EXT4-fs error (device sde): ext4_journal_check_start:61: Detected aborted journal
Aug 05 17:14:44 k8s02 kernel: EXT4-fs (sde): Remounting filesystem read-only
```

##### How did the ext4 journals abort?

In-flight writes returned `-EIO` because the underlying SCSI block devices went offline. The devices went offline because the iSCSI sessions to the Jiva targets were declared dead after the 120-second recovery timeout expired:

```
Aug 05 17:14:44 k8s02 kernel:  session22: session recovery timed out after 120 secs
```

##### How did the iSCSI sessions time out when the Jiva targets were healthy?

They did not fail because the target died — this is the key divergence from the existing runbook's model. `kubectl -n openebs get jivavolumes` showed every volume `Ready`/`RW` throughout, and no jiva-ctrl eviction was found bracketing the 03:05–03:14 window. The jiva-ctrl pods only restarted at 03:26–03:27, coincident with the auto-remediation's own kubelite restart, well *after* the read-only remounts.

The sessions died because the initiator missed its keepalive:

```
Aug 05 17:05:38 k8s02 kernel:  connection23:0: ping timeout of 5 secs expired, recv timeout 5
Aug 05 17:05:38 k8s02 kernel:  connection23:0: detected conn error (1022)
```

##### How did the initiator miss a 5-second keepalive on a healthy network path?

A dqlite write-contention storm began 2 minutes and 16 seconds earlier, on both nodes independently:

```
Aug 05 17:03:22 k8s02 microk8s.daemon-k8s-dqlite: level=error msg="error in txn: update transaction
  failed for key /registry/leases/kube-system/kube-controller-manager: exec (try: 500): database is locked"
```

`try: 500` indicates hundreds of retries per key per second. The resulting CPU and scheduler pressure appears to have delayed the kernel iSCSI initiator's keepalive processing past its 5-second deadline. This is the best-supported hypothesis on tight temporal correlation across two independent nodes, but it is **not proven** — no CPU or scheduler telemetry was retained for the window, so the starvation mechanism could not be directly demonstrated.

##### How did a 5-second keepalive deadline come to sit on the critical path of every Jiva volume?

`node.session.timeo.replacement_timeout` is at its 120s default and the ping timeout at 5s. These defaults assume a dedicated storage network. Here the iSCSI initiator, dqlite, kubelite and every workload contend for the same CPUs on a three-node hyperconverged cluster, so control-plane load and storage-path liveness are not isolated from each other. Raising the iSCSI timeouts was identified as a structural mitigation in the existing runbook (as PGM-222/PGM-221 under the old Linear tracker) and was never implemented.

##### How was the dqlite storm itself not prevented or detected before it reached storage?

The storm's own trigger was not isolated — the sampled log window does not show what was driving writes at 03:03. dqlite write contention is a known, repeatedly-documented failure mode in this cluster with an existing runbook, but monitoring alerts on its *downstream consequences* (watch-cache freeze, ro mounts) rather than on write-retry rate itself. There is no alert on dqlite retry depth, so a storm is only visible once it has already broken something.

→ **ACTIONABLE ROOT CAUSE:** No alerting on dqlite write-retry rate, and no isolation between control-plane CPU pressure and iSCSI keepalive timing. Actions: alert on dqlite retry depth before consequences land; raise iSCSI `replacement_timeout` so a transient control-plane stall cannot kill a storage session.

---

#### Chain 2: Seventeen Hours Between Correct Alert and Any Action — Notification Without Escalation

##### How did four applications silently fail every write for seventeen hours?

Nobody acted on the alerts. The volumes remained read-only from 03:14 until manual intervention at 20:35.

##### How did nobody act, when the monitoring correctly identified the problem?

Not a detection failure. `microk8s-ro-pvc-mounts` went CRITICAL at 03:22 — eight minutes after the first remount — and its output named every affected PVC and pointed at the correct runbook:

```
CRITICAL: 4 PVC volume(s) mounted read-only on k8s02: pvc-17e6e808... pvc-746b2837...
- writes are failing while pods may report Running: recreate the pod(s) to remount rw
(runbook: jiva-ctrl-eviction-iscsi-ro-filesystem)
```

Nagios then sent 17–19 notifications per affected service across seventeen hours. Every one was delivered and none produced action.

##### How did seventeen hours of repeat notifications produce no response?

The incident began at 03:03 and the alerts fired overnight. There is no escalation path that distinguishes "CRITICAL at 03:22 on a Wednesday" from any other notification — the same channel receives routine and severe alerts, and repeat notifications for an unacknowledged CRITICAL carry no increasing urgency. A storage-integrity CRITICAL that is actively losing writes is delivered identically to a 9-day-old acknowledged pending-reboot warning.

##### How did the affected applications not make the failure obvious sooner?

They mostly could not. Only `readarr` crashed, because its .NET/SQLite stack attempts a database migration on startup and dies when the write fails. `sonarr`, `radarr` and `seerr` kept reporting `1/1 Running` with a read-only config volume — the Nagios alert text anticipates this exactly ("pods may report Running"). Both minecraft servers reported `0` restarts for the full seventeen hours while throwing continuous `Read-only file system` exceptions into their logs. `sonarr`'s host check only failed at 06:29, three hours after the remount.

##### How was auto-remediation not extended to cover this failure mode?

Auto-remediation exists in this cluster and fired correctly during this very incident — but only for watch-cache freezes. The read-only-PVC condition has a state-based check that names the exact volumes and a documented recovery procedure, yet no handler. The 2026-07-11 work that added `microk8s-ro-pvc-mounts` delivered detection without wiring the corresponding remediation, and the gap was not tracked.

→ **ACTIONABLE ROOT CAUSE:** Severity-blind notification with no escalation for unacknowledged storage-integrity CRITICALs, and no auto-remediation handler for a failure mode that already has both precise detection and a documented fix. Actions: escalate unacknowledged CRITICALs on data-integrity checks; add a `microk8s-ro-pvc-mounts` remediation handler.

---

#### Chain 3: Auto-Remediation Left k8s02 Worse Than It Found It

##### How did the watch-cache auto-remediation end with a failed unit and 16 duplicate mounts?

Its post-restart verification canary timed out:

```
17:33:40 FAILED: verification canary did not complete within 180s ... leaving k8s02 CORDONED
```

The script exited 2, leaving `watch-cache-remediate.service` in `failed` state, which the `microk8s-watch-cache-remediation-health` check correctly flagged as potentially blocking future remediation launches.

##### How did the canary time out if the watch cache was actually fine?

It was fine. When the watch cache was independently re-tested during this investigation, it was healthy and tracking — cache resourceVersion advancing `13804039 → 13804185 → 13804253` with lag shrinking `214 → 91 → 52`. The canary's 180-second budget was simply too tight for a node that had just restarted dqlite and kubelite while four of its volumes were read-only and one workload was crashlooping. The canary measured a slow node, not a broken watch cache, and reported the latter.

##### How did the remediation's own kubelite restarts create 16 duplicate bind mounts?

This is the documented `jiva-csi-mount-proliferation` pattern: each kubelite restart re-stacks the CSI bind mount without unmounting the previous one. Both affected volumes were CSI-backed (`pvc-746b2837` on k8s02, `pvc-eaa33b86` on k8s03); the four legacy iSCSI volumes each kept a clean single mount pair. The duplication was therefore a side effect of the *fix attempt*, not of the original fault.

##### How did k8s02 end up uncordoned with its mounts still broken?

The script's failure path logs that it leaves the node cordoned, and it exited via that path — yet k8s02 was found uncordoned, with no `uncordoned` log line and the scheduling lease already `NotFound`. Something uncordoned the node out-of-band after the failure, restoring scheduling to a node whose volumes were still read-only. The cordon/uncordon bookkeeping on the failure path does not match its own logging, so the node's actual state after a failed remediation is not reliably knowable from its logs.

##### How was a remediation script allowed to leave the cluster in a state nothing would reconcile?

The script is scoped to watch-cache freezes and has no awareness of storage state. It restarts kubelite — an action known to duplicate CSI mounts — without checking whether volumes on the node are healthy first, and without any post-run reconciliation of the side effects it is known to cause. Its failure path terminates without either completing recovery or escalating, so a failed run produces a half-remediated node and a red check, with no owner.

→ **ACTIONABLE ROOT CAUSE:** The remediation script has no storage-state awareness, an under-budgeted canary, and a failure path whose claimed and actual behaviour diverge. Actions: widen the canary budget or make it adaptive; have the script detect and clean the mount duplication it causes; reconcile the cordon bookkeeping on the failure path.

---

#### Chain 4: The Documented Recovery Procedure Did Not Work As Written

##### How did the runbook's recovery procedure fail to restore the volumes?

The Nagios check and the runbook both advise "recreate the pod(s) to remount rw". Deleting the `readarr` pod was verified to leave the volume `ro,relatime` — the fix did not work.

##### How did a pod recreate leave the volume still read-only?

The ReplicaSet recreated the pod within seconds, and kubelet only tears down the global device mount once *no* pod on the node references the volume. The replacement claimed the stale read-only global mount before kubelet could drop it. The runbook documents this exact trap and mandates cordoning first — but the Nagios check text, which is what an operator actually reads at 03:22, omits it entirely and says only "recreate the pod(s)".

##### How did the working procedure differ?

Scaling the workload to zero — rather than deleting the pod — let the volume become fully unreferenced. Kubelet then unmounted the device *and logged out the iSCSI session*, removing the block device from the node entirely. A subsequent scale to one performed a fresh iSCSI login, replayed the journal, and mounted `rw`. The iSCSI logout, not the pod recreation, is the step that matters.

##### How did one volume stay read-only even after a clean remount?

Where the session had not fully dropped, the superblock retained its error state:

```
Filesystem state:         clean with errors
Filesystem features:      ... needs_recovery ...
FS Error count:           2
First error time:         Wed Aug  5 17:14:44 2026
First error function:     ext4_journal_check_start
```

`borked-craft` required an explicit `e2fsck -f -y /dev/sdg`, which recovered the journal and returned `Filesystem state: clean` with all 789 files intact. No existing runbook mentions checking the superblock or running fsck for this failure mode — the assumption throughout is that a remount is always sufficient.

##### How did ArgoCD interfere with the recovery?

Auto-sync repeatedly reverted the scale-to-0 within roughly 40 seconds, recreating pods mid-procedure. The unmount still completed inside that window, but this made the procedure racy and materially harder to execute. No runbook covering scale-based storage recovery mentions suspending auto-sync, despite ArgoCD being the production deployment mechanism for these workloads.

##### How was the runbook's inaccuracy not discovered before this incident?

The runbook's fast path was proven on 2026-07-11 and refined 2026-07-13 — in both cases the replacement pod landed on a *different* node, where a fresh login happened naturally. That path was never exercised in the case where the pod stays on the same node, so the gap went unnoticed. The Nagios check text was written once, alongside the check, and has never been revalidated against the runbook it cites.

→ **ACTIONABLE ROOT CAUSE:** Recovery guidance was validated only against the cross-node case and drifted out of sync with the alert text that points to it. Actions: correct both the runbook and the check output; document the scale-to-0 + fsck path and the ArgoCD interaction.

---

## Impact

### Services Affected

| Service | Impact | Duration |
| --- | --- | --- |
| `readarr` (media) | Fully DOWN — HTTP 503; crashloop with 201 restarts, SQLite migration could not write | ~17h 6m (03:28 → 20:37) |
| `sonarr` (media) | Fully DOWN — socket timeout; reported `1/1 Running` for 3h while writes failed | ~14h 11m (06:29 → 20:40) |
| `radarr` (media) | Config volume read-only; pod reported Running, all writes silently failing | ~17h 26m (03:14 → 20:40) |
| `seerr` (media) | Config volume read-only; pod reported Running, all writes silently failing | ~17h 34m (03:14 → 20:48) |
| `survive-minecraft` | World saves failing continuously; 0 pod restarts, appeared healthy | ~17h 42m (03:14 → 20:56) |
| `borked-craft-minecraft` | World saves failing continuously; 0 pod restarts, appeared healthy | ~17h 42m (03:14 → 20:56) |
| k8s02 watch-cache remediation | Unit in `failed` state, flagged as potentially blocking future remediation | ~17h 19m (03:38 → 20:58) |

### Duration

- **Total incident window:** ~17h 57m (03:03 → 21:00 AEST)
- **Time to detection:** ~12 minutes (first remount 03:14 → first CRITICAL 03:22, PVCs named)
- **Time from detection to action:** ~17h (03:22 → 20:19) — the dominant cost of this incident
- **Time from action to resolution:** ~41 minutes (20:19 → 21:00), including root-cause investigation
- **Expected recovery time with a corrected runbook:** ~15 min

### Scope

- **Nodes affected:** k8s02 (4 volumes), k8s03 (2 volumes). k8s01 unaffected and used as a recovery target for sonarr/radarr.
- **Data loss:** Yes, partial. Both minecraft worlds could not save from 03:11 AEST until recovery — approximately 17 hours of world state existed only in server RAM and was unrecoverable by any path, since a read-only filesystem cannot accept the flush. The servers were recreated with that state discarded, per explicit decision, reverting to their last successful save. No data loss on the media config volumes: `readarr`'s SQLite migration never completed a write, so the database was untouched.
- **Not affected:** Cluster control plane remained functional throughout; all three nodes stayed `Ready`. No pods were stuck in a non-Running phase. The remaining 71 deployments were unaffected.

---

## Resolution Steps Taken

### Phase 1: Assessment

1. `get_unhandled_problems` via the Nagios MCP returned 2 hosts DOWN (`readarr`, `sonarr`) and 6 degraded services.
2. Reconstructed a timeline from Nagios `last_state_change` timestamps. This showed k8s03 leading k8s02 by 4–6 minutes and mount duplication *preceding* the ro remount on both nodes — indicating a cluster-wide trigger rather than per-node disk failure.
3. Mapped every read-only PV UID to its claim, establishing that four were legacy `openebs-jiva-default` and two were `openebs-jiva-csi-default`.
4. Confirmed all three nodes `Ready` with no pods outside Running/Completed — establishing this as a storage-plane, not availability, incident.

### Phase 2: Root Cause Confirmation

5. Correlated kernel, kubelite and dqlite journals on both nodes across 03:00–04:00, establishing dqlite storm → iSCSI ping timeout → session recovery timeout → ext4 abort, with dqlite first by 2m16s.
6. Verified the Jiva control plane was healthy — `kubectl -n openebs get jivavolumes` showed all volumes `Ready`/`RW`, ruling out replica desync.
7. Verified all 7 iSCSI sessions currently `ESTABLISHED`, confirming a recreate would not simply re-fail.
8. Checked minecraft world-save timestamps, confirming writes stopped at 17:11 UTC and quantifying the unsaved-state exposure before any destructive action.

### Phase 3: Fix — Legacy iSCSI Volumes

9. Deleted the `readarr` pod per the documented procedure. **Verified this did not work** — volume remained `ro,relatime` because the ReplicaSet reclaimed the stale global mount.
10. Scaled `readarr` to 0. Volume fully unmounted, `/dev/sde` disappeared from the node (kubelet logged out the iSCSI session).
11. Scaled back to 1 — fresh login replayed the journal, volume mounted `rw`, pod 1/1 Running.
12. Applied the same procedure to `sonarr` and `radarr`; both rescheduled to k8s01 and mounted `rw`.

### Phase 4: Fix — CSI Volumes and Wedged Teardown

13. Scaled the `seerr` StatefulSet to 0. The 16x stacked mounts collapsed to 1, but kubelet then deadlocked:
    `GetDeviceMountRefs check failed ... the device mount path ... is still mounted by other references`
14. Manually unmounted the orphaned per-pod bind mount, which released kubelet's retry loop. Scaled back to 1 → `rw`, single mount.
15. For minecraft, force-deleted the pods and manually cleared 4 orphaned mounts. (Note: the runbook explicitly warns against `--force` for exactly this reason, and the predicted wedge occurred.)
16. `/dev/sdg` (borked-craft) retained `clean with errors` + `needs_recovery`, so ran `e2fsck -f -y /dev/sdg` after confirming the volume was unmounted and the workload scaled to 0. Journal recovered; `Filesystem state: clean`; 789 files intact.
17. Scaled both minecraft deployments back up; `borked-craft` needed one further pod delete to rebuild a mount whose reference had been manually removed.

### Phase 5: Clearing Remediation State

18. Verified the k8s02 watch cache was genuinely healthy before clearing the failed unit — sampled cache vs quorum resourceVersion three times, confirming the cache was *advancing* (`13804039 → 13804185 → 13804253`) with shrinking lag, rather than treating a single-sample gap as a freeze.
19. `systemctl reset-failed watch-cache-remediate.service` on k8s02.

---

## Verification

```bash
# All six affected volumes accept writes
kubectl --context pvek8s exec -n media <readarr-pod> -- sh -c 'touch /config/.rwtest && rm /config/.rwtest && echo RW-OK'
# → RW-OK   (repeated for sonarr, radarr, seerr, survive, borked-craft — all RW-OK)
```

```bash
# No read-only PVC mounts remain on either node
for n in k8s02 k8s03; do ssh $n "grep -E 'pvc-.* ext4 ro' /proc/mounts"; done
# → (empty)
```

```bash
# Filesystem error state cleared on the volume that needed fsck
ssh k8s03 "sudo dumpe2fs -h /dev/sdg 2>&1 | grep -i 'filesystem state'"
# → Filesystem state:         clean
```

```bash
# Remediation unit no longer failed
ssh k8s02 "systemctl is-failed watch-cache-remediate.service"
# → inactive
```

```bash
# All nodes Ready and uncordoned
kubectl --context pvek8s get nodes
# → k8s01, k8s02, k8s03 all Ready, none SchedulingDisabled
```

Nagios `get_unhandled_problems` returns no hosts down and no incident-related services — only the pre-existing acknowledged `reboot` checks (9.8 days old, predating this incident).

---

## Preventive Measures

### Immediate Actions Required

1. **Correct the read-only PVC recovery guidance** (High)
    - The runbook's fast path and the Nagios check text both say "recreate the pod(s)", which was verified not to work when the pod stays on the same node. Chain 4.
    - Issue: [pgmac-net/ansible#254](https://github.com/pgmac-net/ansible/issues/254)

2. **Add auto-remediation for `microk8s-ro-pvc-mounts`** (High)
    - The check names the exact volumes and a documented fix exists, but no handler is wired — the direct cause of the 17-hour gap. Chain 2.
    - Issue: [pgmac-net/ansible#255](https://github.com/pgmac-net/ansible/issues/255)

3. **Escalate unacknowledged data-integrity CRITICALs** (High)
    - 17–19 notifications over 17 hours produced no action; a storage-integrity CRITICAL is delivered identically to a 9-day-old acknowledged warning. Chain 2.
    - Issue: [pgmac-net/nagios-config#46](https://github.com/pgmac-net/nagios-config/issues/46)

4. **Fix the watch-cache remediation failure path** (Medium)
    - Canary budget too tight for a degraded node; cordon bookkeeping diverges from its own logging; restarts kubelite without storage-state awareness. Chain 3.
    - Issue: [pgmac-net/ansible#256](https://github.com/pgmac-net/ansible/issues/256)

### Longer-Term Improvements

5. **Raise iSCSI `replacement_timeout` and ping timeout** (Medium)
    - Defaults assume a dedicated storage network; on a hyperconverged 3-node cluster a control-plane CPU stall can kill a storage session. Previously identified and never implemented. Chain 1.
    - Issue: [pgmac-net/ansible#257](https://github.com/pgmac-net/ansible/issues/257)

6. **Alert on dqlite write-retry rate** (Medium)
    - Storms are currently only visible through their downstream consequences, by which point damage has occurred. Chain 1.
    - Issue: [pgmac-net/ansible#258](https://github.com/pgmac-net/ansible/issues/258)

7. **Document the ArgoCD interaction for storage recovery** (Low)
    - Auto-sync reverted scale-to-0 within ~40s throughout the recovery, making the procedure racy. Chain 4.
    - Issue: [pgmac-net/homelabia#159](https://github.com/pgmac-net/homelabia/issues/159)

---

## Lessons Learned

### What Went Well

- **Detection was fast and precise.** `microk8s-ro-pvc-mounts` went CRITICAL 8 minutes after the first remount and named every affected PVC. The check built on 2026-07-11 did exactly its job.
- **Reconstructing the timeline from Nagios state-change timestamps before touching logs** immediately showed k8s03 leading k8s02 and duplication preceding the ro remount, which ruled out per-node disk failure and pointed at a cluster-wide trigger within minutes.
- **Verifying the iSCSI transport and JivaVolume CR health before attempting recovery** confirmed a recreate would actually succeed rather than re-fail, avoiding a blind retry loop.
- **Checking minecraft world-save timestamps before recreating the pods** quantified the data exposure and turned an invisible loss into an explicit, informed decision.
- **Testing the fix on one volume before applying it broadly** is what caught the plain-delete approach failing. Had all six been done at once, the failure would have been much harder to attribute.
- **Re-testing the watch cache before clearing the failed unit** — and specifically sampling for *advancement* rather than trusting a single-point comparison — avoided both a false "still frozen" reading and a blind reset.

### What Didn't Go Well

- **Seventeen hours of correct alerts produced no action.** This dwarfs every technical factor in the incident. Diagnosis and repair took 41 minutes; the wait took 17 hours.
- **The documented recovery procedure was wrong for this case**, and the Nagios check text propagated the incorrect short version to whoever reads the alert.
- **`--force --grace-period=0` was used on the minecraft pods** despite the runbook explicitly warning against it for CSI volumes with proliferated mounts. The predicted wedge occurred and required manual `umount` cleanup — the runbook was right and its warning was not heeded.
- **The auto-remediation made things worse on k8s02** — a failed unit, 16 duplicated mounts, and a node uncordoned with broken storage.
- **ArgoCD auto-sync fought the recovery throughout**, reverting scale-to-0 within ~40 seconds each time and making the procedure depend on winning a race.

### Surprise Findings

- **The Jiva target never died.** Every previous instance of this failure mode traced to a jiva-ctrl eviction. Here the JivaVolumes were `Ready`/`RW` throughout and jiva-ctrl only restarted *after* the remounts. The same symptom reached the same outcome by a different mechanism — CPU starvation of the initiator rather than loss of the target.
- **A clean unmount is not always enough.** One volume retained `clean with errors` + `needs_recovery` in its superblock and stayed read-only across a full unmount/remount cycle until `e2fsck` cleared it. No runbook covers checking the superblock for this failure mode.
- **The iSCSI logout, not the pod recreation, is the operative step.** Recovery works when the volume becomes fully unreferenced and the session drops, which is why scale-to-0 succeeds where pod-delete fails.
- **microk8s kubelet uses its own mount namespace**, so a volume can be correctly mounted and writable inside the pod while `mount` on the host shows nothing. This briefly read as "the volume failed to attach" when `survive-minecraft` was in fact fully healthy.
- **Applications hide read-only storage almost completely.** Four of six workloads reported `1/1 Running` with zero restarts for seventeen hours while every write failed. Only the one with a startup database migration crashed.

---

## Action Items

| # | Action | Priority | GitHub |
| --- | --- | --- | --- |
| 1 | Correct read-only PVC recovery guidance in runbook and Nagios check text | High | [pgmac-net/ansible#254](https://github.com/pgmac-net/ansible/issues/254) |
| 2 | Add auto-remediation handler for `microk8s-ro-pvc-mounts` | High | [pgmac-net/ansible#255](https://github.com/pgmac-net/ansible/issues/255) |
| 3 | Escalate unacknowledged data-integrity CRITICALs | High | [pgmac-net/nagios-config#46](https://github.com/pgmac-net/nagios-config/issues/46) |
| 4 | Fix watch-cache remediation canary budget, cordon bookkeeping, and mount cleanup | Medium | [pgmac-net/ansible#256](https://github.com/pgmac-net/ansible/issues/256) |
| 5 | Raise iSCSI `replacement_timeout` and ping timeout on all nodes | Medium | [pgmac-net/ansible#257](https://github.com/pgmac-net/ansible/issues/257) |
| 6 | Alert on dqlite write-retry rate before downstream damage | Medium | [pgmac-net/ansible#258](https://github.com/pgmac-net/ansible/issues/258) |
| 7 | Document ArgoCD auto-sync interaction with storage recovery procedures | Low | [pgmac-net/homelabia#159](https://github.com/pgmac-net/homelabia/issues/159) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03)
- **Kubernetes version:** v1.35.0
- **Container runtime:** containerd 2.1.3
- **OS:** Ubuntu 20.04.6 LTS, kernel 5.4.0-231-generic
- **Storage:** OpenEBS Jiva — both `openebs-jiva-default` (legacy iSCSI) and `openebs-jiva-csi-default` (CSI)
- **GitOps:** ArgoCD with auto-sync enabled on the affected applications

### Key Error Signatures

dqlite write-contention storm (the trigger):
```
level=error msg="error in txn: update transaction failed for key
/registry/leases/kube-system/kube-controller-manager: exec (try: 500): database is locked"
```

iSCSI initiator keepalive starvation:
```
connection23:0: ping timeout of 5 secs expired, recv timeout 5
connection23:0: detected conn error (1022)
session22: session recovery timed out after 120 secs
```

ext4 forced read-only remount:
```
Aborting journal on device sde-8.
EXT4-fs error (device sde): ext4_journal_check_start:61: Detected aborted journal
EXT4-fs (sde): Remounting filesystem read-only
```

Kubelet unmount deadlock from a leaked bind mount:
```
Error: GetDeviceMountRefs check failed for volume "pvc-746b2837-..." on node "k8s02" :
the device mount path ".../globalmount" is still mounted by other references
[.../pods/<uid>/volumes/kubernetes.io~csi/pvc-746b2837-.../mount]
```

Persisted superblock error state blocking a rw remount:
```
Filesystem state:         clean with errors
Filesystem features:      ... needs_recovery ...
First error function:     ext4_journal_check_start
```

### Recovery Procedure (corrected)

```bash
# 1. Identify affected volumes and map to workloads
for n in k8s02 k8s03; do ssh $n "grep -E 'pvc-.* ext4 ro' /proc/mounts"; done
kubectl --context pvek8s get pv <pv> -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}'

# 2. Confirm iSCSI transport and Jiva volume health BEFORE recovery
ssh <node> "sudo iscsiadm -m session"
kubectl --context pvek8s -n openebs get jivavolumes     # → Ready / RW

# 3. Scale to 0 — NOT a pod delete. Wait for full unreference.
kubectl --context pvek8s scale deploy -n <ns> <name> --replicas=0
ssh <node> "mount | grep <pvc>"                          # → must be empty
ssh <node> "ls -la /dev/sdX"                             # → must be gone (iSCSI logged out)

# 4. If kubelet wedges on a leaked bind mount, clear it manually
ssh <node> "sudo umount /var/snap/microk8s/common/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~csi/<pvc>/mount"

# 5. If the device persists, check the superblock and fsck if needed
ssh <node> "sudo dumpe2fs -h /dev/sdX 2>&1 | grep -Ei 'filesystem state|FS Error count'"
# → 'clean with errors' means a remount alone will NOT restore rw
ssh <node> "sudo e2fsck -f -y /dev/sdX"

# 6. Scale back up and verify
kubectl --context pvek8s scale deploy -n <ns> <name> --replicas=1
kubectl --context pvek8s exec -n <ns> <pod> -- sh -c 'touch /data/.rwtest && rm /data/.rwtest && echo RW-OK'
```

### Watch-Cache Health Check (sample for advancement, not a single point)

```bash
for i in 1 2 3; do
  C=$(kubectl --context pvek8s get --raw '/api/v1/namespaces/default/configmaps?resourceVersion=0&limit=1' | grep -oE '"resourceVersion":"[0-9]+"' | head -1 | grep -oE '[0-9]+')
  Q=$(kubectl --context pvek8s get --raw '/api/v1/namespaces/default/configmaps?limit=1' | grep -oE '"resourceVersion":"[0-9]+"' | head -1 | grep -oE '[0-9]+')
  echo "cache=$C quorum=$Q lag=$((Q-C))"; sleep 5
done
# → healthy: cache advances between samples, lag shrinks
# → frozen:  cache static across all three samples
```

---

## References

- GitHub Issue: [pgmac-net/homelabia#157](https://github.com/pgmac-net/homelabia/issues/157) — incident tracking issue
- GitHub Issue: [pgmac-net/homelabia#158](https://github.com/pgmac-net/homelabia/issues/158) — chronic k8s02 image GC failure (independent, surfaced during this investigation)
- Runbook: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md) — updated by this incident with the starvation variant and the scale-to-0 + fsck path
- Runbook: [jiva-csi-mount-proliferation.md](../runbooks/jiva-csi-mount-proliferation.md) — the duplicate bind mount pattern the remediation triggered
- Runbook: [dqlite-write-contention.md](../runbooks/dqlite-write-contention.md) — the trigger condition
- Runbook: [control-plane-watch-cache-freeze.md](../runbooks/control-plane-watch-cache-freeze.md) — the auto-remediation that fired
- Related incident: [pvek8s Storage Cascade — ArgoCD Sync Burst, Watch-Cache Freeze, and jiva iSCSI Read-Only Volumes](2026-07-13-argocd-sync-burst-watch-cache-freeze-jiva-ro.md) — same symptom via jiva-ctrl eviction
- Related incident: [pvek8s dqlite WAL Lock Storm — Jiva Controller Endpoint Deadlock](2026-06-28-dqlite-lock-storm-jiva-endpoint-deadlock.md) — dqlite storm reaching storage by a different path

---

## Reviewers

- @pgmac
