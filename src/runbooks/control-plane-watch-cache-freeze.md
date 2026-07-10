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

## Automated recovery (since 2026-07-04; watchdog since 2026-07-09)

Single-node freezes are **auto-remediated** via two independent trigger
paths, both landing on the same guarded remediation
(`/etc/nagios/remediate_watch_cache.sh`, shipped by ansible; cluster Lease
mutex + per-node transient-unit mutex dedupe them):

1. **Node-local dead-man switch (primary, delivery-independent)** — a
   systemd timer on every node (`watch-cache-watchdog.timer`, 5 min tick)
   runs the RV=0 write-reflection self-test locally; **two consecutive
   CRITICAL results** trigger `event_watch_cache_remediate.sh` directly on
   the node. No nagios, no NRPE, no network in the trigger path
   ([homelabia#134](https://github.com/pgmac-net/homelabia/issues/134),
   closing the 2026-07-09 delivery gap). Worst-case trigger ~11 min from
   freeze onset. UNKNOWN self-test results do not count as strikes.
2. **Nagios event handler (faster parallel path)** — `microk8s-watch-cache`
   HARD CRITICAL fires `event_watch_cache_remediate` via NRPE (~6 min when
   delivery works). Since 2026-07-09 the service uses `check_nrpe_60`, so a
   real freeze shows the check's actual CRITICAL output rather than
   `Socket timeout after 15 seconds`.

Audit trail: `journalctl -u watch-cache-watchdog` (self-test + strikes) and
`journalctl -u watch-cache-remediate` (the remediation itself) on the node,
plus nagios.log event-handler entries.

**A human is needed only when the automation defers or fails:**

- `DEFERRED: only N/2 other nodes Ready+schedulable` — multi-node
  incident; run the manual procedure below.
- `DEFERRED: remediation lease held by <node>` — another node was
  remediating at that instant. Usually benign, **but** the DEFERRED path
  exits 1, leaving the node's transient `watch-cache-remediate.service`
  in systemd `failed` state — which silently blocks every future
  watchdog trigger on that node (see delivery failure #2 below). After
  any DEFERRED, run `sudo systemctl reset-failed watch-cache-remediate.service`
  on that node until [homelabia#137](https://github.com/pgmac-net/homelabia/issues/137)
  ships.
- `REFUSED: remediation ran <2h ago` — recurring freeze; investigate the
  trigger (write storms, snapshot bloat — see
  [dqlite-datastore-vacuum.md](dqlite-datastore-vacuum.md)) instead of
  restarting again.
- `FAILED: ... leaving <node> CORDONED` — the script never uncordons
  without a verified canary in the RV=0 cache read; pick up from
  whichever step it failed at.
- Kill switch: `systemctl disable --now watch-cache-watchdog.timer` on the
  node (watchdog path) and/or remove the `event_handler` line from the
  `microk8s-watch-cache` service in nagios-config and reload nagios
  (handler path).

### Delivery failure: empty journal does NOT mean the handler never fired

Confirmed 2026-07-09 (5h13m outage): the event handler can fire correctly
nagios-side while the remediation never runs on the node. Nagios fires
handlers only on state transitions (SOFT 1, SOFT 2, SOFT→HARD) — three
attempts total, no refire during steady HARD CRITICAL — and all three NRPE
calls can be lost while the node's NRPE is saturated by sibling checks each
running 30–40s against the frozen apiserver (nagios `check_nrpe` gives up at
15s; the watch-cache check itself shows `Socket timeout after 15 seconds`
instead of real output).

Triage to distinguish the cases:

```bash
# Did nagios fire the handler?
ssh macro 'docker exec nagios4 grep -a "EVENT HANDLER" /opt/nagios/var/nagios.log | tail'
# → SERVICE EVENT HANDLER: <node>;microk8s-watch-cache;CRITICAL;HARD;3;event_watch_cache_remediate

# Did the node run it?
ssh <node> 'sudo journalctl -u watch-cache-remediate --since "-6 hours" --no-pager'
# → empty + handler entries above = DELIVERY FAILED: go straight to the
#   manual procedure below; do not wait for the automation.
```

A `microk8s-watch-cache` result of `Socket timeout after 15 seconds` (rather
than a proper CRITICAL message) is itself a saturation indicator — assume
the handler path is lost and check the watchdog journal
(`journalctl -u watch-cache-watchdog`) for strike progress. Both fixes for
this failure mode shipped 2026-07-09 via
[homelabia#134](https://github.com/pgmac-net/homelabia/issues/134): the
node-local watchdog trigger path and the `check_nrpe_60` timeout. This triage
remains for the case where *both* paths fail.

### Delivery failure #2: stale `failed` unit blocks the watchdog trigger

Confirmed 2026-07-10 (~3h scheduling outage, k8s03 holding both scheduler
and KCM leases): the watchdog reached strike 2/2 but logged
`WARNING: failed to launch remediation unit on <node>` and the remediation
never ran. Chain:

1. An earlier remediation attempt on the node **DEFERRED** (lease held by
   another node — correct behaviour) and exited 1, so systemd recorded the
   transient `watch-cache-remediate.service` as `failed`. Nothing resets it.
2. `event_watch_cache_remediate.sh` guards only with
   `systemctl is-active --quiet` (true only while *running*), so the stale
   `failed` unit passes the guard, and `systemd-run --unit=watch-cache-remediate`
   then refuses to start because a unit with that name already exists.
   The Lease guard inside `remediate_watch_cache.sh` is never reached.

Any DEFERRED/FAILED attempt therefore permanently disables the watchdog
trigger path on that node until manually cleared. Triage and fix:

```bash
# The tell: strike 2/2 followed by the launch warning
ssh <node> "sudo journalctl -u watch-cache-watchdog --since '-6 hours' --no-pager \
  | grep -E 'strike 2/2|failed to launch'"

# Confirm the stale unit
ssh <node> "systemctl is-failed watch-cache-remediate.service"   # → failed

# Clear it (also do this after any DEFERRED, proactively)
ssh <node> "sudo systemctl reset-failed watch-cache-remediate.service"
```

Clearing the unit does **not** retro-trigger remediation — the watchdog
only fires on a fresh strike 2/2, up to ~10 min away. If the freeze is
live, don't wait: run the manual procedure below. Script fix tracked in
[homelabia#137](https://github.com/pgmac-net/homelabia/issues/137).

## Manual recovery

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

Also check for **PVs provisioned during the freeze with empty nodeAffinity**
(2026-07-09): the hostpath provisioner records an empty hostname when its
helper pods can't schedule, producing PVs with
`kubernetes.io/hostname In [""]` — permanently unschedulable claims, and PV
nodeAffinity is immutable. Any pod stuck Pending after recovery with
`didn't match PersistentVolume's node affinity` on all nodes:

```bash
kubectl --context pvek8s get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}{"\n"}{end}'
# → any PV showing an empty value is broken; do NOT try to patch it

# Recycle the claimant instead (ephemeral workloads):
kubectl --context pvek8s -n arc-runners delete ephemeralrunner <runner>
# ARC recreates runner + PVC; the healthy provisioner produces a correct PV in ~80s
```

Expect leftover provisioner helper pods (one per ~8min retry during the
freeze) — delete the Completed ones; the `microk8s-hostpath-orphans` check
catches any orphaned backing directories they leave behind
([homelabia#135](https://github.com/pgmac-net/homelabia/issues/135)).

## Post-Recovery Verification

```bash
kubectl --context pvek8s get pods -A --field-selector status.phase=Pending --no-headers | wc -l   # → 0 (after backlog drains)
kubectl --context pvek8s get pods -A --sort-by=.metadata.creationTimestamp --no-headers | tail -1  # newest pod < 2m old (per-minute cronjobs)
```

Expect a large backlog flood (Jobs for every missed CronJob window) — let it
drain; jiva replica pods may briefly go Pending while rescheduling.

## References

- PIR: [pvek8s Scheduling Outage — k8s03 Watch-Cache Freeze and Auto-Remediation Delivery Failure](../incidents/2026-07-09-k8s03-watch-cache-freeze-remediation-delivery-failure.md) (2026-07-09) — 5h19m scheduling outage; source of the delivery-failure triage and empty-nodeAffinity PV sections
- Incident 2026-07-10 — ~3h scheduling outage, k8s03 frozen while holding both scheduler and KCM leases; source of delivery failure #2 (stale `failed` unit); fix tracked in [homelabia#137](https://github.com/pgmac-net/homelabia/issues/137)
- Incident: PGM-241 (2026-06-10/11) — 16h KCM stall, then scheduler, then kubelets on k8s01+k8s03
- Related: [kubelet-silent-stall.md](kubelet-silent-stall.md) — kubelet-only variant and why cordon-before-restart is mandatory
- Related: [kcm-stale-terminating-replicas.md](kcm-stale-terminating-replicas.md) — earlier, narrower KCM informer staleness
- Related: [kubelet-volume-manager-stall.md](kubelet-volume-manager-stall.md) — processorListener variant; dqlite restart safety checks
- Related: [dqlite-write-contention.md](dqlite-write-contention.md) — the write-storm conditions (PGM-237) that break kine watch streams in the first place
- Related: [dqlite-datastore-vacuum.md](dqlite-datastore-vacuum.md) — structural mitigation; freelist bloat makes every raft snapshot a 200MB+ fsync burst that feeds the storms (pgk8s#577)
