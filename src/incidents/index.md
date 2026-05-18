# Incidents

Post-incident reviews documenting what went wrong, why, and how we fixed it.

| Date | Title | Severity | Duration |
|------|-------|----------|----------|
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
