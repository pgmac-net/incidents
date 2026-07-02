---
tags:
  - runbook
  - microk8s
  - dqlite
  - kine
  - watch-cache
  - kcm
  - scheduler
  - kubelet
---

# Control-Plane Watch-Cache Freeze (Zero Pod Creations / Stalled Reflectors)

**Service:** microk8s control plane (pvek8s)
**First documented:** 2026-06-12
**Incident:** PGM-241 — KCM dead 16h with zero pod creations cluster-wide; no alert fired
**Linear:** [PGM-241](https://linear.app/pgmac-net-au/issue/PGM-241), [PGM-242](https://linear.app/pgmac-net-au/issue/PGM-242)
**Nagios:** `microk8s-newest-pod-age` (warn ≥15m, crit ≥30m without any new pod)

---

## Failure Mode

A node's **apiserver watch cache freezes** because the apiserver's watch on
kine (`snap.microk8s.daemon-k8s-dqlite`) breaks and never recovers. Every
client whose reflector lists at `resourceVersion=0` — kubelet, scheduler,
KCM, ARC controller, any controller-runtime operator — is served the frozen
cache and **never sees new objects**, while:

- the process stays alive and `systemd` reports `active`
- leases keep renewing (the lease goroutine doesn't depend on the cache)
- logs keep flowing (probe noise, etc.)
- `kubectl get` looks completely normal (quorum reads bypass the cache)

Symptoms depend on which component is homed on the frozen node:

| Component on frozen node | Symptom |
|---|---|
| KCM (leader) | Zero pod creations cluster-wide; CronJobs stop; Deployments don't reconcile; deleted pods not replaced |
| Scheduler (leader) | Pods pile up Pending with **no FailedScheduling events** |
| kubelet | Pods assigned to the node sit Pending forever; `Scheduled` is the last event |
| ARC controller | Runner pods not created; stale `Running` EphemeralRunner CRs; GH Actions jobs queue for hours |

**Triggers observed so far:**

1. **Sustained dqlite write-contention storm** (PGM-241 and most recurrences) —
   `database is locked` errors visible around the freeze onset.
2. **dqlite leader election / brief member outage** (2026-07-03, k8s01+k8s02) —
   a `no known leader` blip of a few seconds broke the watch streams on two
   nodes at once. **No sustained lock storm**: by the time the alert fires,
   lock counts are zero and the cluster looks healthy. Do not rule out a
   frozen cache because the dqlite metrics are quiet — the freeze persists
   silently until manually cleared, because microk8s ships the apiserver
   with `DetectCacheInconsistency=false` (kine can't support the probes),
   disabling upstream's self-healing for exactly this state.

## Diagnosis — the RV=0 test

Create any object, then compare a watch-cache read against a quorum read
**on the suspect node's local apiserver**:

```bash
kubectl --context pvek8s run cache-canary -n default --image=busybox:1.36 \
  --restart=Never --command -- true

ssh <node> "sudo /snap/bin/microk8s kubectl get --raw \
  '/api/v1/namespaces/default/pods?resourceVersion=0' | grep -c cache-canary"   # cache read
ssh <node> "sudo /snap/bin/microk8s kubectl get --raw \
  '/api/v1/namespaces/default/pods' | grep -c cache-canary"                     # quorum read
```

**`0` from the cache read and `1` from the quorum read = frozen watch cache.**
Test every node — in PGM-241 two of three nodes were frozen and the healthy
one (k8s02) was silently doing all the work.

Supporting signals:

```bash
# kine watch stream churn on the node (high during/after the break)
sudo journalctl -u snap.microk8s.daemon-kubelite --since "-5 minutes" --no-pager \
  | grep -cE "kine.sock.*closed|unexpected EOF"

# the moment a controller's informers died (e.g. ARC)
kubectl logs -n arc-systems <gharc-pod> | grep "Unexpected EOF during watch stream"
```

## Recovery-time gotcha: frozen caches poison plain kubectl

While any node is frozen, `kubectl` through the cluster VIP can hit the
frozen apiserver and serve **stale reads for single GETs too** (consistent
reads from cache) — e.g. `kubectl wait` on a pod you just created can
return `NotFound` even though the pod exists and runs. During recovery,
treat unexpected `NotFound`/stale answers as more evidence, not as a
failure of your recovery step: verify against a healthy node's apiserver
or a quorum read (`?resourceVersion=` empty forces etcd).

## What does NOT work

- **Restarting kubelite alone.** The rebuilt watch cache freezes again
  immediately because kine's feed is still broken — PGM-241 saw two
  consecutive kubelite restarts on k8s01 produce kubelets stalled from birth.
- **Deleting the leader lease.** The stale instance's lease goroutine is
  alive and re-wins the election within seconds.
- **Waiting.** The cache does not self-heal; KCM was dead 16h.

## Recovery

Per affected node, **non-dqlite-leader nodes first, leader last**
(find the leader with `.leader` via the dqlite client, or
`/var/snap/microk8s/current/var/kubernetes/backend/info.yaml` + leader query):

```bash
NODE=<node>

# 1. Cordon (mandatory — kubelet watch-race on restart, see kubelet-silent-stall.md)
kubectl --context pvek8s cordon "$NODE"

# 2. Restart kine/dqlite FIRST — this is the broken layer
ssh "$NODE" "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite"
ssh "$NODE" "systemctl is-active snap.microk8s.daemon-k8s-dqlite"
# wait ~30s; confirm no 'database is locked' errors:
ssh "$NODE" "sudo journalctl -u snap.microk8s.daemon-k8s-dqlite --since '-1 minute' --no-pager | grep -c 'database is locked'"

# 3. Then kubelite
ssh "$NODE" "sudo systemctl restart snap.microk8s.daemon-kubelite"

# 4. Verify BEFORE uncordon: canary must run AND appear in the cache read
kubectl --context pvek8s run "${NODE}-canary" -n default --image=busybox:1.36 \
  --restart=Never --overrides="{\"spec\":{\"nodeName\":\"${NODE}\"}}" --command -- true
kubectl --context pvek8s wait -n default "pod/${NODE}-canary" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s
ssh "$NODE" "sudo /snap/bin/microk8s kubectl get --raw \
  '/api/v1/namespaces/default/pods?resourceVersion=0' | grep -c ${NODE}-canary"   # must be 1
kubectl --context pvek8s delete pod -n default "${NODE}-canary"

# 5. Uncordon
kubectl --context pvek8s uncordon "$NODE"
```

After recovery, also check for **collateral stale controllers** that broke
when the apiserver bounced: restart any controller-runtime operator pods
(e.g. `gharc-controller` in `arc-systems`) whose logs end in watch EOF
errors, and clean up stale CRs (EphemeralRunners claiming `Running` against
Completed/missing pods).

## Post-Recovery Verification

```bash
kubectl --context pvek8s get pods -A --field-selector status.phase=Pending --no-headers | wc -l   # → 0 (after backlog drains)
kubectl --context pvek8s get pods -A --sort-by=.metadata.creationTimestamp --no-headers | tail -1  # newest pod < 2m old (per-minute cronjobs)
```

Expect a large backlog flood (Jobs for every missed CronJob window) — let it
drain; jiva replica pods may briefly go Pending while rescheduling.

## References

- Incident: PGM-241 (2026-06-10/11) — 16h KCM stall, then scheduler, then kubelets on k8s01+k8s03
- Related: [kubelet-silent-stall.md](kubelet-silent-stall.md) — kubelet-only variant and why cordon-before-restart is mandatory
- Related: [kcm-stale-terminating-replicas.md](kcm-stale-terminating-replicas.md) — earlier, narrower KCM informer staleness
- Related: [kubelet-volume-manager-stall.md](kubelet-volume-manager-stall.md) — processorListener variant; dqlite restart safety checks
- Related: [dqlite-write-contention.md](dqlite-write-contention.md) — the write-storm conditions (PGM-237) that break kine watch streams in the first place
- Related: [dqlite-datastore-vacuum.md](dqlite-datastore-vacuum.md) — structural mitigation; freelist bloat makes every raft snapshot a 200MB+ fsync burst that feeds the storms (pgk8s#577)
