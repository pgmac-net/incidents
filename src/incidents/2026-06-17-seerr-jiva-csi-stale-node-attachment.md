---
tags:
  - k8s01
  - k8s03
  - openebs
  - jiva
  - storage
  - scheduling
---

# Post Incident Review: seerr Jiva CSI Stale Node Attachment — PVC Stuck After Cross-Node Rescheduling

**Date:** 2026-06-17
**Duration:** ~31m active (~21:02 AEST → ~21:33 AEST)
**Severity:** Medium (single service unavailable; no data loss; recovery required manual CSI state surgery)
**Status:** Resolved

---

## Executive Summary

During a routine seerr Helm chart version upgrade (v3.2.0 → v3.3.0), ArgoCD killed the running pod on k8s03 to apply the new StatefulSet template. The pod had been running since 2026-06-12. When the pod was killed, the container was already removed from containerd before the kubelet could confirm termination, leaving the pod stuck with a `deletionTimestamp` but unable to complete its finalizer cycle. A force-delete was required to unblock the StatefulSet from creating a replacement.

The replacement pod was scheduled to k8s01 (different from the original k8s03). This triggered a second failure chain: the Jiva CSI node plugin on k8s01 refused to stage the PVC because the `JivaVolume` CRD still carried `nodeID: k8s03` in its labels, stale `mountInfo` containing the k8s03 staging paths, and an active iSCSI session on k8s03 that had never been torn down. All three of these Jiva CSI node-tracking artefacts must be cleared before the volume can be staged on a new node. The fix required manually unmounting the globalmount and pod-specific bind mount on k8s03, logging out the iSCSI initiator session, clearing `mountInfo` in the JivaVolume CRD, and updating the `nodeID` label to `k8s01`. A restart of the Jiva CSI node DaemonSet pod on k8s01 and a force-delete of the stuck seerr pod then allowed the volume to mount cleanly and seerr to start within seconds.

The root cause is the absence of a documented recovery procedure for Jiva CSI volumes that need to move between nodes following a force-deleted pod. The Jiva CSI driver's node-tracking state (`nodeID` label, `mountInfo`, iSCSI sessions) is designed to be cleaned up by the normal pod lifecycle (kubelet calling `NodeUnpublishVolume` → `NodeUnstageVolume`), which does not execute after a force-delete. This failure mode is distinct from the existing mount-proliferation failure mode and warrants its own runbook.

---

## Timeline (AEST — UTC+10)

| Time           | Event |
| -------------- | ----- |
| **~21:00 AEST** | User updates seerr Helm chart version; ArgoCD begins sync |
| **21:02 AEST** | ArgoCD sync kills `seerr-seerr-chart-0` on k8s03; pod enters `Failed` state; `deletionTimestamp` set to 21:02:30 |
| **21:02 AEST** | Kubelet unable to confirm container termination — containerd has already removed the container record (`de45ec18c272b56a76c3e32ed25475da1f99d0ac7a5d398f6f7a2ed124bea08a` not found); pod stays stuck with stale `deletionTimestamp` |
| **~21:03 AEST** | Investigation begins; `kubectl get all -n media` shows `seerr-seerr-chart-0` in `Error` state with `5d6h` age; `kubectl logs` returns `unable to retrieve container logs` |
| **~21:04 AEST** | Pod described: `Exit Code: 1`, `Started: 2026-06-12`, `Finished: 2026-06-17T11:02:01Z`; pod phase `Failed`, `deletionTimestamp: 2026-06-17T11:02:30Z`; container not found in crictl on k8s03 |
| **~21:05 AEST** | Force-delete issued: `kubectl delete pod/seerr-seerr-chart-0 --force --grace-period=0` |
| **~21:05 AEST** | New `seerr-seerr-chart-0` created by StatefulSet controller; scheduled to **k8s01** (not k8s03) |
| **21:07 AEST** | Pod stuck in `ContainerCreating`; kubelet reports `MountVolume.MountDevice failed: volume already mounted at more than one place: {{/globalmount  ext4  /dev/disk/by-path/...}}` |
| **21:07 AEST** | Found stale pod-specific bind mount on k8s03: `findmnt` shows PVC mount at `pods/c077fce2.../volumes/...`; unmounted |
| **21:11 AEST** | Found and logged out stale iSCSI session on k8s03: `iscsiadm -m session` shows `iqn.2016-09.com.openebs.jiva:pvc-746b2837`; Jiva controller confirms logout from initiator 172.22.22.9:35104 |
| **21:12 AEST** | Jiva CSI `NodeUnstageVolume` on k8s03 completes: `target not mounted`; globalmount path fully released |
| **21:12–21:26 AEST** | Error message pattern changes to `{{   }}` (empty fields) confirming the check reads `JivaVolume.spec.mountInfo`; error still fires because CRD has stale content |
| **21:26 AEST** | Cleared stale `mountInfo` in JivaVolume CRD: `kubectl patch jivavolume pvc-746b2837... --type=merge -p '{"spec":{"mountInfo":...}}'` |
| **21:28 AEST** | Discovered `nodeID: k8s03` label on JivaVolume CRD; this is the primary guard the Jiva CSI node plugin checks before staging; updated to `k8s01` |
| **21:30 AEST** | Deleted Jiva CSI node pod on k8s01 to clear any in-memory goroutine state; pod restarts cleanly |
| **21:31 AEST** | Force-deleted stuck seerr pod (backlogged on old CSI socket retry cycle); new pod immediately recreated |
| **21:32 AEST** | `NodePublishVolume` succeeds on k8s01; volume bind-mounted to pod path |
| **21:33 AEST** | `seerr-seerr-chart-0` enters `Running 1/1`; seerr application starts on port 5055; Radarr and Sonarr download sync confirmed working |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: Pod Stuck with deletionTimestamp — Container Gone from containerd

##### How did the pod stay stuck in `Error`/`Failed` state after being killed?

The pod's `deletionTimestamp` was set at 21:02:30, but the kubelet on k8s03 could not complete the pod finalizer cycle because it could not confirm the container had stopped — `crictl logs <container-id>` returned `not found`. The container had already been cleaned up from the containerd runtime before the kubelet's finalizer check ran.

##### How did the container disappear from containerd before the kubelet confirmed termination?

ArgoCD's StatefulSet rolling update sent a `SIGTERM` to the container. When the container process exited, containerd removed its runtime state. The kubelet's finalizer then queried containerd for the container status and received a `NotFound` error, which it treated as a permanent failure rather than a reason to proceed with pod cleanup.

##### How did this leave the pod stuck indefinitely?

The kubelet's pod eviction/garbage collection loop requires confirming the container state before removing the pod API object. With `NotFound` from containerd, it could not produce that confirmation. The pod's `deletionTimestamp` was set but the pod remained in the API server in `Failed` phase indefinitely.

##### How was this not detected or resolved automatically?

No Nagios check or alerting rule monitors for pods with a `deletionTimestamp` older than N minutes. The stuck pod appeared as `Error` (not `Terminating`) which is easy to miss. No documented procedure existed for force-deleting containerd-orphaned pods as part of a chart upgrade workflow.

---

#### Chain 2: New Pod Cannot Mount Jiva PVC After Rescheduling to k8s01

##### How did the new seerr pod on k8s01 fail to mount the PVC?

The Jiva CSI node plugin on k8s01 called `NodeStageVolume` for `pvc-746b2837`. The plugin reads the `JivaVolume` CRD for this volume and found three pieces of stale node-tracking state that prevented staging:

1. `metadata.labels.nodeID: k8s03` — the primary guard; Jiva CSI rejects `NodeStageVolume` if `nodeID` is set to a different node
2. `spec.mountInfo` populated with k8s03's globalmount path and device path
3. Active iSCSI session on k8s03 still logged in to the Jiva iSCSI target

##### How did all three pieces of stale state end up in the JivaVolume CRD?

The old pod on k8s03 was force-deleted (`--force --grace-period=0`). A force-delete skips the normal pod termination lifecycle. Under normal termination, the kubelet calls `NodeUnpublishVolume` → `NodeUnstageVolume` on the Jiva CSI node plugin, which: unmounts the pod volume bind-mount, unmounts the globalmount, logs out the iSCSI initiator, and clears `mountInfo` and `nodeID` from the JivaVolume CRD. Force-delete bypasses all of this.

##### How did the situation require a force-delete?

The pod was stuck with a `deletionTimestamp` because its container had disappeared from containerd (Chain 1). A normal `kubectl delete` had no effect — the pod was already in a deletion cycle that could not complete. Force-delete was the only available unblocking mechanism.

##### How was the compound failure (force-delete → stale CSI state → new pod stuck) not anticipated?

No runbook existed for "Jiva PVC stuck after pod force-deleted and rescheduled to a different node". The existing `jiva-csi-mount-proliferation` runbook covers duplicate bind mounts from kubelite restarts (same-node issue) but not cross-node CSI state migration. The multi-step cleanup (iSCSI logout + mount cleanup + CRD patch + nodeID label update) required manual discovery through log analysis and the Jiva CSI source code behaviour.

##### How was the root `nodeID` label guard not documented as a recovery step?

The `nodeID` label mechanism is internal to the Jiva CSI implementation and is not prominently documented. It took iterative investigation — observing that `{{   }}` empty mount info still produced the error, then examining the JivaVolume CRD labels — to identify it as the primary block. This knowledge gap means future incidents will require the same rediscovery.

---

## Impact

### Services Affected

| Service | Impact | Duration |
| ------- | ------ | -------- |
| `seerr` (Overseerr) | Completely unavailable; pod could not start | ~31m |
| Radarr / Sonarr download sync | No new download requests processed | ~31m |

### Duration

- **Total incident window:** ~31 minutes (21:02 → 21:33 AEST)
- **With documented procedure (runbook):** ~5 minutes

### Scope

- k8s03: affected (stale Jiva mounts and iSCSI session required manual cleanup)
- k8s01: affected (new pod could not start)
- k8s02: not affected
- Data: no data loss; Jiva replica set remained healthy throughout
- User-visible: seerr web UI unavailable for ~31 minutes

---

## Resolution Steps Taken

### Phase 1: Diagnosis

1. Inspected `seerr-seerr-chart-0`: pod in `Error/Failed` with `deletionTimestamp` set and container not found in crictl on k8s03.
2. Force-deleted stuck pod: `kubectl delete pod/seerr-seerr-chart-0 -n media --force --grace-period=0`.
3. New pod created; scheduled to k8s01 (not k8s03); stuck in `ContainerCreating`.
4. Identified `FailedMount` error: `MountVolume.MountDevice failed: volume already mounted at more than one place`.
5. Checked k8s03 for stale mounts: `ssh k8s03 "sudo findmnt | grep 746b2837"` — found pod-specific bind mount.
6. Checked k8s03 iSCSI sessions: `ssh k8s03 "sudo iscsiadm -m session"` — found active session.
7. Inspected `JivaVolume` CRD: found `mountInfo` with k8s03 paths and `labels.nodeID: k8s03`.

### Phase 2: Cleanup k8s03 Stale State

1. Unmounted pod-specific bind mount on k8s03:

   ```bash
   ssh k8s03 "sudo umount /var/snap/microk8s/common/var/lib/kubelet/pods/c077fce2-2dd4-4ea7-8d2e-78084d84a518/volumes/kubernetes.io~csi/pvc-746b2837-ca3c-4b95-9168-7b767573f799/mount"
   ```

2. Unmounted globalmount on k8s03 (Jiva CSI NodeUnstageVolume triggered organically):

   ```bash
   ssh k8s03 "sudo umount /var/snap/microk8s/common/var/lib/kubelet/plugins/kubernetes.io/csi/jiva.csi.openebs.io/82405009b624d9c105b769c82f275dc4d6d356c5e0df5ac9c0d04766f89db002/globalmount"
   ```

3. Logged out iSCSI session on k8s03:

   ```bash
   ssh k8s03 "sudo iscsiadm -m node -T iqn.2016-09.com.openebs.jiva:pvc-746b2837-ca3c-4b95-9168-7b767573f799 -p 10.152.183.57:3260 --logout"
   ```

### Phase 3: Clear JivaVolume CRD Stale State

1. Cleared stale `mountInfo`:

   ```bash
   kubectl patch jivavolume pvc-746b2837-ca3c-4b95-9168-7b767573f799 -n openebs --context pvek8s \
     --type='merge' -p '{"spec":{"mountInfo":{"devicePath":"","fsType":"","stagingPath":""}}}'
   ```

2. Updated `nodeID` label to the new node:

   ```bash
   kubectl label jivavolume pvc-746b2837-ca3c-4b95-9168-7b767573f799 -n openebs --context pvek8s \
     nodeID=k8s01 --overwrite
   ```

### Phase 4: Force Fresh Start

1. Restarted Jiva CSI node pod on k8s01 to clear in-memory state:

   ```bash
   kubectl delete pod openebs-jiva-csi-node-nnmsp -n openebs --context pvek8s
   ```

2. Force-deleted seerr pod (stuck in backoff cycle against old CSI socket):

   ```bash
   kubectl delete pod/seerr-seerr-chart-0 -n media --context pvek8s --force --grace-period=0
   ```

3. New pod created; Jiva CSI `NodeStageVolume` succeeded immediately; pod became `Running 1/1` within 90 seconds.

---

## Verification

```bash
# seerr pod running on new node
kubectl --context pvek8s get pods -n media | grep seerr
# → seerr-seerr-chart-0   1/1   Running   0   90s

# Application serving traffic
kubectl --context pvek8s logs seerr-seerr-chart-0 -n media --tail=5
# → Server ready on port 5055

# No stale mounts on k8s03
ssh k8s03 "sudo findmnt | grep 746b2837; exit 0"
# → (empty)

ssh k8s03 "sudo iscsiadm -m session 2>/dev/null | grep 746b2837; exit 0"
# → (empty)

# JivaVolume nodeID updated and mountInfo populated by new node
kubectl --context pvek8s get jivavolume pvc-746b2837-ca3c-4b95-9168-7b767573f799 -n openebs \
  -o jsonpath='{.metadata.labels.nodeID}'
# → k8s01

# Jiva replicas healthy
kubectl --context pvek8s get pods -n openebs | grep 746b2837
# → all Jiva replicas Running
```

---

## Preventive Measures

### Immediate Actions Required

1. **Create runbook: Jiva CSI PVC stuck after pod rescheduled to different node** (High)
    - Chain 2 required multi-step manual CSI state surgery with no documented procedure. On-call would need to rediscover every step under pressure.
    - Linear: [PGM-254](https://linear.app/pgmac-net-au/issue/PGM-254)

2. **Add Nagios alert for pods with deletionTimestamp older than 5 minutes** (Medium)
    - Chain 1: the stuck pod was not detected by any monitoring; discovered only when investigating the chart update. A pod stuck in deletion for > 5 minutes is always a symptom of a deeper problem.
    - Linear: [PGM-255](https://linear.app/pgmac-net-au/issue/PGM-255)

### Longer-Term Improvements

3. **Evaluate StatefulSet node affinity for Jiva-backed workloads** (Low)
    - Rescheduling a StatefulSet pod to a different node while it uses a Jiva PVC causes the entire Chain 2 failure. Adding soft node affinity (prefer same node) would reduce the probability of cross-node reschedule incidents.
    - Linear: [PGM-257](https://linear.app/pgmac-net-au/issue/PGM-257)

4. **Document force-delete procedure with Jiva CSI cleanup steps** (Medium)
    - Any time `kubectl delete --force` is used on a pod with a Jiva CSI PVC, the CSI teardown must be performed manually. This should be a noted prerequisite in any runbook that calls for force-deleting pods.
    - Linear: [PGM-256](https://linear.app/pgmac-net-au/issue/PGM-256)

---

## Lessons Learned

### What Went Well

- Log correlation was fast: the `{{   }}` error format after patching `mountInfo` clearly confirmed the Jiva CSI plugin was reading that field, pointing directly to the CRD as the source of truth.
- Incremental cleanup approach worked: each fix (iSCSI logout, mount cleanup, CRD patch, nodeID label update) was independently verifiable, making it possible to confirm each step before proceeding.
- Jiva CSI node pod restart and pod force-delete at the end cleared the remaining retry backlog cleanly.

### What Didn't Go Well

- Assumed initial error was about filesystem-level mounts only; spent time on k8s03 mount cleanup before discovering the `nodeID` label was the primary block.
- No prior knowledge that `nodeID` label in JivaVolume CRD is the primary node-attachment guard; this was discovered by examining CRD fields iteratively.
- The error message `already mounted at more than one place: {{   }}` with empty fields was confusing — it correctly reflected the cleared `mountInfo` but didn't indicate the `nodeID` label check.
- Jiva CSI node pod restart was done before the seerr pod force-delete; the pod was still stuck in backoff from the old socket. The order should have been: patch CRD → force-delete seerr pod → (optionally restart CSI node pod).

### Surprise Findings

- The Jiva CSI node plugin reads `JivaVolume.metadata.labels.nodeID` as a primary guard before attempting `NodeStageVolume`. This label is not updated on force-delete — only on graceful termination via the kubelet lifecycle.
- `kubectl delete --force --grace-period=0` bypasses the entire CSI teardown path, leaving iSCSI sessions, filesystem mounts, and CRD state all intact on the previous node.
- The error message includes the contents of `JivaVolume.spec.mountInfo` verbatim; when `mountInfo` was cleared to empty strings, the error changed from `{{/path  ext4  /dev/...}}` to `{{   }}`, making this a useful diagnostic signal.
- The globalmount path hash (`82405009b624d...`) is derived from the PV ID, not the node name — so the path is identical on every node. This means a stale globalmount from k8s03 and a fresh globalmount on k8s01 would look identical in error messages.

---

## Action Items

| #  | Action | Priority | Linear |
| -- | ------ | -------- | ------ |
| 1  | Create runbook: Jiva CSI PVC stuck after pod rescheduled to different node | High | [PGM-254](https://linear.app/pgmac-net-au/issue/PGM-254) |
| 2  | Add Nagios alert for pods with deletionTimestamp older than 5 minutes | Medium | [PGM-255](https://linear.app/pgmac-net-au/issue/PGM-255) |
| 3  | Document force-delete + Jiva CSI manual teardown procedure | Medium | [PGM-256](https://linear.app/pgmac-net-au/issue/PGM-256) |
| 4  | Evaluate StatefulSet node affinity for Jiva-backed workloads | Low | [PGM-257](https://linear.app/pgmac-net-au/issue/PGM-257) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03)
- **Kubernetes version:** v1.35.0
- **Storage:** OpenEBS Jiva CSI 3.6.0 (`jiva.csi.openebs.io`)
- **Affected PVC:** `seerr-seerr-chart-config` (`pvc-746b2837-ca3c-4b95-9168-7b767573f799`)
- **Affected app:** seerr v3.3.0 (StatefulSet, 1 replica)

### Key Error Signatures

Jiva CSI `NodeStageVolume` rejection (with stale mountInfo populated):

```
MountVolume.MountDevice failed for volume "pvc-746b2837-...": rpc error: code = FailedPrecondition
desc = volume {pvc-746b2837-...} is already mounted at more than one place:
{{/var/snap/microk8s/common/var/lib/kubelet/plugins/kubernetes.io/csi/jiva.csi.openebs.io/<hash>/globalmount  ext4  /dev/disk/by-path/ip-<target>:3260-iscsi-iqn...-lun-0}}
```

Jiva CSI `NodeStageVolume` rejection (after mountInfo cleared but nodeID label still wrong):

```
desc = volume {pvc-746b2837-...} is already mounted at more than one place: {{   }}
```

Pod stuck with stale deletionTimestamp (container not found in containerd):

```
unable to retrieve container logs for containerd://<container-id>
```

```
crictl logs <container-id>
# → rpc error: code = NotFound desc = an error occurred when try to find container "...": not found
```

### JivaVolume CRD State Inspection

```bash
# Inspect nodeID label and mountInfo
kubectl get jivavolume <pvc-name> -n openebs --context pvek8s -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('nodeID:', d['metadata']['labels'].get('nodeID'))
print('mountInfo:', json.dumps(d.get('spec',{}).get('mountInfo',{}), indent=2))
"
```

### Jiva CSI Cross-Node Recovery Procedure

```bash
# 1. Identify the old node and volume
OLD_NODE=k8s03
PVC_ID=pvc-746b2837-ca3c-4b95-9168-7b767573f799
NEW_NODE=k8s01

# 2. Find and unmount stale bind mounts on old node
ssh $OLD_NODE "sudo findmnt | grep $PVC_ID"
ssh $OLD_NODE "sudo umount <pod-bind-mount-path>"
ssh $OLD_NODE "sudo umount <globalmount-path>"

# 3. Log out iSCSI session on old node
IQN="iqn.2016-09.com.openebs.jiva:$PVC_ID"
TARGET_IP=$(kubectl get jivavolume $PVC_ID -n openebs --context pvek8s \
  -o jsonpath='{.spec.iscsiSpec.targetIP}')
ssh $OLD_NODE "sudo iscsiadm -m node -T $IQN -p ${TARGET_IP}:3260 --logout"

# 4. Clear mountInfo and update nodeID
kubectl patch jivavolume $PVC_ID -n openebs --context pvek8s --type='merge' \
  -p '{"spec":{"mountInfo":{"devicePath":"","fsType":"","stagingPath":""}}}'
kubectl label jivavolume $PVC_ID -n openebs --context pvek8s nodeID=$NEW_NODE --overwrite

# 5. Restart Jiva CSI node pod on new node to clear in-memory state
CSI_POD=$(kubectl get pods -n openebs --context pvek8s -o wide | grep jiva-csi-node | grep $NEW_NODE | awk '{print $1}')
kubectl delete pod $CSI_POD -n openebs --context pvek8s

# 6. Force-delete stuck application pod (triggers fresh CSI staging on new node)
kubectl delete pod/<app-pod> -n <namespace> --context pvek8s --force --grace-period=0
```

---

## References

- Linear tickets: [PGM-254](https://linear.app/pgmac-net-au/issue/PGM-254), [PGM-255](https://linear.app/pgmac-net-au/issue/PGM-255), [PGM-256](https://linear.app/pgmac-net-au/issue/PGM-256), [PGM-257](https://linear.app/pgmac-net-au/issue/PGM-257)
- Runbook: [Jiva CSI PVC Stuck After Pod Rescheduled to Different Node](../runbooks/jiva-csi-stale-node-attachment.md)
- Related runbook: [Jiva CSI Mount Proliferation](../runbooks/jiva-csi-mount-proliferation.md)
- Related runbook: [Jiva Ctrl Eviction — iSCSI Drop and EXT4 Read-Only](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md)

---

## Reviewers

- @pgmac
