# Post-Incident Reviews

Welcome to the internal Post-Incident Review (PIR) documentation site. This site contains detailed analyses of system incidents, root cause investigations, and lessons learned.

## Purpose

Post-incident reviews are critical for:

- **Learning from failures** - Understanding what went wrong and why
- **Preventing recurrence** - Implementing safeguards and preventive measures
- **Improving systems** - Identifying architectural and operational improvements
- **Knowledge sharing** - Building team expertise and institutional memory

## PGMac . Net Service Status

These documents are an artefact to give clarity and detail on incidents discovered and communicated through my [Nagios Status Page](https://statuspage.pgmac.net.au/)

## Recent Incidents

### 2026

- [2026-03-30 - Sonarr Outage Due to iSCSI Hairpin NAT Failure on k8s03](incidents/2026-03-30-sonarr-iscsi-hairpin-containercreating.md)
  - **Severity**: P2
  - **Duration**: Unknown silent failure + ~45m active investigation and recovery
  - **Summary**: Sonarr became stuck in ContainerCreating on k8s03 because microk8s Calico does not support hairpin NAT for host-namespace iSCSI clients — the kubelet's iSCSI connection to the Jiva controller ClusterIP was looped back to the same node and dropped at the PDU receive stage. Resolution required cordoning k8s03 and force-deleting the pod so it rescheduled to a different node.

- [2026-03-28 - Radarr Outage — OpenEBS Jiva Replica Divergence (Second Occurrence)](incidents/2026-03-28-radarr-jiva-replica-divergence-second.md)
  - **Severity**: High
  - **Duration**: ~30h silent failure + ~50m active recovery
  - **Summary**: Second occurrence of all three OpenEBS Jiva replicas entering CrashLoopBackOff with diverged snapshot chains, rendering the radarr-config PVC unmountable. Unlike the February incident, no single authoritative replica existed, requiring all data directories to be wiped (total data loss). Recovery was further complicated by a ghost RW replica entry in the controller API and a stale iSCSI session on k8s03.

- [2026-03-28 - ARC GitHub Actions Runner Pods Stuck Pending — Kubelet Sync Loop Stall](incidents/2026-03-28-arc-pods-pending-kubelet-sync-stall.md)
  - **Severity**: High
  - **Duration**: ~7h40m
  - **Summary**: Five ARC runner pods remained Pending for over 7 hours due to a layered failure: disk exhaustion on k8s02 triggered image pull failures, recovery attempts caused Calico disruption and PLEG desync, and a ghost containerd record on k8s01 (orphaned from a force-deleted pod) stalled the kubelet sync loop every 60 seconds. Resolution required clearing the ghost container, restarting kubelite, pinning the ARC controller to k8s01, and disabling a Wazuh webhook returning 500 errors on every API server event.

- [2026-02-22 - Radarr Outage Due to OpenEBS Jiva Replica Divergence](incidents/2026-02-22-radarr-openebs-jiva-replica-divergence.md)
  - **Severity**: High
  - **Duration**: ~16h30m silent failure + ~47m active recovery (~20h47m total outage)
  - **Summary**: Radarr became completely unavailable when all three OpenEBS Jiva storage replicas simultaneously entered CrashLoopBackOff following an ungraceful shutdown during an active rebuild, leaving the iSCSI-backed PVC unmountable due to ext4 journal corruption

- [2026-01-06 - Cascading Kubernetes Cluster Failures](incidents/2026-01-06-cluster-cascade-failure.md)
  - **Severity**: Critical
  - **Duration**: ~8 hours (Phase 1-2) + 16.5 hours (Phase 3) + 12+ hours (Phase 5)
  - **Summary**: Multi-phase cascading failure across microk8s cluster spanning 4 days, involving node reboots, kubelet failures, disk exhaustion, storage issues, job controller corruption, and container runtime corruption

## PIR Structure

Each post-incident review follows a standard structure:

1. **Executive Summary** - High-level overview of the incident
2. **Timeline** - Detailed chronological sequence of events
3. **Root Causes** - Analysis of underlying issues
4. **Impact** - Affected services, duration, and scope
5. **Resolution Steps** - Actions taken to resolve the incident
6. **Verification** - Confirmation of service restoration
7. **Preventive Measures** - Immediate and long-term improvements
8. **Lessons Learned** - Key takeaways and insights
9. **Action Items** - Specific follow-up tasks with owners

## Contributing

When creating a new PIR document:

1. Use the naming convention: `YYYY-MM-DD-brief-description.md`
2. Place documents in the `docs/incidents/` directory
3. Update the `mkdocs.yml` navigation section
4. Follow the standard PIR structure template
5. Include relevant technical details, commands, and verification steps

## Navigation

Use the navigation menu to browse incidents by date or search for specific topics using the search functionality.
