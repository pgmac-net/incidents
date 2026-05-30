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
| [KCM Stale terminatingReplicas](kcm-stale-terminating-replicas.md) | microk8s/kube-controller-manager | ReplicaSet refuses to create pods — KCM pod informer stale after kine disruption; terminatingReplicas stuck |
| [Jiva CSI Mount Proliferation](jiva-csi-mount-proliferation.md) | openebs-jiva-csi | Duplicate bind mounts accumulate per kubelite restart, causing findmnt/Ansible hangs |
| [Jiva-ctrl Eviction → iSCSI → EXT4 Read-Only](jiva-ctrl-eviction-iscsi-ro-filesystem.md) | openebs-jiva-csi | Pod filesystem goes read-only after jiva-ctrl pod evicted, dropping iSCSI session and triggering EXT4 journal abort |
| [Safe Node Restart (jiva-ctrl hosted)](jiva-ctrl-node-rolling-restart.md) | openebs-jiva-csi | Pre-restart procedure for nodes hosting jiva-ctrl pods — migrate workloads and verify iSCSI sessions clear before restarting |
| [dqlite Write Contention](dqlite-write-contention.md) | microk8s/dqlite | `database is locked (try:500)` under kubelite restart storms — prevention, recovery, phantom RS fix |

## Scripts

| Script | When to use | Description |
|--------|-------------|-------------|
| [pvek8s-outage-recovery.sh](pvek8s-outage-recovery.sh) | Post-power-outage or full-cluster restart | 10-phase recovery: cordon k8s03, jiva CSI cleanup, orphaned shim kill, dqlite+kubelite restart on k8s03 and k8s01, stuck pod sweep, CoreDNS fix, OpenEBS reset, uncordon |
