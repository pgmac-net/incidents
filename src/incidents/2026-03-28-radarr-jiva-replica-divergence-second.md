# Post Incident Review: Radarr Outage — OpenEBS Jiva Replica Divergence (Second Occurrence)

**Date:** 2026-03-28
**Duration:** ~30h silent failure + ~50m active recovery
**Severity:** High (single service outage — Radarr completely unavailable)
**Status:** Resolved
**Linear:** [PGM-115](https://linear.app/pgmac-net-au/issue/PGM-115/pir-radarr-outage-openebs-jiva-replica-divergence-second-occurrence)
**Second occurrence** on the same PVC — see also [2026-02-22 PIR](2026-02-22-radarr-openebs-jiva-replica-divergence.md)

---

## Executive Summary

Radarr became unavailable when its pod was stuck in `ContainerCreating`. The pod could not start because its persistent volume (`radarr-config`) could not be mounted — the iSCSI portal at `10.152.183.80:3260` was refusing connections. All three OpenEBS Jiva replica pods for the volume had been in `CrashLoopBackOff` for approximately 30 hours prior to detection, each failing with a diverged snapshot chain error.

This is the second occurrence of the same fundamental failure mode on this exact PVC (`pvc-a634b9a3-fdaa-4b45-9dc3-2486e716d755`) — the first occurred on 2026-02-22. The critical alerting action items from the February PIR (alert on `ContainerCreating > 5 minutes`, alert on Jiva replica `CrashLoopBackOff`) had not yet been implemented, which is why this second occurrence also went undetected for ~30 hours.

This incident was more complex to resolve than the February one. The February divergence left a usable authoritative replica whose `volume.meta` `Rebuilding` flag could be patched. This time all three replicas had irreconcilable diverged chains with no single authoritative source, requiring all three data directories to be wiped — resulting in **total data loss** of the radarr config volume. Additional complications arose from a ghost RW replica entry in the controller API (blocking volume promotion to RW) and a stale iSCSI session on k8s03 (blocking the new iSCSI attachment on k8s01).

---

## Timeline (AEST — UTC+10)

| Time | Event |
|------|-------|
| **~2026-03-27 03:00 (approx)** | **ROOT EVENT** (estimated): Unknown disruption causes all 3 Jiva replicas to diverge. Replica pods begin CrashLoopBackOff. |
| ~03:00 onwards | All 3 replicas cycling in CrashLoopBackOff — `rep-1` (k8s03), `rep-2` (k8s02), `rep-3` (k8s01). iSCSI target becomes unserviceable. |
| **~2026-03-28 07:00 (approx)** | Radarr pod rescheduled or restarted, enters `ContainerCreating`. iSCSI mount failing. |
| **~09:10** | **INCIDENT DETECTED**: Investigation triggered. `kubectl describe pod` reveals `FailedMount` events — `iscsiadm: Connection to Discovery Address 10.152.183.80 failed`. |
| ~09:12 | All 3 Jiva replica pods confirmed in CrashLoopBackOff (~30h age). Controller `2/2 Running`. |
| ~09:14 | Replica logs reveal `"Current replica's checkpoint not present in rwReplica chain, Shutting down..."` Head images: rep-1=`head-176`, rep-2=`head-173`, rep-3=`head-465`. All diverged. |
| ~09:15 | **RESOLUTION START**: Decision made to wipe rep-1 (k8s03) and rep-2 (k8s02) data dirs; keep rep-3 (k8s01, head-465, most advanced) as source. |
| ~09:16 | rep-1 and rep-2 deployments scaled to 0. |
| ~09:17 | Cleanup pods deployed on k8s03 and k8s02 to wipe `/var/snap/microk8s/common/var/openebs/pvc-a634b9a3-.../`. Both complete successfully. |
| ~09:18 | rep-1 and rep-2 scaled back to 1. rep-2 comes up `1/1 Running`. rep-3 still failing — "checkpoint not present in rwReplica chain". |
| ~09:19 | rep-3 (k8s01) also wiped — data dir cleared, scaled back to 1. rep-3 fails "can only have one WO replica at a time" — rep-2 is WO rebuilding. |
| ~09:23 | Controller API queried. Ghost RW replica at `10.1.236.71:9502` (dead pod IP) found. Deleted via `DELETE /v1/replicas/<id>`. Volume still RO (replicaCount: 0). |
| ~09:25 | Controller pod deleted/restarted to force re-evaluation. |
| ~09:27 | rep-2 unable to reach controller (`i/o timeout`) during controller restart window. |
| ~09:28 | Controller restarts, endpoints update. rep-1 and rep-2 reconnect. rep-2 promotes to RW; rep-1 becomes WO → promotes to RW. Volume back to `readOnly: false`, `RW replicas: 2`. |
| ~09:30 | rep-3 joins as WO, begins rebuilding from rep-2. |
| ~09:33 | Controller log: "rejecting connection: 10.1.73.64 target already connected at 172.22.22.9" — stale iSCSI session on k8s03 blocking k8s01 mount. |
| ~09:35 | `nsenter` privileged pod deployed on k8s03. Confirms iSCSI session `[sid: 39]` to `iqn.2016-09.com.openebs.jiva:pvc-a634b9a3-...`. Session logged out. |
| ~09:38 | Radarr pod `radarr-59b85cfdbd-62bdl` reaches `1/1 Running`. iSCSI volume mounted successfully. |
| **09:38** | **INCIDENT RESOLVED** |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### How did Radarr become unavailable?

The radarr pod was stuck in `ContainerCreating`. The container never launched because the pod's prerequisite volume mount could not complete.

#### How did the volume mount fail?

The kubelet mount attempt used iSCSI to connect to `10.152.183.80:3260` (the Jiva controller's ClusterIP). The iSCSI initiator (`iscsiadm`) could not establish a session:

```
iscsiadm: Connection to Discovery Address 10.152.183.80 failed
iscsiadm: Login I/O error, failed to receive a PDU
iscsiadm: connection login retries (reopen_max) 5 exceeded
```

#### How was the iSCSI target unavailable?

The Jiva controller pod was running (`2/2 Ready`) and listening on port 3260, but it had **zero healthy replica backends**. The Jiva controller requires at least one healthy RW replica to service the iSCSI target. With no RW replicas, the iSCSI target rejects connections.

#### How did all three Jiva replica pods enter CrashLoopBackOff?

Every replica exited with:

```
level=fatal msg="Failed to add replica to controller, err: Current replica's
checkpoint not present in rwReplica chain, Shutting down..."
```

Jiva's safety check: when a replica restarts and attempts to re-join the controller, it verifies that its latest local snapshot checkpoint exists in the controller's canonical chain. If the checkpoint is absent (i.e., the replica's local chain diverged from the authoritative chain), the replica refuses to serve data and exits to prevent serving stale or inconsistent writes.

With all three replicas failing this check against each other, no replica could become RW, and the deadlock was permanent without intervention.

#### How did all three replicas end up with incompatible diverged chains?

At time of discovery, the replica head images were:

| Replica | Node  | Local Head  | Last Seen RW Chain Head |
|---------|-------|-------------|------------------------|
| rep-1   | k8s03 | head-176    | head-897               |
| rep-2   | k8s02 | head-173    | head-899               |
| rep-3   | k8s01 | head-465    | head-898               |

Each replica's local chain diverged at a different snapshot from the others. The controller had seen a different "RW chain" for each replica because each successive restart caused the controller to snapshot and try a new rebuild source — each time failing and creating a new divergence point.

The divergence was multi-way: rep-1, rep-2, and rep-3 each had local checkpoint snapshots that didn't appear in any sibling's chain. No single replica could act as an authoritative source for the others.

#### How did the chains diverge in the first place?

The replica pods were ~30 hours old at detection time, all in CrashLoopBackOff since creation. This means the divergence event occurred approximately 30 hours before detection — around 2026-03-27 03:00 AEST.

The pattern is identical to the 2026-02-22 incident on the same PVC: an unknown disruption interrupted an in-progress Jiva rebuild, leaving all replicas mid-rebuild with inconsistent states. Each replica snapshotted at the moment it tried to re-join (standard Jiva behaviour during WO→RW promotion), and those new snapshots were not reconciled across nodes before the next disruption.

This is the **second time in 34 days** that `radarr-config` has suffered this exact failure. This strongly suggests either:
1. A persistent instability in the Jiva rebuild process for this PVC specifically, or
2. Recurring cluster disruptions (possibly the same unknown root event from February) that are not being investigated or resolved.

#### Why was this not detected for ~30 hours?

No alerts fire on:
- Jiva replica pods in `CrashLoopBackOff` in the `openebs` namespace
- Pods stuck in `ContainerCreating` beyond a threshold
- `FailedMount` events accumulating on pods
- iSCSI target connectivity failures

These same four alerts were listed as **Critical and High priority action items** in the 2026-02-22 PIR. None were implemented before this second occurrence.

---

### Additional Complications

#### Ghost RW Replica in Controller

After wiping all three data directories and scaling replicas back up, the controller API showed:

```
tcp://10.1.236.71:9502  RW
tcp://10.1.236.245:9502 WO
```

The IP `10.1.236.71` belonged to a previous pod instance (no current pod had that IP). The controller was caching a stale RW entry from before the restart cycle. The new rep-2 (at `10.1.236.245`) was in WO state, waiting to sync from a dead source — causing the rebuild to stall indefinitely.

Resolution: the ghost replica was removed via the Jiva controller REST API:

```bash
curl -X DELETE http://localhost:9501/v1/replicas/dGNwOi8vMTAuMS4yMzYuNzE6OTUwMg==
```

After removal, the volume entered `readOnly: true` with `replicaCount: 0`. The controller was restarted to force fresh replica registration. This was a destructive step but necessary to unblock the rebuild.

#### Stale iSCSI Session on k8s03

After the Jiva volume recovered (all replicas RW, volume RW), the radarr pod on k8s01 was still stuck in `ContainerCreating`. The controller log showed:

```
rejecting connection: 10.1.73.64 target already connected at 172.22.22.9
```

k8s03 (`172.22.22.9`) had a live iSCSI session to the volume's target — a remnant from when radarr had previously run on k8s03. Jiva's iSCSI target only allows one initiator connection at a time. k8s01 (`172.22.22.6`) could not connect until k8s03's session was cleared.

The session was identified and logged out via a privileged `nsenter` pod on k8s03:

```
Logout of [sid: 39, target: iqn.2016-09.com.openebs.jiva:pvc-a634b9a3-..., portal: 10.152.183.80,3260] successful.
```

This class of issue occurs when a pod moves between nodes and the source node's iSCSI initiator daemon (`iscsid`) does not clean up its session — typically because the volume was detached ungracefully (node restart, pod forced deletion) rather than through a normal unmount path.

---

## Impact

### Services Affected

- **Radarr** (`https://radarr.int.pgmac.net`): Completely unavailable. Pod stuck in `ContainerCreating`, no web UI, no API, no media management.
- **Radarr config data**: **Total data loss**. All three data directories were wiped as part of recovery. Radarr will require full reconfiguration.

### Duration

- **Silent failure period**: ~30h (replica divergence at ~03:00 2026-03-27 → detection at ~09:10 2026-03-28)
- **Active recovery**: ~28 minutes (09:10 → 09:38 AEST)
- **Total outage**: ~30h28m

### Scope

- **Storage**: OpenEBS Jiva storage subsystem for `radarr-config` PVC
- **Data**: Full Radarr configuration lost (library, custom formats, indexers, download client config, history)
- **Monitoring**: No detection for ~30h

---

## Resolution Steps

### 1. Identify Diverged Replicas

```bash
kubectl -n openebs get pods -l openebs.io/persistent-volume=pvc-a634b9a3-fdaa-4b45-9dc3-2486e716d755
kubectl -n openebs logs <rep-pod> | grep "volume-head\|fatal"
```

### 2. Select Authoritative Replica (Best Effort)

The replica with the highest local head number has performed the most writes and is the most likely to hold the most recent data. In this incident, rep-3 on k8s01 had `head-465` vs `head-176` and `head-173`.

### 3. Scale Down and Wipe Non-Authoritative Replicas

```bash
# Scale to 0
kubectl -n openebs scale deployment pvc-a634b9a3-...-rep-1 --replicas=0
kubectl -n openebs scale deployment pvc-a634b9a3-...-rep-2 --replicas=0

# Wipe data via privileged pod on each node
kubectl run cleanup-k8s03 --image=alpine --restart=Never --overrides='{
  "spec": {
    "nodeName": "k8s03",
    "containers": [{
      "name": "cleanup", "image": "alpine",
      "command": ["sh", "-c", "rm -rf /data/* && echo done"],
      "volumeMounts": [{"mountPath": "/data", "name": "d"}],
      "securityContext": {"privileged": true}
    }],
    "volumes": [{"name": "d", "hostPath": {"path": "/var/snap/microk8s/common/var/openebs/pvc-a634b9a3-..."}}]
  }
}'
```

### 4. Scale Non-Authoritative Replicas Back Up

```bash
kubectl -n openebs scale deployment pvc-a634b9a3-...-rep-1 --replicas=1
kubectl -n openebs scale deployment pvc-a634b9a3-...-rep-2 --replicas=1
```

### 5. If Authoritative Replica Also Diverged — Wipe It Too

In this incident, rep-3 also failed. The same wipe process was applied. The volume was rebuilt from scratch (empty).

### 6. Check for and Remove Ghost Replicas

```bash
# Exec into the controller container
kubectl -n openebs exec <ctrl-pod> -c <ctrl-container> -- \
  curl -s http://localhost:9501/v1/replicas | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(r['id'], r['address'], r['mode']) for r in d['data']]"

# Delete any replica whose IP does not match a current running pod
kubectl -n openebs exec <ctrl-pod> -c <ctrl-container> -- \
  curl -X DELETE http://localhost:9501/v1/replicas/<base64-id>
```

### 7. Restart Controller If Volume Remains RO

```bash
kubectl -n openebs delete pod <ctrl-pod>
```

Wait for controller to restart and endpoints to update before replicas retry.

### 8. Clear Stale iSCSI Sessions on Other Nodes

If the target pod is scheduled on node A but another node B has a live iSCSI session to the volume:

```bash
# Check which node has the stale session via controller log:
# "rejecting connection: <IP> target already connected at <NODE-IP>"

# Deploy nsenter pod on the blocking node to log out the stale session
kubectl run iscsi-cleanup --image=alpine --restart=Never --overrides='{
  "spec": {
    "nodeName": "k8s03",
    "hostNetwork": true,
    "hostPID": true,
    "containers": [{
      "name": "iscsi-cleanup", "image": "alpine",
      "command": ["nsenter", "--mount=/proc/1/ns/mnt", "--", "sh", "-c",
        "iscsiadm -m session && iscsiadm -m node -T iqn.2016-09.com.openebs.jiva:<pvc-id> -u"],
      "securityContext": {"privileged": true}
    }]
  }
}'
```

---

## Verification

```
radarr pod:           1/1 Running (k8s01)
ctrl:                 2/2 Running
rep-1 (k8s03):        1/1 Running
rep-2 (k8s02):        1/1 Running
rep-3 (k8s01):        1/1 Running

Volume state:         readOnly: false
RW replicas:          2 (rebuilding to 3)
iSCSI session:        Active on k8s01 only
```

---

## Preventive Measures

### Immediate — Overdue (Carry-over from 2026-02-22 PIR)

1. **Alert: pod stuck in ContainerCreating > 5 minutes** (Critical — 34 days overdue)
   - Both this incident and the February incident would have been detected within minutes, not hours, if this alert existed
   - Implementation: `kube_pod_status_phase{phase="Pending"}` duration alert

2. **Alert: Jiva replica CrashLoopBackOff in openebs namespace** (Critical — 34 days overdue)
   - The replicas were in CrashLoopBackOff for ~30h. This alert would have fired within minutes of the root event
   - Implementation: `kube_pod_container_status_waiting_reason{namespace="openebs",reason="CrashLoopBackOff"} > 0`

### New — Specific to This Incident

3. **Investigate the recurring divergence root cause** (Critical)
   - This is the **second** Jiva replica divergence on `radarr-config` in 34 days. The PVC was rebuilt fresh on 2026-02-22; it diverged again by 2026-03-27
   - The root event (a cluster disruption interrupting a Jiva rebuild) has happened at least twice to this PVC. The underlying cause must be identified
   - Actions: review node system logs, UPS/PDU logs, hypervisor/Proxmox events around 2026-03-27 03:00 AEST; correlate with Feb 21 22:25 event from previous PIR

4. **Document and automate ghost replica detection** (High)
   - The Jiva controller can retain stale replica entries after pod restarts. This is not self-healing and blocks volume recovery
   - A periodic check (or post-restart hook) should detect replicas whose IP addresses don't match any running pod
   - Implementation: CronJob querying `GET /v1/replicas` and cross-referencing against pod IPs in the openebs namespace

5. **Document and automate stale iSCSI session detection** (High)
   - When a pod moves nodes, the previous node's iSCSI initiator may retain a live session, blocking the new node from mounting
   - This should be detectable via the controller log message "target already connected at X" and automated logout
   - Implementation: alert on `FailedMount` events + runbook step to check controller logs for "already connected"

6. **Evaluate migration away from OpenEBS Jiva** (High)
   - Two full outages in 34 days on the same PVC, both requiring manual data-dir surgery
   - Jiva's self-healing is limited: it cannot recover when all replicas diverge, and it retains ghost state (stale replica entries, held iSCSI sessions) that requires manual cleanup
   - Evaluate: OpenEBS Mayastor (NVMe-oF, active-active), Longhorn (better self-healing, snapshot cleanup, UI), or Rook/Ceph
   - **Rationale**: The operational cost of Jiva failures (data loss, manual recovery, multiple sessions per incident) is not acceptable for a media server configuration store

7. **Reconfigure Radarr with backup/restore automation** (Medium)
   - Radarr config (library, custom formats, indexers) was lost for the second time
   - Implement: daily Radarr XML backup to a separate PVC or external storage, and a restore playbook
   - The Radarr backup endpoint: `POST /api/v3/command` `{"name":"Backup"}`

---

## Lessons Learned

### What Went Well

1. **Systematic diagnosis**: The full chain from "pod stuck" → "iSCSI failure" → "all replicas diverged" was traced in under 5 minutes using `kubectl describe` and replica pod logs
2. **Ghost replica discovery**: Querying the Jiva controller REST API directly revealed the stale `10.1.236.71` entry that was blocking volume recovery — a non-obvious step that would have been missed without API access
3. **nsenter approach for iSCSI session cleanup**: Avoided the need to SSH into nodes by using a privileged pod with `nsenter --mount=/proc/1/ns/mnt` to access the host's `iscsiadm`
4. **Accepted data loss early**: Recognising that all three replicas were irreconcilably diverged and that radarr config is reconstructable avoided wasted time trying to salvage one replica's data

### What Didn't Go Well

1. **~30 hours of silent failure**: Both the storage failure and the radarr outage were completely invisible without active investigation. The same alerts that were listed as Critical in the February PIR still don't exist
2. **Second occurrence of the same failure on the same PVC**: The February PIR clearly identified this failure mode and the PVC at risk. The fact that it happened again 34 days later, to the same volume, means the preventive actions were treated as optional
3. **Total data loss**: In the February incident, one replica was preserved as an authoritative source. This time, the recovery left no usable data — a more severe outcome from a very similar root cause
4. **Ghost replica required manual API intervention**: The Jiva controller has no self-healing for stale replica entries. This is an undocumented failure mode that requires direct REST API access to resolve
5. **Stale iSCSI session added significant complexity**: After fixing the storage layer, the radarr pod still couldn't start because of a session held on a different node. This class of problem is hard to diagnose — the mount failure looks identical to the original iSCSI failure

### Comparison with 2026-02-22 Incident

| Aspect | 2026-02-22 | 2026-03-28 |
|--------|------------|------------|
| Failure mode | All replicas in `Rebuilding: true` | All replicas with diverged chains |
| Authoritative replica preserved | Yes (rep-3 on k8s01) | No — all three wiped |
| Data loss | None | Total (Radarr must be reconfigured) |
| Additional complications | fsck race condition | Ghost replica + stale iSCSI session |
| Detection time | ~16h | ~30h |
| Active recovery time | ~43m | ~28m |
| Alerts existed | No | No (same as before) |

---

## Action Items

| Priority | Action | Owner | Due Date | Status |
|----------|--------|-------|----------|--------|
| Critical | Alert: pod stuck in ContainerCreating > 5min | SRE | 2026-04-04 | Open |
| Critical | Alert: Jiva replica CrashLoopBackOff (openebs namespace) | SRE | 2026-04-04 | Open |
| Critical | Investigate recurring Jiva divergence root event (node/UPS/hypervisor logs 2026-03-27 ~03:00) | SRE | 2026-04-04 | Open |
| High | Evaluate migration from Jiva to Longhorn or Mayastor | SRE | 2026-04-18 | Open |
| High | Implement ghost replica detection (controller API vs running pods) | SRE | 2026-04-11 | Open |
| High | Write runbook: ghost replica removal + stale iSCSI session logout | SRE | 2026-04-11 | Open |
| High | Implement alert: FailedMount events > 3 on any pod | SRE | 2026-04-04 | Open |
| Medium | Automate Radarr config backup (daily, separate PVC) | SRE | 2026-04-18 | Open |
| Medium | Verify jiva-snapshot-cleanup cronjob health and snapshot chain depth | SRE | 2026-04-04 | Open |

---

## Technical Details

### Environment

- **Cluster**: pvek8s (microk8s, 3 nodes: k8s01/172.22.22.6, k8s02/172.22.22.8, k8s03/172.22.22.9)
- **Storage**: OpenEBS Jiva (`openebs-jiva-default` storage class)
- **Affected PVC**: `radarr-config` (`pvc-a634b9a3-fdaa-4b45-9dc3-2486e716d755`), 5Gi RWO
- **iSCSI target**: `iqn.2016-09.com.openebs.jiva:pvc-a634b9a3-fdaa-4b45-9dc3-2486e716d755` at `10.152.183.80:3260`

### Replica State at Discovery

| Node  | Replica | Head Image   | Chain Checkpoint (first snap) | Status           |
|-------|---------|-------------|-------------------------------|------------------|
| k8s01 | rep-3   | head-465    | volume-snap-03854b6e...       | CrashLoopBackOff |
| k8s02 | rep-2   | head-173    | volume-snap-65160391...       | CrashLoopBackOff |
| k8s03 | rep-1   | head-176    | volume-snap-e6fa71a8...       | CrashLoopBackOff |

All three checkpoints were absent from each other's chains, confirming multi-way divergence with no common ancestor in the active chain.

### Key Log Entries

**Jiva replica fatal error (all 3 replicas):**

```
level=fatal msg="Failed to add replica to controller, err: Current replica's
checkpoint not present in rwReplica chain, Shutting down..."
```

**iSCSI mount failure (radarr pod events):**

```
Warning  FailedMount  kubelet  MountVolume.WaitForAttach failed for volume
"pvc-a634b9a3-...": failed to get any path for iscsi disk, last err seen:
iscsi: failed to sendtargets to portal 10.152.183.80:3260 output:
iscsiadm: Connection to Discovery Address 10.152.183.80 failed
iscsiadm: Login I/O error, failed to receive a PDU
```

**Ghost replica in controller API:**

```
tcp://10.1.236.71:9502  RW    ← dead pod IP, no current replica has this address
tcp://10.1.236.245:9502 WO    ← rep-2 (empty, waiting to rebuild from ghost)
```

**Stale iSCSI session on k8s03 (controller log):**

```
rejecting connection: 10.1.73.64 target already connected at 172.22.22.9
```

**Volume recovery confirmation (controller log):**

```
Previously Volume RO: true, Currently: false, Total Replicas: 2, RW replicas: 2
```

---

## References

- Previous incident (same PVC, same failure mode): [`2026-02-22-radarr-openebs-jiva-replica-divergence.md`](2026-02-22-radarr-openebs-jiva-replica-divergence.md)
- Cluster cascade failure (Jiva snapshot chain depth): [`2026-01-06-cluster-cascade-failure.md`](2026-01-06-cluster-cascade-failure.md)
- Linear ticket: [PGM-115](https://linear.app/pgmac-net-au/issue/PGM-115)

---

## Reviewers

- **Prepared by**: Claude (AI Assistant)
- **Date**: 2026-03-28
- **Review Status**: Draft — Pending human review
