---
tags:
  - runbook
  - dqlite
  - microk8s
---

# dqlite Write Contention

## Symptom

Nagios `microk8s-dqlite-lock` or `microk8s-kine` alerts WARNING or CRITICAL. kube-controller-manager logs show:

```
error in txn: update transaction failed for key /registry/...: exec (try: 500): database is locked
```

kine logs on a node show:

```
grpc: addrConn.createTransport failed ... kine.sock:12379: use of closed network connection
```

Downstream effects: kcm/scheduler informer caches go stale, deployments stop reconciling, new pods fail to schedule or miss calico host routes. If Jiva controller pods become Ready during the write storm, their endpoint update will fail — see [jiva-ctrl-endpoint-deadlock.md](jiva-ctrl-endpoint-deadlock.md) for the self-sustaining deadlock that results.

## Root cause

dqlite uses SQLite as its storage backend, which is single-writer. All Kubernetes object writes (pod status, node heartbeats, job tracking, events) queue through a single dqlite write lock per leader. Under normal load this is fine. After a kubelite restart — especially on the dqlite leader node — every controller reconnects simultaneously and floods the write queue. Multiple restarts in one session compound this.

The `try: 500` threshold means kine exhausted its maximum retry budget (~500 attempts with backoff). At that point kine drops the connection, which breaks the API server's watch stream and causes informer caches on the kcm, scheduler, and calico-node to go stale.

Two structural amplifiers make storms far more likely (analysis: [pgk8s#577](https://github.com/pgmac-net/pgk8s/issues/577)):

1. **Retry amplification bug** ([canonical/microk8s#5153](https://github.com/canonical/microk8s/issues/5153), v1.32+, unfixed) — on a transient `SQLITE_BUSY`, k8s-dqlite re-executes each blocked write up to 500 times with minimal backoff; one lease update can become ~327 duplicate queries in a second, so any brief stall multiplies its own load.
2. **Freelist bloat → snapshot amplification** — the SQLite file never shrinks (`auto_vacuum=0`; dqlite cannot replicate `VACUUM`). Once the file is mostly freelist, every raft snapshot (each 512 raft entries) serialises the whole bloated image — a 200MB+ fsync burst that itself creates the `SQLITE_BUSY` windows feeding amplifier 1. Check with `PRAGMA page_count; PRAGMA freelist_count` and see [dqlite-datastore-vacuum.md](dqlite-datastore-vacuum.md) when snapshots exceed ~50MB.

## Prevention

### Before any kubelite restart

1. Check which node holds the dqlite / kcm lease:
   ```bash
   kubectl -n kube-system get lease kube-controller-manager -o jsonpath='{.spec.holderIdentity}'
   ```
   Restart a **non-leader** node first where possible.

2. Delete accumulated stale jobs to reduce background write rate:
   ```bash
   kubectl delete job --all-namespaces --field-selector=status.conditions[0].type=Complete 2>/dev/null
   kubectl delete job --all-namespaces --field-selector=status.conditions[0].type=Failed 2>/dev/null
   ```
   Verify before deleting; skip one-off migration jobs you want to keep.

3. Check `microk8s-dqlite-lock` and `microk8s-kine` Nagios checks. If either is already WARNING, do not proceed with restarts until they recover.

### During a restart session

- Restart **one node at a time** (`serial: 1`).
- After each restart, wait for full stabilisation before proceeding:
  - All nodes `Ready` with no taints
  - `kubectl -n <ns> get deployment <name> -o jsonpath='{.status.observedGeneration}'` matches `.metadata.generation`
  - No `database is locked` errors in kcm logs (`sudo journalctl -u snap.microk8s.daemon-kubelite.service --since='2 minutes ago' | grep 'database is locked'`)
- Use the maintenance playbook for intentional rolling restarts — it enforces pacing:
  ```bash
  ansible-playbook -i inventory/hosts.ini microk8s-monthly-maintenance.yml
  ```

## Recovery

### Immediate

1. Stop adding more kubelite restarts. Allow the cluster to absorb the write backlog.

2. Delete stale jobs and other high-churn objects:
   ```bash
   kubectl delete job --all-namespaces --field-selector=status.conditions[0].type=Complete
   kubectl delete job --all-namespaces --field-selector=status.conditions[0].type=Failed
   # Old events (high write volume, low value)
   kubectl delete events --all-namespaces --field-selector=reason=BackOff 2>/dev/null
   ```

3. Monitor kcm logs on the leader node to confirm the lock rate is dropping:
   ```bash
   LEADER=$(kubectl -n kube-system get lease kube-controller-manager -o jsonpath='{.spec.holderIdentity}' | cut -d_ -f1)
   ssh $LEADER "sudo journalctl -u snap.microk8s.daemon-kubelite.service -f 2>/dev/null | grep 'database is locked'"
   ```
   Expect the rate to fall within 2–5 minutes.

### If kubelite connections to kine are broken after a restart

`snap.microk8s.daemon-k8s-dqlite` is a **separate** systemd service from kubelite. It is not restarted when kubelite restarts. After a write contention storm, k8s-dqlite can accumulate corrupt internal kine connection state that causes every new kubelite instance to fail its etcd-client connections at high retry counts (`attempt:80+`, `grpc: the client connection is closing`).

Restart k8s-dqlite independently on each affected node before restarting kubelite:

```bash
# Restart k8s-dqlite first (clears kine internal state)
ssh <node> "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
sleep 10

# Then restart kubelite (it will connect to a clean kine session)
kubectl cordon <node>
ssh <node> "sudo systemctl restart snap.microk8s.daemon-kubelite.service"
kubectl wait node/<node> --for=condition=Ready --timeout=120s --context pvek8s
kubectl uncordon <node>
```

Detection: kubelite logs show `retrying of unary invoker failed ... attempt:80+` or `grpc: the client connection is closing` at startup; kubelite may also be silent (PLEG stall) — see [kubelet-silent-stall.md](kubelet-silent-stall.md) Failure Mode 3.

### If kcm/scheduler watches are stale (observedGeneration not advancing)

The kcm's informer cache may be stuck if kine connections dropped during the write storm. The kcm will not process any reconciliations until the cache sync completes.

1. Identify the current kcm leader:
   ```bash
   kubectl -n kube-system get lease kube-controller-manager -o jsonpath='{.spec.holderIdentity}'
   ```

2. If the leader's cache is stuck (no RS/Deployment reconciliation in logs for >5 minutes), restart k8s-dqlite first, then cordon and restart kubelite on the leader node to force a fresh leader election:
   ```bash
   ssh <leader-node> "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
   sleep 10
   kubectl cordon <leader-node>
   ssh <leader-node> "sudo systemctl restart snap.microk8s.daemon-kubelite.service"
   until kubectl get node <leader-node> --no-headers | grep -q 'Ready,SchedulingDisabled'; do sleep 5; done
   kubectl uncordon <leader-node>
   ```

3. Verify the new leader is reconciling within 2 minutes:
   ```bash
   LEADER=$(kubectl -n kube-system get lease kube-controller-manager -o jsonpath='{.spec.holderIdentity}' | cut -d_ -f1)
   ssh $LEADER "sudo journalctl -u snap.microk8s.daemon-kubelite.service --since='2 minutes ago' 2>/dev/null | grep -v 'job_controller\|node_lifecycle\|grpc' | tail -20"
   ```

### If calico-node watch is stale (new pods missing host routes)

Symptom: pods scheduled on a node crash immediately with `connect: no route to host` to `10.152.183.1:443`. No host route for the pod's IP exists (`ip route show | grep <pod-IP>` returns nothing on the node).

```bash
kubectl -n kube-system delete pod -l k8s-app=calico-node --field-selector=spec.nodeName=<affected-node>
```

Wait ~30 seconds for the new calico-node pod to start and program routes. Verify:
```bash
ssh <affected-node> "ip route show | grep cali | wc -l"
```

### If a Deployment is stuck (phantom RS status)

Symptom: `kubectl get deployment` shows `AVAILABLE=1` but no pod exists. The kcm's informer has a ghost pod in its cache.

1. Patch the stale RS status to force reconciliation:
   ```bash
   RS=$(kubectl -n <ns> get replicaset -l <selector> -o name | head -1)
   kubectl -n <ns> patch $RS --subresource=status \
     -p '{"status":{"readyReplicas":0,"availableReplicas":0,"replicas":0,"fullyLabeledReplicas":0}}'
   ```

2. If the deployment controller itself is stuck (observedGeneration not advancing after the patch), rolling-restart the deployment:
   ```bash
   kubectl -n <ns> rollout restart deployment/<name>
   ```
   Note: if ArgoCD manages the deployment with `selfHeal: true`, the restart annotation will be reverted. In that case, restart the kcm leader's kubelite instead (step 2 of the stale watch recovery above).

## Verification

Cluster is healthy when:

- `microk8s-dqlite-lock` and `microk8s-kine` Nagios checks return OK
- `kubectl get nodes` shows all nodes Ready with no taints
- `kubectl get jobs --all-namespaces` shows no accumulation of Complete/Failed jobs
- No `database is locked` in kcm logs for 5+ minutes

## References

- Script: [pvek8s-outage-recovery.sh](pvek8s-outage-recovery.sh) — full post-outage recovery sequence; dqlite+kubelite restart ordering (phases 4 and 6) follows the safe restart procedure in this runbook
- Runbook: [dqlite-datastore-vacuum.md](dqlite-datastore-vacuum.md) — structural mitigation for the snapshot-amplification driver; run when snapshot files exceed ~50MB
- Upstream: [canonical/microk8s#5153](https://github.com/canonical/microk8s/issues/5153) — retry amplification on lease updates (open)
