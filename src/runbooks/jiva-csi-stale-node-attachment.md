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

| | **Mode 1 — Single pod rescheduled** | **Mode 2 — Multi-node reboot** | **Mode 3 — NodeUnpublish false success** |
| --- | --- | --- | --- |
| **Trigger** | A pod is force-deleted (`--force --grace-period=0`), or its container vanishes from containerd before graceful shutdown, and the replacement lands on a different node | All cluster nodes are rebooted and returned to `Ready` (e.g. after a [frozen-init recovery](systemd-pid1-frozen-init.md)) | An ordinary rolling update. The driver returns success from `NodeUnpublishVolume` without unmounting — nobody did anything wrong |
| **Scale** | One volume | Every volume whose pod moved — nine in the 2026-09-03 incident | One volume |
| **Old node state** | Usually still `Ready`, with live mounts and an iSCSI session | Rebooted: no mounts, no sessions, no staging dirs — nothing to clean up | `Ready`, with exactly one orphan pod-dir bind mount, a live iSCSI session, and a pod stuck `Terminating` (usually *displaying* `Completed`) |
| **Why the guard fires** | Genuine leftover attachment on the old node | Nothing is attached anywhere; restoring the old node to `Ready` re-armed a guard against a mount that no longer exists | Genuine leftover mount, but only because `UnmountDevice` is still looping — kubelet has not given up and will finish the job once the mount is gone |
| **Recovery** | Full cleanup — [Steps 1–6](#recovery) below | Clear the stale labels only — [Failure Mode 2](#failure-mode-2--multi-node-reboot) below | **One `umount`, nothing else** — [Failure Mode 3](#failure-mode-3--nodeunpublish-false-success) below. Auto-remediated since 2026-09-12 |
| **First observed** | 2026-06-17 | 2026-09-03 | 2026-08-27 |

> **Do not run Mode 1's cleanup for a Mode 2 event.** After a reboot there are no mounts or sessions to unwind, and the CSI node pod is already a fresh process. Only the CRD label is stale.

> **Do not run Mode 1's cleanup for a Mode 3 event either.** Steps 4 and 6 — clearing the CRD and force-deleting the pod — are actively harmful here. Kubelet is mid-teardown and retrying every 2m2s. Remove the one mount blocking it and it completes the whole chain itself.

---

## Root Cause

The Jiva CSI driver tracks which node has a volume staged via three mechanisms in the `JivaVolume` CRD:

1. **`metadata.labels.nodeID`** — the node that currently holds the volume. This is the primary guard: `NodeStageVolume` is rejected if `nodeID` is set to a different node than the one calling.
2. **`spec.mountInfo`** — staging path, filesystem type, and device path from the previous node. Populated when staging succeeds; cleared when `NodeUnstageVolume` completes.
3. **Active iSCSI session** on the previous node — the iSCSI target tracks connected initiators.

Under normal pod termination, the kubelet calls `NodeUnpublishVolume` → `NodeUnstageVolume`, which clears all three. After a force-delete, none of these cleanup calls happen — all three remain set for the previous node.

**Mode 3 reaches the same end state without anyone force-deleting anything.** The driver's `NodeUnpublishVolume` logs `Unmounting: <pod-dir path>` and returns success while leaving the bind mount in place. Kubelet believes the unpublish worked and proceeds to `UnmountDevice`, which refuses because the device is still referenced:

```
Error: GetDeviceMountRefs check failed for volume "pvc-<id>" on node "<node>" :
the device mount path ".../globalmount" is still mounted by other references
[.../pods/<uid>/volumes/kubernetes.io~csi/pvc-<id>/mount]
```

`UnmountDevice` never completes, so `NodeUnstageVolume` is never called, so all three mechanisms stay set — exactly as if cleanup had been skipped. The difference that matters for recovery: kubelet is still retrying, every 2m2s, indefinitely. It is not stuck because it gave up; it is stuck because one mount is in its way.

This has happened twice in 16 days on this cluster (2026-08-27, 2026-09-12) against `openebs/jiva-csi:3.6.0`, both times during an ordinary rolling update. Upstream status is tracked in [homelabia#183](https://github.com/pgmac-net/homelabia/issues/183).

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

## Failure Mode 3 — NodeUnpublish false success

### When it occurs

During an ordinary rolling update, with no force-delete and nothing unusual about the shutdown. Observed 2026-08-27 ([homelabia#168](https://github.com/pgmac-net/homelabia/issues/168), StatefulSet) and 2026-09-12 ([homelabia#181](https://github.com/pgmac-net/homelabia/issues/181), Deployment, 3h08m of downtime).

The two variants look different from the outside, which is why the second one was not recognised as a repeat:

- **Deployment** — the replacement pod is created and sits in `ContainerCreating`, emitting `FailedMount` every 2 minutes. This is visible to `MicroK8s Assigned Pending Pods`, which alerted within 13 minutes on 2026-09-12.
- **StatefulSet** with `podManagementPolicy: OrderedReady` — the replacement is never created at all, because the old pod has not finished terminating. Nothing is Pending, so nothing counted it. Completely silent before this runbook's automation existed.

### Detection

Automated, since 2026-09-12: **`microk8s-jiva-unpublish-wedge`**, per node.

- **WARNING** — an orphan pod-dir bind mount has been on that node for over 10 minutes (its pod is gone or carries a `deletionTimestamp`), or a pod on that node was refused `NodeStage` with `already mounted at more than one place`.
- **CRITICAL** — still wedged after 30 minutes. Remediation ran and did not clear it. **A human is needed** — the event handler deliberately does not fire on CRITICAL.

The check never keys on the string `Terminating`. In both incidents the stuck pod displayed as `Completed`: its container exited 0 on SIGTERM, so the phase is `Succeeded` while `deletionTimestamp` is set. Anything grepping `kubectl get pods` output for `Terminating` will miss this failure entirely.

By hand:

```bash
# the orphan mount, on the node that holds it
grep -E '/pods/[0-9a-f-]+/volumes/kubernetes\.io~csi/.*/mount$' /proc/mounts

# is its pod actually gone or terminating?
kubectl --context pvek8s get pods -A -o json \
  | jq -r --arg uid "<uid-from-the-path>" \
    '.items[] | select(.metadata.uid == $uid)
     | "\(.metadata.namespace)/\(.metadata.name) phase=\(.status.phase) deleting=\(.metadata.deletionTimestamp // "no")"'

# kubelet still retrying, every 2m2s
journalctl -u snap.microk8s.daemon-kubelite.service --since '-10 min' | grep GetDeviceMountRefs
```

> **The node named in the `already mounted` error is not necessarily the node holding the mount.** On 2026-09-12 the node in the error had zero mounts and zero iSCSI sessions for that PV — the claim came entirely from `JivaVolume.spec.mountInfo`. Check the CR, then the node the CR names.

### Auto-remediation

On HARD WARNING the event handler runs `event_jiva_unpublish_remediate.sh` on the affected node via NRPE, which launches `remediate_jiva_unpublish.sh` detached as a transient systemd unit.

```bash
journalctl -u jiva-unpublish-remediate     # what it did, on the node
```

Guards, all before any unmount: the orphan mount is re-confirmed, kubelite must have been up at least 120s, per-PV (1h) and per-node (3/hour) rate limits apply, and immediately before each `umount` the pod UID is re-verified as gone-or-terminating against the API and `fuser -m` must show nothing holding the filesystem. It then waits up to 6 minutes for the pod object to disappear and reports SUCCESS or FAILED to Slack.

Outcomes other than SUCCESS:

| Journal line | Meaning | What to do |
| --- | --- | --- |
| `FALSE ALARM` | No orphan mount by the time it ran | Nothing. It cleared itself. |
| `DEFERRED` | kubelite not stable | Nothing yet. Check why kubelite is restarting. |
| `REFUSED` | Rate limit hit, or kubectl unavailable, or every candidate failed a guard | Read the journal for which guard. A per-PV refusal means the same volume wedged twice inside an hour — go manual. |
| `FAILED` | The umount did not clear it, or the pod is still present after 6 minutes | Follow the manual recovery below. Do **not** force-delete. |

`microk8s-jiva-unpublish-remediation-health` reports CRITICAL if the transient unit is left in `failed` state or the handler could not launch it at all.

### Recovery

One command, on the node holding the orphan mount:

```bash
sudo umount /var/snap/microk8s/common/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~csi/<pv>/mount
```

Plain `umount`. **Never `-f`, never `-l`** — a lazy unmount hides the reference from kubelet without releasing it, which leaves the wedge in place and removes the evidence.

Then wait. Kubelet's next `UnmountDevice` retry is within 2m2s and cascades everything else on its own: `globalmount` cleared, `NodeUnstageVolume` runs, iSCSI session logged out, `JivaVolume` `mountInfo` rewritten, and the waiting pod stages on its new node. Measured on 2026-09-12: old pod gone and replacement `1/1 Running` about 3 minutes later. Measured again in a controlled repro: the CR cleared itself 30–60s after the pod object went, and the replacement recovered with no CR patch at all.

**Do not**, in this mode:

- **Force-delete the stuck pod** (Step 6 of Mode 1). It drops kubelet's mount reference while the mount is still live, which is how the same ext4 filesystem ends up mounted twice.
- **Clear `JivaVolume.spec.mountInfo`** (Step 4 of Mode 1). Same outcome, same corruption. It clears itself once the unmount lets `NodeUnstage` run. If a case genuinely needs the CR touched, that is a human decision made with evidence from every node, never an automated one.
- **Restart the CSI node pod** (Step 5 of Mode 1). It changes nothing — the stale mount is in the host mount namespace, not in the driver's process.

### Verification

```bash
# on the node that held it: no mounts, no session
grep -c <pv> /proc/mounts
sudo iscsiadm -m session | grep -c <pv>

# the CR should now point at the new node, with mountInfo repopulated there
kubectl --context pvek8s get jivavolume -n openebs <pv> \
  -o jsonpath='{.metadata.labels.nodeID}{"  "}{.spec.mountInfo.stagingPath}{"\n"}'

# and the workload
kubectl --context pvek8s get pods -n <namespace> -o wide
```

---

## References

- PIR: [seerr Jiva CSI Stale Node Attachment](../incidents/2026-06-17-seerr-jiva-csi-stale-node-attachment.md) — Failure Mode 1
- PIR: [pvek8s Total Control Plane Loss — systemd +esm4 PID 1 Segfault](../incidents/2026-09-02-systemd-esm4-pid1-segfault-control-plane-loss.md) — Failure Mode 2
- Related: [systemd-pid1-frozen-init.md](systemd-pid1-frozen-init.md) — the recovery that triggers Failure Mode 2
- Related: [jiva-volume-ext4-corruption.md](jiva-volume-ext4-corruption.md) — what to check when clearing the label is not enough
- Linear: [PGM-254](https://linear.app/pgmac-net-au/issue/PGM-254) — runbook creation ticket
- Related: [jiva-csi-mount-proliferation.md](jiva-csi-mount-proliferation.md) — same CSI infrastructure, different failure mode (duplicate mounts from kubelite restarts, same node)
- Related: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md) — iSCSI session drop from jiva-ctrl eviction
- [homelabia#168](https://github.com/pgmac-net/homelabia/issues/168) — Failure Mode 3, first occurrence (StatefulSet, silent)
- [homelabia#181](https://github.com/pgmac-net/homelabia/issues/181) — Failure Mode 3, second occurrence and the detection plus auto-remediation above
- [homelabia#183](https://github.com/pgmac-net/homelabia/issues/183) — upstream tracking for the `NodeUnpublishVolume` false success
- [homelabia#182](https://github.com/pgmac-net/homelabia/issues/182) — `check-jiva-volumes.py`, the manual fallback when the automation cannot fix it
