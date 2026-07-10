---
tags:
  - k8s01
  - k8s02
  - k8s03
  - kine
  - dqlite
  - watch-stream
  - scheduling
  - openebs
  - jiva
---

# Post Incident Review: pvek8s Scheduling Outage — k8s03 Watch-Cache Freeze and Stale-Unit Watchdog Lockout

**Date:** 2026-07-11
**Duration:** ~3h 0m scheduling outage (~02:32 AEST → ~05:32 AEST); ~5h 40m total including storage collateral (~02:15 → ~07:55)
**Severity:** High (100% of new pod scheduling stopped cluster-wide for ~3h; existing workloads kept running)
**Status:** Resolved

---

## Executive Summary

At ~02:15 AEST a dqlite write-contention storm (`database is locked` errors on k8s01 and k8s03, dominated by openebs jiva replica event writes) broke the apiserver→kine watch streams on all three nodes. k8s02's watch cache recovered on its own within minutes and k8s01 was auto-remediated successfully at 02:30 by the watch-cache automation. k8s03 — which at the time held **both** the `kube-scheduler` and `kube-controller-manager` leader leases — stayed frozen, so from ~02:32 nothing scheduled anywhere in the cluster: every new pod sat Pending with no events, CronJobs piled up 36 missed windows, and dependent services (including the Nagios MCP endpoint) became unreachable.

The auto-remediation designed for exactly this failure was locked out by a new delivery-failure mode. k8s03's first remediation attempt at 02:29 correctly **DEFERRED** because k8s01 held the cluster remediation lease — but the DEFERRED path exits 1, which left the transient `watch-cache-remediate.service` unit in systemd `failed` state. The trigger script guards only with `systemctl is-active`, so every subsequent `systemd-run --unit=watch-cache-remediate` failed on the unit-name collision. The node-local watchdog reached strike 2/2 and attempted to launch remediation **17 consecutive times over 2h49m** (02:40 → 05:18), each one logging `WARNING: failed to launch remediation unit` — and nothing monitors that launch path, so the lockout was invisible.

Nagios detection and notification worked: `microk8s-watch-cache` went HARD CRITICAL on k8s03 at 02:26 and Slack/Zulip notifications fired at 02:25–02:27, 03:27, and 04:32 — but the single operator was asleep, which is precisely the scenario the unattended auto-remediation exists to cover. Human response began at ~05:20 when application outages and the Nagios MCP returning 503 were noticed.

Recovery followed the existing [control-plane watch-cache freeze runbook](../runbooks/control-plane-watch-cache-freeze.md): cordon k8s03, restart `k8s-dqlite` then `kubelite` (in that order), verify with an RV=0 write-reflection canary plus a nodeName-pinned canary pod, then uncordon. Scheduling resumed immediately; the 3h CronJob backlog self-drained; the stale failed unit was cleared with `systemctl reset-failed`. The script fix for the lockout is tracked in [pgmac-net/homelabia#137](https://github.com/pgmac-net/homelabia/issues/137), and the runbook gained a "delivery failure #2" section in [incidents PR#57](https://github.com/pgmac-net/incidents/pull/57).

The storm also left storage collateral that outlived the control-plane recovery: iSCSI I/O errors during the contention window aborted EXT4 journals, and **six jiva volumes remounted read-only** across all three nodes (seerr, readarr, radarr, sonarr, calibre-web, survive-minecraft). Five of the six apps kept reporting `1/1 Running` on dead storage because their probes never touch disk; readarr had in fact been crash-looping on a read-only volume for ~8 days, misattributed to slow storage. All six were recovered ~07:10–07:55 AEST by deleting each pod so kubelet re-attached the volume fresh (journal replay → rw), plus three unstick manoeuvres: a jiva-ctrl restart to drop a stale single-initiator session (radarr), a cordon to stop a pod re-landing on its stale ro global mount (sonarr), and one manual `umount` of a bind mount stranded by a force-delete (seerr).

This is the third watch-cache freeze incident (after [2026-06-24](2026-06-24-k8s02-watch-cache-freeze-dqlite-leadership-disruption.md) and [2026-07-09](2026-07-09-k8s03-watch-cache-freeze-remediation-delivery-failure.md)) and the second consecutive one where the freeze itself was routine but the auto-remediation delivery layer failed in a new way.

---

## Timeline (AEST — UTC+10)

| Time | Event |
| --- | --- |
| **~02:15 AEST** | dqlite write-contention storm begins: `database is locked` (try: 500) errors on k8s01 and k8s03; brief `no known leader` on k8s01 at 02:15:17. Storm keys dominated by openebs jiva replica pod/event writes |
| **~02:20 AEST** | apiserver watch caches freeze on all three nodes as kine watch streams break |
| **02:22 AEST** | iSCSI I/O errors during the storm abort EXT4 journals — six jiva volumes remount read-only across all 3 nodes (seerr, readarr, radarr, sonarr, calibre-web, survive-minecraft configs/data); affected apps keep reporting Running |
| **02:24 AEST** | Nagios `microk8s-watch-cache` goes CRITICAL for k8s03 (SOFT 2, event handler fired); k8s03 node-local watchdog logs strike 1/2 |
| **02:25–02:27 AEST** | k8s01 and k8s03 reach HARD CRITICAL; event handlers fired; Slack + Zulip notifications sent |
| **02:28 AEST** | k8s02 watch cache recovers on its own (`OK - watch cache reflected write in 0s`) |
| **02:29:16 AEST** | k8s01 remediation starts, acquiring the cluster-wide remediation Lease; restarts k8s-dqlite then kubelite on k8s01 |
| **02:29:38 AEST** | k8s03 watchdog strike 2/2 launches its remediation → **DEFERRED** (`remediation lease held by k8s01`), exits 1 — transient `watch-cache-remediate.service` left in systemd `failed` state |
| **02:30:27 AEST** | k8s01 remediation SUCCESS: canary verified in RV=0 cache read, node uncordoned |
| **~02:32 AEST** | First `k8s-heartbeat` pod goes Pending with no events — cluster-wide scheduling outage begins. k8s03 holds both `kube-scheduler` and `kube-controller-manager` leases; both leaders are serving a frozen cache |
| **02:40 AEST** | k8s03 watchdog strike 2/2 again → `WARNING: failed to launch remediation unit on k8s03` (systemd-run name collision with the stale failed unit). This repeats every ~10 minutes — **17 consecutive lockouts** through 05:18 |
| **03:27, 04:32 AEST** | Nagios re-notifications for k8s03 `microk8s-watch-cache` CRITICAL (Slack + Zulip); no human response — overnight |
| **~05:20 AEST** | Operator notices applications down and Nagios MCP returning HTTP 503; investigation begins |
| **05:25 AEST** | Diagnosis: ~36 heartbeat pods Pending (no events), nodes all Ready; `kube-scheduler` and `kube-controller-manager` leases both held by k8s03; k8s03 watchdog journal shows strike 2/2 + launch failure |
| **05:26 AEST** | `kubectl cordon k8s03`; baseline of 5 jiva-ctrl pods on k8s03 recorded (all Running 2/2) |
| **05:27 AEST** | `snap.microk8s.daemon-k8s-dqlite` restarted on k8s03 (clean raft rejoin, no lock errors), then `snap.microk8s.daemon-kubelite` |
| **~05:29 AEST** | Node Ready; RV=0 write-reflection canary passed; nodeName-pinned canary pod Running on k8s03 in 13s; `kubectl uncordon k8s03` |
| **05:32 AEST** | Nagios `microk8s-watch-cache` k8s03 returns OK. New `k8s-heartbeat` job completes end-to-end; stale 3h backlog job GC'd |
| **~05:35 AEST** | Nagios MCP returns HTTP 200; `systemctl reset-failed watch-cache-remediate.service` applied on k8s03; leases redistributed normally (KCM → k8s01) — scheduling outage resolved |
| **~06:50 AEST** | Storage collateral discovered: seerr not Ready (`FailedMount ... read-only file system`), readarr crash-looping (exit 143, SQLite ops 25–46s = write retries against EROFS). Node survey finds six ro jiva mounts across all 3 nodes |
| **07:10–07:40 AEST** | Rolling pod recreations remount volumes rw: calibre-web, readarr, minecraft, sonarr (after cordon — first replacement re-landed on its stale ro global mount), radarr (after jiva-ctrl restart to drop a stale k8s01 iSCSI session blocking single-initiator login) |
| **~07:55 AEST** | seerr recovered last: force-delete had stranded one bind mount on k8s01, wedging kubelet's UnmountDevice (`GetDeviceMountRefs check failed`); manual `umount` of the leftover path unblocked unstage → iSCSI logout → k8s03 stage succeeded. All six services 1/1 Running — incident fully resolved |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: All New Pods Pending Cluster-Wide — Frozen Watch Cache on the Dual-Leader Node

##### How did every new pod sit Pending with no events for 3 hours?

The kube-scheduler leader never saw them. Its reflector lists at `resourceVersion=0` against its local apiserver's watch cache on k8s03, which was frozen — new pods existed in quorum reads but never appeared in the cache the scheduler consumes. KCM leadership was also on k8s03, so CronJob controller, Deployment reconciliation, and Job GC stopped too.

##### How did k8s03's watch cache freeze?

The apiserver's watch on kine (`snap.microk8s.daemon-k8s-dqlite`) broke during a dqlite disturbance and never recovered — the known PGM-241 failure mode. All three nodes' caches froze at ~02:20; k8s02's watch stream happened to reconnect cleanly by 02:28, k8s01 was auto-remediated, k8s03 stayed frozen.

##### How did the kine watch streams break?

A sustained dqlite write-contention storm from ~02:15: `database is locked` at 500 retries across both k8s01 and k8s03, plus a brief `no known leader` window — the same trigger conditions documented in [dqlite-write-contention.md](../runbooks/dqlite-write-contention.md) (PGM-237).

##### How did the write-contention storm arise?

The storm's keys were dominated by openebs jiva replica pod updates and event writes (`/registry/events/openebs/pvc-*-rep-*`, `/registry/pods/openebs/...`). Four jiva replica pods have been crash-looping for 17h–12d (pre-existing baseline), each restart cycle generating event and status writes, layered on the chronic lease-churn write load and dqlite snapshot/freelist pressure (pgk8s#577).

##### How was the freeze not self-healed by Kubernetes?

microk8s ships the apiserver with `DetectCacheInconsistency=false` because kine cannot support the consistency probes — upstream's self-healing for exactly this state is disabled. A frozen cache persists until the process is restarted. This is an upstream limitation; the compensating control is our watch-cache auto-remediation layer — which was locked out (Chain 2).

---

#### Chain 2: Auto-Remediation Locked Out for 2h49m — Stale Failed Unit Blocks systemd-run

##### How did the freeze persist for ~3 hours when the node-local watchdog detected it within 10 minutes?

The watchdog reached strike 2/2 and attempted to launch remediation 17 times between 02:40 and 05:18. Every attempt logged `WARNING: failed to launch remediation unit on k8s03` — the remediation never started.

##### How did every launch attempt fail?

`systemd-run --unit=watch-cache-remediate` refuses to start when a unit of that name already exists in the systemd manager. A stale `watch-cache-remediate.service` was loaded in `failed` state the whole time.

##### How did the unit end up in failed state?

The 02:29:38 remediation attempt correctly **DEFERRED** because k8s01 held the cluster-wide remediation Lease (the multi-node safety working as designed) — but the DEFERRED code path exits 1, so systemd recorded the transient unit as `failed`. Nothing in any script calls `systemctl reset-failed`, so the unit stayed loaded indefinitely.

##### How did the trigger script not handle this?

`event_watch_cache_remediate.sh` guards re-entry only with `systemctl is-active --quiet watch-cache-remediate.service` — true only while *running*. Using the unit name as a per-node mutex was deliberate, but the design never accounted for "failed and never reset" as a terminal stuck state. A benign DEFERRED therefore permanently disarmed the watchdog path on that node.

##### How was the lockout not detected?

Nothing monitors the remediation launch path. The watchdog logged the launch failure 17 times to the node journal, but no Nagios check or alert consumes that signal — the automation reported its own defeat into a log nobody watches. This is the meta-monitoring gap ([pgmac-net/homelabia#138](https://github.com/pgmac-net/homelabia/issues/138)).

---

#### Chain 3: ~3h Human Response Despite Working Notifications

##### How did human response take ~3 hours when Nagios alerted within 9 minutes of the storm?

Slack and Zulip notifications fired at 02:25–02:27 and re-fired at 03:27 and 04:32 AEST — overnight for a single-operator homelab. The operator was asleep and engaged at ~05:20 after noticing application outages.

##### How was overnight unattended recovery supposed to work?

This is a deliberate trade-off: no 24/7 on-call exists for a homelab. The compensating control for overnight incidents *is* the auto-remediation layer (watchdog + Nagios event handler), which handled k8s01 perfectly and was locked out on k8s03 by Chain 2. The residual action is not more paging — it's making the automation's own failures alert-worthy (Chain 2's action items) so the automation stays trustworthy.

---

#### Chain 4: Six Apps Running on Read-Only Storage — Undetected EXT4 Journal Aborts

##### How did six services stay broken for hours after the control plane recovered?

Their jiva volumes were mounted read-only on the workload nodes. Every config/database write failed (`EROFS`), but five of the six pods kept reporting `1/1 Running`, so nothing flagged them; they surfaced only when checked by hand.

##### How did the volumes become read-only?

During the 02:15 write-contention storm, jiva targets/replicas stopped answering iSCSI I/O. The kernel marked the SCSI devices offline, in-flight writes returned I/O errors, JBD2 aborted the ext4 journals, and ext4 remounted each filesystem read-only — the documented [jiva-ctrl eviction → iSCSI → EXT4-ro](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md) cascade (PGM-224), triggered this time by the storm rather than an eviction.

##### How did the failure stay invisible?

App probes never touch disk: tcp-socket and HTTP-status probes pass on a process whose writes all fail. readarr — the one app whose probes indirectly depended on disk — had been crash-looping for ~8 days (SQLite operations taking 25–46s were write retries against `EROFS`, then the startupProbe killed it at 150s), misread as slow storage rather than read-only storage.

##### How was read-only storage not alerted on?

No monitoring exists for `ext4 ro` PVC mounts in `/proc/mounts` or for `EXT4-fs error` / `Aborting journal` kernel signatures. This exact gap was identified in the 2026-05-28 PIR (PGM-221, "log-based alerts on EXT4 ro remount") and never implemented. Now tracked concretely as [pgmac-net/homelabia#140](https://github.com/pgmac-net/homelabia/issues/140).

---

## Impact

### Services Affected

| Service | Impact | Duration |
| --- | --- | --- |
| All new pod scheduling (cluster-wide) | 100% stopped — pods Pending with no events | ~3h 0m |
| kube-controller-manager reconciliation | CronJobs, Deployment/Job reconciliation, GC stopped (leader on frozen node) | ~3h 0m |
| `k8s-heartbeat` CronJob (kube-system) | 36 missed 5-minute windows; `Forbid` concurrency blocked by stuck job | ~3h 0m |
| Nagios MCP (`nagios-mcp.int.pgmac.net`) | HTTP 503 — pod Running but endpoints stale behind frozen control plane | ~3h |
| CI automation (`ci/automation-job-2426`) | Job pod never scheduled | ~3h |
| Applications requiring new pods (restarts, jobs, scaling) | Unable to start any new workload | ~3h 0m |
| seerr, radarr, sonarr, calibre-web, minecraft configs/data | Volumes read-only — all writes failing while pods reported Running | ~5h 30m (02:22 → 07:10–07:55) |
| readarr | Crash-looping on read-only volume (startupProbe kills during EROFS write retries) | ~8 days (pre-existing, same failure mode) |

### Duration

- **Total incident window:** ~5h 40m (02:15 → 07:55 AEST, including storage collateral)
- **Scheduling outage:** ~3h 0m (02:32 → 05:32 AEST)
- **Auto-remediation lockout:** 2h 49m, 17 failed launch attempts (02:29 → 05:18 AEST)
- **Read-only storage on six volumes:** ~5h 30m (02:22 → 07:10–07:55 AEST); readarr's volume ~8 days
- **Active human recovery time:** ~15 min for the control plane (05:20 → 05:35, runbook worked first time) + ~65 min for the storage collateral (06:50 → 07:55)

### Scope

- Nodes: k8s03 frozen throughout; k8s01 frozen ~10 min (auto-remediated); k8s02 frozen ~8 min (self-recovered); ro jiva mounts on all three nodes
- Data loss: none confirmed — ext4 journal replay recovered every volume cleanly on remount; writes during the ro window were refused, not corrupted
- Existing running workloads: unaffected unless jiva-backed — six jiva-backed apps lost all writes while appearing healthy

---

## Resolution Steps Taken

### Phase 1: Diagnosis

1. Confirmed all 3 nodes Ready but ~36 `k8s-heartbeat` pods Pending (one per 5-minute window) with `Events: <none>` — the signature of a scheduler that never saw the pods, not a scheduling failure.
2. `kubectl get lease -n kube-system kube-scheduler kube-controller-manager` — both held by k8s03, still renewing (lease goroutines don't depend on the cache).
3. Checked auto-remediation journals on all nodes: k8s01 `SUCCESS` at 02:30; k8s02 clean; k8s03 showed the 02:29 `DEFERRED` and current watchdog strikes with `WARNING: failed to launch remediation unit`.
4. Root cause of lockout confirmed on k8s03: `watch-cache-remediate.service` loaded in `failed` state since the 02:29 DEFERRED exit 1; `event_watch_cache_remediate.sh` guards only with `is-active`.

### Phase 2: Fix (per [control-plane-watch-cache-freeze.md](../runbooks/control-plane-watch-cache-freeze.md))

1. Recorded baseline: 5 jiva-ctrl pods on k8s03 all Running 2/2 (safe to restart services).
2. `kubectl cordon k8s03` — mandatory before touching kubelite.
3. `ssh k8s03 sudo systemctl restart snap.microk8s.daemon-k8s-dqlite` — clean raft rejoin, no `database is locked` errors, no crash loop. Waited ~20s for settling.
4. `ssh k8s03 sudo systemctl restart snap.microk8s.daemon-kubelite` — dqlite before kubelite, or the new kubelite stalls at birth.
5. `kubectl wait --for=condition=Ready node/k8s03` — Ready within timeout.
6. `sudo systemctl reset-failed watch-cache-remediate.service` on k8s03 — cleared the stale failed unit so the watchdog trigger path is re-armed for the next freeze.

### Phase 3: Verification (before uncordon)

1. RV=0 write-reflection canary: created a configmap, confirmed it appeared in a `resourceVersion=0` cached read — cache thawed, not just restarted.
2. nodeName-pinned canary pod on k8s03 reached Running in 13s — kubelet watch live, not just node-condition Ready.
3. `kubectl uncordon k8s03`.
4. Fresh `k8s-heartbeat` job completed end-to-end; 3h backlog job and its stuck pods self-drained via GC once KCM recovered.
5. Nagios MCP endpoint returned HTTP 200; Nagios `microk8s-watch-cache` k8s03 OK at 05:32.

### Phase 4: Storage Collateral (per [jiva-ctrl-eviction-iscsi-ro-filesystem.md](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md))

1. Surveyed all nodes: `grep -E 'pvc-.* ext4 ro' /proc/mounts` — six ro jiva volumes found; dmesg confirmed `Detected aborted journal` + `rejecting I/O to offline device` from 02:22.
2. Deleted each affected pod so kubelet re-attached the volume fresh (unmount → iSCSI logout → fresh login → ext4 journal replay → rw). This alone recovered calibre-web, readarr, and minecraft.
3. sonarr: replacement pod re-landed on the same node and bind-mounted the stale ro global mount — cordoned the node, deleted the pod again, uncordoned once it rescheduled elsewhere.
4. radarr: new node's iSCSI login rejected (`target already connected` — jiva single-initiator, stale session from a previous node). Restarted the jiva-ctrl pod to drop all sessions; the new node won the re-login.
5. seerr: the earlier force-delete stranded one duplicate bind mount (of 8 — mount proliferation), wedging kubelet's UnmountDevice loop (`GetDeviceMountRefs check failed`, retrying every 2m2s forever). One manual `umount` of the leftover pod path unblocked unstage → iSCSI logout → the pending stage on the new node succeeded within 2 minutes.
6. Verified zero `ext4 ro` PVC mounts on all nodes and all six apps `1/1 Running`.

---

## Verification

```bash
# No pods stuck Pending (after backlog drains)
kubectl --context pvek8s get pods -A --field-selector status.phase=Pending --no-headers | wc -l
# → 0

# Newest pod is fresh (per-5-min cronjobs prove the scheduler is live)
kubectl --context pvek8s get pods -A --sort-by=.metadata.creationTimestamp --no-headers | tail -1
# → a pod < 5m old

# Watch cache reflects writes on k8s03 (nagios check green)
ssh macro 'docker exec nagios4 grep -a "k8s03;microk8s-watch-cache;OK" /opt/nagios/var/nagios.log | tail -1'
# → OK - watch cache reflected write in 0s

# Watchdog trigger path re-armed
ssh k8s03 "systemctl is-failed watch-cache-remediate.service"
# → inactive (NOT 'failed')

# Nagios MCP reachable
curl -s -o /dev/null -w '%{http_code}' https://nagios-mcp.int.pgmac.net/sse --max-time 10
# → 200
```

---

## Preventive Measures

### Immediate Actions Required

1. **Fix the stale-failed-unit lockout in the remediation trigger path** (High)
    - Chain 2's root cause: `event_watch_cache_remediate.sh` must `systemctl reset-failed` a failed `watch-cache-remediate.service` before `systemd-run`, and the DEFERRED path should not leave the unit in `failed` state (dedicated exit code or `SuccessExitStatus`). Without this, any DEFERRED permanently disarms the watchdog on that node.
    - Issue: [pgmac-net/homelabia#137](https://github.com/pgmac-net/homelabia/issues/137)

2. **Alert when the auto-remediation cannot launch** (High)
    - Chain 2's detection gap: the watchdog logged `failed to launch remediation unit` 17 times into a journal nobody watches. A Nagios check (or watchdog-side passive result) must surface remediation launch failures and a lingering `failed` `watch-cache-remediate.service` — the automation's own failure has to be alert-worthy, since it is the only overnight control (Chain 3).
    - Issue: [pgmac-net/homelabia#138](https://github.com/pgmac-net/homelabia/issues/138)

3. **Alert on EXT4 read-only remounts and ro PVC mounts** (High)
    - Chain 4's detection gap: six volumes served `EROFS` for hours (one for 8 days) while pods reported Running. Per-node checks on `/proc/mounts` ro PVC entries and kernel `EXT4-fs error`/`Aborting journal` signatures. First identified 2026-05-28 (PGM-221), never implemented.
    - Issue: [pgmac-net/homelabia#140](https://github.com/pgmac-net/homelabia/issues/140)

### Longer-Term Improvements

4. **Reduce the openebs jiva write pressure feeding contention storms** (Medium)
    - Chain 1's trigger: the storm's write keys were dominated by events/status from four jiva replica pods that have been crash-looping for days. Fixing or silencing those crash-loops removes a standing storm generator (relates to pgk8s#577 dqlite bloat work and open jiva tickets PGM-221/222).
    - Issue: [pgmac-net/homelabia#139](https://github.com/pgmac-net/homelabia/issues/139)

5. **Runbook: document delivery failure #2** (Done)
    - The [control-plane watch-cache freeze runbook](../runbooks/control-plane-watch-cache-freeze.md) gained a "Delivery failure #2: stale `failed` unit blocks the watchdog trigger" section with triage commands and the `reset-failed` mitigation.
    - PR: [pgmac-net/incidents#57](https://github.com/pgmac-net/incidents/pull/57)

---

## Lessons Learned

### What Went Well

- The existing runbook procedure (cordon → k8s-dqlite → kubelite → RV=0 canary → pod canary → uncordon) worked first time; active recovery took ~15 minutes.
- The lease check (`kubectl get lease -n kube-system`) instantly explained why a single frozen node stopped the whole cluster — both control-plane leaders were on k8s03.
- Auto-remediation fully handled k8s01: freeze to verified recovery in ~6 minutes, unattended, with correct lease-based mutual exclusion against k8s03.
- The node-local watchdog *detected* the k8s03 freeze within 10 minutes and kept retrying every ~10 minutes for 3 hours — detection worked; only launch delivery failed.
- Nagios notification path (Slack + Zulip, with re-notifications) worked end-to-end.

### What Didn't Go Well

- A benign DEFERRED result silently disarmed the auto-remediation on k8s03 for the rest of the incident — the safety mechanism (lease mutual exclusion) and the delivery mechanism (transient unit as mutex) interacted destructively.
- 17 explicit `failed to launch remediation unit` warnings went nowhere — the automation had no way to escalate its own failure.
- The Nagios MCP being in-cluster meant the primary monitoring query path (MCP) was itself a casualty; triage had to fall back to direct kubectl/SSH (which worked, but the first tool reached for was down).

### Surprise Findings

- All three nodes froze at ~02:20; k8s02's watch stream reconnected by itself within ~8 minutes. Self-recovery is possible but evidently rare — the other two needed process restarts.
- `systemd-run` treats a *failed* leftover transient unit as a name collision, not something it can replace — using unit names as mutexes requires explicitly handling the `failed` terminal state.
- The stuck heartbeat pods were scheduled to nothing at all (no node assignment, no events) for 3 hours — yet the moment the scheduler leader's cache thawed, the entire backlog resolved within one reconciliation pass with no manual cleanup needed beyond one exceeded-backoff job.
- An app on a read-only volume can look *slow* rather than *broken*: readarr's SQLite operations took 25–46s each because they were retrying writes against `EROFS` (busytimeout churn), which for 8 days read as a storage-performance problem rather than a dead filesystem.
- `kubectl delete pod` alone is a complete fix for EXT4-ro jiva volumes in the common case — kubelet's detach/reattach replays the journal and remounts rw. All three unstick manoeuvres that were needed (cordon-first, ctrl restart, manual umount) stemmed from *stale prior state*, not from the remount itself.
- Force-deleting a pod with CSI mount-proliferation duplicates strands the un-cleared bind mount forever: kubelet's UnmountDevice loop retries every 2 minutes for a pod path it will never unpublish again (`GetDeviceMountRefs check failed`). Prefer letting slow teardowns finish over `--force`.

---

## Action Items

| # | Action | Priority | GitHub |
| --- | --- | --- | --- |
| 1 | Fix stale-failed-unit lockout: reset-failed guard in trigger script + clean DEFERRED exit status | High | [pgmac-net/homelabia#137](https://github.com/pgmac-net/homelabia/issues/137) |
| 2 | Alert on remediation launch failure and lingering failed `watch-cache-remediate.service` | High | [pgmac-net/homelabia#138](https://github.com/pgmac-net/homelabia/issues/138) |
| 3 | Alert on EXT4 read-only remounts and ro PVC mounts per node | High | [pgmac-net/homelabia#140](https://github.com/pgmac-net/homelabia/issues/140) |
| 4 | Reduce openebs jiva crash-loop write pressure feeding dqlite contention storms | Medium | [pgmac-net/homelabia#139](https://github.com/pgmac-net/homelabia/issues/139) |
| 5 | Runbook: document delivery failure #2 (stale failed unit) with triage + mitigation | Done | [pgmac-net/incidents#57](https://github.com/pgmac-net/incidents/pull/57) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03)
- **Kubernetes version:** v1.35.0
- **Datastore:** dqlite via kine (`snap.microk8s.daemon-k8s-dqlite`)
- **Auto-remediation:** `watch-cache-watchdog.timer` (5-min RV=0 self-test, 2 strikes) + Nagios `event_watch_cache_remediate` handler, both invoking `/etc/nagios/remediate_watch_cache.sh` via `systemd-run --unit=watch-cache-remediate`

### Key Error Signatures

```
# The lockout (k8s03 watchdog journal, repeated 17x at ~10-min intervals):
strike 2/2 - triggering remediation (CRITICAL - watch cache did not reflect a write after 30s ...)
WARNING: failed to launch remediation unit on k8s03

# The DEFERRED that seeded the failed unit:
DEFERRED: remediation lease held by k8s01 - another node is remediating
watch-cache-remediate.service: Main process exited, code=exited, status=1/FAILURE

# The storm that broke the kine watch streams (k8s-dqlite journal, both nodes):
error in txn: create transaction failed for key /registry/events/openebs/pvc-...: exec (try: 500): database is locked
[go-dqlite] attempt 1: server 172.22.22.6:19001: no known leader
```

### Lockout Triage and Re-Arm

```bash
# Is the watchdog locked out? (strike 2/2 followed by launch failure)
ssh <node> "sudo journalctl -u watch-cache-watchdog --since '-6 hours' --no-pager \
  | grep -E 'strike 2/2|failed to launch'"

# Confirm the stale unit
ssh <node> "systemctl is-failed watch-cache-remediate.service"   # → failed

# Re-arm (does NOT retro-trigger remediation — if the freeze is live, run the runbook manually)
ssh <node> "sudo systemctl reset-failed watch-cache-remediate.service"
```

### Dual-Leader Check

```bash
# Which node do the control-plane leaders live on? If it's the frozen node, the blast
# radius is the whole cluster, not one node.
kubectl --context pvek8s get lease -n kube-system kube-scheduler kube-controller-manager \
  -o custom-columns=NAME:.metadata.name,HOLDER:.spec.holderIdentity,RENEW:.spec.renewTime
```

---

## References

- GitHub Issue: [pgmac-net/homelabia#137](https://github.com/pgmac-net/homelabia/issues/137) — stale-failed-unit lockout fix
- GitHub Issue: [pgmac-net/homelabia#138](https://github.com/pgmac-net/homelabia/issues/138) — alert on remediation launch failure
- GitHub Issue: [pgmac-net/homelabia#139](https://github.com/pgmac-net/homelabia/issues/139) — jiva write-pressure reduction
- GitHub Issue: [pgmac-net/homelabia#140](https://github.com/pgmac-net/homelabia/issues/140) — EXT4-ro / ro-PVC-mount alerting
- PR: [pgmac-net/incidents#57](https://github.com/pgmac-net/incidents/pull/57) — runbook delivery failure #2 section
- Runbook: [Control-Plane Watch-Cache Freeze](../runbooks/control-plane-watch-cache-freeze.md)
- Runbook: [dqlite Write Contention](../runbooks/dqlite-write-contention.md)
- Related incident: [pvek8s Scheduling Outage — k8s03 Watch-Cache Freeze and Auto-Remediation Delivery Failure](2026-07-09-k8s03-watch-cache-freeze-remediation-delivery-failure.md) (2026-07-09, delivery failure #1: NRPE saturation)
- Related incident: [k8s02 Watch-Cache Freeze — dqlite Leadership Disruption Stalls Pod Creation](2026-06-24-k8s02-watch-cache-freeze-dqlite-leadership-disruption.md) (2026-06-24)
- Historical: PGM-241 (original watch-cache freeze bug), PGM-237 (write-contention storms), pgk8s#577 (dqlite snapshot bloat)

---

## Reviewers

- @pgmac
