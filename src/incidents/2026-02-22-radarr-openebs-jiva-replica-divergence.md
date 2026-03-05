# Post Incident Review: Radarr Outage Due to OpenEBS Jiva Replica Divergence

**Date:** 2026-02-22
**Duration:** ~16h30m silent failure + ~47m active recovery (22:25 AEST 2026-02-21 → 18:48 AEST 2026-02-22)
**Severity:** High (single service outage — Radarr completely unavailable)
**Status:** Resolved

---

## Executive Summary

Radarr became unavailable when its pod failed to start, remaining stuck in `ContainerCreating` for over 4.5 hours before investigation began. The pod could not start because its persistent volume (`radarr-config`) could not be mounted. The mount failure was caused by a corrupted ext4 filesystem on the iSCSI block device (`/dev/sdi`), which itself was caused by all three OpenEBS Jiva storage replicas simultaneously entering a `CrashLoopBackOff` state with diverged snapshot chains.

The Jiva replicas failed because all three had been left in a `Rebuilding: true` state following an ungraceful shutdown at approximately 22:25 AEST on 2026-02-21 — roughly 16 hours before the pod failure was detected. Without a healthy replica to serve as a rebuild source, the Jiva controller could not serve a consistent iSCSI target. This left the filesystem journal dirty, which caused `fsck -a` (run automatically by kubelet before each mount attempt) to fail repeatedly.

Two additional PVCs — `overseerr-config` and `scotchcraft-minecraft-datadir` — were found to have suffered the same underlying Jiva failure but self-recovered because at least one of their replicas remained in a healthy state. They had restart counts of 10-11 and 52-53 respectively indicating significant instability around the same event.

Resolution required: scaling down all Jiva deployments, patching `volume.meta` on one replica to clear the `Rebuilding` flag, clearing the image data on the other two replicas so they rebuilt from the good source, scaling back up in sequence, and allowing the ext4 journal recovery to complete during the next successful mount.

---

## Timeline (AEST — UTC+10)

| Time                  | Event                                                                                                                                                                                                              |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **2026-02-21 ~22:25** | **ROOT EVENT**: Ungraceful shutdown interrupts an in-progress Jiva rebuild across all 3 replicas. All nodes' `revision.counter` files share this timestamp.                                                        |
| ~22:25 onwards        | All 3 Jiva replicas for `radarr-config` enter CrashLoopBackOff. Jiva controller loses all healthy backends. iSCSI LUN (`/dev/sdi`) becomes unserviceable.                                                          |
| ~22:25 onwards        | Kubelet begins retrying PVC mount for radarr pod (not yet scheduled). Each retry runs `fsck -a /dev/sdi`, which fails with "can't read superblock".                                                                |
| **2026-02-22 14:01**  | Radarr pod `radarr-cd6596b59-lbc2v` scheduled, enters `ContainerCreating`. PVC mount failing silently — pod status gives no indication of storage failure.                                                         |
| 14:01 → 18:05         | Pod remains in `ContainerCreating` for 4h4m with no alerting. `FailedMount` events accumulate in pod describe but are not visible without active investigation.                                                    |
| **~18:05**            | **INCIDENT DETECTED**: Manual investigation triggered. `kubectl describe pod` reveals repeated `FailedMount` events citing `can't read superblock on /dev/sdi` and `fsck found errors but could not correct them`. |
| ~18:08                | All 3 Jiva replica pods identified in CrashLoopBackOff: `rep-1` (k8s03), `rep-2` (k8s02), `rep-3` (k8s01). Controller running 2/2 but with zero healthy backends.                                                  |
| ~18:10                | Replica logs reveal fatal error: `"Current replica's checkpoint not present in rwReplica chain, Shutting down..."`                                                                                                 |
| ~18:12                | All 3 nodes' `volume.meta` inspected — all show `"Rebuilding":true` with identical `RevisionCounter: 2538385` but diverged `Parent` snapshot chains. Root cause confirmed.                                         |
| ~18:15                | **RESOLUTION START**: All 4 Jiva deployments (controller + 3 replicas) scaled to 0.                                                                                                                                |
| ~18:17                | `volume.meta` on k8s01 (`rep-3`) patched: `"Rebuilding": false`. This replica designated as the authoritative source.                                                                                              |
| ~18:19                | All `.img` and `.img.meta` files moved to `.bak` directories on k8s02 and k8s03. `volume.meta` files also moved so those replicas start completely fresh.                                                          |
| ~18:21                | Jiva controller scaled back to 1. Becomes ready within 80 seconds.                                                                                                                                                 |
| ~18:22                | `rep-3` (k8s01, the fixed replica) scaled to 1. Joins controller as RW replica.                                                                                                                                    |
| ~18:24                | `rep-1` and `rep-2` scaled to 1. Begin rebuilding from `rep-3`. Jiva correctly serialises — only one WO rebuild at a time.                                                                                         |
| ~18:29                | All 4 Jiva pods `Running`. Snapshot sync active on `rep-2`, `rep-1` queued.                                                                                                                                        |
| ~18:30                | Old D-state `fsck.ext4` process (from prior kubelet retry) clears. `/dev/sdi` becomes free.                                                                                                                        |
| ~18:32                | Manual `fsck -y /dev/sdi` attempt fails — kubelet has already spawned a new `fsck -a` process, racing for the device.                                                                                              |
| ~18:37                | Radarr scaled to 0 to stop kubelet from competing for `/dev/sdi`.                                                                                                                                                  |
| ~18:40                | D-state `fsck -a` process clears. `dmesg` shows `EXT4-fs (sdi): recovery complete` — the kernel's ext4 journal recovery succeeded during a mount attempt after Jiva became healthy.                                |
| ~18:47                | Radarr scaled back to 1.                                                                                                                                                                                           |
| **18:48:28**          | **INCIDENT RESOLVED**: Radarr pod `radarr-cd6596b59-mlbs6` reaches `1/1 Running`.                                                                                                                                  |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### How did radarr become unavailable?

The radarr pod entered `ContainerCreating` and never progressed. The startup probe (TCP socket on port 7878) could not succeed because the container itself never launched.

#### How did the container fail to launch?

Kubelet was unable to mount the `radarr-config` PVC. Volume mounting is a prerequisite for container creation; without it, the pod is stuck in `ContainerCreating` indefinitely.

#### How did the PVC mount fail?

Kubelet automatically runs `fsck` before mounting a block device-backed volume. The fsck reported:

```
/dev/sdi: can't read superblock
```

and later:

```
/dev/sdi: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.
(i.e., without -a or -p options)
```

The auto-repair flag (`-a`) is insufficient for this class of journal inconsistency. Kubelet has no mechanism to escalate beyond `fsck -a`; it simply retries and logs `FailedMount`.

#### How did the ext4 filesystem on `/dev/sdi` become inconsistent?

`/dev/sdi` is the iSCSI block device provided by the OpenEBS Jiva controller for the `radarr-config` PVC. When all Jiva replica pods simultaneously entered `CrashLoopBackOff`, the controller had no healthy backends to service I/O. The iSCSI target remained presented to the host but writes timed out or returned errors. The last radarr write session left the ext4 journal in a dirty/uncommitted state — which `fsck -a` cannot repair because the journal's `needs_recovery` flag was inconsistent with the presence of journal data.

#### How did all three Jiva replica pods enter CrashLoopBackOff?

Each replica's log contained:

```
level=fatal msg="Failed to add replica to controller, err: Current replica's
checkpoint not present in rwReplica chain, Shutting down..."
```

Jiva's safety mechanism: when a replica restarts, it contacts the controller and verifies that its latest snapshot checkpoint exists in the controller's canonical chain. If not, the replica refuses to join (to prevent serving stale or diverged data) and exits. With all three replicas failing this check, the controller has zero healthy backends.

#### How did all three replicas end up with checkpoints that didn't match the controller's chain?

Inspection of each replica's `volume.meta` showed:

```json
{
  "Rebuilding": true,
  "Checkpoint": "volume-snap-0fd00bc8-...",
  "RevisionCounter": 2538385
}
```

All three replicas had identical `RevisionCounter` values (`2538385`) and identical `Checkpoint` UUIDs — but each had a **different `Parent` snapshot** for its head image:

| Node  | Head Parent               |
| ----- | ------------------------- |
| k8s01 | `volume-snap-3d6f0344...` |
| k8s02 | `volume-snap-b5c23a63...` |
| k8s03 | `volume-snap-af55ce5c...` |

All three were in `Rebuilding: true`. They had been simultaneously mid-rebuild when something caused a cluster-wide disruption. Each replica had snapshotted at the moment of trying to join (standard Jiva behaviour during rebuild) and those new snapshots were not present in any sibling's chain — causing the circular checkpoint mismatch.

#### How did all three replicas end up rebuilding at the same time?

The `revision.counter` file on all three nodes bore the same timestamp: **2026-02-21 22:25 AEST**. Jiva writes the revision counter file atomically on clean shutdown. The identical timestamp is strong evidence that all three nodes experienced a simultaneous ungraceful shutdown at that moment — a power event, network partition, or host-level failure causing all three nodes to lose connectivity or restart at the same instant.

OpenEBS Jiva only rebuilds one WO (write-only) replica at a time under normal operation. For all three to be in a rebuilding state simultaneously, the disruption must have occurred **while a multi-replica rebuild was already in progress** — meaning the system had already been in a partially degraded state before the 22:25 event.

#### How did a prior degraded state go undetected?

There is no alerting on:

- Jiva replica `CrashLoopBackOff` or elevated restart counts
- Jiva replica `Rebuilding: true` flag persisting beyond a threshold
- PVC `FailedMount` events accumulating on pods
- Pods remaining in `ContainerCreating` beyond a time threshold

The two other affected PVCs (`overseerr-config`, `scotchcraft-minecraft-datadir`) had accumulated 10-53 restarts respectively before self-recovering — also without triggering any alert.

#### How did the radarr pod sit in `ContainerCreating` for over 4 hours without detection?

The pod status `ContainerCreating` is a normal transient state during startup. Kubernetes does not surface `FailedMount` events prominently in `kubectl get pods` output — they are only visible via `kubectl describe pod`. Without a dashboard widget or alert rule explicitly targeting pods stuck in `ContainerCreating` beyond a threshold (e.g., 5 minutes), the failure was invisible.

---

### Secondary Findings

#### pvc-05e03b60 (overseerr-config) and pvc-f1888541 (scotchcraft-minecraft)

Both PVCs were hit by the same underlying Feb 21 22:25 disruption. Both showed the same "checkpoint not present in rwReplica chain" fatal error in replica logs. Unlike radarr, at least one replica for each volume had remained in a healthy (non-Rebuilding) state before the disruption, allowing them to self-recover by electing one replica as RW and rebuilding the others from it. Recovery took 50-90 minutes and produced 10-53 container restarts per replica pod — indicating significant thrashing before convergence.

---

## Impact

### Services Affected

- **Radarr** (`https://radarr.int.pgmac.net`): Completely unavailable. Pod stuck in `ContainerCreating`, no web UI, no API, no media management functionality.
- **Overseerr** (`https://overseerr.int.pgmac.net`): Elevated Jiva replica instability but service remained available throughout.
- **Scotchcraft Minecraft**: Elevated Jiva replica instability but service remained available throughout.

### Duration

- **Radarr total outage**: ~20h47m (from 22:01 AEST 2026-02-21 to 18:48 AEST 2026-02-22)
  - Silent failure period (undetected): ~16h04m (22:25 → ~14:01 — pod was not scheduled)
  - Pod stuck in ContainerCreating (undetected): ~4h04m (14:01 → ~18:05)
  - Active recovery: ~43m (~18:05 → 18:48)
- **Overseerr instability**: ~6-8h duration, self-resolved, no user-visible outage confirmed
- **Minecraft instability**: ~6-8h duration, self-resolved, no user-visible outage confirmed

### Scope

- **Storage**: OpenEBS Jiva storage subsystem for 3 PVCs across 3 namespaces
- **User-facing**: Media management (no new media could be tracked or imported via Radarr)
- **Monitoring**: No detection for ~16h of silent failure

---

## Resolution Steps Taken

### 1. Create ArgoCD SyncWindow

Create a `dney` SyncWindow in ArgoCD on all applications to ensure ArgoCD does NOT attempt to auto-sync any changes during the restoration

### 2. Scale Down All Jiva Deployments

```bash
kubectl scale deployment -n openebs \
  pvc-a634b9a3-fdaa-4b45-9dc3-2486e716d755-ctrl \
  pvc-a634b9a3-fdaa-4b45-9dc3-2486e716d755-rep-1 \
  pvc-a634b9a3-fdaa-4b45-9dc3-2486e716d755-rep-2 \
  pvc-a634b9a3-fdaa-4b45-9dc3-2486e716d755-rep-3 \
  --replicas=0
```

### 3. Patch volume.meta on k8s01 (rep-3) — the Authoritative Source

```bash
# Backup first
sudo cp volume.meta volume.meta.bak

# Patch Rebuilding flag to false
sudo python3 -c "
import json
path = '/var/snap/microk8s/common/var/openebs/pvc-a634b9a3-.../volume.meta'
with open(path) as f:
    data = json.load(f)
data['Rebuilding'] = False
with open(path, 'w') as f:
    json.dump(data, f, separators=(',', ':'))
"
```

### 4. Clear Image Data on k8s02 and k8s03

```bash
# On k8s02 and k8s03 — move (not delete) all img files and volume.meta to backup
sudo mkdir -p /var/snap/microk8s/common/var/openebs/pvc-a634b9a3-....bak
sudo mv /var/snap/microk8s/common/var/openebs/pvc-a634b9a3-.../*.img \
        /var/snap/microk8s/common/var/openebs/pvc-a634b9a3-....bak/
sudo mv /var/snap/microk8s/common/var/openebs/pvc-a634b9a3-.../*.img.meta \
        /var/snap/microk8s/common/var/openebs/pvc-a634b9a3-....bak/
sudo mv /var/snap/microk8s/common/var/openebs/pvc-a634b9a3-.../volume.meta \
        /var/snap/microk8s/common/var/openebs/pvc-a634b9a3-....bak/
```

### 5. Scale Up in Sequence

```bash
# Controller first
kubectl scale deployment -n openebs pvc-a634b9a3-...-ctrl --replicas=1

# Wait for controller ready
kubectl wait --for=condition=ready pod -n openebs \
  -l openebs.io/persistent-volume=pvc-a634b9a3-...,openebs.io/controller=jiva-controller \
  --timeout=60s

# Good replica (k8s01, rep-3) next
kubectl scale deployment -n openebs pvc-a634b9a3-...-rep-3 --replicas=1

# Allow rep-3 to establish as RW, then bring up the others
kubectl scale deployment -n openebs \
  pvc-a634b9a3-...-rep-1 \
  pvc-a634b9a3-...-rep-2 \
  --replicas=1
```

### 6. Stop Radarr to Clear the Mount Race

```bash
# Radarr was generating competing fsck -a processes preventing manual fsck
kubectl scale deployment -n media radarr --replicas=0
```

At this point the kernel's ext4 journal recovery completed automatically during a mount attempt (`dmesg` showed `EXT4-fs (sdi): recovery complete` and `mounted filesystem with ordered data mode`), eliminating the need for a manual `fsck -y`.

### 7. Restore Radarr

```bash
kubectl scale deployment -n media radarr --replicas=1
```

### 8. Cleanup

```bash
# Remove backup directories from all nodes
ssh k8s01 "sudo rm -f .../volume.meta.bak"
ssh k8s02 "sudo rm -rf ...pvc-a634b9a3-....bak"
ssh k8s03 "sudo rm -rf ...pvc-a634b9a3-....bak"
```

### 9. Remove SyncWindow

Remove the `deny` SyncWindow in ArgoCD to ensure normal/expected auto-sync operation continues

---

## Verification

### Service Health

- ✅ Radarr: `1/1 Running`, stable for 8+ check intervals post-recovery
- ✅ Overseerr: `1/1 Running`, no further replica restarts
- ✅ Minecraft: `1/1 Running`, no further replica restarts

### Storage Health

```
pvc-a634b9a3 (radarr-config):
  ctrl:  2/2 Running
  rep-1: 1/1 Running  (rebuilt from rep-3)
  rep-2: 1/1 Running  (rebuilt from rep-3)
  rep-3: 1/1 Running  (authoritative source)

pvc-05e03b60 (overseerr-config):
  All replicas: 1/1 Running, Rebuilding=false, shared Checkpoint ✅

pvc-f1888541 (minecraft-datadir):
  All replicas: 1/1 Running, Rebuilding=false, shared Checkpoint ✅
```

### Volume Metadata (Post-Recovery)

All radarr-config replicas confirmed with:

- `"Rebuilding": false`
- Shared `Checkpoint` UUID across all 3 nodes
- Shared `Parent` snapshot reference
- Active sync converging `RevisionCounter` values

---

## Preventive Measures

### Immediate Actions Required

1. **Alert on pods stuck in ContainerCreating > 5 minutes** (Critical Priority)
   - Current: No alerting; a pod can sit stuck indefinitely without detection
   - Target: PagerDuty/Slack alert when any pod remains in `ContainerCreating` beyond 5 minutes
   - Implementation: Prometheus `kube_pod_status_phase` + duration alert rule
   - **Rationale**: 4+ hours elapsed before manual detection. This single alert would have reduced radarr's outage from hours to minutes.

2. **Alert on Jiva replica CrashLoopBackOff** (Critical Priority)
   - Current: No alerting on OpenEBS replica pod failures
   - Target: Immediate alert when any Jiva replica pod enters `CrashLoopBackOff` or `Error`
   - Implementation: Prometheus `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}` filtered to `openebs` namespace
   - **Rationale**: All 3 replicas were in CrashLoopBackOff for ~16 hours before detection

3. **Alert on Jiva replica restart count threshold** (High Priority)
   - Current: No alerting; overseerr and minecraft accumulated 10-53 restarts silently
   - Target: Alert when any Jiva replica pod exceeds 5 restarts within 30 minutes
   - Implementation: `rate(kube_pod_container_status_restarts_total[30m]) > 0.1` filtered to openebs namespace
   - **Rationale**: The self-recovered PVCs showed the same failure pattern but slightly less severe — an early restart alert would flag the pattern before it becomes critical

4. **Alert on FailedMount events** (High Priority)
   - Current: `FailedMount` events are only visible via `kubectl describe`; no alerting
   - Target: Alert when a pod generates more than 3 `FailedMount` events
   - Implementation: Prometheus `kube_event_count{reason="FailedMount"}` alert rule
   - **Rationale**: The mount failure was generating repeated events for hours with no visibility

5. **Document OpenEBS Jiva replica divergence recovery runbook** (High Priority)
   - Current: No documented procedure; recovery required real-time diagnosis
   - Target: Step-by-step runbook covering: identify diverged replicas → patch volume.meta → clear image data on non-source replicas → scale up in sequence
   - Location: `incidents/docs/runbooks/openebs-jiva-replica-recovery.md`
   - **Rationale**: Recovery took ~43 minutes of active work; a runbook would reduce this significantly and remove the knowledge dependency

6. **Investigate and document the Feb 21 22:25 root event** (High Priority)
   - Current: The simultaneous all-node disruption at 22:25 AEST is unexplained
   - Target: Identify whether this was a power event, network partition, kernel bug, or other cause
   - Actions:
     - Review UPS/PDU logs for that timeframe
     - Review node-level system logs (`/var/log/syslog`) from all 3 nodes around 22:25
     - Check Proxmox/hypervisor logs if nodes are VMs
   - **Rationale**: The same unknown event also degraded overseerr and minecraft. If it recurs, all Jiva volumes are at risk of the same failure mode

### Longer-Term Improvements

7. **Jiva Rebuilding flag monitoring** (Medium Priority)
   - Add a periodic check (every 5 minutes) that inspects `volume.meta` on all Jiva replica nodes and alerts if `Rebuilding: true` persists beyond 30 minutes
   - A replica stuck in Rebuilding for >30 minutes indicates a stalled or failed rebuild that requires intervention
   - Implementation: CronJob running a script against node hostPaths, or custom Prometheus exporter

8. **Jiva rebuild serialisation guard** (Medium Priority)
   - When a cluster-wide disruption leaves all replicas in Rebuilding state simultaneously, Jiva has no self-healing path because no replica can establish as RW
   - Investigate whether OpenEBS Jiva has a recovery mode or operator-level intervention hook that can be automated
   - Consider upgrading OpenEBS if newer versions have improved recovery handling for this scenario

9. **Structured review of all Jiva volumes' health state** (Medium Priority)
   - Run a periodic job that checks `volume.meta` on all Jiva replica hostPaths across all nodes
   - Report: revision counter skew between replicas, Rebuilding flag, Dirty flag, snapshot chain depth
   - This would surface partial degradation (e.g., one of three replicas in an unhealthy state) before it becomes a full outage

10. **Snapshot chain depth monitoring** (Medium Priority)
    - Referenced from the 2026-01-06 PIR: excessive snapshot accumulation caused Phase 2 storage issues in that incident
    - The radarr-config PVC had 280+ snapshot files on k8s01 at recovery time, indicating the jiva-snapshot-cleanup cronjob may not be running effectively
    - Verify snapshot cleanup cronjob is healthy and its threshold/frequency is appropriate (see 2026-01-06 action items)

---

## Lessons Learned

### What Went Well

1. **Thorough diagnostic approach**: The full causal chain from "pod not starting" to "all replicas Rebuilding simultaneously" was traced in approximately 10 minutes using `kubectl describe`, pod logs, node SSH access, and `volume.meta` inspection
2. **Careful recovery sequencing**: Scaling down before making filesystem changes, choosing the source replica deliberately, moving (not deleting) backup data before confirming recovery — all prevented data loss
3. **Self-healing worked for two of three affected PVCs**: The overseerr and minecraft volumes recovered without intervention, demonstrating that Jiva's rebuild mechanism works correctly when at least one healthy replica survives
4. **Backup before touching metadata**: `volume.meta.bak` was created before patching, and image files were moved rather than deleted, preserving rollback options throughout
5. **The kernel handled ext4 recovery**: Once the Jiva backend was healthy, the kernel's built-in ext4 journal recovery resolved the filesystem corruption without requiring a separate manual `fsck` — simplifying the recovery

### What Didn't Go Well

1. **16+ hours of silent failure**: The root event occurred at 22:25 AEST; the incident was not detected until ~18:05 the next day — a detection gap of over 16 hours
2. **ContainerCreating is invisible as an error state**: The pod appeared "normal" to casual inspection; only `kubectl describe` revealed the FailedMount events
3. **No Jiva health alerting whatsoever**: Three separate PVCs experienced Jiva replica failures affecting 3 different services, all without any alert being generated
4. **fsck -a race condition**: Kubelet continuously spawning new `fsck -a` processes prevented manual `fsck -y` from acquiring the device, requiring the workaround of scaling radarr to 0
5. **The underlying 22:25 disruption remains unexplained**: The simultaneous all-replica crash is the true root cause, and without knowing what caused it, the risk of recurrence cannot be assessed or mitigated
6. **Jiva has no self-healing path when all replicas diverge**: The system had no ability to recover without manual metadata surgery — this is a fundamental architectural limitation

### Surprise Findings

1. **All 3 replicas can simultaneously enter an unrecoverable state**: The assumption that 3-replica Jiva provides resilience only holds if the disruption affects fewer than a quorum. A simultaneous all-node disruption during an active rebuild defeats this assumption entirely.
2. **The Rebuilding flag persists across pod restarts**: `volume.meta` is on the node's hostPath, not in the pod. Each time a replica pod restarted, it read `Rebuilding: true` and immediately failed. The CrashLoopBackOff was not a transient issue — it would never self-resolve.
3. **The revision.counter timestamp as a forensic tool**: The identical `Feb 21 22:25` mtime on all three nodes' `revision.counter` files provided precise timing of the root event without any application-level logging.
4. **ext4 journal recovery as a "free" fix**: The kernel handled the filesystem repair during the successful mount after Jiva was fixed, avoiding the need for manual `fsck -y`. The `can't read superblock` error from the earlier kubelet attempts was due to the total absence of Jiva backends, not permanent disk corruption.
5. **Two other services were also impacted but self-recovered**: Without checking all Jiva pod restart counts, the full blast radius of the Feb 21 event would have been unknown. The same root event caused instability across minecraft and overseerr.

---

## Action Items

| Priority | Action                                                                       | Owner | Due Date   | Status |
| -------- | ---------------------------------------------------------------------------- | ----- | ---------- | ------ |
| Critical | Alert: pod stuck in ContainerCreating > 5 minutes                            | SRE   | 2026-03-01 | Open   |
| Critical | Alert: Jiva replica pod CrashLoopBackOff in openebs namespace                | SRE   | 2026-03-01 | Open   |
| High     | Alert: Jiva replica restart rate > 5 in 30 minutes                           | SRE   | 2026-03-08 | Open   |
| High     | Alert: FailedMount events > 3 on any pod                                     | SRE   | 2026-03-08 | Open   |
| High     | Write OpenEBS Jiva replica recovery runbook                                  | SRE   | 2026-03-08 | Open   |
| High     | Investigate Feb 21 22:25 root event (UPS, PDU, hypervisor logs)              | SRE   | 2026-03-01 | Open   |
| Medium   | Implement Jiva Rebuilding flag monitor (cronjob/exporter)                    | SRE   | 2026-03-15 | Open   |
| Medium   | Investigate Jiva upgrade path or automated rebuild recovery                  | SRE   | 2026-03-22 | Open   |
| Medium   | Periodic Jiva volume health report (revision skew, chain depth)              | SRE   | 2026-03-22 | Open   |
| Medium   | Verify jiva-snapshot-cleanup cronjob health and thresholds                   | SRE   | 2026-03-01 | Open   |
| Low      | Investigate ci namespace high-restart pods (dependency-track: 176 restarts)  | SRE   | 2026-03-15 | Open   |
| Low      | Investigate media namespace chronic restarters (metasearch: 34, linkace: 11) | SRE   | 2026-03-22 | Open   |

---

## Technical Details

### Environment

- **Cluster**: pvek8s (microk8s on 3 nodes: k8s01/172.22.22.6, k8s02, k8s03/172.22.22.9)
- **Storage**: OpenEBS Jiva 2.12.1 (`openebs-jiva-default` storage class)
- **Affected PVC**: `radarr-config` (pvc-a634b9a3-fdaa-4b45-9dc3-2486e716d755), 5Gi RWO
- **iSCSI target**: `iqn.2016-09.com.openebs.jiva:pvc-a634b9a3-fdaa-4b45-9dc3-2486e716d755` at `10.152.183.80:3260`
- **Block device on k8s01**: `/dev/sdi` (ext4 filesystem, 2G)
- **Replica hostPath**: `/var/snap/microk8s/common/var/openebs/pvc-a634b9a3-fdaa-4b45-9dc3-2486e716d755/`

### Replica State at Discovery

| Node  | Replica | Revision Counter | Head Image          | Rebuilding | Status           |
| ----- | ------- | ---------------- | ------------------- | ---------- | ---------------- |
| k8s01 | rep-3   | 2538385          | volume-head-280.img | true       | CrashLoopBackOff |
| k8s02 | rep-2   | 2538385          | volume-head-376.img | true       | CrashLoopBackOff |
| k8s03 | rep-1   | 2538385          | volume-head-378.img | true       | CrashLoopBackOff |

All three had identical `Checkpoint: "volume-snap-0fd00bc8-aaa8-40d1-90c3-1971d4837540.img"` but different `Parent` snapshot references, confirming divergence during an interrupted multi-replica rebuild.

### Key Log Entries

**Jiva replica fatal error (all 3 replicas):**

```
level=fatal msg="Failed to add replica to controller, err: Current replica's
checkpoint not present in rwReplica chain, Shutting down..."
```

**Kubelet mount failure (pod events):**

```
Warning  FailedMount  kubelet  MountVolume.MountDevice failed for volume
"pvc-a634b9a3-..." : 'fsck' found errors on device /dev/disk/by-path/...
but could not correct them:
/dev/sdi: recovering journal
/dev/sdi: Superblock needs_recovery flag is clear, but journal has data.
/dev/sdi: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.
```

**ext4 recovery success (dmesg on k8s01):**

```
[...] EXT4-fs (sdi): recovery complete
[...] EXT4-fs (sdi): mounted filesystem with ordered data mode. Opts: (null)
[...] sd 10:0:0:0: [sdi] Synchronizing SCSI cache
```

### Other Affected PVCs (Same Root Event)

| PVC                              | App                   | Max Restarts | Self-Recovered | Outage         |
| -------------------------------- | --------------------- | ------------ | -------------- | -------------- |
| pvc-05e03b60 (overseerr-config)  | Overseerr             | 11           | Yes            | None confirmed |
| pvc-f1888541 (minecraft-datadir) | Scotchcraft Minecraft | 53           | Yes            | None confirmed |

---

## References

- Previous incident covering Jiva snapshot accumulation: `incidents/docs/incidents/2026-01-06-cluster-cascade-failure.md`
- OpenEBS Jiva documentation: https://openebs.io/docs/user-guides/jiva
- OpenEBS Jiva volume.meta schema: internal replica metadata, not publicly documented

---

## Reviewers

- **Prepared by**: Claude (AI Assistant)
- **Date**: 2026-02-22
- **Review Status**: Draft — Pending human review
