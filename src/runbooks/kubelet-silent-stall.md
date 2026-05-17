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

## Two Distinct Root Causes

Both failure modes produce the same symptom. Check the kubelite journal first to distinguish them.

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

## Quick Reference

| Signal | Failure Mode 1 (imagefs) | Failure Mode 2 (watch stall) |
|--------|--------------------------|------------------------------|
| kubelite logs silent? | **Yes** — zero output | No — logs active |
| Startup error present? | Yes — `no imagefs label` | No |
| kubelet /pods shows stale pods only? | Maybe | **Yes** |
| Fix | `systemctl restart snap.microk8s.daemon-kubelite` | Cordon → restart → uncordon |
| Data at risk? | No | No |

---

## References

- PIR: [microk8s 1.34 → 1.35 Upgrade](../incidents/2026-05-16-microk8s-1.35-upgrade-cgroup-v2-containerd-disk-pressure.md) — Phases 4 and 8
- Linear: [PGM-187](https://linear.app/pgmac-net-au/issue/PGM-187), [PGM-195](https://linear.app/pgmac-net-au/issue/PGM-195)
