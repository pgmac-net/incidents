---
tags:
  - k8s01
  - k8s02
  - k8s03
  - argocd
  - dqlite
  - kine
  - openebs
  - jiva
  - watch-stream
  - crash-loop
  - storage
  - scheduling
---

# Post Incident Review: pvek8s Storage Cascade — ArgoCD Sync Burst, Watch-Cache Freeze, and jiva iSCSI Read-Only Volumes

**Date:** 2026-07-13
**Duration:** ~1h 8m active (~20:17 AEST → ~21:25 AEST); one contributing failure (corrupt jiva replica) pre-existed undetected for 14 days
**Severity:** Medium (two media services on dead storage ~35–45 min, one workspace volume on degraded redundancy; control plane self-healed in 76 s; no data loss)
**Status:** Resolved

---

## Executive Summary

At 20:17 AEST roughly ten ArgoCD applications auto-synced new image tags in a single burst (n8n, hass, cert-manager, cloudflared, trivy, calibre, renovate, system, media, sec). The resulting write load on dqlite broke the kine feed to the k8s03 apiserver watch cache — the same freeze mode as the 2026-07-09 and 2026-07-11 incidents. This time the watch-cache watchdog worked end-to-end unattended: strike 2 at 20:27, cordon → k8s-dqlite restart → kubelite restart → canary verification → uncordon, all in 76 seconds. The control-plane chain was a success story.

The collateral damage was storage. The kubelite restart rescheduled four jiva-ctrl pods from k8s03 to k8s02, killing their iSCSI targets while initiators held active sessions. After the 120-second iSCSI recovery timeout, EXT4 aborted its journal and remounted two volumes read-only: seerr's config volume (mounted on k8s03) and radarr's config volume (mounted on k8s02). radarr kept running on dead storage — its probes don't touch disk — while seerr's manually-deleted pod wedged in Terminating because jiva-csi cannot `chmod` a read-only mount during teardown.

Recovery followed the [jiva-ctrl eviction runbook](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md) with two refinements now folded back into it. First, a plain `kubectl delete` of radarr landed the replacement pod back on the same node where it silently reused the stale read-only global mount — cordon-first is mandatory, not an optional unstick manoeuvre. Second, the wedged seerr teardown needed only a single manual `umount` of the pod mount path; the global-mount teardown and iSCSI logout then completed on their own, and the transient `already mounted at more than one place` error on the new node self-cleared without patching the JivaVolume CR.

The cluster sweep also surfaced an unrelated 14-day-old failure: the coder-workspace volume's replica 1 had crash-looped 92 times with a broken snapshot chain (`volume.meta` referencing a snapshot image that no longer exists). The volume ran the whole time on 2/3 replicas with no alert escalation. The replica was rebuilt by wiping its backing data directory and letting it resync from the two healthy peers (~10 min for 5 GB) — procedure now captured in a new [corrupt snapshot chain runbook](../runbooks/jiva-replica-corrupt-snapshot-chain.md).

---

## Timeline (AEST — UTC+10)

| Time            | Event                                                                                                                                                        |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **~2026-06-28** | (Pre-existing) coder-workspace jiva replica 1 data directory left with broken snapshot chain; pod begins crash-looping, volume silently degraded to 2/3 replicas |
| **20:17**       | ArgoCD auto-syncs ~10 applications with new image tags in one burst                                                                                            |
| **20:21:57**    | k8s03 watch-cache watchdog strike 1/2 — RV=0 self-test shows apiserver watch cache not reflecting writes                                                       |
| **20:27:07**    | Strike 2/2 — watchdog triggers auto-remediation                                                                                                                |
| **20:27:24**    | Remediation cordons k8s03; restarts k8s-dqlite (20:27:25), then kubelite (20:27:45)                                                                            |
| **~20:28**      | kubelite restart reschedules 4 jiva-ctrl pods k8s03 → k8s02; active iSCSI sessions drop; after 120 s recovery timeout EXT4 aborts journals → seerr config ro on k8s03, radarr config ro on k8s02 |
| **20:28:23**    | Remediation SUCCESS: canary pod scheduled and visible in cache read; k8s03 uncordoned — 76 s end-to-end, no human involved                                     |
| **20:31**       | k8s03 manually re-cordoned (operator, initial triage)                                                                                                          |
| **20:32**       | seerr pod manually deleted; teardown wedges — jiva-csi NodeUnpublish fails `chmod ... read-only file system`, finalizer never clears                            |
| **20:52**       | Investigation session begins: survey finds seerr Error/Terminating, radarr Running on ro storage, k8s03 cordoned, ImageGC failing on k8s02/k8s03 (74%/71%), coder replica crash-looping (82 restarts, 14 d) |
| **~20:56**      | `/proc/mounts` survey across all 3 nodes confirms exactly two ro PVC mounts; watchdog journal on k8s03 identifies the 20:27 auto-remediation as the trigger    |
| **~20:58**      | radarr plain `kubectl delete pod` → replacement lands back on k8s02 and reuses the stale ro global mount — still broken                                        |
| **~21:03**      | k8s02 cordoned → radarr deleted again → lands k8s01, fresh iSCSI login, journal replay, mount **rw**; k8s02 uncordoned; stale k8s02 mounts confirmed gone      |
| **~21:08**      | Unused images pruned on k8s02/k8s03; disk 74% → 66%, ImageGC warnings stop                                                                                     |
| **~21:12**      | Operator runs manual `umount` of the wedged seerr pod mount on k8s03 → teardown completes, StatefulSet recreates pod on k8s02; transient `already mounted at more than one place` FailedMount self-clears on retry |
| **~21:15**      | seerr 1/1 Running on k8s02, mount rw; k8s03 uncordoned (operator); no stale iSCSI sessions anywhere                                                            |
| **~21:17**      | gharc-controller ArgoCD app found stuck `Progressing` since 2026-07-12 with all resources healthy — hard refresh annotation fixes it                           |
| **~21:13–21:23**| coder replica rebuild: controller API confirms 2/3 RW quorum; backing local-PV dir wiped via one-shot hostPath pod; replica pod deleted; full resync → **3/3 RW** |
| **~21:25**      | Final sweep: all pods healthy, all 44 ArgoCD apps Synced/Healthy, all nodes Ready                                                                              |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: k8s03 Watch-Cache Freeze — ArgoCD Sync Burst as a New Trigger

##### How did the k8s03 apiserver watch cache freeze?

The kine feed between dqlite and the apiserver watch cache broke under write load — the same failure mode as 2026-06-24, 2026-07-09, and 2026-07-11. All RV=0 reflectors on the node stalled.

##### How did the write load spike?

Roughly ten ArgoCD applications synced new image tags within the same minute (20:17). Each sync produced rolling pod replacements, status updates, endpoint churn, and image pulls across all three nodes — a concentrated dqlite write burst.

##### How did ten applications sync simultaneously?

Renovate-produced image bumps were merged in a batch, and ArgoCD's refresh cycle picked them all up in the same reconciliation window. There is no sync jitter, stagger, or concurrency limit configured on the ArgoCD application controller.

##### How was this not prevented?

dqlite's fragility under write bursts is a known, partially-mitigated condition (vacuum done 2026-06-28, condition-based maintenance restarts). The missing piece is demand-side: nothing rate-limits how many app syncs (and therefore how much cluster churn) land at once. Batched Renovate merges make bursts the default behaviour rather than the exception.

##### How was it detected and contained?

This chain is the success story: the node-local watch-cache watchdog (deployed 2026-07-09/11 after the previous two incidents) fired at strike 2 and the remediation script recovered the node in 76 seconds unattended — versus 5+ hours for each of the two prior occurrences.

---

#### Chain 2: Two Volumes Read-Only — jiva-ctrl Restart Drops Live iSCSI Sessions

##### How did the seerr and radarr filesystems go read-only?

Their iSCSI sessions died while I/O was in flight; after the 120-second session recovery timeout the kernel marked the SCSI devices offline, JBD2 aborted the ext4 journals, and both filesystems remounted read-only.

##### How did the iSCSI sessions die?

The remediation's kubelite restart on k8s03 rescheduled the four jiva-ctrl pods hosted there to k8s02. Each jiva-ctrl pod is the iSCSI target for its volume; the target processes exited while initiators on other nodes held active sessions.

##### How does one controller restart kill the session permanently?

Jiva is a single-controller architecture — there is no target redundancy or multipath. The initiator's `replacement_timeout` of 120 s is shorter than the time it takes a jiva-ctrl pod to be rescheduled, pulled, and re-registered, so the session is declared dead before the target returns.

##### How was this not prevented?

The two structural mitigations identified in the 2026-05-28 PIR were never implemented: extended `NoExecute` toleration on jiva-ctrl pods (ex-PGM-222) and raising `node.session.timeo.replacement_timeout` to 300 s (ex-PGM-221 adjacent). Additionally, the automated remediation restarts kubelite without the jiva pre-migration check that the [rolling-restart runbook](../runbooks/jiva-ctrl-node-rolling-restart.md) prescribes for humans — a deliberate trade-off (a frozen node must be fixed in seconds, not after a 10-minute workload migration), which makes the timeout/toleration mitigations the only viable ones.

##### How was it detected?

The `microk8s-ro-pvc-mounts` and `microk8s-storage-kernel-errors` checks (shipped 2026-07-11) cover exactly this state, and the manual `/proc/mounts` survey from the runbook confirmed the full blast radius in one command.

---

#### Chain 3: Recovery Friction — Same-Node Relanding and Wedged Teardown

##### How did radarr stay broken after its pod was deleted?

The replacement pod scheduled back onto k8s02 (k8s03 was cordoned, and the scheduler has no memory of the failure) and bind-mounted the existing stale read-only global iSCSI mount instead of triggering a detach/reattach.

##### How did the stale global mount survive the pod deletion?

kubelet only tears down the global mount and logs out the iSCSI session when no pod on the node references the volume. The replacement pod claimed the volume before teardown ran, so the ro mount was inherited as-is.

##### How did the seerr pod wedge in Terminating for ~40 minutes?

jiva-csi's NodeUnpublish runs `chmod` on the mount directory, which fails with `EROFS` on a read-only filesystem; the CSI driver made one unmount attempt at 20:32:07 that never completed and never retried, so the deletion finalizer was never cleared.

##### How was this friction not prevented?

The runbook's fast path listed cordon-first only as a conditional "unstick manoeuvre" rather than a mandatory step, and the wedged-teardown procedure implied a multi-step recovery (pod umount + globalmount umount + iSCSI logout + CR patch) when a single pod-mount `umount` is sufficient. Both refinements are now folded into the runbook.

---

#### Chain 4: Coder-Workspace Replica Crash-Looping 14 Days — Corrupt Snapshot Chain, No Escalation

##### How did the replica crash-loop?

On startup the replica opens its volume by rebuilding the snapshot chain from `volume.meta`; the chain referenced `volume-snap-000.img`, which did not exist on disk (the head image was missing entirely, with 11 orphaned snapshot images present). The open fails, the controller connection drops, and the replica process exits — every time, 92 restarts over 14 days.

##### How did the data directory become inconsistent?

Not directly observed. The corruption window opens at the 2026-06-28 dqlite lock storm (the dir's oldest orphan dates to 28 Jun) with further churn during the 2026-07-12 restarts — jiva replica snapshot-chain updates are not atomic across `volume.meta` and the image files, so an ill-timed kill can strand the metadata pointing at never-created or already-deleted images.

##### How did a crash-looping replica persist for 14 days?

The volume kept serving from 2/3 RW replicas, so there was no user-visible impact to force attention. Jiva-operator has no auto-rebuild for a replica that fails to open — it will restart the pod forever rather than re-register it empty and resync.

##### How was it not detected?

A jiva pod health NRPE check was deployed on 2026-07-11 and this replica was already crash-looping then — either the check does not cover this pod naming pattern (`*-jiva-rep-N` bare StatefulSet pods, vs the `*-rep-N-<hash>` Deployment pods) or it alerted into an unhandled queue. This is the concrete monitoring gap to close.

---

## Impact

### Services Affected

| Service                          | Impact                                                                        | Duration  |
| -------------------------------- | ----------------------------------------------------------------------------- | --------- |
| seerr (media)                    | Down — pod Error then wedged Terminating on ro config volume                   | ~43 min   |
| radarr (media)                   | Running on read-only storage — UI up, all writes/imports failing silently      | ~35 min   |
| k8s03 scheduling                 | Cordoned (76 s automated + ~45 min manual re-cordon during triage)             | ~47 min   |
| coder-workspace volume (8ecc)    | Degraded redundancy — 2/3 replicas RW, no user-visible impact                   | ~14 days  |
| gharc-controller (ArgoCD app)    | Cosmetic — stuck `Progressing` health with healthy resources                    | ~30 h     |

### Duration

- **Total incident window:** ~1h 8m (20:17 → 21:25 AEST)
- **Control-plane freeze (automated recovery):** 76 s
- **Expected recovery time with updated runbook:** ~15 min (cordon-first from the start, umount wedged teardown immediately)

### Scope

- All three nodes involved: freeze on k8s03, ro mounts on k8s02 and k8s03, recovery reschedules onto k8s01
- **Data loss: none** — ext4 journal replay recovered both volumes cleanly; replica rebuilt from healthy peers
- User-visible impact limited to seerr (down) and radarr (writes failing)

---

## Resolution Steps Taken

### Phase 1: Diagnosis

1. Cluster survey: `kubectl get nodes` / non-Running pods / ArgoCD app health — found seerr Error, coder replica CrashLoopBackOff, k8s03 cordoned, gharc-controller Progressing.
2. `kubectl describe pod seerr-seerr-chart-0 -n media` → `chmod ...: read-only file system` — matched the [jiva-ctrl eviction runbook](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md) signature.
3. ArgoCD sync times (`.status.operationState.finishedAt`) showed the ~10-app burst at 20:17; jiva-ctrl pod ages (24–32 min, all on k8s02) matched the 20:27 remediation.
4. Runbook ro-mount survey: `for n in k8s01 k8s02 k8s03; do ssh $n "grep -E 'pvc-.* ext4 ro' /proc/mounts"; done` → exactly two ro volumes.
5. `journalctl -u watch-cache-watchdog -u watch-cache-remediate` on k8s03 → full automated remediation record, 20:27:07–20:28:23.
6. Node `managedFields` showed the 20:31 re-cordon was a manual `kubectl` write, not the watchdog.

### Phase 2: radarr (ro volume on k8s02)

1. Plain `kubectl delete pod` — **failed**: replacement landed back on k8s02 and reused the stale ro global mount.
2. `kubectl cordon k8s02` → delete pod → replacement landed k8s01, fresh iSCSI login, journal replay → mount **rw**. `kubectl uncordon k8s02`.
3. Verified stale mounts gone from k8s02 (`grep a634b9a3 /proc/mounts` → empty).

### Phase 3: seerr (wedged Terminating on k8s03)

1. Manual unmount of the wedged pod mount (operator-run — node-level writes require human execution):
   ```bash
   ssh k8s03 sudo umount /var/snap/microk8s/common/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/pvc-746b2837-.../mount
   ```
2. Teardown finalizer cleared within seconds; StatefulSet recreated the pod on k8s02.
3. One transient `already mounted at more than one place` FailedMount, then jiva-csi retried successfully — **no JivaVolume CR patch, no iSCSI logout, no globalmount umount needed**.
4. seerr 1/1 Running, mount rw, no stale sessions on k8s03 (`iscsiadm -m session`).

### Phase 4: coder-workspace replica rebuild

1. Confirmed quorum before touching anything: jiva controller API showed 2 replicas RW.
2. Wiped the corrupt replica's backing local-PV directory via a one-shot busybox hostPath pod pinned to k8s02 (cleaned up immediately after).
3. Deleted the replica pod → re-registered WO → full resync → **3/3 RW in ~10 min**.

### Phase 5: Housekeeping

1. Pruned unused images on k8s02/k8s03 (`crictl rmi --prune`) — disk 74% → 66%, ImageGC warnings stopped.
2. gharc-controller stale health: `kubectl annotate application gharc-controller -n argocd argocd.argoproj.io/refresh=hard --overwrite` → Healthy.

---

## Verification

```bash
# No non-running pods
kubectl --context pvek8s get pods -A | grep -v Running | grep -v Completed
# → (empty)

# All ArgoCD apps healthy
kubectl --context pvek8s get applications -n argocd --no-headers | grep -v 'Synced.*Healthy'
# → (empty)

# No read-only PVC mounts on any node
for n in k8s01 k8s02 k8s03; do ssh $n "grep -E 'pvc-.* ext4 ro' /proc/mounts"; done
# → (empty)

# Coder volume fully replicated
kubectl --context pvek8s exec -n openebs <jiva-ctrl-pod> -c jiva-controller -- \
  curl -s http://localhost:9501/v1/replicas | jq -r '.data[] | "\(.address) \(.mode)"'
# → three lines, all RW
```

---

## Preventive Measures

### Immediate Actions Required

1. **Close the jiva replica crash-loop detection gap** (High)
    - Chain 4: a replica crash-looped 92× over 14 days with zero escalation. Verify the jiva pod health check covers bare `*-jiva-rep-N` StatefulSet pods and that prolonged CrashLoopBackOff in the openebs namespace pages.
    - Issue: [pgmac-net/ansible#219](https://github.com/pgmac-net/ansible/issues/219)

2. **Extend jiva-ctrl NoExecute toleration and raise iSCSI replacement_timeout** (High)
    - Chain 2: both structural mitigations from the 2026-05-28 PIR were never implemented and would have prevented (timeout) or reduced (toleration) tonight's ro volumes. `tolerationSeconds=600` on jiva-ctrl pods; `node.session.timeo.replacement_timeout` 120 s → 300 s on all nodes.
    - Issue: [pgmac-net/homelabia#145](https://github.com/pgmac-net/homelabia/issues/145)

### Longer-Term Improvements

3. **Stagger ArgoCD sync bursts** (Medium)
    - Chain 1: batched Renovate merges cause ~10 simultaneous app syncs, and dqlite write bursts are this cluster's most reliable incident trigger. Investigate ArgoCD controller sync jitter/concurrency limits, or schedule Renovate to spread merges.
    - Issue: [pgmac-net/pgk8s#594](https://github.com/pgmac-net/pgk8s/issues/594)

4. **Investigate ArgoCD stale health assessments** (Low)
    - gharc-controller sat `Progressing` for 30 h with fully healthy resources until a hard refresh. If recurring, a periodic hard-refresh or controller tuning is warranted.
    - Issue: [pgmac-net/pgk8s#595](https://github.com/pgmac-net/pgk8s/issues/595)

---

## Lessons Learned

### What Went Well

- **The watch-cache watchdog paid for itself**: 76 s unattended recovery for a failure mode that took 5h 19m (2026-07-09) and 5h 40m (2026-07-11) when humans were in the loop. Two incidents' worth of hardening held on the third try.
- The 2026-07-11 ro-mount alerting and runbook survey command identified the complete storage blast radius in under a minute.
- Checking `managedFields` on the node object cleanly distinguished the manual 20:31 re-cordon from watchdog action — avoided filing a false bug against the remediation script.
- Confirming 2/3 RW quorum via the jiva controller API before wiping the corrupt replica made a destructive-looking operation provably safe.

### What Didn't Go Well

- The first radarr fix attempt (plain delete) was wasted motion — the runbook listed cordon-first as conditional when it is effectively mandatory for Deployment pods, since the scheduler happily relands on the poisoned node.
- The seerr pod had been wedged in Terminating for ~40 min (since 20:32) before investigation began; the CSI driver's single non-retried unmount attempt gives no signal that it will never self-heal.
- Structural mitigations identified six weeks ago (toleration, iSCSI timeout) were tracked in decommissioned Linear tickets and silently lost — this is the second PIR in a row where "planned but never implemented" items caused or worsened impact.

### Surprise Findings

- A single `umount` of the pod mount path is the complete fix for the wedged-Terminating state — globalmount teardown and iSCSI logout complete on their own, and the `already mounted at more than one place` error self-clears on jiva-csi's next retry. The runbook's four-step stale-state procedure is rarely needed.
- The corrupt replica's data directory contained 11 snapshot images (5 GB) but no head image at all — the chain was not just broken but headless, which jiva handles by crashing rather than re-registering empty.
- ArgoCD app health can silently stick (`Progressing`, 30 h) with every underlying resource healthy; a hard-refresh annotation is the fix.

---

## Action Items

| #   | Action                                                                                              | Priority | GitHub    |
| --- | --------------------------------------------------------------------------------------------------- | -------- | --------- |
| 1   | Verify jiva pod health check covers `*-jiva-rep-N` pods; page on prolonged openebs CrashLoopBackOff | High     | [pgmac-net/ansible#219](https://github.com/pgmac-net/ansible/issues/219) |
| 2   | Implement jiva-ctrl `tolerationSeconds=600` + iSCSI `replacement_timeout` 300 s                      | High     | [pgmac-net/homelabia#145](https://github.com/pgmac-net/homelabia/issues/145) |
| 3   | Stagger ArgoCD sync bursts (controller jitter/concurrency or Renovate schedule)                      | Medium   | [pgmac-net/pgk8s#594](https://github.com/pgmac-net/pgk8s/issues/594) |
| 4   | Investigate ArgoCD stale health assessment (Progressing 30 h with healthy resources)                 | Low      | [pgmac-net/pgk8s#595](https://github.com/pgmac-net/pgk8s/issues/595) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03)
- **Kubernetes version:** v1.35.0 (microk8s), containerd 2.1.3
- **OS:** Ubuntu 20.04.6, kernel 5.4.0-231-generic
- **Storage:** OpenEBS Jiva 3.6.0 (iSCSI), local PV replicas

### Key Error Signatures

```
# Watch-cache freeze (watchdog journal)
strike 2/2 - triggering remediation (CRITICAL - watch cache did not reflect a write after 30s ...)

# Wedged CSI teardown on ro filesystem
MountVolume.SetUp failed ... chmod .../volumes/kubernetes.io~csi/<pvc>/mount: read-only file system

# Same-node relanding / stale global mount (transient during recovery)
MountVolume.MountDevice failed ... volume {<pvc>} is already mounted at more than one place

# Corrupt replica snapshot chain (replica log, --previous)
Error link openebs/volume-head-017.img openebs/volume-snap-000.img: no such file or directory during open
Failed to handle connection, err: EOF, shutdown replica...
```

### Attribution Check for Unexpected Cordons

```bash
# Who last set unschedulable — distinguishes watchdog vs manual kubectl
kubectl get node <node> --show-managed-fields -o json | \
  jq -r '.metadata.managedFields[] | select(.fieldsV1|tostring|contains("unschedulable")) | "\(.manager) \(.operation) \(.time)"'
```

### ArgoCD Sync Burst Reconstruction

```bash
# Apps by last sync time with images — identifies what synced when
kubectl get applications -n argocd -o json | jq -r \
  '.items[] | select(.status.operationState.finishedAt != null) |
   [.metadata.name, .status.operationState.finishedAt, (.status.summary.images // [] | join(","))] | @tsv' |
  sort -k2 -r | head -20
```

---

## References

- Runbook: [Jiva-ctrl Eviction → iSCSI → EXT4 Read-Only](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md) — updated with cordon-first and single-umount findings from this incident
- Runbook: [Jiva Replica Corrupt Snapshot Chain](../runbooks/jiva-replica-corrupt-snapshot-chain.md) — new, from Chain 4
- Runbook: [Control-Plane Watch-Cache Freeze](../runbooks/control-plane-watch-cache-freeze.md)
- Related incident: [pvek8s Scheduling Outage — k8s03 Watch-Cache Freeze and Stale-Unit Watchdog Lockout](2026-07-11-k8s03-watch-cache-freeze-stale-unit-lockout.md)
- Related incident: [pvek8s Scheduling Outage — k8s03 Watch-Cache Freeze and Auto-Remediation Delivery Failure](2026-07-09-k8s03-watch-cache-freeze-remediation-delivery-failure.md)
- Related incident: [pvek8s Post-Power-Outage Recovery — kubelet Volume Manager Stall and KCM Stale terminatingReplicas](2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md) — origin of the never-implemented structural mitigations
- Historical: PGM-221, PGM-222 (Linear, decommissioned) — the lost mitigation tickets superseded by this PIR's action items

---

## Reviewers

- @pgmac
