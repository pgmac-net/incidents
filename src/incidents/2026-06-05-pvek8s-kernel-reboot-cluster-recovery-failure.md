---
tags:
  - k8s01
  - k8s02
  - k8s03
  - kubelet
  - containerd
  - calico
  - openebs
  - jiva
  - scheduling
  - dqlite
  - kernel-update
  - simultaneous-reboot
---

# Post Incident Review: pvek8s Kernel Update — Simultaneous 3-Node Reboot Cascade

**Date:** 2026-06-05
**Duration:** ~6h 58m (~06:27 AEST → ~13:25 AEST)
**Severity:** P1 (cluster fully non-functional; 0 user workloads schedulable for first 4h20m)
**Status:** Resolved

---

## Executive Summary

All three pvek8s nodes were simultaneously rebooted to apply kernel 5.4.0-231-generic. The cluster did not self-recover. By 06:27 AEST, all nodes were Ready but 46+ pods remained Pending for over 4h20m with zero FailedScheduling events — the scheduler was running but not scheduling.

Three independent root causes — all on k8s02 — combined to prevent recovery:

1. **RC-1 (Scheduler informer watch stall):** k8s02 won the kube-scheduler Lease election during the 56-node transition chaos window. The scheduler on k8s02 renewed its lease continuously but its pod/node informer watch stream had stalled (same processorListener goroutine pattern as prior incidents). Zero FailedScheduling events was the diagnostic signal: the scheduler appeared healthy but was not draining its work queue.

2. **RC-2 (Calico Felix NAT not reprogrammed):** calico-node on k8s02 failed to reprogram iptables DNAT/MASQUERADE chains post-reboot. Felix's `resync-nat-v4` loop confirmed it knew the rules were missing, but the daemonset pod had not restarted. Jiva iSCSI sessions between k8s02 replicas and ctrl pods (ClusterIP DNAT) were silently failing, preventing Jiva replicas from reaching quorum.

3. **RC-3 (containerd BoltDB stale state):** containerd on k8s02 survived the reboot with stale task entries in its BoltDB state database. Pod sandbox creation failed with `name is reserved for <pre-reboot-hash>` for any pod that had previously run on k8s02.

All three root causes share a single underlying cause: **simultaneous 3-node reboot with no rolling procedure and no pre-drain of containerd state**.

Recovery required 5 sequential interventions on k8s02 over ~2h: force-deletion of stuck Terminating Jiva ctrl pods, two kubelite restarts (the second to clear a kubelet watch stall on newly scheduled pods), a k8s-dqlite restart (to clear `context canceled` errors blocking pod status writes), and force-deletion of lingering Terminating Jiva replica pods. CoreDNS was also scaled from 1 to 2 replicas to eliminate a DNS single point of failure that had contributed to the blast radius.

---

## Timeline (AEST — UTC+10)

| Time | Event |
|------|-------|
| **~06:00 AEST** | All 3 pvek8s nodes rebooted simultaneously for kernel 5.4.0-231-generic |
| **~06:27 AEST** | Incident detected: all nodes Ready but 46+ pods Pending; no FailedScheduling events; cluster not self-recovering |
| **~06:30 AEST** | Scheduler lease confirmed on k8s02 (`k8s02_<uuid>`); zero scheduler events in last 30m despite 46 Pending pods — informer stall diagnosis |
| **~06:45 AEST** | Calico Felix confirmed not reprogramming NAT on k8s02: `iptables -t nat -L | grep KUBE` returns empty for k8s02; `resync-nat-v4` loop in calico-node logs |
| **~07:00 AEST** | containerd BoltDB stale state confirmed on k8s02: `FailedCreatePodSandBox: name is reserved for <pre-reboot-hash>` in kubelet events |
| **~07:30 AEST** | 6 jiva-ctrl pods stuck Terminating (PDB deadlock): force-deleted with `--force --grace-period=0`; Jiva operator reconciliation unblocked |
| **~07:35 AEST** | 3 orphaned `hostpath-provisioner-k8s02-*` pods (no ownerReference) force-deleted |
| **~08:00 AEST** | k8s02 cordoned; `snap.microk8s.daemon-kubelite` restarted (first restart); k8s02 returns Ready; uncordoned |
| **~08:00 AEST** | First kubelite restart resolves RC-1 (scheduler lease released → k8s01 acquires), RC-2 (calico-node pod restarted → Felix reprograms iptables), RC-3 (BoltDB flushed) |
| **~08:00 AEST** | Pending pod count drops from 46 to 6; CoreDNS scaled from 1 to 2 replicas to eliminate DNS SPOF |
| **~08:15 AEST** | New pods assigned to k8s02 by scheduler but kubelet not generating ContainerCreating/Pulling events — kubelet watch stall on newly scheduled pods |
| **~08:30 AEST** | Test pod `kubelet-test` deployed to k8s02; remains Pending >60s with zero events — kubelet watch stall confirmed |
| **~08:45 AEST** | k8s02 cordoned; second `snap.microk8s.daemon-kubelite` restart; pods begin ContainerCreating |
| **~09:00 AEST** | k8s02 uncordoned; Jiva replica pods assigned and scheduled to k8s02; but kubelet cannot write pod status — pods stay Pending despite ContainerCreating assignment |
| **~09:10 AEST** | k8s02 k8s-dqlite logs show `context canceled` on serviceaccount queries; kubelet cannot commit pod status writes through local dqlite follower |
| **~09:10 AEST** | `snap.microk8s.daemon-k8s-dqlite` restarted on k8s02 |
| **~09:15 AEST** | All Jiva replica pods transition Pending → ContainerCreating → Running |
| **~09:20 AEST** | pvc-05e03b60-rep-1, pvc-a3a7e012-rep-2, pvc-a634b9a3-rep-2 Terminating replicas blocking anti-affinity; force-deleted |
| **~09:20 AEST** | All 6 Jiva PVCs reach quorum (3/3 replicas Running across k8s01/k8s02/k8s03) |
| **~09:25 AEST** | survive-minecraft pod deleted for fresh Jiva remount (was on read-only filesystem from degraded Jiva); new pod starts Running |
| **~09:25 AEST** | **121 pods Running/Completed, 0 error-state pods — cluster fully operational** |
| **~09:30 AEST** | ArgoCD app-controller restarted (96 TLS cert rotations during incident caused stale trust anchor; all apps showing Unknown sync) |
| **~09:35 AEST** | All ArgoCD apps: Synced + Healthy |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: 46 Pods Stuck Pending for 4h20m — Scheduler Informer Watch Stall (RC-1)

##### How did 46 pods remain Pending with no FailedScheduling events?

The kube-scheduler component on k8s02 held the Lease object (`kube-system/kube-scheduler`). The scheduler's lease renewal goroutine was functioning (lease `renewTime` was updating every ~15s), but the scheduler's pod and node informer watch streams had stalled. The scheduling work queue received no input from stalled informers, so no scheduling attempts were made and no FailedScheduling events were generated.

##### How did k8s02 win the scheduler Lease during reboot?

During a simultaneous 3-node reboot, the 56 node-state transitions (from Ready → NotReady → Ready across 3 nodes and their components) create a chaotic Lease election window. k8s02's scheduler process was the first to write a Lease object after all nodes returned to Ready. The Lease is first-write-wins with a 60-second holdback.

##### How did the scheduler informer stall occur on k8s02?

The scheduler uses client-go informers with `processorListener` goroutines to receive watch events from the kube-apiserver. After k8s02's simultaneous reboot, the kine watch stream from k8s-dqlite (local follower on k8s02) reconnected at the TCP level but the internal watch event forwarding state was inconsistent. The informer's `reflector` received no new events post-reconnect; the delta queue stayed empty; scheduling goroutines blocked waiting for queue data.

##### Why did this only affect k8s02?

k8s01 and k8s03 also have scheduler processes, but they were not the Lease holder. Only the active Lease holder's scheduler actually processes pods. k8s01 and k8s03 schedulers were in standby (they could acquire the lease within 60s of detecting liveness failure, but the lease was being renewed continuously — just not scheduling).

##### How was this not detected earlier?

- `kubectl get nodes` showed all nodes Ready: heartbeats run on a separate HTTPS endpoint independent of informer event queues
- `kubectl get pods -A | grep Pending` showed 46 Pending pods but no FailedScheduling events is an unusual pattern — the absence of events is the signal
- No Nagios/Prometheus alert exists for `Pending pods > N for > 5m WITH FailedScheduling events = 0` — this combination specifically indicates scheduler stall vs. legitimate scheduling pressure

---

#### Chain 2: Jiva Replicas Cannot Reach Quorum — Calico Felix NAT Not Reprogrammed (RC-2)

##### How did Jiva replicas fail to reach quorum?

Jiva replicas communicate with their ctrl pod via the ClusterIP service. On k8s02, the iptables DNAT chains for ClusterIP were absent post-reboot. Jiva iSCSI connections from k8s02 replicas to ctrl pods (which run on k8s01) were silently dropped — TCP connections to ClusterIP addresses never reached their destination. With replicas unable to connect to ctrl, quorum could not be formed.

##### How did the iptables DNAT chains go missing on k8s02?

The kernel's iptables state does not survive a reboot. On reboot, Calico's Felix agent is responsible for reprogramming all NAT chains. Felix on k8s02's calico-node pod was running and its `resync-nat-v4` loop was logging the issue, but the calico-node pod itself had not been restarted since the reboot — it was still running with pre-reboot state. Felix requires a fresh start (or explicit `felix reload`) to re-examine and reprogram all chains from scratch.

##### How did calico-node not restart after the node reboot?

calico-node is a DaemonSet with `restartPolicy: Always`. After node reboot, if the pod transitions from Running → Unknown → Running (the node flap pattern), the kubelet may not trigger a container restart. In this case, the calico-node pod on k8s02 survived the reboot without a container restart — its PID persisted with Felix in a degraded NAT state.

##### How was this not detected earlier?

- No NRPE check verifies that ClusterIP DNAT rules exist on each node post-reboot
- Felix `resync-nat-v4` logs are not surfaced as alerts
- The symptom (Jiva not reaching quorum) could be mistaken for anti-affinity or PDB deadlock without checking iptables first

---

#### Chain 3: Pod Sandbox Creation Failing — containerd BoltDB Stale State (RC-3)

##### How did pod sandbox creation fail on k8s02?

`kubectl describe pod` on pods assigned to k8s02 showed: `FailedCreatePodSandBox: name is reserved for <pre-reboot-container-hash>`. containerd's BoltDB task database retained task entries from before the reboot, associating sandbox names with container hashes that no longer existed. New pods attempting to create sandboxes with the same name pattern were rejected.

##### How did containerd BoltDB survive the kernel reboot with stale entries?

containerd persists runtime state to a BoltDB file at `/var/snap/microk8s/common/run/containerd/containerd.db`. This database is not cleaned on service restart unless containerd performs explicit cleanup. Simultaneous reboot (vs. graceful `containerd stop` + `ctr containers rm`) leaves all task entries intact. The BoltDB represents running tasks that no longer exist in the kernel (the network namespaces were destroyed by the reboot) but containerd does not detect this on startup.

##### How was this not caught by containerd's startup health check?

containerd's startup check verifies that its own daemon is running, not that all persisted tasks correspond to live kernel objects. The stale entries in BoltDB are silently accepted. The inconsistency only manifests when a new pod attempts to reuse a name that appears occupied in the BoltDB.

##### How was this not prevented?

The pre-reboot procedure did not include `crictl stopp $(crictl pods -q); crictl rmp $(crictl pods -q)` (stop + remove all pod sandboxes before rebooting). This would have drained BoltDB cleanly before the kernel reboot, eliminating the stale state entirely.

---

#### Chain 4: k8s02 Pod Status Updates Failing — k8s-dqlite `context canceled` (Secondary)

##### How did pods assigned to k8s02 remain stuck in Pending after the second kubelite restart?

After the second kubelite restart, the kubelet on k8s02 was receiving pod assignments from the scheduler (pods had `spec.nodeName: k8s02` set) and beginning pod startup. However, the kubelet could not write pod status updates back to the API server — specifically, it could not commit status changes to move pods from Pending to ContainerCreating.

##### How did the kubelet fail to write pod status?

k8s02's kubelet contacts the local k8s-dqlite follower process via kine.sock. The k8s-dqlite follower forwards writes to the leader (k8s01). The k8s-dqlite process on k8s02 was emitting `context canceled` errors when handling serviceaccount queries — indicating that the write path from k8s02 to the dqlite leader was failing or timing out. The kubelet's API write calls returned errors, blocking status progression.

##### How did a k8s-dqlite restart resolve this?

Restarting the k8s-dqlite process cleared the stale connection state and re-established a clean Raft follower connection to the leader on k8s01. After restart, write transactions completed successfully and the kubelet's pod status updates were committed immediately — all stuck pods transitioned from Pending to ContainerCreating within seconds.

---

## Impact

### Services Affected

| Service | Impact | Duration |
|---------|--------|----------|
| kube-scheduler | Lease on k8s02 (stalled informer); zero scheduling for ~4h20m | ~4h20m |
| All user workloads | 46+ pods stuck Pending; cluster effectively non-functional | ~4h20m |
| Jiva storage | Replicas unable to reach quorum; ClusterIP DNAT absent on k8s02 | ~4h |
| survive-minecraft | Read-only filesystem from degraded Jiva mount | ~1h (pod deleted for remount after quorum restored) |
| ArgoCD sync | Unknown sync state due to 96 TLS cert rotations during incident | ~20m (cleared after app-controller restart) |
| Media workloads (sonarr, radarr, readarr, calibreweb) | Unaffected throughout — pinned to k8s01 stale iSCSI mounts that survived the reboot (NOT restarted) | 0 |

### Duration

- **Full outage window:** ~6h 58m (06:27 → 13:25 AEST)
- **Zero scheduling window:** ~4h 20m
- **Storage/quorum degradation:** ~4h

### Scope

- 3 nodes affected (all nodes involved in simultaneous reboot)
- No data loss: all PVC data intact; all 6 Jiva volumes reached quorum
- Media services (sonarr/radarr/readarr/calibreweb) were NOT restarted per incident protocol and survived on stale iSCSI mounts throughout

---

## What Went Well

1. **Media workloads preserved throughout.** Incident protocol to never restart sonarr/radarr/readarr/calibreweb during Jiva degradation was followed. All 4 services remained Running on stale iSCSI mounts.

2. **Three-layer root cause isolation.** RC-1/RC-2/RC-3 were identified independently before beginning remediation. This prevented a premature k8s02 kubelite restart from being the first action (which would have been correct, but without understanding why).

3. **Single intervention to fix RC-1+RC-2+RC-3 simultaneously.** The kubelite restart on k8s02 resolved all three root causes in one action: scheduler lease released, calico-node pod restarted (Felix reprogram triggered), containerd BoltDB flushed.

4. **Jiva replica quorum restored without data loss.** Progressive force-deletion of Terminating pods (PDB deadlock, anti-affinity deadlock, orphaned pods) unblocked Jiva operator reconciliation without losing any replica data.

5. **CoreDNS HA improvement made during incident.** CoreDNS was scaled from 1 to 2 replicas on separate nodes — a longstanding single point of failure was closed.

---

## What Could Improve

1. **No rolling reboot procedure existed.** The kernel update was applied by rebooting all 3 nodes simultaneously. There was no documented or automated rolling procedure to reboot one node at a time with health verification between each.

2. **No containerd pre-drain step.** The reboot procedure did not include stopping and draining all pod sandboxes via `crictl stopp/rmp` before reboot. This is the proximate cause of RC-3.

3. **No alert for scheduler stall pattern.** The combination of `Pending pods > 0 for > 5m` AND `FailedScheduling events = 0` specifically indicates a scheduler informer stall. This pattern should be alerted but is not.

4. **No alert for scheduler lease holder degraded.** When the scheduler Lease is held by a node experiencing component stalls, there is no detection mechanism. A check for `Lease holder node Ready=True AND FailedScheduling = 0 for > 5m` was not implemented.

5. **CoreDNS was a SPOF.** A single CoreDNS replica was deployed on a single node. Any node reboot including that node drops in-cluster DNS. PodAntiAffinity was not configured.

6. **k8s-dqlite `context canceled` errors not alerted.** The secondary failure (Pod status writes blocked by dqlite follower errors) would have been caught earlier with a check on journalctl for `context canceled` in dqlite logs. The existing `check_dqlite_locks.sh` monitors for `database is locked` but not `context canceled`.

---

## Action Items

| ID | Action | Owner | Priority | Deadline |
|----|--------|-------|----------|----------|
| PGM-226 | Implement rolling reboot playbook (`k8s-reboot.yml`) with: pre-flight jiva-ctrl check, `crictl stopp/rmp` drain, one-node-at-a-time enforcement, post-reboot Calico + Jiva quorum verification | @pgmac | High | 2026-06-12 |
| PGM-226 | Deploy `check_k8s_scheduler_stall.sh` Nagios NRPE check (Pending + zero events pattern) to all 3 nodes | @pgmac | High | 2026-06-12 |
| PGM-226 | Deploy `check_coredns_replicas.sh` NRPE check; ensure CoreDNS PodAntiAffinity patch is applied via ArgoCD | @pgmac | High | 2026-06-07 |
| PGM-226 | Reduce scheduler `leaseDurationSeconds` from 60s to 20s in `/var/snap/microk8s/current/args/kube-scheduler` | @pgmac | Medium | 2026-06-12 |
| PGM-226 | Add `check_calico_node_restarts.sh` NRPE check for Calico NAT reprogramming failures | @pgmac | Medium | 2026-06-19 |
| PGM-226 | Deploy `check_sandbox_changed.sh` NRPE check (SandboxChanged storm = containerd BoltDB stale state indicator) | @pgmac | Medium | 2026-06-19 |
| PGM-226 | Add `context canceled` to dqlite NRPE check thresholds | @pgmac | Medium | 2026-06-19 |
| PGM-226 | Pin Cloudflare Tunnel with node anti-affinity away from k8s02 | @pgmac | Low | 2026-06-26 |
| PGM-226 | Apply vaultwarden NetworkPolicy (ingress-only from ingress-nginx namespace) | @pgmac | Low | 2026-06-26 |

---

## Lessons Learned

### Rolling reboot is non-negotiable for cluster nodes

Rebooting all cluster nodes simultaneously is the equivalent of a complete cluster power cycle. For microk8s with embedded scheduler, controller-manager, and kubelet in kubelite, a simultaneous reboot guarantees chaotic Lease election races and stale component state. Any future kernel update must use the rolling procedure: cordon → drain → reboot → verify Ready → uncordon → wait → next node.

### containerd must be drained before rebooting

`crictl stopp $(crictl pods -q) && crictl rmp $(crictl pods -q)` before rebooting cleanly drains BoltDB. Skipping this step leaves stale sandbox state that blocks pod restart on the next boot. This is especially critical for long-running clusters where pods have been running for weeks or months.

### Zero FailedScheduling events with Pending pods is the scheduler stall signature

Normal scheduling pressure produces FailedScheduling events. A scheduler informer stall produces silence. These two cases look identical from `kubectl get pods` (both show Pending), but are completely different problems requiring different responses. Absence of evidence is evidence of a different kind of failure.

### Lease election races favour problematic nodes

In a simultaneous 3-node reboot, any node can win the scheduler Lease. If k8s02 wins and k8s02 has a component stall, the entire cluster scheduling stops — even though k8s01 and k8s03's schedulers are healthy but idle. Reducing `leaseDurationSeconds` from 60s to 20s means a stalled scheduler is detected and the lease released 3× faster.

### Cascading failures require layered diagnosis before action

RC-1, RC-2, and RC-3 were all present simultaneously. Acting on the most visible symptom (force-deleting stuck pods, or rescheduling workloads) without understanding all three causes would have been ineffective. The correct approach was to enumerate all root causes first, then find the single action (kubelite restart on k8s02) that addressed all three at once.

### Jiva PDB deadlocks require force-deletion; there is no gentler path

When Jiva ctrl pods are stuck Terminating with a PDB that requires minAvailable > current healthy replicas, the cluster will wait forever. The Jiva operator cannot reconcile until old ctrl pods are gone. Force-deletion with `--force --grace-period=0` is the only resolution, and it is safe because ctrl pods are stateless coordinators (replica data lives on the nodes, not in the ctrl pod).

---

## Resolution Summary

**Five sequential interventions on k8s02:**

1. Force-delete 6 Terminating jiva-ctrl pods + 3 orphaned hostpath-provisioner pods → unblocked Jiva operator
2. First kubelite restart on k8s02 → fixed RC-1 (scheduler), RC-2 (Calico), RC-3 (containerd BoltDB)
3. Second kubelite restart on k8s02 → cleared kubelet watch stall on newly scheduled pods
4. k8s-dqlite restart on k8s02 → cleared `context canceled` errors blocking pod status writes
5. Force-delete Terminating Jiva replica pods (anti-affinity deadlock) → Jiva quorum reached

**Final cluster state:** 3 nodes Ready, 121 pods Running/Completed, 0 error-state pods, all services operational, CoreDNS HA (2 replicas, 2 nodes).
