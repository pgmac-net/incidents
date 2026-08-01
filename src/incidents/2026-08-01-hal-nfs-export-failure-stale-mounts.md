---
tags:
  - k8s01
  - k8s02
  - k8s03
  - nfs
  - hal
  - storage
  - monitoring
  - microk8s
---

# Post Incident Review: hal NFS Export Failure — Cluster-Wide Stale Mounts and a 7h Detection Gap

**Date:** 2026-08-01
**Duration:** ~8h 5m total (~02:59 AEST → ~11:04 AEST); ~7h 17m undetected, ~48m active remediation
**Severity:** High (12 pods across 3 namespaces lost their storage; one user-visible outage; SQLite data-integrity exposure)
**Status:** Resolved

---

## Executive Summary

At approximately 02:59 AEST the NFS export layer on `hal.int.pgmac.net` (172.22.22.2, QNAP NAS) failed in a partial and unusually deceptive way: `rpcbind` (port 111) and `rpc.mountd` (port 30000) stopped accepting connections while `nfsd` continued listening on port 2049. The host stayed fully reachable — ping, SSH, HTTPS and the QNAP web UI all responded normally throughout.

The consequence was two-sided. `nfsd` had re-exported, invalidating every outstanding file handle, so all 18 NFS mounts across k8s01, k8s02 and k8s03 returned `Stale file handle`. And because `rpcbind` and `mountd` were gone, no client could establish a fresh mount to recover. This covered `hal:/Qmultimedia`, `hal:/Qdownload`, `hal:/backups`, `hal:/Qmultimedia/Calibre` and all nine `172.22.22.2:/k8s-pvc/*` CSI volumes.

Twelve pods across `media`, `sec` and `netconnectors` lost their storage. Every one of them continued to report `Running` and `Ready` for the entire outage, because their liveness and readiness probes are TCP or HTTP checks against already-warm processes that never touch the filesystem. Home Assistant's recorder retried a failed SQLite commit every three seconds for over seven hours; Tautulli and sabnzbd threw `Errno 116` and `disk I/O error` continuously. None of this raised an alert.

The single alert that fired was `books.int.pgmac.net` host DOWN at 03:34 AEST — the Calibre content server, whose `/config` volume is a direct NFS mount from hal. It presented as `CRITICAL - Socket timeout`: the server accepted TCP on port 8081 and then never responded, because serving a book requires reading the library metadata from a dead mount. Nothing in that alert pointed at storage, and nothing pointed at hal.

hal itself was monitored by a PING check and nothing else — zero service definitions. PING passed continuously, so the NAS showed green while its entire storage role was down. The incident was found only when the Nagios alert list was reviewed manually at 10:16 AEST and the `books` outage was traced back through the ingress, to the pod, to the mount, to the RPC layer. Recovery was straightforward once the cause was known: restart NFS on hal, remount `/mnt/backups` per node, verify SQLite integrity on the three databases that had been written through stale handles, then restart the affected workloads to clear their stale file descriptors. All three databases returned `ok`. `books` returned to UP at 11:04 AEST.

---

## Timeline (AEST — UTC+10)

| Time | Event |
| --- | --- |
| **~02:59 AEST** | hal NFS export layer fails. First stuck Home Assistant recorder transaction (`last_reported_ts=1785517157`). All NFS file handles across the cluster become stale. |
| **03:23 AEST** | Last successful Nagios check of `books.int.pgmac.net`. |
| **03:34 AEST** | `books.int.pgmac.net` enters HARD DOWN, `CRITICAL - Socket timeout`, 10/10 attempts. Slack notification sent. |
| **03:34 – 09:34 AEST** | Four notifications sent for `books` over ~6h. No other alert fires. HA recorder continues retrying every 3s. hal remains green (PING only). |
| **10:16 AEST** | Nagios alert list reviewed. Unhandled problems: `books` DOWN (unacknowledged), three acknowledged `reboot` CRITICALs, `microk8s-kine-reconnect-failures` CRITICAL on k8s03 + WARNING on k8s01/k8s02, `microk8s-dqlite-scheduler` WARNING on all three nodes. |
| **~10:20 AEST** | `books.int.pgmac.net` resolves to all three node IPs — an ingress host, not a real host. `curl` confirms TCP connect in 0.013s then hang to 15s timeout. HTTP/:80 returns 308 instantly; TLS handshake completes; certificate valid. Failure is behind the ingress. |
| **~10:23 AEST** | Watch-cache freeze ruled out: `resourceVersion=0` read returns rv `11661223` against quorum `11661313` — 90 revisions behind, healthy. `readyz` passes. dqlite live `database is locked` rate over the prior 60 min measured at 0 / 2 / 0 across the three nodes. kine and dqlite alerts classified as noise. |
| **~10:28 AEST** | `calibre-64dc8fd5c4-x8mvd` on k8s03: `Running`, `1/1`, 0 restarts, 18d uptime. Probes are TCP on :8080 (Selkies GUI); the ingress backend is :8081 (content server). Probes cannot see the failure. Pod produced zero log output in 12h. |
| **~10:31 AEST** | Direct pod curl to `10.1.235.136:8081` hangs for 10s — confirms the backend, not the ingress. |
| **~10:33 AEST** | Privileged `stat` on the pod's config mount returns `Stale file handle`. Confirmed from inside the container: `ls: unknown io error: '/config', StaleNetworkFileHandle`. **Root cause identified.** |
| **~10:35 AEST** | Cluster-wide sweep. First attempt run unprivileged returns `Permission denied` on pod-scoped mounts — a false signal, corrected by re-running with `sudo`. **All 18 NFS mounts on all three nodes confirmed `Stale file handle`.** |
| **~10:37 AEST** | hal port scan: 22, 443, 2049, 8080 open; **111 and 30000 refused**. `rpcinfo -t hal.int.pgmac.net nfs 3` → `RPC: Remote system error - Connection refused`. `showmount -e` → `clnt_create: RPC: Unable to receive`. Fresh mount fails: `portmap query failed`. |
| **~10:40 AEST** | Blast radius established: 12 pods across `media`/`sec`/`netconnectors`. Live failures confirmed in HA (`sqlite3.OperationalError: disk I/O error`, `OSError: [Errno 116]`), Tautulli and sabnzbd. Nagios host `hal` confirmed to have PING check and zero services. |
| **~10:47 AEST** | Six GitHub Issues raised for the incident and the monitoring gaps. Leftover diagnostic pod `media/curltest-books` deleted. |
| **~10:50 AEST** | NFS restarted on hal (QNAP Control Panel). Ports 111 and 30000 accepting again. `rpcinfo` → `program 100003 version 3 ready and waiting`. `showmount -e` lists all exports. Fresh test mount of `/Qmultimedia` succeeds. |
| **~10:52 AEST** | `/mnt/backups` force-unmounted and remounted on k8s01, k8s02, k8s03. Full privileged re-sweep: **all 18 mounts OK** — the pod-scoped mounts self-revalidated without intervention. |
| **~10:53 AEST** | Affected pods still erroring despite healthy mounts — `OSError: [Errno 9] Bad file descriptor`. Confirms stale FDs held by long-lived processes; restarts required. |
| **~10:55 AEST** | SQLite integrity checks via read-only mounts. `home-assistant_v2.db` (40.8 MB) → `ok`. `sabnzbd history1.db` (2.97 MB) → `ok`. `tautulli.db` (16.6 MB) → `ok` (first attempt failed with `unable to open database file` — an artifact of the read-only mount, resolved by copying the DB first). Vaultwarden found to hold **no SQLite database** on either PVC — external DB backend, never at risk. |
| **~10:56 AEST** | Home Assistant statefulset restarted. New pod scheduled to k8s02. Recorder logs `Ended unfinished session (id=81 from 2026-07-29)` and `could not validate that the sqlite3 database was shutdown cleanly` — expected post-ESTALE, integrity already confirmed. |
| **~10:58 AEST** | Remaining 10 workloads rolling-restarted: trivy-server, tautulli, sabnzbd, linkace + scheduler, vaultwarden, sonarr, radarr, readarr, calibre (last). |
| **~10:59 AEST** | Nagios catches `books` mid-rollout: `HTTP CRITICAL: HTTP/1.1 503 Service Temporarily Unavailable`. Transient. |
| **~11:00 AEST** | All rollouts complete. Stale/IO error count since restart: **0 across all 11 pods**. All endpoints responding. |
| **11:04 AEST** | `books.int.pgmac.net` returns to UP: `HTTP OK: HTTP/1.1 200 OK - 3888545 bytes in 0.053 second response time`. Zero unhandled host problems in Nagios. kine and dqlite alerts cleared on their own, confirming they were threshold artifacts. |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: `books.int.pgmac.net` Host DOWN — Calibre Content Server Wedged on a Dead Mount

##### How did `books.int.pgmac.net` go DOWN with `CRITICAL - Socket timeout`?

The Nagios host check is `check_http -H books.int.pgmac.net --ssl`. The TCP connection established in 13ms and the TLS handshake completed with a valid certificate, but no HTTP response ever arrived. The check timed out after 10s.

##### How did the server accept a connection and then never respond?

`books.int.pgmac.net` is not a host — it is an ingress (`media/calibre-webserver`) routing to the `calibre-webserver` service on port 8081, backed by pod `calibre-64dc8fd5c4-x8mvd`. Curling the pod IP directly on :8081 reproduced the identical 10s hang, placing the fault in the pod, not the ingress or the service.

##### How did the pod accept TCP on :8081 but never serve a response?

Port 8081 is the Calibre content server, which runs inside the `/opt/calibre/bin/calibre` desktop process. The listening socket stayed open — the process was alive and its accept queue functional — but serving any request requires reading the Calibre library metadata database from `/config`.

##### How did reading `/config` fail?

`/config` is a direct NFS mount of `hal.int.pgmac.net:/Qmultimedia/Calibre`. It had gone stale. From inside the container: `ls: unknown io error: '/config', Os { code: 116, kind: StaleNetworkFileHandle }`. Every request blocked on I/O that could never complete.

##### How did the pod stay `Running` and `1/1 Ready` for over seven hours with dead storage?

The pod's liveness, readiness and startup probes are all `tcp-socket :8080` — the Selkies web GUI port, not the content server on :8081, and a TCP check regardless. A TCP probe against a live process cannot detect an application wedged on filesystem I/O. Kubernetes had no signal, so it never restarted the pod: 0 restarts across 18 days.

##### How was there no detection that the content server specifically was broken?

`books.int.pgmac.net` was in fact the *only* thing that detected the wider outage — but it detected it as an application host being down, with no indication of storage or of hal. The probe misalignment (:8080 probed, :8081 served) meant Kubernetes' own health machinery was blind, leaving a single external HTTP check as the sole signal.

**→ ACTIONABLE ROOT CAUSE:** Probes target a different port than the ingress backend, so Kubernetes cannot detect content-server failure. Compounded by the absence of any storage-layer monitoring that would have named the real cause.

---

#### Chain 2: All 18 Cluster NFS Mounts Stale — hal RPC Layer Partial Failure

##### How did every NFS mount on all three nodes go stale simultaneously?

`nfsd` on hal restarted and re-exported its filesystems, which invalidates every previously issued NFS file handle. Clients holding those handles receive `ESTALE` on any subsequent operation.

##### How did the mounts not simply recover, as they normally would after a server restart?

Because the RPC layer did not come back with `nfsd`. A port scan showed 2049 open but **111 (`rpcbind`) and 30000 (`rpc.mountd`) refusing connections**. Remounting requires the portmapper to locate `mountd` and `mountd` to issue a fresh file handle. With both gone, recovery was impossible from the client side:

```
mount.nfs: portmap query failed: RPC: Unable to receive - Connection refused
```

##### How did `nfsd` survive while `rpcbind` and `mountd` did not?

They are separate services on the QNAP appliance. `nfsd` holds its listening socket on 2049 independently of the portmapper. This produces the deceptive state at the heart of this incident: the port most people would check is the one that stays up.

##### How did this failure state look healthy to every check we had?

hal responded to ICMP, SSH (22), HTTPS (443) and the QNAP web UI (8080) throughout. Only two ports out of everything exposed were affected, and neither is one a generic host check would test.

##### How was the RPC layer's failure not detected on the hal side?

Nagios host `hal` (`nagios-config/objects/pgmac.net/servers.cfg:21`) is defined with `check_ping` and **zero service definitions**. There was no check on 111, on 2049, on mountd, or on export reachability. The host's entire monitored surface was "does it respond to ping".

##### How did hal come to be monitored by PING alone despite being the storage backend for 12 workloads?

hal is a QNAP appliance rather than a Linux host running NRPE, so it never received the service-check treatment the k8s nodes and servers did. Its criticality — nine CSI PVs plus four direct NFS exports — grew over time without a corresponding growth in monitoring.

**→ ACTIONABLE ROOT CAUSE:** No monitoring of hal's NFS service layer. A port check on 2049 alone would not have caught this; detection requires `rpcinfo`/`showmount` and an export-freshness `stat`.

---

#### Chain 3: 7h 17m Undetected — Pod Health Signals Cannot See Storage

##### How did a total storage outage affecting 12 pods go undetected for over seven hours?

Every affected pod reported `Running` and `Ready` for the entire duration. `kubectl get pods` showed a completely healthy cluster.

##### How did 12 pods with dead storage all report Ready?

Their liveness and readiness probes are TCP or HTTP checks against long-running processes. Those processes were alive and their sockets accepting. A probe that does not perform a filesystem operation cannot observe that the filesystem is gone.

##### How did the applications themselves not surface the failure?

They did — into their own logs, where nothing was watching. Home Assistant logged `sqlite3.OperationalError: disk I/O error` and `OSError: [Errno 116] Stale file handle` on a 3-second retry loop for 7+ hours. Tautulli and sabnzbd logged continuously. Tautulli accumulated 5 restarts and sabnzbd 2, and even those restart counts raised no alert.

##### How was there no check comparing pod-reported health against actual storage health?

No NRPE check sweeps `mount -t nfs` for stale handles on the nodes. Such a check would have fired on all three nodes simultaneously within minutes, and — unlike the `books` alert — would have named the cause directly.

##### How was the one alert that did fire not recognised as a storage incident?

`books.int.pgmac.net` presented as a single application host being down. Its `notes_url` points at the control-plane watch-cache-freeze runbook, which is unrelated. There was no signal connecting it to hal or to NFS, and no other app alerted alongside it to suggest a common cause.

##### How was the signal further obscured?

The alert list at 10:16 AEST contained `microk8s-kine-reconnect-failures` CRITICAL on k8s03 plus WARNINGs on the other two nodes, and `microk8s-dqlite-scheduler` WARNING on all three. All were measured to be noise — the watch cache was 90 revisions behind quorum (healthy) and the live dqlite lock-error rate was 0/2/0 — but they presented as the more severe, more cluster-wide problem and drew attention first.

**→ ACTIONABLE ROOT CAUSE:** No storage-layer health check independent of application probes, and persistent alert noise that made the one true signal look less important than the false ones.

---

#### Chain 4: Alert Noise Masked the Real Signal — Permanently-WARNING dqlite Check

##### How did `microk8s-dqlite-scheduler` show WARNING on all three nodes during an unrelated incident?

`check_microk8s_dqlite.sh` scales its thresholds to the observation window (lines 127–128):

```bash
CRIT_SCALED=$(("$CRITICAL_THRESHOLD" * "${TIME_WINDOW}" / 24)); [ "$CRIT_SCALED" -lt 1 ] && CRIT_SCALED=1
WARN_SCALED=$(("$WARNING_THRESHOLD" * "${TIME_WINDOW}" / 24)); [ "$WARN_SCALED" -lt 1 ] && WARN_SCALED=1
```

With the deployed `-w 10 -c 100` over a 4h window: `WARN_SCALED = 10 * 4 / 24 = 1`.

##### How does a warn threshold of 1 produce a permanent WARNING?

The background rate of `database is locked` across the cluster is 37–54 per 24h. A threshold of one error in four hours is effectively always met. At the time of the incident the nodes reported 4, 4 and 3 lock errors — all below the CRIT scale of 16, all above a warn scale of 1.

##### How did this survive a previous fix for exactly this problem?

The comment immediately above those lines documents the same failure mode being fixed:

> multiply before dividing: integer math made W/24 truncate to 0 for small thresholds and short windows, turning the check into a permanent WARNING

The multiply-before-divide correction was applied to both lines, but the `-lt 1` floor was left on the WARN line, reintroducing the identical outcome through a different mechanism.

##### How was a permanently-WARNING check not noticed and corrected?

A check that is always warning stops being read. It becomes background texture in the alert list rather than a signal. Nobody re-examined it because its state never changed.

##### How did this contribute to this incident's duration?

It did not cause the outage, but it consumed triage attention at 10:16 AEST. Three WARNING services and one CRITICAL service on the control plane presented as the dominant problem next to a single application host being down. Ruling them out took roughly seven minutes of the investigation before attention turned to `books`.

**→ ACTIONABLE ROOT CAUSE:** Threshold logic produces a permanent WARNING, degrading the alert list's signal-to-noise ratio and slowing triage during unrelated incidents.

---

## Impact

### Services Affected

| Service | Impact | Duration |
| --- | --- | --- |
| `books.int.pgmac.net` (calibre content server) | Complete outage — accepted TCP, never responded | ~7h 41m (03:23 → 11:04) |
| `netconnectors/hass-home-assistant-0` | Recorder unable to commit; failed SQLite write retried every 3s | ~8h (02:59 → ~10:57) |
| `media/tautulli` | `Errno 116` on all storage access; 5 restarts | ~8h |
| `media/sabnzbd` | `disk I/O error`; downloads unwritable; 2 restarts | ~8h |
| `media/linkace` + scheduler | Logs and backups PVCs stale | ~8h |
| `media/sonarr`, `radarr`, `readarr` | Media and downloads mounts stale | ~8h |
| `sec/vaultwarden` | `/data` + `/files` mounts stale (icon cache, sends, RSA key). Vault DB is external — unaffected | ~8h |
| `sec/trivy-server` | Data PVC stale | ~8h |
| `netconnectors/n8n` | PVC stale | ~8h |
| `/mnt/backups` (k8s01, k8s02, k8s03) | Host-level backup target stale on all nodes | ~8h |

### Duration

- **Total incident window:** ~8h 5m (02:59 → 11:04 AEST)
- **Undetected as a storage incident:** ~7h 17m (02:59 → 10:16 AEST)
- **Active investigation:** ~19m (10:16 → 10:35 AEST, symptom to root cause)
- **Active remediation:** ~14m (10:50 → 11:04 AEST, hal restored to `books` UP)
- **Expected recovery time with this runbook:** ~15 min

### Scope

- **Nodes affected:** all three (k8s01, k8s02, k8s03) — every NFS mount on every node
- **Data loss:** none. All three SQLite databases written through stale handles returned `PRAGMA integrity_check` = `ok`
- **Data at risk:** yes — HA recorder, Tautulli and sabnzbd databases were written through invalid file handles for ~8h
- **User-visible impact:** `books.int.pgmac.net` fully down. Other applications served cached/read paths and appeared functional, masking the extent
- **Not affected:** the microk8s control plane (watch cache, dqlite and API server were verified healthy throughout), Vaultwarden's vault data (external DB), all non-hal-backed workloads

---

## Resolution Steps Taken

### Phase 1: Diagnosis

1. Reviewed unhandled Nagios problems. Separated the acknowledged/known (three `reboot` CRITICALs, four acknowledged DOWN hosts) from the actionable (`books` DOWN, kine/dqlite alerts).
2. Ruled out the control-plane alerts before pursuing them, per the dqlite triage rule of measuring the live rate first:

   ```bash
   kubectl --context pvek8s get --raw='/api/v1/pods?resourceVersion=0&limit=1'   # rv 11661223
   kubectl --context pvek8s get --raw='/api/v1/pods?limit=1'                     # rv 11661313
   # → 90 revisions behind — watch cache healthy, not frozen
   ```

   Live `database is locked` rate over the prior 60 min: 0 / 2 / 0 across the nodes. Both alert classes classified as noise.

3. Established that `books.int.pgmac.net` resolves to all three node IPs — an ingress, not a host. Characterised the failure: TCP connect in 13ms, TLS handshake valid, no HTTP response, 15s timeout. HTTP on :80 returned 308 instantly, isolating the fault to the HTTPS backend path.
4. Traced ingress → service → endpoint → pod. Curled the pod IP directly on :8081 and reproduced the hang, ruling out ingress and service.
5. Noted the probe misalignment: probes are `tcp-socket :8080`, ingress backend is :8081. Pod had produced zero log output in 12h.
6. `stat`'d the pod's config mount and found `Stale file handle`; confirmed from inside the container. **Root cause found.**
7. Swept all NFS mounts cluster-wide. The first sweep ran unprivileged and returned `Permission denied` on pod-scoped mounts — a false reading, since those paths are root-only. Re-ran with `sudo`:

   ```bash
   mount -t nfs | awk '{print $1" "$3}' | while read src m; do
     r=$(timeout 6 sudo stat "$m" 2>&1 >/dev/null)
     [ -z "$r" ] && echo "OK    |$src" || echo "STALE |$src|$m"
   done
   ```

   All 18 mounts on all three nodes stale.

8. Diagnosed hal. Port scan showed 2049 open but 111 and 30000 refused; `rpcinfo` and `showmount` both failed; a fresh mount attempt failed at the portmap query. Confirmed `nfsd` alive, RPC layer dead.
9. Enumerated blast radius (12 pods, 9 hal-backed PVs) and confirmed live failures in HA, Tautulli and sabnzbd logs. Confirmed Nagios host `hal` had no service definitions.

### Phase 2: Fix

1. **hal (performed by operator):** NFS restarted via QNAP Control Panel → Network & File Services → NFS. Verified from k8s03:

   ```bash
   rpcinfo -t hal.int.pgmac.net nfs 3    # → program 100003 version 3 ready and waiting
   showmount -e hal.int.pgmac.net        # → all exports listed
   ```

2. Remounted `/mnt/backups` on each node in turn (fstab-managed, not kubelet-managed, so it does not self-heal):

   ```bash
   sudo umount -f /mnt/backups || sudo umount -l /mnt/backups
   sudo mount /mnt/backups
   ```

3. Re-ran the privileged sweep. All 18 mounts OK — the pod-scoped mounts self-revalidated with no intervention, because the export generation matched. No lazy unmounts were needed.
4. Confirmed that healthy mounts had **not** healed the running processes: pods still logged `OSError: [Errno 9] Bad file descriptor`. Restarts required.
5. Ran SQLite integrity checks before allowing any writes, via read-only NFS mounts of the relevant PVC exports. Copying each DB off the read-only mount first was necessary — running `sqlite3` directly against it fails with `unable to open database file`, which is a mount artifact and not corruption:

   ```bash
   sudo mount -t nfs -o vers=3,ro 172.22.22.2:/k8s-pvc/<pvc> /tmp/ic
   sudo cp /tmp/ic/<db> /tmp/copy.db
   sudo sqlite3 /tmp/copy.db "PRAGMA integrity_check;"   # → ok
   ```

   `home-assistant_v2.db` `ok`, `tautulli.db` `ok`, `sabnzbd history1.db` `ok`. Vaultwarden's PVCs were found to contain no SQLite database at all — only `rsa_key.pem`, `icon_cache/`, `sends/` — with `DATABASE_URL` pointing at an external DB server.

6. Rolling-restarted the affected workloads, stateful first, calibre last:

   ```bash
   kubectl --context pvek8s -n netconnectors rollout restart statefulset hass-home-assistant
   kubectl --context pvek8s -n sec rollout restart statefulset/trivy-server deployment/vaultwarden
   kubectl --context pvek8s -n media rollout restart deployment/{tautulli,sabnzbd,linkace,linkace-scheduler,sonarr,radarr,readarr,calibre}
   ```

### Phase 3: Verification

1. Confirmed all rollouts complete and all pods `Running` and fully ready.
2. Counted stale/IO errors across all 11 restarted pods since restart: 0.
3. Probed every affected ingress endpoint.
4. Confirmed `books.int.pgmac.net` returned to UP in Nagios and that the unhandled-problem list was clear of host problems.
5. Deleted the diagnostic pod `media/curltest-books` created during investigation.

---

## Verification

```bash
# All NFS mounts healthy on every node (must be privileged — unprivileged stat returns EACCES)
mount -t nfs | awk '{print $3}' | while read m; do timeout 6 sudo stat "$m" >/dev/null 2>&1 || echo "STALE $m"; done
# → (empty on k8s01, k8s02, k8s03)

# hal RPC layer serving
rpcinfo -t hal.int.pgmac.net nfs 3
# → program 100003 version 3 ready and waiting

# No stale/IO errors in any previously affected pod
kubectl --context pvek8s -n netconnectors logs hass-home-assistant-0 --since=8m \
  | grep -icE "stale file handle|Errno 116|disk I/O error"
# → 0

# All pods Running and fully ready
kubectl --context pvek8s -n media get pods --no-headers | grep -v Completed \
  | awk '{split($2,a,"/"); if ($3!="Running" || a[1]!=a[2]) print}'
# → (empty)

# The acceptance test
curl -s -o /dev/null -w "%{http_code}\n" -m 20 -k https://books.int.pgmac.net/
# → 200
```

Nagios confirmation:

```
books.int.pgmac.net: HTTP OK: HTTP/1.1 200 OK - 3888545 bytes in 0.053 second response time
```

---

## Preventive Measures

### Immediate Actions Required

1. **Add hal NFS service checks to Nagios** (High)
    - Chain 2 and Chain 3. hal is the storage backend for 12 workloads and was monitored by PING alone. A port check on 2049 would **not** have caught this failure — `nfsd` stayed up. Detection requires `check_rpc` against portmapper (111) and mountd, plus an export-freshness check that `stat`s a known path under each of `/Qmultimedia`, `/Qdownload`, `/backups`, `/k8s-pvc`.
    - Issue: [pgmac-net/nagios-config#32](https://github.com/pgmac-net/nagios-config/issues/32)

2. **Add node-side NRPE check for stale NFS mounts** (High)
    - Chain 3. This is the check that would have fired on all three nodes simultaneously and named the cause directly, rather than surfacing as one unrelated-looking application outage. Must run privileged — pod-scoped mounts under `/var/snap/microk8s/common/var/lib/kubelet/pods/` are root-only, and an unprivileged `stat` returns `EACCES`, which is indistinguishable from healthy if only the exit code is checked.
    - Issue: [pgmac-net/ansible#243](https://github.com/pgmac-net/ansible/issues/243)

3. **Document the hal NFS recovery runbook** (High)
    - Chains 2 and 3. No NFS runbook existed — every storage runbook covers jiva/OpenEBS CSI. Several recovery steps are non-obvious and cost time during this incident.
    - Issue: [pgmac-net/incidents#67](https://github.com/pgmac-net/incidents/issues/67) — satisfied by [hal NFS Export Failure](../runbooks/hal-nfs-export-failure.md)

4. **Fix `check_microk8s_dqlite.sh` WARN threshold flooring** (Medium)
    - Chain 4. `WARN_SCALED` floors to 1, making WARNING permanent against a 37–54/24h background rate. This is the same failure mode the code comment claims was already fixed. A permanently-warning check degrades the whole alert list.
    - Issue: [pgmac-net/ansible#244](https://github.com/pgmac-net/ansible/issues/244)

### Longer-Term Improvements

5. **Align kine check documentation and add burst tolerance** (Medium)
    - Chain 4. `services.cfg` notes read "warn at 2 failures in 10min, crit at 5" while the deployed command is `-w 8 -c 15 -t 10` — the runbook text an on-call reads is wrong by 3–4x. Separately, a single 10-second burst (14 errors at 00:07:54 UTC) trips CRITICAL against a 2–4/10min baseline while the control plane is provably healthy.
    - Issue: [pgmac-net/nagios-config#33](https://github.com/pgmac-net/nagios-config/issues/33)

6. **Investigate and monitor k8s01 image filesystem pressure** (Medium)
    - Discovered incidentally. kubelet image GC has failed 289 times in 24h with `freed 0 bytes` — every image is referenced, so GC can never succeed. Unmonitored, and the loudest repeating error in the k8s01 journal, which makes real problems harder to spot.
    - Issue: [pgmac-net/ansible#245](https://github.com/pgmac-net/ansible/issues/245)

7. **Raise journald retention on the k8s nodes** (Low)
    - Retention is ~24h; kubelite alone writes ~36k lines/day. This directly caused a wrong conclusion mid-incident — a daily error count reading `0` for six days and `467` on the seventh looked like a sharp regression but was a retention artifact, and had to be retracted.
    - Issue: [pgmac-net/ansible#246](https://github.com/pgmac-net/ansible/issues/246)

8. **Review probe/backend port alignment across ingress-backed workloads** (Medium)
    - Chain 1. Calibre's probes target :8080 while its ingress backend is :8081, so Kubernetes could not detect the content server failing. Worth auditing whether other workloads have probes pointed at a different port than the one actually serving traffic.
    - Tracked under: [pgmac-net/homelabia#153](https://github.com/pgmac-net/homelabia/issues/153)

---

## Lessons Learned

### What Went Well

- **Measuring the live error rate before acting on the control-plane alerts.** The kine CRITICAL and dqlite WARNINGs looked like the dominant problem. Testing the watch cache (`resourceVersion=0` vs quorum — 90 revisions, healthy) and measuring the live dqlite lock rate (0/2/0) ruled both out in about seven minutes and prevented an unnecessary and risky dqlite/kubelite restart on a healthy control plane.
- **Following the failure down the stack rather than restarting the visible thing.** Ingress → service → endpoint → pod → mount took ~19 minutes from symptom to confirmed root cause. Restarting the calibre pod first would have appeared to fix `books` while leaving 11 other pods silently broken and hal still down.
- **Checking data integrity before restarting anything.** Three SQLite databases had been written through invalid file handles for ~8h. Verifying `integrity_check` before allowing writes was cheap and made the restart decision evidence-based rather than hopeful.
- **The one alert that existed did its job**, even though it pointed at the wrong layer. Without the `books` HTTP check, the outage would likely have run until someone tried to use an affected service.

### What Didn't Go Well

- **The first cluster-wide mount sweep was run unprivileged**, returning `Permission denied` on the pod-scoped mounts. That is indistinguishable from a stale handle if only the exit code is checked, and it briefly produced an inflated picture of the blast radius. Corrected by re-running with `sudo`, but it is a trap worth documenting.
- **A daily error-count trend was misread as a new-onset regression.** Six days of `0` followed by `467` looked like a sharp change; it was journal retention (~24h), and those days held two log lines total. The finding had to be retracted mid-investigation.
- **Triage attention went to the noisier alerts first.** Three WARNINGs and a CRITICAL on the control plane presented as more significant than a single application host being DOWN. The permanently-warning dqlite check has been eroding this alert list's usefulness for some time.
- **The `books` service definition's `notes_url` points at the control-plane watch-cache-freeze runbook**, which is unrelated to how this failure actually presented. An on-call following that link would have been sent in the wrong direction.
- **Seven hours of Home Assistant recorder retry loops produced no alert.** Application-level error rates are not monitored at all.

### Surprise Findings

- **`nfsd` can stay listening on 2049 while `rpcbind` and `mountd` are dead.** The port most likely to be checked is the one that survives. Any NFS health check built on a TCP probe of 2049 would have reported healthy throughout this entire incident.
- **Healthy mounts do not heal running processes.** After every mount verified clean, Home Assistant and sabnzbd still threw `Errno 9 Bad file descriptor` — long-lived processes hold dead file descriptors across the recovery. A mount sweep alone reads as "recovered" and is not.
- **Stale pod-scoped mounts self-revalidated** once hal's exports returned, with no lazy unmount and no kubelet intervention, because the export generation matched. The anticipated hard part of the recovery did not materialise.
- **12 pods reported `Running` and `1/1 Ready` for eight hours with completely dead storage.** TCP and HTTP probes against warm processes are structurally incapable of detecting storage failure.
- **Vaultwarden's vault is not on hal.** Both its PVCs hold only `rsa_key.pem`, `icon_cache/` and `sends/`; `DATABASE_URL` points at an external DB server. It was identified early as the highest-stakes unrecoverable risk and turned out not to be at risk at all — worth knowing before the next storage incident.
- **Tautulli restarted 5 times and sabnzbd twice during the outage**, and neither restart count triggered anything.

---

## Action Items

| # | Action | Priority | GitHub |
| --- | --- | --- | --- |
| 1 | Add hal NFS service checks (rpcbind/mountd/nfsd + export freshness) | High | [pgmac-net/nagios-config#32](https://github.com/pgmac-net/nagios-config/issues/32) |
| 2 | Add node-side NRPE check sweeping `mount -t nfs` for stale handles | High | [pgmac-net/ansible#243](https://github.com/pgmac-net/ansible/issues/243) |
| 3 | Document hal NFS export failure and stale mount recovery runbook | High | [pgmac-net/incidents#67](https://github.com/pgmac-net/incidents/issues/67) |
| 4 | Fix `check_microk8s_dqlite.sh` WARN_SCALED flooring to 1 | Medium | [pgmac-net/ansible#244](https://github.com/pgmac-net/ansible/issues/244) |
| 5 | Align kine check notes with deployed thresholds; add burst tolerance | Medium | [pgmac-net/nagios-config#33](https://github.com/pgmac-net/nagios-config/issues/33) |
| 6 | Investigate and monitor k8s01 image GC failure | Medium | [pgmac-net/ansible#245](https://github.com/pgmac-net/ansible/issues/245) |
| 7 | Raise journald `SystemMaxUse` on k8s nodes | Low | [pgmac-net/ansible#246](https://github.com/pgmac-net/ansible/issues/246) |
| 8 | Incident tracking and probe/backend port alignment review | High | [pgmac-net/homelabia#153](https://github.com/pgmac-net/homelabia/issues/153) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03)
- **Kubernetes version:** v1.35.0
- **OS:** Ubuntu 20.04.6 LTS, kernel 5.4.0-231-generic
- **Container runtime:** containerd 2.1.3
- **Storage backend:** `hal.int.pgmac.net` (172.22.22.2), QNAP NAS, NFSv3
- **Affected exports:** `/Qmultimedia`, `/Qmultimedia/Calibre`, `/Qdownload`, `/backups`, `/k8s-pvc` (9 CSI PVs)
- **Calibre image:** `linuxserver/calibre:9.11.0`

### Key Error Signatures

Client-side, from any node:

```
mount.nfs: portmap query retrying: RPC: Unable to receive
mount.nfs: portmap query failed: RPC: Unable to receive - Connection refused
clnt_create: RPC: Unable to receive
hal.int.pgmac.net: RPC: Remote system error - Connection refused
```

Stale handle on a mountpoint:

```
stat: cannot stat '/var/snap/microk8s/common/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~nfs/config': Stale file handle
```

From inside an affected container:

```
ls: unknown io error: '/config', Os { code: 116, kind: StaleNetworkFileHandle, message: "Stale file handle" }
OSError: [Errno 116] Stale file handle
sqlite3.OperationalError: disk I/O error
```

After the mount recovers but before the pod is restarted:

```
OSError: [Errno 9] Bad file descriptor
```

Nagios, for the only alert that fired:

```
books.int.pgmac.net: CRITICAL - Socket timeout
```

### Diagnostic Procedure

```bash
# 1. Is the NFS server's RPC layer alive? (Do NOT rely on a TCP check of 2049 — nfsd survives.)
rpcinfo -t hal.int.pgmac.net nfs 3
showmount -e hal.int.pgmac.net
for p in 111 2049 30000; do
  timeout 4 bash -c "echo >/dev/tcp/172.22.22.2/$p" 2>/dev/null && echo "$p OPEN" || echo "$p refused"
done

# 2. Sweep every NFS mount on the node for stale handles — MUST be privileged
mount -t nfs | awk '{print $1" "$3}' | while read src m; do
  r=$(timeout 6 sudo stat "$m" 2>&1 >/dev/null)
  [ -z "$r" ] && echo "OK    |$src" || echo "STALE |$src|$m"
done

# 3. Enumerate hal-backed PVs to establish blast radius
kubectl --context pvek8s get pv -o json \
  | python3 -c 'import json,sys; [print(p["metadata"]["name"], p["spec"].get("claimRef",{}).get("namespace"), p["spec"].get("claimRef",{}).get("name")) for p in json.load(sys.stdin)["items"] if "172.22.22.2" in json.dumps(p["spec"]) or "hal.int" in json.dumps(p["spec"])]'
```

### Recovery Procedure

```bash
# 1. Restore NFS on hal (QNAP Control Panel → Network & File Services → NFS), then verify
rpcinfo -t hal.int.pgmac.net nfs 3    # → program 100003 version 3 ready and waiting

# 2. Remount fstab-managed host mounts on each node (kubelet does not manage these)
sudo umount -f /mnt/backups || sudo umount -l /mnt/backups
sudo mount /mnt/backups

# 3. Re-sweep. Pod-scoped mounts normally self-revalidate if the export generation matches.

# 4. Integrity-check SQLite DBs BEFORE restarting anything that writes.
#    Copy off the ro mount first — sqlite3 against a ro NFS mount fails with
#    "unable to open database file", which is a mount artifact, not corruption.
sudo mount -t nfs -o vers=3,ro 172.22.22.2:/k8s-pvc/<pvc> /tmp/ic
sudo cp /tmp/ic/<db> /tmp/copy.db
sudo sqlite3 /tmp/copy.db "PRAGMA integrity_check;"   # → ok

# 5. Restart affected workloads — healthy mounts do NOT clear stale file descriptors
kubectl --context pvek8s -n <ns> rollout restart <kind>/<name>
```

---

## References

- GitHub Issue: [pgmac-net/homelabia#153](https://github.com/pgmac-net/homelabia/issues/153) — incident tracking
- GitHub Issue: [pgmac-net/nagios-config#32](https://github.com/pgmac-net/nagios-config/issues/32) — hal NFS service checks
- GitHub Issue: [pgmac-net/nagios-config#33](https://github.com/pgmac-net/nagios-config/issues/33) — kine check notes drift and burst tolerance
- GitHub Issue: [pgmac-net/ansible#243](https://github.com/pgmac-net/ansible/issues/243) — stale NFS mount NRPE check
- GitHub Issue: [pgmac-net/ansible#244](https://github.com/pgmac-net/ansible/issues/244) — dqlite WARN threshold flooring
- GitHub Issue: [pgmac-net/ansible#245](https://github.com/pgmac-net/ansible/issues/245) — k8s01 image GC failure
- GitHub Issue: [pgmac-net/ansible#246](https://github.com/pgmac-net/ansible/issues/246) — journald retention
- GitHub Issue: [pgmac-net/incidents#67](https://github.com/pgmac-net/incidents/issues/67) — this runbook
- Runbook: [hal NFS Export Failure — Cluster-Wide Stale Mounts](../runbooks/hal-nfs-export-failure.md)

---

## Reviewers

- @pgmac
