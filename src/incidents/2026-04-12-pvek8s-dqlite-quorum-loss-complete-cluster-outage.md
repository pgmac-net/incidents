# Post Incident Review: pvek8s Complete Cluster Outage — dqlite Quorum Loss and Ansible-Injected Invalid Flags

**Date:** 2026-04-04 (degraded) → 2026-04-12
**Duration:** 7 days degraded (2/3 nodes) + ~1h 12m complete outage (2026-04-12 09:27–10:39 AEST)
**Severity:** Critical (complete cluster outage; all NRPE checks timing out; API server unreachable)
**Status:** Resolved

---

## Executive Summary

The pvek8s microk8s cluster suffered a complete 3-node outage when dqlite's Raft consensus layer lost quorum. The proximate trigger was disk pressure on k8s02 (detected 2026-04-04) causing dqlite WAL write failures, which put k8s02 into a crash-restart loop. Over the following 7 days the cluster continued operating with 2/3 voters, but accumulated un-ACKed WAL entries; on 2026-04-11 a snapshot compaction deadlock propagated to k8s01 and k8s03, taking all 3 nodes down.

Recovery was blocked for ~1.5 hours by a second, unrelated issue: an Ansible dqlite tuning role had injected `--snapshot-threshold=512` and `--snapshot-trailing-logs=256` into the k8s-dqlite args file overnight. These flags **do not exist** in k8s-dqlite snap rev 8695. The binary exited with `Error: unknown flag: --snapshot-threshold` on every start attempt, preventing dqlite — and therefore the API server — from coming up.

A further complication: the standard single-node recovery procedure (edit `cluster.yaml` to one node, start that node) failed silently because **dqlite Raft snapshots embed the cluster membership at snapshot time**. A single node cannot reach quorum (2/3) against its own snapshot's 3-node membership list. Recovery required starting all 3 nodes simultaneously.

Total active recovery time from incident detection to resolution: ~1h 12m. No persistent data loss occurred.

---

## Timeline (AEST — UTC+10)

| Time | Event |
|------|-------|
| **2026-04-04 (est.)** | k8s02 disk pressure causes dqlite WAL write failure. k8s02 dqlite enters crash-restart loop. Cluster continues on 2/3 voters (k8s01 + k8s03). No alert fires. |
| **2026-04-11 ~16:07** | dqlite snapshot compaction ACK deadlock on all 3 nodes. k8s01 and k8s03 dqlite enter crash loops. All 3 nodes now failing. ~3,794 restarts on k8s01. |
| **2026-04-12 09:27 AEST** | Incident opened (PGM-137). Nagios Nagios shows `microk8s-dqlite-scheduler` CRITICAL on k8s01, k8s02, k8s03 with 15s socket timeouts. `kubectl --context pvek8s get nodes` fails. |
| ~09:35 | Nagios MCP confirms all 3 nodes CRITICAL. NRPE execution time 15.03s — confirms check is hanging, not just reporting failure. |
| ~09:40 | `journalctl` shows `[go-dqlite] attempt N: server 172.22.22.X:19001: connection refused` / `no known leader` on all nodes. Port 19001 not bound. NRestarts=3794 on k8s01. |
| ~09:45 | Disk confirmed adequate (k8s01: 74%, k8s02: ~75%, k8s03: 71%). Certificates valid until 2027. Root cause: Raft quorum loss confirmed. |
| ~09:52 | All 3 nodes stopped: `sudo microk8s stop` (parallel). Stop sequence: k8s02, k8s01, k8s03. |
| ~09:55 | NRPE check fix: `--request-timeout=10s` added to both kubectl calls in `check_microk8s_dqlite.sh`. Deployed to all 3 nodes. Ansible source files updated. |
| ~10:00 | `microk8s start` on k8s01 (single-node recovery attempt). NRestarts=39 immediately — binary still failing. |
| ~10:05 | **Invalid flags discovered**: manual invocation of `/snap/microk8s/8695/bin/k8s-dqlite --snapshot-threshold=512` → `Error: unknown flag: --snapshot-threshold`. Args file contains Ansible-injected flags not supported by this binary version. |
| ~10:08 | Invalid flags removed from args files on all 3 nodes: `sed -i '/snapshot-threshold\|snapshot-trailing-logs\|^#/d'`. Ansible role `dqlite.yml` updated to remove the task entirely. |
| ~10:12 | k8s01 restarted. Binary now starts but stuck at `[go-dqlite] attempt N: no known leader` indefinitely (250+ attempts). |
| ~10:20 | **Snapshot membership issue discovered**: raft snapshot (216MB, term 2774) embeds 3-node cluster config. Single-node `cluster.yaml` has no effect. Raft segments deleted to force fresh bootstrap — still stuck at quorum 1/3. |
| ~10:30 | 3-node `cluster.yaml` restored from backup on k8s01. All 3 nodes started simultaneously. |
| **~10:39 AEST** | Raft election succeeds in ~60s. All 3 nodes: `microk8s is running`. High availability: yes. Datastore master nodes: 172.22.22.6 172.22.22.8 172.22.22.9. |
| ~10:42 | `kubectl get nodes`: k8s01/k8s02/k8s03 all Ready. ArgoCD server running. Workloads resuming. PGM-137 closed. |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting the surface answer. Keep drilling until reaching an actionable, preventable cause._

#### How were NRPE checks timing out with no useful error?

`check_microk8s_dqlite.sh` called `microk8s kubectl get componentstatuses` and `microk8s kubectl get pods -A` with no `--request-timeout` flag. When the API server was unavailable, both calls blocked indefinitely — exceeding the NRPE socket timeout of 15 seconds. Nagios received `CHECK_NRPE STATE CRITICAL: Socket timeout after 15 seconds` rather than any diagnostic information about the actual cluster state.

#### How was the API server unavailable?

The kube-apiserver (inside kubelite) depends on `kine.sock` — a UNIX socket created by k8s-dqlite that proxies etcd API calls into dqlite. k8s-dqlite was not running on any node, so `kine.sock` was never created, and kubelite failed to start.

#### How was k8s-dqlite not running after `microk8s start`?

The k8s-dqlite binary exited with `Error: unknown flag: --snapshot-threshold` on every invocation. The systemd service restarted it continuously (NRestarts=39 within minutes), but each attempt immediately failed. Since `set -e` is active in the startup script and `exec` replaces the process, the exit code propagated directly to systemd.

#### How did an unknown flag end up in the args file?

The Ansible dqlite tuning role (`roles-dev/ansible-role-microk8s/tasks/dqlite.yml`) used `ansible.builtin.blockinfile` to inject:

```
--snapshot-threshold=512
--snapshot-trailing-logs=256
```

These flags were added based on the k8s-dqlite API as it existed when the role was written (after the Jan 2026 dqlite lock contention incident). The flags were removed or renamed in a subsequent microk8s snap release. Snap rev 8695 (the installed version) does not include them.

#### How was the role allowed to inject unsupported flags without detection?

The Ansible role had no mechanism to validate that a flag exists in the target binary before writing it. The run script (`run-k8s-dqlite-with-args`) passes all lines from the args file directly to the binary — including comment lines injected by `blockinfile` — without any pre-validation. After the playbook ran overnight and the restart was completed, there was no health check task to verify the service remained running.

Additionally, `blockinfile` injects `# BEGIN/END ANSIBLE MANAGED BLOCK` comment lines. While bash evaluates these as comments in an `eval`-style array expansion, their presence alongside invalid flags made diagnosis harder — it was initially unclear whether the comments or the flags were causing the failure.

#### How did the cluster reach complete quorum loss (the underlying outage)?

k8s02 ran low on disk space (estimated 2026-04-04). dqlite's write-ahead log (WAL) requires disk writes to commit entries. When dqlite tried to write a WAL entry on k8s02 and the filesystem was full, the write failed. dqlite exited, and systemd restarted it. On restart, the same WAL entries needed to be applied — and dqlite exited again. k8s02 entered a crash-restart loop with thousands of restarts.

With k8s02's dqlite out of the election pool, the cluster continued on 2 voters (k8s01 + k8s03), which still constitutes quorum in a 3-node cluster. The cluster remained nominally operational for ~7 days.

#### How did the 2-node operation cascade to all 3 nodes?

During 7 days of degraded operation, the 2 active nodes continued taking dqlite snapshots and accumulating WAL entries. At some point (2026-04-11 ~16:07 AEST), a snapshot compaction cycle attempted to ACK completion across all 3 Raft voters. Because k8s02 was not responding to Raft RPC calls, the ACK could not complete. The snapshot compaction deadlock caused the dqlite process on k8s01 and k8s03 to stall, eventually crash. With all 3 nodes now unable to run dqlite, the Raft quorum was completely lost.

#### How did disk pressure on k8s02 go undetected for 7 days?

There was no disk space monitoring or alerting on k8s nodes targeting the `/var/snap/microk8s/` mount point. The existing Nagios NRPE configuration checked overall system disk usage but did not specifically alert on the snap data partition where dqlite stores its WAL, snapshots, and database files.

#### How did the dqlite crash-loop go undetected for 7 days?

There was no NRPE check or Nagios service monitoring the systemd `NRestarts` property for `snap.microk8s.daemon-k8s-dqlite`. The existing `microk8s-dqlite-scheduler` check relied on `kubectl` API calls — which continued to succeed while 2/3 voters were running — and so returned OK throughout the degraded period.

---

### Secondary Finding: Snapshot-Embedded Raft Membership

The standard dqlite recovery guide suggests editing `cluster.yaml` to reduce membership to a single node and starting that node. This approach **does not work when an existing raft snapshot is present**.

dqlite Raft snapshots embed the full cluster configuration (membership) at the time the snapshot was taken. When the single node loads the snapshot, it reads the embedded 3-node membership and requires 2/3 votes to elect a leader. Since the node is alone, it gets 1/3 votes and is stuck at `no known leader` indefinitely.

This is counter-intuitive because `cluster.yaml` is clearly documented as controlling cluster membership. The documentation does not make clear that for an existing cluster with an existing snapshot, the snapshot's embedded membership takes precedence over `cluster.yaml` for Raft election purposes.

---

## Impact

### Services Affected

| Service | Impact | Duration |
|---------|--------|----------|
| All Kubernetes workloads | API server unreachable; no new pod scheduling possible | ~7 days degraded + ~1h 12m full outage |
| Nagios NRPE monitoring | All 3 k8s nodes reporting CRITICAL socket timeout (misleading, not diagnostic) | ~1h 12m visible outage |
| ArgoCD | Unavailable (depends on API server) | ~1h 12m |
| All homelab applications | Running on existing pods; unaffected (no new scheduling required) | 0 |

### Duration

- **Degraded operation** (2/3 voters, no alerting): ~2026-04-04 → 2026-04-11 (~7 days)
- **Complete outage** (0/3 voters): ~2026-04-11 16:07 AEST → 2026-04-12 10:39 AEST (~18h 32m)
- **Active incident window**: 2026-04-12 09:27 AEST → 10:39 AEST (~1h 12m)

### Scope

- 3-node microk8s HA cluster `pvek8s`
- No persistent storage data loss
- No user-facing services disrupted (all applications continued running on existing pods)
- Cluster state recovered from snapshot taken at 2026-04-11 16:17 AEST

---

## Resolution Steps Taken

### Phase 1: Diagnosis

1. **Queried Nagios MCP** for unhandled problems — confirmed all 3 nodes CRITICAL with 15s socket timeout.

2. **Confirmed API server down**:
   ```bash
   kubectl --context pvek8s get nodes
   # → "server was unable to return a response in the time allotted"
   ```

3. **Identified crash-restart loop** on all nodes:
   ```bash
   systemctl show snap.microk8s.daemon-k8s-dqlite --property=NRestarts
   # → NRestarts=3794 (k8s01)
   journalctl -u snap.microk8s.daemon-k8s-dqlite --since '2026-04-10' | grep -E 'error|warn'
   # → [go-dqlite] attempt N: server 172.22.22.X:19001: connection refused / no known leader
   ```

4. **Confirmed data intact**: snapshot `snapshot-2774-2115903254-99297685` (216MB, Apr 11 16:17) present on k8s01.

### Phase 2: NRPE Fix

5. **Added `--request-timeout=10s`** to both kubectl calls in `check_microk8s_dqlite.sh`:
   ```bash
   # Before:
   COMPSTAT=$(/snap/bin/microk8s kubectl get componentstatuses -o json 2>/dev/null)
   PENDING_PODS=$(/snap/bin/microk8s kubectl get pods -A 2>/dev/null | grep -c "Pending")
   # After:
   COMPSTAT=$(/snap/bin/microk8s kubectl get componentstatuses --request-timeout=10s -o json 2>/dev/null)
   PENDING_PODS=$(/snap/bin/microk8s kubectl get pods -A --request-timeout=10s 2>/dev/null | grep -c "Pending")
   ```

6. **Deployed to all 3 nodes** via `scp` + `ssh`. Updated Ansible source files.

### Phase 3: Invalid Flags Discovery and Fix

7. **Stopped all nodes**: `for node in k8s01 k8s02 k8s03; do ssh $node "sudo microk8s stop" & done`

8. **Attempted `microk8s start` on k8s01** — NRestarts=39 immediately, service still failing.

9. **Ran binary manually** to diagnose:
   ```bash
   /snap/microk8s/8695/bin/k8s-dqlite \
     --storage-dir=/var/snap/microk8s/8695/var/kubernetes/backend/ \
     --listen=unix:///var/snap/microk8s/8695/var/kubernetes/backend/kine.sock:12379 \
     --snapshot-threshold=512 \
     --snapshot-trailing-logs=256
   # → Error: unknown flag: --snapshot-threshold
   ```

10. **Removed invalid flags and comment lines** from args files on all 3 nodes:
    ```bash
    for node in k8s01 k8s02 k8s03; do
      ssh $node "sed -i '/snapshot-threshold\|snapshot-trailing-logs\|^#/d' \
        /var/snap/microk8s/8695/args/k8s-dqlite"
    done
    ```

11. **Removed the task from Ansible role** `roles-dev/ansible-role-microk8s/tasks/dqlite.yml` entirely.

### Phase 4: Single-Node Recovery Attempt (Failed)

12. **Edited `cluster.yaml`** on k8s01 to single-node configuration. Started k8s01 dqlite. Observed `[go-dqlite] attempt N: no known leader` for 250+ attempts (~4 minutes).

13. **Removed raft segments** to force fresh bootstrap from snapshot:
    ```bash
    ssh k8s01 "rm -f /var/snap/microk8s/current/var/kubernetes/backend/0000* metadata1 metadata2"
    ```
    Still stuck at `no known leader` — snapshot-embedded 3-node membership requires quorum.

### Phase 5: Correct Recovery — Simultaneous 3-Node Start

14. **Restored 3-node `cluster.yaml`** from backup on k8s01.

15. **Started all 3 nodes simultaneously**:
    ```bash
    for node in k8s01 k8s02 k8s03; do ssh $node "sudo microk8s start" & done; wait
    ```

16. **Raft election completed in ~60 seconds**. All 3 nodes joined as datastore masters.

---

## Verification

### Cluster Health

```
NAME    STATUS   ROLES    AGE      VERSION
k8s01   Ready    <none>   4y234d   v1.34.5
k8s02   Ready    <none>   4y234d   v1.34.5
k8s03   Ready    <none>   4y234d   v1.34.5

microk8s status:
  high-availability: yes
  datastore master nodes: 172.22.22.6:19001 172.22.22.8:19001 172.22.22.9:19001
```

### NRPE Fix Verification

```bash
grep 'request-timeout' /etc/nagios/nrpe.d/check_microk8s_dqlite.cfg
# → --request-timeout=10s present in both kubectl calls on all 3 nodes
```

---

## Preventive Measures

### Immediate Actions Required

1. **Add disk space monitoring for k8s nodes** (Urgent)
   - No alerting existed for disk pressure on `/var/snap/microk8s/`. k8s02 disk pressure was the cascade trigger.
   - Action: Add NRPE check for `/var/snap/microk8s/` utilisation: warn < 20% free, critical < 10% free.
   - Linear: **[PGM-138](https://linear.app/pgmac-net-au/issue/PGM-138)**

2. **Add dqlite service crash-loop alert** (Urgent)
   - `snap.microk8s.daemon-k8s-dqlite` accumulated 3,794 restarts over 7+ days with no alerting.
   - Action: Add NRPE check on `systemctl show snap.microk8s.daemon-k8s-dqlite --property=NRestarts`: warn > 10, critical > 50.
   - Linear: **[PGM-139](https://linear.app/pgmac-net-au/issue/PGM-139)**

3. **Add flag validation and health check to Ansible dqlite role** (High)
   - The role wrote flags unsupported by the installed binary with no pre-check and no post-restart health verification.
   - Action: Add `--help | grep <flag>` validation before writing flags; add service health check after any restart triggered by Ansible.
   - Linear: **[PGM-140](https://linear.app/pgmac-net-au/issue/PGM-140)**

4. **Document dqlite quorum recovery procedure** (High)
   - The snapshot-embedded membership constraint is not documented. The single-node recovery approach fails silently and cost ~1.5h.
   - Action: Add runbook: start all 3 nodes simultaneously; do NOT attempt single-node recovery with existing snapshots.
   - Linear: **[PGM-141](https://linear.app/pgmac-net-au/issue/PGM-141)**

### Longer-Term Improvements

5. **Fix Ansible blockinfile comment pollution in k8s-dqlite args file** (Medium)
   - `blockinfile` injects `# BEGIN/END ANSIBLE MANAGED BLOCK` comment lines. Replace with `lineinfile`.
   - Linear: **[PGM-142](https://linear.app/pgmac-net-au/issue/PGM-142)**

6. **Add NRPE check test suite to prevent kubectl timeout omissions** (Medium)
   - No automated check prevents `kubectl` calls without `--request-timeout` from being added to NRPE scripts.
   - Action: Add pre-commit lint check: any `kubectl` call in `ansible/files/nagios/*.sh` must include `--request-timeout`.
   - Linear: **[PGM-143](https://linear.app/pgmac-net-au/issue/PGM-143)**

---

## Lessons Learned

### What Went Well

- **Data intact throughout**: The 216MB dqlite snapshot from 2026-04-11 16:17 was preserved on all nodes. No Kubernetes state was lost.
- **Invalid flag diagnosis was fast**: Running the binary manually with explicit args immediately revealed `Error: unknown flag: --snapshot-threshold`. ~3 minutes from suspicion to confirmed root cause.
- **Simultaneous 3-node restart was decisive**: Once the correct recovery approach was identified, the cluster was up in ~60 seconds with no manual raft manipulation required.
- **NRPE fix deployed immediately**: The `--request-timeout=10s` fix was deployed to all nodes and Ansible source files in parallel with the recovery work, before the cluster came back up.

### What Didn't Go Well

- **7 days of silent degraded operation**: k8s02's dqlite crash-loop went completely undetected. Two alerting gaps — no disk monitoring, no NRestarts monitoring — together allowed a single-node failure to accumulate for long enough to take the entire cluster down.
- **Ansible role silently deployed breaking change**: The overnight playbook run added unsupported flags to all 3 nodes with no validation and no notification. This turned a repairable quorum loss into a complete binary-level failure that blocked recovery.
- **Single-node recovery approach wasted ~1.5 hours**: The standard recovery guide's suggestion to reduce `cluster.yaml` to one node is correct for bootstrap scenarios but fails for existing snapshots. This was not documented and cost significant investigation time.
- **Comment lines in args file complicated diagnosis**: The `# BEGIN/END ANSIBLE MANAGED BLOCK` comment lines were initially suspected as the cause of the binary failure, requiring additional time to confirm that it was actually the invalid flags.

### Surprise Findings

- **dqlite Raft snapshots embed cluster membership**: Editing `cluster.yaml` does not change the cluster configuration used for Raft elections when an existing snapshot is present. The snapshot's membership overrides `cluster.yaml`. This is a critical undocumented constraint for recovery scenarios.
- **`blockinfile` comment lines are passed to the binary**: The k8s-dqlite run script uses `declare -a args="($(cat $SNAP_DATA/args/$app))"` to build argument arrays. In this evaluation context, `#` lines behave as comments — but only in some bash versions and evaluation modes. This is an unintended interaction between Ansible's file management approach and the microk8s startup mechanism.
- **`--snapshot-threshold` and `--snapshot-trailing-logs` removed in snap rev 8695**: The k8s-dqlite binary no longer supports these flags. Any Ansible role, runbook, or documentation referencing these flags must be updated before applying to a cluster running rev 8695+.

---

## Action Items

| # | Action | Priority | Linear |
|---|--------|----------|--------|
| 1 | Add disk space monitoring for k8s nodes (`/var/snap/microk8s/` < 20% free) | Urgent | [PGM-138](https://linear.app/pgmac-net-au/issue/PGM-138) |
| 2 | Add dqlite crash-loop alert (NRestarts > 10 warn, > 50 critical) | Urgent | [PGM-139](https://linear.app/pgmac-net-au/issue/PGM-139) |
| 3 | Add flag validation + health check to Ansible dqlite args role | High | [PGM-140](https://linear.app/pgmac-net-au/issue/PGM-140) |
| 4 | Document dqlite quorum recovery (all-nodes-simultaneous, snapshot membership) | High | [PGM-141](https://linear.app/pgmac-net-au/issue/PGM-141) |
| 5 | Fix Ansible `blockinfile` comment pollution in k8s-dqlite args file | Medium | [PGM-142](https://linear.app/pgmac-net-au/issue/PGM-142) |
| 6 | Add NRPE check lint: all `kubectl` calls must include `--request-timeout` | Medium | [PGM-143](https://linear.app/pgmac-net-au/issue/PGM-143) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes)
- **Kubernetes version:** v1.34.5
- **microk8s snap revision:** 8695
- **Container runtime:** containerd 1.7.28
- **dqlite snapshot at recovery:** `snapshot-2774-2115903254-99297685` (216MB, 2026-04-11 16:17 AEST)
- **k8s01 dqlite NRestarts at incident start:** 3,794

### k8s-dqlite Args File Before Fix

```
--storage-dir=${SNAP_DATA}/var/kubernetes/backend/
--listen=unix://${SNAP_DATA}/var/kubernetes/backend/kine.sock:12379
# BEGIN ANSIBLE MANAGED BLOCK - dqlite tuning
--snapshot-threshold=512
--snapshot-trailing-logs=256
# END ANSIBLE MANAGED BLOCK - dqlite tuning
```

### k8s-dqlite Args File After Fix

```
--storage-dir=${SNAP_DATA}/var/kubernetes/backend/
--listen=unix://${SNAP_DATA}/var/kubernetes/backend/kine.sock:12379
```

### Key Error Signatures

**Invalid flag (primary recovery blocker):**
```
Error: unknown flag: --snapshot-threshold
Usage:
  k8s-dqlite [flags]
  k8s-dqlite [command]
...
```

**Raft quorum loss (underlying outage):**
```
time="..." level=warning msg="[go-dqlite] attempt N: server 172.22.22.X:19001: connection refused"
time="..." level=warning msg="[go-dqlite] attempt N: server 172.22.22.6:19001: no known leader"
```

**Single-node recovery failure (snapshot membership):**
```
# 250+ identical lines — node never becomes leader
time="..." level=warning msg="[go-dqlite] attempt 251: server 172.22.22.6:19001: no known leader"
```

---

## References

- Related incident (dqlite snapshot bloat + WAL deadlock, April 2026): [2026-04-02-dqlite-snapshot-crash-loop-watch-stream-failure.md](2026-04-02-dqlite-snapshot-crash-loop-watch-stream-failure.md)
- Linear incident ticket: [PGM-137](https://linear.app/pgmac-net-au/issue/PGM-137)
- Memory record on dqlite recovery: `memory/project_dqlite_recovery.md`
- microk8s dqlite documentation: https://microk8s.io/docs/dqlite
- go-dqlite project: https://github.com/canonical/go-dqlite

---

## Reviewers

- @pgmac
