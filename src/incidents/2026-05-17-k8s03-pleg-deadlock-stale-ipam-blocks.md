---
tags:
  - k8s03
  - calico
  - ipam
  - pleg
  - containerd
  - generic-pleg
  - kine
  - dqlite
  - cni
---

# Post Incident Review: k8s03 PLEG Deadlock — Stale Calico IPAM Blocks + Generic PLEG Serial-Poll Vulnerability

**Date:** 2026-05-17 (resolved 2026-05-18)
**Duration:** ~9 hours active (23:30 AEST 2026-05-17 → 08:45 AEST 2026-05-18)
**Severity:** High (k8s03 node deadlocked; recurring across multiple restart attempts; workloads disrupted)
**Status:** Partially Resolved (PLEG recovered, IPAM cleaned; k8s03 cordoned pending stability confirmation)

---

## Executive Summary

Following resolution of PGM-195 (cordon-before-restart procedure for kubelite), k8s03 continued to deadlock under a separate and deeper root cause: Generic PLEG's serial `ListPodSandboxes` poll was being blocked by Calico IPAM operations in containerd's CNI path. Every pod CNI ADD on k8s03 was forced to iterate through 3 completely full IPAM blocks (64/64 used each) before finding free space, generating 3 extra kine/dqlite API calls per CNI event. During any dqlite latency window (compaction, leader election), one of these calls hung indefinitely. The blocked CNI ADD goroutine caused containerd to serialize `ListPodSandboxes` behind it — and since Generic PLEG calls `ListPodSandboxes` every second, PLEG deadlocked silently within seconds. The node CPU dropped to <1% with no log output and no Kubernetes event.

The 3 full IPAM blocks accumulated 237 stale IP allocations for pods that no longer existed. The Calico IPAM GC that would normally reclaim them was not running: `calico-kube-controllers` v3.13.2 has a TypeAssertionError bug where it panics on `cache.DeletedFinalStateUnknown` tombstone objects in its pod event handler, causing the controller to crash continuously and its IPAM GC loop to never execute.

Recovery required two kubelite restarts with full orphaned-sandbox cleanup (not just partial cleanup), deployment of a PLEG deadlock detector, and direct CRD patching to free all 237 stale IPAM allocations. The cluster is stable with k8s03 cordoned. Root-cause fixes (Calico upgrade, EventedPLEG enablement) are tracked as follow-up actions.

---

## Timeline (AEST — UTC+10)

| Time | Event |
|------|-------|
| **~23:30 AEST 2026-05-17** | PGM-195 resolved. Cordon-before-restart procedure confirmed working. k8s03 uncordoned; workloads begin scheduling. |
| **~00:00 AEST 2026-05-18** | ARC listener pod (`arc-systems` namespace) detected missing. Investigation begins: kube-controller-manager and scheduler appear stalled on k8s03 after watch-EOF events. Leader leases deleted to force re-election. Listener pod recreates cleanly. |
| **~00:15 AEST** | k8s03 CPU observed at <1%. Confirmed PLEG deadlock (kubelite PID alive but zero log output, Generic PLEG health check firing). PGM-197 filed. |
| **~00:30 AEST** | k8s03 cordoned. kubelite stopped. Orphaned sandbox cleanup attempted (sandboxes with no running containers removed). kubelite started. |
| **~00:45 AEST** | k8s03 reaches Ready. Appears to recover. CPU rises to ~12%. |
| **~01:00 AEST** | CPU drops back to <1%. Second PLEG deadlock. Goroutine dump captured via SIGQUIT → journald. |
| **~01:30 AEST** | Goroutine dump analysis: `containerd-grpc` goroutines blocked on kine API calls. `ListPodSandboxes` goroutine confirmed serialized behind a blocked CNI ADD goroutine. EventedPLEG=false confirmed in `/var/snap/microk8s/current/args/kubelet`. |
| **~02:00 AEST** | containerd event logs analysed. `container event discarded` (8302/day) confirmed as normal/expected with Generic PLEG (kubelet has no event subscriber when EventedPLEG=false). Not a deadlock indicator. |
| **~02:30 AEST** | containerd CNI ADD logs from `2026-05-17T05:59:38Z` and `2026-05-17T21:12Z` show Calico iterating through all 3 full blocks before finding free space. Pattern: `block 10.1.237.64/26: full → block 10.1.108.128/26: full → block 10.1.108.192/26: full → 10.1.108.134 allocated`. |
| **~03:00 AEST** | Calico IPAM block structure examined. k8s03 has 5 ipamblocks; 3 are 64/64 full (completely stale), 2 partially stale. Total: 237 stale allocations (pods no longer running). |
| **~03:30 AEST** | `calicoctl ipam check` attempted (microk8s-bundled v3.32.0) — hangs indefinitely. Incompatible with running Calico v3.13.2 CRDs (missing `KubeControllersConfiguration`). `calicoctl ipam gc` not a valid subcommand in v3.32.0. Direct CRD inspection required. |
| **~04:00 AEST** | `calico-kube-controllers` logs analysed. TypeAssertionError panic confirmed: `interface {} is cache.DeletedFinalStateUnknown, not *v1.Pod`. Controller crash-looping; IPAM GC loop never reaches execution. This is the reason stale entries accumulated. |
| **~04:30 AEST** | Root cause confirmed. Two-condition deadlock trigger identified: (1) full IPAM blocks forcing 3+ extra kine API calls per CNI ADD; (2) any dqlite latency spike making those calls hang. Both conditions present on k8s03. |
| **~07:00 AEST** | PLEG deadlock detector script (`/opt/pleg_deadlock_detector.sh`) written. Monitors kubelite CPU every 15s; triggers goroutine dump capture (SIGQUIT to kubelite + containerd) when CPU < 3% for 120 consecutive seconds. |
| **~07:49 AEST** | First recovery restart. k8s03 cordoned. kubelite stopped. All sandboxes cleaned (not just orphans). kubelite started. Node reaches Ready; 16 Running pods; 10.7% CPU. |
| **~08:04 AEST** | Second kubelite restart (cleanup refinement). Full sandbox wipe approach confirmed as correct procedure: forces kubelet initial LIST to include all currently-assigned pods, bypassing watch cache delivery issue. |
| **~08:36 AEST** | `pleg-detector.service` systemd unit deployed and enabled on k8s03. Confirmed `Active: active (running)`. Diagnostics output directory: `/var/log/k8s-pleg-debug/`. |
| **~08:45 AEST** | `clean_ipam_blocks.py` dry run shows 237 stale allocations. `--apply` mode run: all 5 k8s03 IPAM blocks patched via `kubectl replace`. Blocks reduced from 64/64, 64/64, 64/64, 62/64, 9/64 → 1/64, 4/64, 4/64, 17/64, 0/64. |
| **~09:00 AEST** | k8s03 stable: 16 Running pods; 10.7% CPU sustained; pleg-detector.service monitoring. k8s03 remains cordoned pending 24h stability window. Follow-up tickets filed (PGM-198–201). |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: PLEG Deadlock — from CNI ADD to kubelet halt

##### How did k8s03's kubelet PLEG deadlock?

With `EventedPLEG=false`, the kubelet uses Generic PLEG which calls `ListPodSandboxes` on containerd's gRPC socket every 1 second. containerd serializes gRPC requests through a shared handler. If any goroutine holds the handler (e.g., a running CNI ADD), `ListPodSandboxes` blocks indefinitely behind it. The PLEG health check fires after ~3 minutes of no relist, marking PLEG as unhealthy. The kubelet enters a deadlocked state: CPU drops to <1%, zero log output, zero pod lifecycle events — but the process remains alive and heartbeating to the API server.

##### How was a CNI ADD goroutine able to block containerd's gRPC handler?

Calico performs IPAM block allocation as part of every CNI ADD. To allocate an IP, Calico reads the available IPAM blocks via the Kubernetes API (kine/dqlite), finds a block with free space, and writes a reservation. If the first block(s) are full, Calico reads the next block — each read is a separate kine API call. Any of these calls hanging indefinitely causes the CNI ADD goroutine to stall inside containerd's gRPC handler.

##### How did IPAM block reads hang?

kine (the k8s API shim over dqlite) serializes reads through the dqlite Raft log. During dqlite events — snapshot compaction, leader election, or high write load — the dqlite leader pauses or slows reads. API calls made during these windows receive `deadline_exceeded` or block until the event resolves. The hang duration varies from milliseconds to several seconds.

##### How did finding a free IPAM block require 3 API calls instead of 1?

Every single CNI ADD on k8s03 had to iterate through 3 fully-saturated IPAM blocks (64/64 used each) before reaching the 4th block with free space. Each full block requires one kine read to discover it is full. 3 full blocks = 3 extra API calls per CNI ADD. This tripled the number of kine API calls landing in any dqlite latency window compared to a healthy IPAM state.

##### How did 3 IPAM blocks become 64/64 full?

The `spec.allocations` arrays of 3 k8s03 IPAM blocks contained 64 non-null entries each — yet the corresponding pods no longer existed. These were **stale** allocations: the pods had been deleted, rescheduled, or evicted, but their IPAM entries were never reclaimed. Calico's IPAM GC is responsible for cross-referencing allocations against running pods and freeing stale entries. If GC does not run, stale entries accumulate until blocks fill.

##### How did Calico's IPAM GC stop running?

`calico-kube-controllers` is the component responsible for IPAM GC. It was crash-looping continuously on pvek8s. The controller's pod event handler in v3.13.2 performs a direct type assertion:

```go
pod := obj.(*v1.Pod)  // panics if obj is not *v1.Pod
```

When a pod is evicted or garbage-collected before the informer delivers a standard Delete event, the API server wraps the stale state in a `cache.DeletedFinalStateUnknown` tombstone. The direct assertion panics, crashing the controller. On each restart, the controller crashes again on the same tombstone — a permanent crash loop. The IPAM GC loop inside the controller never reaches execution.

##### How was calico-kube-controllers v3.13.2 running with this known bug?

Calico v3.13.2 was installed approximately 6 years ago and was never upgraded. It is not managed as a microk8s addon — it was installed independently and is orphaned from microk8s snap management. No Calico upgrade process or version monitoring was in place. The microk8s 1.35 bundled `calicoctl` is v3.32.0 (incompatible with the v3.13.2 CRDs), meaning standard tooling could not inspect or manage the running Calico installation.

##### How was there no process to detect that Calico was never upgraded?

Calico's version was not tracked in any monitoring or inventory system. No Dependabot-equivalent exists for DaemonSet/Deployment image versions in this cluster. The upgrade from microk8s 1.34 to 1.35 (PGM-159) focused on the Kubernetes version and snap components; the independently-installed Calico was not in scope and was not checked.

---

#### Chain 2: Restart Feedback Loop — why the initial recovery failed

##### How did the first kubelite restart fail to recover PLEG?

After the first restart (orphaned-sandbox partial cleanup), the kubelet initially appeared healthy: CPU rose to ~12% and the node showed Ready. Within 2 minutes, CPU dropped to <1% and PLEG deadlocked again. The immediate re-deadlock indicated the root trigger was still present.

##### How did partial orphan cleanup leave the trigger intact?

The partial cleanup removed sandboxes that had no running containers (true orphans). However, some sandboxes for in-flight pod restarts still had associated container records — these were retained. On kubelite restart, the kubelet's initial `ListPodSandboxes` returned these retained sandboxes; the kubelet immediately triggered reconciliation (CNI ADD calls for each). Those CNI ADDs hit the full IPAM blocks → extra kine API calls → PLEG deadlock reproduced within seconds of startup.

##### How does a full sandbox wipe prevent the re-deadlock?

Removing **all** sandboxes before starting kubelite forces the kubelet's initial LIST (from the API server) to be the authoritative source of truth for which pods to run. The kubelet does not attempt to reconcile any pre-existing sandbox state — it starts from scratch, processing only currently-assigned pods at a controlled rate rather than all-at-once sandbox reconciliation.

##### How was the correct cleanup procedure not known initially?

The prior procedure (from PGM-195 investigation) was designed to clean "orphaned" sandboxes — sandboxes with no running containers. This is the standard Kubernetes containerd cleanup approach. The edge case where partially-alive sandboxes trigger immediate PLEG re-deadlock on a node with full IPAM blocks was not documented and was discovered empirically during this incident.

---

#### Chain 3: Silent Detection — why the deadlock was not caught automatically

##### How was PLEG deadlock not automatically detected and alerted?

No monitoring existed for sustained low CPU on kubelite. The PLEG deadlock is silent: the kubelet process remains alive (heartbeating to the API server), the node shows `Ready: True`, and no Kubernetes events or log output are produced. The only external signal is the node's CPU utilisation collapsing.

##### How does Generic PLEG deadlock produce no log output?

The PLEG deadlock occurs when `ListPodSandboxes` blocks inside containerd's gRPC call — the kubelet's PLEG goroutine is stuck waiting for a response that never arrives. The goroutine is alive but not executing any application code. No timeout fires, no error is logged, no channel message is sent. The kubelet's health checks run in separate goroutines, but they report to the API server via the node heartbeat (which continues), not via logs.

##### How was the deadlock eventually detected?

Manually. During the ARC listener pod investigation, an operator observed that k8s03 CPU was <1% on `ps aux` after 3+ minutes post-restart. Combined with zero kubelite log output, this was recognised as a PLEG deadlock pattern. Without the manual observation, the deadlock could persist indefinitely — the node would appear Ready but process no pod lifecycle events.

##### How was there no automated detection before this incident?

No NRPE check existed for kubelite process CPU. The `pleg-detector.service` was created during this incident as a direct response. Prior PLEG analysis (PGM-195) had focused on the watch-cache issue and pod visibility, not on CPU monitoring as a deadlock indicator.

---

## Impact

### Services Affected

| Service | Impact | Duration |
|---------|--------|----------|
| All k8s03-assigned workloads | Pods not processed; existing running pods continued but no new lifecycle events | ~9 hours (multiple deadlock cycles) |
| ARC runner listener pod (arc-systems) | Missing; kube-controller-manager stalled on k8s03 post-watch-EOF | ~15 min (lease deletion resolved) |
| New pod scheduling to k8s03 | Blocked (node cordoned during investigation) | ~9 hours |
| Calico IPAM GC | Not running; stale entries accumulating | Ongoing (calico-kube-controllers v3.13.2 crash loop) |

### Duration

- **Active deadlock periods:** 3 cycles (~00:15, ~01:00, and one more before final recovery) each lasting ~2-10 minutes before detection
- **Total investigation window:** ~9 hours
- **Expected recovery time (with documented procedure):** <30 minutes

### Scope

- k8s03 only (other nodes have different IPAM block state)
- No persistent data loss
- No user-facing service disruption (pods running on k8s01/k8s02 unaffected)
- Calico IPAM GC still not running (root cause: calico-kube-controllers crash loop, tracked in PGM-198/PGM-200)

---

## Resolution Steps Taken

### Phase 1: PLEG Deadlock Detection and Initial Kubelite Restart

1. Observed k8s03 CPU at <1% post-restart via `ps aux | grep kubelite`.
2. Confirmed PLEG deadlock: zero kubelite log output; node showing Ready; no pod lifecycle events.
3. Cordoned k8s03: `kubectl --context pvek8s cordon k8s03`.
4. Stopped kubelite: `ssh k8s03 sudo systemctl stop snap.microk8s.daemon-kubelite`.
5. Cleaned orphaned sandboxes (sandboxes with no running containers).
6. Started kubelite. Node reached Ready (~12% CPU). Re-deadlocked within 2 minutes.

### Phase 2: Goroutine Dump and Root Cause Analysis

7. Sent SIGQUIT to kubelite PID (`kill -SIGQUIT <pid>`) to capture goroutine dump to journald.
8. Confirmed via goroutine dump: `containerd-grpc` goroutine blocked in kine API call; `ListPodSandboxes` goroutine serialized behind it.
9. Confirmed `EventedPLEG=false` in `/var/snap/microk8s/current/args/kubelet`.
10. Confirmed `container event discarded` messages in containerd are **not** a deadlock indicator (expected with Generic PLEG when no event subscriber is registered).

### Phase 3: IPAM Block Root Cause Investigation

11. Examined containerd logs from prior deadlock cycles: timestamps `2026-05-17T05:59:38Z` and `2026-05-17T21:12:49Z` show Calico iterating all 3 full blocks on every CNI ADD.
12. Mapped k8s03 IPAM blocks:
    ```
    10.1.237.64/26:   64/64 used (all stale)
    10.1.108.128/26:  64/64 used (all stale)
    10.1.108.192/26:  64/64 used (all stale)
    10.1.108.64/26:   62/64 used (mostly stale)
    10.1.108.0/26:     9/64 used
    ```
13. Cross-referenced allocations against running pods: confirmed 237 entries for non-existent pods.
14. Confirmed `calico-kube-controllers` crash loop via: `kubectl --context pvek8s logs -n kube-system -l k8s-app=calico-kube-controllers --previous`.
15. Identified TypeAssertionError panic on `cache.DeletedFinalStateUnknown` as crash cause.
16. Confirmed `calicoctl` (microk8s-bundled v3.32.0) incompatible with running Calico v3.13.2 CRDs — direct CRD patching required.

### Phase 4: Recovery Restart (Full Sandbox Wipe)

17. k8s03 cordoned. kubelite stopped.
18. Removed **all** sandboxes (not just orphans) using `microk8s ctr` with `--force`:
    ```bash
    for sid in $(sudo microk8s ctr --address /var/snap/microk8s/common/run/containerd.sock \
      --namespace k8s.io sandboxes list 2>/dev/null | awk 'NR>1{print $1}'); do
      sudo microk8s ctr --namespace k8s.io sandboxes remove --force "$sid" 2>/dev/null
    done
    ```
19. Started kubelite. Node reached Ready; 16 Running pods; 10.7% CPU sustained for 5+ minutes.

### Phase 5: PLEG Deadlock Detector Deployment

20. Wrote `/opt/pleg_deadlock_detector.sh` on k8s03:
    - Monitors kubelite CPU every 15 seconds via `ps`.
    - Threshold: CPU < 3% for 120 consecutive seconds.
    - On deadlock: sends SIGQUIT to kubelite PID and containerd PID; captures goroutine dumps to `/var/log/k8s-pleg-debug/<timestamp>_*`; records sandbox and task state; sleeps 300s to avoid repeated captures.
21. Created and enabled `pleg-detector.service` systemd unit on k8s03.
22. Confirmed running: `Active: active (running) since 2026-05-18T22:36:49 UTC`.

### Phase 6: IPAM Cleanup

23. Wrote `/tmp/clean_ipam_blocks.py` on local machine:
    - Cross-references all IPAM allocations against `kubectl get pods -A` (running pods by namespace+name).
    - Dry run: prints live vs stale count per block with IPAM handles.
    - Apply mode: patches each k8s03 block via `kubectl replace`, nulling stale `allocations` slots and updating `unallocated` list.
    - Does not update `IPAMHandles` (orphaned handles GC'd eventually by calico-kube-controllers when working).
24. Dry run confirmed 237 stale entries.
25. Applied: `python3 /tmp/clean_ipam_blocks.py --apply`.
26. Post-cleanup verification:
    ```
    10.1.237.64/26:   1/64
    10.1.108.128/26:  4/64
    10.1.108.192/26:  4/64
    10.1.108.64/26:  17/64
    10.1.108.0/26:    0/64
    ```
    Calico now finds free space on the first block lookup — no extra API calls per CNI ADD.

---

## Verification

### PLEG Health

```
k8s03 kubelite CPU: 10.7% sustained (vs <1% during deadlock)
Running pods: 16 (all healthy)
pleg-detector.service: Active (monitoring)
PLEG health indicator: CPU > 3% for >120s → no deadlock detected
```

### IPAM Block State (post-cleanup)

```
Block              Before   After
10.1.237.64/26     64/64    1/64   (63 freed)
10.1.108.128/26    64/64    4/64   (60 freed)
10.1.108.192/26    64/64    4/64   (60 freed)
10.1.108.64/26     62/64   17/64   (45 freed)
10.1.108.0/26       9/64    0/64    (9 freed)
Total freed: 237 stale allocations
```

### k8s03 Node State

- Status: Ready (cordoned)
- calico-node: Running (IPAM now finds free blocks immediately)
- pleg-detector.service: Active; diagnostics to `/var/log/k8s-pleg-debug/`

---

## Preventive Measures

### Immediate Actions Required

1. **Fix calico-kube-controllers TypeAssertionError to restore IPAM GC** (High)
   - Without IPAM GC running, stale entries will re-accumulate and full blocks will recur.
   - Action: Update `calico-kube-controllers` image to a version with tombstone/`DeletedFinalStateUnknown` handling. If Calico upgrade (PGM-200) proceeds, this is resolved as part of that work.
   - Linear: [PGM-198](https://linear.app/pgmac-net-au/issue/PGM-198)

2. **Enable EventedPLEG on k8s03** (High)
   - `EventedPLEG=false` forces Generic PLEG's blocking 1-second serial poll, creating the structural deadlock vulnerability. EventedPLEG uses a watch stream and eliminates the serial `ListPodSandboxes` poll.
   - Action: Change `--feature-gates=EventedPLEG=false` to `EventedPLEG=true` (or remove if k8s 1.35 defaults to true) in `/var/snap/microk8s/current/args/kubelet`. Cordon k8s03 before restarting (PGM-195 procedure).
   - Linear: [PGM-199](https://linear.app/pgmac-net-au/issue/PGM-199)

3. **Upgrade Calico from v3.13.2 to a current release** (High)
   - Calico v3.13.2 is ~6 years old, orphaned from microk8s management, and incompatible with microk8s-bundled calicoctl. Modern versions fix IPAM GC issues and are compatible with k8s 1.35 and containerd 2.1.3.
   - Action: Plan sequential Calico upgrade (calico-node + calico-kube-controllers + CRDs). Consider calico-operator for future management. Run IPAM cleanup (`clean_ipam_blocks.py --apply`) before upgrade.
   - Linear: [PGM-200](https://linear.app/pgmac-net-au/issue/PGM-200)

### Longer-Term Improvements

4. **Investigate kine/dqlite latency spikes as an independent risk factor** (Medium)
   - Full IPAM blocks are now cleaned, but any single hanging kine call in a CNI ADD can still create a vulnerability window (even without full blocks) if the hang is long enough. Understand the frequency and duration of dqlite latency events.
   - Action: Analyse kine API call latency distribution; correlate with dqlite compaction and election events; determine whether EventedPLEG alone is sufficient mitigation or whether dqlite tuning is also required.
   - Linear: [PGM-201](https://linear.app/pgmac-net-au/issue/PGM-201)

5. **Uncordon k8s03 after stability window** (High — follow-on from this incident)
   - k8s03 is cordoned pending 24h PLEG health confirmation from pleg-detector.service.
   - Action: After 24h with no deadlock detected, uncordon: `kubectl --context pvek8s uncordon k8s03`.
   - Linear: [PGM-197](https://linear.app/pgmac-net-au/issue/PGM-197)

---

## Lessons Learned

### What Went Well

- **PLEG deadlock pattern recognised quickly**: The <1% CPU + zero log output signature was identified within minutes of the second deadlock cycle.
- **Goroutine dump provided conclusive evidence**: SIGQUIT-based goroutine capture gave a direct view of the blocked gRPC goroutine — no guesswork required for the proximate cause.
- **Direct CRD patching as diagnostic bypass**: When `calicoctl` (version mismatch) couldn't be used, direct inspection and patching of `ipamblocks.crd.projectcalico.org` via kubectl allowed diagnosis and resolution without needing a compatible CLI.
- **PLEG detector deployed before session ended**: Rather than leaving monitoring as a follow-up action, the detector was deployed during the incident and provides auto-capture for any future deadlock.

### What Didn't Go Well

- **First restart used partial sandbox cleanup**: The "orphaned sandbox" cleanup approach is correct for the general case but insufficient here. The full-sandbox-wipe procedure should have been used from the start.
- **No detection for PLEG deadlock**: Without the pleg-detector.service (now deployed), a PLEG deadlock could persist indefinitely — the node shows Ready to the cluster while processing no pod events. This was an unknown-unknown before this incident.
- **Calico was 6 years old and unmonitored**: An independently-installed CNI component running v3.13.2 from 2019 had a known crash-loop bug that blocked garbage collection, directly causing this incident. No process existed to detect version staleness for independently-installed cluster components.
- **EventedPLEG explicitly disabled**: `--feature-gates=EventedPLEG=false` was set explicitly in the kubelet args, disabling a feature that would have eliminated the entire deadlock vector. The reason for this setting is not documented.

### Surprise Findings

- **Generic PLEG and containerd serialize on the same gRPC path**: A CNI ADD operation inside containerd shares the gRPC handler with `ListPodSandboxes`. This means a CNI ADD hang blocks PLEG directly — the containerd layer provides no isolation between pod network setup and pod lifecycle reporting.
- **`container event discarded` logs are completely normal with Generic PLEG**: 8302 such messages per day were observed and initially suspected as a symptom. Confirmed as expected: with `EventedPLEG=false`, the kubelet registers no event subscriber, so every containerd event is discarded. These logs carry no diagnostic value.
- **3 full IPAM blocks tripled the deadlock risk per CNI ADD**: The multiplicative effect of full blocks on kine API call frequency was not intuitive. Each pod start doubled (or tripled) the number of API calls in the deadlock-vulnerable window — full blocks are not just an efficiency problem but a safety multiplier.
- **calico-kube-controllers crash loop is permanent with tombstones in the queue**: The crash on `DeletedFinalStateUnknown` objects is not transient. Every pod eviction or unclean deletion enqueues a tombstone, and once in the queue, it crashes the controller on every restart. The controller can never catch up; IPAM GC will never run. Without a fix, stale entries accumulate indefinitely.
- **Full sandbox wipe is the correct kubelite restart procedure**: Contrary to the principle of preserving running containers, clearing all containerd sandboxes before kubelite restart ensures the kubelet starts from a clean state aligned with the API server's pod assignments. Any retained sandbox — even one with a running container — can trigger immediate CNI reconciliation on startup and reproduce a deadlock.

---

## Action Items

| # | Action | Priority | Linear |
|---|--------|----------|--------|
| 1 | Fix calico-kube-controllers TypeAssertionError panic to restore IPAM GC | High | [PGM-198](https://linear.app/pgmac-net-au/issue/PGM-198) |
| 2 | Enable EventedPLEG on k8s03 (remove `EventedPLEG=false` feature gate) | High | [PGM-199](https://linear.app/pgmac-net-au/issue/PGM-199) |
| 3 | Upgrade Calico from v3.13.2 to a current release (calico-node + calico-kube-controllers) | High | [PGM-200](https://linear.app/pgmac-net-au/issue/PGM-200) |
| 4 | Investigate kine/dqlite latency spike frequency and duration; assess residual risk post-EventedPLEG | Medium | [PGM-201](https://linear.app/pgmac-net-au/issue/PGM-201) |
| 5 | Uncordon k8s03 after 24h stability window (pleg-detector.service confirms no deadlock) | High | [PGM-197](https://linear.app/pgmac-net-au/issue/PGM-197) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03)
- **Kubernetes version:** v1.35.0 (snap rev 8612)
- **Container runtime:** containerd 2.1.3 (microk8s 1.35)
- **CNI:** Calico v3.13.2 (independently installed, not microk8s addon)
- **PLEG mode:** Generic PLEG (`EventedPLEG=false` explicitly set)
- **Host OS:** Ubuntu 20.04 LTS (cgroup v2)

### Key Error Signatures

**PLEG deadlock (silent — no log):**
```
# External indicator only:
ps aux | grep kubelite → CPU < 1% for 3+ minutes
kubectl get node k8s03 → STATUS: Ready (false positive)
# No log output from kubelite during deadlock
```

**calico-kube-controllers TypeAssertionError:**
```
panic: interface conversion: interface {} is
cache.DeletedFinalStateUnknown, not *v1.Pod

goroutine 1 [running]:
k8s.io/client-go/tools/cache.(*DeltaFIFO).Pop(...)
```

**IPAM full block iteration in containerd logs:**
```
2026-05-17T05:59:38.124Z INFO calico/ipam Skipping full block
  block=10.1.237.64/26 node=k8s03
2026-05-17T05:59:38.318Z INFO calico/ipam Skipping full block
  block=10.1.108.128/26 node=k8s03
2026-05-17T05:59:38.501Z INFO calico/ipam Skipping full block
  block=10.1.108.192/26 node=k8s03
2026-05-17T05:59:38.623Z INFO calico/ipam Allocated IP
  ip=10.1.108.134 block=10.1.108.64/26 node=k8s03
```

**CAS conflict on concurrent IPAM DEL (expected — not an error):**
```
operation cannot be fulfilled on ipamblocks.crd.projectcalico.org
"10-1-237-64-26": the object has been modified
# Auto-retried; resolves in ~550ms; normal under concurrent CNI DEL operations
```

### IPAM Cleanup Script

Location: `/tmp/clean_ipam_blocks.py`

```bash
# Dry run (shows live vs stale per block)
python3 /tmp/clean_ipam_blocks.py

# Apply (patches all k8s03 IPAM blocks via kubectl replace)
python3 /tmp/clean_ipam_blocks.py --apply

# Verify post-cleanup
kubectl --context pvek8s get ipamblocks -o json | python3 -c "
import json,sys; d=json.load(sys.stdin)
for b in d['items']:
    s=b['spec']; n=s.get('affinity','').replace('host:','')
    if n!='k8s03': continue
    a=s.get('allocations',[]); used=sum(1 for x in a if x is not None)
    print(b['metadata']['name'], f'used={used}/{len(a)}')
"
```

### PLEG Detector

Location: `pleg-detector.service` on k8s03; script at `/opt/pleg_deadlock_detector.sh`

- **Trigger:** kubelite CPU < 3% for 120 consecutive seconds (checked every 15s)
- **On trigger:** SIGQUIT to kubelite + containerd PID; capture goroutine dumps and sandbox/task state
- **Output:** `/var/log/k8s-pleg-debug/<timestamp>_{kubelite,containerd}_goroutines.log`, `_sandboxes.txt`, `_tasks.txt`
- **Cooldown:** 300s after capture before re-checking

### Kubelite Restart Procedure (Updated)

```bash
# 1. Cordon
kubectl --context pvek8s cordon k8s03

# 2. Stop kubelite
ssh k8s03 sudo systemctl stop snap.microk8s.daemon-kubelite

# 3. Remove ALL sandboxes (not just orphans)
ssh k8s03 'for sid in $(sudo microk8s ctr \
  --address /var/snap/microk8s/common/run/containerd.sock \
  --namespace k8s.io sandboxes list 2>/dev/null | awk "NR>1{print \$1}"); do
  sudo microk8s ctr --namespace k8s.io sandboxes remove --force "$sid" 2>/dev/null
done'

# 4. Start kubelite
ssh k8s03 sudo systemctl start snap.microk8s.daemon-kubelite

# 5. Verify Ready and PLEG healthy (CPU > 10% after 3 min)
kubectl --context pvek8s wait node/k8s03 --for=condition=Ready --timeout=300s

# 6. Uncordon when ready
kubectl --context pvek8s uncordon k8s03
```

---

## References

- Linear ticket: [PGM-197](https://linear.app/pgmac-net-au/issue/PGM-197) — k8s03 recurring PLEG deadlock / stale IPAM root cause confirmed
- Linear ticket: [PGM-195](https://linear.app/pgmac-net-au/issue/PGM-195) — k8s03 kubelet pod watch broken post-restart (cordon-before-restart procedure)
- Linear ticket: [PGM-198](https://linear.app/pgmac-net-au/issue/PGM-198) — Fix calico-kube-controllers TypeAssertionError to restore IPAM GC
- Linear ticket: [PGM-199](https://linear.app/pgmac-net-au/issue/PGM-199) — Enable EventedPLEG on k8s03
- Linear ticket: [PGM-200](https://linear.app/pgmac-net-au/issue/PGM-200) — Upgrade Calico from v3.13.2
- Linear ticket: [PGM-201](https://linear.app/pgmac-net-au/issue/PGM-201) — Investigate kine/dqlite latency spikes
- Notion investigation: [PGM-197: k8s03 PLEG Deadlock — Stale IPAM Blocks](https://www.notion.so/362524b4a07781428c77e7bbc7ef168f)
- IPAM cleanup script: `/tmp/clean_ipam_blocks.py`
- PLEG detector: `/opt/pleg_deadlock_detector.sh` on k8s03 (systemd: `pleg-detector.service`)
- Related incident (microk8s 1.35 upgrade cascade): [pvek8s microk8s 1.34 → 1.35 Upgrade](2026-05-16-microk8s-1.35-upgrade-cgroup-v2-containerd-disk-pressure.md)
- Related incident (Calico RBAC dqlite write storm): [AWX Automation Pod Stuck Pending](2026-05-15-awx-pod-pending-calico-rbac-dqlite-write-storm.md)
- Kubernetes Generic PLEG source: `k8s.io/kubernetes/pkg/kubelet/pleg/generic.go`
- Calico IPAM block CRD: `ipamblocks.crd.projectcalico.org`

---

## Reviewers

- @pgmac
