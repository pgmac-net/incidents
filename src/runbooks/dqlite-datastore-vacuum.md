---
tags:
  - runbook
  - microk8s
  - dqlite
  - kine
  - maintenance
---

# dqlite Datastore Vacuum (Freelist Bloat → Snapshot Amplification)

**Service:** microk8s control plane (pvek8s)
**First executed:** 2026-07-02
**Issue:** [pgk8s#577](https://github.com/pgmac-net/pgk8s/issues/577) — full execution log and results
**Upstream:** [canonical/microk8s#5153](https://github.com/canonical/microk8s/issues/5153) (retry amplification), [canonical/microk8s#3064](https://github.com/canonical/microk8s/issues/3064) (snapshot write volume)

---

## When to run this

The dqlite SQLite database never returns freed pages (`auto_vacuum=0`, and
dqlite cannot replicate `VACUUM`). Over months of write churn the file
becomes mostly freelist, and because raft snapshots serialise the **entire
page file**, every snapshot writes the full bloated image to disk on every
node — at high write rates that is a large fsync burst every ~100 seconds,
which creates the `SQLITE_BUSY` windows that feed
[write-contention storms](dqlite-write-contention.md) and
[watch-cache freezes](control-plane-watch-cache-freeze.md).

**Trigger: snapshot files > ~50 MB**, checked on any node:

```bash
ssh <node> "sudo ls -la /var/snap/microk8s/current/var/kubernetes/backend/ | grep snapshot"
```

Confirm the bloat ratio (2026-07-02 baseline: 268,790 pages / 257,710 free = 96% waste):

```bash
sudo /snap/microk8s/current/bin/dqlite \
  -s file:///var/snap/microk8s/current/var/kubernetes/backend/cluster.yaml \
  -c /var/snap/microk8s/current/var/kubernetes/backend/cluster.crt \
  -k /var/snap/microk8s/current/var/kubernetes/backend/cluster.key \
  k8s 'PRAGMA page_count; PRAGMA freelist_count'
```

## Critical warnings

- **`microk8s dbctl backup` is silently broken on v1.35.** It produces a
  tiny (~212 byte) tarball containing an empty directory and exits 0. The
  migrator's `backup-dqlite` mode lists prefix `/` which kine answers with
  an empty result; the `backup` (etcd-client) mode dies on
  `sortOrder is unsupported`. **Always inspect the backup archive before
  any destructive step.**
- Restoring into the **existing** datastore does not shrink anything —
  SQLite keeps its freelist. The shrink only happens by restoring into a
  **freshly bootstrapped** datastore.
- A wiped node only bootstraps a fresh single-voter dqlite if
  `cluster.yaml` **and** `info.yaml` are absent. With them present it
  loops `no known leader` forever.

## Outage profile

- Full control-plane outage for the window (60–90 min). Workload
  containers keep running; anything needing the apiserver pauses.
- The two rejoined nodes get a `leave`/`join` cycle, which restarts their
  pods — one node at a time, jiva health-checked between.
- Expect collateral: pods interrupted mid-write may leave dirty EXT4
  journals on jiva volumes (mount-time fsck failures afterwards — see
  [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md)
  for the repair pattern), and anything keeping encryption keys on an
  emptyDir will regenerate them (dependency-track KEK incident,
  [pgk8s#578](https://github.com/pgmac-net/pgk8s/issues/578)).

## Procedure

### Phase 0 — Preparation

1. Nagios downtime for pvek8s checks.
2. Pause churn: scale `argocd-application-controller` (sts) and
   `gharc-controller-gha-rs-controller` (deploy) to 0. **Record what was
   scaled — re-enable in Phase 4.**
3. All nodes Ready, all jiva volumes `RW`, no Pending pods.

### Phase 1 — Export (cluster running) and raw backups

1. Static `etcdctl` on one node (kine speaks etcd v3):
   ```bash
   curl -sL https://github.com/etcd-io/etcd/releases/download/v3.5.17/etcd-v3.5.17-linux-amd64.tar.gz \
     | sudo tar xzf - -C /root etcd-v3.5.17-linux-amd64/etcdctl --strip-components=1
   ```
2. Paginated export of `/registry/` (NOT `/` — that returns empty):
   `etcdctl get <start> /registry0 --limit=200 -w json` per page, start
   inclusive from the previous page's last key (dedupe it — a NUL byte
   cannot be passed in argv), values base64 in the JSON = binary-safe.
   Write out migrator-format `N.key`/`N.data` files. A ready-made script
   is attached to [pgk8s#577](https://github.com/pgmac-net/pgk8s/issues/577).
3. **Verify the export against the live apiserver** before stopping
   anything: key count sane, PV/PVC/secret/CRD counts match
   `kubectl get ... | wc -l` exactly. Copy the archive off-node.
4. Stop the cluster — followers first, dqlite leader last:
   `microk8s stop` per node.
5. Raw rollback copies on **every** node:
   ```bash
   sudo tar czf /root/backend-raw-$(date +%F).tar.gz \
     -C /var/snap/microk8s/current/var/kubernetes backend
   ```

### Phase 2 — Fresh datastore on the first node

1. Clear ALL state except TLS material:
   ```bash
   cd /var/snap/microk8s/current/var/kubernetes/backend
   sudo mkdir -p /root/backend-old
   sudo mv 0*-0* open-* snapshot-* metadata* cluster.db dqlite-lock \
           cluster.yaml info.yaml localnode.yaml /root/backend-old/ 2>/dev/null
   # keep: cluster.crt cluster.key failure-domain
   ```
2. `microk8s start` — bootstraps a fresh single-voter datastore (empty
   cluster state is expected).
3. **Stop kubelite** (leave k8s-dqlite running) so the GC controller
   cannot reap restored children ordered before their owners:
   ```bash
   sudo systemctl stop snap.microk8s.daemon-kubelite
   sudo /snap/microk8s/current/bin/k8s-dqlite migrator \
     --endpoint 'unix:///var/snap/microk8s/current/var/kubernetes/backend/kine.sock:12379' \
     --mode restore-to-dqlite --db-dir /root/kine-export
   sudo systemctl start snap.microk8s.daemon-kubelite
   ```
   (The restore direction of the migrator works; only backup is broken.)
4. Verify object counts match the export; check
   `PRAGMA page_count / freelist_count` — expect thousands / 0.

### Phase 3 — Rejoin remaining nodes, one at a time

Per node:

1. Clear state exactly as Phase 2 step 1 (including the identity yamls).
2. `microk8s start` → wait active → `microk8s leave`.
3. On the first node: `microk8s remove-node <node> --force`, then
   `microk8s add-node` → run the printed join on the node.
4. Verify: node Ready, dqlite member added, canary pod schedules AND
   appears in the node's `resourceVersion=0` cache read (see
   [control-plane-watch-cache-freeze.md](control-plane-watch-cache-freeze.md)
   step 4), all jiva replicas back to `RW` before the next node.

### Phase 4 — Close out

1. RV=0 canary on all nodes; snapshot sizes ~10 MB; lock-error rate ≈ 0;
   heartbeat cronjob completing; `microk8s status` shows HA.
2. Re-enable ArgoCD application-controller and ARC controller.
   **This step is easy to lose track of if the window gets interrupted —
   pending runners/listeners stuck for hours afterwards means this was
   missed.**
3. End Nagios downtime. Post before/after page stats to the tracking issue.

### Rollback (any phase)

`microk8s stop` everywhere → wipe `backend/` → extract each node's raw
tarball back in place → start leader-node first → Phase 4 verifications.

## Results achieved (2026-07-02)

| Metric | Before | After |
|---|---|---|
| page_count / freelist | 268,790 / 257,710 | 6,450 / 0 |
| Snapshot size | 237 MB | 12.7 MB |
| Snapshot write load | ~2.4 MB/s | ~150 KB/s |
| Quorum read latency (storm) | 3.1 s | 0.10 s |

## References

- [pgk8s#577](https://github.com/pgmac-net/pgk8s/issues/577) — execution log, export script, full results
- [dqlite-write-contention.md](dqlite-write-contention.md) — the storms this prevents
- [control-plane-watch-cache-freeze.md](control-plane-watch-cache-freeze.md) — the downstream freeze
- [canonical/microk8s#5153](https://github.com/canonical/microk8s/issues/5153) — retry amplification (unfixed upstream; vacuum removes the dominant trigger, not the bug)
