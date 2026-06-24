---
tags:
  - k8s02
  - dqlite
  - kine
  - watch-cache
  - kcm
  - control-plane
  - microk8s
---

# Post Incident Review: k8s02 Watch-Cache Freeze — dqlite Leadership Disruption Stalls Pod Creation

**Date:** 2026-06-24
**Duration:** ~4h active (Nagios alert ~20:20 UTC → recovery ~00:20 UTC 2026-06-25); underlying dqlite disruption at 16:16 UTC
**Severity:** High (KCM stalled cluster-wide; zero pod creations for ~4h; running workloads unaffected)
**Status:** Resolved

---

## Executive Summary

At ~16:16 UTC on 2026-06-24, k8s02's dqlite daemon experienced a raft leadership disruption — logging "no known leader" and "reported leader server is not the leader" warnings before all transactions started failing with "context canceled". The dqlite service remained `active` in systemd but stopped emitting logs after 16:26 UTC.

At some point after the raft disruption, the gRPC watch stream between k8s02's apiserver and the kine socket (`kine.sock`) broke. Because k8s02 held the KCM leader lease, the stalled watch cache meant the KCM could no longer reconcile any objects: Deployments stopped replacing terminated pods, CronJobs stopped firing, and ARC runners stopped launching. No process-level alerts fired — the dqlite daemon, kubelite, and all leases appeared healthy to every existing check.

The `microk8s-watch-cache` Nagios check on k8s02 detected the frozen cache and began firing CRITICAL. The `microk8s-newest-pod-age` check corroborated the stall (no pod created cluster-wide for >30m). Both checks had been firing for ~4h before investigation began.

Recovery followed the [control-plane-watch-cache-freeze runbook](../runbooks/control-plane-watch-cache-freeze.md): cordon k8s02, restart `snap.microk8s.daemon-k8s-dqlite`, restart `snap.microk8s.daemon-kubelite`, verify RV=0 cache reflects fresh writes, uncordon. The KCM lease immediately moved to k8s01 and pod creation resumed within seconds.

The root cause of the dqlite leadership disruption is under investigation (PGM-281). This PIR covers the detection gap and the recovery path.

---

## Timeline (UTC)

| Time | Event |
|------|-------|
| **16:16 UTC** | k8s02 dqlite begins logging raft warnings: "no known leader", "reported leader server is not the leader" (multiple attempts across all three nodes) |
| **16:16 UTC** | All kine transactions on k8s02 fail: "context deadline exceeded", "context canceled" for `/registry/health`, events, node leases, ingress leases |
| **16:26 UTC** | Last dqlite log entry on k8s02 — service stays `active` but completely silent |
| **~20:04 UTC** | Kubelite on k8s02 logs `kine.sock: use of closed network connection` — gRPC watch stream from apiserver to kine has died |
| **~20:09 UTC** | Last kine.sock error in kubelite logs; cache has been frozen since ~20:04 |
| **~20:20 UTC** | `microk8s-watch-cache` CRITICAL fires on k8s02 (NRPE polling interval); `microk8s-newest-pod-age` CRITICAL fires on all nodes (no pod created cluster-wide for >30m) |
| **~00:10 UTC (+1d)** | Investigation begins; Nagios alerts reviewed; user reports both checks firing on all three nodes for ~4h |
| **~00:12 UTC** | RV=0 canary test confirms k8s02 cache frozen (stale annotations from ~16:16 UTC, ~4h old); k8s01 and k8s03 caches healthy |
| **~00:13 UTC** | KCM leader lease holder confirmed as `k8s02_7f7db8d0-b54f-432a-a75b-915ea452be27`; dqlite client unavailable; dqlite logs confirm 16:16 UTC disruption |
| **~00:15 UTC** | No "database is locked" warnings found in dqlite logs — safe to proceed with restart |
| **~00:15 UTC** | `kubectl cordon k8s02` |
| **~00:15 UTC** | `systemctl restart snap.microk8s.daemon-k8s-dqlite` on k8s02 |
| **~00:16 UTC** | Wait 30s; zero "database is locked" errors confirmed |
| **~00:16 UTC** | `systemctl restart snap.microk8s.daemon-kubelite` on k8s02 |
| **~00:18 UTC** | RV=0 test on k8s02 shows fresh canary stamp — watch cache live |
| **~00:18 UTC** | Canary pod scheduled to k8s02; reaches `Succeeded`; visible in k8s02 RV=0 cache read |
| **~00:19 UTC** | `kubectl uncordon k8s02` |
| **~00:19 UTC** | KCM lease moves to `k8s01_944b8f8c-9407-4692-a5a0-9c33bd109f67` |
| **~00:19 UTC** | Backlog drains: CronJobs, ARC runners, hostpath-provisioner jobs all resume immediately; newest pod < 2m |

---

## Root Causes

### Immediate cause (confirmed): k8s02 kine watch stream broke after dqlite leadership disruption

At 16:16 UTC, k8s02's dqlite daemon lost track of the raft leader. The "no known leader" / "reported leader is not the leader" cascade caused all in-flight kine transactions to fail with `context canceled`. After 16:26 UTC, dqlite stopped logging. At some subsequent point (~20:04 UTC), the gRPC watch stream between k8s02's apiserver and kine died and was never re-established. The apiserver's watch cache froze at the state it held when the stream broke.

### Compounding cause (confirmed): KCM leader was on k8s02

The KCM leader lease was held by k8s02. With k8s02's cache frozen, the KCM could not see any new object changes. Pod creation, CronJob scheduling, and Deployment reconciliation all halted cluster-wide for the duration. k8s01 and k8s03 controllers were followers and did not take over.

### Detection gap (confirmed): 3.5h between dqlite disruption and kine.sock breaking

The dqlite disruption happened at 16:16 UTC but the kine.sock watch stream only broke visibly at 20:04 UTC. During the 3.5h gap, the dqlite service was `active` and k8s01/k8s03 quorum reads still worked, masking the underlying instability. The exact mechanism of this delay is under investigation (PGM-281).

### Root cause of dqlite disruption (unknown — under investigation PGM-281)

The trigger for the raft leadership disruption at 16:16 UTC is not yet established. Hypotheses:
1. **Write storm** — high-frequency writes from calico-node, openebs, or ARC runner churn overloaded the raft pipeline (pattern from PGM-237)
2. **Transient network partition** — brief packet loss between k8s02 and the other dqlite members caused leader election timeout
3. **dqlite bug** — a goroutine or connection in k8s-dqlite entered a bad state that stopped it from tracking raft membership correctly

---

## What Went Well

- `microk8s-watch-cache` and `microk8s-newest-pod-age` Nagios checks correctly detected the freeze — both were added specifically to catch PGM-241-class failures
- The RV=0 canary test immediately pinpointed k8s02 as the frozen node (k8s01 and k8s03 tested healthy)
- The recovery runbook was complete and accurate; no surprises during execution
- Total recovery time from diagnosis to fully restored was ~10 minutes
- No running workload was interrupted — pods already scheduled continued running throughout

## What Could Improve

- **Detection delay:** The `microk8s-watch-cache` check fires when the cache is already frozen. A check for kine.sock connection errors or dqlite raft election churn could provide earlier warning (before the stream breaks entirely)
- **Alert routing:** Both checks were classified as CRITICAL on all three nodes (newest-pod-age fires cluster-wide), which obscured that only k8s02 was the root problem — the alert message could be clearer
- **3.5h silent degradation:** The dqlite disruption at 16:16 caused errors for 10 minutes then went silent. No alert fired until 20:20. A check for dqlite error log churn or goroutine stall could have surfaced this 4h earlier
- **No automatic leader failover for KCM:** When k8s02's cache froze, the KCM lease was not revoked — k8s02 kept renewing the lease (lease renewal goroutine doesn't depend on the cache). Other nodes did not take over

---

## Action Items

| # | Action | Ticket |
|---|--------|--------|
| 1 | Investigate dqlite leadership disruption root cause: pull dqlite + kubelite logs from all nodes for 15:50–20:10 UTC 2026-06-24 window | [PGM-281](https://linear.app/pgmac-net-au/issue/PGM-281) |
| 2 | Evaluate adding Nagios check for dqlite raft election churn / kine.sock error rate as an early-warning signal | PGM-281 subtask |

---

## References

- Runbook: [control-plane-watch-cache-freeze.md](../runbooks/control-plane-watch-cache-freeze.md)
- Linear: [PGM-281](https://linear.app/pgmac-net-au/issue/PGM-281) — root cause investigation
- Related: [PGM-241](https://linear.app/pgmac-net-au/issue/PGM-241) — original watch-cache freeze incident (2026-06-10)
- Related PIR: [2026-04-02 dqlite snapshot crash-loop](2026-04-02-dqlite-snapshot-crash-loop-watch-stream-failure.md)
- Related PIR: [2026-05-15 AWX pod pending — dqlite write storm](2026-05-15-awx-pod-pending-calico-rbac-dqlite-write-storm.md)
