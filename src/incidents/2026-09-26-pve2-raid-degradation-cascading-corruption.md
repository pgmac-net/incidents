---
title: 2026-09-26 pve2 RAID degradation, host wedge, cascading corruption
date: 2026-09-26
severity: P1
resolution: Resolved
duration: ~2d 10h 34m total (~02:01 AEST 26 Sep → 12:35 AEST 28 Sep); includes a ~14h30m unexplained host wedge and ~47h of deliberate full-cluster quiesce across three drive rebuilds
impact: >-
  A silently degrading RAID5 array on pve2 (the single hypervisor underlying
  the entire pvek8s cluster) went read-only under ordinary backup I/O load,
  took 7 PVCs offline, then wedged the host itself for 14.5 hours. The forced
  power cycle that followed rolled back an LVM thin pool by ~8GB of guest
  writes and corrupted filesystems, container image layers, and system files
  across all three k8s nodes and one Wazuh VM, one of which needed a full
  backup restore. All three replaceable RAID drives were swapped and
  rebuilt one at a time over the following two days with the cluster fully
  quiesced. All services were restored with no volume data loss; ~8 hours
  of Home Assistant history and the Wazuh manager's post-incident state
  were permanently lost.
tags:
  - pve2
  - proxmox
  - k8s01
  - k8s02
  - k8s03
  - raid
  - lvm
  - thin-pool
  - openebs
  - jiva
  - containerd
  - calico
  - argocd
  - terraform
  - wazuh
  - storage
  - corruption
---

# Post Incident Review: pve2 RAID5 Degradation, Host Wedge, and Cascading Filesystem Corruption

## Executive Summary

pve2's Smart Array P410i RAID5 array (4×300GB SAS, backing every pvek8s node VM, every Jiva replica and controller, dqlite, and all three Wazuh VMs) had been visibly degrading for weeks ([homelabia#186](https://github.com/pgmac-net/homelabia/issues/186), [#187](https://github.com/pgmac-net/homelabia/issues/187)). At ~02:01 AEST on 26 September, routine `vzdump` backup read load against the already-degraded array pushed iSCSI ping latency past the 5-second timeout, and seven PVCs across k8s01 and k8s03 remounted read-only — the same failure mode documented in the [2026-09-15 PIR](2026-09-15-vzdump-fsfreeze-jiva-replica-triple-fault.md), this time without even a guest-agent freeze involved. All seven volumes were recovered by late morning using the existing `jiva-ctrl-eviction-iscsi-ro-filesystem` runbook, including one recurrence of a `/config` permission bug on calibre-web first seen a week earlier.

With the immediate outage cleared, the operator moved to replace the array's failing drives — three of four had rapidly climbing SMART defect counts, one (bay 3) directly implicated as the source of the I/O latency spikes. The cluster was fully quiesced (all 16 application workloads scaled to zero, all three Wazuh VMs stopped, ArgoCD auto-sync blocked with a `SyncWindow`) and bay 3 was pulled and rebuilt cleanly in ~3h10m. 74 minutes after that rebuild finished, at 17:58 AEST, **pve2's own userland died** — ssh, NRPE and the Proxmox web UI all stopped responding, the console showed nothing but a blinking cursor, yet the guest VMs kept running normally throughout. No hardware fault appeared anywhere in the server's event log. After 14.5 hours with no recovery and no way to intervene short of pulling power, the operator forced a power cycle the next morning.

That unclean power cycle is what turned a hardware problem into a data-corruption incident. The host's own root filesystem needed repair on boot; the LVM thin pool underneath every guest disk came up inactive and needed `lvconvert --repair`, which rolled two guests' disks back to their last durable metadata commit — a real, permanent loss of roughly 8GB of writes that no filesystem check could detect. Above that rollback, guest-level damage surfaced across all three k8s nodes and the Wazuh manager VM: corrupted ext4 metadata, a corrupted microk8s snap, corrupted containerd content-store blobs and unpacked image layers, a zeroed `/etc/sudoers` on one node, corrupted system binaries on another, and — on the Wazuh manager VM specifically — enough zeroed core libraries and a zeroed `dpkg` database that the guest had to be restored wholesale from backup rather than repaired in place. Recovering all of this, while continuing the drive-replacement program (bay 2, then bay 4, each requiring its own full quiesce-rebuild-settle cycle), took until 12:35 AEST on 28 September, when every service and all three Wazuh VMs were confirmed healthy simultaneously for the first time since the incident began.

Two further issues surfaced during post-restore hardening and are treated as their own root-cause chains below: calibre-web's `/config` permission bug recurred a **third** time because the original in-cluster fix was never made permanent in git, and a week-old, unrelated `argocd-notifications` ComparisonError was found and fixed via Terraform — an apply that briefly put a live 92-day-uptime `coder` deployment at risk of cascading deletion, caught and reversed with zero actual impact.

The trigger for the pve2 host wedge itself — the single event that turned a routine (if hazardous) drive swap into a two-day, multi-VM corruption incident — was never identified. This is the incident's most significant open finding.

---

## Timeline (AEST — UTC+10)

| Time | Event |
| --- | --- |
| **~02:01 AEST 26 Sep** | k8s01 `/dev/sdc` remounts read-only under `vzdump` (VMs 100/102/103, 01:00–05:14) backup read load against the degraded array. `~04:10` k8s03 `/dev/sdb` follows. No guest-agent freeze involved — read load alone was sufficient, as in the 2026-09-15 incident. |
| **09:20 AEST 26 Sep** | Incident opened ([pgmac-net/incidents#89](https://github.com/pgmac-net/incidents/issues/89)). Nagios: 7 RO PVCs (k8s01 ×2, k8s03 ×5), pve2 RAID drive health CRITICAL (bay 2/3 grown-defect counts climbing fast), controller cache error, pve2 RAM 99%. |
| **09:31 AEST** | Runbook matched: `jiva-ctrl-eviction-iscsi-ro-filesystem` (Mode B, hypervisor I/O stall). Affected: media/{calibre-web,radarr,readarr,sonarr,tautulli}, minecraft/borked-craft, netconnectors/hass. |
| **09:40–10:25 AEST** | All 7 volumes recovered in sequence (scale-to-zero fast path, ArgoCD SyncWindow blocking auto-sync revert): tautulli, sonarr, calibre-web (hit `/config` mode-000, fixed with `chmod 755` — first occurrence in this incident), radarr, readarr, borked-craft, hass. HA recorder had ~8h of gap (02:00–10:21) — permanent loss. |
| **10:40 AEST** | `argocd-notifications` Application found stuck in `ComparisonError` since 18 Sep (pre-existing, unrelated to this incident's trigger — root-caused and fixed later, see Chain 4). vzdump job `babc03b4` paused. |
| **11:35 AEST** | Drive replacement plan approved: bay 3 (fastest-degrading, source of the I/O latency) → bay 4 (worst cumulative history) → bay 2 (oldest); bay 1 (lowest error rate) stays. One at a time, full quiesce, re-rank before each swap. |
| **13:35 AEST** | Full quiesce for bay 3: 16 workloads scaled to 0, 3 Wazuh VMs stopped, `SyncWindow` active, rebuild priority set High. |
| **13:33:54 AEST** | Bay 3 (PMVPK19B) pulled and replaced; rebuild starts automatically. |
| **16:44 AEST** | **Bay 3 rebuild complete** (~3h10m). LD Status OK, all 4 physical drives OK, no new errors. |
| **17:58 AEST** | **pve2 host wedge begins.** ssh, NRPE, and the Proxmox web UI all stop responding simultaneously; console shows only a blinking cursor, keyboard unresponsive. Guest VMs (k8s01–03) continue running normally throughout — this is not a crash. |
| **19:40–22:30 AEST** | Operator confirms the wedge at the physical console; no hardware event in the server's IML around this time (an unrelated iLO firmware self-watchdog-reset at ~20:40 is on the BMC, not the host OS, and does not explain the symptom). Cluster remains fully quiesced. Operator decides to wait overnight rather than force a power cycle immediately. |
| **08:14–08:17 AEST 27 Sep** | With the wedge unresolved after ~14h and the cluster visibly degrading (rising guest I/O-error counts), k8s01–03 are shut down as gracefully as ssh still allows, ahead of a forced power cycle. |
| **~08:24 AEST 27 Sep** | **pve2 force power-cycled.** Boot drops to initramfs: host root filesystem needs `fsck -y` (a genuine medium error on the array is hit and remapped during this fsck). LVM thin pool `pve/data` comes up inactive. |
| **08:50 AEST 27 Sep** | Thin pool repaired (`lvconvert --repair`). **~8GB of guest writes permanently lost** (vm-100 −3.6GB, vm-112 −5.1GB) — rolled back to the pool's last durable metadata commit, a loss invisible to any later filesystem check. |
| **08:55–09:35 AEST 27 Sep** | Read-only, then supervised (`-fy`, with a per-VM rollback snapshot first) fsck of all affected guests. k8s03 hit the heaviest damage (corrupted directories, invalid extents, ~1200 directories of stale containerd image-layer content salvaged to `lost+found`). dqlite's own backend confirmed intact on all three nodes up to ~06:37 — writes between 06:37 and the shutdown are the ones the pool rollback ate. 8 Jiva replicas across k8s02/k8s03 found with unreadable `volume.meta`; sonarr and calibre-web each down to **one** good replica. |
| **09:55 AEST 27 Sep** | Sole-good replicas for sonarr and calibre-web backed up off-host to `hal` before any wipe. A `cp --sparse=always` copy of one replica's log file silently corrupted on first attempt (source re-verified stable); re-copied with `--sparse=never`, verified identical twice. |
| **10:25 AEST 27 Sep** | k8s01–03 started together. Post-boot audit finds further corruption: k8s03's microk8s snap corrupt (repaired by copying a hash-verified identical `.snap` from k8s01); k8s02's `/etc/sudoers` entirely zeroed (kubelite had been dying on every `sudo` call — restored from k8s01/k8s03, md5-verified identical); several k8s01 system binaries (`scp`, `ntfsclone`, `ntfscp`) corrupted (fixed via `apt reinstall`). |
| **12:15–12:40 AEST 27 Sep** | All 8 damaged Jiva replicas wiped and resynced, including the two single-good-replica cases (wipe one damaged replica at a time to let the controller reach quorum with good+fresh). Root cause of k8s03's stalled replicas found: `calico-node`'s own container image had 51 corrupted files inside its unpacked layer — repaired by copying verified-good files from k8s01 byte-for-byte. Full containerd content-store blob rehash across all three nodes finds and clears further corrupt blobs (an n8n image, the Jiva metrics-exporter sidecar image). |
| **13:50 AEST 27 Sep** | Staged application restore. Several apps (seerr, sabnzbd, radarr, buildkitd's local build cache) crash-loop on corrupted **unpacked** image layers or a corrupted cache database on k8s03 — a successful image pull does not guarantee an intact unpacked snapshot; fixed via image removal + re-pull (buildkitd's cache was simply wiped, no data loss, cache-only). k8s02's package integrity audit finds ~207 non-config files differing; 7 packages reinstalled. |
| **15:50 AEST 27 Sep** | Wazuh VMs audited. 111 and 113 clean. **112 (Wazuh-Server) has genuinely zeroed core libraries (`libexpat`, `libcurl`, `libcurl-gnutls`) and a fully zeroed `/var/lib/dpkg/status`** — too broad to hand-repair. Restored wholesale from the 06:10 AEST 26 Sep `vzdump` backup instead; manager state after 07:37 AEST 26 Sep is permanently lost (alert history intact — it lives on the separate indexer VM). |
| **16:30 AEST 27 Sep** | A fresh, brief RO-PVC recurrence (15:16–15:54, 8 more pods) during the vm-112 restore's own array load confirms the array is still the active hazard even with bay 3 replaced. Bay 2 (still climbing uncorrected-error count as a rebuild *survivor*, judged the riskier of the two remaining candidates) replaces bay 4 as the next swap. Full quiesce repeated. |
| **22:25 AEST 27 Sep** | **Bay 2 rebuild complete** (~5h47m). |
| **06:33–09:40 AEST 28 Sep** | **Bay 4 rebuild complete** (~3h06m). All 4 bays now hold a drive from this incident's replacement program except bay 1 (kept deliberately — lowest error rate throughout). |
| **12:35 AEST 28 Sep** | **Full restore complete**, cleanly this time — no unclean stop preceded it. All 16 workloads and all 3 Wazuh VMs verified healthy simultaneously. calibre-web's `/config` mode-000 bug recurred a **third** time (the wipe-and-resync during Jiva repair re-copied the never-permanently-fixed permission bit onto every replica); fixed again live, flagged as still needing a git-level fix. |
| **28 Sep, afternoon–evening (post-restore, not part of the outage window)** | Post-restore hardening: manual ArgoCD app-of-apps syncs (coder/sec/system) hit a recurring silent controller wedge ([homelabia#184](https://github.com/pgmac-net/homelabia/issues/184)), resolved via goroutine-dump + restart. `argocd-notifications`'s week-old ComparisonError fixed via [terraform-pvek8s#18](https://github.com/pgmac-net/terraform-pvek8s/pull/18) — its apply revealed the Application was itself a nested app-of-apps owning `coder`, `coredns-antiaffinity`, and a ConfigMap; a near-miss, caught and reversed with zero actual impact (see Chain 4). calibre-web's `/config` bug fixed permanently via [pgk8s#842](https://github.com/pgmac-net/pgk8s/pull/842)/[#843](https://github.com/pgmac-net/pgk8s/pull/843). A DMAR/IOMMU fault on pve2 found and filed as [homelabia#198](https://github.com/pgmac-net/homelabia/issues/198) (not applied — host judged too freshly stabilised to risk a reboot). |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: Seven PVCs Read-Only — Backup I/O Load on a Silently Degrading Array

##### How did seven applications lose their storage simultaneously?

Their PVCs remounted `ro,relatime` on k8s01 and k8s03 between 02:01 and 04:10 AEST. Each followed the same signature: `ping timeout of 5 secs expired` on the iSCSI session, `conn error (1022)`, then ext4 aborting its journal and remounting read-only.

##### How did the iSCSI sessions time out?

`vzdump` was reading VMs 100/102/103 off the same RAID5 array those VMs' own Jiva replicas and controllers live on. Unlike the 2026-09-15 incident, no guest-agent freeze was involved — this time, backup **read load alone** against an array already flagged CRITICAL for RAID drive health was enough to push latency past the 5-second `noop_out_timeout`.

##### How was a backup allowed to run against an array already known to be failing?

`homelabia#186` and `#187` had already documented rapidly climbing SMART grown-defect and uncorrected-error counts on two of the four drives for weeks before this incident. There is no gate that stops a scheduled backup job from running against a host with an open, active hardware-health issue — the backup job and the hardware-health tracking issue existed independently, with nothing connecting them.

##### How did recovery proceed without further incident?

The existing `jiva-ctrl-eviction-iscsi-ro-filesystem` runbook (Mode B) matched exactly and every volume recovered cleanly with its documented scale-to-zero fast path, including a correct prediction that a plain pod delete would not work on the two volumes that hit the CSI "Mode 3" stale-bind-mount stall.

→ **Actionable root cause:** SMART-trend degradation on the RAID array and the scheduling of I/O-heavy jobs against it (backups) are tracked in entirely separate places, with nothing stopping the latter from running against the former.

---

#### Chain 2: pve2 Host Wedge → Unclean Power Cycle → Multi-Layer Corruption Cascade

##### How did a routine drive rebuild turn into a two-day, multi-VM corruption incident?

74 minutes after bay 3's rebuild completed cleanly, pve2's own userland — ssh, NRPE, the Proxmox web UI — stopped responding entirely, while every guest VM kept running normally. This was a host wedge, not a crash: the hypervisor OS itself stopped functioning while its guests, backed by the same array, did not.

##### How was the wedge diagnosed?

It could not be, beyond ruling things out. The server's own event log (IML) showed no correlated hardware event — no MCE, no PCI error, no thermal or power event — anywhere near 17:58 AEST. The only log entry in the window (an iLO firmware watchdog self-reset at ~20:40) is on the management controller, not the host OS, and does not explain a host-level userland death that began over 40 minutes earlier.

##### How was the wedge resolved?

It wasn't, directly — after 14.5 hours with the console showing nothing but a blinking cursor and no remote access of any kind, the only remaining option was a forced power cycle, performed the next morning after gracefully shutting down the guest VMs first (the host itself could not be shut down gracefully, since nothing on it would respond).

##### How did that power cycle cause data loss and corruption?

The guests were stopped cleanly; the **hypervisor's own root filesystem and the LVM thin pool underneath every guest disk** were not, because the power cut happened at the host level. Both needed repair on boot. The thin-pool repair (`lvconvert --repair`) rebuilt its metadata from the last durable commit, which was **behind** where two guests' filesystems believed they were — a real, ~8GB loss with no trace visible to any subsequent filesystem check.

##### How did the damage spread beyond those two guests' missing blocks?

Above the rolled-back pool, every guest's own filesystem needed its own independent fsck, and the guest that had been doing the most I/O at power-cut time (k8s03) took the heaviest damage: corrupted directories, invalid extents, and — because container image layers and the containerd content store are just files on that same filesystem — corrupted image layers and content-store blobs that didn't surface as symptoms until something specific tried to read them, sometimes during app restore the following day. Isolated file-level zeroing (a node's `/etc/sudoers`, several system binaries, and — on the Wazuh manager VM — core libraries and the entire `dpkg` status database) followed the same mechanism at smaller scale but with more surgical, unlucky targets.

##### How was this not caught before it compounded further?

It was caught, methodically — a read-only fsck pass before any write, per-guest rollback snapshots before the real repair, a full post-boot containerd blob rehash, and a `dpkg -V` sweep on every node — which is exactly why the incident ended in a clean, fully-verified restore rather than a second undetected corruption surfacing weeks later. The gap is upstream of all of that: nothing prevented the wedge itself, and nothing short of a forced power cycle could have ended it once it happened.

→ **Actionable root cause:** the trigger for the pve2 host wedge was never identified — hardware logs show nothing, and the only available recovery path (an unclean power cycle of a hyperconverged hypervisor) is itself the mechanism that caused the data loss and corruption. This is a genuine stopping point in this incident's root-cause analysis, not a gap in the investigation.

---

#### Chain 3: calibre-web's Recurring `/config` Permission Loss — A Fix That Was Never Made Permanent

##### How did calibre-web fail on 26, 27, **and** 28 September?

Each time, identically: the pod failed its startup probe with `sqlite3.OperationalError: unable to open database file`, because its `/config` volume root was mode `000` (`d---------`).

##### How did the same bug recur three times in three days?

The calibre-web Kubernetes Deployment had no `securityContext`/`fsGroup` set — unlike sonarr's equivalent Deployment, which already had `fsGroup: 132`. With no `fsGroup`, kubelet never re-applies group-write ownership on (re)mount, so nothing corrects the permission bit once it's wrong.

##### How did the fix from the first occurrence not survive?

The 26 September fix was a live, in-cluster `chmod 755` — a workaround, not a change committed to the chart in git. It had no way to survive the next event that rebuilt the volume's file tree from scratch.

##### Why did the file tree get rebuilt from scratch, twice more?

This incident's own Jiva-repair work forced calibre-web's replica through a wipe-and-resync **twice** more (27 September, as one of the two single-good-replica repairs; 28 September, incidentally, as part of the broader replica-repair cascade). Each resync faithfully copied the mode-000 root directory onto the fresh replica along with everything else — the bug wasn't reintroduced by chance, it was carried forward mechanically by the exact procedure used to fix a different problem.

##### How was this finally closed?

By committing the fix instead of applying it live: adding a persistent `fsGroup`/`fsGroupChangePolicy` to the calibre-web chart. The first attempt at this ([pgk8s#842](https://github.com/pgmac-net/pgk8s/pull/842)) also set `runAsUser`/`runAsGroup`, which broke the image's linuxserver.io s6-overlay init (it needs to start as root to remap PUID/PGID) — caught immediately and corrected ([pgk8s#843](https://github.com/pgmac-net/pgk8s/pull/843), `fsGroup` only).

##### Was the underlying mechanism — why the root directory goes mode 000 at all — ever explained?

No. The exact same mode-000 signature was found (and left, since it's dormant there) on the `hass` Home Assistant volume, which runs its container as root and so never breaks visibly. Two unrelated volumes showing the identical, specific signature suggests something in the Jiva/CSI mount-and-chmod path itself, not independent random corruption — but this was never confirmed.

→ **Actionable root cause:** a live workaround with no path back into git is guaranteed to be undone by the next operation that touches the same data, and this incident's own recovery procedure was exactly such an operation, twice.

---

#### Chain 4: ArgoCD Controller Silent Wedge, and a Terraform Near-Miss on a Hidden App-of-Apps Dependency

##### How did a routine post-restore ArgoCD sync get stuck?

Manually syncing three app-of-apps (`coder`, `sec`, `system`) to pick up pending image updates, one sync entered `Terminating` and stopped responding to further patches — including an explicit Terminate request.

##### How did a sync operation become unresponsive to new instructions?

The application-controller's `status.operationState` had gone stale: once phase is stuck at Running/Terminating, the controller only re-evaluates that embedded snapshot ("Resuming in-progress operation") and ignores new `spec.operation` patches entirely. This required directly clearing `status.operationState` to unstick, not a normal retry.

##### How did the controller get into that state?

It had silently dropped out of its reconcile rotation — confirmed by 44 of 46 applications showing 21+ hours of stale `reconciledAt` timestamps, with no crash, restart, or error visible anywhere. This is a known, recurring, and still-unexplained failure mode of the ArgoCD application-controller in this cluster ([homelabia#184](https://github.com/pgmac-net/homelabia/issues/184)); the only known remedy — a `kill -QUIT 1` goroutine dump followed by a restart — was applied again here.

##### How, separately, was a week-old ComparisonError discovered and what happened fixing it?

While investigating the controller wedge, `argocd-notifications` was found stuck in `ComparisonError` since 18 September — a Terraform `for_each`-managed map was forcing a Helm `source.helm` block onto an Application whose upstream path had become a plain directory nine days earlier. The fix moved it out of the shared `for_each` into its own standalone Terraform resource ([terraform-pvek8s#18](https://github.com/pgmac-net/terraform-pvek8s/pull/18)).

##### How did that fix put a live production deployment at risk?

Moving a `for_each` key out of its map is a destroy-then-recreate in Terraform, not an in-place update. The **old** Application object — invisible to Terraform's own plan as anything more than "being replaced" — had itself become a nested app-of-apps, owning three other live resources via ArgoCD's own tracking-id mechanism: the `coder` Application (92 days' uptime), `coredns-antiaffinity`, and the notifications `ConfigMap`. Terraform's destroy call had to wait on ArgoCD to cascade-prune all three via the object's `resources-finalizer` before it could complete.

##### How did that wait turn into a stuck apply?

The same application-controller wedge from earlier in this chain stalled the cascade-prune mid-flight; Terraform's apply timed out after 11 minutes with the old object stuck mid-delete, `coder` and its siblings still technically referenced by a half-deleted parent.

##### How was this resolved without actually losing anything?

By verifying, before touching anything further, that nothing had actually been deleted — all three at-risk resources were still `Synced`/`Healthy` with unchanged ages — then stripping the stuck object's finalizer so the delete could complete *without* triggering the cascade-prune it was waiting on, and re-running CI. Full re-verification afterward confirmed all three children cleanly re-adopted under the new object (same tracking-id) and `coder`'s uptime unchanged at 92 days — zero actual disruption occurred.

→ **Actionable root cause:** the application-controller's own recurring silent wedge is still unexplained after multiple occurrences (tracked separately, homelabia#184), and Terraform's plan has no visibility into ownership relationships that ArgoCD creates on its own side — a `for_each` key removed from a map can silently carry a much larger, invisible blast radius than the diff suggests.

---

## Impact

### Services Affected

| Service | Impact | Duration |
| --- | --- | --- |
| media/{tautulli, sonarr, calibre-web, radarr, readarr}, minecraft/borked-craft, netconnectors/hass | 7 PVCs read-only (Chain 1) | ~6h–8h24m each (02:01/04:10 → 10:25 AEST 26 Sep) |
| netconnectors/hass (Home Assistant recorder) | ~8h of history permanently lost (02:00–10:21 AEST) | Permanent |
| media/calibre-web | `/config` mode-000 recurrence, 3rd occurrence | Fixed live 3×; permanent fix shipped post-incident |
| All 16 application workloads + 3 Wazuh VMs | Deliberately quiesced (scaled to 0 / stopped) across the drive-replacement program | ~13:35 AEST 26 Sep → 12:35 AEST 28 Sep (~47h, by design) |
| k8s01, k8s02, k8s03 (guest filesystems, container images/layers, system files) | Corruption from the unclean power cycle; repaired in place | ~08:45 AEST 27 Sep → 13:50 AEST 27 Sep active repair |
| sec/wazuh-server (VM 112) | Core libraries + `dpkg` database zeroed; restored wholesale from 26 Sep 06:10 backup | Manager state after 07:37 AEST 26 Sep lost permanently |
| pve2 host | Userland wedge (ssh/NRPE/web UI unresponsive), guests unaffected | ~17:58 AEST 26 Sep → ~08:24 AEST 27 Sep (~14h26m) |

### Duration

- **Total incident window:** ~2d 10h 34m (~02:01 AEST 26 Sep → 12:35 AEST 28 Sep)
- **Initial outage (Chain 1), detection to full recovery:** ~8h24m (02:01 → 10:25 AEST 26 Sep)
- **Host wedge:** ~14h26m (17:58 AEST 26 Sep → ~08:24 AEST 27 Sep)
- **Corruption repair + drive replacement program (Chains 2–4 hardware/software cleanup):** ~08:24 AEST 27 Sep → 12:35 AEST 28 Sep, including two further full-quiesce rebuild cycles (bay 2 ~5h47m, bay 4 ~3h06m) and their settle windows
- **Post-restore hardening (Chain 3/4 fixes):** 28 September, afternoon–evening, after service restoration — not counted in the outage window

### Scope

- **Nodes/hosts affected:** pve2 (hypervisor — host wedge, RAID array, thin pool), k8s01, k8s02, k8s03 (all three — filesystem and/or container corruption), sec/wazuh-server VM (restored from backup)
- **Data loss:** ~8GB of committed guest writes rolled back by the thin-pool repair (permanent, undetectable by filesystem check); ~8h of Home Assistant recorder history (permanent); Wazuh manager state after 07:37 AEST 26 Sep (permanent — alert history intact on the separate indexer VM). **No Jiva volume data was lost** — all 8 damaged replicas resynced from a good peer within their own volume's replication factor.
- **User-visible impact:** 7 services down for up to ~8h on 26 September; all 16 services + Wazuh unavailable by design for ~47h across the drive-replacement program.
- **Hardware changed:** 3 of 4 RAID5 physical drives replaced (bays 2, 3, 4); bay 1 deliberately kept (lowest error rate throughout).

---

## Resolution Steps Taken

### Phase 1: Initial Triage and Recovery (26 Sep, 09:20–10:40 AEST)

1. Matched Nagios findings to the `jiva-ctrl-eviction-iscsi-ro-filesystem` runbook (Mode B).
2. Recovered all 7 read-only volumes via the scale-to-zero fast path, with an ArgoCD `SyncWindow` blocking auto-sync reverts.
3. Fixed calibre-web's `/config` mode-000 live (`chmod 755`); discovered the identical dormant signature on `hass`.
4. Discovered and deferred the pre-existing `argocd-notifications` ComparisonError; paused the `vzdump` job.

### Phase 2: Drive Replacement Program (26–28 Sep)

1. Re-ranked drive health via Nagios/SMART before each swap; replaced bay 3, then bay 4's slot was superseded by bay 2 (re-ranked as riskier after a fresh RO-PVC blip during the vm-112 restore), then bay 4.
2. Each swap: full cluster quiesce (16 workloads to 0, 3 Wazuh VMs stopped, `SyncWindow` active) → pull/insert → rebuild at High priority → settle → verify → restore.
3. Bay 3 rebuilt in ~3h10m; bay 2 in ~5h47m; bay 4 in ~3h06m. Bay 1 deliberately left untouched.

### Phase 3: Host Wedge Response and Unclean-Shutdown Repair (26–27 Sep)

1. Held the wedge overnight rather than immediately forcing power off, given no console/remote access and no hardware fault evidence to act on.
2. Gracefully shut down k8s01–03 ahead of the forced pve2 power cycle.
3. Repaired the host's own root filesystem (`fsck -y`), then the LVM thin pool (`vgcfgbackup`, one `lvconvert --repair`, `vgchange -ay`).
4. Read-only fsck triage of every guest, then supervised `-fy` repair with a per-VM rollback snapshot taken first.
5. Post-boot integrity audit: microk8s snap repair, zeroed-file repair (`/etc/sudoers`, system binaries), full containerd content-store blob rehash, `dpkg -V` sweep, calico-node image-layer repair.
6. Backed up the sole-good Jiva replica for each of two volumes before wiping their damaged peers; wiped and resynced all 8 damaged replicas.
7. Restored the Wazuh-Server VM wholesale from backup once its damage was found too broad to repair in place.

### Phase 4: Post-Restore Hardening (28 Sep, after service restoration)

1. Resolved a recurring ArgoCD application-controller silent wedge (goroutine-dump + restart) blocking manual syncs.
2. Root-caused and fixed the week-old `argocd-notifications` ComparisonError via Terraform, catching and reversing a near-miss to `coder` during the apply.
3. Shipped a permanent, git-committed fix for calibre-web's recurring `/config` permission loss.
4. Filed the DMAR/IOMMU fault found on pve2 for future action, deliberately not applying the fix (an `iommu=pt` kernel change requiring a reboot) against a freshly-stabilised host.

---

## Verification

```bash
# No PVCs read-only anywhere in the cluster
kubectl --context pvek8s get pods -A --no-headers | grep -vE 'Running|Completed'
# → (empty)

# All Jiva volumes at full replication and RW
kubectl --context pvek8s get jivavolume -n openebs
# → 11/11 volumes: 3 Ready RW

# RAID array healthy on all 4 bays after the final (bay 4) rebuild
ssh pve2 "ssacli ctrl slot=0 ld 1 show; ssacli ctrl slot=0 pd all show"
# → LD1 Status: OK; all 4 physical drives: OK

# Thin pool fully active, no residual repair artifacts before cleanup
ssh pve2 "lvs -a pve"
# → pve/data 'twi-a-tz--' active; data_meta0 kept until fleet-wide stability confirmed

# Containerd content-store integrity, post-repair
for d in $(sudo ctr -n k8s.io content ls -q); do
  sudo ctr -n k8s.io content get "$d" 2>/dev/null | sha256sum | grep -q "${d#sha256:}" \
    || echo "CORRUPT: $d"
done
# → (no output on any node)

# Home Assistant recorder writing again
sqlite3 /config/home-assistant_v2.db "PRAGMA integrity_check;"
# → ok

# ArgoCD fleet fully synced post-hardening
kubectl --context pvek8s get applications -n argocd -o \
  custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status \
  | grep -vE 'Synced.*Healthy'
# → (empty, 46/46)
```

---

## Preventive Measures

### Immediate Actions Required

1. **Investigate the unexplained pve2 host userland wedge** (High)
   - Chain 2. Root cause never identified; hardware logs show nothing. This is the single event that turned a routine drive swap into a two-day corruption incident.
   - Issue: [pgmac-net/homelabia#199](https://github.com/pgmac-net/homelabia/issues/199)

2. **Add a persistent permission fix to the `hass` Helm chart** (Medium)
   - Chain 3 (same signature, dormant). The identical mode-000 volume-root pattern exists on `hass` and is currently harmless only because Home Assistant runs as root.
   - Issue: [pgmac-net/pgk8s#844](https://github.com/pgmac-net/pgk8s/issues/844)

### Longer-Term Improvements

3. **Check for hidden ArgoCD ownership before removing a Terraform `for_each` key** (Medium)
   - Chain 4. A destroy+recreate on a `for_each`-managed Application can carry an invisible blast radius through ArgoCD's own tracking-id ownership graph, which Terraform's plan cannot see.
   - Issue: [pgmac-net/terraform-pvek8s#19](https://github.com/pgmac-net/terraform-pvek8s/issues/19)

4. **Fix or route around the `terraform test` crash on failing assertions** (Low)
   - Discovered during Chain 4's fix. An upstream Terraform bug (`panic: ... value has marks`) crashes the human-readable diagnostic output on any failing test in a repo using sensitive variables, making CI failures unreadable.
   - Issue: [pgmac-net/terraform-pvek8s#20](https://github.com/pgmac-net/terraform-pvek8s/issues/20)

5. **Replace pve2 bay 1 and resolve the array's persistent Unrecoverable-Media-Errors flags** (Low)
   - Chain 1/2. Bay 1 is the last original drive (deliberately deferred this incident — lowest error rate). Separately, the LD has carried "Unrecoverable Media Errors: Detected" / "Parity Initialization: Initialization Failed" / "Last Surface Scan Completed: False" through all three rebuilds; unclear whether these self-clear now every other bay is fresh or need explicit action.
   - Issue: [pgmac-net/homelabia#200](https://github.com/pgmac-net/homelabia/issues/200)

Already resolved during this incident, no further issue needed:
- `argocd-notifications` ComparisonError — [terraform-pvek8s#18](https://github.com/pgmac-net/terraform-pvek8s/pull/18), merged and fully verified.
- calibre-web `/config` permanent fix — [pgk8s#842](https://github.com/pgmac-net/pgk8s/pull/842)/[#843](https://github.com/pgmac-net/pgk8s/pull/843), merged.
- pve2 DMAR/IOMMU fault — already filed as [homelabia#198](https://github.com/pgmac-net/homelabia/issues/198) during this incident.
- ArgoCD controller silent wedge — recurring, tracked at [homelabia#184](https://github.com/pgmac-net/homelabia/issues/184); this incident's occurrence logged there, not duplicated here.
- `docker-registry-frontend` PR — open, operator reviewing directly; no incident-tracking issue needed.

---

## Lessons Learned

### What Went Well

- The `jiva-ctrl-eviction-iscsi-ro-filesystem` and `jiva-replica-corrupt-snapshot-chain` runbooks both matched exactly and their documented procedures (scale-to-zero fast path, the ≥2-RW wipe gate) worked without modification, even under a corruption event severe enough to leave two volumes with only one good replica each.
- A read-only fsck pass, per-guest rollback snapshots, and a full post-boot containerd blob rehash — none of them shortcuts — caught corruption that would otherwise have surfaced as unexplained crash-loops days later, as it briefly did anyway for seerr/sabnzbd/radarr/buildkitd during app restore.
- Two self-caught mistakes were corrected before they caused harm: a `cp --sparse=always` copy that silently corrupted one file was caught by checksum re-verification before the source backup was trusted, and a bash NUL-byte scan that falsely flagged several intact `/etc` files (a command-substitution trailing-newline artifact) was caught before any of them were "repaired."
- The decision to hold the host wedge overnight rather than force a power cycle immediately, and to quiesce the entire cluster before every drive swap, meant the eventual corruption was confined to what an unclean power cycle does to an idle, already-drained system — not to live application writes in flight.
- The Terraform near-miss on `coder` was caught by verifying actual cluster state before taking any further action, rather than trusting the apply's own failure message — the finalizer strip was applied only after confirming nothing had actually been pruned.

### What Didn't Go Well

- The RAID array's known, actively-tracked degradation (homelabia#186/#187) did not stop a backup job from running against it, which is what triggered the entire incident.
- The pve2 host wedge gave no actionable diagnostic signal of any kind — no hardware event, no useful log line — leaving "wait and see, then force power off" as the only available response.
- calibre-web's `/config` fix was applied live three separate times across three days before it was finally committed to git; the same operational shortcut (fix now, commit later) cost real repeat effort each time the underlying data was rebuilt.
- The `argocd-notifications` ComparisonError had already been silently broken for over a week before this incident surfaced it — it was found only because unrelated post-restore work happened to touch ArgoCD.

### Surprise Findings

- Backup **read load alone**, with no guest-agent freeze at all, was sufficient to push iSCSI past its 5-second ping timeout on an already-degraded array — confirming and extending the 2026-09-15 PIR's finding that freeze isn't a precondition, just an additional risk factor.
- An LVM thin-pool repair after an unclean shutdown can roll back guest writes by an amount no filesystem check will ever surface — the only way to detect it at all was comparing `Data%` against a pre-incident baseline.
- Corruption from a single unclean power cycle reached four distinct layers of the stack independently — host root fs, LVM thin-pool metadata, guest ext4 metadata, and container image layers/content-store blobs — each needing its own detection and repair method; no single check would have found all of it.
- Two apparently unrelated volumes (`calibre-web`, `hass`) showed the identical, oddly specific mode-000-on-volume-root corruption signature, suggesting a shared mechanism in the Jiva/CSI mount path rather than independent random corruption — never confirmed, but too specific a coincidence to dismiss.
- A Terraform `for_each` key removal — a change that looked, in the plan output, like replacing one Application with an equivalent one — was actually a destroy of an object that had quietly become a parent app-of-apps for three other live, unrelated resources, entirely outside Terraform's own visibility.

---

## Action Items

| # | Action | Priority | GitHub |
| --- | --- | --- | --- |
| 1 | Investigate the unexplained pve2 host userland wedge | High | [pgmac-net/homelabia#199](https://github.com/pgmac-net/homelabia/issues/199) |
| 2 | Add persistent fsGroup/permission fix to the `hass` Helm chart | Medium | [pgmac-net/pgk8s#844](https://github.com/pgmac-net/pgk8s/issues/844) |
| 3 | Check for hidden ArgoCD ownership before Terraform `for_each` key removal on managed Applications | Medium | [pgmac-net/terraform-pvek8s#19](https://github.com/pgmac-net/terraform-pvek8s/issues/19) |
| 4 | Fix/route around the `terraform test` crash on failing assertions with sensitive variables | Low | [pgmac-net/terraform-pvek8s#20](https://github.com/pgmac-net/terraform-pvek8s/issues/20) |
| 5 | Replace pve2 bay 1; resolve the array's persistent Unrecoverable-Media-Errors flags | Low | [pgmac-net/homelabia#200](https://github.com/pgmac-net/homelabia/issues/200) |
| 6 | New runbook: pve2 unclean-shutdown thin-pool + guest fsck recovery; extend Jiva replica runbook for single-good-replica quorum wipes | Done | This PR |

---

## Technical Details

### Environment

- Cluster: pvek8s (microk8s), 3 nodes (k8s01/02/03), dqlite datastore, calico CNI, containerd
- Storage: OpenEBS Jiva via `openebs-jiva-csi-default`, `replicationFactor: 3`, 11 volumes
- Hypervisor: pve2, ProLiant DL380 G7, Smart Array P410i firmware 6.64, 4×300GB SAS 10K RAID5 (`/dev/sda`, 838GB), LVM thin-pool `pve/data` backing all guest disks
- All three k8s node VMs and all three Wazuh VMs (111 Indexer, 112 Server/Manager, 113 Dashboard) run on this single array

### Key Error Signatures

```text
# Chain 1 — RO PVC trigger (no guest-agent freeze involved this time)
connection16:0: ping timeout of 5 secs expired, recv timeout 5, last rx ...
connection16:0: detected conn error (1022)
EXT4-fs error (device sdX): ext4_journal_check_start:61: Detected aborted journal

# Chain 2 — host wedge (no corresponding hardware log entry found)
kex_exchange_identification: read: Connection reset by peer     # ssh to pve2
# NRPE: Could not connect ... Connection reset by peer
# console: blinking cursor only, keyboard unresponsive

# Chain 2 — thin pool after forced power cycle
Check of pool pve/data failed (status:1). Manual repair required!
# lvs pve/data → twi---tz-- (inactive, no 'a')

# Chain 2 — guest fsck
Detected aborted journal ; needs_recovery
invalid extent node (blk N, lblk N)
block bitmap does not match checksum

# Chain 3 — calibre-web /config permission loss (identical on all 3 occurrences)
sqlite3.OperationalError: unable to open database file
# /config: d--------- abc:abc

# Chain 4 — ArgoCD stuck operation state
# status.operationState.phase stuck at Running/Terminating, ignores new spec.operation patches
kubectl patch application <name> --type merge -p '{"status":{"operationState":null}}'
```

### Ordering the Thin-Pool Repair Safely

```bash
ssh pve2 "systemctl stop pvestatd"                       # stop the 15s activation-retry storm
ssh pve2 "vgcfgbackup -f /root/pve-vg-\$(date +%Y%m%d) pve"
ssh pve2 "lvconvert --repair --yes pve/data"              # ONE attempt only
ssh pve2 "vgchange -ay pve"
# Compare Data% per guest LV against a pre-incident baseline — any drop
# is a permanent, otherwise-undetectable data loss figure.
```

### Discriminating Corrupted Blobs From Corrupted Unpacked Layers

```bash
# A successful image pull only proves the compressed blob is intact —
# it says nothing about the unpacked snapshot a crash-looping pod reads from.
for d in $(sudo ctr -n k8s.io content ls -q); do
  sudo ctr -n k8s.io content get "$d" 2>/dev/null | sha256sum | grep -q "${d#sha256:}" \
    || echo "CORRUPT BLOB: $d"
done
# For a pod crash-looping with "Exec format error" or a missing symbol on
# an image that pulled cleanly, remove and re-pull anyway — the damage is
# in the unpacked layer, not the blob this check covers.
```

---

## References

- Runbook: [pve2-unclean-shutdown-thinpool-fsck-recovery.md](../runbooks/pve2-unclean-shutdown-thinpool-fsck-recovery.md) — new, this PIR
- Runbook: [jiva-replica-corrupt-snapshot-chain.md](../runbooks/jiva-replica-corrupt-snapshot-chain.md) — extended, single-good-replica quorum wipe procedure
- Runbook: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md) — matched and used for Chain 1
- PIR: [pvek8s Triple Replica Fault — Proxmox Backup fs-freeze, Corrupt Snapshot Chains, and an Orphaned Pod Route](2026-09-15-vzdump-fsfreeze-jiva-replica-triple-fault.md) — established backup I/O load as an iSCSI hazard on this array
- Issue: [pgmac-net/homelabia#184](https://github.com/pgmac-net/homelabia/issues/184) — recurring ArgoCD application-controller silent wedge (Chain 4)
- Issue: [pgmac-net/homelabia#186](https://github.com/pgmac-net/homelabia/issues/186), [#187](https://github.com/pgmac-net/homelabia/issues/187) — pve2 RAID5 degradation, pre-dating and triggering this incident
- Issue: [pgmac-net/homelabia#198](https://github.com/pgmac-net/homelabia/issues/198) — pve2 DMAR/IOMMU fault, found during this incident
- PR: [pgmac-net/terraform-pvek8s#18](https://github.com/pgmac-net/terraform-pvek8s/pull/18) — `argocd-notifications` fix and near-miss (Chain 4)
- PR: [pgmac-net/pgk8s#842](https://github.com/pgmac-net/pgk8s/pull/842), [#843](https://github.com/pgmac-net/pgk8s/pull/843) — calibre-web permanent permission fix (Chain 3)
- Incident tracking: [pgmac-net/incidents#89](https://github.com/pgmac-net/incidents/issues/89)
