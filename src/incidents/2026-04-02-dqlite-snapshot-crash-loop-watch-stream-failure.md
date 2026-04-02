# Post Incident Review: dqlite Snapshot Bloat → kube-apiserver Instability → Controller Crash-Loop Cascade and Watch Stream Failure

**Date:** 2026-04-01 to 2026-04-02
**Duration:** ~36h (discovery 2026-04-01 ~09:00 AEST → full resolution 2026-04-02 ~18:00 AEST)
**Severity:** High (5 controllers crash-looping; all new pod creation silently stalled for several hours; AWX and GitHub Actions CI/CD degraded)
**Status:** Resolved

---

## Executive Summary

Five long-running controller pods entered crash-loop or sustained-restart cycles and were unable to stabilise. Separately, a silent failure emerged where no new Kubernetes objects (Pods, ReplicaSets, Deployments) could be created or scheduled across the entire cluster for several hours — discovered only when the AWX operator deployment failed to roll out after a GitOps fix was applied.

The root of both failures was a single configuration gap: **Calico's IPAM GC controller was never enabled**, causing stale IPAM handles to accumulate over years to 6,071 entries. Each handle is a dqlite row; at this scale, dqlite snapshots grew to 215 MB and fired every ~2 minutes. These frequent large snapshots caused kube-apiserver to be unresponsive for 10–30 seconds at a time, which exceeded the default `renewDeadline` (10s) for Kubernetes leader election. Controllers lost their leases and restarted in a loop. Multiple kubelite restarts performed during investigation eventually corrupted the kube-apiserver's watch stream, causing all informer caches across controllers and the scheduler to stop receiving `ADD` events for new objects. Resolution required the monthly dqlite VACUUM maintenance playbook to compact the database and a rolling kubelite restart to flush the broken streams.

---

## Timeline (AEST — UTC+10)

| Time | Event |
|------|-------|
| **2026-04-01 ~09:00** | Investigation begins. 5 pods identified as crash-looping: `awx-operator-controller-manager`, `gh-arc-actions-runner-controller`, `openebs-localpv-provisioner`, `hostpath-provisioner`, `csi-nfs-controller`. Restart counts 400–700+. |
| ~09:30 | Disk pressure on k8s02 identified: 71% full, DiskPressure condition recently True. dqlite snapshot directory contains 550 MB of recent snapshots, newest every ~2 min. |
| ~10:00 | `kubectl get ipamhandles --no-headers \| wc -l` → **6,071**. Calico-kube-controllers has `ENABLED_CONTROLLERS=node` only — no IPAM GC. This is the source of the snapshot bloat. |
| ~10:30 | Deleted 5,472 orphaned IPAM handles (599 remain, all with live allocations). |
| ~11:00 | dqlite restarted on k8s01, k8s02, k8s03 (rolling). Snapshot size unchanged at 215 MB — compaction requires WAL tombstones to expire. |
| ~11:30 | kubelite restarted on k8s02 to clear kube-controller-manager backoff. k8s02 DiskPressure clears. Disk at 71%, 22G free. |
| ~12:00 | ArgoCD fix committed: `awx.yaml` updated with correct `kube-rbac-proxy` image (`registry.k8s.io` not deprecated `gcr.io`) and `--leader-elect-lease-duration=60s --leader-elect-renew-deadline=40s` for awx-manager. `csi-nfs-controller` patched directly with `--leader-election-lease-duration=60s`. |
| ~13:00 | ArgoCD sync applies updated `awx` Application. New Deployment created but pods never start — controller-manager (on k8s03) stops processing new generations. observedGeneration lags behind generation. |
| ~13:30 | kubelite restarted on k8s03 (controller-manager leader). Controllers still not processing new objects. |
| ~14:00 | kubelite restarted on k8s01. Still no RS creation for new Deployments. |
| ~15:00 | kubelite restarted on k8s02. Test Deployment in `default` namespace also stuck (gen=1, obs=empty). Scheduler not scheduling manually created test pods. Cluster-wide watch stream failure confirmed. |
| ~16:00 | Second kubelite restart on k8s03. No improvement. Root cause identified: broken informer cache, not a per-controller issue. |
| **2026-04-02 ~14:00** | User runs `ansible-playbook microk8s-monthly-maintenance.yml` — performs dqlite VACUUM (compacts database) + rolling kubelite restart. Watch stream restored. All controllers and scheduler resume processing new objects. |
| ~14:30 | awx-operator Deployment rolls out successfully. Pod `2/2 Running`. ArgoCD: `awx` Synced/Healthy. |
| ~15:00 | gh-arc crash-loops with `flag provided but not defined: -lease-duration` — summerwind/actions-runner-controller:v0.27.6 binary does not support the flag. Patched to remove unsupported flags. `ignoreDifferences` removed from `gh-arc.yaml` (commit 9f42566). |
| ~15:30 | `gh-arc-actions-runner-controller`: 2/2 Running, 0 restarts. ArgoCD: `gh-arc` Synced/Healthy. |
| **~18:00** | All 5 crash-looping controllers stabilised. Incident resolved. |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting the surface answer. Keep drilling until reaching an actionable, preventable cause._

#### How did AWX and GitHub Actions CI/CD become unavailable?

The `awx-operator-controller-manager` and `gh-arc-actions-runner-controller` pods were crash-looping with hundreds of restarts. Controllers that crash-loop cannot manage their operands: AWX was unable to reconcile its deployment, and the ARC controller was unable to manage runner replicas.

#### How did the controller pods enter crash-loop?

Kubernetes uses a leader election lease mechanism (implemented via `Lease` resources in the `kube-system` namespace) to ensure only one replica of each controller is active. Leader election has two critical parameters:
- `leaseDuration` (default: 15s) — how long a leader holds the lease
- `renewDeadline` (default: 10s) — the leader must renew before this deadline or lose the lease

The kube-apiserver was intermittently unavailable for 10–30 second windows. When a controller could not renew its lease within 10 seconds, it logged `failed to renew lease`, exited, and was restarted by Kubernetes. This repeated continuously.

#### How was the kube-apiserver intermittently unavailable?

dqlite (MicroK8s's embedded etcd replacement) was producing 215 MB snapshots every ~2 minutes. During snapshot creation, the dqlite WAL is checkpointed and the write lock is held for several seconds. kube-apiserver uses dqlite for all reads and writes; during the lock contention window, API requests blocked and timed out.

#### How did dqlite reach 215 MB snapshots every 2 minutes?

A dqlite snapshot captures the entire database state. The snapshot size is directly proportional to database size. The dqlite database had grown to hundreds of MB because it contained 6,071 Calico IPAM handle records — each representing a claimed IP block. Normal snapshot thresholds (512 trailing WAL entries) were reached frequently due to ongoing write traffic from the crash-looping controllers, triggering frequent large snapshots.

#### How did 6,071 IPAM handles accumulate?

Calico creates an IPAM handle record for every pod that is ever assigned an IP address. Handles are supposed to be deleted when pods are deleted and their IPs released. The IPAM garbage collection controller — part of `calico-kube-controllers` — is responsible for cleaning up orphaned handles. However, `calico-kube-controllers` in this cluster was deployed with `ENABLED_CONTROLLERS=node` only, which enables only the node controller. The IPAM controller was never included, so orphaned handles from years of pod churn accumulated without ever being cleaned up.

#### How did `calico-kube-controllers` end up with only the node controller enabled?

This was the original deployment configuration when Calico was installed on this cluster (running Calico v3.13.2, released ~2021). The IPAM controller is not enabled by default in all versions and configurations; it must be explicitly included in `ENABLED_CONTROLLERS`. This default was never reviewed or corrected after initial deployment, and no monitoring existed to alert on IPAM handle growth.

#### How did the broken watch stream occur (secondary root cause)?

During investigation, kubelite was restarted on all three nodes multiple times in an attempt to clear individual controller backlogs. Each kubelite restart causes kube-apiserver to re-establish its dqlite connection and re-initialise its watch stream to all controllers. Under sustained dqlite snapshot pressure (215 MB every 2 min), some watch stream re-establishments failed silently — the stream appeared connected but `ADD` events for new objects were not delivered to any informer cache. This is a known failure mode in etcd/dqlite clients under connection churn: the watch stream reconnects but the resume token is lost or rejected, causing the client to miss events that occurred during reconnection. The result: all controllers and the scheduler received updates for existing objects but never saw new ones. New Deployments were processed by the API server but no controller ever created a ReplicaSet; new Pods were created but the scheduler never saw them.

### Secondary Findings

#### gcr.io/kubebuilder registry deprecation (operational gap)

The `awx-operator` kube-rbac-proxy container was referencing `gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0`. Google Container Registry (`gcr.io/kubebuilder`) was deprecated in March 2025 and images are no longer pulled. The correct registry is `registry.k8s.io/kubebuilder`. This caused `ImagePullBackOff` on the awx-operator pod even after the leader election fix was applied, requiring an additional fix pass. No monitoring existed for image pull failures in non-running controllers.

#### Binary flag incompatibility with summerwind ARC v0.27.6

The `summerwind/actions-runner-controller:v0.27.6` binary does not implement `--lease-duration`, `--renew-deadline`, or `--retry-period` flags. These flags were patched onto the `gh-arc-actions-runner-controller` Deployment during investigation as a leader election fix, but the process started with `flag provided but not defined: -lease-duration` and crashed immediately. The fix was to remove the unsupported flags; the underlying leader election issue was resolved by the dqlite VACUUM (snapshot size reduction), not by the flags. The version of summerwind ARC in use (v0.27.6) is very old and does not support modern leader election tuning.

#### Offline dqlite VACUUM not viable

An attempt was made to vacuum dqlite snapshots offline by: stopping all dqlite services, LZ4-decompressing each node's latest snapshot, running `sqlite3 VACUUM`, recompressing, then restarting. The cluster hung for 8 minutes after restart. Root cause: each node's dqlite snapshot was at a different Raft log index. Independent vacuums produced binary-incompatible SQLite page layouts. Raft could not reconcile the divergent snapshots. The cluster recovered only after reverting to the original (unvacuumed) snapshots. **Safe vacuum requires the online `microk8s dbctl` method or the monthly maintenance playbook** (which uses cowsql's online VACUUM via kubeconfig connection).

---

## Impact

### Services Affected

| Service | Impact | Duration |
|---------|--------|----------|
| AWX Ansible automation | Operator crash-looping; AWX unable to reconcile; automation tasks degraded | ~36h |
| GitHub Actions self-hosted runners | ARC controller crash-looping; runner dispatch degraded | ~36h |
| OpenEBS LocalPV provisioner | Crash-looping; new LocalPV PVC provisioning unavailable | ~36h |
| Hostpath provisioner | Crash-looping; new hostpath PVC provisioning unavailable | ~36h |
| CSI NFS controller | Crash-looping; new NFS PVC provisioning unavailable | ~36h |
| All new pod/deployment creation (cluster-wide) | Silent failure — new objects processed by API server but ignored by controllers and scheduler | ~4–6h |

### Duration

- **Silent failure period** (crash-looping): ~2026-04-01 09:00 → ~2026-04-02 14:00 (~29h) — pods crash-looping with no alerting
- **Active watch stream failure**: ~2026-04-01 15:00 → ~2026-04-02 14:00 (~23h)
- **Active investigation and recovery**: ~2026-04-01 09:00 → ~2026-04-02 18:00 (~33h)
- **Total incident duration**: ~36h

### Scope

- 3-node microk8s HA cluster `pvek8s`
- 5 crash-looping controller pods (awx-operator, gh-arc, openebs-localpv, hostpath-provisioner, csi-nfs-controller)
- Cluster-wide new-object creation stalled for ~4–6h
- No persistent storage data loss
- No user-facing services disrupted (vaultwarden, media, finance apps unaffected — all running on existing pods)

---

## Resolution Steps Taken

### Phase 1: IPAM Handle Cleanup

1. **Counted IPAM handles**: `kubectl get ipamhandles --no-headers | wc -l` → 6,071

2. **Identified orphaned handles** (no corresponding running pod):
    ```bash
    # Get all live pod IPs
    kubectl get pods -A -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' > /tmp/live_ips.txt
    # Cross-reference with IPAM handles
    kubectl get ipamhandles -o json | jq -r '.items[] | select(.metadata.name | test("^ipip")) | .metadata.name'
    ```

3. **Deleted 5,472 orphaned handles**:
    ```bash
    # Bulk delete handles with no live allocation
    calicoctl get ipamhandle -o json | jq -r '.items[] | select(.spec.block | length == 0) | .metadata.name' \
      | xargs -I{} calicoctl delete ipamhandle {}
    ```
    599 handles remained (all with live allocations).

4. **Restarted dqlite** on all three nodes (rolling, serial):
    ```bash
    for node in k8s01 k8s02 k8s03; do
      ssh $node 'sudo systemctl restart snap.microk8s.daemon-k8s-dqlite'
      sleep 10
    done
    ```

5. **Restarted kubelite on k8s02** to clear controller-manager backoff.

### Phase 2: Leader Election Fixes (GitOps)

6. **Updated `awx.yaml`** (commit de4b157):
   - Fixed kube-rbac-proxy image: `gcr.io/kubebuilder` → `registry.k8s.io/kubebuilder`
   - Added `--leader-elect-lease-duration=60s --leader-elect-renew-deadline=40s` to awx-manager args

7. **Patched `csi-nfs-controller`** directly (via kubectl) with `--leader-election-lease-duration=60s`.

8. **Committed ArgoCD sync** for `ci-tools` app-of-apps; ArgoCD applied updated Application manifests.

### Phase 3: Watch Stream Diagnosis

9. **Confirmed cluster-wide watch stream failure** by:
   - Creating test Deployment in `default` namespace → no RS created (gen=1, obs=empty)
   - Creating test Pod directly → pod remained Pending indefinitely (scheduler silent)
   - Confirming Deployment controller on k8s03 had not processed any new generations for hours

10. **Multiple kubelite restarts** (k8s03, k8s01, k8s02, k8s03 again) — each restored some function temporarily but did not fix the root stream issue under continued dqlite snapshot pressure.

### Phase 4: Root Fix — Monthly Maintenance Playbook

11. **User ran** `ansible-playbook -i inventory/hosts.ini microk8s-monthly-maintenance.yml`:
    - dqlite VACUUM via cowsql (online, safe — no Raft disruption)
    - Rolling kubelite restart (serial: 1, with health checks between nodes)

12. **Result**: dqlite snapshot size reduced. Rolling kubelite restart flushed all broken informer caches and re-established watch streams cleanly (no dqlite lock contention during restart).

13. **All controllers resumed** processing within 2 minutes of final kubelite restart.

### Phase 5: gh-arc Flag Incompatibility Fix

14. **Identified binary incompatibility**: `gh-arc-actions-runner-controller` crash-looped with `flag provided but not defined: -lease-duration`.

15. **Removed unsupported flags** from the Deployment:
    ```bash
    kubectl patch deployment gh-arc-actions-runner-controller -n ci --type=json \
      -p '[{"op":"remove","path":"/spec/template/spec/containers/0/args/X"}]'
    # (repeated for --lease-duration, --renew-deadline, --retry-period)
    ```

16. **Removed `ignoreDifferences`** from `gh-arc.yaml` (commit 9f42566) — the flag protection was no longer needed since the flags were invalid.

### Phase 6: awx-operator Manual Recovery

17. **Deployment controller stuck** with `observedGeneration` lagging — caused by the watch stream failure period. Resolved after maintenance playbook restored the watch stream.

18. **awx-operator pod** `awx-operator-controller-manager` reached 2/2 Running. ArgoCD: `awx` Synced/Healthy.

---

## Verification

### Controller Health

```
NAME                                          READY   STATUS    RESTARTS   AGE
awx-operator-controller-manager-xxx           2/2     Running   0          2h
gh-arc-actions-runner-controller-xxx          2/2     Running   0          1h
```

### ArgoCD Application Status

```
NAME       SYNC STATUS   HEALTH STATUS
ci-tools   Synced        Healthy
awx        Synced        Healthy
gh-arc     Synced        Healthy
```

### Cluster Health

```
NAME    STATUS   ROLES    AGE      VERSION
k8s01   Ready    <none>   4y220d   v1.34.5
k8s02   Ready    <none>   4y220d   v1.34.5
k8s03   Ready    <none>   4y220d   v1.34.5
```

### IPAM Handles

```bash
kubectl get ipamhandles --no-headers | wc -l
# → 599 (down from 6,071; all with live allocations)
```

### New Object Creation (post-fix)

Test Deployment created in `default` namespace reached `1/1 Running` within 30 seconds of the maintenance playbook completing.

---

## Preventive Measures

### Immediate Actions Required

1. **Enable Calico IPAM GC controller** (Critical)
   - `calico-kube-controllers` currently has `ENABLED_CONTROLLERS=node` only. IPAM handles will re-accumulate at the same rate as before.
   - Action: Add `workloadendpoint` and `ipam` to `ENABLED_CONTROLLERS` in calico-kube-controllers deployment. This enables automatic cleanup of orphaned handles.
   - If on Calico ≥ v3.20: also use `calicoctl ipam check --fix` to perform one-time cleanup.
   - Risk if ignored: 6,071 handles will re-accumulate within months; incident will recur.
   - Linear: **[PGM-118](https://linear.app/pgmac-net-au/issue/PGM-118/enable-calico-ipam-gc-controller-to-prevent-handle-accumulation)**

2. **Upgrade Calico from v3.13.2 to current (v3.29+)** (High)
   - v3.13.2 is ~4 years old. Modern Calico includes improved IPAM GC, better eBPF support, and security fixes.
   - Action: Plan and execute Calico upgrade via rolling node procedure. Test with `calico-node` pod health checks between nodes.
   - Linear: **[PGM-119](https://linear.app/pgmac-net-au/issue/PGM-119/upgrade-calico-from-v3132-to-v329)**

3. **Add monitoring for IPAM handle count** (High)
   - No alert existed for IPAM handle accumulation.
   - Action: Add Prometheus alert: `count(calico_ipam_allocated_ips) > 1000` → warning; `> 3000` → critical.
   - Linear: **[PGM-120](https://linear.app/pgmac-net-au/issue/PGM-120/add-prometheus-alert-for-calico-ipam-handle-count)**

4. **Add monitoring for dqlite snapshot frequency and size** (High)
   - Frequent large snapshots are a leading indicator of database bloat. No alert fired during 36h of snapshot storms.
   - Action: Add alert on dqlite snapshot file age (`find /var/snap/microk8s/current/var/kubernetes/backend -name 'snapshot-*' -newer snapshot-${N-1}` rate > 1/5min) and size (> 50 MB per snapshot).
   - Linear: **[PGM-121](https://linear.app/pgmac-net-au/issue/PGM-121/add-alert-for-dqlite-snapshot-storm-rate-and-size)**

5. **Add Kubernetes leader election failure alerting** (High)
   - No alert fired for `failed to renew lease` log entries across 5 controllers over 36h.
   - Action: Add Loki/Alloy alert rule matching `failed to renew lease` in controller logs.
   - Linear: **[PGM-122](https://linear.app/pgmac-net-au/issue/PGM-122/add-loki-alert-for-kubernetes-leader-election-failures)**

### Longer-Term Improvements

6. **Upgrade hostpath-provisioner** (Medium)
   - `cdkbot/hostpath-provisioner:1.3.0` does not support `--leader-election-lease-duration` flags. Stabilised naturally after dqlite VACUUM but cannot be tuned for slow etcd environments.
   - Action: Upgrade to a version that supports leader election tuning (v1.4+).
   - Linear: **[PGM-123](https://linear.app/pgmac-net-au/issue/PGM-123/upgrade-hostpath-provisioner-to-support-leader-election-flag-tuning)**

7. **Upgrade openebs-localpv-provisioner** (Medium)
   - `openebs/provisioner-localpv:2.12.0` does not support `--leader-election-lease-duration` flags. Same issue as hostpath-provisioner.
   - Action: Upgrade to a version that supports leader election tuning.
   - Linear: **[PGM-124](https://linear.app/pgmac-net-au/issue/PGM-124/upgrade-openebs-localpv-provisioner-to-support-leader-election-flag)**

8. **Upgrade summerwind/actions-runner-controller** (Medium)
   - `v0.27.6` is the last release of the summerwind ARC variant. It does not support modern leader election flags. Consider migrating to the `actions/actions-runner-controller` (the official successor) which supports `gha-runner-scale-set`.
   - Action: Evaluate migration to `actions/actions-runner-controller` gha-runner-scale-set mode (already partly in use via `gharc-*` apps).
   - Linear: **[PGM-125](https://linear.app/pgmac-net-au/issue/PGM-125/evaluate-migration-from-summerwind-arc-v0276-to-actionsactions-runner)**

9. **Document and schedule monthly dqlite maintenance** (Medium)
   - The monthly maintenance playbook (`ansible/microk8s-monthly-maintenance.yml`) was the definitive fix. It is not currently scheduled.
   - Action: Set up a cron trigger or AWX job template to run `microk8s-monthly-maintenance.yml` on the first Sunday of each month.
   - Linear: **[PGM-126](https://linear.app/pgmac-net-au/issue/PGM-126/schedule-monthly-dqlite-maintenance-awx-job-or-cron)**

10. **Document watch stream failure recovery runbook** (High)
    - No runbook existed for "controllers and scheduler stopped processing new objects". The symptom is non-obvious (API server accepts requests, events are recorded, but nothing happens).
    - Action: Add runbook entry:
      ```bash
      # Symptom: new Deployments stuck at gen>obs, new Pods never scheduled
      # Diagnose:
      kubectl create deployment test-stream --image=nginx -n default
      kubectl get rs -n default  # if no RS created within 30s, watch stream broken
      # Fix:
      ansible-playbook -i inventory/hosts.ini microk8s-monthly-maintenance.yml
      # OR if urgent: rolling kubelite restart AFTER dqlite snapshot storm has subsided
      ```
    - Linear: **[PGM-127](https://linear.app/pgmac-net-au/issue/PGM-127/document-kube-apiserver-watch-stream-failure-recovery-runbook)**

11. **Verify binary flag support before patching Deployments** (Medium)
    - Two recovery actions (gh-arc `--lease-duration` flags, hostpath-provisioner `--leader-election-lease-duration`) failed because the binary didn't support the flags. Wasted ~2h.
    - Action: Before patching a Deployment with new CLI flags, verify: `kubectl exec <pod> -- <binary> --help | grep <flag>`. Document this in the operator runbook.
    - Linear: **[PGM-128](https://linear.app/pgmac-net-au/issue/PGM-128/add-binary-flag-verification-step-to-operator-patching-runbook)**

---

## Lessons Learned

### What Went Well

- **IPAM handle root cause identified quickly**: The connection between 6,071 handles → large snapshots → slow apiserver → leader election failures was traced within ~1h of starting investigation.
- **Calico IPAM cleanup was safe**: Deleting 5,472 orphaned handles had no impact on running pods. The 599 remaining handles all had live allocations.
- **ArgoCD GitOps preserved intent**: All fixes were committed to git and synced via ArgoCD. Manual kubectl patches were used only for emergency recovery and documented for later GitOps reconciliation.
- **No data loss**: All persistent storage (OpenEBS volumes, dqlite Raft state) was unaffected throughout.
- **Monthly maintenance playbook was definitive**: The existing `microk8s-monthly-maintenance.yml` playbook, when finally run, resolved both the dqlite snapshot size issue and the broken watch stream in a single operation.

### What Didn't Go Well

- **No alerting for 36h**: Five controllers crashed hundreds of times with no notification. The incident was discovered manually.
- **Multiple kubelite restarts worsened the situation**: Each restart under active dqlite snapshot pressure had a chance of breaking the watch stream further. A better approach: fix the root cause (dqlite bloat) first, then perform a single clean restart.
- **Offline vacuum attempt wasted time**: The LZ4-decompress → sqlite3 VACUUM → recompress approach was attempted before understanding that dqlite snapshots are Raft-state-encoded. The 8-minute cluster hang and manual recovery cost ~2h.
- **Binary flag incompatibility not checked**: Patching `gh-arc` with `--lease-duration` flags without first verifying binary support caused an additional crash-loop that took ~1h to diagnose.
- **gcr.io deprecation not caught earlier**: The `gcr.io/kubebuilder` image deprecation was a known issue (since March 2025) that was not applied to the awx.yaml manifest until this incident forced it.

### Surprise Findings

- **Offline dqlite vacuum is not safe**: The attempt to vacuum snapshots offline by stopping all dqlite services and vacuuming each node's snapshot independently caused Raft state inconsistency. Each node's snapshot was at a different Raft log index; independent SQLite vacuums produce binary-incompatible page layouts. Recovery required restoring all nodes to their original (pre-vacuum) snapshots.
- **Watch stream failure is silent**: When the kube-apiserver watch stream breaks after reconnection under etcd/dqlite pressure, it does not produce obvious error logs. Controllers continue to function for existing objects and produce no errors — only new objects are silently ignored. The symptom (`observedGeneration` never incrementing) looks identical to a controller being overloaded or having a bug.
- **`ansible-operator-plugins` uses `--leader-elect-*` not `--leader-election-*`**: The AWX operator binary uses non-standard flag naming (`--leader-elect-lease-duration` not `--leader-election-lease-duration`). This caused an initial patch to fail silently (flag accepted but not acted on) before the correct flag name was found.

---

## Action Items

| # | Action | Priority | Owner | Linear |
|---|--------|----------|-------|--------|
| 1 | Enable Calico IPAM GC controller (`ENABLED_CONTROLLERS=node,workloadendpoint,ipam`) | Critical | @pgmac | [PGM-118](https://linear.app/pgmac-net-au/issue/PGM-118/enable-calico-ipam-gc-controller-to-prevent-handle-accumulation) |
| 2 | Upgrade Calico v3.13.2 → v3.29+ | High | @pgmac | [PGM-119](https://linear.app/pgmac-net-au/issue/PGM-119/upgrade-calico-from-v3132-to-v329) |
| 3 | Add Prometheus alert for IPAM handle count (>1000 warn, >3000 crit) | High | @pgmac | [PGM-120](https://linear.app/pgmac-net-au/issue/PGM-120/add-prometheus-alert-for-calico-ipam-handle-count) |
| 4 | Add alert for dqlite snapshot storm (rate >1/5min or size >50MB) | High | @pgmac | [PGM-121](https://linear.app/pgmac-net-au/issue/PGM-121/add-alert-for-dqlite-snapshot-storm-rate-and-size) |
| 5 | Add Loki alert for Kubernetes leader election failures (`failed to renew lease`) | High | @pgmac | [PGM-122](https://linear.app/pgmac-net-au/issue/PGM-122/add-loki-alert-for-kubernetes-leader-election-failures) |
| 6 | Upgrade hostpath-provisioner to version supporting leader election flag tuning | Medium | @pgmac | [PGM-123](https://linear.app/pgmac-net-au/issue/PGM-123/upgrade-hostpath-provisioner-to-support-leader-election-flag-tuning) |
| 7 | Upgrade openebs-localpv-provisioner to version supporting leader election flag tuning | Medium | @pgmac | [PGM-124](https://linear.app/pgmac-net-au/issue/PGM-124/upgrade-openebs-localpv-provisioner-to-support-leader-election-flag) |
| 8 | Evaluate migration from summerwind ARC v0.27.6 to actions/actions-runner-controller gha-runner-scale-set | Medium | @pgmac | [PGM-125](https://linear.app/pgmac-net-au/issue/PGM-125/evaluate-migration-from-summerwind-arc-v0276-to-actionsactions-runner) |
| 9 | Schedule monthly dqlite maintenance (AWX job template or cron, first Sunday of month) | Medium | @pgmac | [PGM-126](https://linear.app/pgmac-net-au/issue/PGM-126/schedule-monthly-dqlite-maintenance-awx-job-or-cron) |
| 10 | Document watch stream failure recovery runbook | High | @pgmac | [PGM-127](https://linear.app/pgmac-net-au/issue/PGM-127/document-kube-apiserver-watch-stream-failure-recovery-runbook) |
| 11 | Add binary flag verification step to operator runbook | Medium | @pgmac | [PGM-128](https://linear.app/pgmac-net-au/issue/PGM-128/add-binary-flag-verification-step-to-operator-patching-runbook) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes)
- **Kubernetes version:** v1.34.5
- **Container runtime:** containerd 1.7.28
- **Calico version:** v3.13.2
- **AWX operator version:** 2.19.1
- **summerwind ARC version:** v0.27.6
- **dqlite snapshot size at incident start:** ~215 MB (every ~2 min)
- **IPAM handles at incident start:** 6,071 (5,472 orphaned)

### Crash-Looping Pods at Incident Start

| Namespace | Pod | Restarts | Root Cause | Fix |
|-----------|-----|----------|------------|-----|
| ci | awx-operator-controller-manager | ~700 over 55d | renewDeadline exceeded + gcr.io image pull failure | leader-elect flags + registry fix (GitOps) |
| ci | gh-arc-actions-runner-controller | ~700 over 55d | renewDeadline exceeded | dqlite VACUUM (root fix); unsupported flags removed |
| openebs | openebs-localpv-provisioner | ~700 over 55d | renewDeadline exceeded | Stabilised naturally after dqlite VACUUM |
| kube-system | hostpath-provisioner | ~700 over 55d | renewDeadline exceeded | Stabilised naturally after dqlite VACUUM |
| kube-system | csi-nfs-controller | ~700 over 55d | renewDeadline exceeded | `--leader-election-lease-duration=60s` kubectl patch |

### Key Error Signatures

**Controller leader election failure (all 5 pods, continuous):**
```
E leaderelection.go:330 error retrieving resource lock kube-system/csi-nfs
err="Get \"https://127.0.0.1:16443/apis/coordination.k8s.io/v1/namespaces/kube-system/leases/csi-nfs\": context deadline exceeded"
```

**dqlite WAL checkpoint lock contention (kube-controller-manager):**
```
W controller.go:244 "Requeue" key="ci/awx-operator-controller-manager" err="database is locked"
```

**Watch stream failure (silent — identified by observing controller inaction):**
```
# No error log. Symptom only:
# kubectl get deploy <name> -o jsonpath='{.status.observedGeneration}' → empty or stale
# kubectl get rs -n <namespace> → no new RS created
```

**gh-arc binary flag incompatibility:**
```
flag provided but not defined: -lease-duration
```

**awx-operator image pull failure:**
```
Failed to pull image "gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0":
rpc error: code = NotFound desc = failed to pull and unpack image
```

---

## References

- Related incident (disk pressure on k8s02 as contributing factor): memory record `project_k8s02_disk.md`
- Related incident (ARC pods stuck Pending, kubelet sync stall): `incidents/src/incidents/2026-03-28-arc-pods-pending-kubelet-sync-stall.md`
- Monthly maintenance playbook: `ansible/microk8s-monthly-maintenance.yml`
- Calico IPAM GC documentation: https://docs.tigera.io/calico/latest/reference/kube-controllers/configuration
- MicroK8s dqlite documentation: https://microk8s.io/docs/dqlite
- Kubernetes leader election: https://kubernetes.io/blog/2016/01/simple-leader-election-with-kubernetes/

---

## Reviewers

- @pgmac

---

## Notes

### On dqlite Snapshot Safety

The dqlite snapshot format is not plain SQLite — each snapshot is LZ4-compressed and encodes a Raft log index. Nodes in a Raft cluster can have snapshots at different indices; this is normal and expected (the leader sends the latest snapshot to lagging followers). However, if you decompress and SQLite-VACUUM a snapshot offline, the resulting file has a different SQLite page layout but the same Raft index. When dqlite restarts and attempts to reconcile snapshots across nodes, the divergent page layouts cause Raft state machine inconsistency. **Never vacuum dqlite snapshots offline.** Use the `microk8s dbctl` tooling or the monthly maintenance playbook.

### On kube-apiserver Watch Stream Failures

Under sustained dqlite write pressure (frequent large snapshots causing lock contention), kube-apiserver watch streams to controllers can fail silently. The failure mode is not a connection drop — TCP remains established — but rather a lost or rejected resume token during a background reconnection. Affected controllers continue to receive `MODIFIED` and `DELETED` events for existing objects (these are delivered via the existing stream buffer) but stop receiving `ADD` events for new objects. Diagnosis: create a new object and observe whether the relevant controller acknowledges it within 30 seconds. Recovery: wait for dqlite snapshot pressure to subside, then perform a rolling kubelite restart. The monthly maintenance playbook does both.

### On Calico IPAM Handle Accumulation Rate

At normal homelab workload churn (ephemeral runner pods, occasional deployments), approximately 5,000 handles accumulated over ~3 years — roughly 1,500 per year or ~4 per day. At this rate, re-accumulation to 1,000 handles (alert threshold) would take ~8 months if the IPAM GC controller remains disabled. Enabling the IPAM GC controller should reduce handles to near-zero and maintain them there.
