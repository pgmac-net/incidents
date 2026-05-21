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

As of 2026-05-21, only one PVC uses the CSI storage class:

| PVC | Namespace | Pod |
|-----|-----------|-----|
| `seerr-seerr-chart-config` (`pvc-746b2837`) | `media` | `seerr-seerr-chart-0` (k8s02) |

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

## Remediation

The cleanup is non-disruptive — the workload pod continues running throughout.

The original active mount (added when the pod first started) sits at the bottom of the stack; `umount` removes from the top, so a single call clears the entire stale stack through kernel shared-namespace propagation.

```bash
# Identify paths to clean
ssh <node> "grep 'jiva.csi.openebs.io' /proc/mounts | awk '{print \$2}' | grep globalmount | sort -u"
# This gives you the GLOBAL_PATH value(s) needed below.

# Find the corresponding pod volume mount path
ssh <node> "grep '<vol-id>' /proc/mounts | awk '{print \$2}' | grep -v globalmount | sort -u"
# This gives you the POD_PATH value(s) needed below.

# Run cleanup on the affected node as root
ssh <node> 'sudo bash -s' << 'EOF'
POD_PATH="<full pod volume mount path>"
GLOBAL_PATH="<full globalmount path>"

echo "Before: pod=$(grep -c "$POD_PATH" /proc/mounts) global=$(grep -c "$GLOBAL_PATH" /proc/mounts)"

COUNT=$(grep -c "$POD_PATH" /proc/mounts)
while [ "$COUNT" -gt 1 ]; do
    umount "$POD_PATH" 2>/dev/null
    COUNT=$(grep -c "$POD_PATH" /proc/mounts)
done

COUNT=$(grep -c "$GLOBAL_PATH" /proc/mounts)
while [ "$COUNT" -gt 1 ]; do
    umount "$GLOBAL_PATH" 2>/dev/null
    COUNT=$(grep -c "$GLOBAL_PATH" /proc/mounts)
done

echo "After: pod=$(grep -c "$POD_PATH" /proc/mounts) global=$(grep -c "$GLOBAL_PATH" /proc/mounts) total=$(wc -l < /proc/mounts)"
EOF
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
- [PGM-195](https://linear.app/pgmac-net-au/issue/PGM-195), [PGM-201](https://linear.app/pgmac-net-au/issue/PGM-201) — kubelite restart incidents that caused accumulation
- [Kubelet Silent Stall runbook](kubelet-silent-stall.md) — related kubelite restart procedures
