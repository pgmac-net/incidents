---
title: "Jiva controller replica-registration wedge"
tags:
  - runbook
  - microk8s
  - storage
  - openebs
  - jiva
  - crash-loop
  - iscsi
---

# Jiva Controller Replica-Registration Wedge — `/v1/replicas` Hangs, Replica Loops on `Waiting for s.Replica()`

**Service:** OpenEBS Jiva (pvek8s)
**First observed:** 2026-09-19 (k8s01 pre-move, pgmac-net/homelabia#185) — sabnzbd and borked-craft; hass showed the precursor
**Source:** [pgmac-net/homelabia#185](https://github.com/pgmac-net/homelabia/issues/185). No PIR — the events were self-inflicted during planned maintenance and no service was lost.

---

## Symptom

After a `jiva-ctrl` pod is moved or restarted, one volume never returns to three healthy replicas even though nothing looks broken:

- One replica pod (typically the one on the node being emptied) sits at `0/1`, or is `1/1 Running` but never becomes useful, with a **high lifetime restart count** (30+):

    ```
    pvc-<id>-jiva-rep-0   0/1   CreateContainerError   35   26d
    ```

- Its log is a tight loop and nothing else:

    ```
    level=info msg="Waiting for s.Replica() to be non nil"
    ```

- The controller's log went **silent** — no lines for many minutes — and its last line was the loss of a replica connection:

    ```
    level=warning msg="Closing RPC conn with replica: 10.1.73.185:9503"
    ```

- **The `JivaVolume` CR keeps saying `3 Ready RW`** while all of this is going on. It is a lagging summary and must not be used to judge health here.

### The discriminating test

The controller process is alive, so `exec` works and most of the API answers. Only the replica-registration path is stuck:

```bash
CTRL=$(kubectl --context pvek8s get pods -n openebs -o name | grep '<pvc-prefix>.*ctrl' | head -1)

# Fast — answers in milliseconds
kubectl --context pvek8s exec -n openebs ${CTRL#pod/} -c jiva-controller -- \
  curl -s -m 10 -o /dev/null -w "http=%{http_code} time=%{time_total}\n" http://localhost:9501/v1/volumes
# → http=200 time=0.005

# Hangs until curl gives up
kubectl --context pvek8s exec -n openebs ${CTRL#pod/} -c jiva-controller -- \
  curl -s -m 25 -w "\n[http=%{http_code} time=%{time_total}]\n" http://localhost:9501/v1/replicas
# → [http=000 time=25.001]      command terminated with exit code 28
```

**`/v1/volumes` fast and `/v1/replicas` hanging is the wedge.** A controller that is simply busy re-syncing also stops answering `/v1/replicas` for a while (see [the re-sync note](#a-slow-re-sync-is-not-this)), so tell them apart by *replica activity*, not by the hang alone: a healthy re-sync shows data being written to the returning replica's directory; a wedge shows none.

```bash
# Is the returning replica's data directory changing?
PV=$(kubectl --context pvek8s get pv -o custom-columns='CLAIM:.spec.claimRef.name,PTH:.spec.local.path' --no-headers \
     | grep '<pvc-prefix>.*jiva-rep-<N>' | awk '{print $2}')
ssh <node> "sudo du -s $PV; sudo ls -la --time-style=full-iso $PV | sort -k6,7 | tail -3"
# wait 30s and run again — unchanged size and mtimes (only replica.log growing) = wedge
```

---

## Root Cause

A replica that had been running was replaced while its **old process kept serving from a stale containerd sandbox**. Kubelet was building a new sandbox for the pod, so two processes existed for one replica, at different IPs.

The controller already counts three replicas — the zombie (still connected, still serving) and the two healthy peers — so when the new container tries to register itself it is refused:

```
level=error msg="Error in request: can't add tcp://10.1.73.132:9502, error: replication factor: 3, added replicas: 3"
"POST /v1/replicas HTTP/1.1" 500
```

The replica treats that as fatal and restarts, forever. When kubelet finally reaps the stale sandbox the zombie's connection dies (`Ping timeout on replica …`, `Closing RPC conn`), and the controller's replica-registration handler then stops making progress — the silence in its log, and the hang on `/v1/replicas`.

**Restarting the controller alone does not clear it** while the wedged replica is still trying to register: the new controller inherits the same loop. (Tried twice on 2026-09-19; both times the wedge returned.)

The affected replicas were all on the node being emptied and all had **32–38 lifetime restarts** and duplicate containerd sandboxes — flappy replicas that had been quietly unstable for weeks. Snapshot-chain length was *not* the differentiator (11 vs 13 files).

---

## Detection

Before treating anything as a wedge, gather the three signals:

```bash
# 1. Replica pod state and restart counts (JSON — do NOT read the NODE column with awk;
#    a "(3h ago)" restart annotation shifts every later column)
kubectl --context pvek8s get pods -n openebs -o json | python3 -c '
import json,sys
for x in json.load(sys.stdin)["items"]:
    n=x["metadata"]["name"]
    if "<pvc-prefix>" in n and "jiva-rep" in n:
        print(n[-5:], x["spec"].get("nodeName"), x["status"].get("phase"),
              [c["ready"] for c in x["status"].get("containerStatuses",[])],
              "restarts", [c["restartCount"] for c in x["status"].get("containerStatuses",[])])'

# 2. Controller log silence and the refusal message
kubectl --context pvek8s -n openebs logs ${CTRL#pod/} -c jiva-controller --tail=15 | cut -c1-200

# 3. Duplicate sandboxes for the replica on its node (READY twice = zombie still serving)
ssh <node> 'sudo crictl pods -o json' | python3 -c '
import json,sys,collections
c=collections.defaultdict(list)
for p in json.load(sys.stdin)["items"]:
    if p["metadata"]["namespace"]=="openebs" and "rep" in p["metadata"]["name"]:
        c[p["metadata"]["name"]].append(p["state"].replace("SANDBOX_",""))
[print(k[-24:], v) for k,v in sorted(c.items()) if v.count("READY")>1]'
```

---

## Recovery — Park the Replica, Then Restart the Controller

The idea: take the wedged replica out of the picture so the controller has nothing to refuse, and let the volume run on its two healthy replicas. When the node is about to be rebooted this costs nothing — that is where the reboot leaves the volume anyway.

!!! warning "Two healthy copies must remain"
    Do this only when the **other two replica pods are `1/1 Ready` and were `RW` before the wedge** (check the controller log from before it went silent). With **no consumer attached** there are no writes, so the copies cannot diverge — that is the safe case, and why the [stop-first procedure](jiva-ctrl-node-rolling-restart.md#preferred-procedure-stop-first-one-volume-at-a-time) matters. With a consumer attached, prefer to wait for the re-sync to finish.

    Never park a replica while the volume is mid-re-sync with only one confirmed-`RW` copy: that leaves a single healthy copy.

### Step 1: Cordon the node (if it is not already)

The replica's PV pins it to its node, so on a cordoned node a deleted replica pod stays `Pending` instead of being recreated straight into the same trouble.

```bash
kubectl --context pvek8s cordon <node>
```

### Step 2: Delete the wedged replica pod

```bash
kubectl --context pvek8s -n openebs delete pod pvc-<id>-jiva-rep-<N> --wait=false
# wait until it reports Pending (the stale sandbox is reaped, which can take 1-3 minutes)
kubectl --context pvek8s -n openebs get pod pvc-<id>-jiva-rep-<N> --no-headers
# → 0/1   Pending
```

### Step 3: Restart the controller

```bash
kubectl --context pvek8s -n openebs delete pod ${CTRL#pod/} --wait=false
```

### Step 4: Confirm it came back with two `RW`

```bash
NEW=$(kubectl --context pvek8s get pods -n openebs --no-headers | grep '<pvc-prefix>.*ctrl' \
      | grep -v Terminating | awk '$2=="2/2" && $3=="Running" {print $1}' | head -1)
kubectl --context pvek8s exec -n openebs $NEW -c jiva-controller -- \
  curl -s -m 10 http://localhost:9501/v1/replicas | python3 -c '
import json,sys
[print(d["address"], d["mode"]) for d in json.load(sys.stdin)["data"]]'
# → two lines, both RW
```

`/v1/replicas` now answers immediately. If it still hangs, the wedge is on a different replica — repeat the detection.

### Step 5: Bring the parked replica back later

Uncordon the node when maintenance is finished. The replica schedules, registers against a stable controller and re-syncs — normally seconds to a couple of minutes:

```bash
kubectl --context pvek8s uncordon <node>
```

---

## Verification

```bash
# Controller answers, replica list matches expectation (2 while parked, 3 after uncordon)
kubectl --context pvek8s exec -n openebs $NEW -c jiva-controller -- \
  curl -s -m 10 http://localhost:9501/v1/replicas | python3 -c '
import json,sys; print([d["mode"] for d in json.load(sys.stdin)["data"]])'

# Consumer (if running) can write
kubectl --context pvek8s exec -n <ns> <pod> -- sh -c 'touch <mount>/.rwtest && rm <mount>/.rwtest && echo RW-OK'
```

---

## A slow re-sync is not this

A replica that genuinely has to catch up also blocks the controller for a while, and that is **normal**: after any controller move every replica goes `WO` (write-only, rebuilding) before returning to `RW`, and `/v1/replicas` may not answer during it. It ranged from seconds to **~19 minutes** (sonarr, 2026-09-19).

What distinguishes it from the wedge is progress — data lands in the returning replica's directory, and `replica.log` shows sync activity rather than an endless `Waiting for s.Replica()`. Give a slow re-sync time; do not park a replica that is making progress.

The danger of a slow re-sync is for a **live consumer**: while it runs the controller cannot answer iSCSI pings and the consumer goes read-only. See [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md) and stop the consumer first.

---

## References

- Source: [pgmac-net/homelabia#185](https://github.com/pgmac-net/homelabia/issues/185) — k8s01 pre-move notes, 2026-09-19
- Related: [jiva-ctrl-node-rolling-restart.md](jiva-ctrl-node-rolling-restart.md) — where a controller move happens, and the stop-first procedure that keeps this off live consumers
- Related: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md) — what a live consumer suffers while the controller is blocked
- Related: [jiva-replica-corrupt-snapshot-chain.md](jiva-replica-corrupt-snapshot-chain.md) — a replica that crash-loops on a *broken chain* (log shows a file error); this one loops on a *refused registration*
- Related: [jiva-ctrl-endpoint-deadlock.md](jiva-ctrl-endpoint-deadlock.md) — replicas crash-loop because controller endpoints are stuck `notReadyAddresses`; here the endpoints are healthy
