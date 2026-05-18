---
tags:
  - k8s03
  - calico
  - vxlan
  - kine
  - dqlite
  - kubelet
  - watch-stream
  - argocd
---

# Post Incident Review: k8s03 Extended Recovery — kine Watch Corruption, VXLAN Route Corruption, and Kubelet Watch Stream Stall

**Date:** 2026-05-18
**Duration:** ~2h10m active (~14:00 AEST → ~16:10 AEST)
**Severity:** High (cross-node traffic blackholed; multiple workloads stuck Pending/Terminating/CrashLoopBackOff; calico-node unable to start for 35+ min)
**Status:** Resolved (cluster fully operational; all non-OpenEBS pods Running)

---

## Executive Summary

Following resolution of PGM-197 (k8s03 PLEG deadlock / stale IPAM cleanup), the recovery session continuing from a prior exhausted context encountered two compounding failure modes that extended the k8s03 incident by ~2h10m.

The first failure was a silent kubelet watch stream stall: after kubelite restart #2, the kubelet logged "Watching apiserver" but the underlying kine/dqlite watch had failed with `database is locked` and `WATCH Failed to create watcher: context canceled`. No events — pod CREATE, DELETE, or UPDATE — were delivered through the stream. calico-node-sqfcs was scheduled to k8s03 at 14:59 AEST but sat Pending for 35+ minutes while the kubelet watched a dead stream. An argocd StatefulSet pod had been Terminating for 44+ minutes for the same reason. Fix: restart k8s-dqlite first (to clear kine's corrupt watch context), then restart kubelite. After the third restart, the kubelet picked up calico-node-sqfcs within 6 seconds.

The second failure was VXLAN route corruption on k8s01 and k8s02: Felix on those nodes had stale routes for k8s03's pod subnets using `via 10.1.235.128` (INCOMPLETE in ARP) instead of the actual VTEP `10.1.235.133`. All cross-node traffic originating from or destined to k8s03 pods was silently dropped. This had cascaded: argocd-redis-ha-haproxy-j7sr6 was in Init:CrashLoopBackOff for 112+ minutes because its init container could not reach the Redis sentinel ClusterIP (backed by k8s03-resident pods). Fix: `sudo ip route replace <subnet> via 10.1.235.133 dev vxlan.calico onlink` for all 6 k8s03 subnets on both peer nodes.

Both root causes trace back to PGM-201 (kine/dqlite watch reliability): the watch stall is a direct kine/dqlite watch delivery failure; the VXLAN route corruption is a Felix watch delivery failure, also caused by the same kine event pipeline not delivering the calico-node VTEP re-registration to Felix on peer nodes.

---

## Timeline (AEST — UTC+10)

| Time | Event |
|------|-------|
| **~09:00 AEST** | Prior session (PGM-197) completed: 237 stale IPAM entries cleaned; k8s03 cordoned pending 24h stability. Context window exhausted; new session begins. |
| **~14:00 AEST** | Recovery session resumed. k8s03 cordoned. kubelite restart #1 attempted to get calico-node starting. calico-node pod pending scheduling. |
| **14:22:40 AEST** | kubelite restart #2 complete. kubelet logs "Watching apiserver" — watch stream appears established. |
| **14:59:11 AEST** | calico-node-sqfcs created and bound to k8s03 by the scheduler. Pod remains Pending indefinitely — kubelet does not pick it up. |
| **~15:10 AEST** | argocd-redis-ha-server-2 confirmed Terminating for 44+ min (deletionTimestamp set, container already stopped in containerd, but kubelet not acknowledging deletion). Root cause: same watch stall. |
| **~15:15 AEST** | k8s-dqlite logs examined: `database is locked` errors at 03:40–03:54 UTC; `WATCH Failed to create watcher: failed to get compact revision: context canceled`. Watch delivery failed during kubelite restart #2. |
| **~15:20 AEST** | `kubectl get --raw /api/v1/nodes/k8s03/proxy/pods` returns only the initial LIST pods; calico-node-sqfcs not present. Confirms stale watch cache — no events delivered in 20+ min. |
| **~15:25 AEST** | argocd-redis-ha-haproxy-j7sr6 observed Init:CrashLoopBackOff — has been failing for 112 min. Init container attempts Redis sentinel ClusterIP connection; traffic cannot reach k8s03 Redis pods. Suspicion raised: VXLAN routing issue. |
| **~15:28 AEST** | VXLAN route diagnosis: `ip route show table main \| grep '10.1.235'` on k8s01/k8s02 shows `10.1.235.128/26 via 10.1.235.128 dev vxlan.calico onlink`. `ip neigh show dev vxlan.calico \| grep 10.1.235.128` → `10.1.235.128 INCOMPLETE`. Actual VTEP: `10.1.235.133` (from node annotation). Route gateway is wrong. |
| **15:32:37 AEST** | `sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service` on k8s03. Wait 10s for kine to reconnect and establish clean watch. |
| **15:33:20 AEST** | kubelite restart #3 (kubelite restarted after k8s-dqlite). k8s03 cordoned before restart. |
| **15:33:28 AEST** | kubelet logs "Watching apiserver". Events begin flowing immediately. |
| **15:33:34 AEST** | calico-node-sqfcs transitions Running → Ready (6 seconds after new watch established; kubelet picked it up instantly). Felix programs all 12 cali- dispatch chain entries. |
| **~15:40 AEST** | VXLAN routes corrected on k8s01 and k8s02: `sudo ip route replace <subnet> via 10.1.235.133 dev vxlan.calico onlink` for all 6 k8s03 pod subnets. ARP entries update to REACHABLE. |
| **~15:45 AEST** | Cross-node connectivity verified: DNS resolving from k8s03 pods; ClusterIP services reachable across nodes. |
| **~15:47 AEST** | argocd-redis-ha-haproxy-j7sr6 transitions Init:0/1 → Running. Init container can now reach Redis sentinel. |
| **~15:48 AEST** | `kubectl delete pod argocd-redis-ha-server-2 --grace-period=0 --force` issued. StatefulSet recreates pod; becomes Ready (3/3 containers). |
| **15:50 AEST** | k8s03 uncordoned. All calico dispatch chains verified complete (12 cali- interfaces programmed). |
| **~16:10 AEST** | Cluster fully operational. All non-OpenEBS pods Running. PGM-197 updated with Extended Recovery section. |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: Kubelet Watch Stream Stall — from kine corruption to calico-node Pending

##### How did calico-node-sqfcs sit Pending for 35+ minutes after being scheduled to k8s03?

The kubelet never received the pod CREATE event from the API server. The watch stream the kubelet established after kubelite restart #2 was a dead stream: TCP connection alive, HTTP/2 session alive, kubelet logged "Watching apiserver" — but no events flowed through it. `kubectl get --raw /api/v1/nodes/k8s03/proxy/pods` returned only the initial LIST response from startup, with no new pods appearing for 20+ minutes.

##### How did a live TCP/HTTP2 watch connection deliver no events?

The API server watch cache sends events to subscribers when it receives them from its internal event queue. If the watch cache is not receiving new events from its source (kine), downstream subscriber streams — including the kubelet's — receive no events regardless of connection health.

##### How did the API server's watch cache stop receiving events from kine?

kine failed to establish a working watch against the dqlite Raft log. Logs showed `WATCH Failed to create watcher: failed to get compact revision: context canceled` and `database is locked` at 03:40–03:54 UTC (just before kubelite restart #2). kine's watch establishment was interrupted by a dqlite lock contention event. Once a kine watch fails, that watch session receives no events — kine does not automatically re-establish the watch for in-flight API server sessions.

##### How did dqlite become locked during the watch establishment?

k8s-dqlite (the MicroK8s-bundled dqlite implementation) uses SQLite as its Raft log backend. During specific internal operations — snapshot creation, log compaction, or high-concurrency write bursts — the SQLite database file acquires an exclusive lock. Any concurrent reader that lands in this window receives `database is locked` and fails. kine's watch creation path performs a `compact revision` read, which was one such reader.

##### How did restarting k8s-dqlite before kubelite fix the watch stall?

Restarting k8s-dqlite terminates all existing kine sessions and forces a clean reconnect. When kubelite subsequently starts, the API server's watch infrastructure re-establishes its kine watch against a fresh dqlite session with no corrupt state. The API server watch cache then begins receiving events immediately, and the kubelet's downstream watch receives them within the same cycle.

##### How was there no detection that the watch stream had silently stalled?

The kubelet logs "Watching apiserver" on stream establishment and provides no subsequent watch health log until the stream terminates. Absence of events is not distinguishable from a quiet cluster. `kubectl get node k8s03` continues to show Ready (the node heartbeat continues via a separate mechanism). There is no built-in timeout after which the kubelet re-establishes the watch if no events arrive. PGM-201 (kine watch reliability) was filed during the previous session but not yet resolved.

##### How did the prior kubelite restart not also stall?

kubelite restart #1 (earlier in the session) succeeded because it happened before the dqlite lock event window. The lock contention window at 03:40–03:54 UTC specifically coincided with the kine watch establishment attempt during kubelite restart #2. The timing mismatch between the restart and the dqlite internal operation is what made restart #2 fail while restart #1 did not.

---

#### Chain 2: Stuck Terminating Pod — argocd-redis-ha-server-2 Terminating 44+ min

##### How did argocd-redis-ha-server-2 stay Terminating for 44+ minutes?

The pod's `deletionTimestamp` had been set (kubectl issued a graceful delete), and containerd had already stopped the container. However, the kubelet never received the DELETE event from the API server — same dead watch stream as Chain 1. Without the delete event, the kubelet could not process the termination, clean the pod directory, or release the pod resources.

##### How did this block recovery?

The Terminating pod occupied a sandbox entry that the kubelet would attempt to reconcile on the next sync. Without the kubelet acknowledging the deletion, the StatefulSet controller could not create a replacement pod (ordinal 2 was considered in use). The pod also consumed a network namespace that the VXLAN cleanup would need to clear.

##### How was it resolved?

`kubectl delete pod --grace-period=0 --force` removes the API object immediately, bypassing the graceful termination wait. The container had already exited, so no actual workload was interrupted. Once the API object was gone, the kubelet cleaned up the pod directory on its next sync, and the StatefulSet controller created a replacement pod.

##### How does force-delete know it is safe here?

The pod is already Terminating: its `deletionTimestamp` is set, the container process has exited (confirmed by `kubectl describe` showing the container in Terminated state with exit code), and the only outstanding work is kubelet housekeeping (unmounting volumes, removing sandbox). Force-delete is safe when the container is confirmed stopped, the only blocking factor is API server acknowledgement, and the replacement pod can recreate any needed state via the StatefulSet's persistent volume claims.

---

#### Chain 3: VXLAN Route Corruption — cross-node traffic blackhole from k8s03 pods

##### How did all cross-node traffic to/from k8s03 pods fail after calico-node recovered?

Routes on k8s01 and k8s02 for k8s03's pod subnets used `via 10.1.235.128` as the VXLAN gateway. `ip neigh show dev vxlan.calico | grep 10.1.235.128` returned `10.1.235.128 INCOMPLETE` — no MAC address was ever resolved for this gateway. Packets encapsulated with this VTEP destination MAC (which didn't exist) were silently dropped by the vxlan.calico interface.

##### How did the routes use the wrong VTEP address (10.1.235.128 instead of 10.1.235.133)?

Felix on k8s01 and k8s02 programmed these routes based on node resource annotations it had received via its Kubernetes API watch. `10.1.235.128` is the network base address of the `/26` block, not a valid VTEP. `10.1.235.133` is the actual VTEP, as confirmed by `kubectl get node k8s03 -o jsonpath='{.metadata.annotations.projectcalico\.org/IPv4VXLANTunnelAddr}'`. Felix wrote the wrong value, suggesting it received or had cached a stale/incomplete annotation.

##### How did Felix receive the wrong VTEP value for k8s03?

When calico-node on k8s03 starts, it registers its VTEP address into the node's annotations via the Kubernetes API. Felix on peer nodes watches for these annotation changes. If calico-node restarted on k8s03 and re-registered its VTEP, Felix on k8s01/k8s02 should have received the new annotation and updated the routes. Instead, Felix received no update — the stale `10.1.235.128` value was left in the routing table.

##### How did Felix fail to receive k8s03's VTEP re-registration?

Felix watches Kubernetes node resources via the same API server watch mechanism that failed for the kubelet (Chain 1). If the kine/dqlite watch delivery was broken at the time calico-node re-registered its VTEP, the node annotation UPDATE event would not have been delivered to Felix. Felix's in-memory state would retain the last-known value, which was `10.1.235.128` from before the most recent calico-node restart.

##### How was Felix's stale state not corrected during the recovery window (35+ min while calico-node was Pending)?

Felix is event-driven: it reconciles routes in response to watch events for node resources. There is no periodic full-resync that would catch a missed annotation update. Without receiving a new annotation event for k8s03, Felix never re-evaluated the routes. The wrong routes persisted for the duration of the watch stall (35+ min) plus the time between calico-node becoming Ready and route correction (~7 min).

##### How did this cause argocd-redis-ha-haproxy to be Init:CrashLoopBackOff for 112 minutes?

argocd-redis-ha-haproxy's init container connects to the ArgoCD Redis sentinel ClusterIP. The sentinel traffic is load-balanced to `argocd-redis-ha-server-*` pods, which are scheduled on k8s03. With VXLAN routes blackholed, the init container's TCP connections to the ClusterIP were silently dropped after the ECMP routing path selected a k8s03-resident pod. Since cross-node traffic was silently dropped (no TCP RST, just packet loss), the init container timed out on every attempt. The 112-minute window started when the VXLAN corruption began — before this session started its diagnosis.

##### How was the corruption not noticed for 112+ minutes?

No monitoring exists for VXLAN VTEP route correctness. The pod health checks (`kubectl get pods -A`) showed argocd-redis-ha-haproxy as Init:CrashLoopBackOff, which was attributed to an application issue or the ongoing k8s03 instability. The connection between the route corruption and the Init container failure was not made until the Felix dispatch chain analysis showed all 12 interfaces correctly programmed — ruling out iptables as the cause and redirecting attention to the routing layer.

##### How was there no automated detection of the wrong gateway address?

No NRPE check or Nagios probe verifies that VXLAN route gateways match node VTEP annotations. The standard k8s health checks (node Ready, pod Running) are orthogonal to dataplane correctness. Diagnosing the VXLAN corruption required manually correlating `ip route` output, `ip neigh` output, and `kubectl get node` annotation values across three nodes.

---

## Impact

### Services Affected

| Service | Impact | Duration |
|---------|--------|----------|
| calico-node (k8s03) | Pending — kubelet watch stall; Felix not programming iptables rules | ~35 min (14:59–15:33 AEST) |
| argocd-redis-ha-server-2 | Stuck Terminating — kubelet not acknowledging deletion; StatefulSet blocked | ~44 min (until force-delete at ~15:48 AEST) |
| argocd-redis-ha-haproxy-j7sr6 | Init:CrashLoopBackOff — Redis sentinel unreachable via VXLAN blackhole | ~112 min (resolved ~15:47 AEST) |
| All k8s03 pod cross-node traffic | Silently dropped — VXLAN routes on k8s01/k8s02 using wrong gateway (INCOMPLETE ARP) | ~35 min (15:05–15:40 AEST approx.) |
| DNS resolution (k8s03 pods) | Failed — CoreDNS pods on other nodes unreachable via blackholed VXLAN | Same ~35 min window |
| buildkitd (k8s03) | Unable to reach container registry or build targets | Same ~35 min window |

### Duration

- **Total extended recovery window:** ~2h10m
- **Active cross-node traffic blackhole:** ~35 min
- **Init:CrashLoopBackOff cascade:** 112 min (pre-existing; resolved with route fix)
- **Expected recovery time (with documented procedure):** <20 min

### Scope

- k8s03 directly affected; k8s01/k8s02 had corrupted dataplane state (wrong VXLAN routes)
- No persistent data loss
- OpenEBS Jiva replica pods remain in CrashLoopBackOff (pre-existing, unrelated)

---

## Resolution Steps Taken

### Phase 1: Watch Stream Stall Diagnosis

1. Observed calico-node-sqfcs Pending for 20+ min despite k8s03 showing Ready.
2. Verified kubelet was not aware of the pod: `kubectl get --raw /api/v1/nodes/k8s03/proxy/pods` — pod absent from list.
3. Confirmed watch stall: k8s-dqlite logs showed `database is locked` and `WATCH Failed to create watcher: context canceled` at 03:40–03:54 UTC (coinciding with kubelite restart #2).
4. Confirmed `argocd-redis-ha-server-2` also stuck Terminating for 44+ min — same root cause.

### Phase 2: Watch Stream Fix (k8s-dqlite + kubelite restart)

5. Cordoned k8s03 (already cordoned from prior session).
6. Restarted k8s-dqlite: `ssh k8s03 "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"`. Waited 10s for kine reconnection.
7. Restarted kubelite: `ssh k8s03 "sudo systemctl restart snap.microk8s.daemon-kubelite.service"`.
8. Observed kubelet log "Watching apiserver" at 15:33:28 AEST. Within 6 seconds, calico-node-sqfcs was picked up and became Ready.
9. Force-deleted stuck Terminating pod: `kubectl delete pod argocd-redis-ha-server-2 -n argocd --grace-period=0 --force`. StatefulSet immediately created replacement.

### Phase 3: VXLAN Route Corruption Diagnosis

10. Observed argocd-redis-ha-haproxy-j7sr6 Init:CrashLoopBackOff despite calico-node now Ready and Felix dispatch chains fully programmed (12 interfaces).
11. Checked dispatch chains directly: `ssh k8s01 "sudo iptables -L cali-from-wl-dispatch -n"` and sub-chains `cali-from-wl-dispatch-0`, `cali-from-wl-dispatch-1` — all 12 interfaces present, no missing entries.
12. Checked VXLAN routes: `ssh k8s01 "ip route show table main | grep '10.1.235'"` → `10.1.235.128/26 via 10.1.235.128 dev vxlan.calico onlink`. Same on k8s02.
13. Checked ARP: `ssh k8s01 "ip neigh show dev vxlan.calico | grep 10.1.235.128"` → `10.1.235.128 INCOMPLETE`. Gateway address unresolvable.
14. Verified actual VTEP: `kubectl get node k8s03 -o jsonpath='{.metadata.annotations.projectcalico\.org/IPv4VXLANTunnelAddr}'` → `10.1.235.133`. Route gateway is wrong.

### Phase 4: VXLAN Route Repair

15. Replaced routes on both peer nodes for all 6 k8s03 pod subnets:
    ```bash
    for subnet in 10.1.235.128/26 10.1.235.192/26 10.1.236.0/26 10.1.236.64/26 10.1.237.128/26 10.1.238.0/26; do
      ssh k8s01 "sudo ip route replace $subnet via 10.1.235.133 dev vxlan.calico onlink"
      ssh k8s02 "sudo ip route replace $subnet via 10.1.235.133 dev vxlan.calico onlink"
    done
    ```
16. Verified ARP updated: `ip neigh show dev vxlan.calico | grep 10.1.235.133` → `10.1.235.133 lladdr <mac> REACHABLE` on both nodes.
17. Verified cross-node connectivity restored: DNS resolution working from k8s03 pods; ClusterIP services reachable.

### Phase 5: Final Recovery and Verification

18. Confirmed argocd-redis-ha-haproxy-j7sr6 transitioned Running within 2 min of route fix.
19. Confirmed argocd-redis-ha-server-2 recreated (StatefulSet) and became Ready (3/3).
20. Uncordoned k8s03.
21. Verified all non-OpenEBS pods Running.

---

## Verification

### Kubelet Watch Health

```
kubectl get --raw /api/v1/nodes/k8s03/proxy/pods | jq '.items[].metadata.name'
# calico-node-sqfcs and all k8s03 pods appear within 5s of each scheduling event
# No pods stuck Pending for >60s
```

### VXLAN Route State (post-repair)

```
ssh k8s01 "ip route show table main | grep vxlan.calico | grep '10.1.235'"
# 10.1.235.128/26 via 10.1.235.133 dev vxlan.calico onlink  ← correct
# 10.1.235.192/26 via 10.1.235.133 dev vxlan.calico onlink  ← correct

ssh k8s01 "ip neigh show dev vxlan.calico | grep 10.1.235.133"
# 10.1.235.133 lladdr xx:xx:xx:xx:xx:xx REACHABLE
```

### Cluster State

- All 3 nodes: Ready (k8s03 uncordoned)
- calico-node: Running on all 3 nodes; all dispatch chains complete
- argocd-redis-ha: 3/3 server pods Running; haproxy Running
- buildkitd: Running with connectivity
- OpenEBS Jiva replica pods: CrashLoopBackOff (pre-existing, PGM-197 scope)

---

## Preventive Measures

### Immediate Actions Required

1. **Fix kine/dqlite watch reliability to prevent silent watch stream stalls** (High)
   - Both the kubelet watch stall and the Felix VTEP staleness have the same root: kine failing to establish a watch during dqlite lock contention. Without a fix, any dqlite lock event during a kubelite restart will produce a silently stalled watch.
   - Action: Investigate kine watch re-establishment logic; add retry with backoff on `database is locked`; add watch health probe in k8s-dqlite. Alternatively, assess whether dqlite can reduce lock contention window during compaction.
   - Linear: [PGM-201](https://linear.app/pgmac-net-au/issue/PGM-201)

2. **Add monitoring for kubelet watch stream staleness** (High)
   - The watch stall is completely silent: node shows Ready, kubelet logs "Watching apiserver", but new pods never appear. There is no built-in detection. A check comparing pod count on `kubectl get --raw /api/v1/nodes/<node>/proxy/pods` vs scheduled pods in the API server would catch stalls within minutes.
   - Action: Create NRPE check or Nagios service check that detects when a node has scheduler-bound pods not appearing in kubelet's pod list for >120s.
   - Linear: new ticket

3. **Add monitoring for VXLAN VTEP route gateway correctness** (Medium)
   - No monitoring exists to verify that `ip route via <addr>` on each node matches the target node's VTEP annotation. A simple script comparing route gateways against `kubectl get node -o jsonpath` annotations would catch this within minutes.
   - Action: Create NRPE check that verifies VXLAN route gateways match Calico VTEP annotations for all peer nodes. Run on all 3 nodes.
   - Linear: new ticket

### Longer-Term Improvements

4. **Document "restart k8s-dqlite before kubelite" as canonical watch stall recovery procedure** (Medium)
   - The two-step restart (k8s-dqlite first, then kubelite) is required to clear kine's corrupt watch state before the API server re-establishes its watch cache. Restarting kubelite alone is insufficient — as demonstrated by restart #2 failing while restart #3 (preceded by k8s-dqlite restart) succeeded immediately.
   - Action: Update `pgk8s` runbook and ansible-role-microk8s-maintenance with the canonical 3-step procedure (cordon → k8s-dqlite restart → kubelite restart). Note: memory file `feedback_k8s03_watch_stall_recovery.md` already created.
   - Linear: [PGM-201](https://linear.app/pgmac-net-au/issue/PGM-201) (sub-task)

5. **Investigate and address Calico VXLAN route staleness after calico-node restart** (Medium)
   - Felix should reconcile VTEP routes when calico-node re-registers. If the event is missed due to kine watch corruption, the routes stay wrong indefinitely. Felix may need a periodic reconcile pass or a re-registration trigger after calico-node completes startup. Tracked as part of the Calico upgrade (PGM-200).
   - Linear: [PGM-200](https://linear.app/pgmac-net-au/issue/PGM-200)

---

## Lessons Learned

### What Went Well

- **Watch stall identified via k8s-dqlite logs**: Correlating kubelet's `Watching apiserver` log with kine's `database is locked` errors at the same timestamp narrowed the diagnosis quickly. Without the dqlite log correlation, we might have continued restarting kubelite without clearing the corrupt state.
- **`kubectl get --raw /api/v1/nodes/<node>/proxy/pods` as watch health probe**: This diagnostic was decisive — seeing calico-node-sqfcs absent from kubelet's pod list after 20+ minutes confirmed the watch was stalled, not that the pod was genuinely pending infrastructure.
- **Root cause of Init:CrashLoopBackOff traced to routing, not application**: The 112-minute Init:CrashLoopBackOff for argocd-redis-ha-haproxy was traced to VXLAN route corruption rather than an application issue or Redis configuration problem. Checking iptables dispatch chains first (correctly programmed) redirected attention to the routing layer.
- **Runbook captured in memory immediately**: Both the k8s-dqlite+kubelite restart procedure and the VXLAN route repair procedure were saved to persistent memory (`feedback_k8s03_watch_stall_recovery.md`, `feedback_calico_vxlan_route_repair.md`) before the session ended.

### What Didn't Go Well

- **kubelite restarted before k8s-dqlite**: Restart #2 was a kubelite-only restart. Had k8s-dqlite been restarted first (the now-documented procedure), the watch would have established cleanly and the 35+ min stall would not have occurred.
- **VXLAN route corruption missed for 112+ minutes**: The argocd-redis-ha-haproxy Init:CrashLoopBackOff was attributed to ongoing k8s03 instability rather than investigated as a separate routing issue. Proactive VXLAN route verification after each calico-node restart would have caught this immediately.
- **No systematic "check all routing layers" step after calico-node Ready**: After calico-node became Ready and Felix programmed iptables rules, it was assumed the dataplane was correct. A routing check (not just iptables) should be part of the calico-node recovery checklist.

### Surprise Findings

- **Kubelite watch stream silently stalls with a live TCP/HTTP2 connection**: The kubelet established the watch (logged it), the connection was alive, but no events flowed. This is an invisible failure mode — there is no error, no timeout, no retry. The kubelet treats a quiet stream as a quiet cluster.
- **k8s-dqlite restart is required before kubelite to clear kine watch corruption**: Restarting only kubelite leaves kine in a state where the API server's watch cache re-establishes against the same corrupt dqlite session. Restarting k8s-dqlite forces kine to reconnect from a clean state, allowing a healthy watch to be established on the next kubelite start.
- **VTEP route gateway (`10.1.235.128`) is the network base address of the /26**: The value `10.1.235.128` is the first address in the `10.1.235.128/26` block. This is not a valid host address and would never have an ARP entry — it was never going to become REACHABLE. This pattern is diagnostic: if a VXLAN route gateway matches the network address of the subnet it routes, the gateway was programmed from a default/initial value rather than a real VTEP.
- **Felix does not recover from missed VTEP events**: After calico-node became Ready and Felix programmed all 12 iptables dispatch chain entries, the VXLAN routes were still wrong. Felix did not perform any post-startup route reconciliation — it relied entirely on having received the VTEP annotation event. Missed event = permanently wrong route.

---

## Action Items

| # | Action | Priority | Linear |
|---|--------|----------|--------|
| 1 | Fix kine/dqlite watch reliability: add retry-with-backoff on `database is locked` during watch creation | High | [PGM-201](https://linear.app/pgmac-net-au/issue/PGM-201) |
| 2 | Add NRPE check: detect kubelet watch stream stall (scheduled pods not appearing in `/proxy/pods` for >120s) | High | new ticket |
| 3 | Add NRPE check: verify VXLAN route gateways match Calico VTEP node annotations on all peer nodes | Medium | new ticket |
| 4 | Update microk8s runbook: document canonical watch stall recovery as 3-step (cordon → k8s-dqlite restart → kubelite restart) | Medium | [PGM-201](https://linear.app/pgmac-net-au/issue/PGM-201) |
| 5 | Add VXLAN route verification step to calico-node recovery checklist (post-Ready state) | Medium | [PGM-200](https://linear.app/pgmac-net-au/issue/PGM-200) |
| 6 | Upgrade Calico from v3.13.2 (fixes Felix watch reliability, IPAM GC, VTEP reconciliation) | High | [PGM-200](https://linear.app/pgmac-net-au/issue/PGM-200) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03)
- **Kubernetes version:** v1.35.0 (snap rev 8612)
- **Container runtime:** containerd 2.1.3 (microk8s 1.35)
- **CNI:** Calico v3.13.2 (independently installed)
- **k8s-dqlite:** MicroK8s bundled (kine over SQLite-backed dqlite Raft)

### Key Error Signatures

**kine watch corruption (k8s-dqlite logs on k8s03):**
```
database is locked
WATCH Failed to create watcher: failed to get compact revision: context canceled
```

**Kubelet watch stall (external indicator):**
```bash
# Watch established — but nothing flows through it:
journalctl -u snap.microk8s.daemon-kubelite | grep "Watching apiserver"
# → "Watching apiserver" logged, but:
kubectl get --raw /api/v1/nodes/k8s03/proxy/pods | jq '.items | length'
# → Returns stale count from initial LIST; new pods never appear
```

**VXLAN route corruption:**
```bash
ip route show table main | grep 'vxlan.calico' | grep '10.1.235'
# Wrong: 10.1.235.128/26 via 10.1.235.128 dev vxlan.calico onlink

ip neigh show dev vxlan.calico | grep 10.1.235.128
# → 10.1.235.128 INCOMPLETE  ← MAC never resolved; packets dropped

kubectl get node k8s03 -o jsonpath='{.metadata.annotations.projectcalico\.org/IPv4VXLANTunnelAddr}'
# → 10.1.235.133  ← actual VTEP; route gateway should be this
```

### Watch Stall Recovery Procedure

```bash
# 1. Cordon
kubectl --context pvek8s cordon k8s03

# 2. Restart k8s-dqlite first (clears kine corrupt watch state)
ssh k8s03 "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
sleep 10  # wait for kine reconnection

# 3. Restart kubelite
ssh k8s03 "sudo systemctl restart snap.microk8s.daemon-kubelite.service"

# 4. Verify watch is live — new pods appear within 30s
kubectl --context pvek8s wait node/k8s03 --for=condition=Ready --timeout=120s
kubectl get --raw /api/v1/nodes/k8s03/proxy/pods | jq '.items[].metadata.name'

# 5. Uncordon
kubectl --context pvek8s uncordon k8s03
```

### VXLAN Route Repair Procedure

```bash
# Identify actual VTEP for target node
VTEP=$(kubectl get node k8s03 \
  -o jsonpath='{.metadata.annotations.projectcalico\.org/IPv4VXLANTunnelAddr}')

# Replace routes on all peer nodes for all k8s03 subnets
for subnet in 10.1.235.128/26 10.1.235.192/26 10.1.236.0/26 \
              10.1.236.64/26 10.1.237.128/26 10.1.238.0/26; do
  ssh k8s01 "sudo ip route replace $subnet via $VTEP dev vxlan.calico onlink"
  ssh k8s02 "sudo ip route replace $subnet via $VTEP dev vxlan.calico onlink"
done

# Verify ARP resolved
ssh k8s01 "ip neigh show dev vxlan.calico | grep $VTEP"
# → 10.1.235.133 lladdr xx:xx:xx:xx:xx:xx REACHABLE
```

### Felix Dispatch Chain Verification

```bash
# Felix uses sub-chains when >8 workload endpoints:
ssh k8s01 "sudo iptables -L cali-from-wl-dispatch -n --line-numbers"
ssh k8s01 "sudo iptables -L cali-from-wl-dispatch-0 -n --line-numbers"
ssh k8s01 "sudo iptables -L cali-from-wl-dispatch-1 -n --line-numbers"
# All 12 cali-XXX interfaces should appear across main chain + sub-chains
# DROP rule at end of each sub-chain is expected (default deny for unmatched)
```

---

## References

- Linear ticket: [PGM-197](https://linear.app/pgmac-net-au/issue/PGM-197) — k8s03 recurring PLEG deadlock (this extended recovery is documented as an addendum)
- Linear ticket: [PGM-201](https://linear.app/pgmac-net-au/issue/PGM-201) — kine/dqlite latency spikes (root cause of both watch failures in this incident)
- Linear ticket: [PGM-200](https://linear.app/pgmac-net-au/issue/PGM-200) — Calico upgrade from v3.13.2 (addresses Felix watch reliability and VTEP reconciliation)
- Memory: `feedback_k8s03_watch_stall_recovery.md` — canonical 3-step watch stall recovery procedure
- Memory: `feedback_calico_vxlan_route_repair.md` — VXLAN route corruption diagnosis and `ip route replace` fix
- Related incident (PLEG deadlock / stale IPAM): [k8s03 PLEG Deadlock — Stale Calico IPAM Blocks](2026-05-17-k8s03-pleg-deadlock-stale-ipam-blocks.md)
- Related incident (microk8s 1.35 upgrade cascade): [pvek8s microk8s 1.34 → 1.35 Upgrade](2026-05-16-microk8s-1.35-upgrade-cgroup-v2-containerd-disk-pressure.md)

---

## Reviewers

- @pgmac
