# Incidents

Post-incident reviews documenting what went wrong, why, and how we fixed it.

| Date | Sev | Title | Duration |
|------|-----|-------|----------|
| 2026-09-02 | <span class="sev sev--p1">P1</span> | [pvek8s Total Control Plane Loss and Read-Only Volume Cascade — systemd +esm4 PID 1 Segfault, a Recurring dqlite/iSCSI Storm, and Two Rounds of Storage Recovery](2026-09-02-systemd-esm4-pid1-segfault-control-plane-loss.md) | ~33h across two linked incidents |
| 2026-08-15 | <span class="sev sev--p2">P2</span> | [hal NFS Handle Invalidation — Silent SQLite Failures Across Three Services and a 2.7-Day Detection Gap](2026-08-15-hal-nfs-handle-invalidation-silent-sqlite-failures.md) | ~2d 16h 38m |
| 2026-08-06 | <span class="sev sev--p2">P2</span> | [pvek8s Read-Only Volume Cascade — dqlite Storm, iSCSI Starvation, and a 17-Hour Action Gap](2026-08-06-dqlite-storm-iscsi-ro-volumes-detection-gap.md) | ~17h 57m |
| 2026-08-01 | <span class="sev sev--p2">P2</span> | [hal NFS Export Failure — Cluster-Wide Stale Mounts and a 7h Detection Gap](2026-08-01-hal-nfs-export-failure-stale-mounts.md) | ~8h 5m total |
| 2026-07-13 | <span class="sev sev--p3">P3</span> | [pvek8s Storage Cascade — ArgoCD Sync Burst, Watch-Cache Freeze, and jiva iSCSI Read-Only Volumes](2026-07-13-argocd-sync-burst-watch-cache-freeze-jiva-ro.md) | ~1h 8m active |
| 2026-07-11 | <span class="sev sev--p2">P2</span> | [pvek8s Scheduling Outage — k8s03 Watch-Cache Freeze and Stale-Unit Watchdog Lockout](2026-07-11-k8s03-watch-cache-freeze-stale-unit-lockout.md) | ~3h 0m scheduling outage |
| 2026-07-09 | <span class="sev sev--p2">P2</span> | [pvek8s Scheduling Outage — k8s03 Watch-Cache Freeze and Auto-Remediation Delivery Failure](2026-07-09-k8s03-watch-cache-freeze-remediation-delivery-failure.md) | ~5h 19m active |
| 2026-06-28 | <span class="sev sev--p2">P2</span> | [pvek8s dqlite WAL Lock Storm — Jiva Controller Endpoint Deadlock](2026-06-28-dqlite-lock-storm-jiva-endpoint-deadlock.md) | ~11h 11m total degradation |
| 2026-06-24 | <span class="sev sev--p2">P2</span> | [k8s02 Watch-Cache Freeze — dqlite Leadership Disruption Stalls Pod Creation](2026-06-24-k8s02-watch-cache-freeze-dqlite-leadership-disruption.md) | ~4h active |
| 2026-06-17 | <span class="sev sev--p3">P3</span> | [seerr Jiva CSI Stale Node Attachment — PVC Stuck After Cross-Node Rescheduling](2026-06-17-seerr-jiva-csi-stale-node-attachment.md) | ~31m active |
| 2026-06-05 | <span class="sev sev--p1">P1</span> | [pvek8s Kernel Update — Simultaneous 3-Node Reboot Cascade](2026-06-05-pvek8s-kernel-reboot-cluster-recovery-failure.md) | ~6h 58m |
| 2026-05-28 | <span class="sev sev--p2">P2</span> | [pvek8s Post-Power-Outage Recovery — kubelet Volume Manager Stall and KCM Stale terminatingReplicas](2026-05-28-pvek8s-post-outage-kubelet-informer-kcm-stall.md) | ~5h 20m active |
| 2026-05-23 | <span class="sev sev--p3">P3</span> | [k8s01 Calico CNI Unauthorized — Stale Pod-Bound Token After Calico Upgrade](2026-05-23-k8s01-calico-cni-unauthorized-stale-kubeconfig.md) | ~1h active |
| 2026-05-18 | <span class="sev sev--p2">P2</span> | [k8s03 Extended Recovery — kine Watch Corruption, VXLAN Route Corruption, and Kubelet Watch Stream Stall](2026-05-18-k8s03-extended-recovery-kine-watch-vxlan-route-corruption.md) | ~2h10m active |
| 2026-05-17 | <span class="sev sev--p2">P2</span> | [k8s03 PLEG Deadlock — Stale Calico IPAM Blocks + Generic PLEG Serial-Poll Vulnerability](2026-05-17-k8s03-pleg-deadlock-stale-ipam-blocks.md) | ~9 hours active |
| 2026-05-16 | <span class="sev sev--p2">P2</span> | [microk8s 1.34 → 1.35 Rolling Upgrade — cgroup v2, containerd Shim, Disk Pressure, and Kubelet Stall](2026-05-16-microk8s-1.35-upgrade-cgroup-v2-containerd-disk-pressure.md) | ~8.75 hours active |
| 2026-05-15 | <span class="sev sev--p3">P3</span> | [AWX Automation Pod Stuck Pending — Calico RBAC Gap + dqlite Write Storm](2026-05-15-awx-pod-pending-calico-rbac-dqlite-write-storm.md) | ~13 min silent |
| 2026-04-12 | <span class="sev sev--p1">P1</span> | [pvek8s Complete Cluster Outage — dqlite Quorum Loss and Ansible-Injected Invalid Flags](2026-04-12-pvek8s-dqlite-quorum-loss-complete-cluster-outage.md) | 7 days degraded |
| 2026-04-02 | <span class="sev sev--p2">P2</span> | [dqlite Snapshot Bloat → kube-apiserver Instability → Controller Crash-Loop Cascade and Watch Stream Failure](2026-04-02-dqlite-snapshot-crash-loop-watch-stream-failure.md) | ~36h |
| 2026-03-30 | <span class="sev sev--p2">P2</span> | [Sonarr Outage Due to iSCSI Hairpin NAT Failure on k8s03](2026-03-30-sonarr-iscsi-hairpin-containercreating.md) | Unknown silent failure period + ~45m active investigation and recovery |
| 2026-03-28 | <span class="sev sev--p2">P2</span> | [Radarr Outage — OpenEBS Jiva Replica Divergence (Second Occurrence)](2026-03-28-radarr-jiva-replica-divergence-second.md) | ~30h silent failure + ~50m active recovery |
| 2026-03-28 | <span class="sev sev--p2">P2</span> | [ARC GitHub Actions Runner Pods Stuck Pending — Kubelet Sync Loop Stall and Multi-Node Degradation](2026-03-28-arc-pods-pending-kubelet-sync-stall.md) | ~7h40m |
| 2026-02-22 | <span class="sev sev--p2">P2</span> | [Radarr Outage Due to OpenEBS Jiva Replica Divergence](2026-02-22-radarr-openebs-jiva-replica-divergence.md) | ~16h30m silent failure + ~47m active recovery |
| 2026-01-06 | <span class="sev sev--p1">P1</span> | [Cascading Kubernetes Cluster Failures](2026-01-06-cluster-cascade-failure.md) | ~8 hours |