---
title: "hal NFS failure (export loss / handle invalidation)"
tags:
  - runbook
  - nfs
  - hal
  - storage
  - microk8s
---

# hal NFS Failure — Export Loss and Handle Invalidation

**Service:** `hal.int.pgmac.net` (172.22.22.2, QNAP NAS) — NFS backend for `pvek8s`
**First observed:** 2026-08-01 (Mode 1), 2026-08-15 (Mode 2), 2026-11-15 (Mode 3)
**PIR:** [hal NFS Export Failure — Cluster-Wide Stale Mounts and a 7h Detection Gap](../incidents/2026-08-01-hal-nfs-export-failure-stale-mounts.md)
**PIR:** [hal NFS Handle Invalidation — Silent SQLite Failures Across Three Services and a 2.7-Day Detection Gap](../incidents/2026-08-15-hal-nfs-handle-invalidation-silent-sqlite-failures.md)
**PIR:** [hal rpc.mountd OOM Kill — Cluster-Wide Stale NFS Mounts and a 4-Hour Overnight Gap](../incidents/2026-11-15-hal-mountd-oom-kill-stale-mounts.md)

---

## Symptom

Applications backed by hal write `Stale file handle` / `Errno 116` / `disk I/O error` into their own logs continuously, and nothing watches those logs.

Meanwhile **everything looks healthy**:

- `kubectl get pods` shows all pods `Running` and `1/1 Ready` with low or zero restart counts
- hal responds to ping, SSH, HTTPS and the QNAP web UI
- the microk8s control plane is fine — watch cache current, dqlite quiet

In Mode 1 the applications also hang: they accept TCP connections and never respond, and Nagios reports the affected ingress host DOWN with `CRITICAL - Socket timeout`. In Mode 2 they keep serving normally and only their database or log writes are dead, so **nothing external looks wrong at all**.

!!! warning "Probes cannot see this"
    TCP and HTTP probes against a long-running process never touch the filesystem. A pod with completely dead storage will report `Ready` indefinitely. During the 2026-08-01 incident, 12 pods reported healthy for eight hours; during 2026-08-15, Home Assistant reported healthy while recording no history for 2.7 days.

## 3 Distinct Root Causes

Modes 1 and 2 start the same way: hal invalidates previously issued NFS file handles. They differ in whether the RPC layer survives, and that changes the whole recovery path. Mode 3 is different again: `nfsd` keeps running, but `rpc.mountd` dies, and mounts go stale about 25 minutes later when nfsd's export caches expire.

**Check all three of these first, not `rpcinfo` alone:**

```bash
rpcinfo -t hal.int.pgmac.net nfs 3          # nfsd
timeout 10 showmount -e hal.int.pgmac.net   # mountd actually answering
for p in 111 2049 30000; do timeout 4 bash -c "echo >/dev/tcp/172.22.22.2/$p" 2>/dev/null && echo "$p OPEN" || echo "$p refused"; done
```

| `rpcinfo nfs 3` | `showmount -e` | 111 / 30000 | Mode |
| --- | --- | --- | --- |
| error | error | refused / refused | 1: export loss |
| ready | exports listed | open / open | 2: handle invalidation (nothing to fix on hal) |
| ready | `RPC: Unable to receive; errno = Connection refused` | open / **refused** | 3: mountd killed |

!!! warning "`rpcinfo` alone misreads Mode 3 as Mode 2"
    In Mode 3, `rpcinfo -t … nfs 3` succeeds and `rpcinfo -p` still lists `mountd` (a dead process's stale portmapper registration). Only `showmount -e` and port 30000 show that mountd is gone.

---

## Failure Mode 1 — Export Loss (RPC layer down)

### When it occurs

`nfsd` restarts and re-exports, and `rpcbind`/`mountd` fail to come back with it. Mounts break cluster-wide; applications hang.

### Context

`nfsd` on hal restarts and re-exports its filesystems, which invalidates every previously issued NFS file handle. Clients holding those handles get `ESTALE` on any subsequent operation.

Normally clients would recover by remounting. In this failure mode they cannot, because `rpcbind` (port 111) and `rpc.mountd` (port 30000) do **not** come back with `nfsd`. They are separate services on the QNAP appliance, and `nfsd` holds its listening socket on 2049 independently of the portmapper.

This produces the deceptive state at the heart of the failure: **the port you would think to check is the one that stays up**. A TCP health check against 2049 reports healthy throughout. Remounting requires the portmapper to locate `mountd`, and `mountd` to issue a fresh file handle — with both gone, recovery is impossible from the client side.

Applications fail in proportion to how much they touch disk. Ones serving cached or static content look fine; ones doing SQLite writes (Home Assistant recorder, Tautulli, sabnzbd) fail immediately and loudly into their logs.

---

### Detection

```bash
# Is the RPC layer alive? Run from any k8s node.
rpcinfo -t hal.int.pgmac.net nfs 3
# → healthy:  program 100003 version 3 ready and waiting
# → broken:   hal.int.pgmac.net: RPC: Remote system error - Connection refused

showmount -e hal.int.pgmac.net
# → healthy:  Export list for hal.int.pgmac.net: /Qmultimedia /Qdownload /backups /k8s-pvc ...
# → broken:   clnt_create: RPC: Unable to receive

# Port-level confirmation. Note 2049 stays OPEN in this failure mode.
for p in 111 2049 30000; do
  timeout 4 bash -c "echo >/dev/tcp/172.22.22.2/$p" 2>/dev/null && echo "$p OPEN" || echo "$p refused"
done
# → broken:   111 refused / 2049 OPEN / 30000 refused
```

Sweep every NFS mount on each node for stale handles:

```bash
mount -t nfs | awk '{print $1" "$3}' | while read src m; do
  r=$(timeout 6 sudo stat "$m" 2>&1 >/dev/null)
  [ -z "$r" ] && echo "OK    |$src" || echo "STALE |$src|$m"
done
```

!!! danger "This sweep must run privileged"
    Pod-scoped mounts under `/var/snap/microk8s/common/var/lib/kubelet/pods/` are root-only. An unprivileged `stat` returns `Permission denied`, which is **indistinguishable from a stale handle** if you only check the exit code — and it will also make healthy mounts look broken. Always use `sudo`.

Establish the blast radius:

```bash
kubectl --context pvek8s get pv -o json | python3 -c '
import json,sys
for p in json.load(sys.stdin)["items"]:
    if "172.22.22.2" in json.dumps(p["spec"]) or "hal.int" in json.dumps(p["spec"]):
        c = p["spec"].get("claimRef", {})
        print(p["metadata"]["name"], c.get("namespace"), c.get("name"))'
```

---

### Recovery

1. **Restore NFS on hal.** QNAP Control Panel → Network & File Services → NFS: toggle off, apply, toggle on. Verify from a k8s node before going any further — nothing downstream will work until this is true:

   ```bash
   rpcinfo -t hal.int.pgmac.net nfs 3
   # → program 100003 version 3 ready and waiting

   showmount -e hal.int.pgmac.net | grep -E "Qmultimedia|Qdownload|k8s-pvc|backups"
   # → all four exports listed
   ```

2. **Prove a fresh mount works** before touching anything else:

   ```bash
   sudo mkdir -p /tmp/nfsprobe
   sudo timeout 20 mount -t nfs -o vers=3,ro hal.int.pgmac.net:/Qmultimedia /tmp/nfsprobe
   sudo ls /tmp/nfsprobe | head -5
   sudo umount /tmp/nfsprobe && sudo rmdir /tmp/nfsprobe
   ```

3. **Remount fstab-managed host mounts** on each node — k8s01, then k8s02, then k8s03. These are not kubelet-managed and will not self-heal:

   ```bash
   sudo umount -f /mnt/backups || sudo umount -l /mnt/backups
   sudo mount /mnt/backups
   sudo stat /mnt/backups
   # → no "Stale file handle"
   ```

4. **Re-run the privileged sweep** from Detection on all three nodes. Pod-scoped mounts normally self-revalidate with no intervention once exports return, provided the export generation matches — during the 2026-08-01 incident all 18 mounts recovered on their own at this point. Only if a mount is still stale:

   ```bash
   sudo umount -l <mountpoint>   # kubelet re-establishes it on the next pod start
   ```

5. **Integrity-check SQLite databases before restarting anything that writes.** Any app that was mid-write during the outage has been writing through invalid file handles. Mount the PVC export read-only and copy the DB off before checking — running `sqlite3` directly against a read-only NFS mount fails with `unable to open database file`, which is a mount artifact and **not** corruption:

   ```bash
   sudo mkdir -p /tmp/ic
   sudo mount -t nfs -o vers=3,ro 172.22.22.2:/k8s-pvc/<pvc-name> /tmp/ic
   sudo find /tmp/ic -maxdepth 4 \( -name "*.db" -o -name "*.sqlite*" \) -printf "%s\t%p\n"
   sudo cp /tmp/ic/<db> /tmp/copy.db
   sudo sqlite3 /tmp/copy.db "PRAGMA integrity_check;"
   # → ok
   sudo rm -f /tmp/copy.db; sudo umount /tmp/ic; sudo rmdir /tmp/ic
   ```

   Databases worth checking: Home Assistant `home-assistant_v2.db` (highest write volume, highest risk), Tautulli `tautulli.db`, sabnzbd `admin/history1.db`.

   If any check returns something other than `ok`: **stop**, copy the database aside, and recover that application individually. The HA recorder DB can be rebuilt if it comes to that.

6. **Restart the affected workloads.** Healthy mounts do **not** heal running processes — long-lived processes hold dead file descriptors across the recovery and will keep failing with `OSError: [Errno 9] Bad file descriptor` until restarted.

   Stateful first, then the rest, with the alerting application last so its recovery is the final confirmation:

   ```bash
   kubectl --context pvek8s -n netconnectors rollout restart statefulset hass-home-assistant
   kubectl --context pvek8s -n netconnectors rollout status statefulset hass-home-assistant --timeout=300s

   kubectl --context pvek8s -n sec rollout restart statefulset/trivy-server deployment/vaultwarden
   kubectl --context pvek8s -n media rollout restart \
     deployment/tautulli deployment/sabnzbd deployment/linkace deployment/linkace-scheduler \
     deployment/sonarr deployment/radarr deployment/readarr deployment/calibre
   ```

7. **Clean up any diagnostic pods** created during the investigation.

---

### Verification

Recovery is complete when all of the following hold:

```bash
# No stale mounts on any node
mount -t nfs | awk '{print $3}' | while read m; do
  timeout 6 sudo stat "$m" >/dev/null 2>&1 || echo "STALE $m"
done
# → (empty on k8s01, k8s02, k8s03)

# No stale/IO errors in any previously affected pod since its restart
kubectl --context pvek8s -n <ns> logs <pod> --since=8m \
  | grep -icE "stale file handle|Errno 116|disk I/O error|Bad file descriptor"
# → 0

# All pods Running and fully ready
kubectl --context pvek8s -n media get pods --no-headers | grep -v Completed \
  | awk '{split($2,a,"/"); if ($3!="Running" || a[1]!=a[2]) print}'
# → (empty)

# Every affected endpoint responds
for u in warden hass automation linkace tautulli sabnzbd sonarr radarr readarr books calibre; do
  printf "%-12s " "$u"
  curl -s -o /dev/null -w "http=%{http_code} t=%{time_total}s\n" -m 20 -k "https://$u.int.pgmac.net/"
done
# → no http=000 (that is a timeout); 200/302/303/401 are all fine
```

Finally, confirm in Nagios that the alerting host has returned to UP. Expect something like:

```
books.int.pgmac.net: HTTP OK: HTTP/1.1 200 OK - 3888545 bytes in 0.053 second response time
```

!!! note "Expected post-recovery log noise"
    Home Assistant will log `could not validate that the sqlite3 database was shutdown cleanly` and `Ended unfinished session (id=N from <date>)` on first start. This is expected after an `ESTALE` crash and is not a problem if `PRAGMA integrity_check` returned `ok` in step 5.

---

## Failure Mode 2 — Handle Invalidation (RPC layer intact)

### When it occurs

hal invalidates previously-issued file handles — an `nfsd` re-export that changes the export generation — but `rpcbind`, `mountd`, `nfsd`, `nlockmgr` and `statd` all stay up. Mounts keep working. Fresh lookups succeed. **Only descriptors that were already open are dead**, and they stay dead until the process is restarted.

This mode is far quieter than Mode 1 and can run for days. It cost 2.7 days of Home Assistant recorder history on 2026-08-15 with no alert at any point.

### Detection

The whole diagnosis rests on one contrast: the path works, the process's descriptors do not.

```bash
POD=<affected-pod>; NS=<namespace>

# 1. RPC layer healthy? If yes, this is Mode 2, not Mode 1 - do not touch hal.
rpcinfo -p 172.22.22.2 | grep -E "mountd|nfs|nlockmgr|status"
# → all registered = Mode 2

# 2. Mount alive from inside the pod? Both of these SUCCEED in Mode 2.
kubectl --context pvek8s -n $NS exec $POD -- df -h /config
kubectl --context pvek8s -n $NS exec $POD -- sh -c 'touch /config/.writetest && echo WRITE OK && rm -f /config/.writetest'

# 3. Is the database actually damaged? A fresh connection answers in one command.
kubectl --context pvek8s -n $NS exec $POD -- python3 -c \
  "import sqlite3;c=sqlite3.connect('<db-path>');print(c.execute('PRAGMA quick_check').fetchone())"
# → ('ok',)  = the file is fine and the process's descriptors are not
```

A healthy read on the exact path the running process cannot read **is** the signature. Confirm it directly:

```bash
kubectl --context pvek8s -n $NS exec $POD -- sh -c \
  'for p in $(ls /proc | grep -E "^[0-9]+$"); do
     n=$(ls -l /proc/$p/fd 2>/dev/null | grep -c "(deleted)")
     [ "${n:-0}" -gt 0 ] && { echo "pid=$p deleted_fds=$n"
       ls -l /proc/$p/fd 2>/dev/null | grep "(deleted)" | sed "s/.*-> //" | sort -u; }
   done'
# → e.g. pid=7 deleted_fds=10  →  /config/admin/history1.db (deleted)

kubectl --context pvek8s -n $NS exec $POD -- dd if=/proc/7/fd/11 bs=16 count=1
# → dd: failed to open '/proc/7/fd/11': Stale file handle
```

!!! danger "`(deleted)` is not proof on its own, and its absence does not clear a pod"
    A descriptor shows `(deleted)` only when the inode was unlinked. A handle invalidated by re-export can be stale without that marker — Home Assistant's recorder had **no** `(deleted)` descriptors while failing every commit. Always corroborate with the application's own error signature.

Find every other victim before declaring the incident over — the failure follows the PVC, so victims are spread across nodes and namespaces:

```bash
kubectl --context pvek8s get pvc -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName --no-headers \
  | grep nfs-csi

kubectl --context pvek8s -n <ns> logs <pod> | grep -ciE "stale file handle|Errno 116|disk I/O error"
# → anything above 0 needs a restart
```

### Recovery

There is nothing to fix on hal and nothing to remount. Restart each affected workload — that is the entire fix, because only a restart re-opens the descriptors.

```bash
kubectl --context pvek8s -n media rollout restart deployment/sabnzbd
kubectl --context pvek8s -n media rollout status deployment/sabnzbd --timeout=180s

# StatefulSet pods: delete the pod, then wait for it to come back
kubectl --context pvek8s -n netconnectors delete pod hass-home-assistant-0
kubectl --context pvek8s -n netconnectors wait --for=condition=Ready pod/hass-home-assistant-0 --timeout=300s
```

Restart order does not matter — the services are independent. Check for an active workload first if it matters to you (sabnzbd: confirm `queue10.sab` is ~20 bytes, meaning an empty queue).

### Verification

```bash
# No error signatures since restart
kubectl --context pvek8s -n <ns> logs <pod> | grep -ciE "disk I/O error|stale file handle|Errno 116"
# → 0

# No stale descriptors remaining
kubectl --context pvek8s -n <ns> exec <pod> -- sh -c 'ls -l /proc/1/fd /proc/7/fd 2>/dev/null | grep -c "(deleted)"'
# → 0

# The database file is being written again - mtime must be current, not frozen
kubectl --context pvek8s -n <ns> exec <pod> -- sh -c 'date; ls -la <db-path>'
```

Home Assistant specifically: a successful restart checkpoints the WAL, so `home-assistant_v2.db-wal` collapses from megabytes to a few KB. It will also log `could not validate that the sqlite3 database was shutdown cleanly` and `Ended unfinished session` on first start — expected after an `ESTALE` crash, not a problem.

### Context

SQLite reports `ESTALE` on read as `sqlite3.OperationalError: disk I/O error`, which reads like corruption and is not. Python's `RotatingFileHandler` reports it as `OSError: [Errno 116] Stale file handle` from `self.stream.tell()`. Neither library re-opens on failure: SQLite holds its descriptor for the life of the connection, the log handler for the life of the handler. Both retry the *operation*, forever, against a descriptor that can never succeed.

Applications with several connections can be partly alive — sabnzbd kept writing new history rows through a fresh connection while ten cached read descriptors were dead, which makes "the database is being written to" a misleading health signal.

A related but **separate** problem surfaces once the stale descriptors are cleared: `sqlite3.OperationalError: database is locked` on writes. That is SQLite's byte-range locking running over NLM on NFSv3 (`local_lock=none`), where lock latency exceeds Python's 5s default busy timeout. It is not a stale handle and a restart will not fix it — the fix is moving the database off NFS onto block storage.

---

## Failure Mode 3 — mountd Killed (nfsd Alive)

### When it occurs

`rpc.mountd` on hal dies, most likely killed by the OOM killer, and nothing restarts it. `nfsd` and the portmapper keep running. On 2026-11-15 the OOM killer took mountd at `total-vm:520116kB` after about 106 days of uptime on a 256 MB appliance.

### Context

The kernel `nfsd` validates client file handles against export and auth caches that it fills by upcall to `rpc.mountd`. Cached entries keep working until they expire. After that, nfsd cannot revalidate a handle and clients get `ESTALE`. So mounts stay healthy for a while after mountd dies (25 minutes on 2026-11-15), then go stale node by node. No remount is possible, because remounting needs mountd. Unlike Mode 1, the handles themselves were never invalidated: once mountd is back, **every mount revalidates by itself**.

Nagios fires `nfs-mountd` (port 30000 refused) within one check interval, long before any mount goes stale. If that alert is the first one, you are looking at Mode 3 and have about 25 minutes to fix it before clients notice.

### Detection

```bash
# From any k8s node. nfsd alive, mountd not:
rpcinfo -t hal.int.pgmac.net nfs 3
# → program 100003 version 3 ready and waiting
timeout 10 showmount -e hal.int.pgmac.net
# → rpc mount export: RPC: Unable to receive; errno = Connection refused
for p in 111 2049 30000; do timeout 4 bash -c "echo >/dev/tcp/172.22.22.2/$p" 2>/dev/null && echo "$p OPEN" || echo "$p refused"; done
# → 111 OPEN / 2049 OPEN / 30000 refused

# On hal: is mountd running, and was it OOM-killed? (capture dmesg early: the ring buffer wraps within hours)
ssh hal 'ps | grep -c "[r]pc.mountd"; dmesg | grep -E "Out of memory|Killed process"'
# → 0
# → Killed process NNNNN (rpc.mountd) total-vm:520116kB, anon-rss:31852kB, ...
```

Blast radius: use the privileged stat sweep from Mode 1. Expect **all** hal mounts stale once the cache has expired, including `/mnt/backups` on every node.

### Recovery

1. **Restart NFS on hal** from the shell (the QNAP UI toggle from Mode 1 also works):

    ```bash
    ssh hal '/etc/init.d/nfs restart'
    ```

    This also restarts nfsd and starts a 90-second NFSv4 grace period. It did not disrupt v3 clients on 2026-11-15.

2. **Verify mountd** from a k8s node, then prove a fresh mount:

    ```bash
    timeout 10 showmount -e hal.int.pgmac.net | grep -E "Qmultimedia|Qdownload|k8s-pvc|backups"
    # → all four exports listed
    sudo mkdir -p /tmp/nfsprobe && sudo timeout 20 mount -t nfs -o vers=3,ro hal.int.pgmac.net:/Qmultimedia /tmp/nfsprobe && sudo ls /tmp/nfsprobe | head -3; sudo umount /tmp/nfsprobe; sudo rmdir /tmp/nfsprobe
    ```

3. **Re-run the privileged stat sweep.** Mounts should all be OK without a remount. Only if one is still stale, follow Mode 1 steps 3–4.

4. **Find processes still holding dead descriptors.** Do not restart everything: on 2026-11-15 only 1 of 9 workloads needed it. Open each NFS-path descriptor in each affected pod:

    ```bash
    kubectl --context pvek8s -n <ns> exec <pod> -- sh -c 'for p in $(ls /proc | grep -E "^[0-9]+$"); do for f in /proc/$p/fd/*; do t=$(readlink $f 2>/dev/null); case "$t" in /config*|/downloads*|/media*|/books*|/data*|/home/scanner*) dd if=$f bs=1 count=0 2>&1 | grep -qi stale && echo "STALE pid=$p $t";; esac; done; done; echo probe-done'
    # → probe-done                                   (clean)
    # → STALE pid=1 /home/scanner/.cache/trivy/...   (restart this one)
    ```

    Add each app's own mount prefix to the `case` pattern if it differs.

5. **Restart only the pods the probe flags**, after the SQLite integrity check from Mode 1 step 5 for any that write SQLite.

    !!! warning "trivy-server: cold start can crash-loop"
        If trivy's DB aged during the outage, a restart triggers a full ~1.7 GB DB download that outlasts its liveness probe (no startupProbe in chart 0.7.0; pgmac-net/pgk8s#1108). If it crash-loops on `[vulndb] Downloading vulnerability DB...`, raise the liveness delay temporarily using [ArgoCD App-of-Apps Temporary Override](argocd-app-of-apps-temporary-override.md).

### Verification

```bash
# Nagios nfs-mountd back to OK (and every node's microk8s-nfs-stale-mounts)
ssh macro 'docker exec nagios4 /opt/nagios/libexec/check_tcp -H 172.22.22.2 -p 30000'
# → TCP OK - 0.000 second response time on 172.22.22.2 port 30000

# No stale mounts anywhere
for n in k8s01 k8s02 k8s03; do ssh $n 'mount -t nfs,nfs4 | awk "{print \$3}" | while read m; do timeout 6 sudo -n stat "$m" >/dev/null 2>&1 || echo STALE; done | grep -c STALE'; done
# → 0 / 0 / 0

# calibre recreated itself (it cannot start while its mount is stale)
kubectl --context pvek8s -n media get pods | grep calibre
# → 1/1 Running
```

---

## Quick Reference

| Signal | Mode 1 (Export Loss) | Mode 2 (Handle Invalidation) | Mode 3 (mountd Killed) |
| ------ | -------------------- | ---------------------------- | ---------------------- |
| `rpcinfo -t hal.int.pgmac.net nfs 3` | RPC: Remote system error | ready and waiting | ready and waiting |
| Ports 111 / 30000 | refused | open | open / **refused** |
| `showmount -e` | `clnt_create: RPC: Unable to receive` | exports listed normally | `RPC: Unable to receive; errno = Connection refused` |
| First Nagios alert | stale mounts / ingress DOWN | none | `nfs-mountd` CRITICAL, ~25 min before stale mounts |
| `stat` on the mountpoint | Stale file handle | succeeds | Stale file handle (after cache expiry) |
| `df` / `touch` inside the pod | fail or hang | succeed | fail |
| Fresh SQLite connection to the DB | fails | succeeds, `quick_check` = `ok` | fails |
| App still serving traffic | No — hangs, ingress DOWN | Yes — looks completely normal | Mostly; apps that restart cannot start (calibre) |
| Typical time to notice | hours (a user notices an outage) | days (nothing to notice) | minutes if alerts are read, hours overnight |
| Fix | Restore NFS on hal, remount, then restart workloads | Restart the affected workloads only | Restart NFS on hal; mounts self-heal; restart only fd-probe-flagged pods |
| Data at risk? | Yes — mid-write SQLite; integrity-check before restart | No — writes fail cleanly, but unwritten data is lost for good | Low — writes fail cleanly; integrity-check SQLite before restart |

---

## Notes

- **Vaultwarden's vault is not on hal.** Both its PVCs hold only `rsa_key.pem`, `icon_cache/` and `sends/`; `DATABASE_URL` points at an external DB server. It looks like the highest-stakes item on the affected list and is not actually at risk.
- **Do not restart kubelite or dqlite for this.** The control plane is not involved. Verify it is healthy and leave it alone — restarting it adds risk for no benefit.
- **Do not trust a TCP check on 2049.** It reports healthy through this entire failure mode.
- **Do not trust `microk8s-nfs-stale-mounts` to clear Mode 2.** That check runs `stat` against the mountpoint, which is a fresh lookup and succeeds by definition when only descriptors are stale. It passes throughout Mode 2 (see pgmac-net/ansible#263).
- **Do not restore NFS on hal for Mode 2.** Check `rpcinfo`, `showmount -e` and port 30000 first (see the table at the top). If the RPC layer is up there is nothing wrong on hal, and toggling NFS off/on invalidates handles for every *other* client that is currently fine.

---

## References

- PIR: [hal NFS Export Failure — Cluster-Wide Stale Mounts and a 7h Detection Gap](../incidents/2026-08-01-hal-nfs-export-failure-stale-mounts.md) — Mode 1
- PIR: [hal NFS Handle Invalidation — Silent SQLite Failures Across Three Services and a 2.7-Day Detection Gap](../incidents/2026-08-15-hal-nfs-handle-invalidation-silent-sqlite-failures.md) — Mode 2
- PIR: [hal rpc.mountd OOM Kill — Cluster-Wide Stale NFS Mounts and a 4-Hour Overnight Gap](../incidents/2026-11-15-hal-mountd-oom-kill-stale-mounts.md) — Mode 3
- Issue: [pgmac-net/nagios-config#68](https://github.com/pgmac-net/nagios-config/issues/68) — auto-restart mountd (Mode 3)
- Issue: [pgmac-net/nagios-config#70](https://github.com/pgmac-net/nagios-config/issues/70) — hal memory monitoring
- Issue: [pgmac-net/incidents#67](https://github.com/pgmac-net/incidents/issues/67) — this runbook
- Issue: [pgmac-net/ansible#263](https://github.com/pgmac-net/ansible/issues/263) — fd-level stale handle detection (Mode 2 is invisible to current checks)
- Issue: [pgmac-net/pgk8s#675](https://github.com/pgmac-net/pgk8s/issues/675) — move remaining SQLite configs off `nfs-csi`
- Issue: [pgmac-net/nagios-config#32](https://github.com/pgmac-net/nagios-config/issues/32) — hal NFS service checks
- Issue: [pgmac-net/ansible#243](https://github.com/pgmac-net/ansible/issues/243) — stale NFS mount NRPE check
- Related: [jiva-csi-mount-proliferation.md](jiva-csi-mount-proliferation.md) — different storage backend, similar mount-layer symptoms
- Related: [jiva-csi-stale-node-attachment.md](jiva-csi-stale-node-attachment.md)
