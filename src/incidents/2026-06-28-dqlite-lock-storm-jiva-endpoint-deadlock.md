---
tags:
  - k8s01
  - k8s02
  - k8s03
  - dqlite
  - kine
  - jiva
  - openebs
  - kcm
  - storage
  - crash-loop
  - microk8s
---

# Post Incident Review: pvek8s dqlite WAL Lock Storm — Jiva Controller Endpoint Deadlock

**Date:** 2026-06-28
**Duration:** ~11h 11m total degradation (~12:46 AEST → ~23:57 AEST); ~52m active recovery (~23:05 AEST → ~23:57 AEST)
**Severity:** High (three PVCs with all replicas crashing for 10+ hours; iSCSI volumes at risk of going read-only; no complete data loss)
**Status:** Resolved

---

## Executive Summary

At approximately 12:46 AEST on 2026-06-28, Jiva iSCSI replica pods began CrashLoopBackOff across three PVCs (calibreweb, radarr, and one unidentified volume). The root cause of this initial failure was not determined — the jiva-operator likely lost its watch connection to the API server at this time and stopped reconciling. Jiva controller pods were absent or unreachable, causing replicas to cycle with `connection refused` errors.

At ~22:58 AEST, the jiva-operator recovered and recreated the Jiva controller pods. The controllers became Ready at ~23:03 AEST. At this point, normal operation should have resumed: the kube-controller-manager's endpoint-controller should have moved the controllers from `notReadyAddresses` to `addresses` in their respective service endpoints, allowing replicas to connect. Instead, a dqlite WAL lock storm on k8s01 and k8s02 (the dqlite leader) prevented those endpoint writes from succeeding. The endpoint-controller exhausted its write budget (`database is locked: try 500`) and gave up. The controllers remained in `notReadyAddresses`, replicas kept crashing, and a self-sustaining deadlock was established: replicas crash because they can't reach the controller, and the controller can't achieve replica quorum because replicas can't connect.

At ~23:15 AEST, the lock storm caused k8s01 kubelite to restart and lose its KCM leader lease. The KCM leader migrated to k8s03, whose kine.sock was experiencing intermittent `use of closed network connection` errors — preventing the KCM from writing the endpoint updates even after the dqlite lock rate fell. The scheduler lease migrated to k8s02, whose dqlite was still experiencing `try 500` lock contention. This left both the KCM and scheduler on nodes unable to write to the API server.

The cluster state was detected at ~23:46 AEST. After diagnosing that the KCM was stuck (EndpointSlices not regenerating, rollout restarts no-oping, force-deleted pods not recreating), the fix was to restart `snap.microk8s.daemon-k8s-dqlite` on k8s03 (follower) and then on k8s02 (leader). This caused k8s01 to win the new dqlite leader election, with KCM and scheduler co-located on k8s01 with no network hop for writes. jiva-operator immediately reconciled, created new controller pods with correct endpoints, and replica pods reconnected. All 24 Jiva replica pods reached 1/1 Running by ~23:57 AEST.

---

## Timeline (AEST — UTC+10)

| Time | Event |
|------|-------|
| **~12:46 AEST** | Jiva replica pods created / begin CrashLoopBackOff — `connection refused` to controller services. Original trigger (controller pods absent or unreachable) unknown |
| **~12:46–22:58 AEST** | ~10h of silent degradation: replica pods cycle with 5-minute backoff; 11 restarts per replica pod; jiva-operator not reconciling; no alert fires |
| **~22:58 AEST** | jiva-operator recovers watch and recreates Jiva controller pods for three affected PVCs |
| **~23:01 AEST** | dqlite WAL lock storm intensifies on k8s02 (leader, `try 500`) and k8s01; write failures begin across the cluster |
| **~23:03 AEST** | Jiva controller pods become Ready; endpoint-controller attempts to write endpoint updates → fails due to dqlite lock contention |
| **~23:03 AEST** | Controllers stuck in `notReadyAddresses`; replica CrashLoopBackOff continues (endpoints not updated → connection refused) |
| **~23:05–23:15 AEST** | dqlite lock storm peak; kube-controller-manager on k8s01 exhausts lease renewal writes |
| **~23:15 AEST** | k8s01 kubelite restarts (PID 3193358 → 3228140); KCM lease migrates to k8s03; scheduler lease migrates to k8s02 |
| **~23:15+ AEST** | k8s03 kine.sock intermittent `use of closed network connection`; KCM on k8s03 cannot write endpoint updates. k8s02 dqlite still `try 500`; scheduler cannot write |
| **~23:46 AEST** | Investigation begins; found 8+ jiva replica pods CrashLoopBackOff, 3 controller services with `notReadyAddresses`, 3 other PVCs with rep-3 crashing |
| **~23:47 AEST** | Deleted 3 stale EndpointSlices → none regenerated (CM not writing) |
| **~23:47 AEST** | Annotated controller pod to trigger endpoint refresh → endpoint `resourceVersion` unchanged (CM not writing) |
| **~23:48 AEST** | `rollout restart jiva-operator` → annotation added but no new ReplicaSet created (deployment controller = stuck CM) |
| **~23:48 AEST** | Force-deleted 3 controller pods + jiva-operator pod → none recreated; confirmed deployment controller is the stuck CM |
| **~23:49 AEST** | Identified `use of closed network connection` errors in k8s03 kubelite logs; KCM confirmed on k8s03 via lease |
| **~23:50 AEST** | Confirmed k8s02 dqlite: `database is locked (try 500)` in k8s-dqlite logs; scheduler lease on k8s02 confirmed |
| **~23:51 AEST** | Manual Endpoints patch (moved controllers to `addresses`) abandoned — pods already force-deleted; would have pointed to dead pods |
| **~23:52 AEST** | `systemctl restart snap.microk8s.daemon-k8s-dqlite` on k8s03 (follower) |
| **~23:53 AEST** | k8s03 kubelite also restarted (triggered by k8s-dqlite restart); KCM lease migrates to k8s01 |
| **~23:54 AEST** | `systemctl restart snap.microk8s.daemon-k8s-dqlite` on k8s02 (leader) |
| **~23:55 AEST** | k8s01 wins new dqlite leader election; KCM and scheduler both on k8s01 (co-located with dqlite leader) |
| **~23:56 AEST** | jiva-operator reconciles; creates new Jiva controller pods; endpoint-controller writes correct endpoint state |
| **~23:57 AEST** | Jiva controller endpoints show `addresses` (not `notReadyAddresses`); replica pods begin connecting |
| **~00:00 AEST (+1d)** | Force-deleted remaining CrashLoopBackOff replica pods to accelerate reconnection |
| **~00:02 AEST (+1d)** | All 24 Jiva replica pods 1/1 Running; 0 non-running pods cluster-wide; full resolution |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: Jiva replica CrashLoopBackOff for 10+ hours — Endpoint Write Failure Deadlock

##### How did Jiva replica pods crash for 10+ hours?

Replicas received `connection refused` when attempting TCP connections to the Jiva controller service (port 9501). With no healthy address in the service endpoints, every retry failed.

##### How did the controller service have no healthy addresses?

The controller pods were in `notReadyAddresses` in the service's Endpoints object (and EndpointSlice). Kubernetes only routes traffic to addresses in the `addresses` section; `notReadyAddresses` is excluded. The endpoint-controller is responsible for moving a pod from `notReadyAddresses` to `addresses` when the pod's Ready condition becomes `True`.

##### How did the endpoint update never get written?

The endpoint-controller (part of kube-controller-manager) attempted to write the pod-Ready→endpoint update at ~23:03 AEST when the controllers became Ready. The write failed because dqlite was under severe WAL lock contention (`database is locked: try 500`) at that exact moment. The endpoint-controller gave up after exhausting its retry budget and never retried again.

##### How did dqlite have severe WAL lock contention at that moment?

The dqlite leader (k8s02) was experiencing a sustained write storm from kubelite/controller reconnects after an earlier disturbance. SQLite WAL mode is single-writer; under high concurrent write load, writers queue for the WAL checkpoint lock. The `try 500` threshold means kine exhausted its maximum retry budget (~500 attempts). This write storm coincided exactly with the window when the controllers became Ready and needed their endpoint update written.

##### How did this deadlock persist after the dqlite lock rate fell?

The kube-controller-manager leader had migrated to k8s03 (when k8s01 kubelite restarted at ~23:15 AEST). k8s03's kine.sock was experiencing intermittent `use of closed network connection` errors — gRPC channel reconnections failing. The new CM instance on k8s03 could not write endpoint updates either, keeping the deadlock in place.

Additionally, once the controller pods were force-deleted during diagnosis (in the erroneous belief they needed recreation), the jiva-operator was also deleted. This meant there were no Running controller pods at all for a period, making the endpoint deadlock irreversible through the CM alone — jiva-operator had to recreate the controller pods from scratch.

##### How was the endpoint deadlock not prevented or detected?

- **No alert fires when a Jiva controller service has `notReadyAddresses` entries for an extended period.** The endpoint deadlock is silent to all current monitoring.
- **No alert fires when Jiva replica pods have more than a handful of CrashLoopBackOff restarts.** The `microk8s-newest-pod-age` check detects zero pod creations cluster-wide but not CrashLoopBackOff in existing pods.
- **No runbook existed** for the Jiva controller endpoint deadlock pattern. This led to time-consuming diagnostic dead-ends (EndpointSlice deletion, rollout restarts, Endpoints patching) before the root cause was identified.
- **The `dqlite-write-contention` runbook** covers general write contention recovery but does not document the downstream Jiva endpoint deadlock pattern or how to diagnose a stuck CM as the root cause of endpoint staleness.

---

#### Chain 2: KCM leadership on broken node — CM write failures persist after dqlite partially recovers

##### How did the KCM fail to heal endpoint state even after the dqlite lock rate fell?

The KCM leader lease was on k8s03. k8s03's kine.sock was experiencing intermittent `use of closed network connection` errors throughout this period. Every write attempt by the CM (including endpoint updates) was failing at the gRPC transport layer before even reaching dqlite.

##### How did k8s03's kine.sock become broken?

k8s03's k8s-dqlite service is a dqlite raft follower. Its kine.sock gRPC connection pool had entered a broken state after the lock storm — channels failing to reconnect, similar to the pattern documented in the 2026-06-24 PIR. The `use of closed network connection` error repeating every few minutes indicates the connection pool was in a degraded state where new channel connections failed, but kubelite kept trying.

##### How did KCM end up on k8s03 with a broken kine?

At ~23:15 AEST, k8s01's kubelite restarted (due to losing the KCM lease renewal writes during the lock storm). k8s03 won the KCM leader election because it had been running continuously and was still renewing its lease (the lease-renewal goroutine doesn't depend on write success in the same way). This placed the CM on the node with the worst kine connectivity.

##### How was this not detected?

- **No alert for kine.sock reconnection failures.** The `microk8s-kine` Nagios check detects `database is locked` errors but the `use of closed network connection` pattern (channel-level failures distinct from dqlite lock contention) has no dedicated check. This gap was identified in the 2026-06-24 PIR (PGM-281 subtask) but not yet implemented.
- **No alert for CM leader placement.** There is no check that the KCM leader is on a node with healthy kine connectivity.

---

#### Chain 3: jiva-operator absent from reconciliation for ~10 hours — Original failure trigger unknown

##### How did Jiva replicas crash for ~10 hours without the controllers being recreated?

The jiva-operator is the controller responsible for managing Jiva controller pods. It failed to reconcile the missing/failed controller pods for approximately 10 hours (from ~12:46 AEST to ~22:58 AEST). Without the jiva-operator recreating the controllers, replicas had no target to connect to.

##### How did the jiva-operator fail to reconcile for 10 hours?

Unknown. The jiva-operator logs at the time are not available for the full 10-hour window. The most likely explanation is that the jiva-operator lost its watch connection to the API server (possibly due to a previous dqlite/kine disturbance) and stopped processing reconciliation events. When it reconnected at ~22:58 AEST, it immediately saw the missing controllers and recreated them.

##### How was this not detected?

- **No alert when jiva-ctrl pods are absent for > 5 minutes.** The current monitoring does not check for the existence of jiva-ctrl pods by namespace or by PVC.
- The 10-hour silent failure went entirely undetected. The cluster appeared healthy to all monitoring during this period — other pods were being created normally, so `microk8s-newest-pod-age` did not fire.

---

## Impact

### Services Affected

| Service / PVC | Impact | Duration |
|---|---|---|
| calibreweb-calibre-web-config (pvc-0bb83414) | All 3 replicas CrashLoopBackOff; volume degraded (no replica redundancy, iSCSI target at risk) | ~11h |
| radarr (pvc-a634b9a3, 167d old) | All 3 replicas CrashLoopBackOff; volume degraded | ~11h |
| pvc-a3a7e012 (385d old, service unknown) | All 3 replicas CrashLoopBackOff; volume degraded | ~11h |
| pvc-05e03b60 (385d old) | rep-3 CrashLoopBackOff; 2/3 replicas running; redundancy degraded | ~11h |
| pvc-17e6e808 (268d old) | rep-3 CrashLoopBackOff; 2/3 replicas running; redundancy degraded | ~11h |
| pvc-d16dc542 (385d old) | rep-3 CrashLoopBackOff; 2/3 replicas running; redundancy degraded | ~11h |
| jiva-operator | Force-deleted during diagnosis; not immediately recreated (CM stuck); ~5min gap | ~5m |

### Duration

- **Total degradation window:** ~11h 11m (replica CrashLoopBackOff ~12:46 → ~23:57 AEST)
- **Active recovery time:** ~52m (~23:05 AEST lock storm → ~23:57 AEST full resolution)
- **Detection to resolution:** ~11m
- **Expected recovery time with documented runbook:** ~5m

### Scope

- All three cluster nodes involved (dqlite issues on k8s01, k8s02, k8s03)
- Six Jiva PVCs degraded (three with all replicas crashing)
- No confirmed data loss — iSCSI controllers remained accessible to existing sessions throughout
- No seerr (pvc-746b2837) or new volumes (pvc-8eccb718) affected
- Running application pods were not interrupted — only pods attempting new mounts or restarts would have been blocked

---

## Resolution Steps Taken

### Phase 1: Diagnosis

1. Found replica pods in CrashLoopBackOff:
   ```bash
   kubectl --context pvek8s get pods -n openebs | grep rep | grep -v Running
   # → 8+ pods CrashLoopBackOff with 11-13 restarts
   ```

2. Identified controller services with `notReadyAddresses`:
   ```bash
   kubectl --context pvek8s get endpoints -n openebs | grep jiva-ctrl-svc
   # → 3 services showing IP in notReadyAddresses, empty addresses
   ```

3. Confirmed KCM was stuck (EndpointSlice deletion test):
   ```bash
   kubectl --context pvek8s delete endpointslice -n openebs <slice-names>
   # → EndpointSlices not recreated after 60s (CM not writing)
   ```

4. Identified KCM leader node:
   ```bash
   kubectl --context pvek8s -n kube-system get lease kube-controller-manager \
     -o jsonpath='{.spec.holderIdentity}'
   # → k8s03_...
   ```

5. Found k8s03 kine.sock drops in kubelite logs:
   ```bash
   ssh k8s03 "sudo journalctl -u snap.microk8s.daemon-kubelite --since '30 minutes ago' \
     --no-pager | grep 'use of closed network connection' | tail -5"
   # → multiple hits confirming broken gRPC channel pool
   ```

6. Found k8s02 dqlite lock contention:
   ```bash
   ssh k8s02 "sudo journalctl -u snap.microk8s.daemon-k8s-dqlite --since '15 minutes ago' \
     --no-pager | grep 'database is locked' | tail -5"
   # → 'database is locked (try: 500)' → leader is k8s02, severely contended
   ```

### Phase 2: Fix

7. Restarted k8s-dqlite on k8s03 (follower) — cleared broken kine connection state:
   ```bash
   ssh k8s03 "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite"
   ```
   Side effect: k8s03 kubelite also restarted (k8s03 kubelite depends on k8s-dqlite). KCM lease migrated to k8s01.

8. Restarted k8s-dqlite on k8s02 (leader) — cleared WAL lock storm, triggered dqlite leader re-election:
   ```bash
   ssh k8s02 "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite"
   ```
   k8s01 won the new dqlite leader election. KCM and scheduler were now both on k8s01, co-located with the dqlite leader (no network hop for writes).

9. Waited for jiva-operator to reconcile (~30s):
   - jiva-operator created new Jiva controller pods with fresh IPs
   - endpoint-controller immediately wrote correct endpoint state (now that CM could write)

10. Force-deleted remaining CrashLoopBackOff replica pods to accelerate reconnection:
    ```bash
    kubectl --context pvek8s delete pod -n openebs \
      pvc-0bb83414-...-rep-1 pvc-0bb83414-...-rep-2 pvc-0bb83414-...-rep-3 \
      pvc-a3a7e012-...-rep-3 pvc-a634b9a3-...-rep-3 # etc.
    ```

### Steps That Did Not Work

The following diagnostic actions were attempted before the root cause was identified, all of which failed because the KCM could not write to the API server:

- **Deleting stale EndpointSlices** → not regenerated (CM not writing)
- **Annotating controller pods** to force endpoint refresh → `resourceVersion` unchanged (CM not writing)
- **`rollout restart jiva-operator`** → annotation added, but no new RS created (deployment controller = stuck CM)
- **Force-deleting controller pods and jiva-operator** → none recreated (replicaset/deployment controller = stuck CM)
- **Manually patching Endpoints** to move controllers to `addresses` section → abandoned when pods had already been force-deleted (would have pointed to dead pod IPs)

---

## Verification

```bash
# All pods Running cluster-wide
kubectl --context pvek8s get pods -A --field-selector='status.phase!=Running' \
  --no-headers | grep -v Completed
# → (empty)

# All jiva replicas Running and connected
kubectl --context pvek8s get pods -n openebs -o wide | grep rep
# → all 24 replica pods 1/1 Running

# Jiva controller endpoints healthy (addresses, not notReadyAddresses)
kubectl --context pvek8s get endpoints -n openebs | grep jiva-ctrl-svc
# → all services show IP in addresses column

# dqlite leader is k8s01 (writes are local, no network hop)
# confirm via k8s-dqlite logs or /var/snap/microk8s/current/var/kubernetes/backend/info.yaml
```

---

## Preventive Measures

### Immediate Actions Required

1. **Add Nagios alert: Jiva controller service endpoints stuck in notReadyAddresses** (High)
    - Alert when any `-jiva-ctrl-svc` Endpoint object has one or more entries in `notReadyAddresses` for > 5 minutes. This directly detects the endpoint deadlock before it becomes a multi-hour outage.
    - Issue: [#47](https://github.com/pgmac-net/incidents/issues/47)

2. **Add Nagios alert: Jiva replica pods in CrashLoopBackOff** (High)
    - Alert when any Jiva replica pod (`-rep-`) has `restartCount > 5` or is in `CrashLoopBackOff` status. Catches replica failures early, before extended deadlock sets in.
    - Issue: [#48](https://github.com/pgmac-net/incidents/issues/48)

### Longer-Term Improvements

3. **Investigate: why jiva-operator failed to reconcile for ~10 hours** (Medium)
    - The original controller failure at ~12:46 AEST went undetected for 10 hours. Determine whether the jiva-operator lost its API server watch, crashed silently, or was otherwise degraded. Review jiva-operator pod logs and events around that time.
    - Issue: [#49](https://github.com/pgmac-net/incidents/issues/49)

4. **Add Nagios alert: kine.sock `use of closed network connection` reconnection failures** (Medium)
    - Tracks persistent gRPC channel pool failures on individual nodes — an early-warning signal before the kine watch stream breaks entirely. This was previously identified in the 2026-06-24 PIR (PGM-281 subtask) and is reinforced by this incident, where the broken kine.sock on k8s03 was the blocking factor for endpoint writes post-storm.
    - Linear: see PGM-281 subtask (existing)

---

## Lessons Learned

### What Went Well

- **Diagnosis was systematic:** checked endpoint state, confirmed CM was stuck (EndpointSlice test), identified KCM node, checked kine.sock and dqlite separately — a clear path to root cause.
- **Fix was non-destructive:** restarting k8s-dqlite on followers and then the leader is a low-risk operation; did not require node reboots, kubelite manual restarts, or data operations.
- **Recovery was fast once the root cause was identified:** ~11 minutes from diagnosis to all pods Running.
- **dqlite leader migration to k8s01 co-located CM with leader**, eliminating the network hop that was causing CM write failures on k8s03 — a beneficial side-effect of the fix ordering (follower first, leader second).

### What Didn't Go Well

- **10+ hours of silent degradation** with no alert. Six PVCs were degraded for most of a day with no notification.
- **Wasted diagnostic time on wrong approaches:** EndpointSlice deletion, rollout restarts, pod force-deletes — all no-ops when the CM can't write. The key diagnostic signal (`use of closed network connection` on the KCM's node) should have been checked first. A runbook would have saved ~15 minutes.
- **Manual Endpoints patch was wrong:** Patching the Endpoints object to move controllers to `addresses` is only valid if the pods are Running. Once pods were force-deleted, the patch would have pointed to dead IPs. The correct fix was to restore CM write capability first, then let it manage endpoints.
- **Force-deleting the jiva-operator** was unnecessary. The jiva-operator had already done its job (recreating controller pods); deleting it caused a temporary gap in reconciliation coverage.
- **Restarting k8s-dqlite on k8s03 also restarted k8s03 kubelite** — an unintended side-effect. This was safe in this case (k8s03 kubelite was already degraded), but future operators should be aware that k8s-dqlite and kubelite can be coupled in this way on some microk8s configurations.

### Surprise Findings

- **Restarting k8s-dqlite on k8s03 caused kubelite to restart.** On k8s03 specifically, kubelite was tightly coupled to the k8s-dqlite service at restart time. This was not expected — `snap.microk8s.daemon-k8s-dqlite` is a separate systemd unit from `snap.microk8s.daemon-kubelite`.
- **The Jiva endpoint deadlock is self-sustaining.** Once endpoints are stuck in `notReadyAddresses`, replicas crash → no replicas register → controller never achieves quorum → controller doesn't update its status → endpoints stay not-ready. This loop cannot be broken by KCM endpoint writes alone after replicas have been crashing for a while; the controller pods also need to be fresh.
- **CM leader election doesn't consider kine connectivity.** A CM instance on a node with a broken kine.sock can hold the lease indefinitely (lease renewal is separate from write capability), blocking any other CM from taking over and healing state.

---

## Action Items

| # | Action | Priority | Linear |
|---|--------|----------|--------|
| 1 | Add Nagios alert: Jiva controller service endpoints stuck in notReadyAddresses > 5min | High | [#47](https://github.com/pgmac-net/incidents/issues/47) |
| 2 | Add Nagios alert: Jiva replica pod CrashLoopBackOff restart count > 5 | High | [#48](https://github.com/pgmac-net/incidents/issues/48) |
| 3 | Investigate why jiva-operator failed to reconcile for ~10h (original failure trigger) | Medium | [#49](https://github.com/pgmac-net/incidents/issues/49) |
| 4 | Add Nagios alert: kine.sock `use of closed network connection` reconnection failures (existing PGM-281 subtask) | Medium | PGM-281 subtask |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/172.22.22.6, k8s02/172.22.22.8, k8s03/172.22.22.9)
- **Kubernetes version:** v1.35.0
- **OpenEBS Jiva version:** 2.12.1 (jiva-operator 3.6.0)
- **dqlite leader at incident start:** k8s02
- **dqlite leader at resolution:** k8s01

### Key Error Signatures

**Jiva replica crash (connection refused to controller):**
```
error connecting to peer: dial tcp <controller-ClusterIP>:9501: connect: connection refused
```

**dqlite WAL lock contention (endpoint write failure):**
```
error in txn: update transaction failed for key /registry/endpoints/openebs/...: exec (try: 500): database is locked
```

**kine.sock broken channel pool (CM write failure):**
```
kine.sock:12379: use of closed network connection
```

### Diagnosing the KCM-stuck-writing Pattern

The definitive test that CM is not writing (and that manual intervention like pod restarts won't help):

```bash
# 1. Delete an EndpointSlice managed by CM and watch if it regenerates
ES=$(kubectl --context pvek8s get endpointslice -n openebs \
  -l kubernetes.io/service-name=<service-name> -o name | head -1)
kubectl --context pvek8s delete -n openebs "$ES"
sleep 30
kubectl --context pvek8s get endpointslice -n openebs \
  -l kubernetes.io/service-name=<service-name>
# → If no EndpointSlice: CM is not writing

# 2. Identify KCM leader node
kubectl --context pvek8s -n kube-system get lease kube-controller-manager \
  -o jsonpath='{.spec.holderIdentity}' | cut -d_ -f1

# 3. Check kine.sock on the KCM leader node
ssh <kcm-leader-node> "sudo journalctl -u snap.microk8s.daemon-kubelite \
  --since '10 minutes ago' --no-pager | grep 'use of closed network connection' | wc -l"
# → >0 confirms broken kine channel pool on KCM leader

# 4. Check dqlite lock contention (especially on leader)
for node in k8s01 k8s02 k8s03; do
  echo "=== $node ==="
  ssh "$node" "sudo journalctl -u snap.microk8s.daemon-k8s-dqlite \
    --since '5 minutes ago' --no-pager | grep -c 'database is locked'"
done
# → non-zero on leader = write storm; restart dqlite on followers then leader
```

### Recovery Procedure for Jiva Endpoint Deadlock

See [jiva-ctrl-endpoint-deadlock.md](../runbooks/jiva-ctrl-endpoint-deadlock.md) for the full runbook.

```bash
# Step 1: Find dqlite leader
ssh k8s01 "sudo cat /var/snap/microk8s/current/var/kubernetes/backend/info.yaml" | grep leader
# or check which node has the fewest 'database is locked' errors

# Step 2: Restart dqlite on follower nodes (non-leader first)
# WARNING: may also restart kubelite on those nodes
ssh k8s03 "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite"
sleep 30

# Step 3: Restart dqlite on the leader (triggers new election)
ssh k8s02 "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite"

# Step 4: Wait for CM to reconcile (~30s), then force-delete crashing replica pods
kubectl --context pvek8s get pods -n openebs | grep rep | grep -v Running | \
  awk '{print $1}' | xargs kubectl --context pvek8s delete pod -n openebs
```

---

## References

- Runbook: [jiva-ctrl-endpoint-deadlock.md](../runbooks/jiva-ctrl-endpoint-deadlock.md) — new runbook for this failure mode
- Runbook: [dqlite-write-contention.md](../runbooks/dqlite-write-contention.md) — write contention recovery and prevention
- Runbook: [control-plane-watch-cache-freeze.md](../runbooks/control-plane-watch-cache-freeze.md) — broader CM/apiserver freeze recovery
- Related PIR: [2026-06-24 k8s02 watch-cache freeze](2026-06-24-k8s02-watch-cache-freeze-dqlite-leadership-disruption.md) — previous dqlite lock storm incident; same kine.sock drop pattern on k8s03
- Issue [#47](https://github.com/pgmac-net/incidents/issues/47) — Nagios alert: Jiva controller notReadyAddresses
- Issue [#48](https://github.com/pgmac-net/incidents/issues/48) — Nagios alert: Jiva replica CrashLoopBackOff
- Issue [#49](https://github.com/pgmac-net/incidents/issues/49) — Investigate jiva-operator 10h reconciliation gap
- Linear: PGM-281 — kine.sock reconnection failure monitoring (existing subtask)

---

## Reviewers

- @pgmac
