---
tags:
  - k8s02
  - dqlite
  - kine
  - watch-cache
  - kcm
  - control-plane
  - microk8s
  - ansible
---

# Post Incident Review: k8s02 Watch-Cache Freeze — Ansible Parallel dqlite Restart Stalls Pod Creation

**Date:** 2026-06-24
**Duration:** ~4h active (Nagios alert ~20:20 UTC → recovery ~00:20 UTC 2026-06-25); underlying dqlite disruption at 16:16 UTC
**Severity:** High (KCM stalled cluster-wide; zero pod creations for ~4h; running workloads unaffected)
**Status:** Resolved

---

## Executive Summary

At 16:02 UTC on 2026-06-24, `update/home.yml` ran against the k8s group without `serial: 1`. The playbook processed k8s01 and k8s03 in parallel. After upgrading packages and modifying `/var/snap/microk8s/current/args/k8s-dqlite`, the Ansible handler fired `systemctl restart snap.microk8s.daemon-k8s-dqlite` on both nodes at the **same second** (16:16:06 UTC). Ansible also restarted kubelite on both nodes at 16:16:10 UTC.

With k8s01 and k8s03 dqlite simultaneously offline, k8s02 (the only remaining raft member) could not achieve quorum. All kine transactions on k8s02 failed with `context canceled`. k8s01 and k8s03 dqlite restarted within ~2 seconds (16:16:08), raft re-elected a leader, and those nodes recovered normally. k8s02's kubelite was never restarted — its existing HTTP/2 watch stream connection stayed alive via TCP keepalives but stopped delivering events after the raft disruption.

From 16:26 UTC (after raft recovery), k8s02's watch cache appeared to work — the watch stream was alive and delivering events via the old HTTP/2 connection. At ~20:04 UTC, the long-lived HTTP/2 watch stream connection finally closed (after ~3.5h of degraded operation and sustained write contention). The apiserver's watch cache froze. Because k8s02 held the KCM leader lease, all pod creation, CronJob scheduling, and Deployment reconciliation halted cluster-wide.

The `microk8s-watch-cache` Nagios check detected the freeze at ~20:20 UTC. Recovery followed the [control-plane-watch-cache-freeze runbook](../runbooks/control-plane-watch-cache-freeze.md): cordon k8s02, restart `snap.microk8s.daemon-k8s-dqlite`, restart `snap.microk8s.daemon-kubelite`, verify, uncordon. Total recovery time ~10 minutes.

**Fix applied (PGM-281):** Added `serial: 1` to the `k8s` play in `update/home.yml`.

---

## Timeline (UTC)

| Time | Event |
|------|-------|
| **16:02 UTC** | Ansible `update/home.yml` begins on k8s01 AND k8s03 simultaneously (no `serial: 1`) — `AnsiballZ_setup.py` runs on both nodes at same second |
| **16:03-16:04 UTC** | APT update + full upgrade runs on k8s01 and k8s03 simultaneously |
| **16:04-16:10 UTC** | dqlite `database is locked` (try: 500) on k8s01 and k8s03 — write contention from lease updates; Ansible's APT activity adds write pressure |
| **16:14:22 UTC** | k8s02 kubelite logs first kine.sock connection failure (`operation was canceled`) — pre-existing write contention propagates to k8s02 kine |
| **16:15:51-16:16:02 UTC** | Ansible modifies `/var/snap/microk8s/current/args/k8s-dqlite` on k8s01 and k8s03: adds `--metrics` and `--metrics-listen=127.0.0.1:9042` |
| **16:16:03-16:16:05 UTC** | Ansible queries journald for "database is locked" and "use of closed network connection" errors — detects contention but does not abort |
| **16:16:06 UTC** | **Root cause:** `ansible.builtin.systemd state=restarted` fires for `snap.microk8s.daemon-k8s-dqlite` on k8s01 AND k8s03 at the same second |
| **16:16:07 UTC** | k8s02 dqlite sees `connection refused` to k8s01 (172.22.22.6) and k8s03 (172.22.22.9) — both peers offline simultaneously |
| **16:16:07-16:16:31 UTC** | k8s02 dqlite: `no known leader` (18+ attempts) → all kine transactions fail: `context canceled`, `context deadline exceeded` |
| **16:16:08 UTC** | k8s01 and k8s03 dqlite restart with new PIDs — raft begins leader election |
| **16:16:10 UTC** | Ansible restarts kubelite on k8s01 and k8s03 — new kubelite PIDs establish fresh connections to newly-restarted dqlite |
| **16:16:24-16:16:30 UTC** | k8s01 and k8s03 new dqlite elect leader; raft cluster reforms; k8s02 reconnects as raft follower |
| **~16:26 UTC** | k8s02 dqlite reconnects to new raft leader; kine resumes event delivery on existing HTTP/2 watch stream; last dqlite log entry (recovery complete) |
| **16:24-20:04 UTC** | k8s02 kubelite logs `kine.sock: use of closed network connection` every ~4-5 min — gRPC connection pool channels failing to reconnect; watch stream on existing HTTP/2 connection still alive |
| **~16:27 UTC** | dqlite `database is locked` resumes on k8s01 and k8s03 — write contention continues after restart (hostpath-provisioner, masterleases TTL) |
| **~20:04 UTC** | Long-lived HTTP/2 watch stream connection on k8s02 finally closes (sustained write contention + ~3.5h TCP lifetime) |
| **~20:20 UTC** | `microk8s-watch-cache` CRITICAL fires on k8s02 (NRPE polling interval); `microk8s-newest-pod-age` CRITICAL fires on all nodes (no pod created cluster-wide for >30m) |
| **~00:10 UTC (+1d)** | Investigation begins |
| **~00:12 UTC** | RV=0 canary test confirms k8s02 cache frozen (stale annotations ~4h old); k8s01 and k8s03 caches healthy |
| **~00:13 UTC** | KCM leader lease confirmed as `k8s02_7f7db8d0-b54f-432a-a75b-915ea452be27` |
| **~00:15 UTC** | `kubectl cordon k8s02` |
| **~00:15 UTC** | `systemctl restart snap.microk8s.daemon-k8s-dqlite` on k8s02 |
| **~00:16 UTC** | Wait 30s; zero "database is locked" errors confirmed |
| **~00:16 UTC** | `systemctl restart snap.microk8s.daemon-kubelite` on k8s02 |
| **~00:18 UTC** | RV=0 test on k8s02 shows fresh canary stamp — watch cache live |
| **~00:19 UTC** | `kubectl uncordon k8s02` |
| **~00:19 UTC** | KCM lease moves to `k8s01_944b8f8c-9407-4692-a5a0-9c33bd109f67` |
| **~00:19 UTC** | Backlog drains: CronJobs, ARC runners, hostpath-provisioner jobs all resume; newest pod < 2m |

---

## Root Causes

### Primary cause (confirmed): `update/home.yml` ran k8s nodes without `serial: 1`

The `k8s` play in `update/home.yml` had no `serial` directive, causing Ansible to process k8s01, k8s02, and k8s03 in parallel. When the `ansible-role-microk8s` role modified `/var/snap/microk8s/current/args/k8s-dqlite` on k8s01 and k8s03, the handler fired `systemctl restart snap.microk8s.daemon-k8s-dqlite` on both nodes at the same second (16:16:06 UTC). Kubelite was also restarted on both nodes at 16:16:10 UTC.

With k8s01 and k8s03 dqlite simultaneously offline, k8s02 (the only remaining raft member) lost quorum for ~2 seconds. All kine transactions on k8s02 failed with `context canceled`, disrupting the connection pool between k8s02's apiserver and its kine socket.

**Fix:** Added `serial: 1` to the `k8s` play in `ansible/update/home.yml` (PGM-281).

### Compounding cause (confirmed): dqlite restart during active write contention

At the time of the restart (16:16:06 UTC), k8s01 and k8s03 dqlite were experiencing `database is locked` (try: 500) — severe write contention from lease updates. Ansible detected this contention via journald queries at 16:16:03-16:16:05 but had no abort condition — it restarted dqlite regardless.

The restart during active contention likely made the raft re-election noisier and caused kine's connection pool on k8s02 to enter a prolonged broken state (ongoing `use of closed network connection` errors for ~3.5h).

### Compounding cause (confirmed): k8s02 kubelite not restarted — long-lived HTTP/2 watch stream survived ~3.5h

Ansible's k8s update did NOT restart kubelite on k8s02 (k8s02 was not in the concurrent Ansible run — it was processed separately, or skipped). k8s02's kubelite (PID 2547215) kept running continuously. Its existing HTTP/2 watch stream to kine.sock (established well before the disruption) stayed alive via TCP keepalives.

After raft recovery at ~16:26, k8s02's kine resumed event delivery on the old HTTP/2 connection. New connection pool channel requests continued to fail (`use of closed network connection` every ~4-5 min), but the watch stream was alive. The watch cache functioned normally from ~16:26 to ~20:04.

At ~20:04, the long-lived HTTP/2 connection finally closed — likely from sustained write contention pushing kine to terminate stale streams, or an HTTP/2 server-side connection lifetime limit. The watch cache froze.

### Compounding cause (confirmed): KCM leader was on k8s02

The KCM leader lease was held by k8s02. With k8s02's cache frozen, the KCM could not see any new object changes. Pod creation, CronJob scheduling, and Deployment reconciliation halted cluster-wide. The KCM lease was not revoked — k8s02's lease-renewal goroutine operates independently of the watch cache.

---

## What Went Well

- `microk8s-watch-cache` and `microk8s-newest-pod-age` Nagios checks correctly detected the freeze
- The RV=0 canary test immediately pinpointed k8s02 as the frozen node (k8s01 and k8s03 tested healthy)
- The recovery runbook was complete and accurate; no surprises during execution
- Total recovery time from diagnosis to fully restored was ~10 minutes
- No running workload was interrupted — pods already scheduled continued running throughout
- Journald persistence on all nodes meant 7h+ of logs were available for post-incident archaeology

## What Could Improve

- **`serial: 1` not enforced on k8s plays:** The `update/home.yml` k8s play lacked `serial: 1`. The `microk8s-monthly-maintenance.yml` playbook has `serial: 1` but the main update playbook did not. K8s operations must always be serial to prevent simultaneous dqlite restarts.
- **No abort on lock contention:** Ansible detected `database is locked` errors at 16:16:03-16:16:05 immediately before triggering the restart, but restarted anyway. The role should abort (or warn and skip) if recent lock contention is detected.
- **3.5h silent degradation:** The watch cache was eventually working again from 16:26 to 20:04, but kine's connection pool was in a broken state throughout. A Nagios check for persistent kine.sock reconnection failures (the `use of closed network connection` pattern repeating every 5 min) would have surfaced this much earlier.
- **Detection delay on watch stream health:** The `microk8s-watch-cache` check fires when the cache is already frozen. An earlier check (detecting repeated kine.sock errors or high dqlite raft churn) could fire before the stream breaks entirely.
- **No automatic KCM leader failover:** When k8s02's cache froze, k8s02 kept renewing the KCM lease normally. Other nodes could not preempt it.

---

## Action Items

| # | Action | Ticket | Status |
|---|--------|--------|--------|
| 1 | Add `serial: 1` to `k8s` play in `update/home.yml` | [PGM-281](https://linear.app/pgmac-net-au/issue/PGM-281) | **Done** — committed 2026-06-25 |
| 2 | Add guard in `ansible-role-microk8s` to abort dqlite restart if recent lock contention detected | PGM-281 subtask | Open |
| 3 | Add Nagios check for persistent kine.sock reconnection failures as early-warning signal | PGM-281 subtask | Open |

---

## References

- Runbook: [control-plane-watch-cache-freeze.md](../runbooks/control-plane-watch-cache-freeze.md)
- Linear: [PGM-281](https://linear.app/pgmac-net-au/issue/PGM-281) — root cause investigation and fix
- Related: [PGM-241](https://linear.app/pgmac-net-au/issue/PGM-241) — original watch-cache freeze incident (2026-06-10)
- Related PIR: [2026-04-02 dqlite snapshot crash-loop](2026-04-02-dqlite-snapshot-crash-loop-watch-stream-failure.md)
- Related PIR: [2026-05-15 AWX pod pending — dqlite write storm](2026-05-15-awx-pod-pending-calico-rbac-dqlite-write-storm.md)
