---
tags:
  - runbook
---

# Runbooks

Operational runbooks for diagnosing and recovering from known failure patterns on pvek8s.

| Runbook | Service | Description |
|---------|---------|-------------|
| [Calico CNI Unauthorized](calico-cni-unauthorized.md) | calico/cni | Pods stuck ContainerCreating — expired or wrong-SA calico-kubeconfig JWT causes Unauthorized on pod sandbox creation |
| [Kubelet Silent Stall](kubelet-silent-stall.md) | microk8s | Node shows Ready but pods never schedule — eviction manager stall or pod watch goroutine stall |
| [Kubelet Volume Manager Stall](kubelet-volume-manager-stall.md) | microk8s/openebs | Pods stuck ContainerCreating with no iSCSI sessions — processorListener goroutine blocked after kine watch disruption |
| [Control-Plane Watch-Cache Freeze](control-plane-watch-cache-freeze.md) | microk8s | Zero pod creations / stalled reflectors — apiserver watch cache frozen by broken kine feed; RV=0 test; restart k8s-dqlite before kubelite |
| [KCM Stale terminatingReplicas](kcm-stale-terminating-replicas.md) | microk8s/kube-controller-manager | ReplicaSet refuses to create pods — KCM pod informer stale after kine disruption; terminatingReplicas stuck |
| [Jiva CSI Mount Proliferation](jiva-csi-mount-proliferation.md) | openebs-jiva-csi | Duplicate bind mounts accumulate per kubelite restart, causing findmnt/Ansible hangs |
| [Jiva CSI Stale Node Attachment](jiva-csi-stale-node-attachment.md) | openebs-jiva-csi | PVC stuck ContainerCreating after pod force-deleted and rescheduled to different node — stale nodeID label, mountInfo, and iSCSI session on old node |
| [Jiva-ctrl Eviction → iSCSI → EXT4 Read-Only](jiva-ctrl-eviction-iscsi-ro-filesystem.md) | openebs-jiva-csi | Pod filesystem goes read-only after jiva-ctrl pod evicted, dropping iSCSI session and triggering EXT4 journal abort |
| [Safe Node Restart (jiva-ctrl hosted)](jiva-ctrl-node-rolling-restart.md) | openebs-jiva-csi | Pre-restart procedure for nodes hosting jiva-ctrl pods — migrate workloads and verify iSCSI sessions clear before restarting |
| [Jiva Controller Endpoint Deadlock](jiva-ctrl-endpoint-deadlock.md) | openebs-jiva/kcm | Replica CrashLoopBackOff with controller endpoints stuck in `notReadyAddresses` — CM write failure creates self-sustaining deadlock; fix by restarting k8s-dqlite (follower then leader) |
| [dqlite Write Contention](dqlite-write-contention.md) | microk8s/dqlite | `database is locked (try:500)` under kubelite restart storms — prevention, recovery, phantom RS fix |
| [dqlite Datastore Vacuum](dqlite-datastore-vacuum.md) | microk8s/dqlite | Freelist bloat makes every raft snapshot a 200MB+ fsync burst feeding lock storms — full export/rebuild/rejoin procedure; `dbctl backup` silently broken on 1.35 |
| [k8s Upgrade Post-Upgrade Validation](k8s-upgrade-validation.md) | microk8s | Post-rolling-upgrade checks for stale EndpointSlice IPs and stale Calico IPAM blocks that silently cause service disruptions |

## Scripts

| Script | When to use | Description |
|--------|-------------|-------------|
| [pvek8s-outage-recovery.sh](pvek8s-outage-recovery.sh) | Post-power-outage or full-cluster restart | 10-phase recovery: cordon k8s03, jiva CSI cleanup, orphaned shim kill, dqlite+kubelite restart on k8s03 and k8s01, stuck pod sweep, CoreDNS fix, OpenEBS reset, uncordon |
