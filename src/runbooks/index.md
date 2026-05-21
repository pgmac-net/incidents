---
tags:
  - runbook
---

# Runbooks

Operational runbooks for diagnosing and recovering from known failure patterns on pvek8s.

| Runbook | Service | Description |
|---------|---------|-------------|
| [Kubelet Silent Stall](kubelet-silent-stall.md) | microk8s | Node shows Ready but pods never schedule — eviction manager stall or pod watch goroutine stall |
| [Jiva CSI Mount Proliferation](jiva-csi-mount-proliferation.md) | openebs-jiva-csi | Duplicate bind mounts accumulate per kubelite restart, causing findmnt/Ansible hangs |
