---
title: 2026-09-02 systemd segfault & jiva RO cascade
date: 2026-09-02
severity: P1
resolution: Resolved
duration: ~33h across two linked incidents (22:42 AEST 2 Sep → ~07:41 AEST 4 Sep); incident 1 ~23h 4m (~18h undetected, ~69m control-plane loss, ~3h30m recovery), incident 2 ~8h 44m (~7h45m undetected, ~35m active recovery)
impact: >-
  All three pvek8s apiservers dead simultaneously for ~69 minutes with no
  ability to schedule, restart or inspect any workload. A follow-on dqlite
  storm ~24h later remounted 10 of 11 Jiva volumes read-only fleet-wide,
  taking four external services down for up to ~8h45m. ext4 corruption
  across five Jiva volumes and SQLite damage on two. No data was ultimately
  lost in either incident.
tags:
  - k8s01
  - k8s02
  - k8s03
  - systemd
  - kubelite
  - dqlite
  - containerd
  - openebs
  - jiva
  - iscsi
  - calico
  - argocd
  - storage
  - monitoring
  - microk8s
  - crash-loop
---

# Post Incident Review: pvek8s Total Control Plane Loss and Read-Only Volume Cascade — systemd +esm4 PID 1 Segfault, a Recurring dqlite/iSCSI Storm, and Two Rounds of Storage Recovery

## Executive Summary

Between 2026-09-02 22:42 AEST and 2026-09-03 21:46 AEST, all three pvek8s nodes lost their init process and then, one by one, their Kubernetes control plane. systemd PID 1 caught `SIGSEGV`, dumped core, and entered its terminal `Freezing execution` loop on k8s01, k8s03 and k8s02 in turn. A frozen PID 1 is alive but permanently deaf: it can never again start a unit, restart a service, answer D-Bus or fire a timer. Every microk8s daemon on all three nodes was therefore running completely unsupervised.

The trigger was an operator-run `apt-get dist-upgrade` on 2026-09-01 that moved systemd from `245.4-4ubuntu3.24+esm3` to `+esm4` on all three nodes simultaneously. The package's `postinst` performs `daemon-reexec`, placing the new ESM binary into PID 1. All three then crashed 9–33 hours later — same package, same version, same crash, three machines. This is an Ubuntu 20.04 ESM regression, not a local fault; core dumps from all three nodes were preserved for a Canonical report.

The outage became user-visible only when the unsupervised daemons began dying. `kubelite` terminates its entire process — apiserver, kubelet, scheduler and controller-manager together — when it loses leader election, and normally systemd restarts it within a second. With PID 1 frozen it simply stayed dead. k8s03's kubelite died at 17:36, k8s02's at 17:44, and k8s01's at 18:03 — the last one taking the final surviving apiserver with it and producing ~69 minutes of total control plane loss. Notably, k8s01's kubelite died *during* this investigation, roughly 90 seconds before an attempt to cordon k8s03.

Recovery required `sysrq` (`sync`, `remount read-only`, `reboot`) on each node, because `reboot`, `systemctl reboot` and Ansible's `reboot` module all route through the dead PID 1. The documented reboot order (k8s02 → k8s03 → k8s01) had to be **inverted** — k8s01 was the only node still serving an apiserver when recovery began, and then, once it too had died, k8s03 was simply the fastest path back to a working control plane. Each node returned healthy with a live PID 1 owning the D-Bus name, all microk8s units active, port 16443 listening, and zero SEGV since boot.

Rebooting the nodes did not end the incident. Four further failures, each with a completely different mechanism, kept nine pods down for up to three hours afterwards: stale `nodeID` labels on nine `JivaVolume` CRs (the cross-node double-mount guard firing against nodes we had just made `Ready` again); a dirty ext4 journal on tautulli's volume; a volume root left at mode `0000` on calibreweb, which has no `fsGroup`; and genuine ext4 metadata corruption on readarr's and sonarr's volumes from the unclean shutdown, with sonarr's SQLite database additionally damaged. All were recovered without data loss — readarr's database passed `integrity_check` after `e2fsck`, and sonarr's was rebuilt with SQLite `.recover`, preserving all 39 tables and every row.

Two things made this far worse than it needed to be. First, **nothing detected a dead init for 18 hours**, because every monitoring check on these nodes asks systemd whether systemd is alive. Second, roughly half the Nagios alert board was actively misleading — `check_systemd.sh` reports an unreachable D-Bus as a *service* failure, and four other scripts fabricate "unit not found" when `systemctl` times out, which read as "MicroK8s is not installed".

### A second, linked incident: the dqlite storm returns

Ninety minutes after the first incident closed, at 23:14 AEST on 3 Sep, a dqlite write-contention storm — the same failure class [homelabia#139](https://github.com/pgmac-net/homelabia/issues/139) had been closed against — starved the kernel iSCSI initiator's 5-second keepalive on all three nodes at once. This is the documented **Mode B** cascade from the [jiva-ctrl-eviction-iscsi-ro-filesystem](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md) runbook: `ping timeout` before any `conn error (1020)`, session recovery timing out after 120 seconds, the kernel marking the block devices offline, and ext4 journals aborting mid-write. Ten of the cluster's eleven Jiva volumes remounted read-only within an eleven-minute window (12:57–13:08 UTC) — including the one volume deliberately left untouched during the first incident's recovery because it was healthy, which is the clearest evidence this was a fresh, independent event rather than lingering damage.

The read-only mounts alone produced no alert for over four and a half hours; the cascade only became visible once the affected applications' own retry loops exhausted — readarr and sonarr's deployments were reported degraded at 04:00 AEST, and jiva replica pods began crash-looping in earnest from 05:10, feeding writes back into dqlite in the exact self-reinforcing loop the (closed) `microk8s-jiva-pod-health` check warns about. By 06:49 AEST four externally-monitored services (Home Assistant, Overseerr, Readarr, Sonarr) were returning HTTP 503, alongside five more pods silently blocked on the same read-only volumes.

Recovery followed the existing runbook's Fast Path A — scale each workload to zero, confirm the device and every bind-mount reference are fully released, scale back up — across nine volumes, plus a tenth (calibreweb) found separately with a milder `clean with errors` flag despite never fully remounting read-only. Two complications not previously documented surfaced along the way: ArgoCD's `selfHeal` reverted the scale-to-zero on three workloads via two app-of-apps parents (`bork`, `system`) that had to be discovered from scratch, mirroring `media`'s role in the first incident; and four pods hit the runbook's known `GetDeviceMountRefs` wedge, requiring a manual unmount of a stranded pod-path bind mount before kubelet would complete teardown. Every recovered filesystem returned `clean`, and readarr's, sonarr's and tautulli's databases all passed `PRAGMA integrity_check: ok` despite this event aborting journals mid-write rather than the first incident's clean shutdown — no data was lost. Two Jiva replicas remain in `CrashLoopBackOff` at time of writing, reporting `network is unreachable` to a healthy controller's ClusterIP from inside their own pod network namespace despite correct host-level iptables rules — a likely Calico per-pod route gap, tracked separately, not blocking service since both affected volumes hold 2-of-3 quorum.

---

## Timeline (AEST — UTC+10)

| Time | Event |
| ---- | ----- |
| **~02:05–02:08, 2 Sep** | Operator runs `apt-get dist-upgrade` on all three nodes. systemd `245.4-4ubuntu3.24+esm3` → `+esm4`; `postinst` runs `daemon-reexec`, placing the new binary into PID 1 |
| **~22:30, 2 Sep** | snapd "Regenerate security profiles" loop already running on k8s01 (pre-existing, ~166/hr) |
| **22:42:02, 2 Sep** | **k8s01 systemd catches `SIGSEGV`, dumps core (pid 2342078), `Freezing execution`.** Nagios checks last OK at 22:41:20 — a 42-second match |
| **02:13:05, 3 Sep** | Kernel upgrade to 5.4.0-238 writes `/var/run/reboot-required` — 3.5h *after* the crash, a red herring |
| **10:50:34, 3 Sep** | **k8s03 systemd SEGV + freeze** (core pid 2813797) |
| **11:15:59, 3 Sep** | **k8s02 systemd SEGV + freeze** (core pid 2585468) |
| **16:45–17:06** | Nagios second wave: `microk8s-components`, `watch-cache`, `kine`, `dqlite-lock`, `jiva-pod-health` go critical/unknown |
| **17:06** | Investigation begins. Host UP, PING 0% loss; ~20 service checks failing, many `CHECK_NRPE STATE CRITICAL: Socket timeout after 15 seconds` |
| **17:21** | `wazuh-agent` timing out identified as the key signal — no kubectl involved, so not the known kubectl-timeout false positive |
| **17:36:35** | **k8s03 kubelite dies** — `server.go:323] "Leaderelection lost"`. Cannot restart; node goes `NotReady` |
| **17:44:37** | **k8s02 kubelite dies** — same signature. Two apiservers now gone |
| **17:57** | Root cause identified: systemd PID 1 segfault on all three nodes, `+esm4` upgrade implicated. Reboot advised, order inverted (k8s01 last — sole surviving apiserver) |
| **18:03:41** | **k8s01 kubelite dies** — same signature. **Total control plane loss begins** |
| **18:05** | Cordon attempt fails: `Unable to connect to the server: EOF`. k8s01's death confirmed via SSH |
| **18:07–18:11** | k8s03: core dump preserved, `sysrq` `s` (Emergency Sync complete), `u` (verified `ro,relatime`), `b` |
| **18:16** | **k8s03 back.** PID 1 owns `org.freedesktop.systemd1`, SSH login 240s → 3.5s, all microk8s units active, 16443 listening, kernel 5.4.0-238, 0 SEGV. **Control plane restored** |
| **18:53–19:00** | k8s02: same sequence. Back at 19:00:23, healthy |
| **19:05–19:12** | k8s01: same sequence. Back at 19:12:00, healthy. **All three nodes `Ready`, three apiservers serving** |
| **20:17** | Terminating backlog fully drained (112 → 0), but nine pods stuck: eight `ContainerCreating` on k8s03, `hass-home-assistant-0` `Init:0/1` on k8s02 |
| **20:30** | Jiva CSI driver source read: the "already mounted at more than one place" error tests the **`nodeID` label**, not the `mountInfo` it prints |
| **20:33** | Canary confirmed — radarr `Running` after clearing its stale `nodeID` label |
| **20:38–20:48** | Remaining labels cleared (three blocked by the permission classifier, run manually by the operator). 8 of 9 pods recover |
| **20:56–20:57** | tautulli: `e2fsck -f -y /dev/sdg` replays dirty journal (`clean with errors` → `clean`); pod `Running` |
| **21:00–21:03** | `argocd-redis-ha-server-0` bootstrap deadlock broken by deleting the pod; StatefulSet reaches **3/3** |
| **21:07–21:08** | calibreweb: volume root `chmod 755` (was `0000`); pod `Running` |
| **21:22–21:24** | readarr: device imaged, `e2fsck -f -y` repairs extent-tree corruption; pod `Running`, `integrity_check: ok`, 26 authors / 372 books intact |
| **21:28–21:36** | sonarr: ArgoCD auto-sync suspended on `media` + `sonarr`, stale bind mount unmounted, device imaged, `e2fsck -f -y` repairs bitmap/i_blocks damage |
| **21:42–21:44** | sonarr SQLite `.recover` rebuild — `integrity_check: ok`, all 39 tables and every row preserved (188/19012/9398/21504); pod `Running` |
| **21:46** | ArgoCD `syncPolicy` restored verbatim on both apps. **Incident 1 resolved** |
| **22:57:19–13:08 UTC, 3 Sep** | **Incident 2 begins.** dqlite storm starves iSCSI keepalive fleet-wide (`ping timeout` before `conn error (1020)` on all three nodes — Mode B); 10 of 11 Jiva volumes remount read-only by 23:08–23:35 AEST |
| **04:00** | Nagios: `media/readarr (0/1)`, `media/sonarr (0/1)` deployments reported degraded |
| **05:10–05:28** | Jiva replica pods begin sustained `CrashLoopBackOff`, feeding further dqlite writes |
| **06:49** | Operator flags 4 services down (hass, overseerr, readarr, sonarr all HTTP 503) and several pods in error/CrashLoopBackOff; investigation resumes |
| **06:50–07:00** | Root cause confirmed via Nagios alerts + kernel journal: Mode B signature present on all 3 nodes, 12:57–13:08 UTC. All 11 jiva-ctrl pods found recreated simultaneously at 17:52:52–56 UTC (03:52 AEST), all on k8s01 |
| **07:00–07:04** | ArgoCD `syncPolicy` suspended on 10 apps (`media`, `radarr`, `readarr`, `sabnzbd`, `sonarr`, `tautulli`, `seerr`, `hass`, `survive`, `borked-craft`); 9 workloads scaled to zero |
| **07:04–07:08** | `hass`, `borked-craft`, `survive` found reverted to `replicas: 1` — two previously-undocumented ArgoCD app-of-apps parents (`bork`, `system`) discovered and suspended; re-scaled successfully |
| **07:06–07:08** | All 9 globalmounts confirmed released (unmounted, iSCSI logged out) across all three nodes |
| **07:08–07:09** | All 9 workloads scaled back to 1; all Running within ~60s; RW confirmed from inside every pod |
| **07:12–07:13** | Three jiva replica pods found still `CrashLoopBackOff`: `pvc-8eccb718-...-rep-0` (broken snapshot chain, pre-existing), `pvc-4dc1b925-...-rep-1` and `pvc-c231ecc5-...-rep-0` (`network is unreachable` to a healthy ctrl ClusterIP). Both affected volumes hold 2/3 quorum — deferred as a non-blocking follow-up |
| **07:15–07:26** | Calibreweb found separately with `clean with errors` (never fully remounted ro); `media` app-of-apps re-suspended after reverting the first attempt; device imaged, `e2fsck -f -y`, volume root `chmod 755` (same missing-`fsGroup` recurrence as incident 1) |
| **07:12–07:15** | readarr, sonarr, tautulli databases re-verified: `PRAGMA integrity_check: ok` on all three despite this event aborting journals mid-write (unlike incident 1's clean shutdown) |
| **07:26–07:41** | All 12 ArgoCD `syncPolicy` values restored verbatim; Nagios confirms all 4 previously-down services cleared, all 11 JivaVolumes `Ready/RW`, dqlite lock rate back to baseline. **Incident 2 resolved** |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: All Three Apiservers Dead — systemd PID 1 Segfault

##### How did all three apiservers stop serving?

`kubelite` — which hosts the apiserver, kubelet, scheduler and controller-manager in one process — exited on each node and was never restarted. k8s03 at 17:36:35, k8s02 at 17:44:37, k8s01 at 18:03:41.

##### How did kubelite exit?

It self-terminated. Each death logged `server.go:323] "Leaderelection lost"` immediately before exit. `dmesg` was clean on every node — no OOM kill, no signal from outside. Under kine/dqlite latency, kubelite loses its leader lease and deliberately terminates the whole process.

##### How was kubelite not restarted?

Its systemd unit has a restart policy, but systemd could not act. PID 1 was frozen: `State: S (sleeping)`, one thread, and `busctl --system list` showed `org.freedesktop.systemd1` as `(activatable)` with no owning PID. Every `systemctl` call blocked for 25 seconds on D-Bus activation and then failed.

##### How did PID 1 become frozen?

systemd caught `SIGSEGV`, dumped core, and entered its terminal freeze loop:

```
systemd[1]: Caught <SEGV>, dumped core as pid 2342078.
systemd[1]: Freezing execution.
```

This happened on k8s01 at 22:42:02 on 2 Sep, k8s03 at 10:50:34 and k8s02 at 11:15:59 on 3 Sep. Core dumps were left at `/var/crash/_usr_lib_systemd_systemd.0.crash` on each node.

##### How did systemd segfault on three machines at once?

All three were running `systemd 245.4-4ubuntu3.24+esm4`, upgraded from `+esm3` by a single `apt-get dist-upgrade` across the fleet on 2026-09-01 16:05–16:08 UTC. The systemd `postinst` runs `daemon-reexec`, which replaces the running PID 1 image with the new binary. Every node therefore began executing the new ESM build at essentially the same moment, and each crashed 9–33 hours later.

##### How was a fleet-wide simultaneous upgrade of PID 1 possible?

Cluster nodes are patched together in a single pass, with no staggering and no soak period on one node before the others follow. A defect in a package that re-execs PID 1 is therefore armed on all three nodes at once, which converts a single-node fault into a cluster-wide one.

##### How was this class of failure not prevented?

There is no policy or tooling enforcing staged OS upgrades across the cluster, and no hold on `systemd` and its siblings despite PID 1 being the single most dangerous package to replace in place on a node that cannot be quickly rebuilt. The specific defect is upstream and not fixable locally — but the blast radius was entirely a local choice.

---

#### Chain 2: An 18-Hour Detection Gap — Monitoring That Asks systemd About systemd

##### How was a dead init not noticed for 18 hours?

k8s01's PID 1 froze at 22:42 on 2 Sep. The first human attention came at 17:06 on 3 Sep — 18h 24m later — and only because the alert board had become noisy enough to prompt a look.

##### How did no alert identify the actual problem?

Alerts did fire, in volume. But they described the wrong thing. `microk8s-containerd` and `microk8s-dqlite` reported `Service snap.microk8s.daemon-*.service critical` while both daemons were in fact running healthily; `wazuh-agent` reported an NRPE timeout while six wazuh processes were running normally.

##### How did the checks report healthy services as critical?

`check_systemd.sh` runs `systemctl is-active "${SERV}"` and treats any non-`active` output as a service failure:

```bash
STAT=$(systemctl is-active "${SERV}")
if [[ ${STAT} == "active" ]]; then ... else echo "Service ${SERV} critical"; exit 2; fi
```

It never inspects the exit code, so "the service is inactive" and "systemd cannot be reached at all" are indistinguishable. With D-Bus dead, every service on the box reports CRITICAL.

##### How did other checks claim MicroK8s was not installed?

Four scripts (`check_dqlite_locks.sh:27`, `check_kine.sh:28`, `check_kine_reconnect_failures.sh:56`, `check_kubelite_log_staleness.sh:40`) test for a unit like this:

```bash
if ! systemctl list-units --full --all | grep -q "snap.microk8s.daemon-k8s-dqlite"; then
    echo "UNKNOWN: MicroK8s dqlite service not found"
```

When `systemctl` fails, its error goes to **stderr** and stdout is empty, so `grep -q` fails and the script fabricates "not found" — surfacing as `MicroK8s not installed?`. All four returned in 6.66–6.68s, the shared D-Bus timeout truncated by NRPE's 15s socket limit.

##### How was the real signal — a dead PID 1 — not measured by anything?

Every systemd-related check on these nodes queries systemd through D-Bus. When systemd itself is the casualty, all of them fail in ways that describe their *targets* rather than the manager. There is no check that asks, independently of systemd, whether PID 1 is alive and owns its bus name.

##### How was that gap not closed earlier?

A frozen-but-alive PID 1 had not occurred before on this cluster, so monitoring was designed around services failing *under* a healthy init, never the init itself. The failure mode is self-masking: the more thoroughly systemd is dead, the more confidently the monitoring blames something else.

---

#### Chain 3: Nine Pods Unable to Mount — Jiva's Cross-Node Guard Firing on Stale State

##### How did nine pods fail to start after the cluster recovered?

Every one failed at `MountVolume.MountDevice` with `FailedPrecondition`:

```
volume {pvc-...} is already mounted at more than one place:
{{/var/snap/.../globalmount  ext4 /dev/disk/by-path/ip-10.152.183.209:3260-iscsi-...-lun-0}}
```

##### How were the volumes reported as mounted twice?

They were not mounted at all. k8s03 had zero jiva mounts in `/proc/mounts`, no iSCSI sessions, and no staging directories. The CSI node plugin was a fresh process started after the reboot, so it held no stale memory either.

##### How did the driver reach that conclusion?

The message is misleading. Reading the driver source (`openebs/jiva-operator` `pkg/driver/node.go`) shows `NodeStageVolume` rejects the request when the `JivaVolume` CR carries a **`nodeID` label naming a different node**, and that node is `Ready`. It *prints* `instance.Spec.MountInfo`, which is not what it tests. Clearing `mountInfo` changed the error text to `{{   }}` and changed nothing else — the definitive proof that the label was the real gate.

##### How did the `nodeID` labels point at the wrong nodes?

The label records where a volume was last staged. Nine volumes still named k8s01 or k8s02 from before the outage. Their pods had since been rescheduled to k8s03 (and k8s02 for hass), so every request came from a node that did not match the label.

##### How did the guard reject mounts for volumes that were genuinely free?

The guard's second condition is that the previously-recorded node is `Ready`. Under normal single-node maintenance the old node is down, so the guard correctly stands aside. Here we rebooted *all three* nodes back to `Ready` — which re-armed the guard against a double-mount that could not possibly exist. The corroboration was exact: the one volume with no `nodeID` label (`pvc-8eccb718`) was the only one that mounted without trouble, and the one whose label matched its node (`pvc-746b2837`) kept working throughout.

##### How was this not cleaned up automatically?

`NodeUnstageVolume` clears the label on graceful teardown. On these nodes the kubelet was dead when the volumes stopped being used, so teardown never ran for any of them. Nothing reconciles a `nodeID` label against reality afterwards.

##### How was this trap not anticipated during the reboot?

The existing runbook ([jiva-csi-stale-node-attachment](../runbooks/jiva-csi-stale-node-attachment.md)) documents this failure for a *single* force-deleted pod rescheduled to another node. Nobody had connected it to a multi-node reboot, where it occurs at scale and where restoring the old node to `Ready` is precisely what triggers it. `k8s-reboot.yml` has no pre-uncordon or post-reboot step that checks for stale `nodeID` labels.

---

#### Chain 4: Filesystem and Database Corruption on Two Volumes

##### How did readarr and sonarr fail after their volumes finally mounted?

readarr crashlooped with `CorruptDatabaseException ... SQLiteException: disk I/O error`; the kernel logged, repeatedly:

```
EXT4-fs error (device sdf): ext4_find_extent:968: inode #69: comm Readarr:
  pblk 33973 bad header/extent: invalid magic - magic 5d35, entries 25376, max 25711(0), depth 8293(0)
```

##### How did the filesystems become corrupt?

Both were flagged `Filesystem state: clean with errors`. Their ext4 metadata was damaged by writes that were in flight when the nodes went down — inode 69's extent-tree header was garbage, inode 68's block accounting was wrong, and `/logs/readarr.txt` had multiply-claimed blocks.

##### How were writes in flight when the nodes went down?

`kubelite` died while `containerd` kept running. Containers therefore continued serving and **writing** with no kubelet supervising them — k8s01 had 170 running tasks and k8s02 157 at a point when Kubernetes considered both nodes `NotReady` and their pods gone. Those writes were still landing on Jiva-backed ext4 when the nodes were rebooted.

##### How did the reboot not flush them safely?

Recovery used `sysrq` `s` then `u`, and `Emergency Sync complete` plus a verified `ro,relatime` was confirmed on every node before `b`. That protects the *node's* filesystems. It does not help iSCSI-attached Jiva volumes whose writers were unsupervised containers, nor does it reconcile what a container had buffered. Damage was confined to k8s03 — 32 EXT4 errors, zero on k8s01 and k8s02.

##### How did the corruption survive the CSI driver's own check?

The Jiva CSI driver runs `fsck -a` before mounting. `fsck -a` deliberately refuses to act on a dirty journal or structural inconsistency and returns an error instead, which is why readarr's volume would not mount at all. sonarr's damage was mild enough that `fsck -a` passed it, so sonarr ran for hours on a filesystem flagged `clean with errors` — and on a SQLite database that `integrity_check` later showed had a duplicate page reference.

##### How was corrupted-but-mounting storage not detected?

Nothing checks `dumpe2fs -h ... | grep 'Filesystem state'` on Jiva volumes after a node event, and nothing alerts on `EXT4-fs error` in the kernel log. sonarr would have kept running and writing to a damaged database indefinitely; it was found only because a deliberate post-incident sweep was run across all eleven volumes.

##### How was there no procedure for this?

Post-reboot verification in `k8s-reboot.yml` covers Calico routes, JivaVolume quorum and a kubelet canary — all control-plane and scheduling concerns. Filesystem integrity of the attached volumes was never part of the checklist, because previous incidents damaged availability rather than data.

---

#### Chain 5: Collateral State Loss on Remount — redis-ha and calibreweb

##### How did `argocd-redis-ha-server-0` crashloop after the cluster recovered?

Its init container ran at 18:19:58, found a master, and configured itself as a slave:

```
Found redis master (10.152.183.251)  ->  we are slave of redis master (10.152.183.251:6379)
```

That address is `argocd-redis-ha-announce-2`. Pod-2's container was still running unmanaged at that instant, so the reachability ping succeeded. Pod-2 then disappeared, leaving pod-0 permanently replicating from nothing — `role=slave; repl=connecting`.

##### How did it not recover on its own?

Sentinel quorum is 2 and pod-0 was the only sentinel, so it could not promote itself. The `argocd-redis-ha` headless Service had no ready endpoints, so `argocd-redis-ha:26379` returned `Name does not resolve`; and with `OrderedReady` pod management, pods -1 and -2 were never created because -0 never became `Ready`. A closed loop. Deleting pod-0 broke it — it re-bootstrapped as master and the StatefulSet filled to 3/3 in ~2 minutes.

##### How did calibreweb fail after its volume mounted?

`sqlite3.OperationalError: unable to open database file`. The volume root was mode `0000` owned by `123:132`, with intact files inside. `ctime` on that directory was 20:38 on 3 Sep — the moment the volume re-staged.

##### How was calibreweb's volume root left unusable?

Its pod has `securityContext: {}` — **no `fsGroup`**. Every other volume in the namespace shows `drwxrws--- root:<fsGroup>`, which is kubelet applying fsGroup ownership on mount. With no fsGroup, kubelet does not manage that directory at all, so whatever mode the remount produced simply stood.

##### How was that fragility not caught before?

It only surfaces when the volume is re-staged from scratch, which normal operation never does. Both of these are cases where application-level state assumed continuity that a full-cluster restart does not provide, and neither had a health check capable of distinguishing "still starting" from "permanently wedged". **This chain recurred verbatim during incident 2** (calibreweb, 07:15–07:26 AEST 4 Sep) the moment its volume was re-staged for the ext4 repair — direct confirmation that the fix belongs on the workload's `fsGroup`, not in whatever happened to fix the mode last time.

---

#### Chain 6: The Storm Returns — dqlite Write Contention Restarts the iSCSI Cascade

##### How did 10 of 11 Jiva volumes go read-only 90 minutes after incident 1 closed?

A dqlite write-contention storm at 22:57–23:08 AEST starved the kernel iSCSI initiator's keepalive on all three nodes simultaneously. The kernel signature is unambiguous and present on every node: `ping timeout of 5 secs expired` **before** any `conn error (1020)`, which the existing [jiva-ctrl-eviction-iscsi-ro-filesystem](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md) runbook documents as **Mode B** — the target (jiva-ctrl) stays healthy throughout; it is the initiator that misses its 5-second deadline under CPU/scheduler pressure. Session recovery timed out after 120 seconds on every affected session, the kernel marked the block devices offline, in-flight writes returned `-EIO`, and ext4 journals aborted, remounting read-only.

##### How did a dqlite storm strike so soon after the first incident closed?

Undetermined with certainty. The two candidate explanations are not mutually exclusive: elevated write activity from the previous night's recovery (reboots, controller migrations, scheduler churn, three separate ArgoCD sync operations) may not have fully settled by 22:57; alternatively this is simply the cluster's known recurring failure mode reasserting itself independent of the prior incident, as it has on 2026-06-28, 2026-07-07, 2026-07-11, 2026-08-06, and now 2026-09-03. [homelabia#139](https://github.com/pgmac-net/homelabia/issues/139), closed against exactly this class of storm, was flagged for review rather than reopened unilaterally, since it is not established whether its fix regressed or a different trigger reaches the same downstream storm.

##### How did the storm produce a worse outcome than the 2026-08-06 precedent?

2026-08-06 hit six volumes across two nodes in seven minutes. This event hit ten volumes across all three nodes within eleven minutes — including `pvc-746b2837`, the one volume this incident's own recovery had deliberately left untouched hours earlier specifically because it was healthy. Nothing about the recovery from incident 1 made the cluster more fragile to this trigger; the wider blast radius reflects how many Jiva volumes now exist on the cluster, not a regression from the first incident.

##### How was the cascade not detected for over four and a half hours?

The read-only mounts themselves produce no immediate alert-worthy symptom — pods can keep reporting `Running` while writes silently fail, exactly as documented in Chain 4 above and in the [2026-08-15 hal NFS PIR](2026-08-15-hal-nfs-handle-invalidation-silent-sqlite-failures.md). Detection came only once downstream retry loops exhausted: readarr/sonarr deployments reported degraded at 04:00, and jiva replica pods began crash-looping from 05:10 — feeding further writes into dqlite in the self-reinforcing loop the (closed) `microk8s-jiva-pod-health` check's own output warns about (`sustained jiva crash-loops feed dqlite write storms`).

##### How was this not prevented or detected sooner?

Two gaps, both already tracked as action items from incident 1 rather than new discoveries: no alert fires on the read-only mount state itself faster than the current ~4h detection path, and the dqlite storm's root trigger remains only partially understood despite five prior occurrences. This chain adds one genuinely new gap — recovering from a fleet-wide Jiva RO event now requires knowing about **three** ArgoCD app-of-apps parents (`media`, `bork`, `system`), only one of which (`media`) was previously documented; `bork` and `system` had to be rediscovered live, under time pressure, costing several minutes and two reverted scale-down attempts.

---

## Impact

### Services Affected

| Service | Impact | Duration |
| ------- | ------ | -------- |
| Kubernetes control plane (all 3 apiservers) | No scheduling, restarts, `kubectl`, logs or exec cluster-wide | ~69m total loss (18:03 → 19:12); degraded from 17:36 |
| microk8s service supervision (all 3 nodes) | No unit could start or restart; all systemd timers dead | ~18h (k8s01), ~8h (k8s02/k8s03) |
| Auto-remediation (watch-cache watchdog, jiva mounts) | Silently offline — both are systemd timers | ~18h |
| radarr, readarr, sonarr, sabnzbd, tautulli, calibreweb, 2× minecraft | `ContainerCreating`, unable to mount Jiva volumes | ~2h 30m – 3h |
| hass-home-assistant | `Init:0/1`, unable to mount | ~1h 20m |
| ArgoCD redis-ha | StatefulSet 0/3; ArgoCD cache degraded | ~3h |
| readarr | Down; ext4 + database corruption | ~3h 20m |
| sonarr | Ran ~4h on a corrupt filesystem and damaged database | ~4h latent, ~16m remediation downtime |
| hass, seerr (overseerr), readarr, sonarr *(incident 2)* | HTTP 503 — external Nagios host checks CRITICAL | up to ~8h45m latent, ~9m active remediation each |
| radarr, sabnzbd, tautulli, calibreweb, 2× minecraft *(incident 2)* | Mount blocked, no external HTTP alert | up to ~8h45m latent, ~9m active remediation each |
| Jiva replicas `pvc-8eccb718-rep-0`, `pvc-4dc1b925-rep-1`, `pvc-c231ecc5-rep-0` | `CrashLoopBackOff`; 2/3 quorum on 2 volumes | Ongoing at time of writing — not blocking service |

### Duration

**Incident 1**
- **Total incident window:** ~23h 4m (22:42 AEST 2 Sep → 21:46 AEST 3 Sep)
- **Undetected:** ~18h 24m
- **Total control plane loss:** ~69m
- **Active recovery:** ~3h 30m
- **Expected recovery time (with documented procedure):** ~45–60 min for the three-node `sysrq` reboot cycle, plus ~20 min for the stale-label sweep

**Incident 2**
- **Total incident window:** ~8h 44m (22:57 AEST 3 Sep → 07:41 AEST 4 Sep)
- **Undetected:** ~7h 45m (first remount to operator report at 06:49)
- **Services down (HTTP):** up to ~8h45m for the 4 externally-monitored services
- **Active recovery:** ~35m (06:50–07:26 for the primary 10 volumes; permission-fix loop for calibreweb included)
- **Expected recovery time (with documented procedure):** ~20–30 min once the app-of-apps hierarchy is documented (issue pgk8s#748) — most of the ~35m here was spent rediscovering `bork` and `system`

### Scope

- All three nodes: k8s01, k8s02, k8s03, across both incidents
- **Data loss: none, either incident.** readarr's database passed `integrity_check` after `e2fsck` both times it was tested; sonarr's was rebuilt via SQLite `.recover` in incident 1 (all 39 tables and every row preserved: 188 series / 19012 episodes / 9398 episode files / 21504 history rows) and re-verified `ok` after incident 2's more abrupt journal abort. Backups were captured in both incidents but never needed.
- User-visible impact: all media services and Home Assistant unavailable for up to ~3h in incident 1, and hass/overseerr/readarr/sonarr unavailable for up to ~8h45m in incident 2; no ability to manage any workload cluster-wide for ~69 minutes during incident 1.

---

## Resolution Steps Taken

### Phase 1: Diagnosis

1. Confirmed the host was UP and reachable — not a network or host-down fault.
2. Identified `wazuh-agent` (no kubectl involvement) among the NRPE timeouts as evidence the fault was not the known kubectl-timeout false positive.
3. Established that checks which *completed* reported real apiserver failure, while those that timed out were collateral — separating genuine fault from monitoring artefact.
4. Found `Caught <SEGV>` / `Freezing execution` in the journal on all three nodes and confirmed a frozen PID 1 via `/proc/1/status` and `busctl --system list`.
5. Correlated with `/var/log/apt/history.log`: the `+esm3 → +esm4` upgrade at 2026-09-01 16:08:19 UTC.
6. Ruled out watch-cache freeze, dqlite contention, PLEG stall, Jiva mount proliferation, Calico breakage, disk pressure, read-only root and resource starvation — each with explicit evidence.

### Phase 2: Node Recovery (k8s03 → k8s02 → k8s01)

1. Preserved `/var/crash/_usr_lib_systemd_systemd.0.crash` from each node before touching it.
2. Confirmed `sysrq=176` already permits `sync`(16) + `remount-ro`(32) + `reboot`(128) — no change needed.
3. Per node: `sync`, then `echo s`, then `echo u`, **verified `findmnt -no OPTIONS /` returned `ro,relatime`**, then `echo b`.
4. Verified each node on return: PID 1 owning `org.freedesktop.systemd1`, `systemctl is-system-running`, microk8s units active, 16443 listening, kernel 5.4.0-238, zero SEGV since boot.

### Phase 3: Storage and Application Recovery

1. Read the Jiva CSI driver source to establish that `nodeID`, not `mountInfo`, gates `NodeStageVolume`.
2. Verified across all three nodes that none of the affected volumes was actually mounted, then cleared the stale `nodeID` labels — canarying on one volume (radarr) before the rest.
3. tautulli: `e2fsck -f -y` replayed a dirty journal (`clean with errors` → `clean`).
4. redis-ha: deleted `argocd-redis-ha-server-0` to break the bootstrap deadlock.
5. calibreweb: `chmod 755` on the volume root (mode `0000`).
6. readarr: imaged the device, `e2fsck -f -n` preview, then `e2fsck -f -y`; verified `integrity_check: ok`.
7. sonarr: suspended ArgoCD auto-sync on `media` and `sonarr`, unmounted a stale bind mount left by a false unpublish, imaged the device, `e2fsck -f -y`, then SQLite `.recover` into a fresh database, verified and swapped in.
8. Restored both ArgoCD `syncPolicy` values verbatim, including `media`'s `syncOptions`.

### Phase 4: Incident 2 — Fleet-Wide Read-Only Cascade Recovery

1. Confirmed the Mode B kernel signature (`ping timeout` before `conn error (1020)`) on all three nodes across the exact same 12:57–13:08 UTC window — ruled out chasing an evicted jiva-ctrl per the runbook's own guidance.
2. Mapped all 9 affected app pods to their PVCs, owning controllers (Deployment/StatefulSet), and ArgoCD Applications.
3. Recorded and suspended `syncPolicy` on 10 Applications (`media`, plus 9 leaf apps) before touching any workload.
4. Scaled all 9 workloads to zero; one scale command hit a transient `database is locked (try: 500)` — checked the live dqlite rate (0–1/2min, not a storm) before retrying rather than assuming another emergency.
5. Found `hass`, `borked-craft`, `survive` reverted to `replicas: 1` — traced to two undocumented ArgoCD app-of-apps parents (`bork`, `system`); suspended both, re-scaled successfully.
6. Confirmed every globalmount and iSCSI session fully released on all three nodes before scaling anything back up.
7. Cleared four `GetDeviceMountRefs` wedges (readarr, sonarr, seerr, hass) with a manual `umount` of the exact leftover bind-mount path named in the kubelite journal.
8. Scaled all 9 workloads back to 1; verified RW from inside every pod with a `touch`/`rm` round-trip, not just `Running` status.
9. Found calibreweb separately (`clean with errors`, never fully remounted ro) via a full filesystem-state sweep of every recovered device; repaired with the same image/`e2fsck` sequence, then hit and fixed the same missing-`fsGroup` mode-`0000` recurrence from Chain 5.
10. Re-verified `PRAGMA integrity_check: ok` on readarr's, sonarr's and tautulli's databases given this event's more abrupt journal abort.
11. Restored all 12 ArgoCD `syncPolicy` values verbatim (10 from step 3, plus `media` and `calibreweb` suspended a second time for the calibreweb repair).
12. Left three jiva replica pods in `CrashLoopBackOff` as a documented, non-blocking follow-up — both affected volumes hold 2/3 quorum.

---

## Verification

```bash
# PID 1 alive and owning its bus name (the check that was missing)
ssh k8s01 'busctl --system list | grep systemd1'
# → org.freedesktop.systemd1  1  systemd  root  :1.3  init.scope

# All three nodes Ready, all three apiservers serving
kubectl --context pvek8s get nodes
# → k8s01 Ready / k8s02 Ready / k8s03 Ready
kubectl --context pvek8s get endpoints -n default kubernetes
# → 172.22.22.6:16443,172.22.22.8:16443,172.22.22.9:16443

# All Jiva volumes healthy
kubectl --context pvek8s get jivavolume -n openebs \
  -o custom-columns='PHASE:.status.phase,STATUS:.status.status' --no-headers | sort | uniq -c
# → 11 Ready RW

# No filesystem carries an error flag, on any node
for h in k8s01 k8s02 k8s03; do
  ssh $h 'for d in /dev/disk/by-path/*iscsi*openebs*; do
    sudo dumpe2fs -h "$(readlink -f "$d")" 2>/dev/null | grep -i "^Filesystem state"; done'
done
# → all "clean" (no "clean with errors")

# No EXT4 errors since the repairs
ssh k8s03 'sudo dmesg -T | grep "EXT4-fs error" | tail -1'
# → last error 11:11:23 UTC, before the 11:22 repair; nothing since

# Databases intact
sqlite3 readarr.db "PRAGMA integrity_check;"   # → ok
sqlite3 sonarr.db  "PRAGMA integrity_check;"   # → ok
```

**Incident 2:**

```bash
# All 9 (then 10) globalmounts rw, no volume still ro
for h in k8s01 k8s02 k8s03; do
  ssh $h 'grep "jiva.csi.openebs.io.*globalmount" /proc/mounts | awk "{print \$1, \$4}"'
done
# → every entry "rw,relatime"

# All 4 previously-down services confirmed RW from inside the pod, not just Running
kubectl --context pvek8s exec -n media readarr-<pod> -- sh -c \
  'touch /config/.rwtest && rm /config/.rwtest && echo RW-OK'
# → RW-OK (repeated for sonarr, seerr, hass, and the other 5 recovered workloads)

# Every syncPolicy restored to its exact recorded original
for app in media bork system radarr readarr sabnzbd sonarr tautulli seerr hass survive borked-craft calibreweb; do
  kubectl --context pvek8s get application -n argocd "$app" -o jsonpath='{.spec.syncPolicy}'
done
# → matches the pre-incident values captured before any patch

# Nagios confirms all 4 down services cleared and no new criticals
# (mcp__nagios__get_alerts) → hass/overseerr/readarr/sonarr absent from the alert list
```

---

## Preventive Measures

### Immediate Actions Required

1. **Hold systemd on Ubuntu 20.04 ESM nodes and decide on an `+esm3` downgrade** (High)
    - Chain 1. `+esm4` segfaulted PID 1 on 3/3 nodes within 33h. All three now run fresh `+esm4` PID 1s started within an hour of each other, so a recurrence would take the whole cluster down at once rather than staggered over 12h. `+esm3` remains available from `focal-infra-security` at equal priority.
    - Issue: [pgmac-net/ansible#274](https://github.com/pgmac-net/ansible/issues/274)

2. **Add a PID-1 / D-Bus liveness check that does not go through systemd** (High)
    - Chain 2. Nothing detected a dead init for 18h because every check asks systemd about systemd. Must run from the Nagios host, not via NRPE.
    - Issue: [pgmac-net/nagios-config#52](https://github.com/pgmac-net/nagios-config/issues/52)

3. **`check_systemd.sh` must distinguish an unreachable manager from a failed service** (High)
    - Chain 2. It currently reports every service on the box as CRITICAL when D-Bus is down. Capture `systemctl`'s exit code and emit UNKNOWN (3), not CRITICAL (2).
    - Issue: [pgmac-net/ansible#275](https://github.com/pgmac-net/ansible/issues/275)

4. **Clear stale `JivaVolume` nodeID labels and verify volume filesystems during `k8s-reboot.yml`** (High)
    - Chains 3 and 4. The stale-label trap recurs on every multi-node reboot, and corrupted-but-mountable filesystems currently go undetected.
    - Issue: [pgmac-net/ansible#276](https://github.com/pgmac-net/ansible/issues/276)

5. **Investigate the chronic snapd "Regenerate security profiles" loop** (High)
    - Contributing factor to Chain 1. Survived all three reboots; 45–73 forks/sec per node, ~169k–217k cumulative changes. Predates the systemd upgrade (~166/hr before, ~179/hr after), so it is not the root cause — but it is the load that exercises PID 1 hardest.
    - Issue: [pgmac-net/homelabia#171](https://github.com/pgmac-net/homelabia/issues/171)

### Longer-Term Improvements

6. **Fix the four NRPE scripts that fabricate "unit not found"** (Medium)
    - Chain 2. `systemctl` writes errors to stderr, so `grep -q` on empty stdout produces a false "MicroK8s not installed" verdict.
    - Issue: [pgmac-net/ansible#277](https://github.com/pgmac-net/ansible/issues/277)

7. **Raise the NRPE timeout above systemd's 25s D-Bus timeout** (Medium)
    - Chain 2. NRPE's 15s socket limit truncates the real error text and hides the actual failure.
    - Issue: [pgmac-net/ansible#278](https://github.com/pgmac-net/ansible/issues/278)

8. **Stagger OS upgrades across cluster nodes with a soak period** (Medium)
    - Chain 1. A single `dist-upgrade` across all three nodes armed a simultaneous fleet failure. Upgrade one node and soak for 48h before the rest.
    - Issue: [pgmac-net/ansible#279](https://github.com/pgmac-net/ansible/issues/279)

9. **Add `fsGroup` to calibreweb and make redis-ha bootstrap resilient** (Medium)
    - Chain 5. calibreweb's missing `fsGroup` leaves its volume root unmanaged across remounts; redis-ha can deadlock permanently when all replicas are lost at once. Confirmed to recur verbatim on any future re-stage, since it recurred in incident 2 before this fix landed.
    - Issue: [pgmac-net/pgk8s#746](https://github.com/pgmac-net/pgk8s/issues/746)

10. **Determine whether the closed dqlite-storm fix (homelabia#139) actually holds** (High)
    - Chain 6. A storm of the exact class that issue targeted recurred 90 minutes after incident 1 closed, taking 10 of 11 Jiva volumes read-only fleet-wide. Not reopened unilaterally — flagged via comment for a call on whether the fix regressed or a different trigger reaches the same downstream failure.
    - Issue: [pgmac-net/homelabia#139](https://github.com/pgmac-net/homelabia/issues/139) (comment added, not reopened)

11. **Investigate the Calico per-pod route gap on Jiva replica initiators** (Medium)
    - Chain 6. Two jiva-rep pods report `network is unreachable` to a healthy jiva-ctrl ClusterIP from inside their own pod network namespace, despite correct host-level iptables rules — the same shape as the existing [calico-orphaned-pod-route](../runbooks/calico-orphaned-pod-route.md) runbook. Both affected volumes hold 2/3 quorum; not currently blocking service.
    - Issue: [pgmac-net/homelabia#173](https://github.com/pgmac-net/homelabia/issues/173)

12. **Document the ArgoCD app-of-apps hierarchy for incident responders** (Medium)
    - Chain 6. Recovering the fleet-wide RO cascade required discovering two previously-undocumented app-of-apps parents (`bork`, `system`) live, under time pressure, after `selfHeal` reverted three scale-to-zero attempts. Only `media` was documented from incident 1.
    - Issue: [pgmac-net/pgk8s#748](https://github.com/pgmac-net/pgk8s/issues/748)

---

## Action Items

| # | Action | Priority | GitHub |
| - | ------ | -------- | ------ |
| 1 | Hold systemd on Ubuntu 20.04 ESM nodes and decide on an `+esm3` downgrade | High | [pgmac-net/ansible#274](https://github.com/pgmac-net/ansible/issues/274) |
| 2 | Add a PID 1 / D-Bus liveness check that does not depend on systemd | High | [pgmac-net/nagios-config#52](https://github.com/pgmac-net/nagios-config/issues/52) |
| 3 | `check_systemd.sh` must report an unreachable manager as UNKNOWN, not CRITICAL | High | [pgmac-net/ansible#275](https://github.com/pgmac-net/ansible/issues/275) |
| 4 | `k8s-reboot.yml`: clear stale JivaVolume nodeID labels and verify volume filesystems | High | [pgmac-net/ansible#276](https://github.com/pgmac-net/ansible/issues/276) |
| 5 | Investigate the chronic snapd "Regenerate security profiles" loop | High | [pgmac-net/homelabia#171](https://github.com/pgmac-net/homelabia/issues/171) |
| 6 | Fix the four NRPE scripts that fabricate "unit not found" | Medium | [pgmac-net/ansible#277](https://github.com/pgmac-net/ansible/issues/277) |
| 7 | Raise the NRPE timeout above systemd's 25s D-Bus timeout | Medium | [pgmac-net/ansible#278](https://github.com/pgmac-net/ansible/issues/278) |
| 8 | Stagger OS upgrades across cluster nodes with a soak period | Medium | [pgmac-net/ansible#279](https://github.com/pgmac-net/ansible/issues/279) |
| 9 | Add `fsGroup` to calibreweb; make redis-ha bootstrap resilient | Medium | [pgmac-net/pgk8s#746](https://github.com/pgmac-net/pgk8s/issues/746) |
| 10 | Determine whether the closed dqlite-storm fix (homelabia#139) actually holds | High | [pgmac-net/homelabia#139](https://github.com/pgmac-net/homelabia/issues/139) |
| 11 | Investigate the Calico per-pod route gap on Jiva replica initiators | Medium | [pgmac-net/homelabia#173](https://github.com/pgmac-net/homelabia/issues/173) |
| 12 | Document the ArgoCD app-of-apps hierarchy for incident responders | Medium | [pgmac-net/pgk8s#748](https://github.com/pgmac-net/pgk8s/issues/748) |

---

## Lessons Learned

### What Went Well

- **The `wazuh-agent` anomaly cracked the case.** Noticing that a check with no kubectl involvement was also failing ruled out the familiar kubectl-timeout explanation and forced a host-level hypothesis.
- **Separating "checks that completed" from "checks that timed out"** turned a wall of ~20 alerts into a clear signal: everything that actually returned reported real apiserver failure.
- **Reading the driver source rather than guessing.** Three plausible hypotheses about the "mounted at more than one place" error were wrong; the source settled it in one step and prevented nine unnecessary patches.
- **Canarying the fix.** Clearing `mountInfo` on one volume proved that hypothesis wrong before it was applied to nine.
- **Every destructive step was verified before commitment** — `Emergency Sync complete` and `ro,relatime` confirmed before each `sysrq b`; a read-only `e2fsck -f -n` preview before every repair; device images captured before both filesystem repairs.
- **Recovery order was re-derived from evidence, not followed by rote.** The documented order would have destroyed the last surviving apiserver.
- **Incident 2's Mode B diagnosis took minutes, not hours,** because the exact runbook already existed from 2026-08-06 — a direct payoff of writing runbooks during incident 1 rather than treating the write-up as pure paperwork.
- **A live dqlite lock error during recovery (`try: 500`) was checked against the current rate before reacting,** not treated as a fresh emergency — the rate was near-zero, confirming it was transient, and the retry succeeded seconds later.
- **Verified RW from inside every pod, not just `Running` status,** which is what caught calibreweb's fsGroup recurrence and confirmed the other 9 workloads before declaring the incident closed.

### What Didn't Go Well

- **18 hours of blindness.** The single most important signal — init is dead — had no monitoring at all.
- **The alert board actively misled.** Roughly half the alerts were false, and several implied MicroK8s was uninstalled. Time was spent disproving them.
- **The cluster was patched as one unit,** turning an upstream package defect into a simultaneous three-node failure. It will recur on the same schedule unless the upgrade process changes.
- **Rebooting all three nodes back to `Ready` re-armed the Jiva guard** against mounts that no longer existed — a foreseeable consequence of a documented failure mode that nobody had connected to multi-node reboots.
- **sonarr ran for ~4 hours on a corrupt filesystem** and a damaged database, and was found only by a deliberate sweep. Without that sweep it would still be running that way.
- **ArgoCD `selfHeal` fought the recovery.** Scaling a deployment to zero was reverted within a minute, and patching the child Application's `syncPolicy` was undone by the app-of-apps parent — costing time before the correct two-level suspension was identified. **This recurred in incident 2 with two more app-of-apps parents** (`bork`, `system`) that were entirely undocumented, costing several minutes and two failed scale-down attempts before both were found.
- **A dqlite storm of the exact class a closed issue (homelabia#139) targeted recurred 90 minutes after the first incident closed,** and took ten volumes down at once — the widest blast radius of any occurrence of this failure mode to date.
- **The snapd security-profile loop from incident 1 remains unfixed** (homelabia#171, paused mid-investigation to handle this second incident) and continues to flood the kernel log, which will make the next kernel-level fault as hard to find as this one nearly was.

---

## Related Incidents

- [2026-06-05 pvek8s Kernel Update — Simultaneous 3-Node Reboot Cascade](2026-06-05-pvek8s-kernel-reboot-cluster-recovery-failure.md) — the prior instance of fleet-wide simultaneous patching causing a cluster-wide outage; Chain 1 is the same systemic gap, with a different package.
- [2026-06-17 seerr Jiva CSI Stale Node Attachment](2026-06-17-seerr-jiva-csi-stale-node-attachment.md) — same `nodeID` guard as Chain 3, single-pod scale.
- [2026-08-06 pvek8s Read-Only Volume Cascade — dqlite Storm, iSCSI Starvation, and a 17-Hour Action Gap](2026-08-06-dqlite-storm-iscsi-ro-volumes-detection-gap.md) — the first occurrence of Chain 6's exact Mode B mechanism (six volumes, two nodes); this incident is its second, wider occurrence (ten volumes, three nodes).
- [2026-08-15 hal NFS Handle Invalidation](2026-08-15-hal-nfs-handle-invalidation-silent-sqlite-failures.md) — SQLite reporting `disk I/O error` for a storage-layer fault, as readarr did here.

---

## Runbooks

- [systemd PID 1 segfault — frozen init recovery](../runbooks/systemd-pid1-frozen-init.md) — created by this PIR
- [Jiva volume ext4 corruption after unclean shutdown](../runbooks/jiva-volume-ext4-corruption.md) — created by this PIR
- [Jiva CSI stale node attachment](../runbooks/jiva-csi-stale-node-attachment.md) — extended with the multi-node reboot failure mode
- [Jiva-ctrl eviction → iSCSI → EXT4 read-only](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md) — Mode B section updated with this incident's ten-volume, three-node occurrence; used directly for incident 2's diagnosis and recovery
