---
title: "Safe node restart (jiva-ctrl hosted)"
tags:
  - runbook
  - microk8s
  - storage
  - openebs
  - jiva
  - iscsi
  - node-restart
---

# Safe Node Restart for Nodes Hosting jiva-ctrl Pods

**Service:** OpenEBS Jiva iSCSI (pvek8s)
**First documented:** 2026-05-30
**PIR:** [pvek8s Post-Power-Outage Recovery — kubelet Volume Manager Stall and KCM Stale terminatingReplicas](../incidents/2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md)
**Linear:** [PGM-223](https://linear.app/pgmac-net-au/issue/PGM-223)
**Revised 2026-09-19:** stop-first procedure, controller-move mechanics and reboot flags added from [pgmac-net/homelabia#185](https://github.com/pgmac-net/homelabia/issues/185) (k8s01, which hosted all 11 controllers)

---

## When to Use This Runbook

Use this runbook whenever you need to restart kubelite (or drain/taint) a node that may be hosting jiva-ctrl pods (iSCSI targets).

**Why this matters:** jiva-ctrl pods are iSCSI targets. When the node running them is restarted, those pods are evicted and the iSCSI target process exits. Any workload pod on *another* node that has an active iSCSI session to the controller will detect a TCP connection failure, enter 120-second session recovery, and — if the target does not reappear within that window — have its SCSI device go offline. The kernel's JBD2 journal then aborts and EXT4 remounts the filesystem read-only. This is a data-safe failure but requires manual recovery.

The pre-restart procedure below migrates affected workload pods *before* the restart, so the iSCSI sessions are already gone and there is nothing to fail over.

See [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md) for recovery if the filesystem has already gone read-only.

---

## Choosing a Procedure

| The node hosts… | Do this |
| --- | --- |
| **No** jiva-ctrl pods | Nothing to move. Go straight to [rebooting the node](#rebooting-the-node). |
| A **few** controllers, and a short outage per app is acceptable | [Stop-first](#preferred-procedure-stop-first-one-volume-at-a-time) for each, then reboot. |
| **Many** controllers (k8s01 held all 11) | Stop-first, one volume at a time, **budget ~4 minutes per volume** (up to ~35 for a slow one), then reboot with the shuffle skipped. Do not use the automated shuffle. |
| Any volume already **read-only** | [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md). Too late to pre-move. |

---

## What Moving a Controller Actually Does

Deleting a `jiva-ctrl` pod so it reschedules is **not** a quiet operation. Every replica of that volume loses its controller, exits, restarts and has to **re-register**, and each one passes through `WO` (write-only, rebuilding) before it returns to `RW`:

```
RW,RW,RW  →  (controller restarts)  →  RW,RW,WO  →  RW,RW,RW
```

For as long as a replica is being added, **the controller stops answering** — including its iSCSI target, which lives in the same process. A consumer attached to that volume misses its 5-second iSCSI pings, the session drops, ext4 aborts its journal and the filesystem goes **read-only**. That is [Mode B](jiva-ctrl-eviction-iscsi-ro-filesystem.md) reached through a different door.

How long the re-add takes varies enormously: **seconds** for most volumes, **~19 minutes** for sonarr on 2026-09-19. You cannot tell in advance. The consequences:

- Moving a controller **under a live consumer is a gamble** — 1 of the first 3 live moves went read-only.
- The `JivaVolume` CR is a **lagging summary**. It kept reporting `3 Ready RW` while the controller was blocked and not answering. Judge health from the **controller itself** (below), and treat a controller that does not answer as unhealthy.
- With only three nodes the moves simply **relocate the pile**: after emptying k8s01, all 11 controllers sat on k8s03. Plan for that node's own reboot.

!!! warning "Wednesday's cascade, and why this is not just the automated shuffle"
    On 2026-09-16 `k8s-reboot.yml` shuffled ten controllers off k8s02, one at a time with a one-minute settle. It then aborted at its own quorum gate having never rebooted the node — but the churn had already produced replica crash-loops on all three nodes, stale containerd sandbox reservations and three read-only PVCs. Ten sequential controller moves are ten re-sync waves. See [PIR 2026-09-15](../incidents/2026-09-15-vzdump-fsfreeze-jiva-replica-triple-fault.md) for the neighbouring failure.

### Reading real health: ask the controller

```bash
CTRL=$(kubectl --context pvek8s get pods -n openebs -o name | grep '<pvc-prefix>.*ctrl' | head -1)

kubectl --context pvek8s exec -n openebs ${CTRL#pod/} -c jiva-controller -- \
  curl -s -m 10 http://localhost:9501/v1/replicas | python3 -c '
import json,sys
[print(d["address"], d["mode"]) for d in json.load(sys.stdin)["data"]]'
# healthy: three lines, all RW
# re-syncing: one line WO
# no output / curl exit 28: controller is blocked — do not proceed, see the wedge runbook if it persists
```

A volume is only healthy for the purposes of moving on when **all** of these hold: the controller answers with the expected number of `RW` replicas; every replica pod is `1/1 Ready`; no node holds a read-only mount of it; and no node logged `ping timeout` / `conn error` during a settle period. If the controller stays silent while no data is being written to the returning replica, that is the [replica-registration wedge](jiva-ctrl-replica-registration-wedge.md).

---

## Preferred Procedure: Stop-First, One Volume at a Time

Stopping the consumer before the controller moves means **nothing is attached while the re-sync runs, so nothing can go read-only.** The cost is a short, deliberate outage per app — 3–5 minutes in normal cases — instead of a coin-flip on a long one. Do it for one volume at a time and stop at the first anomaly.

!!! note "Suspend ArgoCD auto-sync first — parents too"
    `--replicas=0` on an ArgoCD-managed workload is reverted within about a minute. Suspending only the leaf app is not enough: an app-of-apps parent re-enables it. Record each app's current policy, then suspend `system`, the parent app and the leaf app (see [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md#fast-path-a-scale-to-zero-preferred-proven-2026-08-06-six-volumes)):

    ```bash
    kubectl --context pvek8s -n argocd get application <app> -o jsonpath='{.spec.syncPolicy.automated}'   # save this
    kubectl --context pvek8s -n argocd patch application <app> --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
    ```

    Restore each one to exactly what you recorded when the last volume is done.

### Before any volume

1. **Cordon the node** so controllers and consumers cannot come back to it:

    ```bash
    kubectl --context pvek8s cordon <node>
    ```

2. **Back up the JivaVolume CRs** — they are your record of `nodeID` labels if one goes stale:

    ```bash
    kubectl --context pvek8s get jivavolume -n openebs -o json > jivavolumes-prepatch-$(date +%Y%m%d-%H%M).json
    ```

3. Confirm the array is quiet. A re-sync competes with everything else for the same spindles:

    ```bash
    ssh root@pve2 'LC_ALL=C sar -d 1 1 | awk "\$2==\"sda\"{print \"await=\"\$(NF-1)\"ms util=\"\$NF\"%\"}" | tail -1'
    # → await well under 5ms
    ```

4. **Do a canary first**: pick the volume with **no consumer** (or the least important app) and run the whole sequence on it. Order the rest by how much an outage would hurt, least first, and put anything with users on it (game servers) **last**.

### For each volume

1. **Stop the consumer** and wait until its pod is gone:

    ```bash
    kubectl --context pvek8s -n <ns> scale <deployment|statefulset>/<name> --replicas=0
    ```

2. **Confirm the volume is fully unreferenced on every node** — no mount, no iSCSI session, and an empty `nodeID` label. Never force anything if this does not clear; see [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md):

    ```bash
    for n in k8s01 k8s02 k8s03; do
      echo -n "$n mounts="; ssh $n "grep -c <pvc-prefix> /proc/mounts"
      echo -n "$n iscsi=";  ssh $n "sudo iscsiadm -m session 2>/dev/null | grep -c <pvc-prefix>"
    done
    kubectl --context pvek8s -n openebs get jivavolume pvc-<id> -o jsonpath='{.metadata.labels.nodeID}{"\n"}'
    # → 0 0 for every node, and an empty label
    ```

3. **Park this volume's replica on the node being emptied** if it has one — *while the volume is still fully 3×`RW`*, so two healthy copies always remain. On a cordoned node the deleted replica stays `Pending`, and there is nothing left on the node to re-add. This is what [avoids the wedge](jiva-ctrl-replica-registration-wedge.md):

    ```bash
    # find it from JSON, never by an awk column — a "(3h ago)" restart annotation shifts the NODE column
    kubectl --context pvek8s get pods -n openebs -o json | python3 -c '
    import json,sys
    for x in json.load(sys.stdin)["items"]:
        n=x["metadata"]["name"]
        if "<pvc-prefix>" in n and "jiva-rep" in n and x["spec"].get("nodeName")=="<node>": print(n)'

    kubectl --context pvek8s -n openebs delete pod <that-replica> --wait=false   # → Pending
    ```

4. **Move the controller**, then wait for a new `2/2 Running` pod on another node:

    ```bash
    kubectl --context pvek8s -n openebs delete pod ${CTRL#pod/} --wait=false
    ```

5. **Wait until the controller itself reports every expected replica `RW`.** Expect `RW,RW,WO` before `RW,RW,RW`; give it minutes, and do **not** restart the consumer early. With a replica parked, the expected count is **two**.

6. **Restart the consumer** and check it lands off the node and can write:

    ```bash
    kubectl --context pvek8s -n <ns> scale <deployment|statefulset>/<name> --replicas=1
    kubectl --context pvek8s -n <ns> exec <new-pod> -- sh -c 'touch <mount>/.rwtest && rm <mount>/.rwtest && echo RW-OK'
    kubectl --context pvek8s -n openebs get jivavolume pvc-<id> -o jsonpath='{.metadata.labels.nodeID}{"\n"}'
    # → the node the new pod is on
    ```

7. **Move on only when the volume has settled**: still healthy after a further 30–60 seconds, no read-only mount, no iSCSI errors on any node. If anything looks wrong, **stop** — the app is already back up, or (if step 5 never completed) is still stopped and safe.

### Before rebooting

- Every controller is off the node; every consumer is off the node; **no `nodeID` label references it**.
- Volumes with a parked replica are healthy at two `RW` — that is intended.
- Restore ArgoCD auto-sync on everything you suspended.
- Check what the drain will evict, and whether any CI runner is busy.

---

## Rebooting the Node

Use `k8s-reboot.yml` — see [Automated Option](#automated-option-ansible) for the flags. For a node that has been emptied as above:

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini k8s-reboot.yml --limit <node> \
  -e k8s_reboot_via_pve=true \
  -e k8s_reboot_skip_jiva_shuffle=true \
  -e k8s_reboot_allow_parked_jiva_replicas=true
```

## After the Node Returns

The node's replicas rejoin a **stable** controller, which is the easy path: on 2026-09-19 all 11 volumes were fully `RW` about two minutes after k8s01 came back, with no read-only mounts and no iSCSI errors.

```bash
# every volume back to 3 x RW — from the CR is fine here, the controllers are steady
kubectl --context pvek8s get jivavolume -n openebs -o json | python3 -c '
import json,sys
for v in sorted(json.load(sys.stdin)["items"], key=lambda v: v["metadata"]["name"]):
    print(v["metadata"]["name"][4:12], [r["mode"] for r in v["status"].get("replicaStatus",[])])'

# no label references a node that has just come back with a stale view
kubectl --context pvek8s get jivavolume -n openebs -L nodeID

# nothing left read-only
for n in k8s01 k8s02 k8s03; do
  ssh $n "awk '\$4 ~ /(^|,)ro(,|\$)/ && \$2 ~ /kubelet.pods/ {print \$2}' /proc/mounts"; done
```

Then reclaim space if the VM disk options changed (`fstrim -v /`), and check the parked replicas came back.

### DaemonSet pods that will not start (containerd name reservation)

Straight after the reboot a few pods on the node may hang with:

```
Failed to create pod sandbox: ... failed to reserve sandbox name "speaker-xxxxx_metallb-system_<uid>_0": name "..." is reserved for "<id>"
```

Kubelet is trying to reuse a name that containerd still holds for an older sandbox or container. It usually clears by itself in 15–25 minutes; a targeted fix is faster and safe **for a pod that has healthy peers**. First find out what holds the name:

```bash
ssh <node> 'sudo crictl pods | grep <pod>'         # NotReady sandbox = dead, still registered
ssh <node> 'sudo crictl ps -a | grep <container>'  # is the holder Running or Exited?
```

- **Holder is a `NotReady` (dead) sandbox** — remove exactly that one. Confirm its state first; never remove a `Ready` sandbox with a live workload:

    ```bash
    ssh <node> 'sudo crictl inspectp <id> | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[\"status\"][\"state\"], d[\"status\"][\"metadata\"][\"name\"])"'
    # → SANDBOX_NOTREADY <pod>
    ssh <node> 'sudo crictl rmp <id>'
    ```

- **Holder is a container that is still `Running`** (the pod has two Ready sandboxes and a failing liveness probe) — delete the pod. A DaemonSet recreates it with a new UID, so nothing collides:

    ```bash
    kubectl --context pvek8s -n <ns> delete pod <pod>
    ```

Do not do either for a pod with no healthy peer without thinking twice. Neither caused an outage on 2026-09-19 (MetalLB and ingress-nginx each had two healthy instances elsewhere). This is the same family as RC-3 in [PIR 2026-06-05](../incidents/2026-06-05-pvek8s-kernel-reboot-cluster-recovery-failure.md).

---

## Pre-Restart Procedure (older approach: migrate workloads away from evicted controllers)

!!! note "Superseded for a full node move"
    This procedure targets the case where controllers are about to be **evicted abruptly** by a kubelite restart: it moves workload pods that hold iSCSI sessions to those controllers off *other* nodes first. It does not move the controllers themselves. For emptying a node that hosts controllers ahead of a reboot, use [stop-first](#preferred-procedure-stop-first-one-volume-at-a-time).

### Step 1 — Identify jiva-ctrl pods on the target node

```bash
TARGET_NODE=<node>   # e.g. k8s01

kubectl --context pvek8s get pods -n openebs -o wide --no-headers | \
  awk -v n="$TARGET_NODE" '/jiva.*ctrl/ && $7==n {print $1, $7}'
```

If the output is empty, no jiva-ctrl pods are on this node — skip to the [Node Restart Procedure](#node-restart-procedure).

Example output:
```
pvc-746b2837-...-jiva-ctrl-0   k8s01
pvc-a3a7e012-...-jiva-ctrl-0   k8s01
```

### Step 2 — Find nodes with active iSCSI sessions to those controllers

For each jiva-ctrl pod, check whether any node has a live iSCSI session to its controller service:

```bash
# Get the ClusterIP of each controller's service
# The service name shares the PV prefix with the ctrl pod name
kubectl --context pvek8s get svc -n openebs | grep "jiva-ctrl"
# → pvc-746b2837-...-jiva-ctrl-svc   ClusterIP   10.152.183.57   ...
# → pvc-a3a7e012-...-jiva-ctrl-svc   ClusterIP   10.152.183.22   ...

# Check all nodes for active sessions to those IPs
for pod in $(kubectl --context pvek8s get pods -n openebs \
    -l app=openebs-jiva-csi-node -o name); do
  echo "=== $pod ==="
  kubectl --context pvek8s exec -n openebs "$pod" -c jiva-csi-plugin -- \
    iscsiadm -m session 2>/dev/null || echo "(no sessions)"
done
```

Note which nodes have sessions to each controller IP. Those are the nodes hosting workload pods that must be migrated before the restart.

### Step 3 — Migrate workload pods off the affected nodes

For each controller with active sessions on other nodes, find and delete the workload pod that holds that PVC:

```bash
# Derive the PV name from the ctrl pod name (strip -jiva-ctrl-N suffix)
CTRL_POD=pvc-746b2837-...-jiva-ctrl-0
PV_NAME=${CTRL_POD%-jiva-ctrl-*}

# Find the PVC bound to this PV
kubectl --context pvek8s get pvc -A --no-headers | awk -v pv="$PV_NAME" '$3==pv {print $1, $2}'
# → media   seerr-seerr-chart-config

# Find the pod in that namespace using that PVC
PVC_NS=media
PVC_NAME=seerr-seerr-chart-config
kubectl --context pvek8s get pods -n "$PVC_NS" -o json | \
  python3 -c "
import json,sys
data=json.load(sys.stdin)
pvc='$PVC_NAME'
for p in data['items']:
  for v in p['spec'].get('volumes',[]):
    if v.get('persistentVolumeClaim',{}).get('claimName')==pvc:
      print(p['metadata']['name'])
"
```

Once you have the pod name, delete it and wait for it to reschedule to a node that is **not** `$TARGET_NODE`:

```bash
kubectl --context pvek8s delete pod -n "$PVC_NS" <pod-name>

# Watch until Running on a different node
kubectl --context pvek8s get pod -n "$PVC_NS" <pod-name> -o wide -w
# → 1/1 Running on k8s02 or k8s03 (not TARGET_NODE)
```

!!! warning "StatefulSet pods do not reschedule automatically on cordoned nodes"
    If the node is already cordoned (or if you cordon it before deleting), StatefulSet pods will stay
    Pending until you uncordon another eligible node. Delete the pod *before* cordoning the target node
    so the scheduler can place it freely.

Repeat for every controller with active sessions.

### Step 4 — Verify all sessions have logged out

Confirm no node retains an iSCSI session to the controllers that were on `$TARGET_NODE`:

```bash
for pod in $(kubectl --context pvek8s get pods -n openebs \
    -l app=openebs-jiva-csi-node -o name); do
  echo "=== $pod ==="
  kubectl --context pvek8s exec -n openebs "$pod" -c jiva-csi-plugin -- \
    iscsiadm -m session 2>/dev/null | grep "<controller-ClusterIP>" || echo "(none)"
done
# All nodes should show "(none)" for the affected controller IPs
```

Only proceed once all sessions to the affected controllers are gone.

---

## Node Restart Procedure

With iSCSI sessions safely cleared, restart the node using the standard dqlite → kubelite ordering:

1. **Cordon the node** (required — prevents the kubelet watch-race stall on restart):

    ```bash
    kubectl --context pvek8s cordon "$TARGET_NODE"
    ```

    See [kubelet-silent-stall.md — Failure Mode 2](kubelet-silent-stall.md) for why cordoning before restart is mandatory.

2. **Restart k8s-dqlite first**, wait for it to stabilise:

    ```bash
    ssh "$TARGET_NODE" "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
    # Wait until active and no 'database is locked' errors for 30s
    ssh "$TARGET_NODE" "sudo systemctl is-active snap.microk8s.daemon-k8s-dqlite.service"
    ```

3. **Restart kubelite**:

    ```bash
    ssh "$TARGET_NODE" "sudo systemctl restart snap.microk8s.daemon-kubelite.service"
    ```

4. **Wait for node Ready**:

    ```bash
    kubectl --context pvek8s wait node/"$TARGET_NODE" --for=condition=Ready --timeout=300s
    ```

5. **Uncordon**:

    ```bash
    kubectl --context pvek8s uncordon "$TARGET_NODE"
    ```

See [kubelet-volume-manager-stall.md — Option B](kubelet-volume-manager-stall.md) for the full dqlite restart safety procedure and lock-contention checks.

---

## Post-Restart Verification

```bash
# Node is Ready and schedulable
kubectl --context pvek8s get node "$TARGET_NODE"
# → Ready (no SchedulingDisabled)

# jiva-ctrl pods have rescheduled and are Running
kubectl --context pvek8s get pods -n openebs -o wide | grep jiva.*ctrl
# → all Running, spread across nodes

# Workload pods that were migrated are Running with rw filesystems
kubectl --context pvek8s get pods -n <namespace> <pod-name> -o wide
# → 1/1 Running on a node other than TARGET_NODE

# iSCSI sessions re-established on the workload node
NEW_NODE=$(kubectl --context pvek8s get pod -n <namespace> <pod-name> \
  -o jsonpath='{.spec.nodeName}')
NEW_JIVA_POD=$(kubectl --context pvek8s get pods -n openebs \
  -l app=openebs-jiva-csi-node \
  -o jsonpath="{.items[?(@.spec.nodeName=='$NEW_NODE')].metadata.name}")
kubectl --context pvek8s exec -n openebs "$NEW_JIVA_POD" -c jiva-csi-plugin -- \
  iscsiadm -m session
# → tcp: [...] iqn.2016-09.com.openebs.jiva:<pvc-name> (non-flash)

# Filesystem is rw
kubectl --context pvek8s exec -n openebs "$NEW_JIVA_POD" -c jiva-csi-plugin -- \
  grep "<pvc-name>" /proc/mounts
# → should show rw in mount options, not ro
```

---

## References

- PIR: [pvek8s Post-Power-Outage Recovery](../incidents/2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md) — Chain 4 root cause (batched jiva-ctrl eviction → EXT4 ro)
- Linear: [PGM-223](https://linear.app/pgmac-net-au/issue/PGM-223) — this runbook
- Related: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md) — recovery if the filesystem has already gone read-only (use when it's too late to migrate first)
- Related: [jiva-ctrl-replica-registration-wedge.md](jiva-ctrl-replica-registration-wedge.md) — a moved controller that never reports its replicas
- Related: [jiva-csi-stale-node-attachment.md](jiva-csi-stale-node-attachment.md) — stale `nodeID` label after a single-node reboot
- Issue: [pgmac-net/homelabia#185](https://github.com/pgmac-net/homelabia/issues/185) — the k8s01 power-cycle these additions come from
- Related: [kubelet-volume-manager-stall.md](kubelet-volume-manager-stall.md) — Option B: full dqlite+kubelite restart procedure and lock-contention safety checks
- Related: [kubelet-silent-stall.md](kubelet-silent-stall.md) — Failure Mode 2: why cordon-before-restart is required for kubelite restarts

---

## Automated Option — Ansible

The manual procedure above remains the canonical reference and should be
used when the automation is unavailable or when a volume is already
degraded. `k8s-reboot.yml` automates the **reboot**; for a node that hosts
controllers, empty it with [stop-first](#preferred-procedure-stop-first-one-volume-at-a-time)
first. The playbook's own controller shuffle is the part to be careful with.

### Option A — reboot flow (after the node has been emptied)

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini k8s-reboot.yml --limit <node> \
  -e k8s_reboot_via_pve=true \
  -e k8s_reboot_skip_jiva_shuffle=true \
  -e k8s_reboot_allow_parked_jiva_replicas=true
```

| Flag | Effect | Use when |
| --- | --- | --- |
| `k8s_reboot_via_pve=true` | Power-cycles the VM with `qm reboot` from Proxmox instead of rebooting inside the guest. Asserts the boot id changed and `qm pending` is empty afterwards. | The VM has **pending hardware changes** (disk `discard`, size, `agent` options). An in-guest reboot keeps the same QEMU process, so they are never applied. |
| `k8s_reboot_skip_jiva_shuffle=true` | Does not move controllers off the node first. Volumes take one interruption when the node goes down instead of one per controller. | The node was already emptied by hand, or you accept one interruption. **Recommended on a three-node cluster**: the shuffle mostly relocates the pile. |
| `k8s_reboot_allow_parked_jiva_replicas=true` | Excludes `jiva-rep` pods from the stuck-Pending pre-flight. | You parked replicas by deleting them on the cordoned node (stop-first step 3). Without it the pre-flight aborts on them. |
| `k8s_reboot_jiva_quorum_retries` / `_delay` | The quorum gate retries (default 10 × 15 s) rather than failing on the first look. | Volumes are still settling after a shuffle. |

If you leave the shuffle **on** (the default), `k8s-reboot.yml` announces the migration and moves controllers off one at a time, waiting for each JivaVolume to be `Ready`, then re-validates quorum before it cordons, drains and reboots. Read [What Moving a Controller Actually Does](#what-moving-a-controller-actually-does) before relying on that: the `Ready` it waits for comes from the lagging CR, not the controller, and on 2026-09-16 the sequence cascaded into three read-only PVCs and aborted before the reboot ever happened.

### Option B — shuffle only (no reboot)

The migration is also available standalone via the
`ansible-role-microk8s` role, gated behind an explicit tag so it can never
run as part of a normal role application:

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini update/home.yml \
  --limit <node> --tags jiva-ctrl-shuffle
```

Or from another playbook:

```yaml
- name: Shuffle jiva-ctrl pods off the target node
  ansible.builtin.include_role:
    name: ansible-role-microk8s
    tasks_from: jiva_ctrl_shuffle
```

### What the automation does (and does not do)

- Finds controllers by **label** (`openebs.io/controller=jiva-controller`
  for legacy 2.12 volumes, `openebs.io/component=jiva-controller` for
  3.6 CSI volumes) — do not rely on `jiva.*ctrl` pod-name matching; legacy
  controller pods are named `pvc-...-ctrl-...` without "jiva"
- Aborts if any JivaVolume is `Syncing`/`Error`/`Unknown` before starting
- Cordons the node so controllers cannot reschedule back, and **leaves it
  cordoned** — Option A's reboot flow uncordons at the end; after a
  standalone Option B run you must `kubectl uncordon <node>` yourself
- Moves one controller at a time: delete pod → wait for the Deployment
  rollout → replacement `2/2 Running` on another node → JivaVolume `Ready`
  (CSI volumes; legacy volumes have no JivaVolume CR and get a settle
  pause instead)
- Fails if any controller remains on the node afterwards
- It does **not** stop consumers. Each controller move therefore runs under
  a live consumer, and a re-sync that outlasts the 5-second iSCSI ping
  timeout puts that consumer's filesystem read-only. Do not count on
  the iSCSI session transparently reconnecting to the moved controller. If a
  filesystem has already gone read-only, use
  [jiva-ctrl-eviction-iscsi-ro-filesystem.md](jiva-ctrl-eviction-iscsi-ro-filesystem.md)
  instead — it is too late to shuffle

Implementation: `tasks/jiva_ctrl_shuffle.yml` in
[ansible-role-microk8s](https://github.com/pgmac-net/ansible-role-microk8s)
(PGM-240); reboot integration in `ansible/k8s-reboot.yml` (PGM-239/PGM-240;
flags added in ansible#294 and #297).
