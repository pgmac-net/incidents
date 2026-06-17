---
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

This occurs after a pod is **force-deleted** (`--force --grace-period=0`) or its container disappears from containerd before graceful shutdown, and the replacement pod is scheduled to a **different node** than where the original pod ran.

The Jiva CSI node plugin on the new node checks `JivaVolume.metadata.labels.nodeID` before staging. If `nodeID` points to a different node, it rejects the mount regardless of whether actual mounts or iSCSI sessions are still active.

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

## References

- PIR: [seerr Jiva CSI Stale Node Attachment](../incidents/2026-06-17-seerr-jiva-csi-stale-node-attachment.md)
- Linear: [PGM-254](https://linear.app/pgmac-net-au/issue/PGM-254) — runbook creation ticket
- Related: [jiva-csi-mount-proliferation.md](jiva-csi-mount-proliferation.md) — same CSI infrastructure, different failure mode (duplicate mounts from kubelite restarts, same node)
- Related: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md) — iSCSI session drop from jiva-ctrl eviction
