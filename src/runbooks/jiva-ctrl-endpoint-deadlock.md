---
tags:
  - runbook
  - openebs
  - jiva
  - kcm
  - dqlite
  - kine
  - storage
  - microk8s
---

# Jiva Controller Endpoint Deadlock

**Service:** OpenEBS Jiva iSCSI (pvek8s)
**First observed:** 2026-06-28
**PIR:** [pvek8s dqlite WAL Lock Storm — Jiva Controller Endpoint Deadlock](../incidents/2026-06-28-dqlite-lock-storm-jiva-endpoint-deadlock.md)

---

## Symptom

Jiva replica pods are in CrashLoopBackOff with `connection refused` errors to the controller service. Jiva controller pods are Running and show Ready in `kubectl get pods`, but their service endpoints have the controller pod IP in `notReadyAddresses` (not `addresses`). Normal recovery attempts (rollout restarts, pod deletions, EndpointSlice deletion) do nothing — the cluster is silently unable to process writes.

Observable signals:

```bash
# Replica pods crashing
kubectl --context pvek8s get pods -n openebs | grep rep
# → pvc-...-rep-1   0/1   CrashLoopBackOff   11   11h

# Controller endpoint has notReadyAddresses
kubectl --context pvek8s get endpoints -n openebs | grep jiva-ctrl-svc
# → pvc-...-jiva-ctrl-svc   <none>   <ready>/<age>
# (the <none> means addresses is empty; notReadyAddresses holds the IP)

kubectl --context pvek8s get endpoints -n openebs <svc-name> -o jsonpath='{.subsets}'
# → shows notReadyAddresses: [{ip: "10.x.x.x"}], addresses: []
```

---

## Root Cause

This is a self-sustaining deadlock between two Kubernetes subsystems:

1. **Jiva replicas need the controller endpoint to be in `addresses`** (not `notReadyAddresses`) to connect. Without a reachable controller endpoint, replicas get `connection refused` and CrashLoopBackOff.
2. **The endpoint-controller needs Jiva replica connectivity to be healthy before the controller pod achieves quorum** — but the endpoint-controller actually just needs the *controller pod* to be Ready, which it is. The issue is that the endpoint-controller *already failed* to write the Ready→addresses update, and it does not retry.

The deadlock is initiated when:
- Jiva controller pods become Ready, AND
- the kube-controller-manager is unable to write the endpoint update at that exact moment

The CM write failure typically happens due to **dqlite WAL lock contention** (`database is locked: try 500`) or **kine.sock channel pool failures** (`use of closed network connection`) on the node holding the KCM leader lease.

Once the controller endpoint is stuck in `notReadyAddresses`, no amount of pod restarts, rollout restarts, or EndpointSlice deletions will fix it — the CM must be able to write, and write successfully, to move the endpoint to `addresses`. If the CM is on a node with broken kine connectivity, it holds the lease indefinitely (lease renewal is separate from write capability) and no other CM can take over.

---

## Detection

Confirm the deadlock by checking all three conditions:

```bash
# 1. Replica pods crashing
kubectl --context pvek8s get pods -n openebs | grep -E 'rep.*CrashLoop|rep.*Error'

# 2. Controller endpoint stuck in notReadyAddresses
for svc in $(kubectl --context pvek8s get svc -n openebs -o name | grep jiva-ctrl-svc); do
  echo "=== $svc ==="
  kubectl --context pvek8s get -n openebs "$svc" \
    -o jsonpath='{.metadata.name}: addresses={.subsets[0].addresses} notReady={.subsets[0].notReadyAddresses}'
  echo
done
# → notReadyAddresses populated, addresses empty = deadlock

# 3. CM is not writing (EndpointSlice test — definitive)
ES=$(kubectl --context pvek8s get endpointslice -n openebs \
  -l kubernetes.io/service-name=<one-of-the-stuck-services> -o name | head -1)
kubectl --context pvek8s delete -n openebs "$ES"
sleep 30
kubectl --context pvek8s get endpointslice -n openebs \
  -l kubernetes.io/service-name=<one-of-the-stuck-services>
# → no EndpointSlice after 30s = CM not writing; the deadlock is active
```

Once confirmed CM is stuck, identify why:

```bash
# A: Find KCM leader
KCM_NODE=$(kubectl --context pvek8s -n kube-system get lease kube-controller-manager \
  -o jsonpath='{.spec.holderIdentity}' | cut -d_ -f1)
echo "KCM is on: $KCM_NODE"

# B: Check kine.sock broken channel pool on that node
ssh "$KCM_NODE" "sudo journalctl -u snap.microk8s.daemon-kubelite \
  --since '10 minutes ago' --no-pager | grep -c 'use of closed network connection'"
# → >5 hits in 10 minutes = broken kine channel pool; fix = restart dqlite on KCM node

# C: Check dqlite write contention (run on all nodes, especially the dqlite leader)
for node in k8s01 k8s02 k8s03; do
  echo "=== $node ==="
  ssh "$node" "sudo journalctl -u snap.microk8s.daemon-k8s-dqlite \
    --since '5 minutes ago' --no-pager | grep -c 'database is locked'" 2>/dev/null
done
# → high count on any node (especially the leader) = write contention; fix = restart dqlite on leader
```

---

## Recovery

**Order: follower nodes first, then the dqlite leader.**

Find the dqlite leader before starting:

```bash
ssh k8s01 "sudo cat /var/snap/microk8s/current/var/kubernetes/backend/info.yaml" 2>/dev/null | grep -A2 leader
# or: the node with the highest 'database is locked' count is usually the leader under contention
```

### Step 1 — Restart dqlite on follower nodes

Restart `snap.microk8s.daemon-k8s-dqlite` on any node that is **not** the dqlite leader:

```bash
FOLLOWER=k8s03   # whichever node is not the dqlite leader
ssh "$FOLLOWER" "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite"
```

!!! warning "k8s-dqlite restart may also restart kubelite"
    On some nodes, restarting k8s-dqlite causes kubelite to also restart. This will cause
    the KCM lease to migrate off that node — which is desirable if the KCM was on the follower
    with broken kine. Wait 30–60s before proceeding.

```bash
sleep 30
# Verify the KCM has migrated off the follower node if it was there
kubectl --context pvek8s -n kube-system get lease kube-controller-manager \
  -o jsonpath='{.spec.holderIdentity}' | cut -d_ -f1
```

### Step 2 — Restart dqlite on the leader

Restarting the dqlite leader triggers a new raft leader election:

```bash
LEADER=k8s02   # the current dqlite leader
ssh "$LEADER" "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite"
```

Wait for the new leader election to complete (~30s):

```bash
sleep 30
# Confirm no 'database is locked' errors on any node
for node in k8s01 k8s02 k8s03; do
  echo "=== $node ==="
  ssh "$node" "sudo journalctl -u snap.microk8s.daemon-k8s-dqlite \
    --since '1 minute ago' --no-pager | grep -c 'database is locked'" 2>/dev/null
done
# → 0 on all nodes
```

### Step 3 — Wait for jiva-operator to reconcile

The jiva-operator should now be able to write to the API server. It will reconcile and recreate any missing controller pods within ~30s. Wait and confirm:

```bash
sleep 30
kubectl --context pvek8s get pods -n openebs | grep ctrl
# → all jiva-ctrl pods Running 2/2
```

If the jiva-operator itself was deleted during diagnosis (force-deleted), wait for it to be recreated:

```bash
kubectl --context pvek8s get pods -n openebs | grep jiva-operator
# → 1/1 Running
```

### Step 4 — Verify endpoints are now in addresses

```bash
kubectl --context pvek8s get endpoints -n openebs | grep jiva-ctrl-svc
# → IP should now appear in the addresses column, not notReadyAddresses
```

If endpoints are still stuck after 60s, check whether the controller pods are actually Ready:

```bash
kubectl --context pvek8s get pods -n openebs | grep ctrl
# → if any pod is not 2/2 Running, wait for it to stabilise before checking endpoints again
```

### Step 5 — Force-delete crashing replica pods to accelerate reconnection

Replica pods in CrashLoopBackOff have exponential backoff (up to 5 minutes between restarts). Delete them to trigger immediate restart and reconnection to the now-healthy controller endpoints:

```bash
kubectl --context pvek8s get pods -n openebs -o name | grep rep | \
  xargs -I{} sh -c 'kubectl --context pvek8s get -n openebs {} \
    --no-headers -o custom-columns=STATUS:.status.phase,NAME:.metadata.name | \
    grep -v Running | awk "{print \$2}"' | \
  xargs kubectl --context pvek8s delete pod -n openebs 2>/dev/null

# Or more simply, delete all non-Running replica pods:
kubectl --context pvek8s get pods -n openebs --no-headers | \
  grep rep | grep -v Running | awk '{print $1}' | \
  xargs kubectl --context pvek8s delete pod -n openebs
```

---

## Verification

All conditions must be true:

```bash
# All replica pods Running
kubectl --context pvek8s get pods -n openebs | grep rep
# → all 1/1 Running, 0 CrashLoopBackOff

# All controller endpoints in addresses (not notReadyAddresses)
kubectl --context pvek8s get endpoints -n openebs | grep jiva-ctrl-svc
# → all services have IPs in the addresses column

# No cluster-wide pod creation stall
kubectl --context pvek8s get pods -A --sort-by=.metadata.creationTimestamp | tail -3
# → newest pod < 5m old

# Jiva volumes are healthy (CSI volumes only)
kubectl --context pvek8s get jivavolume -n openebs 2>/dev/null
# → all Status: Ready
```

---

## What NOT to Do

**Do not try to fix this by:**

- **Deleting EndpointSlices** — they will not regenerate until the CM can write
- **Patching the Endpoints object manually** — only valid if the controller pods are Running with stable IPs; invalid if pods have been force-deleted (patch would point to dead IPs)
- **Rollout-restarting jiva-operator or controller deployments** — the annotation is written, but the deployment controller (part of stuck CM) will not act on it
- **Force-deleting controller pods** — they will not be recreated (deployment/RS controller = stuck CM)
- **Waiting** — the endpoint deadlock is self-sustaining; it will not self-heal

The root fix is always to restore the CM's ability to write. That means clearing the kine.sock connection pool failures or the dqlite write contention blocking the CM leader.

---

## References

- PIR: [pvek8s dqlite WAL Lock Storm — Jiva Controller Endpoint Deadlock](../incidents/2026-06-28-dqlite-lock-storm-jiva-endpoint-deadlock.md)
- Related: [dqlite-write-contention.md](dqlite-write-contention.md) — write contention root cause and prevention
- Related: [control-plane-watch-cache-freeze.md](control-plane-watch-cache-freeze.md) — broader CM/apiserver freeze where cache is fully frozen (vs. write-only failure here)
- Related: [jiva-ctrl-node-rolling-restart.md](jiva-ctrl-node-rolling-restart.md) — safe node restart procedure for nodes hosting jiva-ctrl pods
