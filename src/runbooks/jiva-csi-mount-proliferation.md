---
tags:
  - runbook
  - microk8s
  - storage
  - openebs
---

# Jiva CSI Mount Proliferation

**Service:** openebs-jiva-csi (pvek8s)
**Nagios check:** `microk8s-jiva-csi-mounts`
**First observed:** 2026-05-21
**Linear:** [PGM-203](https://linear.app/pgmac-net-au/issue/PGM-203)

---

## Symptom

Nagios fires `WARNING` or `CRITICAL` on `microk8s-jiva-csi-mounts` for a k8s node.

The alert message identifies the affected volume and duplicate count:

```
WARNING - Jiva CSI mount duplication: 82405009:x14
CRITICAL - Jiva CSI mount proliferation: 82405009:x68
```

Secondary symptom that may appear before the Nagios alert fires: Ansible `gather_facts` times out on the affected node with:

```
[WARNING]: Timeout exceeded when getting mount info for
  .../jiva.csi.openebs.io/<vol-id>/globalmount
[WARNING]: Timeout exceeded when getting mount info for
  .../pods/<pod-uid>/volumes/kubernetes.io~csi/<pvc>/mount
```

---

## Root Cause

The Jiva CSI `NodePublishVolume` call is not idempotent. Each time kubelite restarts, the kubelet re-calls `NodeStageVolume` + `NodePublishVolume` for every CSI-backed pod already scheduled to the node. The Jiva node plugin correctly detects the globalmount already exists and skips re-staging, but still performs the pod volume bind mount unconditionally.

Over many kubelite restart cycles (e.g. during dqlite storms or PLEG incidents), duplicate bind mounts accumulate at:

- `.../jiva.csi.openebs.io/<vol-id>/globalmount`
- `.../pods/<pod-uid>/volumes/kubernetes.io~csi/<pvc>/mount`

At 2048+ duplicates, `findmnt` scanning `/proc/mounts` hangs, causing Ansible fact collection to time out.

---

## Affected volumes

Only volumes using `openebs-jiva-csi-default` storage class (provisioner: `jiva.csi.openebs.io`) are affected.
Volumes using the older `openebs-jiva-default` (provisioner: `openebs.io/provisioner-iscsi`) are **not** affected.

As of 2026-06-28, the following PVCs use the CSI storage class:

| PVC | Namespace | Pod |
|-----|-----------|-----|
| `seerr-seerr-chart-config` (`pvc-746b2837`) | `media` | `seerr-seerr-chart-0` |
| coder workspace home (`pvc-8eccb718`) | `coder` | coder workspace pod |

---

## Detection

```bash
# 1. Check current duplicate count
ssh <node> "grep 'jiva.csi.openebs.io' /proc/mounts | awk '{print \$2}' | grep globalmount | sort | uniq -c | sort -rn"

# 2. Check total mount table size (>1000 is problematic)
ssh <node> "wc -l /proc/mounts"

# 3. Identify which pod owns the affected PVC
kubectl --context pvek8s get pods -A -o wide | grep <node>
```

A healthy node shows exactly 1 occurrence per Jiva CSI volume.

---

## Auto-remediation

Since 2026-07-16 ([homelabia#146](https://github.com/pgmac-net/homelabia/issues/146)) this failure mode self-heals: a Nagios event handler on `microk8s-jiva-csi-mounts` HARD WARNING/CRITICAL fires an NRPE trigger on the affected node, which launches `remediate_jiva_csi_mounts.sh` detached under systemd (`journalctl -u jiva-mounts-remediate`). The script runs the umount loop below for every duplicated volume, with guards:

- **Re-confirmation** — no duplicated mounts = FALSE ALARM, no action
- **Kubelite stability** — waits until kubelite has been active ≥10min (polls up to 15min); unmounting while the kubelet is re-running `NodePublishVolume` is the overshoot scenario
- **Rate limit** — refuses to run twice within 1h; rapid recurrence means kubelite is crash-looping and needs a human
- **Overshoot abort** — if any umount drops a count to 0, it stops ALL cleanup, logs ERROR, and exits failed. The recovery path (iSCSI logout + JivaVolume patch + pod delete, below) is deliberately human-only

**Before intervening manually, check the auto-remediation first:**

```bash
ssh <node> "journalctl -u jiva-mounts-remediate --since '1 hour ago'"
```

- `SUCCESS` — done; wait for the next Nagios poll
- `DEFERRED` / `REFUSED` — the guard explains why; note the trigger only re-fires on a Nagios state *change*, so after fixing the underlying cause either wait for WARNING→CRITICAL escalation or run the cleanup manually
- `ERROR: OVERSHOOT` / `FAILED` — live mount lost; go straight to **If live mount was accidentally removed** below
- Empty journal — delivery failed; check `microk8s-jiva-mounts-remediation-health` and `journalctl -t jiva-mounts-trigger`, then remediate manually

`microk8s-jiva-mounts-remediation-health` pages when the delivery path itself is broken (lingering failed `jiva-mounts-remediate` unit, or launch failures in the last 30min). Both checks CRITICAL together = it will NOT self-heal, go manual.

---

## Manual remediation

!!! warning "Overshoot risk: cleanup can remove the live mount"
    The loop below stops when `/proc/mounts` count reaches 1. This assumes the count
    decrements one-by-one. **It does not always.** When the stacked mounts form a
    parent-child kernel hierarchy, a single `umount` can collapse many `/proc/mounts`
    entries at once — dropping the count past 1 directly to 0. When that happens the
    live mount is removed and the pod immediately loses filesystem access.

    The loop below detects this and prints a warning. If you see `DANGER: live mount
    removed`, stop immediately and follow the **If live mount removed** section below.

Identify paths to clean:

```bash
# Globalmount paths (one per PVC)
ssh <node> "grep 'jiva.csi.openebs.io' /proc/mounts | awk '{print \$2}' | grep globalmount | sort -u"

# Pod volume mount paths (one per PVC)
ssh <node> "grep '<vol-id>' /proc/mounts | awk '{print \$2}' | grep -v globalmount | sort -u"
```

Run cleanup on the affected node as root:

```bash
ssh <node> 'sudo bash -s' << 'EOF'
POD_PATH="<full pod volume mount path>"
GLOBAL_PATH="<full globalmount path>"

echo "Before: pod=$(grep -c "$POD_PATH" /proc/mounts) global=$(grep -c "$GLOBAL_PATH" /proc/mounts)"

COUNT=$(grep -c "$POD_PATH" /proc/mounts)
while [ "$COUNT" -gt 1 ]; do
    umount "$POD_PATH" 2>/dev/null || true
    NEW=$(grep -c "$POD_PATH" /proc/mounts)
    if [ "$NEW" -eq 0 ]; then
        echo "DANGER: live mount removed (count $COUNT → 0). Pod volume lost. Run recovery."
        break
    fi
    COUNT=$NEW
done

COUNT=$(grep -c "$GLOBAL_PATH" /proc/mounts)
while [ "$COUNT" -gt 1 ]; do
    umount "$GLOBAL_PATH" 2>/dev/null || true
    NEW=$(grep -c "$GLOBAL_PATH" /proc/mounts)
    if [ "$NEW" -eq 0 ]; then
        echo "DANGER: live globalmount removed (count $COUNT → 0). Run recovery."
        break
    fi
    COUNT=$NEW
done

echo "After: pod=$(grep -c "$POD_PATH" /proc/mounts) global=$(grep -c "$GLOBAL_PATH" /proc/mounts) total=$(wc -l < /proc/mounts)"
EOF
```

When the loop terminates normally (count reaches 1), cleanup is complete and the pod continues running.

---

## If live mount was accidentally removed

This happens when the count jumps from >1 to 0, meaning the live kernel mount was removed along with the stale duplicates. The pod's volume becomes inaccessible but the pod itself keeps running (it will error when it next tries to write or read the volume).

**Recovery requires three steps:**

### 1 — Log out the iSCSI session on the old node

The PVC's iSCSI session is still attached to the node where cleanup ran. The volume cannot attach elsewhere until this is cleared:

```bash
# Find the iSCSI target for the PVC
ssh <old-node> "sudo iscsiadm -m session"
# Output: tcp: [<N>] <target-portal>:3260,1 <iqn>

# Log out
ssh <old-node> "sudo iscsiadm -m node -T <iqn> -p <portal> --logout"
```

### 2 — Patch the JivaVolume CR to clear stale node attachment

```bash
# Find the JivaVolume for the PVC
kubectl --context pvek8s get jivavolume -n openebs

# Patch to clear mountInfo and nodeID
kubectl --context pvek8s patch jivavolume <pvc-name> -n openebs \
  --type=json \
  -p '[
    {"op":"remove","path":"/spec/mountInfo"},
    {"op":"remove","path":"/metadata/labels/nodeID"}
  ]'
```

If the `remove` op fails because the field doesn't exist, that field is already clear — skip it.

### 3 — Restart the pod to trigger CSI re-attachment

```bash
kubectl --context pvek8s -n <namespace> delete pod <pod-name>
```

The pod will reschedule (possibly to a different node). The Jiva CSI node plugin will call `NodeStageVolume` + `NodePublishVolume` on the new node, establishing a fresh iSCSI session and clean globalmount.

Verify:

```bash
# Pod running on new node
kubectl --context pvek8s -n <namespace> get pod <pod-name> -o wide

# Exactly 1 globalmount on new node (not the old one)
ssh <new-node> "grep 'jiva.csi.openebs.io' /proc/mounts | grep <vol-id>"

# No residual iSCSI session on old node
ssh <old-node> "sudo iscsiadm -m session | grep <iqn> || echo clean"
```

---

## Verification

```bash
# Confirm exactly 2 /dev/sd* entries for the PVC (globalmount + pod bind)
ssh <node> "grep 'jiva.csi.openebs.io' /proc/mounts"

# Confirm pod is still healthy
kubectl --context pvek8s -n <namespace> get pod <pod-name>
kubectl --context pvek8s -n <namespace> logs <pod-name> --tail=10

# Confirm Nagios check now returns OK
ssh <node> "sudo /etc/nagios/check_jiva_csi_mounts.sh"
```

---

## Recurrence

This recurs each time kubelite restarts on the node while a Jiva CSI pod is scheduled there. The dqlite lock error situation makes kubelite restarts plausible. Monitor the `microk8s-jiva-csi-mounts` check — a WARNING at 10+ duplicates gives time to remediate well before Ansible or other tooling is affected.

---

## References

- [PGM-203](https://linear.app/pgmac-net-au/issue/PGM-203) — incident and fix
- [homelabia#146](https://github.com/pgmac-net/homelabia/issues/146) — auto-remediation via Nagios event handler (2026-07-16)
- [PGM-195](https://linear.app/pgmac-net-au/issue/PGM-195), [PGM-201](https://linear.app/pgmac-net-au/issue/PGM-201) — kubelite restart incidents that caused accumulation
- PIR: [pvek8s dqlite WAL Lock Storm — Jiva Controller Endpoint Deadlock](../incidents/2026-06-28-dqlite-lock-storm-jiva-endpoint-deadlock.md) — incident where overshoot removed live seerr mount; iSCSI logout + JivaVolume patch recovery documented here
- [Jiva CSI Stale Node Attachment runbook](jiva-csi-stale-node-attachment.md) — the "If live mount removed" recovery above produces the same stale attachment state
- [Kubelet Silent Stall runbook](kubelet-silent-stall.md) — related kubelite restart procedures
- [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md) — related failure mode: jiva-ctrl pod eviction causes iSCSI session drop and EXT4 read-only remount; both failure modes affect the same jiva-csi-node DaemonSet infrastructure
