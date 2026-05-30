---
tags:
  - runbook
  - microk8s
  - storage
  - openebs
  - jiva
  - iscsi
  - node-restart
---

# Safe Node Restart for Nodes Hosting jiva-ctrl Pods

**Service:** OpenEBS Jiva iSCSI (pvek8s)
**First documented:** 2026-05-30
**PIR:** [pvek8s Post-Power-Outage Recovery — kubelet Volume Manager Stall and KCM Stale terminatingReplicas](../incidents/2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md)
**Linear:** [PGM-223](https://linear.app/pgmac-net-au/issue/PGM-223)

---

## When to Use This Runbook

Use this runbook whenever you need to restart kubelite (or drain/taint) a node that may be hosting jiva-ctrl pods (iSCSI targets).

**Why this matters:** jiva-ctrl pods are iSCSI targets. When the node running them is restarted, those pods are evicted and the iSCSI target process exits. Any workload pod on *another* node that has an active iSCSI session to the controller will detect a TCP connection failure, enter 120-second session recovery, and — if the target does not reappear within that window — have its SCSI device go offline. The kernel's JBD2 journal then aborts and EXT4 remounts the filesystem read-only. This is a data-safe failure but requires manual recovery.

The pre-restart procedure below migrates affected workload pods *before* the restart, so the iSCSI sessions are already gone and there is nothing to fail over.

See [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md) for recovery if the filesystem has already gone read-only.

---

## Pre-Restart Procedure

### Step 1 — Identify jiva-ctrl pods on the target node

```bash
TARGET_NODE=<node>   # e.g. k8s01

kubectl --context pvek8s get pods -n openebs -o wide --no-headers | \
  awk -v n="$TARGET_NODE" '/jiva.*ctrl/ && $7==n {print $1, $7}'
```

If the output is empty, no jiva-ctrl pods are on this node — skip to the [Node Restart Procedure](#node-restart-procedure).

Example output:
```
pvc-746b2837-...-jiva-ctrl-0   k8s01
pvc-a3a7e012-...-jiva-ctrl-0   k8s01
```

### Step 2 — Find nodes with active iSCSI sessions to those controllers

For each jiva-ctrl pod, check whether any node has a live iSCSI session to its controller service:

```bash
# Get the ClusterIP of each controller's service
# The service name shares the PV prefix with the ctrl pod name
kubectl --context pvek8s get svc -n openebs | grep "jiva-ctrl"
# → pvc-746b2837-...-jiva-ctrl-svc   ClusterIP   10.152.183.57   ...
# → pvc-a3a7e012-...-jiva-ctrl-svc   ClusterIP   10.152.183.22   ...

# Check all nodes for active sessions to those IPs
for pod in $(kubectl --context pvek8s get pods -n openebs \
    -l app=openebs-jiva-csi-node -o name); do
  echo "=== $pod ==="
  kubectl --context pvek8s exec -n openebs "$pod" -c jiva-csi-plugin -- \
    iscsiadm -m session 2>/dev/null || echo "(no sessions)"
done
```

Note which nodes have sessions to each controller IP. Those are the nodes hosting workload pods that must be migrated before the restart.

### Step 3 — Migrate workload pods off the affected nodes

For each controller with active sessions on other nodes, find and delete the workload pod that holds that PVC:

```bash
# Derive the PV name from the ctrl pod name (strip -jiva-ctrl-N suffix)
CTRL_POD=pvc-746b2837-...-jiva-ctrl-0
PV_NAME=${CTRL_POD%-jiva-ctrl-*}

# Find the PVC bound to this PV
kubectl --context pvek8s get pvc -A --no-headers | awk -v pv="$PV_NAME" '$3==pv {print $1, $2}'
# → media   seerr-seerr-chart-config

# Find the pod in that namespace using that PVC
PVC_NS=media
PVC_NAME=seerr-seerr-chart-config
kubectl --context pvek8s get pods -n "$PVC_NS" -o json | \
  python3 -c "
import json,sys
data=json.load(sys.stdin)
pvc='$PVC_NAME'
for p in data['items']:
  for v in p['spec'].get('volumes',[]):
    if v.get('persistentVolumeClaim',{}).get('claimName')==pvc:
      print(p['metadata']['name'])
"
```

Once you have the pod name, delete it and wait for it to reschedule to a node that is **not** `$TARGET_NODE`:

```bash
kubectl --context pvek8s delete pod -n "$PVC_NS" <pod-name>

# Watch until Running on a different node
kubectl --context pvek8s get pod -n "$PVC_NS" <pod-name> -o wide -w
# → 1/1 Running on k8s02 or k8s03 (not TARGET_NODE)
```

!!! warning "StatefulSet pods do not reschedule automatically on cordoned nodes"
    If the node is already cordoned (or if you cordon it before deleting), StatefulSet pods will stay
    Pending until you uncordon another eligible node. Delete the pod *before* cordoning the target node
    so the scheduler can place it freely.

Repeat for every controller with active sessions.

### Step 4 — Verify all sessions have logged out

Confirm no node retains an iSCSI session to the controllers that were on `$TARGET_NODE`:

```bash
for pod in $(kubectl --context pvek8s get pods -n openebs \
    -l app=openebs-jiva-csi-node -o name); do
  echo "=== $pod ==="
  kubectl --context pvek8s exec -n openebs "$pod" -c jiva-csi-plugin -- \
    iscsiadm -m session 2>/dev/null | grep "<controller-ClusterIP>" || echo "(none)"
done
# All nodes should show "(none)" for the affected controller IPs
```

Only proceed once all sessions to the affected controllers are gone.

---

## Node Restart Procedure

With iSCSI sessions safely cleared, restart the node using the standard dqlite → kubelite ordering:

1. **Cordon the node** (required — prevents the kubelet watch-race stall on restart):

    ```bash
    kubectl --context pvek8s cordon "$TARGET_NODE"
    ```

    See [kubelet-silent-stall.md — Failure Mode 2](kubelet-silent-stall.md) for why cordoning before restart is mandatory.

2. **Restart k8s-dqlite first**, wait for it to stabilise:

    ```bash
    ssh "$TARGET_NODE" "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
    # Wait until active and no 'database is locked' errors for 30s
    ssh "$TARGET_NODE" "sudo systemctl is-active snap.microk8s.daemon-k8s-dqlite.service"
    ```

3. **Restart kubelite**:

    ```bash
    ssh "$TARGET_NODE" "sudo systemctl restart snap.microk8s.daemon-kubelite.service"
    ```

4. **Wait for node Ready**:

    ```bash
    kubectl --context pvek8s wait node/"$TARGET_NODE" --for=condition=Ready --timeout=300s
    ```

5. **Uncordon**:

    ```bash
    kubectl --context pvek8s uncordon "$TARGET_NODE"
    ```

See [kubelet-volume-manager-stall.md — Option B](kubelet-volume-manager-stall.md) for the full dqlite restart safety procedure and lock-contention checks.

---

## Post-Restart Verification

```bash
# Node is Ready and schedulable
kubectl --context pvek8s get node "$TARGET_NODE"
# → Ready (no SchedulingDisabled)

# jiva-ctrl pods have rescheduled and are Running
kubectl --context pvek8s get pods -n openebs -o wide | grep jiva.*ctrl
# → all Running, spread across nodes

# Workload pods that were migrated are Running with rw filesystems
kubectl --context pvek8s get pods -n <namespace> <pod-name> -o wide
# → 1/1 Running on a node other than TARGET_NODE

# iSCSI sessions re-established on the workload node
NEW_NODE=$(kubectl --context pvek8s get pod -n <namespace> <pod-name> \
  -o jsonpath='{.spec.nodeName}')
NEW_JIVA_POD=$(kubectl --context pvek8s get pods -n openebs \
  -l app=openebs-jiva-csi-node \
  -o jsonpath="{.items[?(@.spec.nodeName=='$NEW_NODE')].metadata.name}")
kubectl --context pvek8s exec -n openebs "$NEW_JIVA_POD" -c jiva-csi-plugin -- \
  iscsiadm -m session
# → tcp: [...] iqn.2016-09.com.openebs.jiva:<pvc-name> (non-flash)

# Filesystem is rw
kubectl --context pvek8s exec -n openebs "$NEW_JIVA_POD" -c jiva-csi-plugin -- \
  grep "<pvc-name>" /proc/mounts
# → should show rw in mount options, not ro
```

---

## References

- PIR: [pvek8s Post-Power-Outage Recovery](../incidents/2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md) — Chain 4 root cause (batched jiva-ctrl eviction → EXT4 ro)
- Linear: [PGM-223](https://linear.app/pgmac-net-au/issue/PGM-223) — this runbook
- Related: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md) — recovery if the filesystem has already gone read-only (use when it's too late to migrate first)
- Related: [kubelet-volume-manager-stall.md](kubelet-volume-manager-stall.md) — Option B: full dqlite+kubelite restart procedure and lock-contention safety checks
- Related: [kubelet-silent-stall.md](kubelet-silent-stall.md) — Failure Mode 2: why cordon-before-restart is required for kubelite restarts
