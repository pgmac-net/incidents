---
tags:
  - runbook
  - nfs
  - hal
  - storage
  - microk8s
---

# hal NFS Export Failure — Cluster-Wide Stale Mounts

**Service:** `hal.int.pgmac.net` (172.22.22.2, QNAP NAS) — NFS backend for `pvek8s`
**First observed:** 2026-08-01
**PIR:** [hal NFS Export Failure — Cluster-Wide Stale Mounts and a 7h Detection Gap](../incidents/2026-08-01-hal-nfs-export-failure-stale-mounts.md)

---

## Symptom

One or more applications hang without erroring: they accept TCP connections and then never respond. Nagios reports the affected ingress host as DOWN with `CRITICAL - Socket timeout` or an HTTP check timeout.

Meanwhile **everything looks healthy**:

- `kubectl get pods` shows all pods `Running` and `1/1 Ready` with low or zero restart counts
- hal responds to ping, SSH, HTTPS and the QNAP web UI
- the microk8s control plane is fine — watch cache current, dqlite quiet

The giveaway is that the affected pods write `Stale file handle` / `Errno 116` / `disk I/O error` into their own logs continuously, and nothing watches those logs.

!!! warning "Probes cannot see this"
    TCP and HTTP probes against a long-running process never touch the filesystem. A pod with completely dead storage will report `Ready` indefinitely. During the 2026-08-01 incident, 12 pods reported healthy for eight hours.

---

## Root Cause

`nfsd` on hal restarts and re-exports its filesystems, which invalidates every previously issued NFS file handle. Clients holding those handles get `ESTALE` on any subsequent operation.

Normally clients would recover by remounting. In this failure mode they cannot, because `rpcbind` (port 111) and `rpc.mountd` (port 30000) do **not** come back with `nfsd`. They are separate services on the QNAP appliance, and `nfsd` holds its listening socket on 2049 independently of the portmapper.

This produces the deceptive state at the heart of the failure: **the port you would think to check is the one that stays up**. A TCP health check against 2049 reports healthy throughout. Remounting requires the portmapper to locate `mountd`, and `mountd` to issue a fresh file handle — with both gone, recovery is impossible from the client side.

Applications fail in proportion to how much they touch disk. Ones serving cached or static content look fine; ones doing SQLite writes (Home Assistant recorder, Tautulli, sabnzbd) fail immediately and loudly into their logs.

---

## Detection

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

## Recovery

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

## Verification

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

## Notes

- **Vaultwarden's vault is not on hal.** Both its PVCs hold only `rsa_key.pem`, `icon_cache/` and `sends/`; `DATABASE_URL` points at an external DB server. It looks like the highest-stakes item on the affected list and is not actually at risk.
- **Do not restart kubelite or dqlite for this.** The control plane is not involved. Verify it is healthy and leave it alone — restarting it adds risk for no benefit.
- **Do not trust a TCP check on 2049.** It reports healthy through this entire failure mode.

---

## References

- PIR: [hal NFS Export Failure — Cluster-Wide Stale Mounts and a 7h Detection Gap](../incidents/2026-08-01-hal-nfs-export-failure-stale-mounts.md)
- Issue: [pgmac-net/incidents#67](https://github.com/pgmac-net/incidents/issues/67) — this runbook
- Issue: [pgmac-net/nagios-config#32](https://github.com/pgmac-net/nagios-config/issues/32) — hal NFS service checks
- Issue: [pgmac-net/ansible#243](https://github.com/pgmac-net/ansible/issues/243) — stale NFS mount NRPE check
- Related: [jiva-csi-mount-proliferation.md](jiva-csi-mount-proliferation.md) — different storage backend, similar mount-layer symptoms
- Related: [jiva-csi-stale-node-attachment.md](jiva-csi-stale-node-attachment.md)
