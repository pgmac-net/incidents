---
tags:
  - k8s01
  - calico
  - openebs
  - containerd
  - kubelet
  - networking
  - storage
---

# Post Incident Review: k8s01 Calico CNI Unauthorized — Stale Pod-Bound Token After Calico Upgrade

**Date:** 2026-05-23
**Duration:** ~1h active (~12:01 AEST → ~13:01 AEST)
**Severity:** Medium (6 PVC replicas stuck Terminating; Jiva redundancy reduced to 2-of-3 per affected PVC; no service outage)
**Status:** Resolved

---

## Executive Summary

Following the Calico v3.13.2→v3.29.3 upgrade (PGM-200), six OpenEBS Jiva replica pods on k8s01 became stuck in Terminating for ~1 hour. Each attempt to destroy their network sandbox failed with `plugin type="calico" failed (delete): error getting ClusterInformation: connection is unauthorized: Unauthorized`. Six replacement pods sat Pending, unable to schedule because anti-affinity blocked the only node their node selector would accept (k8s01, where their Terminating counterparts still held their affinity slot).

The root cause was a path mismatch on k8s01 between where Calico's `install-cni` writes its kubeconfig and where microk8s's containerd reads it. On k8s02 and k8s03, `/etc/cni/net.d` is a symlink to `/var/snap/microk8s/current/args/cni-network/` (the containerd `conf_dir`). On k8s01, `/etc/cni/net.d` is a real directory created at node initialisation in 2021 — the symlink was never created. When PGM-200 restarted calico-node on k8s01, the `install-cni` init container wrote a fresh pod-bound kubeconfig to `/etc/cni/net.d/` (the standard Linux path). containerd, reading from the microk8s path, kept the stale kubeconfig whose token was bound to the now-deleted old pod (`calico-node-px6bj`) — and therefore Unauthorized.

Fix: copied the fresh kubeconfig to the microk8s cni-network path, replaced the real directory with a symlink (matching k8s02/k8s03), and cleaned up the orphaned network sandboxes via force-delete. The stuck pods self-terminated immediately; Pending pods scheduled within seconds.

---

## Timeline (AEST — UTC+10)

| Time | Event |
|------|-------|
| **~08:20 AEST** | Calico v3.29.3 upgrade (PGM-200) restarts calico-node DaemonSet on all three nodes. On k8s02 and k8s03, `install-cni` writes fresh pod-bound kubeconfig to `/etc/cni/net.d/` which resolves (via symlink) to `/var/snap/microk8s/current/args/cni-network/`. On k8s01, `install-cni` writes to `/etc/cni/net.d/` (real directory); the microk8s cni-network path is not updated. |
| **~08:20 AEST** | Old pod `calico-node-px6bj` is deleted (DaemonSet rolling update). Kubernetes token controller invalidates its pod-bound service account token. The stale token remains in k8s01's `/var/snap/microk8s/current/args/cni-network/calico-kubeconfig`. |
| **12:01 AEST** | Jiva operator triggers a rolling pod restart cycle for affected PVCs. Six Jiva replica pods on k8s01 receive delete signals. kubelet calls `KillPodSandbox` for each; containerd invokes the Calico CNI plugin with the DEL command. |
| **12:01 AEST** | Calico CNI plugin attempts `GET ClusterInformation` using the stale token. API server returns `401 Unauthorized`. `KillPodSandbox` fails with `failed to destroy network for sandbox: plugin type="calico" failed (delete): error getting ClusterInformation: connection is unauthorized: Unauthorized`. |
| **12:01–13:00 AEST** | kubelet retries `KillPodSandbox` every ~15s, accumulating 185+ `FailedKillPod` warnings per pod. Six replacement pods are created (one per Jiva ReplicaSet) and remain Pending: anti-affinity blocks k8s01 (Terminating counterpart still there), node selector excludes k8s02/k8s03. |
| **~12:45 AEST** | User notices Pending/Terminating pods in openebs namespace and reports the issue. Investigation begins. |
| **~12:47 AEST** | `FailedKillPod` events examined. Root error: `connection is unauthorized: Unauthorized` from Calico CNI at `KillPodSandbox`. |
| **~12:52 AEST** | calico-node pods confirmed Running (1/1) on all three nodes. The issue is not calico-node itself but the CNI binary's kubeconfig. |
| **~12:54 AEST** | `kubectl debug node/k8s01`: calico-kubeconfig JWT decoded — token bound to `calico-node-px6bj` (deleted pod). Current pod: `calico-node-4t5hk`. Token is invalidated. |
| **~12:55 AEST** | `/etc/cni/net.d/` on k8s01: real directory, updated 22:20 UTC May 22 (by `install-cni`). `/var/snap/microk8s/current/args/cni-network/`: separate directory, last updated 00:15 UTC May 22 (stale). |
| **~12:57 AEST** | k8s02 and k8s03 confirmed: `/etc/cni/net.d` is a symlink to `/var/snap/microk8s/current/args/cni-network/` on both. k8s01 is the anomaly. |
| **~12:58 AEST** | microk8s containerd config confirmed: `conf_dir = "${SNAP_DATA}/args/cni-network"`. |
| **~13:00 AEST** | Fix applied on k8s01 (via `kubectl debug node`): fresh `calico-kubeconfig` and `10-calico.conflist` copied from `/etc/cni/net.d/` to `/var/snap/microk8s/current/args/cni-network/`. Real `/etc/cni/net.d` directory removed; symlink created pointing to microk8s path. |
| **~13:00 AEST** | All 6 Terminating pods self-terminate within seconds (kubelet retry cycle succeeds on next attempt with valid token). |
| **~13:01 AEST** | All 6 Pending replacement pods schedule to k8s01 and reach Running. No remaining Pending or Terminating pods cluster-wide. PGM-204 filed. |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: Calico CNI Unauthorized — stale pod-bound token blocks pod teardown on k8s01

##### How did pod sandbox teardown fail on k8s01?

The Calico CNI plugin's DEL operation could not authenticate to the Kubernetes API. Every `KillPodSandbox` call from containerd invokes the CNI plugin binary, which tries to `GET ClusterInformation` from the API server using a kubeconfig at `/var/snap/microk8s/current/args/cni-network/calico-kubeconfig`. The API server returned `401 Unauthorized`, causing the DEL to fail and the pod to remain Terminating.

##### How did the kubeconfig contain an invalid token?

The token in the microk8s cni-network kubeconfig was a **pod-bound projected service account token** issued to `calico-node-px6bj` — a pod that no longer existed. Pod-bound tokens are automatically invalidated when their issuing pod is deleted. When the Calico upgrade (PGM-200) rolled out a new DaemonSet revision, `calico-node-px6bj` was deleted and replaced by `calico-node-4t5hk`. The old token's entry in the token reviewer cache was revoked, causing any subsequent API call using it to receive `401 Unauthorized`.

##### How did the microk8s cni-network path still have the old token after the upgrade?

When `calico-node-4t5hk` started, its `install-cni` init container successfully wrote a new kubeconfig (with a fresh token bound to `calico-node-4t5hk`) to `/etc/cni/net.d/calico-kubeconfig`. However, on k8s01, `/etc/cni/net.d` is a **real directory** — not a symlink to `/var/snap/microk8s/current/args/cni-network/`. The write landed in the standard Linux CNI path and never reached the microk8s-specific path that containerd actually reads.

##### How did `/etc/cni/net.d` become a real directory on k8s01 instead of a symlink?

k8s01 was provisioned in September 2021 (directory timestamp: `Sep 14 2021`). At that time, microk8s's Calico addon or initial CNI setup created `/etc/cni/net.d` as a real directory. On k8s02 and k8s03 (provisioned later, June 2024 per symlink timestamp), the directory was created as a symlink to the microk8s cni-network path from the start — reflecting an updated provisioning procedure. k8s01 was never retroactively fixed.

##### How did this difference go undetected for years?

Before Calico v3.13.2→v3.29.3 (PGM-200), the calico-node pod on k8s01 (`calico-node-px6bj`) had been running continuously since the node was set up without being replaced. Its pod-bound token never expired and was never invalidated. The stale `/etc/cni/net.d` real directory had no observable effect: the microk8s path had a valid (though increasingly old) kubeconfig, and no upgrade or restart had ever required a fresh token to be delivered there.

##### How was the divergence not caught during the PGM-200 Calico upgrade?

The upgrade playbook verified cluster health (pods Running, Calico IPAM GC active) but did not verify that the CNI kubeconfig was correctly refreshed on each node after calico-node restarted. The path mismatch is only observable when comparing the two directories or decoding the JWT in the microk8s kubeconfig to verify its `kubernetes.io.pod.name` claim matches the current calico-node pod — neither check was part of the upgrade procedure.

##### How was this not detected before pod deletions were attempted?

The faulty kubeconfig only matters during the CNI DEL phase (pod network teardown). The CNI ADD phase (pod network setup) also reads the kubeconfig, but since the calico-node pod on k8s01 had been Running for hours with a working token in memory, new pod creation on k8s01 proceeded normally. Only the first pod deletion after the token was invalidated exposed the fault — which occurred ~4 hours later when the Jiva operator triggered a rolling restart.

---

#### Chain 2: Pending replacements unable to schedule — anti-affinity deadlock

##### How did the 6 replacement Jiva replica pods stay Pending?

The scheduler reported: `0/3 nodes are available: 1 node(s) didn't match pod anti-affinity rules, 2 node(s) didn't match Pod's node affinity/selector`. Jiva replica pods use node affinity to pin each replica to a specific node (via `topology.jiva.openebs.io/nodeName` labels) and pod anti-affinity to prevent two replicas of the same PVC from running on the same node. The replacement for each stuck pod was required to go to k8s01 (node affinity) but was blocked by the Terminating counterpart still holding the anti-affinity slot on k8s01.

##### How did the Terminating pods keep holding the anti-affinity slot?

The Terminating pods were still present as API objects because the kubelet could not complete their teardown (Chain 1). The scheduler treats Terminating pods as occupying their anti-affinity rules until the API object is deleted. Since no finalizers were set on the pods, the only blocker to API object removal was the kubelet completing its `KillPodSandbox` call — which was looping on the Calico CNI 401 error.

##### How did fixing the CNI kubeconfig resolve both chains simultaneously?

Once the valid kubeconfig was in place, the next `KillPodSandbox` retry succeeded: the Calico CNI DEL call authenticated, cleaned up the network namespace, and returned success. The kubelet acknowledged the pod as terminated and deleted the API object. The scheduler immediately placed the replacement pod on k8s01 (anti-affinity slot now clear). Both chains resolved within seconds of the kubeconfig fix — no force-delete of stuck pods was necessary.

---

## Impact

### Services Affected

| Service | Impact | Duration |
|---------|--------|----------|
| 6 OpenEBS Jiva PVC replica pods (k8s01) | Stuck Terminating — CNI DEL failing; sandbox not cleaned up | ~59 min (12:01–13:00 AEST) |
| 6 Jiva PVC replacement replicas | Stuck Pending — anti-affinity deadlock with Terminating predecessors | ~15–59 min depending on when each was created |
| Affected PVCs (6 total) | Reduced redundancy: 2-of-3 replicas Running; Jiva controller still serving I/O | ~59 min |

### Duration

- **Total incident window:** ~1 hour (12:01–13:01 AEST)
- **Expected recovery time (with documented procedure):** ~5 min

### Scope

- k8s01 only (CNI path mismatch specific to this node)
- No data loss — Jiva I/O continued via controller + 2 healthy replicas per PVC
- No user-facing service disruption

---

## Resolution Steps Taken

### Diagnosis

1. Identified 6 Terminating pods (24h old; deletion started ~44m prior) and 6 Pending replacements in `openebs` namespace.
2. Described a Terminating pod: `FailedKillPod x185 over 44m — KillPodSandboxError: plugin type="calico" failed (delete): error getting ClusterInformation: connection is unauthorized: Unauthorized`.
3. Confirmed calico-node Running on all nodes — issue was the CNI plugin binary's kubeconfig, not calico-node itself.
4. Used `kubectl debug node/k8s01 --image=busybox` to read `/var/snap/microk8s/current/args/cni-network/calico-kubeconfig` — JWT decoded, `kubernetes.io.pod.name: calico-node-px6bj` (deleted), vs current pod `calico-node-4t5hk`.
5. Compared `/etc/cni/net.d/` (updated 22:20 UTC May 22, fresh) vs microk8s cni-network path (updated 00:15 UTC May 22, stale).
6. Checked k8s02 and k8s03: `/etc/cni/net.d → /var/snap/microk8s/current/args/cni-network` (symlink). k8s01: real directory. Root cause confirmed.
7. Verified containerd config: `conf_dir = "${SNAP_DATA}/args/cni-network"` — containerd reads only the microk8s path.

### Fix

8. `kubectl debug node/k8s01 --image=busybox`:
   - Copied `/etc/cni/net.d/calico-kubeconfig` → `/var/snap/microk8s/current/args/cni-network/calico-kubeconfig`
   - Copied `/etc/cni/net.d/10-calico.conflist` → `/var/snap/microk8s/current/args/cni-network/10-calico.conflist`
   - Removed real `/etc/cni/net.d` directory
   - Created symlink: `ln -s /var/snap/microk8s/current/args/cni-network /etc/cni/net.d`
9. All 6 Terminating pods self-terminated within ~5 seconds (kubelet retry succeeded on next attempt).
10. All 6 Pending pods scheduled and reached Running.

---

## Verification

```bash
# No Pending or Terminating pods remain
kubectl --context pvek8s get pods -A --field-selector=status.phase=Pending
# → No resources found

kubectl --context pvek8s get pods -A | grep -v Running | grep -v Completed | grep -v NAMESPACE
# → (empty)

# Symlink in place on k8s01
# kubectl debug node/k8s01 -- ls -la /host/etc/cni/net.d
# → lrwxrwxrwx  /host/etc/cni/net.d -> /var/snap/microk8s/current/args/cni-network

# kubeconfig now matches current calico-node pod
# Token's kubernetes.io.pod.name: calico-node-4t5hk ✓
```

---

## Preventive Measures

### Immediate Actions Required

1. **Add CNI symlink verification to Calico upgrade playbook** (Medium)
   - The Calico upgrade playbook (or `ansible-role-microk8s`) should verify that `/etc/cni/net.d` is a symlink to `/var/snap/microk8s/current/args/cni-network/` on every node before and after upgrade. A mismatched node would fail this check and prompt remediation before calico-node restarts invalidate any tokens.
   - Linear: [PGM-205](https://linear.app/pgmac-net-au/issue/PGM-205)

2. **Add Ansible task to enforce CNI symlink idempotently on all nodes** (Medium)
   - An idempotent Ansible task in `ansible-role-microk8s` that creates the `/etc/cni/net.d` symlink if absent (removing any real directory first after backing up its contents). This would retroactively fix any other nodes that share k8s01's pre-2024 provisioning.
   - Linear: [PGM-206](https://linear.app/pgmac-net-au/issue/PGM-206)

### Longer-Term Improvements

3. **Add post-upgrade validation: verify calico-kubeconfig token is valid on all nodes** (Low)
   - After a Calico upgrade (or any calico-node rolling restart), verify that the JWT in the microk8s cni-network kubeconfig on each node has a `kubernetes.io.pod.name` matching the currently-running calico-node pod. A script or Ansible task could decode the token and cross-check. Catches the mismatch before the first pod deletion triggers it.
   - Linear: [PGM-207](https://linear.app/pgmac-net-au/issue/PGM-207)

---

## Lessons Learned

### What Went Well

- **CNI kubeconfig JWT decoding was decisive**: Decoding the token in the microk8s path immediately showed `calico-node-px6bj` as the issuing pod, pointing to the exact failure mechanism. Without this step, the investigation might have spent time on calico-node itself (which was healthy).
- **`kubectl debug node` gave direct filesystem access**: Reading and writing host files via the debug pod avoided SSH access requirements and made the fix fast and auditable.
- **Self-healing after kubeconfig fix**: No force-delete was needed. Once the kubelet's next retry cycle succeeded, both the Terminating pods and the Pending pods resolved automatically — confirming the fix was correct and complete.
- **Root cause traced to pre-2024 provisioning difference**: Identifying the symlink creation date (June 2024 on k8s02/k8s03 vs. absent on k8s01 from 2021) gave a clear explanation of why this only affected one node.

### What Didn't Go Well

- **Upgrade validation did not check CNI kubeconfig freshness**: The PGM-200 Calico upgrade was considered complete when pods were Running and IPAM GC was active. No check verified that the CNI kubeconfig delivered to the microk8s path matched the newly-running calico-node pod on each node. The fault was latent for ~4 hours until the first pod deletion.
- **Node provisioning divergence undetected for years**: k8s01's real `/etc/cni/net.d` directory had been there since 2021. No periodic audit or post-upgrade check compared CNI directory state across nodes.
- **Anti-affinity deadlock compounded the impact**: The Pending pods couldn't schedule until the Terminating pods cleared — creating a visible, confusing double-fault. If the scheduler had been able to schedule replacements on k8s02/k8s03 (or if node affinity was relaxed), the impact would have been limited to the CNI issue alone.

### Surprise Findings

- **Pod-bound token invalidation is silent and immediate**: When `calico-node-px6bj` was deleted during the Calico rolling update, its token was immediately invalidated with no warning to the CNI plugin. There is no grace period, no token rotation event, no API server error logged until something actually tries to use the stale token.
- **The CNI DEL failure mode is entirely hidden during normal operation**: The misconfigured path on k8s01 was invisible: new pods could be created (CNI ADD succeeded, presumably using a cached/separate token path or different code path), nodes showed Ready, calico-node was healthy, and no logs indicated any issue. Only a pod deletion — specifically one that reached the CNI DEL phase — exposed the fault.
- **k8s02 and k8s03 also updated correctly despite same symlink target**: On k8s02/k8s03, `install-cni` writing to `/etc/cni/net.d/calico-kubeconfig` (via the symlink) automatically updated the microk8s cni-network path. This is why those nodes worked correctly — the same upgrade action had opposite effects depending on whether the symlink was in place.

---

## Action Items

| # | Action | Priority | Linear |
|---|--------|----------|--------|
| 1 | Add CNI symlink verification step to Calico upgrade playbook | Medium | [PGM-205](https://linear.app/pgmac-net-au/issue/PGM-205) |
| 2 | Add idempotent Ansible task to enforce `/etc/cni/net.d → cni-network` symlink on all nodes | Medium | [PGM-206](https://linear.app/pgmac-net-au/issue/PGM-206) |
| 3 | Add post-upgrade validation: verify calico-kubeconfig JWT pod claim matches current calico-node pod on each node | Low | [PGM-207](https://linear.app/pgmac-net-au/issue/PGM-207) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03)
- **Kubernetes version:** v1.35.0 (snap rev 8612)
- **Container runtime:** containerd 2.1.x (microk8s 1.35)
- **CNI:** Calico v3.29.3 (independently installed via VXLAN manifest, PGM-200)
- **Affected node:** k8s01 (provisioned Sep 2021; `/etc/cni/net.d` real directory)
- **Healthy nodes:** k8s02, k8s03 (provisioned Jun 2024; `/etc/cni/net.d` symlink)

### Key Error Signatures

**kubelet FailedKillPod (kubelet/containerd events on k8s01):**
```
error killing pod: failed to "KillPodSandbox" for "<uid>" with KillPodSandboxError:
"rpc error: code = Unknown desc = failed to destroy network for sandbox \"<sha>\": 
plugin type=\"calico\" failed (delete): error getting ClusterInformation: 
connection is unauthorized: Unauthorized"
```

**CNI kubeconfig JWT — stale token diagnostic:**
```bash
# Read JWT from microk8s cni-network path and decode payload:
cat /var/snap/microk8s/current/args/cni-network/calico-kubeconfig \
  | grep token | awk '{print $2}' \
  | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool \
  | grep -E 'pod|exp|sub'
# "name": "calico-node-px6bj"  ← should match current calico-node pod name
# "exp": 1810944929             ← check against current time (may not be expired!)
# "sub": "system:serviceaccount:kube-system:calico-node"
```

**CNI directory state comparison:**
```bash
# On each node: check if /etc/cni/net.d is a symlink or real directory
kubectl --context pvek8s debug node/<nodename> -it --image=busybox -- \
  sh -c "ls -la /host/etc/cni/ && head -3 /host/var/snap/microk8s/current/args/cni-network/calico-kubeconfig"
# Healthy: lrwxrwxrwx  net.d -> /var/snap/microk8s/current/args/cni-network
# Broken:  drwx------  net.d (real directory — kubeconfigs diverged)
```

### Fix Procedure (for future recurrence)

```bash
# On the affected node (via kubectl debug node):
kubectl --context pvek8s debug node/<node> -it --image=busybox -- sh -c '
  # 1. Copy fresh files from real /etc/cni/net.d to microk8s path
  cp /host/etc/cni/net.d/calico-kubeconfig \
     /host/var/snap/microk8s/current/args/cni-network/calico-kubeconfig
  chmod 600 /host/var/snap/microk8s/current/args/cni-network/calico-kubeconfig
  cp /host/etc/cni/net.d/10-calico.conflist \
     /host/var/snap/microk8s/current/args/cni-network/10-calico.conflist

  # 2. Replace real directory with symlink
  rm -f /host/etc/cni/net.d/calico-kubeconfig /host/etc/cni/net.d/10-calico.conflist
  rmdir /host/etc/cni/net.d
  ln -s /var/snap/microk8s/current/args/cni-network /host/etc/cni/net.d
'
# Stuck Terminating pods will self-terminate within ~15s (kubelet retry cycle)
```

---

## References

- Linear ticket: [PGM-204](https://linear.app/pgmac-net-au/issue/PGM-204) — this incident (resolved)
- Linear ticket: [PGM-200](https://linear.app/pgmac-net-au/issue/PGM-200) — Calico v3.29.3 upgrade (root trigger: calico-node rolling restart)
- Related incident (VXLAN route corruption post-Calico upgrade): [k8s03 Extended Recovery — kine Watch Corruption and VXLAN Route Corruption](2026-05-18-k8s03-extended-recovery-kine-watch-vxlan-route-corruption.md)

---

## Reviewers

- @pgmac
