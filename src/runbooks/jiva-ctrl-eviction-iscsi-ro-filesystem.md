---
tags:
  - runbook
  - microk8s
  - storage
  - openebs
  - jiva
  - iscsi
  - ro-filesystem
  - ext4
---

# Jiva-ctrl Eviction → iSCSI Session Drop → EXT4 Read-Only Filesystem

**Service:** OpenEBS Jiva iSCSI (pvek8s)
**First observed:** 2026-05-28
**PIR:** [pvek8s Post-Power-Outage Recovery — kubelet Volume Manager Stall and KCM Stale terminatingReplicas](../incidents/2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md)
**Linear:** [PGM-224](https://linear.app/pgmac-net-au/issue/PGM-224)

---

## Symptom

A pod running an OpenEBS Jiva-backed PVC enters a read-only or error state. The pod may:

- Log `Read-only file system` errors
- Enter `CrashLoopBackOff` or `Error` state
- Become stuck in `Failed` or `Terminating` on a cordoned node (jiva-csi cannot run `chmod` during teardown because the filesystem is read-only)

In dmesg on the node running the pod:
```
EXT4-fs (sdX): Remounting filesystem read-only
```

This is distinct from the [kubelet-volume-manager-stall](kubelet-volume-manager-stall.md) scenario (where pods are stuck in `ContainerCreating` and iSCSI never attached). Here, iSCSI **was** attached and the pod **was** running — then lost its storage mid-flight.

---

## Root Cause

The jiva-ctrl pod (iSCSI target) running on some node was evicted or killed while an iSCSI initiator on another node had an active session to it.

**Full cascade:**

1. A node hosting jiva-ctrl pod(s) receives a `NoExecute` taint (NotReady, maintenance, or recovery rolling restart)
2. The taint-eviction-controller deletes the jiva-ctrl pods — the iSCSI target process exits
3. The iSCSI initiator on the workload node detects `conn error (1020)` (TCP RST or connection refused)
4. iSCSI session recovery runs for 120 seconds — if the target does not reappear, the session is declared dead
5. The kernel marks the SCSI block device offline; in-flight I/O returns `-EIO`
6. JBD2 (ext4 journal) aborts on the first failed write, setting `JBD2_ABORT` flag
7. EXT4 detects the aborted journal on the next write attempt and remounts the filesystem read-only

**Batched eviction amplifier**: During cluster recovery, if the kube-controller-manager was temporarily disconnected from dqlite, pending taint evictions queue up. On reconnect, all queued jiva-ctrl pods are evicted simultaneously — dropping all iSCSI sessions at once, leaving no time for individual session recovery.

**Earlier link-flap comparison**: A brief physical network event (eth0 down <30s) will also trigger error 1020, but the sessions recover once connectivity returns because the iSCSI target is still alive. The critical difference here is that the **target process itself** was killed.

---

## Detection

### Step 1: Confirm filesystem is read-only on the affected pod

```bash
# Check pod events
kubectl describe pod <pod-name> -n <namespace> | grep -iE 'read.only|error|io error'

# Check pod logs for ro filesystem errors
kubectl logs <pod-name> -n <namespace> | grep -iE 'read.only file system|EROFS|I/O error'
```

### Step 2: Confirm EXT4 ro remount in node dmesg

Find which node the pod is (or was) on, then check dmesg:

```bash
NODE=$(kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.spec.nodeName}')

# Via the jiva-csi-node DaemonSet pod on that node
JIVA_POD=$(kubectl get pods -n openebs -l app=openebs-jiva-csi-node \
  -o jsonpath="{.items[?(@.spec.nodeName=='$NODE')].metadata.name}")

kubectl exec -n openebs $JIVA_POD -c jiva-csi-plugin -- dmesg | \
  grep -E 'EXT4.*Remounting|conn error|session recovery timed out|I/O error.*sd[a-z]|Aborting journal'
```

Key signatures:
```
iscsid: connection1:0: detected conn error (1020)
iscsid: session1: session recovery timed out after 120 secs
EXT4-fs (sdX): Remounting filesystem read-only
```

### Step 3: Identify the affected PVC and jiva-ctrl ClusterIP

```bash
# Get the PVC name from the pod spec
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}'

# Get the jiva-ctrl service ClusterIP (this is what iSCSI connects to)
PVC_NAME=<pvc-name>
PV_NAME=$(kubectl get pvc $PVC_NAME -n <namespace> -o jsonpath='{.spec.volumeName}')
kubectl get svc -n openebs | grep "${PV_NAME:0:25}"
```

### Step 4: Check JivaVolume CR state

```bash
kubectl get jivavolume -n openebs | grep "<pvc-partial-name>"
kubectl get jivavolume <pvc-name> -n openebs -o jsonpath='{.spec.mountInfo}'
# Stale if nodeID does not match the node you're trying to mount on
```

---

## Recovery

### Phase 1: Assess and stabilise

1. Determine whether the affected node is cordoned:
   ```bash
   kubectl get node <node> -o jsonpath='{.spec.unschedulable}'
   # → "true" = cordoned
   ```

2. If the node is **not** cordoned and the pod might recover, check whether the jiva-ctrl has restarted and the iSCSI session can re-establish:
   ```bash
   # Check jiva-ctrl pod status
   kubectl get pods -n openebs | grep "<pvc-partial-name>.*ctrl"

   # Check iSCSI session state on the affected node
   kubectl exec -n openebs $JIVA_POD -c jiva-csi-plugin -- iscsiadm -m session
   ```
   If the session is re-established and the filesystem is still ro, proceed to Phase 2.
   If the jiva-ctrl is running but the session is absent, the 120s timeout already expired — proceed to Phase 2.

### Phase 2: Unstick the pod if stuck in Failed/Terminating

A pod on a read-only filesystem will not complete deletion because jiva-csi cannot `chmod` the mount directory. The deletion finalizer is never cleared.

1. Unmount the stale CSI mounts from inside the jiva-csi-node container on the affected node:
   ```bash
   # Get the pod UID
   POD_UID=$(kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.metadata.uid}')
   PVC_NAME=<pvc-name>

   # Unmount pod volume bind mount
   kubectl exec -n openebs $JIVA_POD -c jiva-csi-plugin -- \
     umount /var/snap/microk8s/common/var/lib/kubelet/pods/${POD_UID}/volumes/kubernetes.io~csi/${PVC_NAME}/mount

   # Unmount CSI globalmount (staging)
   # Get the vol-id from the path
   VOL_ID=$(kubectl exec -n openebs $JIVA_POD -c jiva-csi-plugin -- \
     sh -c 'ls /var/snap/microk8s/common/var/lib/kubelet/plugins/jiva.csi.openebs.io/')
   kubectl exec -n openebs $JIVA_POD -c jiva-csi-plugin -- \
     umount /var/snap/microk8s/common/var/lib/kubelet/plugins/jiva.csi.openebs.io/${VOL_ID}/globalmount
   ```

2. Delete the stuck pod (now that mounts are clear, the finalizer can complete):
   ```bash
   kubectl delete pod <pod-name> -n <namespace>
   ```

### Phase 3: Log out stale iSCSI session from old node

If the pod was on node A and you want to reschedule to node B, node A's iSCSI initiator may still have the session registered (even if the session is dead). This will cause "already mounted at more than one place" errors on node B.

```bash
# Get jiva-ctrl IQN and portal IP
IQN="iqn.2016-09.com.openebs.jiva:<pvc-name>"
PORTAL_IP=$(kubectl get svc -n openebs -o jsonpath="{.items[?(@.metadata.name contains '<pvc-partial-name>')].spec.clusterIP}")

# Log out from old node via jiva-csi-node container
kubectl exec -n openebs $JIVA_POD -c jiva-csi-plugin -- \
  iscsiadm -m node -T $IQN -p ${PORTAL_IP}:3260 --logout

# Verify session is gone
kubectl exec -n openebs $JIVA_POD -c jiva-csi-plugin -- iscsiadm -m session
```

### Phase 4: Clear stale JivaVolume CR mountInfo

If the JivaVolume CR still has `spec.mountInfo` from the old node, jiva-csi on the new node will refuse to mount, reporting "already mounted":

```bash
kubectl patch jivavolume <pvc-name> -n openebs --type=merge \
  -p '{"spec":{"mountInfo":{"devicePath":"","stagingPath":""}}}'
```

**Note:** jiva-operator may repopulate this field quickly during active NodeStageVolume attempts. If the new pod is already trying to mount, the patch may be overwritten. If so:
1. Cordon the new node first to stop scheduling
2. Apply the patch
3. Uncordon to allow the pod to reschedule to a clean node

### Phase 5: Reschedule the pod to a healthy node

If the original node is cordoned, the pod will not reschedule automatically (for StatefulSets in particular). Force-delete the pod after Phases 2–4 are complete:

```bash
kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0
```

The StatefulSet controller will recreate the pod. It will schedule to a node where jiva-csi can successfully login iSCSI and mount the volume rw.

### Phase 6: Verify

```bash
# Pod is Running with rw filesystem
kubectl get pod <pod-name> -n <namespace>
# → 1/1 Running

# Verify mount is rw on the new node
NEW_NODE=$(kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.spec.nodeName}')
NEW_JIVA_POD=$(kubectl get pods -n openebs -l app=openebs-jiva-csi-node \
  -o jsonpath="{.items[?(@.spec.nodeName=='$NEW_NODE')].metadata.name}")
kubectl exec -n openebs $NEW_JIVA_POD -c jiva-csi-plugin -- \
  grep "<pvc-name>" /proc/mounts
# Should show rw (not ro) in the mount options

# iSCSI session active on new node
kubectl exec -n openebs $NEW_JIVA_POD -c jiva-csi-plugin -- iscsiadm -m session
# → tcp: [...] iqn.2016-09.com.openebs.jiva:<pvc-name> (non-flash)

# No stale iSCSI sessions on old node
kubectl exec -n openebs $OLD_JIVA_POD -c jiva-csi-plugin -- iscsiadm -m session
# → (empty or no matching session)
```

---

## Prevention

### During cluster recovery / rolling node restarts

Before applying a `NoExecute` taint to or draining a node:

1. **Identify jiva-ctrl pods on that node:**
   ```bash
   kubectl get pods -n openebs -o wide | grep "<node-name>" | grep "ctrl"
   ```

2. **For each jiva-ctrl pod, find which nodes have active iSCSI sessions to it:**
   ```bash
   # Get the controller service ClusterIP
   kubectl get svc -n openebs | grep "<pvc-partial>"

   # Check all jiva-csi-node containers for active sessions to that ClusterIP
   for pod in $(kubectl get pods -n openebs -l app=openebs-jiva-csi-node -o name); do
     echo "=== $pod ==="; \
     kubectl exec -n openebs $pod -c jiva-csi-plugin -- \
       iscsiadm -m session 2>/dev/null | grep "<clusterIP>"
   done
   ```

3. **If sessions exist on other nodes:** First delete the workload pods that use those PVCs, allow them to reschedule to a node NOT hosting the jiva-ctrl, and verify iSCSI re-attaches to a different controller. Then proceed with the node restart.

4. **If no sessions exist:** Safe to proceed directly.

See [PGM-223](https://linear.app/pgmac-net-au/issue/PGM-223) for the full rolling restart runbook (to be written).

### Structural mitigations (not yet implemented)

- **Extended NoExecute toleration** on jiva-ctrl pods (`tolerationSeconds=600`) — gives more time for transient NotReady to resolve before eviction fires. Tracked: [PGM-222](https://linear.app/pgmac-net-au/issue/PGM-222).
- **iSCSI session recovery timeout** — increase `node.session.timeo.replacement_timeout` from 120s to 300s+ to give jiva-ctrl pods more time to restart and re-register. Configure via iscsiadm on each node or in the jiva-csi DaemonSet.
- **Monitoring** — log-based alerts on EXT4 ro remount and iSCSI session failure patterns in kern.log. Tracked: [PGM-221](https://linear.app/pgmac-net-au/issue/PGM-221).

---

## References

- PIR: [pvek8s Post-Power-Outage Recovery — kubelet Volume Manager Stall and KCM Stale terminatingReplicas](../incidents/2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md) — Chain 4
- Linear: [PGM-224](https://linear.app/pgmac-net-au/issue/PGM-224) — this runbook
- Linear: [PGM-221](https://linear.app/pgmac-net-au/issue/PGM-221) — log-based alerts (planned)
- Linear: [PGM-222](https://linear.app/pgmac-net-au/issue/PGM-222) — extended jiva-ctrl tolerations (planned)
- Linear: [PGM-223](https://linear.app/pgmac-net-au/issue/PGM-223) — rolling restart runbook for jiva-ctrl nodes (planned)
- Related: [jiva-csi-mount-proliferation.md](jiva-csi-mount-proliferation.md) — duplicate CSI mounts from kubelite restarts (separate but related failure mode affecting same jiva-csi-node DaemonSet)
- Related: [kubelet-volume-manager-stall.md](kubelet-volume-manager-stall.md) — iSCSI attach failure where pods are stuck ContainerCreating (vs this runbook: pod was already Running then lost storage)
- Related: [dqlite-write-contention.md](dqlite-write-contention.md) — KCM dqlite reconnect behaviour that causes batched evictions
- Script: [pvek8s-outage-recovery.sh](pvek8s-outage-recovery.sh) — full post-outage cluster recovery; phases 4 and 6 include jiva-ctrl pre-check before restarting nodes
