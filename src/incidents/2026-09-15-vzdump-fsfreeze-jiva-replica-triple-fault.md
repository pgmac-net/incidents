---
title: 2026-09-15 vzdump fs-freeze Jiva triple fault
date: 2026-09-15
severity: P2
resolution: Resolved
duration: ~23h 0m (~21:23 AEST 2026-09-15 → ~20:23 AEST 2026-09-16); ~17m active remediation
impact: >-
  survive-minecraft was down for 23 hours on a read-only PVC while three Jiva
  replicas across all three nodes crash-looped from three unrelated causes; two
  replica data directories (~83 GB of orphaned snapshot images) had to be wiped
  and resynced. No data was lost. Nagios alerted continuously for 23h; nobody acted.
tags:
  - k8s01
  - k8s02
  - k8s03
  - openebs
  - jiva
  - calico
  - cni
  - argocd
  - proxmox
  - crash-loop
  - storage
  - networking
---

# Post Incident Review: pvek8s Triple Replica Fault — Proxmox Backup fs-freeze, Corrupt Snapshot Chains, and an Orphaned Pod Route

## Executive Summary

Taking Proxmox `vzdump` snapshot backups of the three pvek8s node VMs while their workloads were running froze each node's filesystems through the QEMU guest agent. Because every Jiva replica, every Jiva controller and the dqlite datastore live on those same nodes, freezing one node stalled the replicas it hosted; the surviving controllers then missed the 5-second iSCSI ping deadline, initiators on the other nodes dropped their sessions, and ext4 aborted its journal and remounted read-only. That was the trigger. Three separate faults fell out of it, and the cluster stayed broken for 23 hours.

The first fault was the user-visible one: `minecraft/survive-minecraft` went into CrashLoopBackOff at 21:23 AEST on 2026-09-15 when its PVC `pvc-1908508d` remounted read-only, and it stayed there for 23 hours. The second and third were storage corruption: the data directories of `pvc-1908508d`'s replica on k8s03 and `pvc-4aea2a19`'s replica on k8s02 were left with an inconsistent snapshot chain — 14 and 13 orphaned `volume-snap-*.img` files respectively and no head image at all — which is the fourth and fifth occurrence of a failure mode first documented on 2026-07-13. The fourth was networking: the remaining replica of `pvc-1908508d` on k8s01 lost its Calico pod route during the same freeze window and every outbound connection to its controller's ClusterIP failed with `connect: network is unreachable`, leaving the volume with one usable replica and therefore read-only at the Jiva layer as well as the ext4 layer.

Recovery had to be ordered, because the wipe-and-rebuild procedure for a corrupt snapshot chain is only safe with at least two other replicas RW, and `pvc-1908508d` had one. Deleting the network-broken replica pod on k8s01 re-ran CNI, programmed a route, and brought the volume back to two RW; the corrupt replica on k8s03 was then wiped and resynced to three RW; the calibreweb replica on k8s02 was rebuilt in parallel, its own gate already satisfied. Restarting the minecraft pod at that point did **not** restore service — the replacement pod re-bound the stale read-only global mount before kubelet could unstage it, exactly as the `jiva-ctrl-eviction-iscsi-ro-filesystem` runbook predicts. Scaling the deployment to zero (with ArgoCD auto-sync temporarily disabled so it could not revert the scale-down), confirming the iSCSI session had logged out, then scaling back to one restored the service at 20:23 AEST.

Detection was not the problem. `microk8s-ro-pvc-mounts` had been CRITICAL on k8s01 for 23 hours and had sent 85 notifications to Slack and Zulip; `microk8s-jiva-pod-health` had been CRITICAL on all three nodes with a maximum crash-loop age of 1355 minutes; `microk8s-deployments` had flagged `survive-minecraft` as 0/1. Every one of those checks was added by an earlier PIR. The gap this time was that nothing acts on them: the read-only PVC failure mode has a documented recovery procedure and no auto-remediation, so the alert simply repeated for a day.

This incident is the storage-side consequence of the backups taken during [pgmac-net/homelabia#186](https://github.com/pgmac-net/homelabia/issues/186) (pve2's RAID5 returning an unrecoverable read error, which is why the backups were being taken at all). It also root-causes the previously open [pgmac-net/homelabia#173](https://github.com/pgmac-net/homelabia/issues/173).

---

## Timeline (AEST — UTC+10)

| Time | Event |
| --- | --- |
| **20:25 AEST 15 Sep** | `vzdump 102` (k8s02) starts with guest-agent `fs-freeze`. iSCSI `ping timeout of 5 secs expired` appears on all three nodes. |
| **20:30 AEST 15 Sep** | k8s02 backup aborts — `err -61 - No data available` (pve2 RAID unreadable sector, homelabia#186). `guest-fsfreeze-thaw failed - got wrong command id`; filesystems verified thawed afterwards. |
| **20:32–20:41 AEST 15 Sep** | k8s03 remounts `sdd` then `sdc` read-only (`EXT4-fs error ... Detected aborted journal`); k8s01 logs hung tasks then remounts `sdd` read-only. `readarr` and `tautulli` PVCs go read-only. |
| **~20:32 AEST 15 Sep** | `pvc-4aea2a19` replica data directory on k8s02 left with an inconsistent snapshot chain (`volume.meta` mtime 20:29). |
| **21:16 AEST 15 Sep** | `vzdump 100` (k8s01) starts with `fs-freeze`; `qemu-ga` and `rs:main` block for >120s. |
| **21:23 AEST 15 Sep** | k8s01 remounts `sdg` (`pvc-1908508d`) read-only. **`survive-minecraft` begins crash-looping — service down.** Calico CNI log on k8s01 records `CNI_CONTAINERID does not match WorkloadEndpoint ContainerID, don't delete WEP` in the same minute; `pvc-1908508d-...-jiva-rep-1` loses its pod route. |
| **~21:40 AEST 15 Sep** | `pvc-1908508d` replica on k8s03 enters its continuous crash loop (`volume.meta` mtime 20:38). Volume drops to 1 RW replica, `Syncing`/`RO`. |
| **22:09 AEST 15 Sep** | Wazuh-Server backup (no guest agent, no freeze) still drives k8s02 iSCSI `ping timeout` — backup read load alone is sufficient. pve2 `sda` await 0.3ms → 28–75ms. |
| **22:30 AEST 15 Sep** | `readarr` and `tautulli` recovered by plain pod delete (their volumes were 3/3 RW). `pvc-1908508d` left read-only; replica faults deferred. |
| **~21:28 AEST 15 Sep → 20:06 AEST 16 Sep** | Nagios CRITICAL throughout: `microk8s-ro-pvc-mounts` on k8s01 (85 notifications), `microk8s-jiva-pod-health` on all nodes, `microk8s-deployments` degraded. No action taken. |
| **20:06 AEST 16 Sep** | Incident opened ([pgmac-net/incidents#85](https://github.com/pgmac-net/incidents/issues/85)). minecraft pod at 265 restarts. |
| **20:07 AEST 16 Sep** | Nagios MCP returns `-32602` (stale SSE session); SSH + `docker exec nagios4` fallback used until the MCP was reconnected. |
| **20:08 AEST 16 Sep** | Three distinct faults identified and matched to runbooks. `ip route get 10.1.73.177` on k8s01 → `RTNETLINK answers: Invalid argument`. Wipe-and-rebuild gate (≥2 RW) forces the repair order. |
| **20:11 AEST 16 Sep** | rep-1 pod deleted; recreated with IP `10.1.73.187` and a programmed route (`dev cali6a36d11eb4d`). `pvc-1908508d` → `Ready`/`RW`, 2 replicas. |
| **20:12 AEST 16 Sep** | `pvc-4aea2a19` rep-2 wiped (13 orphaned images, no head image) and restarted; resyncs to 3/3. |
| **20:15 AEST 16 Sep** | `pvc-1908508d` rep-2 wiped on k8s03 (14 orphaned 5 GB images, no head image, ~70 GB freed) and restarted; volume reaches `3 Ready RW` within ~2 min. |
| **20:17 AEST 16 Sep** | `kubectl delete pod survive-minecraft-...` — **does not restore service**; replacement pod re-binds the stale `ro,relatime` mount. |
| **20:21 AEST 16 Sep** | ArgoCD auto-sync disabled on app `survive`; deployment scaled to 0; unreference verified (no mounts, `/dev/sdg` gone); scaled back to 1. |
| **20:23 AEST 16 Sep** | **Service restored.** Pod 1/1 Running, mount `rw,relatime`, chunk saves succeeding. ArgoCD auto-sync restored. |
| **20:28 AEST 16 Sep** | Verified by forced NRPE runs: jiva pod health OK, ro-pvc OK, 62/62 deployments healthy, k8s01 load normal. |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: survive-minecraft Down 23 Hours — Read-Only PVC With Detection But No Remediation

##### How did survive-minecraft stay in CrashLoopBackOff for 23 hours?

Its container could not write to `/data`: every start failed at `/data/.rcon-cli.env: Read-only file system`. The PVC `pvc-1908508d` was mounted `ro,relatime` on k8s01.

##### How did the mount become read-only?

At 21:23 AEST on 2026-09-15 the ext4 filesystem on `/dev/sdg` logged `ext4_journal_check_start:61: Detected aborted journal` and remounted read-only. The journal aborted because the underlying iSCSI session to the Jiva controller stopped responding: `connection16:0: ping timeout of 5 secs expired` followed by `detected conn error (1022)`.

##### How did the iSCSI session stop responding?

`vzdump` was backing up VM 100 (k8s01) in snapshot mode. The QEMU guest agent issued `fs-freeze`, which suspends **all** filesystems in the guest. The Jiva replicas running on that node store their data on the node's own root filesystem, so freezing it stalled every replica hosted there, and the controllers waiting on those replicas exceeded the 5-second iSCSI ping deadline.

##### How did a routine backup reach the storage path at all?

The cluster is hyperconverged on a single hypervisor: all three node VMs, all Jiva replicas, all Jiva controllers and dqlite run on pve2's one 4-spindle RAID5 array. A `replicationFactor: 3` volume has three copies that share one failure domain and one I/O queue, so any pve2-wide stall — a freeze, or merely backup read load, as the 22:09 Wazuh backup proved — hits every replica of every volume simultaneously.

##### How was a backup allowed to freeze a live storage node?

`fs-freeze` is Proxmox's default for snapshot-mode backups whenever a guest agent is present (`agent: 1`, set in `terraform-pgpve/vms.tf`). There is no per-VM `freeze-fs-on-backup=0`, no policy requiring k8s nodes to be cordoned and drained before a backup, and no documented safe procedure for backing up a hyperconverged node. The backups were run ad-hoc during homelabia#186 precisely because no scheduled backup job existed to have established a safe pattern.

##### How was the 23-hour outage not shortened by monitoring?

It was detected immediately and continuously. `microk8s-ro-pvc-mounts` went CRITICAL on k8s01 within minutes and sent 85 notifications to Slack and Zulip over 23 hours; `microk8s-deployments` reported `minecraft/survive-minecraft (0/1)`; `microk8s-jiva-pod-health` reported the crash loops on all three nodes. Every check fired correctly.

##### How did continuous CRITICAL alerts produce no action for 23 hours?

Read-only PVC mounts have a documented recovery procedure but **no auto-remediation**, unlike the watch-cache freeze and Jiva unpublish-wedge failure modes, which self-heal via Nagios event handlers. The alert therefore repeated unchanged for a day with no escalation past the normal notification channel, and the one human recipient was working a different incident (homelabia#186) at the time.

→ **Actionable root cause:** the read-only-PVC failure mode is detected but not remediated, and `vzdump` of a hyperconverged k8s node is unsafe by default with nothing preventing it.

---

#### Chain 2: Two Corrupt Snapshot Chains — Non-Atomic Metadata Under a Frozen Filesystem

##### How did two Jiva replicas crash-loop for a day?

`pvc-1908508d-...-jiva-rep-2` on k8s03 failed at `Can't remove head file volume-head-029.img as it contains some data`, and `pvc-4aea2a19-...-jiva-rep-2` on k8s02 at `Error link openebs/volume-head-021.img openebs/volume-snap-000.img: no such file or directory`. Both exited fatally on every start.

##### How did their data directories reach that state?

Each held a broken snapshot chain: k8s03 had 14 orphaned `volume-snap-*.img` files of 5 GB each and **no head image**; k8s02 had 13 orphaned images and no head image. `volume.meta` still referenced images that were absent or half-written, so the open-time chain walk failed.

##### How did the chain become inconsistent?

Jiva updates `volume.meta`, the `.img.meta` parent pointers and the image files themselves non-atomically. Both directories' `volume.meta` mtimes (20:29 and 20:38 on 2026-09-15) fall inside the backup window, so the freeze suspended writes partway through a snapshot-chain update and the replica was killed before it could complete.

##### How did a partial chain become permanent?

Jiva has no self-repair for a broken chain: the replica reads `volume.meta`, fails the open, the controller drops the connection, the process exits, and the pod restarts into exactly the same failure forever. Recovery requires a human to wipe the data directory so the replica rejoins in write-only mode and resyncs.

##### How was this not already prevented, given it has happened before?

This is the **fourth and fifth occurrence** of a failure mode first documented on 2026-07-13, recurring on 2026-09-05 ([homelabia#174](https://github.com/pgmac-net/homelabia/issues/174), now closed). Detection was added after the first occurrence and works. The recurrence driver — an ill-timed kill during a snapshot-chain update — was never addressed, and the follow-up issues that touched it (#137, #139, #140) were closed as their own narrower scopes.

→ **Actionable root cause:** recurring snapshot-chain corruption has detection and a recovery runbook but no prevention, and no owning issue tracks the recurrence itself.

---

#### Chain 3: Orphaned Pod Route — A Blackholed Replica Nobody Could See

##### How did `pvc-1908508d-...-jiva-rep-1` on k8s01 fail?

Every attempt to reach its controller's ClusterIP failed instantly: `Get "http://10.152.183.78:9501/v1/replicas": dial tcp 10.152.183.78:9501: connect: network is unreachable`, ending in `Retry count exceeded, Shutting down...`.

##### How did a pod on a healthy node fail to reach a healthy ClusterIP?

The Service had a valid endpoint (`10.1.236.150` on k8s02, controller 2/2 Running). The failure was node-local: `ip route get 10.1.73.177` on k8s01 returned `RTNETLINK answers: Invalid argument` — the kernel signature of a packet falling through to Calico's per-block blackhole route because the pod's own `/32` route was missing.

##### How did the per-pod route go missing?

Calico programs one host route per pod veth at sandbox creation. k8s01's CNI log recorded `CNI_CONTAINERID does not match WorkloadEndpoint ContainerID, don't delete WEP` at 2026-09-15 11:23 UTC — the same minute the node remounted `sdg` read-only under the backup freeze. The stalled node left CNI state and the WorkloadEndpoint out of step, and the pod ended up with neither a veth nor a route.

##### How did it stay broken for a day?

CNI programs the route only at **sandbox** creation. The container restarted 257 times inside the same sandbox, so every restart re-entered the same blackhole. Only pod deletion (a new sandbox) could fix it.

##### How was a blackholed pod not detected?

Nothing monitors for pod IPs that have no route on their own node. The pod reported `Running`/`0/1` and its node was Ready, so cluster-level checks saw nothing wrong; only the application log carried the signature. The symptom had already been reported once as [homelabia#173](https://github.com/pgmac-net/homelabia/issues/173) and remained open and un-root-caused.

##### How did the existing runbook not catch it?

`calico-orphaned-pod-route.md` tells the responder to compare per-node veth and route counts and treat a veth surplus as the orphan count. Here the counts matched exactly on every node (31/31, 37/37, 46/46) because the sandbox had no veth **either** — it contributed neither side of the comparison. A responder following the runbook's steps in order would have concluded there were no orphans.

→ **Actionable root cause:** no detection for blackholed pod IPs, and the runbook's primary diagnostic is a heuristic that reads clean in exactly this case.

---

## Impact

### Services Affected

| Service | Impact | Duration |
| --- | --- | --- |
| `minecraft/survive-minecraft` | Down — CrashLoopBackOff on a read-only PVC, 265 restarts | ~23h 0m |
| `media/calibreweb` | No outage; volume ran on 2/3 replicas | ~22h 35m degraded |
| `openebs` `pvc-1908508d` | `Syncing`/`RO`, 1 of 3 replicas usable | ~23h |
| `media/readarr`, `media/tautulli` | Read-only PVCs from the same trigger; recovered the previous night | ~2h each |

### Duration

- **Total incident window:** ~23h 0m (21:23 AEST 15 Sep → 20:23 AEST 16 Sep)
- **Active remediation:** ~17m (20:06 → 20:23 AEST 16 Sep)
- **Expected recovery time (with documented procedure, had it been actioned at detection):** ~20 min

### Scope

- Nodes affected: k8s01 (read-only PVC, orphaned route), k8s02 (corrupt replica), k8s03 (corrupt replica)
- Data loss: none. Both wiped replicas resynced from healthy peers; the minecraft world was intact and writable on recovery.
- User-visible impact: the minecraft server was unreachable for 23 hours. calibreweb was unaffected.
- Collateral: ~83 GB of orphaned snapshot images reclaimed (70 GB on k8s03, 13 GB on k8s02).

---

## Resolution Steps Taken

### Phase 1: Diagnosis

1. Confirmed scope with Nagios (MCP failed `-32602`; used `ssh macro 'docker exec nagios4 ...'` until reconnected).
2. Read all three replica logs and found **three different** error signatures, not one.
3. Confirmed the orphaned route with `ip route get 10.1.73.177` → `RTNETLINK answers: Invalid argument`, and confirmed the controller Service endpoint was healthy, ruling out a controller fault.
4. Checked the replica quorum for both volumes. `pvc-1908508d` had 1 RW — below the runbook's wipe gate — which fixed the repair order.

### Phase 2: Restore redundancy

1. Captured CNI evidence (`CNI_CONTAINERID does not match WorkloadEndpoint`) before mutating, since pod deletion destroys it.
2. Deleted the blackholed replica pod on k8s01; the new sandbox got IP `10.1.73.187` with a route on `cali6a36d11eb4d`. Volume returned to 2 RW.
3. Wiped and rebuilt `pvc-4aea2a19` rep-2 on k8s02 (gate verified: 2 RW) via a one-shot hostPath pod, then deleted the replica pod.
4. Wiped and rebuilt `pvc-1908508d` rep-2 on k8s03 once the gate was satisfied. Volume reached `3 Ready RW` in ~2 minutes.

### Phase 3: Restore service

1. `kubectl delete pod survive-minecraft-...` — failed to clear the read-only mount, as the runbook predicts.
2. Disabled ArgoCD auto-sync on app `survive` (`selfHeal: true` would revert a scale-down within ~40s).
3. Scaled the deployment to 0, verified full unreference (no `1908508d` in `/proc/mounts`, `/dev/sdg` absent → iSCSI session logged out), scaled back to 1.
4. Restored ArgoCD auto-sync; app returned `Synced`/`Healthy`.

---

## Verification

```bash
# Volume back to full redundancy
kubectl --context pvek8s get jivavolume -n openebs pvc-1908508d-948c-4320-b095-da8e3b4f2662
# → 3   Ready   RW

# Mount is writable again on the node
ssh k8s01 'awk "\$2 ~ /1908508d/ {print \$4}" /proc/mounts'
# → rw,relatime

# No crash-looping pods anywhere
kubectl --context pvek8s get pods -A --no-headers | grep -vE 'Running|Completed'
# → (empty)

# Confirm through the checks that raised the alarm, without waiting for the interval
ssh macro 'docker exec nagios4 /opt/nagios/libexec/check_nrpe -H k8s01 -c check_ro_pvc_mounts -t 30'
# → OK: no read-only PVC mounts | ro_pvcs=0;;1;0;
ssh macro 'docker exec nagios4 /opt/nagios/libexec/check_nrpe -H k8s01 -c check_jiva_pod_health -t 30'
# → OK - no openebs pods crash-looping or restarting in last 60 minutes
ssh macro 'docker exec nagios4 /opt/nagios/libexec/check_nrpe -H k8s02 -c check_k8s_deployments -t 30'
# → OK - All 62 deployment(s) healthy
```

---

## Preventive Measures

### Immediate Actions Required

1. **Make Proxmox backups of k8s node VMs safe by default** (High)
    - Chain 1. `fs-freeze` on a hyperconverged node stalls every Jiva replica it hosts; backup read load alone also caused iSCSI timeouts. Needs `freeze-fs-on-backup=0` (or a cordon-and-drain backup procedure) plus `--bwlimit` and an off-peak schedule.
    - Issue: [pgmac/terraform-pgpve#5](https://github.com/pgmac/terraform-pgpve/issues/5)

2. **Auto-remediate or escalate read-only PVC mounts** (High)
    - Chain 1. Detection is perfect and action was absent: 85 notifications over 23 hours. The watch-cache and Jiva unpublish failure modes already self-heal via Nagios event handlers; this one does not.
    - Issue: [pgmac-net/homelabia#188](https://github.com/pgmac-net/homelabia/issues/188)

3. **Add detection for blackholed pod IPs** (High)
    - Chain 3. A pod whose `/32` route is missing reports Running on a Ready node and fails only in its own logs. Root-causes the open homelabia#173.
    - Issue: [pgmac-net/homelabia#189](https://github.com/pgmac-net/homelabia/issues/189)

### Longer-Term Improvements

4. **Address recurring Jiva snapshot-chain corruption** (Medium)
    - Chain 2. Fifth occurrence. Detection and recovery exist; prevention does not, and no open issue owns the recurrence.
    - Issue: [pgmac-net/homelabia#190](https://github.com/pgmac-net/homelabia/issues/190)

5. **Fix the orphaned-pod-route runbook's primary diagnostic** (Medium)
    - Chain 3. The veth/route count heuristic reads clean when the sandbox has no veth. Addressed in this PR; issue tracks review.
    - Issue: [pgmac-net/incidents#86](https://github.com/pgmac-net/incidents/issues/86)

---

## Lessons Learned

### What Went Well

- Every relevant Nagios check fired correctly and identified the right objects; all three were added by earlier PIRs.
- The runbook's quorum gate (`≥2 RW before wiping a replica`) prevented a data-loss mistake and dictated a safe repair order that was not obvious from the symptoms.
- The `jiva-ctrl-eviction-iscsi-ro-filesystem` runbook correctly predicted that a plain pod delete would not clear the read-only mount, which saved a second round of guesswork.
- Evidence was captured before mutating, so the CNI log line that dates the route loss to the backup window survived the pod deletion that fixed it.
- Recovery was verified by forcing live NRPE runs rather than waiting out the check interval.

### What Didn't Go Well

- A 23-hour outage with continuous CRITICAL alerts and 85 notifications. Detection without remediation or escalation bought nothing here.
- The incident was self-inflicted: the backups that caused it were taken in response to another incident, without considering their effect on a hyperconverged cluster.
- Three faults sharing one trigger presented as one symptom; treating the crash loops as a single problem would have produced a wrong fix, and wiping the corrupt replica first would have risked the only surviving copy.
- The previous night's triage stopped at "pre-existing replica faults" for `pvc-1908508d` and deferred them, leaving the service down overnight.
- homelabia#173 had already reported chain 3's exact symptom and sat open and un-root-caused.

### Surprise Findings

- Backup **read load alone** — with no freeze at all, on a VM with no guest agent — was enough to cause iSCSI ping timeouts on a k8s node: pve2's average disk latency went from 0.3ms to 28–75ms.
- The runbook heuristic for orphaned pod routes fails precisely in the worst case: when the sandbox has no veth, veth and route counts match and the node looks clean.
- One wiped replica directory held 70 GB of orphaned snapshot images — the corruption was also a substantial silent disk-space leak on k8s03.
- `guest-fsfreeze-thaw failed - got wrong command id` was reported by vzdump while the guest had in fact thawed; the error is not a reliable indicator that filesystems are still frozen (verify with `qm guest cmd <vmid> fsfreeze-status`).

---

## Action Items

| # | Action | Priority | GitHub |
| --- | --- | --- | --- |
| 1 | Make Proxmox backups of k8s node VMs safe by default (no fs-freeze, bwlimit, off-peak) | High | [pgmac/terraform-pgpve#5](https://github.com/pgmac/terraform-pgpve/issues/5) |
| 2 | Auto-remediate or escalate read-only PVC mounts | High | [pgmac-net/homelabia#188](https://github.com/pgmac-net/homelabia/issues/188) |
| 3 | Add NRPE check: detect pod IPs with no route on their own node | High | [pgmac-net/homelabia#189](https://github.com/pgmac-net/homelabia/issues/189) |
| 4 | Prevent recurring Jiva snapshot-chain corruption (5th occurrence) | Medium | [pgmac-net/homelabia#190](https://github.com/pgmac-net/homelabia/issues/190) |
| 5 | Fix orphaned-pod-route runbook's primary diagnostic | Medium | [pgmac-net/incidents#86](https://github.com/pgmac-net/incidents/issues/86) |

---

## Technical Details

### Environment

- Cluster: pvek8s (microk8s), Kubernetes v1.35.0, containerd 2.1.3, Ubuntu 20.04.6, kernel 5.4
- Storage: OpenEBS Jiva 3.6.0 via `openebs-jiva-csi-default`, `replicationFactor: 3`, replicas on `openebs-hostpath` (`/var/openebs/local`)
- Hypervisor: pve2 (Proxmox 8.4.21), ProLiant DL380 G7, Smart Array P410i, 4× 300G SAS RAID5 — degraded, see homelabia#186
- All three node VMs run on that single array

### Key Error Signatures

```text
# Trigger — iSCSI session loss under guest fs-freeze
connection16:0: ping timeout of 5 secs expired, recv timeout 5, last rx ...
connection16:0: detected conn error (1022)
EXT4-fs error (device sdg): ext4_journal_check_start:61: Detected aborted journal
EXT4-fs (sdg): Remounting filesystem read-only

# Chain 2 — corrupt snapshot chain (two variants, same root cause)
Error Can't remove head file volume-head-029.img as it contains some data during open
Error link openebs/volume-head-021.img openebs/volume-snap-000.img: no such file or directory
Failed to handle connection, err: EOF, shutdown replica...

# Chain 3 — orphaned pod route
Failed to check replica state, err: Get "http://10.152.183.78:9501/v1/replicas":
  dial tcp 10.152.183.78:9501: connect: network is unreachable, will retry
Retry count exceeded, Shutting down...
# and on the node:
$ ip route get 10.1.73.177
RTNETLINK answers: Invalid argument

# Chain 1 — workload symptom
rm: cannot remove '/data/.rcon-cli.env': Read-only file system
```

### Discriminating Three Faults That Look Identical

```bash
# All three present as CrashLoopBackOff in the openebs namespace.
# The logs, not the pod status, tell them apart:
for p in $(kubectl --context pvek8s -n openebs get pods --no-headers \
           | awk '$3=="CrashLoopBackOff"{print $1}'); do
  echo "== $p"
  kubectl --context pvek8s -n openebs logs "$p" --previous --tail=5 | grep -iE 'error|fatal'
done

# Then, for any "network is unreachable", test the route on that pod's node:
IP=$(kubectl --context pvek8s -n openebs get pod <pod> -o jsonpath='{.status.podIP}')
ssh <node> "ip route get $IP"
# → RTNETLINK answers: Invalid argument   = orphaned route (delete the pod)
# → <ip> dev caliXXXX src <node-ip>       = route fine, look elsewhere
```

### Ordering Repairs by Quorum

```bash
# Never wipe a replica until at least two others are RW.
CTRL=$(kubectl --context pvek8s get pods -n openebs -o name | grep '<vol-id>.*ctrl' | head -1)
kubectl --context pvek8s exec -n openebs "${CTRL#pod/}" -c jiva-controller -- \
  curl -s http://localhost:9501/v1/replicas \
  | python3 -c 'import json,sys;[print(d["address"], d["mode"]) for d in json.load(sys.stdin)["data"]]'
# → need ≥2 RW lines before wiping the third
```

---

## References

- Incident tracking issue: [pgmac-net/incidents#85](https://github.com/pgmac-net/incidents/issues/85)
- GitHub Issue: [pgmac-net/homelabia#186](https://github.com/pgmac-net/homelabia/issues/186) — pve2 RAID5 unrecoverable read error; the reason the backups were being taken
- GitHub Issue: [pgmac-net/homelabia#173](https://github.com/pgmac-net/homelabia/issues/173) — "Jiva replica initiator pods report network unreachable to healthy jiva-ctrl ClusterIP", root-caused by Chain 3
- GitHub Issue: [pgmac-net/homelabia#187](https://github.com/pgmac-net/homelabia/issues/187) — pve2 physical disk and RAID health monitoring
- Runbook: [jiva-replica-corrupt-snapshot-chain.md](../runbooks/jiva-replica-corrupt-snapshot-chain.md) — updated by this incident with the head-file variant and the quorum-ordering rule
- Runbook: [calico-orphaned-pod-route.md](../runbooks/calico-orphaned-pod-route.md) — updated by this incident; route test promoted over the veth/route count heuristic
- Runbook: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md) — updated with the backup fs-freeze trigger
- Related incident: [pvek8s Read-Only Volume Cascade — dqlite Storm, iSCSI Starvation, and a 17-Hour Action Gap](2026-08-06-dqlite-storm-iscsi-ro-volumes-detection-gap.md) — same read-only cascade, different trigger, same action gap
- Related incident: [pvek8s Storage Cascade — ArgoCD Sync Burst, Watch-Cache Freeze, and jiva iSCSI Read-Only Volumes](2026-07-13-argocd-sync-burst-watch-cache-freeze-jiva-ro.md) — first occurrence of the corrupt snapshot chain

---

## Reviewers

- @pgmac
