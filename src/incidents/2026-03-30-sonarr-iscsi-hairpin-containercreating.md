# Post Incident Review: Sonarr Outage Due to iSCSI Hairpin NAT Failure on k8s03

**Date:** 2026-03-30
**Duration:** Unknown silent failure period + ~45m active investigation and recovery
**Severity:** P2 (single service outage — Sonarr completely unavailable)
**Status:** Resolved

---

## Executive Summary

Sonarr became unavailable when its pod became stuck in `ContainerCreating` and could not progress past volume attachment. The pod had been rescheduled to k8s03 following a prior instability event, and the Jiva iSCSI controller for the `sonarr-config` PVC happened to also be running on k8s03 at the time.

The mount failure was caused by an iSCSI hairpin NAT limitation in microk8s: when the sonarr pod's kubelet (running in the host network namespace on k8s03) attempted to connect to the Jiva controller's ClusterIP (`10.152.183.62:3260`), kube-proxy DNAT forwarded the connection back to a pod on the same node. The microk8s CNI (Calico) does not support hairpin NAT for host-namespace iSCSI clients — the connection was dropped at the PDU receive stage, producing a repeated `Login I/O error, failed to receive a PDU` error.

Investigation was complicated by two misleading earlier errors. A preceding `fsck found errors on device ... but could not correct them` event (from an earlier pod on k8s01) had already resolved by the time the active investigation began, and fsck of the volume confirmed the filesystem was clean (exit 0). The Jiva controller pod and all three replicas were running and healthy throughout — the failure was purely a network topology issue invisible from pod status output.

Resolution required cordoning k8s03 to prevent sonarr from rescheduling there, force-deleting the stuck pod, and confirming the new pod landed on k8s01 (a different node to the Jiva controller). Sonarr reached `1/1 Running` within 27 seconds of rescheduling, with clean database startup and no data loss.

A secondary unrelated issue — OpenEBS components on k8s02 experiencing a restart storm (localpv-provisioner: 697 restarts, snapshot-operator: 184 restarts) due to k8s02 disk pressure — was identified during the investigation but did not contribute to the Sonarr outage directly.

---

## Timeline (AEST — UTC+10)

| Time | Event |
| ---- | ----- |
| **Prior to detection** | Sonarr pod previously running on k8s01 becomes unhealthy (readiness probe failure). Pod rescheduled to k8s01, then to k8s03. |
| **Prior to detection** | `fsck found errors on device ... but could not correct them` recorded in media namespace events (k8s01). iSCSI session on k8s01 subsequently cleared. |
| **~T+0** | **INCIDENT DETECTED**: Sonarr pod `sonarr-dd4cb4f69-8kmhv` stuck in `ContainerCreating` on k8s03. User reports issue. |
| ~T+2m | Initial investigation: `kubectl describe pod` reveals repeated `FailedMount` — `iscsi: failed to sendtargets to portal 10.152.183.62:3260` / `iscsiadm: Login I/O error, failed to receive a PDU`. |
| ~T+3m | **Initial misdiagnosis**: Jiva controller pod suspected missing; ClusterIP `10.152.183.62` suspected unreachable. Corrected after observability sweep confirms controller pod `2/2 Running`, 0 restarts, 6+ hours uptime. |
| ~T+8m | **Second misdiagnosis**: fsck error in earlier events suspected as active root cause. Corrected after fsck debug pod run on k8s01 returns exit 0 — filesystem clean. |
| ~T+15m | **Action 1**: Jiva controller pod deleted and restarted. New controller pod reaches `2/2 Ready`. Sonarr remains in `ContainerCreating`. |
| ~T+18m | **Action 2**: Sonarr pod force-deleted (`--force --grace-period=0`). New pod also scheduled to k8s03. Also stuck in `ContainerCreating`. |
| ~T+20m | **Root cause identified**: Both sonarr pod and Jiva controller pod on k8s03. iSCSI hairpin NAT limitation confirmed — microk8s host-namespace iscsiadm cannot traverse kube-proxy DNAT when source and backend pod are on the same node. |
| ~T+22m | **Resolution start**: k8s03 cordoned to prevent sonarr rescheduling there. |
| ~T+23m | Sonarr pod force-deleted. New pod `sonarr-dd4cb4f69-k929r` scheduled to k8s01. |
| ~T+24m | iSCSI attach and mount succeeds. Sonarr container starts. |
| ~T+25m | **INCIDENT RESOLVED**: `sonarr-dd4cb4f69-k929r` reaches `1/1 Running` on k8s01. DB migrations complete. `Application started` confirmed in logs. |
| ~T+26m | k8s03 uncordoned. |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### How did Sonarr become unavailable?

The sonarr pod entered `ContainerCreating` and never progressed. No container was launched, so the readiness probe could not succeed and the service was completely unavailable.

#### How did the container fail to launch?

Kubelet was unable to mount the `sonarr-config` PVC. The pod is stuck in `ContainerCreating` indefinitely when PVC mounting fails — Kubernetes has no timeout on this state.

#### How did the PVC mount fail?

The iSCSI initiator (`iscsiadm`) on k8s03 could not establish a session with the Jiva controller's iSCSI target at ClusterIP `10.152.183.62:3260`. The error chain was:

```
iscsi: failed to sendtargets to portal 10.152.183.62:3260
iscsiadm: Connection to Discovery Address 10.152.183.62 failed
iscsiadm: Login I/O error, failed to receive a PDU
```

The attach succeeded at the Kubernetes control plane level (`SuccessfulAttachVolume` was logged by the attachdetach-controller), but the host-level iSCSI session could not be established.

#### How did the iSCSI session fail to establish when the controller pod was running and healthy?

`iscsiadm` runs in the host network namespace on each node (it is a host-level process invoked by kubelet). When it connects to ClusterIP `10.152.183.62:3260`, kube-proxy (iptables DNAT rules) rewrites the destination to the actual Jiva controller pod IP.

The Jiva controller pod was running on k8s03 — the same node as the sonarr pod. kube-proxy DNAT forwarded the connection from the host network namespace back to a pod running on the local node. microk8s with Calico does not support hairpin NAT for host-namespace clients: a host process connecting to a ClusterIP whose backing pod is on the same node cannot traverse the DNAT path and have the reply delivered back correctly. The TCP handshake either fails or the PDU exchange times out.

#### How did the sonarr pod and Jiva controller end up co-scheduled on k8s03?

No pod anti-affinity rules exist on the sonarr deployment. The Kubernetes scheduler placed the sonarr pod on k8s03 based on resource availability without awareness that the Jiva controller for sonarr's PVC was also on k8s03. The Jiva controller itself also has no affinity rules to avoid co-scheduling with its consumer pods.

This co-scheduling is a normal, valid scheduling decision from Kubernetes' perspective. The failure mode is invisible to the scheduler because the iSCSI connection failure only manifests at mount time, not during scheduling.

#### How did this co-scheduling not cause issues before?

The hairpin NAT limitation is node-specific: if sonarr and its Jiva controller are on different nodes, iSCSI works correctly because DNAT routes the connection to a remote pod IP, which traverses the standard overlay network. The failure only occurs when both land on the same node. Prior to this incident, sonarr ran on k8s01 with the Jiva controller on a different node.

The rescheduling that triggered this incident occurred because sonarr's prior pod had a readiness probe failure, causing a restart and new scheduling cycle — which happened to place both sonarr and the controller on k8s03.

#### How did this take ~20 minutes to diagnose despite a known error pattern?

Two prior errors in the event log created false trails:

1. An older `fsck found errors on device ... but could not correct them` event was still visible in `kubectl describe pod` output. This was from a previous pod on k8s01 and had already resolved (the iSCSI session on k8s01 was cleared). It was investigated first, consuming diagnostic time.

2. The `Login I/O error, failed to receive a PDU` error is identical whether the cause is a missing controller pod, a hung iSCSI target daemon, a network policy, or a hairpin NAT failure. The controller pod showing `2/2 Running` with 0 restarts correctly ruled out a missing controller, but the hairpin hypothesis was not reached until Actions 1 and 2 failed to resolve it.

There is no Kubernetes event, log entry, or metric that directly identifies "iSCSI hairpin NAT failure" as the cause. The diagnosis required elimination of all other causes combined with observation that both pods were on the same node.

---

### Secondary Issue: k8s02 OpenEBS Restart Storm

Independently of the Sonarr outage, all OpenEBS components co-located on k8s02 were in a restart storm (localpv-provisioner: 697 restarts, snapshot-operator: 184 restarts, provisioner: 110 restarts). This correlates with the known k8s02 disk pressure issue where `ImageGCFailed` events show the kubelet image garbage collector cannot free space. This did not cause the Sonarr outage but represents ongoing storage subsystem risk. Tracked separately.

---

## Impact

### Services Affected

- **Sonarr** (`https://sonarr.int.pgmac.net`): Completely unavailable. No TV episode search, monitoring, or download management.
- **All other media services**: Unaffected throughout — Radarr, Readarr, Overseerr, SABnzbd, Tautulli, Calibre all remained healthy.

### Duration

- **Sonarr outage**: Exact start unknown; active investigation and recovery: ~45 minutes
- **Data loss**: None — PVC remained Bound and filesystem was confirmed clean (fsck exit 0)

### Scope

- **Storage**: Single PVC (`sonarr-config`, pvc-17e6e808-a9fc-4f64-b490-71deffdb81fd, 1Gi openebs-jiva-default)
- **User-facing**: No TV library management, no episode tracking updates
- **Other Jiva volumes**: Unaffected (their pods and controllers were not co-scheduled on the same node)

---

## Resolution Steps Taken

### 1. Confirm Current Pod and Node State

```bash
kubectl --context pvek8s -n media get pod -l app.kubernetes.io/name=sonarr -o wide
kubectl --context pvek8s -n openebs get pod | grep "17e6e808"
```

Confirmed both sonarr (`sonarr-dd4cb4f69-8kmhv`) and Jiva controller (`pvc-17e6e808-...-ctrl-75854597dc-pr4kt`) were on k8s03.

### 2. Restart Jiva Controller Pod (Action 1 — did not resolve)

```bash
kubectl --context pvek8s -n openebs delete pod \
  pvc-17e6e808-a9fc-4f64-b490-71deffdb81fd-ctrl-75854597dc-pr4kt
```

New controller pod came up `2/2 Ready`. Sonarr remained in `ContainerCreating` — new controller pod also landed on k8s03.

### 3. Force-Delete Sonarr Pod (Action 2 — did not resolve)

```bash
kubectl --context pvek8s -n media delete pod \
  sonarr-dd4cb4f69-8kmhv --force --grace-period=0
```

New sonarr pod also scheduled to k8s03. Also stuck in `ContainerCreating`. Confirmed hairpin NAT as root cause.

### 4. Run fsck to Confirm Filesystem Health (Action 3 — confirmed clean)

Scaled sonarr to 0, deployed privileged debug pod on k8s01, ran `fsck.ext4 -y` on the iSCSI device. Result: exit 0, no errors. Filesystem confirmed clean.

### 5. Cordon k8s03 and Reschedule Sonarr (Resolution)

```bash
# Prevent sonarr from scheduling to k8s03
kubectl --context pvek8s cordon k8s03

# Force-delete stuck pod to trigger rescheduling
kubectl --context pvek8s -n media delete pod \
  sonarr-dd4cb4f69-<new-id> --force --grace-period=0

# Confirm new pod on a different node
kubectl --context pvek8s -n media get pod -l app.kubernetes.io/name=sonarr -o wide

# Restore k8s03 to schedulable
kubectl --context pvek8s uncordon k8s03
```

New pod `sonarr-dd4cb4f69-k929r` scheduled to k8s01. iSCSI mounted cleanly. Pod reached `1/1 Running` within 27 seconds.

---

## Verification

- ✅ **Sonarr**: `sonarr-dd4cb4f69-k929r` — `1/1 Running` on k8s01, 0 restarts
- ✅ **Startup logs**: `Application started`, `Now listening on: http://[::]:8989`, DB migrations clean (SQLite 3.51.2)
- ✅ **PVC**: `sonarr-config` — Bound, mounted on k8s01
- ✅ **Filesystem**: fsck exit 0, 1893/65536 files, 120975/262144 blocks, no errors
- ✅ **Jiva replicas**: All 3 `1/1 Running` (rep-1: 6 restarts, rep-2: 0, rep-3: 3 — pre-existing, not incident-related)
- ✅ **k8s03**: Uncordoned, all other pods healthy

---

## Preventive Measures

### Immediate Actions Required

1. **Add pod anti-affinity to sonarr deployment to prevent co-scheduling with its Jiva controller** (Critical Priority)
   - Current: No anti-affinity rules; scheduler can place sonarr and its Jiva controller on the same node
   - Target: Preferred anti-affinity rule preventing sonarr from sharing a node with pods labelled for its PV
   - Implementation (via ArgoCD):
     ```yaml
     affinity:
       podAntiAffinity:
         preferredDuringSchedulingIgnoredDuringExecution:
         - weight: 100
           podAffinityTerm:
             labelSelector:
               matchLabels:
                 openebs.io/persistent-volume: pvc-17e6e808-a9fc-4f64-b490-71deffdb81fd
             topologyKey: kubernetes.io/hostname
     ```
   - **Rationale**: The co-scheduling failure mode is entirely preventable with a single affinity rule. Without it, any future rescheduling event can reproduce this outage.

2. **Apply the same anti-affinity pattern to all Jiva-backed deployments** (High Priority)
   - Radarr, Readarr, Overseerr, Calibreweb all use `openebs-jiva-default` PVCs and have the same latent exposure
   - Implement the same anti-affinity pattern for each deployment, referencing their respective PV names
   - **Rationale**: This incident revealed a cluster-wide misconfiguration, not a sonarr-specific one

3. **Alert on pods stuck in ContainerCreating > 5 minutes** (Critical Priority)
   - This action item carries over from the 2026-02-22 Radarr PIR (still Open). This incident is a second occurrence of the same detection gap.
   - Implementation: Prometheus `kube_pod_status_phase` + duration alert rule → Slack/notification
   - **Rationale**: Two separate incidents have now involved pods sitting in `ContainerCreating` for extended periods without alerting. This must be closed.

4. **Document iSCSI hairpin NAT as a known microk8s/Calico limitation in a runbook** (High Priority)
   - Add a runbook entry: "Sonarr/Radarr/other Jiva-backed pod stuck in ContainerCreating with iSCSI PDU errors — check for controller/consumer co-scheduling on same node"
   - Include the cordon-reschedule resolution procedure
   - Location: `incidents/docs/runbooks/openebs-jiva-iscsi-hairpin.md`

### Longer-Term Improvements

5. **Investigate microk8s hairpin NAT configuration** (Medium Priority)
   - Calico in microk8s may support hairpin NAT via `natOutgoing` or `IPIPMode` configuration changes
   - Enabling hairpin NAT would eliminate the failure mode entirely, removing the need for anti-affinity rules as a workaround
   - Validate on a test pod before applying to production

6. **Address k8s02 disk pressure** (High Priority — tracked separately)
   - `openebs-localpv-provisioner` (697 restarts), `snapshot-operator` (184 restarts), `provisioner` (110 restarts) all on k8s02
   - `ImageGCFailed` events active: kubelet cannot free space, GC finds 0 bytes eligible
   - Drain OpenEBS pods from k8s02 temporarily, prune container images manually
   - See: `memory/project_k8s02_disk.md`

7. **Review Jiva replica placement strategy** (Medium Priority)
   - Jiva controller pods have no affinity rules and can schedule to any node
   - If the controller and consumer always avoid the same node, the hairpin failure cannot occur even without application-level anti-affinity
   - Investigate adding node anti-affinity to OpenEBS Jiva controller deployments at the operator level

---

## Lessons Learned

### What Went Well

1. **Systematic elimination narrowed root cause efficiently**: Once the two initial false trails (stale fsck event, missing controller hypothesis) were eliminated with targeted kubectl checks and fsck confirmation, the correct cause was identified quickly
2. **fsck via debug pod preserved data integrity**: Running fsck offline via a privileged pod rather than attempting to work around a live mount protected against any risk of further filesystem damage
3. **Cordon/reschedule is a clean, reversible mitigation**: Cordoning k8s03 had zero impact on other workloads and was fully reversible — a low-risk intervention that immediately resolved the issue
4. **Zero data loss**: The filesystem was clean throughout; the entire incident was a network topology failure, not a storage failure
5. **All other media services unaffected**: The Jiva architecture's per-volume isolation meant the failure was contained to sonarr alone

### What Didn't Go Well

1. **Two misdiagnoses cost ~15 minutes**: The stale fsck event in pod describe output and the ambiguous iSCSI PDU error created two false trails before the node co-scheduling hypothesis was reached
2. **The ContainerCreating detection gap persists**: The 2026-02-22 Radarr PIR identified this as a Critical action item. It was not implemented, and this incident is a direct second consequence of that gap
3. **No anti-affinity rules on any Jiva-backed deployments**: A cluster-wide misconfiguration that was not identified or addressed after the previous Jiva incidents. All Jiva consumers have the same latent exposure
4. **The hairpin NAT failure mode is not documented anywhere in the cluster's runbooks**: Diagnosis required reasoning from first principles rather than matching against a known failure pattern
5. **k8s02 disk pressure pre-existing and unaddressed**: The restart storms on k8s02 added noise during investigation and represent ongoing storage risk

### Surprise Findings

1. **iSCSI PDU errors are indistinguishable across multiple failure modes**: A missing controller pod, a hung iSCSI target daemon, a network policy block, and a hairpin NAT failure all produce the same `Login I/O error, failed to receive a PDU` message. The only discriminating factor is node placement — which requires correlating pod node assignments across two different namespaces
2. **SuccessfulAttachVolume does not mean iSCSI will work**: The Kubernetes attach/detach controller operates at the API level (VolumeAttachment objects) and successfully records the attachment. The actual host-level iSCSI session is established later by kubelet, after the API-level attach — so a successful attach event does not guarantee a working mount
3. **The Jiva controller and its consumer can co-schedule without any warning**: There is no admission controller, scheduler plugin, or Jiva operator behaviour that warns when this happens. The failure is entirely silent until mount time
4. **fsck clean despite prior fsck errors in events**: The earlier `fsck found errors ... but could not correct them` events were from a previous, now-resolved failure mode. The current filesystem state was healthy. Event history in `kubectl describe` can reflect resolved issues and mislead current diagnosis

---

## Action Items

| Priority | Action | Owner | Due Date | Status |
| -------- | ------ | ----- | -------- | ------ |
| Critical | Add pod anti-affinity to sonarr deployment (ArgoCD) | pgmac | 2026-04-06 | Open |
| Critical | Alert: pod stuck in ContainerCreating > 5 minutes (**carry-over from 2026-02-22**) | pgmac | 2026-04-06 | Open |
| High | Add pod anti-affinity to radarr, readarr, overseerr, calibreweb deployments (ArgoCD) | pgmac | 2026-04-13 | Open |
| High | Write runbook: Jiva-backed pod ContainerCreating with iSCSI hairpin NAT | pgmac | 2026-04-13 | Open |
| High | Resolve k8s02 disk pressure (drain OpenEBS pods, prune images) | pgmac | 2026-04-06 | Open |
| Medium | Investigate microk8s/Calico hairpin NAT configuration options | pgmac | 2026-04-20 | Open |
| Medium | Review Jiva controller pod placement strategy (operator-level anti-affinity) | pgmac | 2026-04-20 | Open |

---

## Technical Details

### Environment

- **Cluster**: pvek8s (microk8s on 3 nodes: k8s01, k8s02, k8s03)
- **CNI**: Calico (microk8s default)
- **Storage**: OpenEBS Jiva (`openebs-jiva-default` storage class)
- **Affected PVC**: `sonarr-config` (pvc-17e6e808-a9fc-4f64-b490-71deffdb81fd), 1Gi RWO
- **iSCSI target**: ClusterIP `10.152.183.62:3260`
- **Jiva controller pod at incident**: `pvc-17e6e808-a9fc-4f64-b490-71deffdb81fd-ctrl-75854597dc-pr4kt` on k8s03

### Pod State at Detection

| Pod | Namespace | Node | Status |
| --- | --------- | ---- | ------ |
| `sonarr-dd4cb4f69-8kmhv` | media | k8s03 | ContainerCreating |
| `pvc-17e6e808-...-ctrl-75854597dc-pr4kt` | openebs | k8s03 | Running 2/2 |
| `pvc-17e6e808-...-rep-1-*` | openebs | k8s02 | Running 1/1 (6 restarts) |
| `pvc-17e6e808-...-rep-2-*` | openebs | k8s01 | Running 1/1 (0 restarts) |
| `pvc-17e6e808-...-rep-3-*` | openebs | k8s03 | Running 1/1 (3 restarts) |

### Key Error Events

**iSCSI hairpin failure (media namespace, pod events):**

```
Warning  FailedMount  kubelet  MountVolume.WaitForAttach failed for volume
"pvc-17e6e808-a9fc-4f64-b490-71deffdb81fd":
iscsi: failed to sendtargets to portal 10.152.183.62:3260
iscsiadm: Connection to Discovery Address 10.152.183.62 failed
iscsiadm: Login I/O error, failed to receive a PDU
```

**fsck (from earlier resolved failure — misleading):**

```
Warning  FailedMount  kubelet  MountVolume.WaitForAttach failed for volume
"pvc-17e6e808-a9fc-4f64-b490-71deffdb81fd":
fsck found errors on device /dev/disk/by-path/ip-10.152.183.62:3260-iscsi-iqn...pvc-17e6e808...-lun-0
but could not correct them
```

**Resolution confirmation (sonarr startup log):**

```
[Info] DatabaseService: Migrating main database to 216
[Info] Microsoft.Hosting.Lifetime: Now listening on: http://[::]:8989
[Info] Microsoft.Hosting.Lifetime: Application started.
```

### OpenEBS Health at Incident Time (k8s02 secondary issue)

| Component | Node | Restarts | Status |
| --------- | ---- | -------- | ------ |
| openebs-localpv-provisioner | k8s02 | 697 | Running (degraded) |
| openebs-snapshot-operator | k8s02 | 184 | Running (degraded) |
| openebs-provisioner | k8s02 | 110 | Running (degraded) |
| openebs-ndm-operator | k8s02 | 76 | Running (degraded) |
| openebs-apiserver | k8s01 | 77 | Running (degraded) |

---

## References

- Previous Radarr Jiva incident (replica divergence): `incidents/docs/incidents/2026-02-22-radarr-openebs-jiva-replica-divergence.md`
- Second Radarr Jiva incident: `incidents/docs/incidents/2026-03-28-radarr-jiva-replica-divergence-second.md`
- k8s02 disk pressure tracking: `memory/project_k8s02_disk.md`
- Linear ticket: [PGM-117](https://linear.app/pgmac-net-au/issue/PGM-117)
- microk8s Calico networking: https://microk8s.io/docs/addon-calico
- OpenEBS Jiva iSCSI documentation: https://openebs.io/docs/user-guides/jiva

---

## Reviewers

- **Prepared by**: Claude (AI Assistant)
- **Date**: 2026-03-30
- **Review Status**: Draft — Pending human review
