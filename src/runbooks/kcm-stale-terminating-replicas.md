---
tags:
  - runbook
  - kine
  - dqlite
  - kubelet
  - microk8s
  - scheduling
  - watch-stream
---

# KCM Stale terminatingReplicas — ReplicaSet Refuses to Create Pods

**Service:** kube-controller-manager (pvek8s k8s01)
**First observed:** 2026-05-29
**PIR:** [pvek8s Post-Power-Outage Recovery — kubelet Volume Manager Stall and KCM Stale terminatingReplicas](../incidents/2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md)

---

## Symptom

A ReplicaSet shows `terminatingReplicas: 1` (or more) in its status but `kubectl get pods -l <selector>` returns no pods. The RS will not create replacement pods. Scaling to 0 and back to 1 does not help — the RS changes the replica count but still refuses to create a pod. Pods do not appear to exist anywhere in the cluster.

This is a K8s 1.35+ behaviour: the RS controller tracks `terminatingReplicas` as a separate field and withholds creating new pods while it believes terminating pods are still outstanding.

---

## Root Cause

The kube-controller-manager's pod informer cache is stale. After a kine/dqlite watch stream disruption (power outage, kine crash, or kine restart with corrupted subscription state), the KCM's client-go `processorListeners` stop receiving events. The informer cache becomes frozen at the pre-disruption snapshot.

When pods are then force-deleted (`--grace-period=0 --force`), the API server removes the pod object immediately, but the KCM never receives the DELETE event. From the KCM's perspective the pod still exists in Terminating state. The K8s 1.35 RS controller sets `terminatingReplicas: 1` and refuses to create a replacement, preventing recovery.

This failure is often seen alongside a kubelet volume manager stall on a different node (both caused by the same kine disruption). See [kubelet-volume-manager-stall.md](kubelet-volume-manager-stall.md).

---

## Detection

```bash
# Step 1: Check RS status for terminatingReplicas
kubectl --context pvek8s get rs -n <namespace> -o json | \
  jq '.items[] | select(.status.terminatingReplicas > 0) | {name: .metadata.name, status: .status}'
# → {"name": "radarr-XXXXXXX", "status": {"terminatingReplicas": 1, "replicas": 1}}

# Step 2: Confirm no pods actually exist for the RS's label selector
RS_SELECTOR=$(kubectl --context pvek8s get rs -n <namespace> <rs-name> \
  -o jsonpath='{.spec.selector.matchLabels}' | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(','.join(f'{k}={v}' for k,v in d.items()))")
kubectl --context pvek8s get pods -n <namespace> -l "$RS_SELECTOR"
# → No resources found  ← confirms stale state

# Step 3: Confirm scale-to-0/scale-to-1 does NOT resolve it
kubectl --context pvek8s scale rs -n <namespace> <rs-name> --replicas=0
kubectl --context pvek8s get rs -n <namespace> <rs-name> -o jsonpath='{.status}'
# → Still shows terminatingReplicas:1 if informer is stale

# Step 4: Confirm this is a KCM informer stall, not a genuine terminating pod
kubectl --context pvek8s get pods -A | grep Terminating
# → (empty — no Terminating pods anywhere)
# → Confirmed: terminatingReplicas is purely stale informer state
```

---

## Recovery

The only reliable fix is to flush the KCM's pod informer cache by restarting kine and kubelite on the node running the kube-controller-manager (k8s01 in the pvek8s cluster). After restart, the KCM performs a full re-list from the API server, discovers no Terminating pods, clears terminatingReplicas, and creates the replacement pod immediately.

!!! warning "Cordon k8s01 before restarting kubelite (PGM-195)"
    Always cordon the node before restarting kubelite. Restarting without cordoning can cause
    newly scheduled pods to land in the watch stream's past and never be processed.
    See [kubelet-silent-stall.md Failure Mode 2](kubelet-silent-stall.md).

1. Cordon k8s01:
   ```bash
   kubectl --context pvek8s cordon k8s01
   ```

2. Restart kine first (must precede kubelite — PGM-201):
   ```bash
   ssh k8s01 "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
   sleep 10
   ssh k8s01 "sudo systemctl is-active snap.microk8s.daemon-k8s-dqlite.service"
   # → active
   ```

3. Restart kubelite:
   ```bash
   ssh k8s01 "sudo systemctl restart snap.microk8s.daemon-kubelite.service"
   ```

4. Wait for k8s01 to return to Ready:
   ```bash
   kubectl --context pvek8s wait node/k8s01 --for=condition=Ready --timeout=120s
   ```

5. Uncordon k8s01:
   ```bash
   kubectl --context pvek8s uncordon k8s01
   ```

6. Verify the RS immediately clears terminatingReplicas and creates a new pod:
   ```bash
   kubectl --context pvek8s get rs -n <namespace> <rs-name> -o jsonpath='{.status}'
   # → {"availableReplicas":0,"replicas":1}  (terminatingReplicas gone)
   kubectl --context pvek8s get pods -n <namespace> -l <selector> -w
   # → New pod appears within 30 seconds, transitions to Running
   ```

---

## Verification

```bash
# RS terminatingReplicas cleared
kubectl --context pvek8s get rs -n <namespace> <rs-name> -o jsonpath='{.status.terminatingReplicas}'
# → (empty / 0)

# Replacement pod Running
kubectl --context pvek8s get pods -n <namespace> -l <selector>
# → 1/1 Running

# k8s01 back to Ready and schedulable
kubectl --context pvek8s get node k8s01
# → Ready  (SchedulingEnabled)
```

---

## References

- PIR: [pvek8s Post-Power-Outage Recovery — kubelet Volume Manager Stall and KCM Stale terminatingReplicas](../incidents/2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md)
- Linear: [PGM-217](https://linear.app/pgmac-net-au/issue/PGM-217)
- Related: [kubelet-volume-manager-stall.md](kubelet-volume-manager-stall.md) — often co-occurs (same kine disruption stalls kubelet informer)
- Related: [kubelet-silent-stall.md](kubelet-silent-stall.md) — Failure Mode 2 (kubelite restart procedure, PGM-195 cordon requirement)
- Related: [dqlite-write-contention.md](dqlite-write-contention.md) — kine restart ordering and safety
