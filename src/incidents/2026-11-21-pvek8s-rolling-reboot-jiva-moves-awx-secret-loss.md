---
title: 2026-11-21 pvek8s rolling reboot
date: 2026-11-21
severity: P3
services: [cluster-control-plane, cluster-storage, deployment]
resolution: Resolved
duration: ~7h 15m active (06:37 → 13:52 AEST); reboot-required alert fired ~4h 20m earlier (02:18 AEST)
impact: >-
  Planned rolling kernel reboot of all three pvek8s nodes. Ten Jiva-backed apps were stopped for
  ~4h 50m for stop-first controller moves, AWX was down for ~2h 40m because its database secret was
  missing, and ingress, metallb and the control plane were briefly degraded. No data loss; all 11
  Jiva volumes finished 3/3 RW.
tags:
  - k8s01
  - k8s02
  - k8s03
  - reboot
  - maintenance
  - jiva
  - openebs
  - dqlite
  - kine
  - containerd
  - calico
  - argocd
  - awx
  - sealed-secrets
  - storage
  - scheduling
  - sre-harness
---

# Post Incident Review: pvek8s Rolling Kernel Reboot — Jiva Stop-First Moves, Post-Reboot Stale Sandboxes and AWX Credential Loss

## Executive Summary

At 02:18 AEST on 2026-11-21 Nagios reported `reboot-required` older than 24 hours on k8s01, k8s02 and k8s03: kernel updates were installed and inactive. Nothing was user-visible, and unattended triage rated it P4. A person promoted it to an incident at 06:40 because the maintenance it required was expected to expose problems. It did. The incident was graded P3 at the end because the maintenance caused deliberate outages of ten apps, an unplanned AWX outage and brief control-plane and ingress degradation. There was no data loss.

Three independent chains made a one-hour-per-node job take about seven hours. First, the Jiva iSCSI controllers cannot be moved under a live consumer without risking read-only filesystems, so each of the 11 controllers (all on k8s03 by the time it mattered) was moved by hand, stop-first, one volume at a time. The moves hit a corrupt snapshot chain, two replica-registration wedges and a zombie replica, all documented failure modes that were recovered by runbook. Second, after each reboot containerd and kubelet disagreed about sandbox state (calico-node looped on k8s01, ingress and metallb failed on k8s02 and k8s03), and every leadership change produced a dqlite and kine write storm; the reboot playbook's gates blocked the k8s03 reboot twice, correctly but expensively. Third, the awx-operator re-rendered AWX's database credentials when the pods around k8s02 restarted, found no `postgres-configuration-secret` in `ci`, fell back to a host that does not exist and left AWX down. Why the secret was missing is not established; it reappeared when the sealed-secrets controller rescheduled during the k8s03 reboot, and AWX recovered on its original ReplicaSets once the database password matched it.

Order of recovery: k8s01 rebooted first, its calico-node sandbox loop fixed by a cordon and kubelite restart; the 11 Jiva consumers were stopped under an ArgoCD deny window and the controllers moved to k8s01; k8s02 was rebooted before k8s03 because its stale containerd state kept producing zombie replicas; k8s03 rebooted on the third attempt after AWX was paused and dqlite quietened; AWX, the stale ArgoCD health view and a six-month-old duplicate AWX mesh ingress were cleaned up last. This follows the 2026-06-05 kernel-reboot cascade (P1) and the 2026-09-16 shuffle cascade, whose procedures (rolling order, `k8s_reboot_skip_jiva_shuffle=true`, stop-first) are what kept this incident at P3.

---

## Timeline (AEST — UTC+10)

| Time | Event |
| ---- | ----- |
| **~02:10 (11-20)** | `/var/run/reboot-required` created on all three nodes (automatic package upgrade) |
| **02:18** | Detected: Nagios `reboot-required` crossed 86400 s on k8s01/k8s02/k8s03. Triage opens catalog-70 (P4) |
| **06:37** | Responder joins; confirms kernel updates need a reboot. Order recommended: k8s01, k8s02, k8s03 |
| **06:40** | Promoted to incidents-106 |
| **06:41** | dqlite leader query returns k8s02; kcm and scheduler leases are on k8s03. Order revised to k8s01 → k8s03 → k8s02 |
| **06:45** | Jiva placement: 10 controllers on k8s03, 1 (readarr) on k8s01, none on k8s02. Runbook says skip the Jiva shuffle on a 3-node cluster |
| **~06:57** | readarr scaled to 0 (stop-first for k8s01's one controller) |
| **~06:58–06:59** | **k8s01 rebooted** (Nagios host DOWN→UP ~1 min). dqlite member leaves and rejoins |
| **07:03–07:10** | Post-reboot on k8s01: containerd sandbox-name reservations (jiva-csi-node, metallb speaker, alloy, ingress-nginx); calico-node enters a SandboxChanged loop (16 in 3 min, later 38 restarts) |
| **07:12** | `crictl rmp` of the dead calico sandbox: no effect; the kubelet keeps killing the working sandbox |
| **07:15** | k8s02 kubelite journal shows one `database is locked`/`kine.sock` burst tied to k8s01 rejoining; storm has tailed off, so the kubelite-restart precondition is met |
| **07:16** | On k8s01: cordon, `snap restart microk8s.daemon-kubelite` |
| **07:17** | calico-node `1/1 Running`, first Ready since the reboot |
| **07:17–07:19** | k8s02 `jiva-unpublish-wedge` (orphan readarr mount) clears by auto-remediation; k8s01 uncordoned. **Step 1 of 3 done** |
| **07:26** | ArgoCD deny sync window set on project `default` (4 h; later 8 h) |
| **07:47** | k8s02 and k8s03 cordoned; stop-first begins on k8s03's 11 Jiva volumes |
| **~07:57** | 9 consumers at 0 (radarr stopped later, by 08:12); 3 orphan mounts on k8s02 |
| **08:07** | `jiva-unpublish-wedge` HARD WARNING; auto-remediation unmounts all 3 at ~08:12 |
| **08:23** | First controller moved (sabnzbd). At 08:36 its rep-1 on k8s02 is in CrashLoopBackOff: **corrupt snapshot chain** |
| **08:39** | rep-1 backing directory wiped after the quorum gate (2 RW) confirmed; rebuilt from peers, 3/3 RW by 08:57 |
| **08:37–08:57** | survive-minecraft (clean), calibreweb (serialised WO rebuild, normal), sabnzbd moved |
| **09:02–09:12** | sonarr moved (first delete had not run); 3/3 RW in ~6 min, vs ~19 min on 2026-09-19 |
| **09:14–09:32** | hass moved: `/v1/replicas` hangs, **registration wedge** with a zombie rep-1 on k8s02. Recovered by parking rep-1 and restarting the controller |
| **09:40–09:43** | seerr moved: rep-2 on k8s02 is a zombie in a stale sandbox with no network |
| **09:45** | Reboot order changed to k8s01 → **k8s02** → k8s03: k8s02's containerd/kubelet state is the common factor |
| **09:49–10:17** | coder workspace, tautulli, radarr (second wedge, parked and restarted), readarr and borked-craft moved. All 11 controllers on k8s01 |
| **10:20** | Pre-reboot check: every volume RW on its k8s01 and k8s03 copies; hass and radarr k8s02 replicas parked |
| **~10:22** | **k8s02 reboot started**. k8s03 uncordoned (playbook refuses to run with a cordoned peer) |
| **~10:28–10:35** | k8s02 back. dqlite leadership moves to k8s03; cluster-wide lock storm (k8s03 25 context-cancelled, k8s01 25 locks); ingress-nginx on k8s02 `CreateContainerError`; k8s01 root disk 14–15% free |
| **~10:34** | awx-operator reconciles after being rescheduled: re-renders `pgawx-app-credentials`; new pgawx-web crash-loops, new pgawx-task waits on migrations. **AWX down** |
| **10:42** | dqlite-lock and kine OK on all nodes |
| **10:54** | Decision: k8s03 reboot gate GO |
| **~10:57** | k8s03 reboot started |
| **11:05** | **Attempt 1 aborted**: playbook pre-flight "stuck Pending pods" (pgawx-task, 31 min Pending) |
| **11:15–11:23** | AWX narrowed: `awx-manage showmigrations` fails `Name or service not known`; `postgres-configuration-secret` absent in `ci` |
| **11:25** | AWX operator, task and web scaled to 0. **Attempt 2 aborted**: dqlite lock gate (4/1/8 in 10 min) |
| **11:38–11:40** | dqlite quiet (0 locks on all nodes); attempt 3 started |
| **~11:46** | **k8s03 rebooted**. Leaders: dqlite k8s01, kcm k8s02, scheduler k8s01. metallb speaker (port 7946 in use) and ingress-nginx (no network) crash-loop on k8s03 |
| **12:23** | k8s03 crash-loops cleared by themselves (~35 min). dqlite and kine OK on all nodes |
| **12:25** | ansible#374 opened: automate the Jiva controller relocation |
| **12:47** | All ten stopped apps scaled back to 1/1 |
| **12:48–13:08** | AWX: chart references a secret it does not create; the secret in git is a SealedSecret. A copy of `postgres-configuration-secret` is found re-created ~82 min earlier; the DB role's password is set to match |
| **13:09–13:16** | awx-operator scaled to 1; pgawx-task and pgawx-web return on their **original** ReplicaSets. **AWX recovered** |
| **13:19** | ArgoCD deny window removed; AWX chart update (3.2.0 → 3.2.1) synced; DB password stored in Bitwarden |
| **13:22–13:25** | pgk8s#1162 opened and merged: removes the AWXMeshIngress that has clashed with `pgawx-ingress` since 2026-05-15 |
| **13:26–13:49** | 4 ArgoCD apps stuck `Progressing` with fully available Deployments; hard refresh clears them. 47/47 Synced and Healthy |
| **13:52** | Severity revised P4 → P3. Incident resolved |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: Ten apps stopped for ~4h 50m — Jiva controllers cannot be moved live

##### How did ten apps go down for most of a morning for a kernel reboot?

Each app's Jiva controller (the iSCSI target) was on k8s03, and the apps had to be scaled to 0 and the controllers moved to k8s01 one at a time before k8s03 could be rebooted. Consumers were stopped at ~07:47–08:12 AEST and scaled back at 12:47.

##### How did the controllers have to be moved with the apps stopped?

If a controller is evicted while a consumer holds an iSCSI session, the session drops, SCSI goes offline and ext4 remounts read-only. The runbook ([jiva-ctrl-node-rolling-restart](../runbooks/jiva-ctrl-node-rolling-restart.md)) therefore prescribes stop-first for a node with many controllers, and `k8s_reboot_skip_jiva_shuffle=true` because the automated shuffle caused the 2026-09-16 cascade.

##### How did all 11 controllers end up on one node?

They were placed by the scheduler, apparently with no spread constraint (inferred; the controller Deployments were not inspected). k8s02 hosts none; k8s01's readarr controller moved to k8s03 when k8s01 rebooted, leaving all 11 on k8s03. A reboot of any node that happens to hold them is a manual, hours-long operation.

##### How did the manual moves themselves go wrong?

Moving a controller restarts its three replicas, and four known failure modes were hit: a corrupt snapshot chain (sabnzbd rep-1 on k8s02, `no such file or directory` on `volume-snap-000.img`), a replica-registration wedge from a zombie replica in a stale sandbox (hass, radarr), a zombie rep-2 (seerr) and orphan unpublish mounts (readarr, then calibreweb/borked-craft/sabnzbd on k8s02). Each had a runbook, so each was recovered in minutes; the cost was the diagnosis time between moves. Most failures landed on k8s02, whose containerd state was stale.

##### How did a deliberate trade-off of the storage design persist without automation?

Jiva's controller is a single iSCSI target per volume and cannot be live-migrated; this is a known architectural limitation of the storage engine in use. The procedure to work around it was proven by hand on 2026-09-19 and again today, but exists only as a runbook. Eight distinct failure modes were met and handled by a person typing commands, one of them a controller delete that silently did not run because the pod name contained a glob.

##### How was this not prevented?

There is no automation of the relocation with wedge/corruption detection and safety gates (never below 2 RW, one volume at a time). That gap is the actionable root cause: [pgmac-net/ansible#374](https://github.com/pgmac-net/ansible/issues/374), opened during the incident. A controller spread constraint or a different storage engine are longer-term options.

---

#### Chain 2: k8s03 reboot took three attempts — post-reboot stale sandboxes and dqlite storms

##### How did the k8s03 reboot take three attempts and five hours from the first reboot to the last?

The playbook's pre-flights aborted attempt 1 (stuck Pending pod, 11:05) and attempt 2 (`database is locked` counts, 11:25). Both gates are deliberate protections (PGM-238, dqlite-write-contention runbook) and both were right to stop a reboot into an unstable control plane, but each cost 15–30 minutes.

##### How did the control plane stay noisy enough to trip the gates?

Every reboot moved a leader. k8s01's reboot made a dqlite member leave and rejoin (16 kine failures in 10 min); k8s02's reboot moved dqlite leadership to k8s03 and produced a cluster-wide storm (k8s03 25 context-cancelled, k8s01 56 kine reconnect failures in 10 min) that took ~15 minutes to subside. Our own scale-downs and the 5-minute heartbeat CronJob added lock errors in the gate's 10-minute window (4/1/8), which is stricter than the Nagios threshold (5).

##### How did stale sandboxes make it worse?

After every reboot containerd held sandbox names that the kubelet no longer tracked: k8s01's calico-node looped through 38 restarts in a SandboxChanged cycle that `crictl rmp` did not break and only a cordon plus kubelite restart did; k8s02's ingress-nginx hit `CreateContainerError` and its Jiva replicas became zombies; k8s03's metallb speaker failed with `bind: address already in use` on 7946 and ingress-nginx had no network (both cleared in ~35 min unaided). This is the RC-3 containerd name-reservation pattern from the 2026-06-05 PIR recurring on all three nodes.

##### How did the same pattern recur after a documented drain procedure?

The June procedure drains pods with `crictl stopp`/`rmp` before reboot, yet stale names persisted. It was not established in the incident whether the drain ran in the playbook or whether the reservations are created at boot. The fix (kubelite restart) works but is manual, and the gate that waits for it is a person watching `microk8s-sandbox-changed`.

##### How did the playbook and the stop-first procedure conflict?

`k8s-reboot.yml` refuses to run while a peer is cordoned, but stop-first needs peers cordoned so moved controllers land on k8s01. k8s03 was uncordoned before the k8s02 reboot, so evicted pods could land on the node that rebooted next. The stuck-Pending gate also cannot tell a harmless AWX pod from a kubelet stall.

##### How was this not detected or documented earlier?

There was no runbook for a rolling reboot (triage noted the gap at 02:19), the `kine-reconnect-failures` alert had no runbook and went CRITICAL after every event, and the Nagios `microk8s-cluster-status` check reports a deliberate cordon as lost nodes (`Nodes: 1/3 Ready`). Actions: a rolling-reboot runbook (created, below), post-reboot sandbox gate/fix, playbook gate alignment, and a kine-reconnect runbook.

---

#### Chain 3: AWX down for ~2h 40m — operator re-rendered credentials without its database secret

##### How did AWX go down at ~10:34?

The awx-operator pod, moved to k8s01 by the k8s02 drain, reconciled and rolled new ReplicaSets (`pgawx-task` 648667b5c9, `pgawx-web` 6f448cdc65). The new web pod crash-looped and the new task pod sat in `wait-for-migrations` (Attempt 66 by 11:06) while the old task pod, still running, was replaced by one with the same fault.

##### How did the new pods not reach the database?

`awx-manage showmigrations` inside the init container fails with `[Errno -2] Name or service not known`: the database host does not resolve. DNS is healthy (CoreDNS 2/2; `kubernetes.default` and `macro.int.pgmac.net` resolve from the same pod). The host is not the AWX database.

##### How did the pods get a host that does not exist?

The AWX CR names `postgres-configuration-secret`, which did not exist in `ci`. With no secret the operator re-rendered `pgawx-app-credentials` with its default managed-postgres host, changing the pod template checksum. This is a medium-confidence inference that fits every observation: when the secret returned, the operator rendered the **original** ReplicaSet hashes (6c74544bfd, 6d67d5c4bc), which would not happen if credentials had come from anywhere else.

##### How did the operator then fail to recover on its own?

It runs its migration check by exec into the pgawx-web container, which was in CrashLoopBackOff, so the reconcile failed every cycle (`container not found (pgawx-web)`, AWX status `Failure` since 10:34) and never migrated or marked done. The failure mode is self-sustaining.

##### How did the secret go missing?

Not established. The Secret reappeared ~82 minutes before 13:05 (around the k8s03 reboot at ~11:45) when the sealed-secrets controller, previously on k8s03, was rescheduled; the SealedSecret is in git (`templates/awx-postgres-sealed-secret.yaml`) and was probably re-unsealed on restart. Why it was absent beforehand (pruned, never unsealed, deleted) is open. The old pods worked until now because they held connections established before the loss.

##### How was this not detected?

Nothing checks that a Secret referenced by the AWX CR (or a SealedSecret's target) exists. The chart also manages a placeholder `pgawx-postgres-configuration` (type `unmanaged`, host and database `Unset`), so a second, wrong secret looked plausible. The real DB password was in neither Bitwarden nor the Ansible vault, so a password rotation was planned before the secret was found intact. A latent, unrelated fault was cleaned up at the same time: the AWXMeshIngress had clashed with `pgawx-ingress` on `awx.int.pgmac.net` since 2026-05-15 (removed by pgk8s#1162). Actions: find the cause of the missing Secret, alert on SealedSecrets without Secrets, fix the chart placeholder.

---

## Impact

### Services Affected

| Service | Impact | Duration |
| ------- | ------ | -------- |
| sabnzbd, survive-minecraft, calibreweb, sonarr, hass, seerr, tautulli, radarr, borked-craft, readarr | Deliberately stopped (scaled to 0) for stop-first controller moves | ~07:47–08:12 → 12:47 AEST (~4h 35m–5h; per app shorter) |
| readarr | Stopped before the k8s01 reboot, ahead of the other nine | from ~06:57 AEST |
| AWX (web/task, ci) | Down: operator re-rendered credentials, no DB connection | ~10:34 → 13:16 AEST (~2h 40m) |
| ingress-nginx | Controller on k8s01 and k8s02 briefly in ContainerCreating / CreateContainerError; k8s03 crash-looped; ran on 2 of 3 | minutes per node; ~35 min on k8s03 |
| metallb | k8s03 speaker crash-looped; L2 announcements failed over to k8s01/k8s02 | ~35 min |
| dqlite / kine control plane | Write storms after each leadership move; `database is locked`, kine reconnect failures | ~15 min after each of k8s01, k8s02, k8s03 reboots |
| ArgoCD | Self-heal blocked by deny window (intended); 4 apps stale `Progressing` | 06:30 → 13:19 (window); ~1h 45m (stale health) |
| Jiva volumes | One replica wiped and rebuilt (sabnzbd rep-1); two volumes ran on 2/3 replicas for a period | no data loss |

### Duration

- **Detection to responder:** ~4h 20m (02:18 → 06:37 AEST), which is expected for a P4 `reboot-required` alert overnight.
- **Active incident window:** ~7h 15m (06:37 → 13:52 AEST).
- **Expected time with automation:** not measured. Stop-first costs ~4 min per volume per the runbook, so the 11 moves alone are ~45 min before gates and failure handling.

### Scope

- All three nodes (k8s01, k8s02, k8s03) rebooted onto the new kernel.
- **Data loss:** none. All 11 Jiva volumes ended 3/3 RW. One replica (sabnzbd rep-1) was wiped on purpose and rebuilt from two healthy peers.
- **User-visible impact:** the ten stopped apps (media, Minecraft, Home Assistant, Coder workspace) and AWX. Home Assistant recorder staleness alerted UNKNOWN while hass was at 0.
- **Not affected:** DNS, the apps not on Jiva, NFS (`hal`), and the pve2 RAID (WARNING throughout, pre-existing, acknowledged).

---

## Resolution Steps Taken

### Phase 1: k8s01 reboot and post-reboot fix (06:37 → 07:19)

1. Triage found no runbook for a rolling reboot; the 2026-06-05 PIR procedure and `k8s-reboot.yml` (PGM-226) were used. Leaders located (dqlite k8s02; kcm/scheduler k8s03) and order set k8s01 → k8s03 → k8s02.
2. readarr scaled to 0; k8s01 rebooted via the playbook with the Jiva shuffle off.
3. k8s01 calico-node loop: `crictl rmp` on the dead sandbox did not help; after the dqlite storm tailed off, `cordon` + `snap restart microk8s.daemon-kubelite`; calico-node Ready, node uncordoned.

### Phase 2: stop-first on k8s03 (07:26 → 12:47)

1. ArgoCD deny sync window added on project `default` so `selfHeal` could not re-scale stopped apps.
2. k8s02 and k8s03 cordoned. Consumers scaled to 0 one at a time; orphan mounts on k8s02 cleared by auto-remediation.
3. Controllers moved one at a time by deleting the exact controller pod, verifying with the controller API: `/v1/volumes` 200 and `/v1/replicas` listing 3 `RW` matching pod IPs.
4. Recoveries applied: corrupt chain → quorum gate (2 RW), then wipe the replica's backing directory; registration wedge → park the replica on the cordoned node, restart the controller; serialised WO rebuild → wait.
5. All consumers scaled back at 12:47 once the k8s03 reboot was done.

### Phase 3: k8s02 and k8s03 reboots (10:22 → 11:46)

1. k8s03 uncordoned (playbook requirement), then k8s02 rebooted; waited for the dqlite storm to subside.
2. k8s03 reboot gate assessed GO at 10:54 and started; attempt 1 aborted (stuck Pending AWX pod); AWX scaled to 0 (operator, task, web); attempt 2 aborted (dqlite locks); attempt 3 after a 0-lock window succeeded.

### Phase 4: AWX and cleanup (11:15 → 13:49)

1. AWX diagnosed read-only: operator log (`container not found (pgawx-web)`), `showmigrations` DNS error, `postgres-configuration-secret` absent.
2. Secret found re-created; DB role password set to match; operator scaled to 1; AWX back on original ReplicaSets at 13:16.
3. Deny window removed; AWX chart synced; DB password stored in Bitwarden; mesh ingress clash removed by pgk8s#1162.
4. Four stale-Progressing ArgoCD apps hard-refreshed.

---

## Verification

```bash
kubectl --context pvek8s get nodes
# → k8s01, k8s02, k8s03 all Ready, none cordoned; new kernel active

# Nagios: reboot-required OK on all three nodes
# Nagios: microk8s-dqlite-lock / microk8s-kine / kine-reconnect-failures OK on all three

kubectl --context pvek8s get pods -A | grep -v Running | grep -v Completed
# → (empty — no Pending pods)

# Each Jiva controller: /v1/replicas answers immediately with 3 RW, addresses matching pod IPs
# → 11 of 11 volumes 3/3 RW

# ArgoCD
# → 47 of 47 Applications Synced and Healthy; no AWXMeshIngress or pgawx-ingress-mesh in ci
# Nagios microk8s-deployments: all 63 deployments healthy
```

---

## Preventive Measures

### Immediate Actions Required

1. **Find why `postgres-configuration-secret` was missing and guarantee it is unsealed** (High) — Chain 3. The Secret was absent for an unknown period and AWX was only exposed when its operator reconciled.
    - Issue: [pgmac-net/pgk8s#1163](https://github.com/pgmac-net/pgk8s/issues/1163)
2. **Post-reboot containerd stale sandbox gate and fix** (High) — Chain 2. Recurred on all three nodes; the kubelite-restart fix is manual.
    - Issue: [pgmac-net/homelabia#283](https://github.com/pgmac-net/homelabia/issues/283)
3. **AWX: fail loudly on a missing DB secret and remove the placeholder secret** (Medium) — Chain 3.
    - Issue: [pgmac-net/pgk8s#1164](https://github.com/pgmac-net/pgk8s/issues/1164)
4. **`k8s-reboot.yml` pre-flight gates conflict with stop-first** (Medium) — Chain 2.
    - Issue: [pgmac-net/ansible#375](https://github.com/pgmac-net/ansible/issues/375)
5. **Runbook for `microk8s-kine-reconnect-failures`** (Medium) — Chain 2.
    - Issue: [pgmac-net/incidents#107](https://github.com/pgmac-net/incidents/issues/107)

### Longer-Term Improvements

6. **Automate the Jiva controller relocation (stop-first) with wedge and corruption detection** (High) — Chain 1. Opened during the incident with the eight failure modes and acceptance criteria.
    - Issue: [pgmac-net/ansible#374](https://github.com/pgmac-net/ansible/issues/374)
7. **Catalog: AWX, sealed-secrets and Jiva consumers belong to no service; AWX → external PostgreSQL dependency** (Medium) — catalog finding.
    - Issue: [pgmac-net/sre-catalog#71](https://github.com/pgmac-net/sre-catalog/issues/71)
8. **`microk8s-cluster-status` counts a cordoned node as not Ready** (Low) — Chain 2.
    - Issue: [pgmac-net/nagios-config#72](https://github.com/pgmac-net/nagios-config/issues/72)
9. **ArgoCD apps stuck Progressing after application-controller restart** (Low) — Chain 2.
    - Issue: [pgmac-net/homelabia#285](https://github.com/pgmac-net/homelabia/issues/285)
10. **Harness user cannot ssh to k8s02** (Low) — diagnosis gap.
    - Issue: [pgmac-net/homelabia#284](https://github.com/pgmac-net/homelabia/issues/284)
11. **Investigate macro heat (HDD 52C) and iowait** (Low) — observation, not a chain.
    - Issue: [pgmac-net/homelabia#286](https://github.com/pgmac-net/homelabia/issues/286)

### Runbook decisions

| Chain | Decision | Reason |
| ----- | -------- | ------ |
| 1 — Jiva controller moves | **Skip** (no new runbook) | Covered by [jiva-ctrl-node-rolling-restart](../runbooks/jiva-ctrl-node-rolling-restart.md), [replica-registration-wedge](../runbooks/jiva-ctrl-replica-registration-wedge.md), [corrupt-snapshot-chain](../runbooks/jiva-replica-corrupt-snapshot-chain.md) and [stale-node-attachment](../runbooks/jiva-csi-stale-node-attachment.md). Every failure was recovered by them; the gap is automation (ansible#374) |
| 2 — Post-reboot instability | **Create** [Rolling Kernel Reboot of pvek8s](../runbooks/k8s-rolling-reboot.md) | No runbook covered the reboot as a whole: leader-aware order, ArgoCD deny window, gates between nodes, the playbook's flags, and the sandbox-loop fix |
| 3 — AWX credential loss | **Skip** | The cause of the missing Secret is not established and recovery depended on the DB password not being stored. A runbook would be speculative until pgk8s#1163 completes |

---

## Lessons Learned

### What Went Well

- **The June and September procedures held.** Rolling order, `k8s_reboot_skip_jiva_shuffle=true` and stop-first produced no read-only volumes, no lost data and no P1.
- **Leader-first thinking.** Finding the dqlite leader (k8s02) and the kcm/scheduler leases (k8s03) before choosing the order, and changing the order twice on evidence, kept each leadership move to a node that had been rebooted recently.
- **Runbooks worked.** The corrupt-chain wipe, the registration-wedge park-and-restart and the unpublish auto-remediation each recovered in minutes; the quorum gate (2 RW) was checked before the one destructive step.
- **The playbook's pre-flights stopped two bad reboots.** Both aborts were correct: AWX was genuinely unhealthy and dqlite was genuinely contended.
- **`microk8s-sandbox-changed` and `jiva-unpublish-wedge` detected the right things on time** (the check from PGM-226 flagged the k8s01 calico loop at 07:13).
- **Stop-first on the second visit was faster:** sonarr re-synced in ~6 min versus ~19 min on 2026-09-19.

### What Didn't Go Well

- **A one-hour-per-node reboot took ~7 hours** because there is no automation for controller relocation, and the same eight failure modes are still discovered by a person on every attempt.
- **The playbook gates fight the stop-first workflow** (peer-cordon, stuck-Pending, dqlite window), costing two aborted attempts and an uncordon that let evicted pods land on the next node to reboot.
- **A controller delete with a `*jiva-ctrl*` glob silently did nothing** (sonarr, 09:02). The harness confirmed the old pod was still running only because it checked.
- **AWX was a surprise.** An unrelated latent fault surfaced because the reboot happened to reschedule the operator, and the credential needed to repair it was in no password store.
- **The alert noise obscured real faults.** Dozens of alert transitions (restart counts, `kine-reconnect-failures`, `Nodes: 1/3 Ready`, `Pending images`) each needed a decision on whether it was expected.
- **k8s02 is not reachable for the harness over ssh**, so the node with the most problems was read from pasted logs.

### Surprise Findings

- **Reboot order was not what the leaders suggested.** k8s02 held dqlite, k8s03 held the controllers and the other two leases; the right order changed three times as evidence arrived, ending k8s01 → k8s02 → k8s03.
- **Removing the dead sandbox with `crictl rmp` did not break the calico-node loop;** the kubelet's own pod state was wrong and only a kubelite restart fixed it.
- **The AWX mesh ingress had never worked** (duplicate host since 2026-05-15) and nobody knew.
- **A Secret can vanish and reappear:** sealed-secrets re-unsealing on a reschedule is the best explanation, but it means the Secret's absence is invisible until something reconciles.
- **ArgoCD's health view went stale for ~1h 45m** after an application-controller restart, though every Deployment was fully available.
- **Not investigated:** macro's HDD at 52C and 20% free root partition (observed 13:49); pve2 RAID uncorrected errors growing ~5 a day (pre-existing, acknowledged).

---

## Action Items

| #   | Action | Priority | GitHub |
| --- | ------ | -------- | ------ |
| 1   | Find why postgres-configuration-secret was missing in `ci`; guarantee it is unsealed | High | [pgmac-net/pgk8s#1163](https://github.com/pgmac-net/pgk8s/issues/1163) |
| 2   | Post-reboot containerd stale sandbox gate and fix in the reboot procedure | High | [pgmac-net/homelabia#283](https://github.com/pgmac-net/homelabia/issues/283) |
| 3   | AWX: fail loudly on missing DB secret; remove placeholder `pgawx-postgres-configuration` | Medium | [pgmac-net/pgk8s#1164](https://github.com/pgmac-net/pgk8s/issues/1164) |
| 4   | `k8s-reboot.yml`: reconcile pre-flight gates with stop-first | Medium | [pgmac-net/ansible#375](https://github.com/pgmac-net/ansible/issues/375) |
| 5   | Runbook for `microk8s-kine-reconnect-failures` | Medium | [pgmac-net/incidents#107](https://github.com/pgmac-net/incidents/issues/107) |
| 6   | Automate Jiva controller relocation (stop-first) with wedge/corruption detection | High | [pgmac-net/ansible#374](https://github.com/pgmac-net/ansible/issues/374) |
| 7   | Catalog: AWX, sealed-secrets, Jiva consumers; AWX → external PostgreSQL dependency | Medium | [pgmac-net/sre-catalog#71](https://github.com/pgmac-net/sre-catalog/issues/71) |
| 8   | `microk8s-cluster-status`: report cordoned nodes separately from NotReady | Low | [pgmac-net/nagios-config#72](https://github.com/pgmac-net/nagios-config/issues/72) |
| 9   | ArgoCD apps stuck Progressing after application-controller restart | Low | [pgmac-net/homelabia#285](https://github.com/pgmac-net/homelabia/issues/285) |
| 10  | Harness read-only ssh to k8s02 | Low | [pgmac-net/homelabia#284](https://github.com/pgmac-net/homelabia/issues/284) |
| 11  | Investigate macro heat and iowait | Low | [pgmac-net/homelabia#286](https://github.com/pgmac-net/homelabia/issues/286) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03, VMs on pve2)
- **Storage:** OpenEBS Jiva (3 replicas per volume, 11 volumes); datastore k8s-dqlite via kine
- **GitOps:** ArgoCD with `selfHeal`, app-of-apps (`ci-tools` owns the AWX Application)
- **Reboot tooling:** `k8s-reboot.yml` (pgmac-net/ansible, PGM-226) with `k8s_reboot_skip_jiva_shuffle=true`

### Key Error Signatures

```
SandboxChanged ... failed to reserve sandbox name ... is reserved for "<id>"     # k8s01 calico-node loop
Error link openebs/volume-head-093.img openebs/volume-snap-000.img: no such file or directory during open   # corrupt chain
can only have one WO replica at a time, found WO Replica: tcp://<ip>:9502         # serialised rebuild (normal)
Waiting for s.Replica() to be non nil                                            # registration wedge
dial tcp 10.152.183.57:9501: connect: network is unreachable                     # zombie replica, no network
listen tcp 172.22.22.9:7946: bind: address already in use                        # metallb speaker, k8s03
Failed to execute on pod pgawx-web-... container not found (pgawx-web)           # awx-operator deadlock
django.db.utils.OperationalError: [Errno -2] Name or service not known           # AWX DB host
Abort if stuck Pending pods exist: 1 pod(s) Pending for more than 3 minutes      # k8s-reboot.yml attempt 1
Abort if dqlite lock errors detected: [('k8s01','4'),('k8s02','1'),('k8s03','8')]  # k8s-reboot.yml attempt 2
```

### ArgoCD deny window (project `default`)

```yaml
syncWindows:
  - kind: deny
    applications: ['*']
    manualSync: true
    schedule: '30 6 21 11 *'
    duration: 8h
    timeZone: Australia/Brisbane
```

### Evidence

No SAR or nagiosgraph graphs were captured during the incident (`~/incident-evidence/incidents-106` does not exist), and none of the chains is a resource-exhaustion failure; the storms are evidenced by the Nagios check output recorded in the timeline. A graph of the dqlite lock and kine reconnect counts around 10:28 and 11:46 AEST would have shown the leadership-move storms: no such artefact exists, so the claim rests on the check results.

### Audit Log

Verified with `audit.py verify --incident incidents-106` (the log itself is kept in the private audit location and is not reproduced here):

- **Records:** 837; hash chain intact; 1 self-reported record; 0 capture errors; no state-directory access; no leftover secrets.
- **Approvals:** 49; **denials:** 1; **Tier 2 actions claimed:** 0.
- **Attempts that never completed:** 15, all read-only (`kube_read.py` queries, `grep`, `ssh` journal reads) plus one denied mutation (a hard refresh annotation on the `cert-manager` ArgoCD Application attempted at 13:26 AEST, which matches the single denial; the refresh was later done by the responder at 13:49). The k8s02 `ssh` attempt failed on publickey (action item 10).
- **Mutating commands with no approval for that exact command:** 60 flagged. 58 are the harness's own bookkeeping (`timeline.py add` ×57, `incident.py set` ×1: severity P4 → P3). The other two are the denied hard-refresh above and a read-only `grep -rln` over the runbooks that the pattern matcher classified as a mutation. No mutation reached the cluster without an approval. Every change to the cluster in this incident was made by the responder; the harness ran read-only queries and the approved `crictl` and kubelite commands in phase 1 and the AWX scale-downs and scale-up in phases 3 and 4.
- Mutation detection is pattern-based, per simple command; a command too long to classify counts as a mutation, and file edits made with other tools are not classified.

---

## References

- GitHub Issue: [pgmac-net/incidents#106](https://github.com/pgmac-net/incidents/issues/106) — incident tracking issue
- GitHub Issue: [pgmac-net/ansible#374](https://github.com/pgmac-net/ansible/issues/374) — automate Jiva stop-first relocation
- Pull request: [pgmac-net/pgk8s#1162](https://github.com/pgmac-net/pgk8s/pull/1162) — remove the clashing AWXMeshIngress
- Related incident: [2026-09-15 pvek8s Triple Replica Fault](2026-09-15-vzdump-fsfreeze-jiva-replica-triple-fault.md)
- Related incident: [2026-09-26 pve2 RAID5 degradation](2026-09-26-pve2-raid-degradation-cascading-corruption.md)
- Runbook (new): [Rolling Kernel Reboot of pvek8s](../runbooks/k8s-rolling-reboot.md)
- Runbook: [Safe Node Restart (jiva-ctrl hosted)](../runbooks/jiva-ctrl-node-rolling-restart.md)
- Runbook: [Jiva Controller Replica-Registration Wedge](../runbooks/jiva-ctrl-replica-registration-wedge.md)
- Runbook: [Jiva Replica Corrupt Snapshot Chain](../runbooks/jiva-replica-corrupt-snapshot-chain.md)
- Runbook: [dqlite Write Contention](../runbooks/dqlite-write-contention.md)

---

## Reviewers

- @pgmac
