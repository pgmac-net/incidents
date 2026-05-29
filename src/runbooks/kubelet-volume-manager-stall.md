---
tags:
  - runbook
  - kubelet
  - openebs
  - jiva
  - kine
  - dqlite
  - microk8s
  - storage
  - watch-stream
---

# Kubelet Volume Manager Stall — iSCSI WaitForAttachAndMount Hang

**Service:** microk8s kubelet / OpenEBS Jiva iSCSI (pvek8s)
**First observed:** 2026-05-28
**PIR:** [pvek8s Post-Power-Outage Recovery — kubelet Volume Manager Stall and KCM Stale terminatingReplicas](../incidents/2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md)

---

## Symptom

Pods scheduled to a node are stuck in `ContainerCreating` for minutes or hours. The node shows `Ready: True` and kubelet logs may be active, but no container creation events appear for the stuck pods. `iscsiadm -m session` on the affected node shows no active iSCSI sessions despite the pods claiming iSCSI PVCs.

This is distinct from pods stuck in `Pending` (scheduling failure). The pods have already been scheduled (they have `spec.nodeName` set) but the kubelet volume manager cannot progress from "desired" to "actual" state.

---

## Root Cause

The kubelet's client-go `processorListener` goroutines become permanently blocked after a kine/dqlite watch stream disruption (power outage, dqlite crash, or kine restart). The processorListeners consume events from the informer's delta queue — when kine's watch subscription state is corrupted on restart, no new events flow into the queue, and the goroutines block indefinitely in `select`.

Without informer events, the kubelet's volume reconciler never runs `VerifyControllerAttachedVolume` against `node.status.volumesAttached`. All pod worker goroutines block in `WaitForAttachAndMount`, waiting for the actual-state-of-world to reflect the attached volume — a state that will never arrive.

Crucially, the kubelet heartbeat mechanism uses a separate HTTPS endpoint (`/api/v1/nodes/<name>/status`) that does not depend on the informer event queue. The node continues reporting `Ready: True` even while the volume manager is completely frozen.

Additionally, because the stalled kubelet still reports the iSCSI volumes in `node.status.volumesInUse`, the Attachable-Detachable Controller (ADC) will not attach those volumes to another node — it believes the current node still holds them.

---

## Detection

```bash
# Step 1: Confirm pods are stuck in ContainerCreating with age > 5 minutes
kubectl --context pvek8s get pods -A --field-selector spec.nodeName=<node> | grep ContainerCreating

# Step 2: Check for active iSCSI sessions on the node — should be non-empty for iSCSI pods
ssh <node> "sudo iscsiadm -m session"
# → Empty output despite iSCSI PVCs claimed = volume manager is not progressing

# Step 3: Check volume manager metrics (kubelet :10255/metrics or via Prometheus)
# The stall signature is desired_state_of_world present but actual_state_of_world absent
curl -sk https://<node>:10250/metrics 2>/dev/null | \
  grep 'volume_manager_total_volumes{.*iscsi'
# → desired_state_of_world=N present, actual_state_of_world NOT emitted = stall confirmed
# → storage_operation_duration_seconds for kubernetes.io/iscsi also absent

# Step 4: Confirm node still reports volumesInUse (blocking ADC from reattaching)
kubectl --context pvek8s get node <node> -o jsonpath='{.status.volumesInUse}'
# → [...kubernetes.io/iscsi/...] — volumes listed even though no iSCSI sessions exist

# Step 5: Capture goroutine dump to confirm processorListener stall
ssh <node> "sudo kill -SIGUSR1 \$(pgrep -f 'snap.microk8s.daemon-kubelite')"
sleep 5
ssh <node> "sudo journalctl -u snap.microk8s.daemon-kubelite --since '1 minute ago' | \
  grep -c 'select, [0-9]*m'"
# → count > 0 confirms goroutines blocked in select for minutes
```

**ProcessorListener stall signature in goroutine dump:**
```
goroutine NNNNN [select, 33 minutes]:
k8s.io/client-go/tools/cache.(*processorListener).pop(...)
```

**WaitForAttachAndMount blocked goroutines:**
```
goroutine NNNNN [semacquire, 33 minutes]:
k8s.io/kubernetes/pkg/volume/util/operationexecutor.(*volumeToMount).WaitForAttachAndMount(...)
```

---

## Recovery

The processorListener stall cannot be resolved by restarting only kubelite on the stalled node, because the kine watch subscription state is corrupted — a fresh kubelite will immediately stall again on the same kine instance. The recommended fix bypasses the stall by rescheduling workloads to healthy nodes.

### Option A — Reschedule to a healthy node (preferred, no node restart required)

This is safe: iSCSI PVC data is preserved; pods restart cleanly on another node.

1. Clear stale volumesAttached and volumesInUse on the stalled node to unblock ADC:
   ```bash
   kubectl --context pvek8s patch node <node> --subresource=status --type=json \
     -p='[{"op":"replace","path":"/status/volumesAttached","value":[]},{"op":"replace","path":"/status/volumesInUse","value":[]}]'
   ```

2. Cordon the stalled node:
   ```bash
   kubectl --context pvek8s cordon <node>
   ```

3. Force-delete the stuck pods (they have no running containers, so grace period is irrelevant):
   ```bash
   kubectl --context pvek8s get pods -A --field-selector spec.nodeName=<node> -o name | \
     xargs kubectl --context pvek8s delete --force --grace-period=0
   # Or delete specific pods:
   kubectl --context pvek8s delete pod -n <namespace> <pod-name> --force --grace-period=0
   ```

4. Verify pods reschedule to a healthy node and iSCSI attaches:
   ```bash
   kubectl --context pvek8s get pods -n <namespace> -w
   # → pods should transition: Pending → ContainerCreating → Running within ~2 minutes
   ```

### Option B — Full kine+kubelite restart on the stalled node (clears the stall, schedule during maintenance)

Use this to fully rehabilitate the node after using Option A. Requires cordoning the node first (PGM-195/PGM-201 procedure).

1. Cordon the node if not already cordoned:
   ```bash
   kubectl --context pvek8s cordon <node>
   ```

2. Restart kine first (must precede kubelite):
   ```bash
   ssh <node> "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
   sleep 10
   ssh <node> "sudo systemctl is-active snap.microk8s.daemon-k8s-dqlite.service"
   # → active
   ```

3. Restart kubelite:
   ```bash
   ssh <node> "sudo systemctl restart snap.microk8s.daemon-kubelite.service"
   ```

4. Wait for node Ready:
   ```bash
   kubectl --context pvek8s wait node/<node> --for=condition=Ready --timeout=120s
   ```

5. Verify processorListeners are no longer stalled (goroutine dump should show no long-blocked selects):
   ```bash
   ssh <node> "sudo kill -SIGUSR1 \$(pgrep -f 'snap.microk8s.daemon-kubelite')"
   sleep 5
   ssh <node> "sudo journalctl -u snap.microk8s.daemon-kubelite --since '1 minute ago' | \
     grep 'select, [0-9]*m'"
   # → (empty — no goroutines blocked in select for minutes)
   ```

6. Uncordon and verify iSCSI attach works on rescheduled pods:
   ```bash
   kubectl --context pvek8s uncordon <node>
   ```

---

## Verification

```bash
# No ContainerCreating pods on the affected node
kubectl --context pvek8s get pods -A --field-selector spec.nodeName=<node> | grep ContainerCreating
# → (empty)

# volumesInUse cleared (or contains only legitimately attached volumes)
kubectl --context pvek8s get node <node> -o jsonpath='{.status.volumesInUse}'
# → [] (after Option A) or current attached volumes (after Option B)

# Rescheduled pods Running on healthy node
kubectl --context pvek8s get pods -n <namespace> -l <selector>
# → 1/1 Running, on k8s01 or k8s02

# iSCSI sessions active on the new node
ssh <new-node> "sudo iscsiadm -m session"
# → tcp: [...targetPortal...] (one session per iSCSI volume)
```

---

## References

- PIR: [pvek8s Post-Power-Outage Recovery — kubelet Volume Manager Stall and KCM Stale terminatingReplicas](../incidents/2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md)
- Linear: [PGM-216](https://linear.app/pgmac-net-au/issue/PGM-216)
- Related: [kubelet-silent-stall.md](kubelet-silent-stall.md) — Failure Mode 2 (pod watch goroutine stall, same kine root cause; pods stuck Pending instead of ContainerCreating)
- Related: [dqlite-write-contention.md](dqlite-write-contention.md) — kine restart safety procedure and ordering
- Related: [kcm-stale-terminating-replicas.md](kcm-stale-terminating-replicas.md) — often occurs alongside this failure (same kine disruption stalls KCM informer)
