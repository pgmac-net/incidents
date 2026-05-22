---
tags:
  - runbook
  - microk8s
---

# Kubelet Silent Stall — Node Ready, Pods Never Schedule

**Service:** microk8s (pvek8s)
**First observed:** 2026-05-16
**PIR:** [microk8s 1.34 → 1.35 Upgrade](../incidents/2026-05-16-microk8s-1.35-upgrade-cgroup-v2-containerd-disk-pressure.md)

---

## Symptom

A k8s node shows `Ready: True` in `kubectl get nodes` and is heartbeating normally, but pods assigned to it remain `Pending` indefinitely with no kubelet events generated.

This is a false-positive health signal: `kubectl get nodes` only confirms the kubelet can communicate with the API server — it does not verify that pod assignment is functional.

---

## Three Distinct Root Causes

All three failure modes produce the same symptom. Check the kubelite journal and process state to distinguish them.

---

## Failure Mode 1 — Eviction Manager Imagefs Stall

### When it occurs

After an upgrade to microk8s 1.35 (containerd 2.1.3). The containerd metrics API changed its imagefs label surface; the kubelet eviction manager cannot resolve the imagefs label for the configured runtime, enters a degraded state, and silently drops pod lifecycle operations while continuing to heartbeat.

### Detection

```bash
# 1. Confirm pods are Pending on the node but it shows Ready
kubectl get nodes
kubectl get pods -A --field-selector spec.nodeName=<node> | grep Pending

# 2. Check for kubelite log silence — no output in last 5 minutes is the key sign
journalctl -u snap.microk8s.daemon-kubelite --since '5 minutes ago'

# 3. Look for the stall signature in startup logs
journalctl -u snap.microk8s.daemon-kubelite --since '30 minutes ago' | \
  grep -i "imagefs\|eviction manager"
```

**Stall signature:**
```
"eviction manager: failed to check if we have separate container filesystem.
Ignoring." err="no imagefs label for configured runtime"
```

### Recovery

```bash
sudo systemctl restart snap.microk8s.daemon-kubelite
```

Pods should begin scheduling within ~60 seconds.

!!! warning "Cordon first if this is a production restart"
    If the restart is planned (not emergency), cordon the node first to avoid triggering
    Failure Mode 2 (pod watch goroutine stall). See below.

### Verification

```bash
# Pods on node transitioning to Running
kubectl get pods -A --field-selector spec.nodeName=<node> -w

# Kubelite producing active log output
journalctl -u snap.microk8s.daemon-kubelite -f
```

### Context

- Introduced by containerd 2.1.3 (microk8s 1.35) changing the internal metrics API surface for image filesystem labels.
- A kubelite restart resolves it; no data is at risk.
- The `Ignoring.` in the log message is misleading — the failure is not ignored, it silently disables pod assignment.

---

## Failure Mode 2 — Pod Watch Goroutine Stall (Post-Restart)

### When it occurs

After any kubelite restart **without cordoning the node first**. kubelite is monolithic — the API server and kubelet restart as a single process. If pods are scheduled to the node between the restart and the kubelet completing its initial LIST, those pods land in the watch stream's past and are never processed.

This is a structural issue with the monolithic kubelite restart and does not self-heal without cordoning.

### Detection

```bash
# 1. Node shows Ready but pods stuck Pending after restart
kubectl get nodes
kubectl get pods -A --field-selector spec.nodeName=<node> | grep Pending

# 2. Kubelite is producing logs (unlike Failure Mode 1) but no pod events
journalctl -u snap.microk8s.daemon-kubelite --since '5 minutes ago'
# Will show log output, but no "SyncPod" or pod-related entries for stuck pods

# 3. Kubelet /pods endpoint shows only pre-restart stale pods
curl -sk https://127.0.0.1:10250/pods | python3 -c \
  "import json,sys; pods=json.load(sys.stdin)['items']; \
   [print(p['metadata']['namespace'], p['metadata']['name']) for p in pods]"
# If this only shows stale/deleted pods and not the Pending ones, watch is broken

# 4. Capture goroutine dump to confirm (optional — for deep investigation)
sudo kill -SIGUSR1 $(pgrep -f 'snap.microk8s.daemon-kubelite')
# Look for handleAnyWatch goroutine blocked in [select] for minutes
sudo journalctl -u snap.microk8s.daemon-kubelite | grep -A5 "handleAnyWatch"
```

**Watch stall signature (goroutine dump):**
```
goroutine 12104 [select, 4 minutes]:
k8s.io/client-go/tools/cache.handleAnyWatch(...)
  .../client-go/tools/cache/reflector.go:904
created by k8s.io/kubernetes/pkg/kubelet/config.newSourceApiserverFromLW
  k8s.io/kubernetes/pkg/kubelet/config/apiserver.go:67
```

### Recovery — Cordon-Before-Restart Procedure

!!! danger "Required procedure for all kubelite restarts on k8s03"
    Always cordon the node before restarting kubelite. Restarting without cordoning will
    re-create this stall condition for any pods scheduled during the restart window.

```bash
# Step 1: Cordon the node to prevent new pod scheduling during restart
kubectl --context pvek8s cordon <node>

# Step 2: Restart kubelite
sudo systemctl restart snap.microk8s.daemon-kubelite

# Step 3: Wait for node to return to Ready
kubectl --context pvek8s wait node/<node> --for=condition=Ready --timeout=120s

# Step 4: Verify pods are being processed (watch for activity)
kubectl get pods -A --field-selector spec.nodeName=<node> -w
# Pre-assigned pods (spec.nodeName already set) should transition to Running

# Step 5: Uncordon once pods are healthy
kubectl --context pvek8s uncordon <node>
```

If already in a stall state (restart happened without cordoning):

```bash
# Re-apply the cordon-before-restart procedure — a second restart with cordon will fix it
kubectl --context pvek8s cordon <node>
sudo systemctl restart snap.microk8s.daemon-kubelite
kubectl --context pvek8s wait node/<node> --for=condition=Ready --timeout=120s
# Verify, then uncordon
kubectl --context pvek8s uncordon <node>
```

### Verification

```bash
# All pods on node Running or transitioning
kubectl get pods -A --field-selector spec.nodeName=<node>

# Kubelite logs show pod sync activity
journalctl -u snap.microk8s.daemon-kubelite -f | grep -i "syncpod\|pod\|starting"
```

### Why Cordoning Works

Cordoning sets the node as `Unschedulable`, preventing new pods from receiving `spec.nodeName=<node>` during the restart window. Pre-assigned pods (already in the API server with `spec.nodeName` set) appear in the kubelet's initial LIST on restart — processed correctly without depending on the watch stream. Only newly scheduled pods are vulnerable to the watch race.

### Context

- kubelite's `resync period = 0` means the pod watch never re-LISTs unless the watch fails. Since the watch is alive (just empty), no self-healing occurs.
- Documented in PGM-195. Required procedure for all future kubelite restarts on k8s03.
- Applies to any node where kubelite restarts while pods are being scheduled to it.

---

## Failure Mode 3 — PLEG Stall (Orphaned Containerd Shims)

### When it occurs

After multiple kubelite restarts in a short session (e.g., during incident recovery). Each restart can leave behind orphaned `containerd-shim-runc-v2` zombie processes — shims whose containers have exited but whose processes were not cleaned up. On the next kubelite start, PLEG's first `relist()` call iterates over every shim, including orphaned ones. Each orphaned shim causes a gRPC `ContainerStatus` call to hang until its timeout, serialising the entire relist for 30-60+ minutes.

The k8s-dqlite service (kine) is a **separate** systemd service from kubelite (`snap.microk8s.daemon-k8s-dqlite.service`). It is NOT restarted when kubelite is restarted. After kubelite restart storms, kine's internal connection state can become corrupt — all new kubelite instances will fail their etcd-client connections to kine until k8s-dqlite is restarted independently.

### Detection

```bash
# 1. Kubelet completely silent after startup — no logs after initial node registration
ssh <node> "sudo journalctl -u snap.microk8s.daemon-kubelite -n 5 --no-pager"
# Will show only startup lines (kubelet_node_status.go:77 "Successfully registered node")
# and then nothing — even after 10+ minutes

# 2. Process is ALIVE but has zero CPU activity
PID=$(ssh <node> "sudo systemctl show snap.microk8s.daemon-kubelite --property=MainPID | cut -d= -f2")
ssh <node> "sudo cat /proc/$PID/schedstat && sleep 3 && sudo cat /proc/$PID/schedstat"
# If both lines are identical → zero CPU → PLEG stall

# 3. Orphaned shim count (shims > running tasks = orphans)
ssh <node> "pgrep -c containerd-shim && sudo /snap/microk8s/current/bin/ctr \
  --address /var/snap/microk8s/common/run/containerd.sock -n k8s.io tasks list | wc -l"
# If shim count >> task count, there are orphaned shims causing the stall

# 4. kine connection errors (check for high retry counts on startup)
ssh <node> "sudo journalctl -u snap.microk8s.daemon-kubelite --since '5 minutes ago' | \
  grep 'retrying of unary invoker'"
# attempt:50+ means kine connections are exhausted
```

**PLEG stall signature:**
```
# Only startup logs, then silence for 10+ minutes:
May 22 02:34:21 k8s03 kubelite[...]: "Successfully registered node" node="k8s03"
# ... nothing after this for 30+ minutes ...

# schedstat identical across 3+ second window:
195398181 57385342 625
195398181 57385342 625   ← no CPU consumed = PLEG blocking

# Shim count > running tasks:
44 shims
27 running tasks      ← 17 orphaned shims causing hang
```

### Recovery

#### Step 1 — Kill orphaned shims

Cordon the node first if not already cordoned.

```bash
kubectl --context pvek8s cordon <node>

# Kill orphaned shims (shims without a corresponding running task)
ssh <node> "
  RUNNING=\$(sudo /snap/microk8s/current/bin/ctr \
    --address /var/snap/microk8s/common/run/containerd.sock \
    -n k8s.io tasks list 2>/dev/null | awk 'NR>1 {print \$1}')
  KILLED=0
  for PID in \$(pgrep -f containerd-shim 2>/dev/null); do
    CID=\$(sudo cat /proc/\$PID/cmdline 2>/dev/null | tr '\0' '\n' | grep -A1 '^-id$' | tail -1)
    if [ -n \"\$CID\" ] && ! echo \"\$RUNNING\" | grep -q \"\$CID\"; then
      sudo kill -9 \$PID 2>/dev/null && KILLED=\$((KILLED+1))
    fi
  done
  echo \"Killed \$KILLED orphaned shims\"
"
# Verify: shim count should now approximately equal running task count
ssh <node> "pgrep -c containerd-shim"
```

#### Step 2 — Restart k8s-dqlite (if kine connection errors present)

```bash
ssh <node> "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
sleep 10
# Verify kine is up
ssh <node> "sudo systemctl is-active snap.microk8s.daemon-k8s-dqlite.service"
```

#### Step 3 — Restart kubelite

If kubelite is still running from the stalled start:
```bash
ssh <node> "sudo systemctl restart snap.microk8s.daemon-kubelite.service"
```

#### Step 4 — Verify PLEG recovery

```bash
# Kubelet should produce logs within 30 seconds of restart
ssh <node> "sudo journalctl -u snap.microk8s.daemon-kubelite --since '1 minute ago' | \
  grep -v '^--' | tail -10"

# Node should return to Ready
kubectl --context pvek8s wait node/<node> --for=condition=Ready --timeout=120s

# Uncordon once healthy
kubectl --context pvek8s uncordon <node>
```

#### Nuclear option — when orphan kill is insufficient

If PLEG stall persists after killing orphaned shims (e.g., kine corruption also involved, or shim enumeration itself is blocking), do a full clean restart:

```bash
# Stop kubelite FIRST, then kill ALL shims (disrupts pods on node — they will restart)
ssh <node> "sudo systemctl stop snap.microk8s.daemon-kubelite.service"
ssh <node> "for PID in \$(pgrep -f containerd-shim 2>/dev/null); do sudo kill -9 \$PID 2>/dev/null; done"
ssh <node> "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
sleep 10
ssh <node> "sudo systemctl start snap.microk8s.daemon-kubelite.service"
```

This stops all pods on the node cleanly. StatefulSets, Deployments, and DaemonSets recreate their pods automatically. PVC data is preserved.

### Why this happens

PLEG (Pod Lifecycle Event Generator) runs a `relist()` goroutine every second. On kubelet startup, the very first relist must complete before any pod synchronization can proceed. The relist calls `ContainerStatus` via CRI (containerd's runtime service) for every known container. If a `containerd-shim-runc-v2` process for an exited container is still alive (orphaned), containerd must wait for it to respond — each such call can take 30-60 seconds to time out. With dozens of orphaned shims, the first relist can take 30-60+ minutes, during which the kubelet is completely frozen.

Orphaned shims accumulate because containerd 2.x uses shim-sharing and because each kubelite restart can leave zombie shim processes behind if the node lifecycle events are not cleanly processed during the restart.

The k8s-dqlite / kine separation is critical: `snap.microk8s.daemon-k8s-dqlite` provides the SQLite-backed etcd-compatible API to all kubelite processes on the node. After write contention storms (see [dqlite-write-contention runbook](dqlite-write-contention.md)), k8s-dqlite accumulates internal state that causes all subsequent kubelite etcd-client connections to fail at high retry counts. Restarting k8s-dqlite resets this state without affecting the WAL or any dqlite data.

### Context

- First observed: 2026-05-22, during PGM-203 follow-up kubelite restart session on k8s03
- k8s-dqlite / kine separation discovered by observing `snap.microk8s.daemon-k8s-dqlite` service age (1 day 5h) vs kubelite restarts on the same day
- All-shims-killed approach was required when orphan kill alone did not unblock the relist — the relist had already started enumerating shims before the kills took effect

---

## Quick Reference

| Signal | Failure Mode 1 (imagefs) | Failure Mode 2 (watch stall) | Failure Mode 3 (PLEG stall) |
|--------|--------------------------|------------------------------|-----------------------------|
| kubelite logs silent? | **Yes** — zero output | No — logs active | **Yes** — startup only |
| Startup error present? | Yes — `no imagefs label` | No | No (or kine retry errors) |
| kubelet /pods stale? | Maybe | **Yes** | N/A |
| schedstat frozen (0 CPU)? | Yes | No | **Yes** |
| shims >> running tasks? | No | No | **Yes** |
| Fix | `systemctl restart kubelite` | Cordon → restart → uncordon | Kill orphan shims → restart k8s-dqlite → restart kubelite |
| Data at risk? | No | No | No (pods restart from PVCs) |

---

## Post-Incident Checks (After Nuclear Restart)

After a nuclear restart (stop kubelite → kill all shims → restart k8s-dqlite → start kubelite), `containerd-shim` processes are cleaned. However, **non-shim application processes** that were running in containers on the node can also survive as orphans if their container was killed abruptly. These orphans may hold advisory file locks or bind to paths that block new container instances from initialising correctly.

The symptom is subtle: the new container starts, creates its socket, but a handler or worker is blocked acquiring a file lock held by the orphaned process. The gRPC socket exists but never responds — presenting as a probe timeout rather than a lock error.

### Detection

```bash
# Check for unexpected duplicates of known lock-using services
ssh <node> "sudo pgrep -a buildkitd"
# Multiple hits = orphan from a previous container instance

# Confirm the older process is an orphan — its /proc Modify time predates the restart window
ssh <node> "sudo stat /proc/<older-PID> | grep Modify"
# Modify time older than the restart = orphaned from previous container

# Confirm: orphan's ephemeral /run/ is empty, new instance has the live socket
ssh <node> "sudo ls /proc/<older-PID>/root/run/<app>/"   # empty = orphan
ssh <node> "sudo ls /proc/<newer-PID>/root/run/<app>/"   # has socket = current
```

### Recovery

```bash
sudo kill <orphan-PID>
```

The new instance acquires the lock and completes startup immediately.

### Services to check after a nuclear restart on this cluster

| Service | Lock file | Detection |
|---------|-----------|-----------|
| buildkitd | `/var/lib/buildkit/buildkitd.lock` | `pgrep -a buildkitd` → multiple hits |

Add entries as new orphan patterns are discovered.

---

## References

- PIR: [microk8s 1.34 → 1.35 Upgrade](../incidents/2026-05-16-microk8s-1.35-upgrade-cgroup-v2-containerd-disk-pressure.md) — Phases 4 and 8
- Linear: [PGM-187](https://linear.app/pgmac-net-au/issue/PGM-187), [PGM-195](https://linear.app/pgmac-net-au/issue/PGM-195), [PGM-203](https://linear.app/pgmac-net-au/issue/PGM-203)
- Related: [dqlite-write-contention runbook](dqlite-write-contention.md) — k8s-dqlite restart context
