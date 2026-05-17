---
tags:
  - calico
  - awx
  - rbac
  - dqlite
  - write-storm
---

# Post Incident Review: AWX Automation Pod Stuck Pending — Calico RBAC Gap + dqlite Write Storm

**Date:** 2026-05-15
**Duration:** ~13 min silent (pod never scheduled) + ~8 min to fix + ~1.5h total including maintenance
**Severity:** Medium (AWX CI/CD jobs failing repeatedly; no user-facing homelab services impacted)
**Status:** Resolved

---

## Executive Summary

AWX job 1865 ("Hardware docs update") failed because its pod `automation-job-1865-ntgbq` was stuck in `Pending` for 13+ minutes and was never scheduled. The kube-scheduler had a stale informer watch — it had missed the pod's ADD event and would never schedule it without intervention. The same failure had already silently affected three previous jobs (1859, 1861, 1863) without investigation.

The root cause was a RBAC gap in the `calico-kube-controllers` ClusterRole that had existed since cluster creation. The pod/workloadendpoint controller was forbidden from listing pods and workloadendpoints, causing it to crash-loop every ~5 seconds and generate ~12 API writes/minute of error traffic. This amplified the write pressure on dqlite, which already experienced periodic 1–2 second write locks during 225MB snapshot serialization. When a lock occurred during an inflight scheduler watch stream write, the stream was interrupted; after reconnecting, the scheduler's informer missed the pod ADD event and never recovered without a restart.

Resolution required fixing the Calico ClusterRole, restarting `daemon-kubelite` on k8s03 (the scheduler node) to flush the stale informer, and removing the long-abandoned NewRelic MutatingWebhookConfiguration. Post-fix, dqlite lock errors ceased entirely within 3 minutes. AWX job 1867 scheduled and ran successfully on first retry.

A monthly maintenance rolling restart was performed to refresh all informer watches cluster-wide. The 225MB snapshot size did not reduce after the rolling restart — establishing that the maintenance play cannot address SQLite page fragmentation via rolling restarts; a microk8s upgrade is required for that.

---

## Timeline (AEST — UTC+10)

| Time | Event |
|------|-------|
| **~04:43** | kube-scheduler acquires leader on k8s03 (UTC 20:43 the previous evening — reflects ongoing leader election instability; 4,499 transitions recorded since install) |
| **~07:20** | AWX creates pod `automation-job-1865-ntgbq` in `ci` namespace. Pod enters `Pending`. |
| **~07:20 → 07:33** | Pod sits Pending for 13+ minutes with zero events and zero status conditions. kube-scheduler on k8s03 never attempts to schedule it — pod ADD event was lost from informer watch. This is the fourth consecutive AWX job failure (1859, 1861, 1863 also failed). |
| **~07:33** | Incident discovered. Investigation begins. |
| ~07:33 | `kubectl describe pod` confirms: no events, no conditions, no scheduler activity. |
| ~07:35 | Scheduler lease confirmed renewing on k8s03. k8s02 kubelet logs show `database is locked (exec try: 500)` recurring ~every 1–2 minutes. |
| ~07:36 | `snap restart microk8s.daemon-kube-scheduler` fails — no such service; all control-plane components are bundled in `daemon-kubelite`. Scheduler restart deferred. |
| ~07:37 | k8s02 node conditions show `KubeletNotReady`-adjacent latency on port 10250; disk health confirmed OK (71% usage). |
| ~07:38 | NewRelic `nri-metadata-injection` MutatingWebhookConfiguration identified — failurePolicy: Ignore, NewRelic not in use. Queued for removal. |
| ~07:39 | `calico-kube-controllers` logs show `pods is forbidden: User "system:serviceaccount:kube-system:calico-kube-controllers" cannot list resource "pods"` repeating every ~5 seconds. |
| ~07:40 | ClusterRole `calico-kube-controllers` inspected. `pods` has only `get` (missing `list`/`watch`). `workloadendpoints` resource entirely absent. Both have been missing since `resourceVersion: 146` — cluster creation. |
| **~07:41** | Calico ClusterRole patched: added `list`/`watch` to `pods`; added `workloadendpoints` with full `watch/list/get/create/update/delete`. |
| ~07:41 | NewRelic `nri-metadata-injection` MutatingWebhookConfiguration deleted. |
| **~07:41** | `daemon-kubelite` restarted on k8s03 to flush stale controller-manager and scheduler informer watches. kube-scheduler re-elects on k8s02. |
| ~07:43 | `dependency-track-frontend` rolling update (also stalled on k8s03) resumes; stuck pod force-deleted; replacement scheduled to k8s01/k8s02. |
| **~07:44** | Last `database is locked` error observed on k8s02 (cert-manager lease renewal). No further lock errors. |
| ~07:50 | `calico-kube-controllers` pod Running 1/1 with clean logs — both `node` and `workloadendpoint` controllers functional. IPAM sync: "Node and IPAM data is in sync". |
| ~08:05 | Cluster verification: all 3 nodes Ready, no Pending pods, scheduler lease stable, zero lock errors in 20+ minutes. |
| **~08:08** | AWX job 1867 (retry of "Hardware docs update") triggered. Pod `automation-job-1867-ckj4l` reaches Running within 30 seconds of creation. **Job completes successfully.** |
| ~08:10 | dqlite database analysis: 225MB snapshot, 21.8MB live data (~10x fragmentation from years of writes without VACUUM). Decision: run monthly maintenance play to refresh all informer watches. |
| ~08:18 | Monthly maintenance (`microk8s-monthly-maintenance.yml`) rolling restart begins: k8s01. |
| ~08:25 | k8s01 complete. Snapshot still 225MB — k8s01 re-synced from leader's un-vacuumed snapshot on restart. |
| ~08:28 | k8s02 complete. Snapshot still 225MB — same reason. |
| ~08:33 | k8s03 complete. Snapshot still 225MB. 6 transient lock errors during k8s03 restart window (leader election churn); 0 errors in steady state immediately after. |
| **~08:35** | Maintenance complete. All nodes Ready. No Pending pods. Zero lock errors. **Incident fully resolved.** |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting the surface answer. Keep drilling until reaching an actionable, preventable cause._

#### How did AWX job 1865 fail?

The automation pod `automation-job-1865-ntgbq` was stuck in `Pending` for 13+ minutes. AWX's execution environment controller timed out waiting for the pod to reach Running and marked the job failed.

#### How was the pod stuck in Pending?

The kube-scheduler never emitted a `Scheduled` event for the pod. It had zero status conditions — the API server never received a binding from the scheduler. The pod existed in etcd but was invisible to the scheduler.

#### How did the scheduler not see the pod?

The scheduler maintains an in-memory pod queue populated by a watch stream from the API server. When the watch stream is interrupted and reconnects, the `ResourceVersion` the scheduler uses to resume the watch may skip over events that fired during the gap. The pod's `ADDED` event was in that gap — the scheduler never received it and the pod was never enqueued for scheduling.

#### How was the watch stream disrupted?

The kube-apiserver running on k8s03 periodically failed to write to dqlite's `kine.sock` during snapshot serialization. The error — `database is locked (exec try: 500)` — indicates that after 500 retries over ~1 second, the write timed out. In-flight watch stream heartbeats and response writes failed during these windows, causing the scheduler client to detect a stale connection and reconnect.

#### How was the dqlite database locking frequently enough to disrupt watch streams?

Two factors combined:

1. **Snapshot size**: The dqlite SQLite database is 225MB (vs 21.8MB of live data — ~10x fragmentation from years of writes without VACUUM). Serializing 225MB locks the SQLite write mutex for ~1–2 seconds every time a snapshot is taken.

2. **High write rate**: `calico-kube-controllers` was generating ~12 API write-equivalent operations per minute through a continuous crash loop. At this rate, writes were queued when a lock began, and the 500-retry limit was frequently hit before the lock released.

Together, snapshot locks that previously resolved within the retry window now exceeded it reliably.

#### How was calico-kube-controllers generating 12 writes/minute via crash loop?

The pod/workloadendpoint controller started every ~5 seconds and immediately attempted to `LIST` pods and `WorkloadEndpoints` from the API server. Both calls returned HTTP 403 Forbidden. The controller logged the RBAC error and exited. Each cycle generated API server write traffic: audit log entries, event records, status updates. The node controller (a separate goroutine) ran successfully, so the pod was always reported as Running/Ready, hiding the internal failure.

#### How was the LIST operation forbidden?

The ClusterRole `calico-kube-controllers` (at `resourceVersion: 146` — unchanged since cluster creation) had:

- `pods`: only `get` verb — `list` and `watch` were absent
- `workloadendpoints`: the entire resource was missing from the rules

The pod/workloadendpoint controller requires `list` and `watch` on `pods` to build its initial endpoint cache, and full CRUD on `workloadendpoints` to manage Calico's network endpoint records. Without these, it could not initialise.

#### How did this RBAC gap exist since cluster creation without being noticed?

Three compounding factors:

1. **The node controller masked the failure.** `calico-kube-controllers` is a single pod running multiple internal controllers. The node controller (IPAM tunnel IP management) ran successfully with the permissions it had. The pod reported `1/1 Running` and passed all readiness checks. Nothing external indicated that two of its three controllers were silently crash-looping.

2. **The dqlite lock errors were treated as background noise.** `database is locked` has appeared in the cluster logs since installation. The errors were recurring but transient — the cluster functioned — so they were never investigated as a symptom of an amplified write rate.

3. **No alerting on RBAC authorization failures.** There is no alert for `403 Forbidden` patterns in controller logs, no alert for write rate on kine.sock, and no alert for scheduler informer watch reconnection events. The failure mode was entirely invisible without manual log inspection.

#### How did four AWX jobs (1859, 1861, 1863, 1865) fail before this was investigated?

Each failed job produced an AWX failure notification, but the failures were not followed up with cluster-level investigation. The pattern of repeated AWX job failures in sequence — which strongly implies a scheduling problem rather than a job content problem — was not recognised as an incident trigger. There is no alert for "N consecutive AWX job failures for the same playbook".

---

## Impact

### Services Affected

| Service | Impact | Duration |
|---------|--------|----------|
| AWX job 1859 | Failed — pod not scheduled | Unknown (pre-incident) |
| AWX job 1861 | Failed — pod not scheduled | Unknown (pre-incident) |
| AWX job 1863 | Failed — pod not scheduled | Unknown (pre-incident) |
| AWX job 1865 ("Hardware docs update") | Failed — pod Pending 13+ min, timed out | ~13 min |
| `dependency-track-frontend` rolling update | Stalled — new RS created but pod stuck on k8s03 | ~30 min (resolved as side effect) |

### Duration

- **Silent failure period** (first failing job to discovery): Unknown — at least 4 job cycles
- **Active incident (pod creation to fix applied)**: ~8 minutes
- **Time to last lock error**: ~11 minutes post-fix
- **Total session including maintenance**: ~2 hours

### Scope

- 3-node microk8s HA cluster `pvek8s`
- AWX CI/CD automation (`ci` namespace)
- No persistent storage affected
- No user-facing homelab services affected

---

## Resolution Steps Taken

### Phase 1: Root Cause Identification

1. **Pod inspection**: `kubectl describe pod automation-job-1865-ntgbq -n ci` — zero events, zero conditions. Scheduler never attempted to schedule.

2. **Scheduler lease check**: Lease renewing normally on k8s03. Scheduler alive but informer stale.

3. **dqlite log analysis**: `database is locked (exec try: 500)` recurring ~every 1–2 minutes on k8s02 during snapshot serialization.

4. **calico-kube-controllers log analysis**: `pods is forbidden` error every ~5 seconds. ClusterRole inspection confirmed `list`/`watch` missing from `pods`; `workloadendpoints` entirely absent.

### Phase 2: Fixes Applied

5. **Calico ClusterRole patched**:
    ```bash
    kubectl --context pvek8s apply -f - <<EOF
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: calico-kube-controllers
    rules:
    - apiGroups: [""]
      resources: [nodes]
      verbs: [watch, list, get]
    - apiGroups: [""]
      resources: [pods]
      verbs: [watch, list, get]        # added list, watch
    - apiGroups: [crd.projectcalico.org]
      resources: [ippools]
      verbs: [list]
    - apiGroups: [crd.projectcalico.org]
      resources: [blockaffinities, ipamblocks, ipamhandles]
      verbs: [get, list, create, update, delete]
    - apiGroups: [crd.projectcalico.org]
      resources: [clusterinformations]
      verbs: [get, create, update]
    - apiGroups: [crd.projectcalico.org]
      resources: [workloadendpoints]   # added entire resource
      verbs: [watch, list, get, create, update, delete]
    EOF
    ```

6. **NewRelic webhook removed**:
    ```bash
    kubectl --context pvek8s delete mutatingwebhookconfiguration newrelic-bundle-nri-metadata-injection
    ```

7. **daemon-kubelite restarted on k8s03** to flush stale informer watches for scheduler and controller-manager:
    ```bash
    ssh k8s03 sudo snap restart microk8s.daemon-kubelite
    ```

8. **Stuck dependency-track-frontend pod force-deleted** (stalled on k8s03 for same reason):
    ```bash
    kubectl --context pvek8s delete pod dependency-track-frontend-... -n ci --force --grace-period=0
    ```

9. **Stuck Terminating pods cleared** (k8s03 kubelet backlog post-restart):
    ```bash
    kubectl --context pvek8s delete pod dependency-track-frontend-7d6b5bc85d-ntqvw -n ci --force --grace-period=0
    kubectl --context pvek8s delete pod dependency-track-frontend-846b56f765-v4zpr -n ci --force --grace-period=0
    kubectl --context pvek8s delete pod linkace-cronjob-29646582-8g924 -n media --force --grace-period=0
    ```

### Phase 3: Verification and Maintenance

10. **AWX job 1867 triggered manually** from AWX UI. Pod `automation-job-1867-ckj4l` reached Running within 30 seconds. Job completed successfully.

11. **Monthly maintenance play** (`microk8s-monthly-maintenance.yml`) run as rolling restart across k8s01 → k8s02 → k8s03 to refresh all informer watches cluster-wide.

---

## Verification

```
kubectl --context pvek8s get pods --all-namespaces --field-selector=status.phase=Pending
→ No resources found

kubectl --context pvek8s get nodes
→ k8s01   Ready   4y267d   v1.34.5
  k8s02   Ready   4y267d   v1.34.5
  k8s03   Ready   4y267d   v1.34.5

kubectl --context pvek8s get pods -n kube-system -l k8s-app=calico-kube-controllers
→ calico-kube-controllers-656c7f6f9f-czpvb   1/1   Running   0   ...

kubectl --context pvek8s get mutatingwebhookconfigurations
→ cert-manager-webhook   (NewRelic entry gone)
```

Lock error count on k8s02 from 07:44 onwards: **0**.

AWX job 1867 logs confirmed: `automation-job-1867-ckj4l   1/1   Running` within 30s of creation.

---

## Preventive Measures

### Immediate Actions Required

1. **Commit Calico ClusterRole fix to GitOps** (High Priority)
   - The RBAC fix was applied directly with `kubectl apply`. It is not yet in the ArgoCD GitOps manifests. ArgoCD drift detection will surface this.
   - Action: Patch the Calico manifests in the GitOps repo with the corrected ClusterRole and sync.

2. **Alert on consecutive AWX job failures** (High Priority)
   - Jobs 1859, 1861, and 1863 failed before this incident was investigated. A repeated-failure pattern is a strong signal of infrastructure, not playbook, problems.
   - Action: Add an AWX/webhook alert for N ≥ 2 consecutive failures of the same template. Route to homelab alerting channel.

3. **Alert on kube-apiserver RBAC 403 rate** (High Priority)
   - The calico-kube-controllers crash loop generated hundreds of 403 errors per hour for an unknown period. No alert fired.
   - Action: Add Prometheus alert for `apiserver_request_total{code="403"} > 10/min` sustained over 5 minutes, with label filter for system service accounts.

4. **Alert on dqlite write error rate** (Medium Priority)
   - `database is locked` in kubelite logs is a direct signal that snapshot serialization is interfering with API server writes. Currently treated as background noise.
   - Action: Add log-based alert (Loki/Promtail or similar) for `database is locked` occurrences > 5 in any 5-minute window.

### Longer-Term Improvements

5. **Reduce dqlite snapshot size via microk8s upgrade** (High Priority)
   - The snapshot is 225MB vs 21.8MB of live data (~10x fragmentation). This is the underlying reason snapshots cause long lock windows.
   - The monthly maintenance rolling-restart play **does not fix this** — each restarted node re-syncs from the leader's un-vacuumed snapshot, discarding its local VACUUM. Online VACUUM via cowsql is not supported. Offline simultaneous VACUUM breaks Raft consensus (confirmed April 2026).
   - Action: Upgrade microk8s to a current snap revision. Newer k8s-dqlite versions have improved snapshot compaction and WAL management. This is the only safe path to snapshot size reduction.

6. **Implement Calico IPAM GC** (Medium Priority)
   - 838 stale IPAM handles (pod IP allocation records from deleted pods) remain. These should self-GC now that `calico-kube-controllers` has correct RBAC and the workloadendpoint controller is functional.
   - Manual cleanup with `calicoctl ipam check --allow-version-mismatch` is blocked by the v3.32 client vs v3.13.2 cluster version mismatch.
   - Action: Install calicoctl v3.13.x locally, or use the version bundled in the calico-node pod, and run `calicoctl ipam check` + `release --leaked` to explicitly clean stale handles.

7. **Alert on scheduler informer watch reconnections** (Medium Priority)
   - The scheduler silently lost its pod informer and never recovered without a restart. This failure mode is invisible without active log monitoring.
   - Action: Add alert for kube-scheduler log pattern `Failed to watch *v1.Pod` or `watch chan error`. If the scheduler reconnects more than once per 10 minutes, something is disrupting the watch stream.

8. **Investigate and resolve recurring scheduler leader elections** (High Priority)
   - 4,499 scheduler leader elections since cluster install is abnormal. Even after this fix, the underlying dqlite snapshot locking will continue to cause occasional missed renewals.
   - The long-term fix is snapshot size reduction (item 5). Monitoring the election rate post-fix will confirm whether the Calico RBAC was the dominant contributor.

9. **AWX job failure runbook** (Low Priority)
   - No runbook existed for "AWX pod stuck Pending". Diagnosis required ad-hoc investigation.
   - Action: Add runbook entry: if AWX pod Pending > 2 min with no events → check scheduler lease, check dqlite lock errors, check calico-kube-controllers logs, check node conditions.

---

## Lessons Learned

### What Went Well

- **Root cause found quickly once investigation started**: From "pod is Pending" to "Calico RBAC is broken" took ~6 minutes. The causal chain from dqlite locks → write storm → calico crash loop → RBAC was clear from log evidence.
- **Fix was surgical and low-risk**: Patching a ClusterRole is non-disruptive. No application restarts, no data risk, no downtime beyond the kubelite restart on k8s03 (~30s).
- **No data loss or persistent storage impact**: Calico networking itself was functioning correctly — only the IPAM GC and workloadendpoint tracking controllers were broken. No pod-to-pod connectivity issues occurred.
- **AWX confirmed fixed on first retry**: The clean retry (job 1867) proved the fix immediately without needing to wait for another scheduled run.

### What Didn't Go Well

- **Three prior job failures went uninvestigated**: Jobs 1859, 1861, and 1863 each failed before 1865. If job 1859's failure had triggered a cluster investigation, the RBAC gap would have been found on the same day. The assumption that "AWX job failures = playbook problems" is not safe when failures are consecutive.
- **A cluster-level configuration gap existed since creation**: The Calico ClusterRole has been broken since `resourceVersion: 146`. This is at minimum months of accumulated write pressure from the crash loop. The absence of any RBAC validation in the cluster install or post-install verification process allowed this to go undetected.
- **dqlite lock errors were normalised**: "database is locked" appearing in logs had been treated as an expected characteristic of the cluster rather than a signal worth investigating. It had been present for long enough that it became invisible background noise.
- **Monthly maintenance play does not fix SQLite fragmentation**: It was assumed the rolling-restart maintenance play would reduce snapshot size as it had in April 2026. In April, the size reduction came from deleting 5,472 IPAM handles (actual data removal) before running the play. With only 838 handles today and no data bulk-deletion step, there was nothing for the VACUUM to compact. This distinction was not understood until observed.

### Surprise Findings

- **calico-kube-controllers showed 1/1 Running despite two internal controllers crash-looping**: Kubernetes readiness probes check the process, not internal controller state. A pod can report fully healthy while half its business logic is in a tight error loop. The node controller's success was sufficient to pass the health check.
- **Rolling restart cannot compact a fragmented SQLite database in a Raft cluster**: Each node, on restart, re-syncs from the leader. Any local VACUUM is immediately overwritten by the leader's snapshot. This makes the standard "restart fixes things" intuition wrong for this specific problem — the only way to compact is to upgrade to a version with better native compaction, or stop all three nodes simultaneously (which risks Raft quorum loss as observed in April 2026).
- **The scheduler informer gap is deterministic, not random**: Once the watch stream drops during a lock window and the scheduler reconnects, pods created during that gap are silently lost from the scheduling queue. They will never be scheduled without manual intervention (delete the pod, recreate it, or restart the scheduler). This is not a probabilistic race — it is a guaranteed miss when reconnect occurs after the pod ADD event.

---

## Action Items

| # | Action | Priority | Owner |
|---|--------|----------|-------|
| 1 | Commit Calico ClusterRole fix to GitOps manifests | High | @pgmac |
| 2 | Alert: N ≥ 2 consecutive AWX job failures for same template | High | @pgmac |
| 3 | Alert: apiserver RBAC 403 rate > 10/min for system service accounts | High | @pgmac |
| 4 | Alert: `database is locked` > 5 occurrences in 5-min window | Medium | @pgmac |
| 5 | Alert: kube-scheduler watch reconnection > 1/10min | Medium | @pgmac |
| 6 | Plan and schedule microk8s upgrade to reduce dqlite snapshot size | High | @pgmac |
| 7 | Install calicoctl v3.13.x, run `ipam check` + `release --leaked` | Medium | @pgmac |
| 8 | Add AWX Pending pod runbook to incident response docs | Low | @pgmac |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes)
- **Kubernetes version:** v1.34.5
- **Container runtime:** containerd 1.7.28
- **Calico version:** v3.13.2
- **dqlite snap revision:** 8695
- **AWX:** pgawx (ci namespace)

### dqlite Database State at Incident

| Metric | Value |
|--------|-------|
| Snapshot size | 225MB |
| Live data (kine rows, `deleted=0`) | 21.8MB (3,732 rows) |
| Fragmentation ratio | ~10x |
| Raft log index | ~2,133,866,000 |
| Scheduler leader elections (lifetime) | 4,499 |
| Last snapshot interval | ~2 min (every ~500 raft entries) |
| Lock error frequency (pre-fix) | ~1–2 per minute |
| Lock error frequency (post-fix) | 0 |

### Calico RBAC Before/After

**Before (broken since cluster creation, `resourceVersion: 146`):**

```yaml
rules:
- apiGroups: [""]
  resources: [pods]
  verbs: [get]                    # missing list, watch
# workloadendpoints: entirely absent
```

**After (fixed):**

```yaml
rules:
- apiGroups: [""]
  resources: [pods]
  verbs: [watch, list, get]       # added list, watch
- apiGroups: [crd.projectcalico.org]
  resources: [workloadendpoints]  # added
  verbs: [watch, list, get, create, update, delete]
```

### Key Error Signatures

**calico-kube-controllers (every ~5 seconds, pre-fix):**
```
pods is forbidden: User "system:serviceaccount:kube-system:calico-kube-controllers"
cannot list resource "pods" in API group "" at the cluster scope
```

**k8s02 kubelite — dqlite lock (every ~1–2 min, pre-fix):**
```
rpc error: code = Unknown desc = update transaction failed for key
/registry/leases/kube-system/kube-controller-manager:
exec (try: 500): database is locked
```

---

## References

- Related incident (dqlite snapshot bloat, crash-loop cascade): [dqlite Snapshot Bloat → kube-apiserver Instability → Controller Crash-Loop Cascade and Watch Stream Failure](2026-04-02-dqlite-snapshot-crash-loop-watch-stream-failure.md)
- Related incident (dqlite quorum loss, invalid Ansible flags): [pvek8s Complete Cluster Outage — dqlite Quorum Loss and Ansible-Injected Invalid Flags](2026-04-12-pvek8s-dqlite-quorum-loss-complete-cluster-outage.md)
- Linear ticket: [PGM-181](https://linear.app/pgmac-net-au/issue/PGM-181)
- Calico v3.13 RBAC reference: https://projectcalico.docs.tigera.io/archive/v3.13/reference/resources/clusterrole

---

## Reviewers

- @pgmac
