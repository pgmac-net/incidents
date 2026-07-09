# Incidents

Post-incident reviews documenting what went wrong, why, and how we fixed it.

| Date | Title | Severity | Duration |
|------|-------|----------|----------|
| 2026-07-09 | [pvek8s Scheduling Outage — k8s03 Watch-Cache Freeze and Auto-Remediation Delivery Failure](2026-07-09-k8s03-watch-cache-freeze-remediation-delivery-failure.md) | High | ~5h 19m |
| 2026-06-28 | [pvek8s dqlite WAL Lock Storm — Jiva Controller Endpoint Deadlock](2026-06-28-dqlite-lock-storm-jiva-endpoint-deadlock.md) | High | ~11h 11m |
| 2026-06-24 | [k8s02 Watch-Cache Freeze — dqlite Leadership Disruption Stalls Pod Creation](2026-06-24-k8s02-watch-cache-freeze-dqlite-leadership-disruption.md) | High | ~4h |
| 2026-06-17 | [seerr Jiva CSI Stale Node Attachment — PVC Stuck After Cross-Node Rescheduling](2026-06-17-seerr-jiva-csi-stale-node-attachment.md) | Medium | ~31m |
| 2026-06-05 | [pvek8s Kernel Update — Simultaneous 3-Node Reboot Cascade](2026-06-05-pvek8s-kernel-reboot-cluster-recovery-failure.md) | P1 | ~6h 58m |
| 2026-05-28 | [pvek8s Post-Power-Outage Recovery — kubelet Volume Manager Stall and KCM Stale terminatingReplicas](2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md) | High | ~5h 20m |
| 2026-05-23 | [k8s01 Calico CNI Unauthorized — Stale Pod-Bound Token After Calico Upgrade](2026-05-23-k8s01-calico-cni-unauthorized-stale-kubeconfig.md) | Medium | ~1h |
| 2026-05-18 | [k8s03 Extended Recovery — kine Watch Corruption, VXLAN Route Corruption, and Kubelet Watch Stream Stall](2026-05-18-k8s03-extended-recovery-kine-watch-vxlan-route-corruption.md) | High | ~2h10m |
| 2026-05-17 | [k8s03 PLEG Deadlock — Stale Calico IPAM Blocks + Generic PLEG Serial-Poll Vulnerability](2026-05-17-k8s03-pleg-deadlock-stale-ipam-blocks.md) | High | ~9h |
| 2026-05-16 | [microk8s 1.34 → 1.35 Rolling Upgrade — cgroup v2, containerd Shim, Disk Pressure, and Kubelet Stall](2026-05-16-microk8s-1.35-upgrade-cgroup-v2-containerd-disk-pressure.md) | High | ~8.75h |
| 2026-05-15 | [AWX Automation Pod Stuck Pending — Calico RBAC Gap + dqlite Write Storm](2026-05-15-awx-pod-pending-calico-rbac-dqlite-write-storm.md) | Medium | ~13 min silent + ~8 min to fix |
| 2026-04-12 | [pvek8s Complete Cluster Outage — dqlite Quorum Loss and Ansible-Injected Invalid Flags](2026-04-12-pvek8s-dqlite-quorum-loss-complete-cluster-outage.md) | Critical | 7d degraded + ~1h 12m full outage |
| 2026-04-02 | [dqlite Snapshot Bloat → kube-apiserver Instability → Controller Crash-Loop Cascade and Watch Stream Failure](2026-04-02-dqlite-snapshot-crash-loop-watch-stream-failure.md) | High | ~7h |
| 2026-03-30 | [Sonarr Outage Due to iSCSI Hairpin NAT Failure on k8s03](2026-03-30-sonarr-iscsi-hairpin-containercreating.md) | High | ~45m |
| 2026-03-28 | [Radarr Outage — OpenEBS Jiva Replica Divergence (Second Occurrence)](2026-03-28-radarr-jiva-replica-divergence-second.md) | High | ~30h |
| 2026-03-28 | [ARC GitHub Actions Runner Pods Stuck Pending — Kubelet Sync Loop Stall and Multi-Node Degradation](2026-03-28-arc-pods-pending-kubelet-sync-stall.md) | High | ~7h40m |
| 2026-02-22 | [Radarr Outage Due to OpenEBS Jiva Replica Divergence](2026-02-22-radarr-openebs-jiva-replica-divergence.md) | High | ~17h |
| 2026-01-06 | [Cascading Kubernetes Cluster Failures](2026-01-06-cluster-cascade-failure.md) | Critical | ~3 days |
