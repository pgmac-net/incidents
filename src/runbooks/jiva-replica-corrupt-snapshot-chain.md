---
tags:
  - runbook
  - microk8s
  - storage
  - openebs
  - jiva
  - crash-loop
---

# Jiva Replica Corrupt Snapshot Chain — CrashLoopBackOff on Missing Snapshot Image

**Service:** OpenEBS Jiva (pvek8s)
**First observed:** 2026-06-28 (diagnosed and fixed 2026-07-13)
**PIR:** [pvek8s Storage Cascade — ArgoCD Sync Burst, Watch-Cache Freeze, and jiva iSCSI Read-Only Volumes](../incidents/2026-07-13-argocd-sync-burst-watch-cache-freeze-jiva-ro.md)

---

## Symptom

A single jiva replica pod is in `CrashLoopBackOff` with a steadily climbing restart count (tens of restarts over days), while the volume's other replicas and its controller are Running and the workload using the volume is unaffected:

```
openebs  pvc-<vol-id>-jiva-rep-1   0/1   CrashLoopBackOff   82 (70s ago)   14d
```

The volume is silently running on degraded redundancy (2/3 replicas). Because the workload keeps working, this state can persist for days without attention — check restart count × age, not just pod status.

This is distinct from [jiva-ctrl-endpoint-deadlock](jiva-ctrl-endpoint-deadlock.md) (replicas CrashLoop because controller endpoints are stuck `notReadyAddresses` — there the *controller connection* is the problem and multiple replicas are usually affected). Here exactly one replica crashes, and its log shows a local file error.

---

## Root Cause

The replica's on-disk snapshot chain is inconsistent: `volume.meta` (and the `.img.meta` parent pointers) reference a snapshot or head image file that does not exist in the data directory. On startup, the replica opens the volume by walking this chain and hard-linking the head image; a missing file makes the open fail, the controller drops the connection, and the replica process exits fatally. Jiva has **no self-repair** for a broken chain — the pod restarts and fails identically forever.

The inconsistency is left behind by an ill-timed kill during snapshot-chain updates (metadata and image files are not updated atomically). Observed after dqlite storm / mass-restart windows. In the 2026-07-13 case the directory held 11 orphaned snapshot images and **no head image at all**.

---

## Detection / Diagnosis

### Step 1: Confirm the error signature

```bash
kubectl logs <rep-pod> -n openebs --previous --tail=20
```

Key signature:

```
Error link openebs/volume-head-017.img openebs/volume-snap-000.img: no such file or directory during open
...
Failed to handle connection, err: EOF, shutdown replica...
```

The named `volume-snap-*.img` (or the head image) is missing from the replica's data directory.

### Step 2: Confirm quorum — MANDATORY before any destructive step

The rebuild wipes this replica's data. Only safe when at least 2 other replicas are RW:

```bash
CTRL=$(kubectl get pods -n openebs -o name | grep '<vol-id-prefix>.*ctrl')
kubectl exec -n openebs ${CTRL#pod/} -c jiva-controller -- \
  curl -s http://localhost:9501/v1/replicas | jq -r '.data[] | "\(.address) \(.mode)"'
# → need ≥2 lines showing RW (the crashing replica won't be listed or shows ERR)
```

**If fewer than 2 replicas are RW: STOP.** Wiping this replica risks data loss — investigate the other replicas first.

### Step 3: Identify the backing data directory and node

Replica data lives on a local PV bound to a per-replica PVC in the `openebs` namespace:

```bash
# Find the replica's own PVC → PV → hostPath and node
kubectl get pv -o custom-columns='PV:.metadata.name,NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name' | grep '<vol-id-prefix>'
kubectl get pv <rep-pv> -o jsonpath='{.spec.local.path} {.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}{"\n"}'
# → /var/openebs/local/<rep-pv>  k8s0N
```

Optionally inspect the directory to confirm the broken chain (missing head/snap images, orphaned `.img` files):

```bash
ssh <node> "sudo ls -la /var/openebs/local/<rep-pv>/"
```

---

## Recovery — Wipe and Rebuild

The fix is to empty the replica's data directory so it re-registers with the controller as a fresh replica (WO mode) and performs a full resync from the healthy peers. ~10 min for a 5 GB volume.

### Step 1: Wipe the data directory contents

Via a one-shot hostPath pod pinned to the replica's node (keeps the operation inside kubectl; delete the pod afterwards):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: jiva-replica-wipe
  namespace: openebs
  labels:
    purpose: debug-cleanup
spec:
  restartPolicy: Never
  nodeName: <node>
  containers:
    - name: wipe
      image: docker.io/library/busybox:1.36
      command: ["sh", "-c", "rm -rf /data/* && echo WIPED && ls -la /data/"]
      volumeMounts:
        - name: replica-data
          mountPath: /data
  volumes:
    - name: replica-data
      hostPath:
        path: /var/openebs/local/<rep-pv>
        type: Directory
```

```bash
kubectl apply -f wipe-pod.yaml
kubectl logs jiva-replica-wipe -n openebs   # → WIPED, empty listing
kubectl delete pod jiva-replica-wipe -n openebs
```

(Equivalent: `ssh <node> "sudo find /var/openebs/local/<rep-pv>/ -mindepth 1 -delete"`.)

Wipe **contents only** — the directory itself is the local-PV mount point and must remain.

### Step 2: Restart the replica pod

```bash
kubectl delete pod <rep-pod> -n openebs
```

The StatefulSet recreates it; with an empty data dir it registers with the controller in WO (write-only/rebuilding) mode and resyncs.

---

## Verification

```bash
# Replica pod stable — no new restarts
kubectl get pod <rep-pod> -n openebs
# → 1/1 Running, RESTARTS 0

# All replicas RW after resync completes (~10 min for 5G)
kubectl exec -n openebs ${CTRL#pod/} -c jiva-controller -- \
  curl -s http://localhost:9501/v1/replicas | jq -r '.data[] | "\(.address) \(.mode)"'
# → 3 lines, all RW
```

---

## Prevention

- Alert on prolonged CrashLoopBackOff in the `openebs` namespace — the 2026-07-13 case ran 92 restarts over 14 days unnoticed because the volume kept serving from 2/3 replicas (see PIR action items).
- Note both jiva pod naming patterns when scoping checks: bare `pvc-<id>-jiva-rep-N` StatefulSet pods **and** `pvc-<id>-rep-N-<hash>` Deployment pods.

---

## References

- PIR: [pvek8s Storage Cascade — ArgoCD Sync Burst, Watch-Cache Freeze, and jiva iSCSI Read-Only Volumes](../incidents/2026-07-13-argocd-sync-burst-watch-cache-freeze-jiva-ro.md) — Chain 4
- Related: [jiva-ctrl-endpoint-deadlock.md](jiva-ctrl-endpoint-deadlock.md) — replica CrashLoop with a *controller-side* cause
- Related: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md) — the storm/restart windows that create the corruption opportunity
- Related PIRs: [2026-02-22](../incidents/2026-02-22-radarr-openebs-jiva-replica-divergence.md), [2026-03-28](../incidents/2026-03-28-radarr-jiva-replica-divergence-second.md) — replica *divergence* (different failure: replicas disagree, none crash)
