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
| [Jiva CSI Mount Proliferation](jiva-csi-mount-proliferation.md) | openebs-jiva-csi | Duplicate bind mounts accumulate per kubelite restart, causing findmnt/Ansible hangs |
| [dqlite Write Contention](dqlite-write-contention.md) | microk8s/dqlite | `database is locked (try:500)` under kubelite restart storms — prevention, recovery, phantom RS fix |
