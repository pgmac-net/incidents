# Post Incident Review: ARC GitHub Actions Runner Pods Stuck Pending — Kubelet Sync Loop Stall and Multi-Node Degradation

**Date:** 2026-03-28
**Duration:** ~7h40m (07:07 AEST → 14:47 AEST)
**Severity:** High (GitHub Actions CI/CD completely unavailable — all self-hosted runners unable to start)
**Status:** Resolved

---

## Executive Summary

Five GitHub Actions Runner Controller (ARC) pods entered `Pending` state and remained there for over 7 hours. The ARC stack — two runner pods, two listener pods, and one controller pod — was completely stalled, rendering all self-hosted CI/CD workflows inoperable.

The incident had a layered root cause. The initial trigger was **disk exhaustion on k8s02**, which prevented the containerd image GC from freeing space and caused image pulls to fail. Investigation and recovery attempts introduced secondary failures: **Calico networking disruption on k8s02**, **recurring PLEG desync on k8s03**, and critically — a **ghost container on k8s01** that stalled the kubelet's pod sync loop. The ghost container was an orphaned containerd record left behind after a force-delete of the ARC controller pod while it was actively running. This orphaned container caused the kubelet to error every 60 seconds in `manager.go`, blocking it from processing new pod assignments for ~15 minutes until identified and cleared.

Final resolution required:

1. Deleting the ghost container from containerd's `k8s.io` namespace on k8s01
2. Restarting kubelite on k8s01 to flush orphaned in-memory pod state
3. Patching the ARC controller deployment with a `nodeSelector` for k8s01 (the only fully stable node)
4. Disabling the Wazuh audit webhook, which had been returning 500 errors on every API server event across all three nodes
5. Uncordoning k8s02 and k8s03 after node-level stabilisation

---

## Timeline (AEST — UTC+10)

| Time | Event |
|------|-------|
| **~07:07** | **ROOT EVENT**: 5 ARC pods enter `Pending` state. `FreeDiskSpaceFailed` begins firing on k8s02 — kubelet unable to free 16.2 GiB, 0 bytes eligible (all images in use). |
| ~07:07 | `self-hosted-754b578d-listener` and `self-hosted-8ds97-runner-5zs9b` scheduled to k8s03 but never reach `ContainerCreating`. Three runner pods (`g7d9b`, `jjw6x`, `mg5q4`) remain unscheduled. |
| ~07:10 | k8s02 kubelet last Ready transition — `KubeletReady` event posted. |
| ~07:10 → 10:39 | `FreeDiskSpaceFailed` continues firing on k8s02 every ~5 minutes (x36 occurrences). No alerting triggers. |
| **~10:39** | Analysis begins. Error detective identifies disk exhaustion on k8s02 as primary cause, PLEG issues on k8s03 as secondary. |
| Investigation | k8s03 PLEG fixed: containerd restarted, then kubelite restarted on k8s03. |
| Investigation | k8s02 Calico networking broken (new pods unable to reach API server). Calico-node pod restarted on k8s02. k8s02 cordoned to prevent further scheduling. |
| Investigation | k8s01 controller-manager informer stale (RS not created). kubelite restarted on k8s01, triggering fresh informer resync → RS `74ddc5d4df` created. |
| Investigation | ARC controller pod `74ddc5d4df-5jtvj` Running, creates listener pod, watch stream breaks. Controller pod force-deleted. |
| **~14:02 UTC** | New controller pod `74ddc5d4df-zqr78` starts on k8s01 (1/1 Running). Listener pod `self-hosted-754b578d-listener` scheduled to k8s01, enters `Pending`. No `ContainerCreating` event for 9+ minutes. |
| ~14:04 UTC | Kubelet on k8s01 logging `manager.go:1116: Failed to create existing container: task 621a9a... not found` every 60 seconds — ghost container from force-deleted pod `33695e61`. |
| ~14:11 UTC | Ghost container (`621a9a644b80...`) confirmed in containerd `k8s.io` namespace with no running task. Deleted: `microk8s ctr --namespace k8s.io containers rm 621a9a...`. Ghost container errors stop. |
| ~14:12 UTC | Listener pod still Pending — kubelet silent (no logs about the pod). Kubelet's internal state still holds orphaned pod `33695e61`. |
| ~14:17 UTC | Listener pod force-deleted and recreated by ARC controller. Still Pending — confirms kubelet sync loop is blocked by orphaned pod state, not just the container record. |
| **~14:20 UTC** | kubelite restarted on k8s01 to flush orphaned in-memory pod state. |
| **~14:20 UTC** | Listener pod `self-hosted-754b578d-listener` reaches `ContainerCreating` and starts: **1/1 Running** at 10.1.74.140. |
| ~14:21 UTC | Listener logs show active job completions from pgmac-net/ansible workflows (`vuln`, `iac`). |
| ~14:25 UTC | Stale RS pod `66cf67ccbf-lw86v` confirmed gone. arc-runners namespace empty (runner `5zs9b` completed normally). |
| ~14:30 UTC | Wazuh audit webhook (`--audit-webhook-config-file`, `--audit-webhook-batch-max-size`) removed from kube-apiserver args on all three nodes. kubelite restarted sequentially (k8s01 → k8s02 → k8s03). |
| **~14:47 UTC** | k8s02 and k8s03 uncordoned. All three nodes Ready, no scheduling restrictions. **Incident resolved.** |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting the surface answer. Keep drilling until reaching an actionable, preventable cause._

#### How did GitHub Actions CI/CD become unavailable?

The ARC listener pod and all runner pods were stuck in `Pending` for 7+ hours. Without a running listener, the ARC controller cannot register runners with GitHub or dispatch JIT tokens. No jobs could execute.

#### How did the ARC pods get stuck in Pending?

Three separate node-level failure modes converged:

- **k8s02**: Disk exhaustion — containerd image store full, kubelet image GC unable to free any bytes (all images referenced by running pods). Image pulls for new pods failed silently.
- **k8s03**: PLEG desync — containerd and kubelite fell out of sync after multiple restarts during investigation. The kubelet could not receive container lifecycle events, preventing pods from progressing.
- **k8s01**: Ghost container in kubelet sync loop — the kubelet's `manager.go` sync goroutine errored every 60 seconds attempting to reconcile an orphaned container record, blocking pod processing.

#### How did k8s02 reach disk exhaustion?

The containerd image store accumulated images over time without effective garbage collection. At 85% disk usage (63G used of 78G), the kubelet's image GC high-threshold was breached. The GC attempted to free 16.2 GiB but found zero eligible images — all 187 images were actively referenced by running pods (openebs replica controllers, vaultwarden, and other long-running workloads). No alert fired; the first indication was `FreeDiskSpaceFailed` events in the Kubernetes event stream, only visible via active investigation.

#### How did the kubelet find zero images eligible for GC?

OpenEBS Jiva uses a hub-and-spoke model: each PVC has a controller pod and 3 replica pods, each holding a copy of the storage volume. On k8s02 this meant ~20+ openebs pods, each referencing its own image. These pods run continuously and are never evicted. Over time, as new images were pulled for ephemeral ARC runner workloads (`docker:dind`, `ghcr.io/actions/actions-runner`), the store filled with images that could not be reclaimed without stopping openebs pods — which would degrade PVC availability.

#### How did the ghost container on k8s01 end up blocking the kubelet?

During recovery, the ARC controller pod `74ddc5d4df-5jtvj` was force-deleted (`--grace-period=0 --force`) while it was in `Running` state (1/1 Ready). Force-deleting a Running pod removes the pod object from etcd immediately, but containerd on the host node still holds an active container record for the pod's container. When kubelite was subsequently restarted on k8s01, the kubelet read containerd's state and found the orphaned container `621a9a644b80...` (associated with cgroup path `/kubepods/besteffort/pod33695e61-f79a-4447-b42f-551ef9f58db6/`). It tried to reconcile this container via `manager.go:EnsureContainerState()`, but the runc task was gone — yielding `task 621a9a... not found` every 60 seconds.

#### How did this ghost container block processing of the new listener pod?

The kubelet's container manager sync loop runs per-pod. For the orphaned pod `33695e61`, the sync goroutine errored and retried indefinitely on its 60-second cycle. While the error itself did not lock the entire kubelet, it consumed the sync goroutine for that pod. More critically, after deleting the container record from containerd (`microk8s ctr --namespace k8s.io containers rm`), the kubelet's in-memory state still held pod `33695e61`. The kubelet had no mechanism to reconcile "container deleted from containerd but pod still in memory" without restarting, and this in-memory stale state prevented it from processing new pod assignments received via its API server watch stream.

#### How did force-deleting a Running pod leave an orphaned container?

Force-deletion bypasses the graceful termination lifecycle. Normally, when a pod is deleted, the API server sets a `deletionTimestamp`, the kubelet receives the update, sends `SIGTERM` to containers, waits for `terminationGracePeriodSeconds`, then removes the pod from containerd and reports back to the API server to finalise deletion. With `--grace-period=0 --force`, the pod object is removed from etcd immediately, and the kubelet never receives the graceful termination signal. If the kubelet is restarted before it can complete cleanup of the old pod, the container record persists in containerd indefinitely.

#### How did the Wazuh audit webhook compound the incident?

The Wazuh webhook (`172.22.22.57:8080`) was configured with `--audit-webhook-batch-max-size=1` (synchronous-like delivery) on all three API servers. The Wazuh service was returning HTTP 500 for all requests. Every API server event — including each `kubectl get pods` during investigation — triggered a webhook delivery attempt, a 500 response, and an error log entry. This flooded the kubelite logs, obscuring genuine error signals (ghost container errors, PLEG warnings) and significantly increased diagnostic noise throughout the incident.

### Secondary Findings

#### k8s02 Calico networking failure (investigator-introduced)

During investigation, multiple kubelite restarts on k8s02 caused the calico-node pod (`calico-node-898mx`) to lose its network programming state. New pods on k8s02 could not reach the Kubernetes API server (10.152.183.1) or other nodes. This was not present at incident start — it was introduced by iterative restarts. Fixed by deleting the calico-node pod and allowing it to reschedule fresh.

#### k8s03 PLEG recurrence (investigator-introduced)

k8s03 experienced PLEG desync multiple times during investigation, each time requiring a sequential restart of containerd followed by kubelite. The PLEG desync was triggered by kubelite restarts that left containerd and the kubelet's container view out of sync. Cordoning k8s03 between fixes and uncordoning only once stable stopped the recurrence.

---

## Impact

### Services Affected

| Service | Impact | Duration |
|---------|--------|----------|
| GitHub Actions self-hosted runners (`pgmac-net` org) | Complete unavailability — no CI/CD jobs could execute | ~7h40m |
| ARC listener | Unable to communicate with GitHub Actions API | ~7h40m |
| ARC controller | Unable to dispatch JIT tokens / register runners | Partial — controller eventually Running but unable to complete setup |
| Wazuh audit log delivery | All audit events silently dropped (500 responses) | Pre-existing, unrelated duration |

### Duration

- **Silent failure period**: ~07:07 → ~10:39 AEST (~3h32m) — no alerting, incident discovered manually
- **Active investigation and recovery**: ~10:39 AEST → ~14:47 AEST (~4h8m)
- **Total incident duration**: ~7h40m

### Scope

- 3-node microk8s HA cluster `pvek8s`
- ARC stack (`arc-systems`, `arc-runners` namespaces)
- No persistent storage impacted
- No user-facing homelab services affected (openebs volumes, vaultwarden, etc. unaffected)

---

## Resolution Steps Taken

### Phase 1: Root Cause Identification

1. **Error detective analysis** of cluster events, pod states, and node conditions identified:
   - `FreeDiskSpaceFailed` on k8s02 (x36, recurring every ~5 min)
   - Pods scheduled to k8s03 (`runner-5zs9b`, listener) with `PodScheduled: True` but no IP
   - Three runner pods with `Node: <none>` (never scheduled)
   - No `FailedScheduling` events, no image pull errors, no PVC issues
   - All nodes reporting `DiskPressure: False` (kubelet threshold not yet breached, misleading)

### Phase 2: Node Stabilisation

2. **k8s03 PLEG fix**: Restarted containerd then kubelite on k8s03 in sequence.

3. **k8s02 Calico fix**: Deleted `calico-node-898mx` pod on k8s02; replacement pod `calico-node-l496l` started 1/1 Ready. k8s02 cordoned to prevent further scheduling while disk remains full.

4. **k8s01 controller-manager resync**: Restarted kubelite on k8s01. Controller-manager informer refreshed; RS `74ddc5d4df` created; ARC controller pod scheduled and reached Running.

### Phase 3: ARC Controller Deployment Stabilisation

5. **Patched ARC controller deployment** with `nodeSelector` for k8s01 (only fully stable node):
    ```bash
    kubectl --context pvek8s patch deployment gharc-controller-gha-rs-controller \
      -n arc-systems --type=merge \
      -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"k8s01"}}}}}'
    ```

6. **Force-deleted stale controller pod** `5jtvj` after its watch stream broke post-listener-creation.

### Phase 4: Ghost Container Removal

7. **Identified ghost container** in kubelet logs — `manager.go:1116` error every 60s:
    ```
    Failed to create existing container:
    /kubepods/besteffort/pod33695e61-.../621a9a644b80...: task 621a9a... not found
    ```

8. **Confirmed container in containerd** `k8s.io` namespace with no running task:
    ```bash
    ssh k8s01 'sudo microk8s ctr --namespace k8s.io containers ls | grep 621a9a'
    ```

9. **Deleted ghost container**:
    ```bash
    ssh k8s01 'sudo microk8s ctr --namespace k8s.io containers rm \
      621a9a644b80c35958dbb7f70d661d345fde64fcc0a325b603d8e5f74968aca3'
    ```

10. **Confirmed ghost errors stopped** in kubelite logs.

11. **Restarted kubelite on k8s01** to flush orphaned pod `33695e61` from in-memory state (container deletion alone was insufficient — kubelet's in-memory state still blocked new pod processing):
    ```bash
    ssh k8s01 'sudo systemctl restart snap.microk8s.daemon-kubelite'
    ```

12. **Listener pod** transitioned to `ContainerCreating` and reached `1/1 Running` within 45 seconds of restart.

### Phase 5: Audit Webhook Removal

13. **Removed Wazuh audit webhook config** from all three nodes:
    ```bash
    for node in k8s01 k8s02 k8s03; do
      ssh $node 'sudo sed -i "/--audit-webhook-config-file\|--audit-webhook-batch-max-size/d" \
        /var/snap/microk8s/current/args/kube-apiserver'
    done
    ```

14. **Restarted kubelite sequentially** (k8s01 → k8s02 → k8s03, 30s between each) to reload API server config.

### Phase 6: Cluster Restoration

15. **Uncordoned k8s03** (PLEG stable, no errors in 5-minute window).

16. **Uncordoned k8s02** (Calico networking restored; disk at 85% — flagged for separate cleanup).

---

## Verification

### ARC Stack Health

```
NAME                                                  READY   STATUS    RESTARTS   AGE
gharc-controller-gha-rs-controller-74ddc5d4df-zqr78   1/1     Running   0          25m
self-hosted-754b578d-listener                         1/1     Running   0          9m47s
```

Listener logs confirmed active job processing:
```
Job completed message received. {"JobID": "077390cb-...", "Result": "succeeded", "RunnerName": "self-hosted-8ds97-runner-rqrwc"}
Job completed message received. {"JobID": "8666b680-...", "Result": "succeeded", "RunnerName": "self-hosted-8ds97-runner-qnvwv"}
```

### Node Health

```
NAME    STATUS   ROLES    AGE      VERSION
k8s01   Ready    <none>   4y219d   v1.34.5
k8s02   Ready    <none>   4y219d   v1.34.5
k8s03   Ready    <none>   4y219d   v1.34.5
```

### Audit Webhook Silenced

Post-restart kubelite logs: no `Error in audit plugin 'webhook'` entries observed.

---

## Preventive Measures

### Immediate Actions Required

1. **k8s02 disk cleanup** (High Priority)
   - k8s02 remains at 85% disk utilisation (63G used, 12G free). Kubelet image GC will continue to fail.
   - Action: Drain openebs replica pods temporarily, run `microk8s ctr --namespace k8s.io images prune`, allow pods to reschedule.
   - Risk if ignored: As ephemeral runner images accumulate, k8s02 will reach 100% and new pods will fail to pull images.

2. **Avoid force-deleting Running pods** (High Priority)
   - `kubectl delete pod --force --grace-period=0` on a Running pod leaves orphaned container records in containerd if kubelite is restarted before cleanup completes.
   - Action: Prefer graceful deletion (`kubectl delete pod`). Only use force-delete for pods that are already in `Terminating` or `Unknown` state.
   - If force-delete is necessary on a Running pod, immediately check containerd state: `microk8s ctr --namespace k8s.io containers ls` and clean up any orphaned records before restarting kubelite.

3. **Disk pressure alerting** (High Priority)
   - No alert fired during 3h32m of silent `FreeDiskSpaceFailed` events.
   - Action: Deploy Prometheus node-exporter with alert rule for `node_filesystem_avail_bytes / node_filesystem_size_bytes < 0.20` on all nodes.
   - Add dedicated alert for kubelet `imageGCFailed` condition.

4. **Kubelet imageGC threshold tuning** (Medium Priority)
   - Default thresholds (85% high, 80% low) are too close to k8s02's baseline usage given openebs pod density.
   - Action: Lower thresholds in `/var/snap/microk8s/current/args/kubelet`:
     ```
     --image-gc-high-threshold=75
     --image-gc-low-threshold=70
     ```
   - Alternatively, migrate openebs images to a dedicated node to reduce image density on k8s02.

### Longer-Term Improvements

5. **Ephemeral runner image cleanup** (Medium Priority)
   - ARC ephemeral runners pull `docker:dind` and `ghcr.io/actions/actions-runner` on every scale event. These images accumulate layers.
   - Action: Deploy a CronJob to periodically prune ARC-related images on all nodes:
     ```bash
     microk8s ctr --namespace k8s.io images rm $(microk8s ctr --namespace k8s.io images ls | grep 'actions-runner\|docker.*dind' | awk '{print $1}')
     ```
   - Schedule: weekly, with a check that no runner pods are active before pruning.

6. **Structured node restart procedure** (High Priority)
   - Multiple investigator-introduced failures (Calico networking on k8s02, PLEG on k8s03) resulted from uncoordinated kubelite restarts without verifying containerd state first.
   - Action: Document and follow a node restart runbook:
     1. Cordon node before restarting kubelite
     2. Restart containerd first, wait for all containerd tasks to show RUNNING
     3. Restart kubelite
     4. Verify all pods on node reach Ready before uncordoning
     5. Check `microk8s ctr --namespace k8s.io containers ls` for orphaned records

7. **Wazuh audit webhook monitoring** (Medium Priority)
   - The webhook was silently dropping 100% of audit events via 500 responses. No alert existed.
   - Action: Add health check for Wazuh webhook endpoint. If endpoint returns non-2xx, alert immediately — audit logging is a security control.
   - If Wazuh webhook is re-enabled: set `--audit-webhook-batch-max-size` to a higher value (e.g. 100) and use async mode to prevent blocking API server event processing.

8. **ARC controller node affinity** (Low Priority)
   - The `nodeSelector` applied during this incident (`kubernetes.io/hostname: k8s01`) is a workaround, not a solution. It creates a single point of failure for CI/CD.
   - Action: Replace nodeSelector with node affinity + anti-affinity rules that prefer stable nodes and spread across the cluster. Add pod disruption budgets for ARC controller.
   - Commit the nodeSelector patch to ArgoCD GitOps manifests (current patch is applied directly to the cluster, not via ArgoCD).

9. **PLEG monitoring** (Medium Priority)
   - k8s03 experienced PLEG desync multiple times, each requiring manual intervention.
   - Action: Add alert for `kubelet_pleg_relist_duration_seconds` exceeding 5 seconds, or for kubelet log pattern `PLEG is not healthy`.

10. **Runbook: Ghost container cleanup** (High Priority)
    - No documented procedure existed for identifying and removing orphaned containerd containers that block kubelet sync loops.
    - Action: Add runbook entry:
      ```bash
      # Identify ghost containers (in k8s.io namespace, task not found)
      microk8s ctr --namespace k8s.io containers ls
      microk8s ctr --namespace k8s.io tasks ls
      # Compare — any container ID without a matching task is a ghost
      # Remove:
      microk8s ctr --namespace k8s.io containers rm <container-id>
      # If kubelet still stuck, restart kubelite
      sudo systemctl restart snap.microk8s.daemon-kubelite
      ```

---

## Lessons Learned

### What Went Well

- **Root cause was eventually found**: Despite multiple red herrings and investigator-introduced failures, the ghost container blocking the kubelet sync loop was identified through careful log analysis.
- **No data loss**: Persistent storage (openebs volumes) was unaffected throughout. No application data was at risk.
- **ArgoCD preserved deployment intent**: The ARC controller deployment in ArgoCD maintained the desired state. The `nodeSelector` workaround was applied directly to the cluster; ArgoCD drift will surface it for review.
- **Cluster HA held**: The 3-node dqlite Raft cluster maintained quorum throughout sequential API server restarts.

### What Didn't Go Well

- **No alerting for 3h32m**: The `FreeDiskSpaceFailed` events fired 36 times before anyone looked. A disk alert would have reduced incident duration by hours.
- **Force-delete on a Running pod introduced a new failure mode**: Using `--force --grace-period=0` on a Running pod should be a last resort. It was used too early in the recovery process, introducing the ghost container that became the hardest problem to diagnose.
- **Iterative restarts without a checklist caused regression**: Restarting kubelite on k8s02 and k8s03 multiple times without first verifying containerd state resulted in Calico networking failure and repeated PLEG desyncs. Each "fix" introduced a new problem.
- **Wazuh webhook noise obscured diagnostics**: The flood of 500-error audit log lines made it significantly harder to identify the ghost container errors in the kubelite logs. A better filtering strategy (or disabling the webhook at incident start) would have shortened diagnosis time.
- **nodeSelector change not committed to GitOps**: The deployment patch was applied directly with `kubectl patch`. ArgoCD will eventually drift-detect this and may revert it if auto-sync is enabled.

### Surprise Findings

- **`DiskPressure: False` is misleading**: k8s02 reported `DiskPressure: False` even while `FreeDiskSpaceFailed` was firing repeatedly. The kubelet's eviction threshold (default 10% free) was not yet breached, but the image GC threshold (default 85%) was. These are separate systems — a node can be failing to GC images while still reporting healthy to the scheduler.
- **Ghost container had wrong image label**: The orphaned container `621a9a...` showed `docker.io/tautulli/tautulli:v2.16.1` as its image in `microk8s ctr containers ls`. This was unexpected (the ARC controller pod uses `gha-runner-scale-set-controller`). This may indicate image metadata is stored by hash rather than by original image reference, or a coincidental ID collision.
- **Container deletion alone was insufficient**: Removing the ghost container from containerd stopped the 60-second error loop, but the kubelet's in-memory pod state (`pod33695e61`) still blocked new pod processing. A kubelite restart was required in addition to the containerd cleanup.

---

## Action Items

| # | Action | Priority | Owner |
|---|--------|----------|-------|
| 1 | Clean k8s02 disk (drain openebs replicas + image prune) | High | @pgmac |
| 2 | Add disk utilisation alert (>80% on any node) | High | @pgmac |
| 3 | Add kubelet imageGCFailed alert | High | @pgmac |
| 4 | Document ghost container cleanup runbook | High | @pgmac |
| 5 | Add node restart checklist to runbooks | High | @pgmac |
| 6 | Commit ARC controller nodeSelector to ArgoCD manifests | Medium | @pgmac |
| 7 | Tune kubelet imageGC thresholds on all nodes (75%/70%) | Medium | @pgmac |
| 8 | Deploy ephemeral runner image prune CronJob | Medium | @pgmac |
| 9 | Add PLEG health alert | Medium | @pgmac |
| 10 | Add Wazuh webhook health check / re-enable with async config | Medium | @pgmac |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes)
- **Kubernetes version:** v1.34.5
- **Container runtime:** containerd 1.7.28
- **ARC version:** 0.13.0
- **Scale-set:** `self-hosted` (org: `pgmac-net`)
- **Storage backend:** OpenEBS Jiva (PVCs) + dqlite (etcd replacement)

### Nodes at Incident Start

| Node | IP | CPU Req | Mem Req | Pods | Issues |
|------|----|---------|---------|------|--------|
| k8s01 | 172.22.22.6 | 32% | 31% | ~? | Controller-manager informer stale |
| k8s02 | 172.22.22.8 | 34% | 9% | 72 | Disk 85% full, image GC failing |
| k8s03 | 172.22.22.9 | 13% | 1% | 28 | PLEG desync |

### Affected Pods at Incident Start

| Namespace | Pod | Node | Status | Root Cause |
|-----------|-----|------|--------|------------|
| arc-runners | self-hosted-8ds97-runner-5zs9b | k8s03 | Pending (Scheduled) | PLEG on k8s03 |
| arc-runners | self-hosted-8ds97-runner-g7d9b | None | Pending (Unscheduled) | Listener stuck; JIT token unavailable |
| arc-runners | self-hosted-8ds97-runner-jjw6x | None | Pending (Unscheduled) | Listener stuck; JIT token unavailable |
| arc-runners | self-hosted-8ds97-runner-mg5q4 | None | Pending (Unscheduled) | Listener stuck; JIT token unavailable |
| arc-systems | self-hosted-754b578d-listener | k8s03 | Pending (Scheduled) | PLEG on k8s03 |

### Key Error Signatures

**k8s02 — Image GC failure (recurring every ~5 min):**
```
E kubelet.go:1611 "Image garbage collection failed multiple times in a row"
err="Failed to garbage collect required amount of images.
Attempted to free 16430601830 bytes, but only found 0 bytes eligible to free."
```

**k8s01 — Ghost container sync loop (every 60s):**
```
E manager.go:1116 Failed to create existing container:
/kubepods/besteffort/pod33695e61-f79a-4447-b42f-551ef9f58db6/621a9a644b80c35958dbb7f70d661d345fde64fcc0a325b603d8e5f74968aca3:
task 621a9a644b80c35958dbb7f70d661d345fde64fcc0a325b603d8e5f74968aca3 not found
```

**All nodes — Wazuh webhook (every ~20s):**
```
E metrics.go:110 Error in audit plugin 'webhook' affecting 1 audit events:
an error on the server ("500 Internal Server Error") has prevented the request from succeeding
```

---

## References

- Related incident (previous cascade failure, ARC orphaned pods): `incidents/src/incidents/2026-01-06-cluster-cascade-failure.md`
- ARC (GitHub Actions Runner Controller) v0.13.0: https://github.com/actions/actions-runner-controller
- microk8s kubelite: https://microk8s.io/docs/high-availability
- Kubernetes kubelet image GC: https://kubernetes.io/docs/concepts/architecture/garbage-collection/#container-image-garbage-collection

---

## Reviewers

- @pgmac

---

## Notes

### On "DiskPressure: False" While Image GC Fails

The kubelet has two separate disk pressure systems:

1. **Node condition `DiskPressure`** — driven by eviction thresholds (`--eviction-hard=imagefs.available<10%`). This affects scheduling and appears in `kubectl get nodes`. Not breached here.
2. **Image GC** — driven by `imageGCHighThresholdPercent` (default 85%) and `imageGCLowThresholdPercent` (default 80%). This runs independently and can fail without setting `DiskPressure: True`.

This means a node can appear healthy to the scheduler while its image store is full and image pulls are failing. Do not rely on `kubectl get nodes` conditions alone to assess whether a node can accept new pods that require image pulls.

### On Kubelet In-Memory State vs Containerd State

When a pod is force-deleted, two separate state stores become inconsistent:

1. **etcd/apiserver** — pod record removed immediately
2. **containerd** — container records persist until kubelet cleans them up
3. **kubelet in-memory** — pod tracked in `podManager` and `statusManager` until explicitly cleared

Deleting the containerd container record (step 3) resolves the per-container error, but the kubelet's in-memory pod map still holds the orphaned pod entry. This stale entry can interfere with processing of new pod assignments on the same goroutine. A kubelite restart is the cleanest way to flush it.
