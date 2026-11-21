---
title: "Rolling kernel reboot of pvek8s"
tags:
  - runbook
  - microk8s
  - reboot
  - jiva
  - dqlite
  - argocd
  - k8s01
  - k8s02
  - k8s03
---

# Rolling Kernel Reboot of pvek8s — Nagios `reboot-required` on All Three Nodes

**Service:** pvek8s (microk8s HA, k8s01/k8s02/k8s03)
**First documented:** 2026-11-21
**PIR:** [pvek8s rolling kernel reboot — Jiva stop-first moves, post-reboot stale sandboxes and AWX credential loss](../incidents/2026-11-21-pvek8s-rolling-reboot-jiva-moves-awx-secret-loss.md)
**Incident:** [pgmac-net/incidents#106](https://github.com/pgmac-net/incidents/issues/106)

---

## When to Use This Runbook

Nagios `reboot-required` goes CRITICAL when `/var/run/reboot-required` is older than 24 hours (kernel or other package updates are installed but not active). Nothing is broken, but the reboot is a P3-sized operation on this cluster: the 2026-11-21 reboot took ~7 hours and stopped ten apps. Plan it as maintenance.

This runbook is the order and the gates. The mechanics of emptying a node that hosts Jiva controllers are in [Safe Node Restart (jiva-ctrl hosted)](jiva-ctrl-node-rolling-restart.md).

---

## Detection

```bash
# Which nodes need it, and since when
ssh <node> 'ls -l /var/run/reboot-required; cat /var/run/reboot-required.pkgs'
```

---

## Plan Before Touching Anything

1. **Find the leaders.** Every leadership move costs a write storm of ~15 minutes, so reboot the leaders last and as few times as possible.
    - dqlite raft leader: the query in [dqlite-write-contention.md](dqlite-write-contention.md)
    - `kube-controller-manager` and `kube-scheduler` leases: `kubectl -n kube-system get lease`
2. **Find the Jiva controllers.** `kubectl get pods -A -o wide | grep jiva-ctrl`. On 2026-11-21 all 11 were on k8s03 (readarr's moved to k8s03 when k8s01 rebooted).
3. **Order** the nodes: a node with no leader role and few controllers first, the dqlite leader last. A stale peer from an earlier reboot can change this: on 2026-11-21 k8s02 was moved ahead of k8s03 because its containerd state kept producing zombie replicas.
4. **Block ArgoCD self-heal** for the duration, otherwise scaled-down apps come straight back. Add a deny `syncWindow` on project `default` (applications `*`, `manualSync: true`, a `schedule` and `duration` covering the work). It is not extended automatically, so extend it if the work overruns (it was raised from 4h to 8h). Remove it only when every app is back at its intended replicas.
5. Check `pve2` RAID state first: boot I/O lands on the degraded array.

---

## Gates Between Nodes

Do not start the next node until all of these hold:

| Gate | Check |
| --- | --- |
| Node is back | `Ready`, `reboot-required` check OK, `calico-node`, `jiva-csi-node`, metallb speaker, ingress-nginx `Running` |
| No stale sandboxes | Nagios `microk8s-sandbox-changed` OK; no pod in `CreateContainerError` with "name is reserved" — see [fix](#fix-post-reboot-sandbox-loop) |
| dqlite quiet | `microk8s-dqlite-lock`, `microk8s-kine` and `microk8s-kine-reconnect-failures` OK on all three nodes for ~15 minutes. The playbook's own gate is stricter than Nagios (it trips on ≥ a handful of `database is locked` in 10 minutes, including ones caused by your own scale-downs) |
| Jiva | Every volume 3/3 `RW` (see [jiva-ctrl-replica-registration-wedge.md](jiva-ctrl-replica-registration-wedge.md) for the query), or deliberately 2/2 with the third parked |
| No stuck Pending pod | The playbook aborts if any pod is Pending > 3 minutes anywhere in the cluster, even one unrelated to the node (AWX did this) |
| Peers uncordoned | The playbook aborts if any peer is cordoned; uncordon, then check where evicted pods and moved controllers can land |

---

## Reboot a Node

1. Stop consumers and move Jiva controllers off the node, one volume at a time: [stop-first procedure](jiva-ctrl-node-rolling-restart.md#preferred-procedure-stop-first-one-volume-at-a-time). Scale down only what the move requires, and name the controller pod exactly: `kubectl` does not expand a `*jiva-ctrl*` glob and a delete with one is a silent NotFound.
2. Run the playbook with the Jiva shuffle off (three-node cluster):

    ```bash
    ansible-playbook k8s-reboot.yml --limit <node> -e k8s_reboot_skip_jiva_shuffle=true
    # add -e k8s_reboot_allow_parked_jiva_replicas=true if replicas are deliberately parked Pending
    ```

3. Watch the gates above, then the next node.

---

## Fix: Post-Reboot Sandbox Loop

Seen after all three reboots on 2026-11-21. Signature on the node:

```
SandboxChanged ... failed to reserve sandbox name ... is reserved for "<id>"
```

`calico-node` is `PodInitializing` with a restart count climbing (36–39), while `crictl pods` shows the container running in a sandbox that the kubelet keeps killing and recreating.

1. Check dqlite is quiet first. Do not restart kubelite while `kine` or dqlite checks are failing ([dqlite-write-contention.md](dqlite-write-contention.md)).
2. Removing the one dead sandbox (`crictl rmp <id>`) did **not** break the loop on 2026-11-21.
3. Cordon the node and restart kubelite, then uncordon after `calico-node` is `1/1`:

    ```bash
    microk8s kubectl cordon <node>
    sudo snap restart microk8s.daemon-kubelite
    ```

4. Expect a short `kine-reconnect-failures` burst from the restart itself; it clears once the 10-minute window passes it.

Some loops cleared on their own (k8s02 ingress-nginx, k8s03 metallb speaker and ingress-nginx after ~35 minutes), so give an isolated crash-loop a few minutes before restarting kubelite.

---

## Verification

```bash
kubectl get nodes                                        # → 3 Ready, none cordoned
kubectl get pods -A | grep -v -e Running -e Completed    # → empty
# Nagios: reboot-required OK on all nodes, dqlite/kine OK, argocd-apps OK
# ArgoCD: all Applications Synced and Healthy; hard-refresh any stuck Progressing
```

After removing the sync window, hard-refresh any Application still `Progressing` whose Deployment is fully available: after an `argocd-application-controller` restart four apps stayed stale for ~1h45m.

---

## References

- [PIR 2026-11-21](../incidents/2026-11-21-pvek8s-rolling-reboot-jiva-moves-awx-secret-loss.md)
- [Safe Node Restart (jiva-ctrl hosted)](jiva-ctrl-node-rolling-restart.md)
- [Jiva Controller Replica-Registration Wedge](jiva-ctrl-replica-registration-wedge.md)
- [Jiva Replica Corrupt Snapshot Chain](jiva-replica-corrupt-snapshot-chain.md)
- [dqlite Write Contention](dqlite-write-contention.md)
- [k8s Upgrade Post-Upgrade Validation](k8s-upgrade-validation.md)
- [pgmac-net/ansible#374](https://github.com/pgmac-net/ansible/issues/374) — automate the stop-first controller move
