---
title: "Jiva CSI stale node attachment"
tags:
  - runbook
  - openebs
  - jiva
  - storage
  - microk8s
---

# Jiva CSI PVC Stuck After Pod Rescheduled to Different Node

**Service:** openebs-jiva-csi (pvek8s)
**First observed:** 2026-06-17
**PIR:** [seerr Jiva CSI Stale Node Attachment — PVC Stuck After Cross-Node Rescheduling](../incidents/2026-06-17-seerr-jiva-csi-stale-node-attachment.md)

---

## Symptom

A pod that uses a Jiva CSI PVC is stuck in `ContainerCreating`. The kubelet on the new node logs:

```
MountVolume.MountDevice failed for volume "pvc-<id>": rpc error: code = FailedPrecondition
desc = volume {pvc-<id>} is already mounted at more than one place:
{{/var/snap/microk8s/common/var/lib/kubelet/plugins/kubernetes.io/csi/jiva.csi.openebs.io/<hash>/globalmount  ext4  /dev/disk/by-path/ip-<target>:3260-iscsi-iqn...-lun-0}}
```

Or, if `mountInfo` has already been partially cleared:

```
desc = volume {pvc-<id>} is already mounted at more than one place: {{   }}
```

The Jiva CSI node plugin on the new node checks `JivaVolume.metadata.labels.nodeID` before staging. If `nodeID` points to a different node **and that node is `Ready`**, it rejects the mount regardless of whether actual mounts or iSCSI sessions are still active.

There are two distinct triggers.

## Quick Reference

| | **Mode 1 — Single pod rescheduled** | **Mode 2 — Multi-node reboot** |
| --- | --- | --- |
| **Trigger** | A pod is force-deleted (`--force --grace-period=0`), or its container vanishes from containerd before graceful shutdown, and the replacement lands on a different node | All cluster nodes are rebooted and returned to `Ready` (e.g. after a [frozen-init recovery](systemd-pid1-frozen-init.md)) |
| **Scale** | One volume | Every volume whose pod moved — nine in the 2026-09-03 incident |
| **Old node state** | Usually still `Ready`, with live mounts and an iSCSI session | Rebooted: no mounts, no sessions, no staging dirs — nothing to clean up |
| **Why the guard fires** | Genuine leftover attachment on the old node | Nothing is attached anywhere; restoring the old node to `Ready` re-armed a guard against a mount that no longer exists |
| **Recovery** | Full cleanup — [Steps 1–6](#recovery) below | Clear the stale labels only — [Failure Mode 2](#failure-mode-2--multi-node-reboot) below |
| **First observed** | 2026-06-17 | 2026-09-03 |

> **Do not run Mode 1's cleanup for a Mode 2 event.** After a reboot there are no mounts or sessions to unwind, and the CSI node pod is already a fresh process. Only the CRD label is stale.

---

## Root Cause

The Jiva CSI driver tracks which node has a volume staged via three mechanisms in the `JivaVolume` CRD:

1. **`metadata.labels.nodeID`** — the node that currently holds the volume. This is the primary guard: `NodeStageVolume` is rejected if `nodeID` is set to a different node than the one calling.
2. **`spec.mountInfo`** — staging path, filesystem type, and device path from the previous node. Populated when staging succeeds; cleared when `NodeUnstageVolume` completes.
3. **Active iSCSI session** on the previous node — the iSCSI target tracks connected initiators.

Under normal pod termination, the kubelet calls `NodeUnpublishVolume` → `NodeUnstageVolume`, which clears all three. After a force-delete, none of these cleanup calls happen — all three remain set for the previous node.

---

## Recovery

All steps assume you know:
- `OLD_NODE` — the node where the pod previously ran (check `JivaVolume` labels or recent pod history)
- `NEW_NODE` — the node where the replacement pod is stuck
- `PVC_ID` — the PVC name (e.g. `pvc-746b2837-ca3c-4b95-9168-7b767573f799`)

### Step 1 — Confirm the diagnosis

```bash
# Check nodeID label and mountInfo on the JivaVolume CRD
kubectl get jivavolume $PVC_ID -n openebs --context pvek8s -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('nodeID:', d['metadata']['labels'].get('nodeID'))
print('mountInfo:', json.dumps(d.get('spec',{}).get('mountInfo',{}), indent=2))
"
# → nodeID should point to OLD_NODE, not NEW_NODE

# Confirm stale iSCSI session on old node
IQN="iqn.2016-09.com.openebs.jiva:$PVC_ID"
ssh $OLD_NODE "sudo iscsiadm -m session 2>/dev/null | grep $PVC_ID; exit 0"
# → tcp: [N] <target-ip>:3260,1 iqn.2016-09.com.openebs.jiva:pvc-<id> (non-flash)

# Confirm stale mounts on old node
ssh $OLD_NODE "sudo findmnt | grep $PVC_ID; exit 0"
```

### Step 2 — Clean up stale mounts on old node

```bash
# Unmount pod-specific bind mount (if present)
POD_MOUNT=$(ssh $OLD_NODE "sudo findmnt | grep $PVC_ID | grep -v globalmount | awk '{print \$1}'; exit 0" 2>/dev/null)
if [ -n "$POD_MOUNT" ]; then
  ssh $OLD_NODE "sudo umount '$POD_MOUNT'"
fi

# Unmount globalmount (if present)
GLOBAL_MOUNT=$(ssh $OLD_NODE "sudo findmnt | grep $PVC_ID | grep globalmount | awk '{print \$1}'; exit 0" 2>/dev/null)
if [ -n "$GLOBAL_MOUNT" ]; then
  ssh $OLD_NODE "sudo umount '$GLOBAL_MOUNT'"
fi

# Verify both mounts are gone
ssh $OLD_NODE "sudo findmnt | grep $PVC_ID; exit 0"
# → (empty)
```

### Step 3 — Log out iSCSI session on old node

```bash
TARGET_IP=$(kubectl get jivavolume $PVC_ID -n openebs --context pvek8s \
  -o jsonpath='{.spec.iscsiSpec.targetIP}')
IQN="iqn.2016-09.com.openebs.jiva:$PVC_ID"

ssh $OLD_NODE "sudo iscsiadm -m node -T '$IQN' -p '${TARGET_IP}:3260' --logout"
# → Logout of [sid: N, target: iqn.2016-09.com.openebs.jiva:pvc-..., portal: ...] successful.

# Confirm no sessions remain
ssh $OLD_NODE "sudo iscsiadm -m session 2>/dev/null | grep $PVC_ID; exit 0"
# → (empty)
```

### Step 4 — Clear stale CRD state

```bash
# Clear mountInfo fields
kubectl patch jivavolume $PVC_ID -n openebs --context pvek8s --type='merge' \
  -p '{"spec":{"mountInfo":{"devicePath":"","fsType":"","stagingPath":""}}}'

# Update nodeID label to new node
kubectl label jivavolume $PVC_ID -n openebs --context pvek8s \
  nodeID=$NEW_NODE --overwrite

# Verify
kubectl get jivavolume $PVC_ID -n openebs --context pvek8s \
  -o jsonpath='{.metadata.labels.nodeID}'
# → k8s01 (or whichever NEW_NODE is)
```

### Step 5 — Restart Jiva CSI node pod on new node

```bash
CSI_POD=$(kubectl get pods -n openebs --context pvek8s -o wide \
  | grep jiva-csi-node | grep "$NEW_NODE" | awk '{print $1}')
kubectl delete pod $CSI_POD -n openebs --context pvek8s

# Wait for restart
kubectl wait pods -n openebs --context pvek8s -l app=openebs-jiva-csi-node \
  --field-selector "spec.nodeName=$NEW_NODE" --for=condition=Ready --timeout=60s
```

### Step 6 — Force-delete the stuck application pod

```bash
# Identify the stuck pod
kubectl get pods -n <namespace> --context pvek8s | grep <app-name>

# Force delete to trigger fresh NodeStageVolume with clean CRD state
kubectl delete pod/<app-pod> -n <namespace> --context pvek8s --force --grace-period=0

# Watch the new pod start
kubectl get pods -n <namespace> --context pvek8s -w
# → should reach Running 1/1 within ~90 seconds
```

---

## Verification

```bash
# Application pod running
kubectl get pods -n <namespace> --context pvek8s | grep <app-name>
# → <app-pod>   1/1   Running   0   90s

# JivaVolume nodeID updated and mountInfo populated with new node's paths
kubectl get jivavolume $PVC_ID -n openebs --context pvek8s \
  -o jsonpath='{.metadata.labels.nodeID}'
# → <NEW_NODE>

# No stale mounts or iSCSI sessions on old node
ssh $OLD_NODE "sudo findmnt | grep $PVC_ID; sudo iscsiadm -m session 2>/dev/null | grep $PVC_ID; exit 0"
# → (empty)

# Jiva replicas all healthy
kubectl get pods -n openebs --context pvek8s | grep $PVC_ID
# → all jiva-ctrl and jiva-rep pods Running
```

---

## Failure Mode 2 — Multi-Node Reboot

### When it occurs

After every node in the cluster has been rebooted and returned to `Ready` — for example following a [systemd frozen-init recovery](systemd-pid1-frozen-init.md) or a full power event. Pods are rescheduled while the cluster is degraded, so many land on a different node than their `nodeID` label records.

The guard's second condition is what bites: it only rejects when the node named in the label is `Ready`. During ordinary single-node maintenance the old node is down and the guard correctly stands aside. Rebooting *all* nodes back to health re-arms it against attachments that no longer exist anywhere.

Because the kubelet was dead when these volumes stopped being used, `NodeUnstageVolume` never ran, so no label was ever cleared. Nothing reconciles `nodeID` against reality afterwards.

### Detection

```bash
# Every volume's label vs. where its consumer actually is
kubectl --context pvek8s get jivavolume -n openebs -L nodeID
kubectl --context pvek8s get pods -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase' \
  --no-headers | awk '$4!="Running"'
```

Two corroborating signals confirm the label is the cause rather than a real double-mount:

- A volume with **no** `nodeID` label mounts without trouble
- A volume whose label **matches** its node keeps working throughout

```bash
# Prove nothing is actually mounted anywhere — required before clearing any label
for h in k8s01 k8s02 k8s03; do
  echo -n "$h jiva globalmounts: "
  ssh $h 'grep -c "jiva.csi.openebs.io.*globalmount" /proc/mounts
          echo -n "  iscsi sessions: "; sudo iscsiadm -m session 2>&1 | grep -c "^tcp" || echo 0'
done
```

> The error message is misleading: it prints `spec.mountInfo` but tests the `nodeID` label. Clearing `mountInfo` changes the text to `{{   }}` and fixes nothing — do not waste time on it.

### Recovery

**Safety gate first.** The label is a genuine RWO double-mount guard. Only clear it for volumes proven unmounted everywhere by the Detection step. Leave alone any volume whose staging hash appears in a live mount.

```bash
# Back up all CRs first
kubectl --context pvek8s get jivavolume -n openebs -o json > jivavolumes-prepatch.json

# Canary one volume, confirm its pod starts, then do the rest
kubectl --context pvek8s -n openebs label jivavolume $PVC_ID nodeID-
```

Each pod mounts within ~2 minutes (kubelet's retry backoff). Success is visible in the CR itself — the driver re-labels the volume with the **correct** node once staging succeeds:

```bash
kubectl --context pvek8s get jivavolume -n openebs -L nodeID
```

### Verification

```bash
kubectl --context pvek8s get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'
# → empty (or only transient CronJob pods)

kubectl --context pvek8s get jivavolume -n openebs \
  -o custom-columns='PHASE:.status.phase,STATUS:.status.status' --no-headers | sort | uniq -c
# → all Ready RW
```

A pod that still fails to mount after its label is cleared has a *different* problem — most likely filesystem damage from the unclean shutdown. See [jiva-volume-ext4-corruption](jiva-volume-ext4-corruption.md).

---

## References

- PIR: [seerr Jiva CSI Stale Node Attachment](../incidents/2026-06-17-seerr-jiva-csi-stale-node-attachment.md) — Failure Mode 1
- PIR: [pvek8s Total Control Plane Loss — systemd +esm4 PID 1 Segfault](../incidents/2026-09-02-systemd-esm4-pid1-segfault-control-plane-loss.md) — Failure Mode 2
- Related: [systemd-pid1-frozen-init.md](systemd-pid1-frozen-init.md) — the recovery that triggers Failure Mode 2
- Related: [jiva-volume-ext4-corruption.md](jiva-volume-ext4-corruption.md) — what to check when clearing the label is not enough
- Linear: [PGM-254](https://linear.app/pgmac-net-au/issue/PGM-254) — runbook creation ticket
- Related: [jiva-csi-mount-proliferation.md](jiva-csi-mount-proliferation.md) — same CSI infrastructure, different failure mode (duplicate mounts from kubelite restarts, same node)
- Related: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md) — iSCSI session drop from jiva-ctrl eviction
