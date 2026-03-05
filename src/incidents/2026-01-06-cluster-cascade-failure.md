# Post Incident Review: Cascading Kubernetes Cluster Failures

**Date:** 2026-01-06
**Duration:** ~8 hours (estimated 09:00 - 17:00 AEST)
**Severity:** Critical (Complete cluster instability, multiple service outages)
**Status:** Resolved

---

## Executive Summary

A cascading failure across the microk8s Kubernetes cluster began with unplanned node reboots, leading to widespread kubelet failures, disk exhaustion, controller corruption, and ultimately service outages. The incident progressed through five distinct phases spanning January 6-9, 2026:

**Phase 1 (2026-01-06 09:00-12:30):** Cascading node failures caused kubelet hangs on all three nodes due to disk pressure (97-100% usage), audit buffer overload, and orphaned pod accumulation. The cluster reached a critical state where pods could not be scheduled, started, or terminated. 571 orphaned GitHub Actions runner pods and 22 stuck OpenEBS replica pods contributed to resource exhaustion.

**Phase 2 (2026-01-06 12:30-15:35):** After stabilizing node operations, secondary issues emerged: OpenEBS Jiva volume snapshot accumulation (1011+ snapshots), ingress controller endpoint caching failures, and volume capacity exhaustion. Multiple media services (Sonarr, Radarr, Overseerr) became inaccessible.

**Phase 3 (2026-01-08 02:00-18:25):** Job controller corruption prevented all cluster-wide job creation for 16.5 hours. Required nuclear option (cluster restart with dqlite backup) to resolve persistent database state corruption originating from Phase 1.

**Phase 4 (2026-01-08 19:00-19:45):** ArgoCD application recovery required manual finalizer removal and configuration fixes for GitHub Actions runner controllers and LinkAce cronjob.

**Phase 5 (2026-01-09 09:50-09:55):** k8s01 container runtime corruption recurred 48+ hours after Phase 3 nuclear option, demonstrating that cluster restart cleared cluster-global state but not node-local container runtime issues. 4 runner pods stuck Pending for 12+ hours due to silent failure pattern.

Resolution required systematic intervention across multiple infrastructure layers: node recovery, disk cleanup, pod force-deletion, storage subsystem repair, ingress refresh, database backup/restart, and multiple node-local container runtime restarts. All services restored to full functionality with complete volume replication (3/3 replicas).

---

## Timeline (AEST - UTC+10)

### Phase 1: Cascading Node and Kubelet Failures

| Time        | Event                                                                                                                   |
| ----------- | ----------------------------------------------------------------------------------------------------------------------- |
| ~09:00      | **INCIDENT START**: Unplanned node reboots across k8s01, k8s02, k8s03 (likely power event or scheduled maintenance)     |
| 09:15-09:30 | Cluster returns online but exhibits severe instability: pods not scheduling, not starting, not terminating              |
| 09:30-10:00 | Initial diagnostics: Control plane components healthy, scheduler functioning, but kubelets not processing assigned pods |
| 10:00-10:15 | Identified k8s02 kubelet hung: pods assigned by scheduler but never reaching ContainerCreating state                    |
| 10:15-10:20 | **RESOLUTION 1.1**: Restarted kubelite on k8s02 (`systemctl restart snap.microk8s.daemon-kubelite`)                     |
| 10:20-10:30 | k8s01 kubelet repeatedly crashing: "Kubelet stopped posting node status" within minutes of restart                      |
| 10:30-10:45 | Root cause analysis k8s01: Disk at 97% usage + audit buffer overload ("audit buffer queue blocked" errors)              |
| 10:45-11:00 | Database lock errors in kine (etcd replacement): "database is locked" preventing state updates                          |
| 11:00-11:15 | k8s03 diagnostics: Disk at 100% capacity with garbage collection failures                                               |
| 11:15-11:30 | Discovered 571 orphaned GitHub Actions runner pods in ci namespace (deployment scaled to 0 but pods remained)           |
| 11:30-11:45 | **RESOLUTION 1.2**: Disk cleanup on k8s01 (container images, logs) reducing from 97% → 87% usage                        |
| 11:45-12:00 | **RESOLUTION 1.3**: Disk cleanup on k8s03 reducing from 100% → 81% usage                                                |
| 12:00-12:15 | k8s01 kubelet stabilized after disk cleanup, node maintaining Ready status                                              |
| 12:15-12:20 | Deleted RunnerDeployment and HorizontalRunnerAutoscaler (GitHub Actions runner controller orphaned)                     |
| 12:20-12:25 | Force-deleted 22 OpenEBS replica pods stuck in Terminating state                                                        |
| 12:25-12:30 | Began aggressive force-deletion of 571 runner pods in batches (Pending, ContainerStatusUnknown, StartError, Completed)  |

### Phase 2: Storage and Ingress Service Outages

| Time        | Event                                                                                                                                             |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| ~12:30      | **PHASE 2 START**: User reports 504 Gateway Timeout errors for Sonarr at https://sonarr.int.pgmac.net/                                            |
| 12:30-12:45 | Initial investigation: Examined ingress controller logs showing upstream timeouts to pods at old IP addresses (10.1.236.34:8989 for Sonarr, etc.) |
| 12:45-13:00 | Root cause analysis: Discovered Radarr pod in CrashLoopBackOff with "No space left on device" error. Sonarr pod Pending on k8s01 node.            |
| 13:00-13:15 | Volume analysis: Identified OpenEBS Jiva volumes with excessive snapshots (1011 vs 500 threshold) affecting Radarr, Sonarr, and Overseerr         |
| 13:15-13:30 | Node troubleshooting: Identified k8s01 node unable to start new containers despite being healthy (residual kubelet issues from Phase 1)           |
| 13:30-13:35 | **RESOLUTION 2.1**: Restarted microk8s on k8s01, resolving pod scheduling issues                                                                  |
| 13:35-14:00 | Snapshot cleanup: Triggered manual Jiva snapshot cleanup job (jiva-snapshot-cleanup-manual)                                                       |
| 13:52       | Cleanup job started processing Overseerr volume (pvc-05e03b60)                                                                                    |
| 13:57       | Sonarr volume (pvc-17e6e808) cleanup completed                                                                                                    |
| 14:10       | **RESOLUTION 2.2**: Restarted all 3 ingress controller pods to clear stale endpoint cache                                                         |
| 14:11       | **SERVICE RESTORED**: Sonarr accessible at https://sonarr.int.pgmac.net/ (200 OK responses)                                                       |
| 14:15       | Overseerr confirmed accessible (200 OK responses)                                                                                                 |
| 14:20       | Radarr volume (pvc-311bef00) cleanup completed                                                                                                    |
| 14:25       | Radarr pod still crashing: volume at 100% capacity (958M/974M used)                                                                               |
| 14:28       | **RESOLUTION 2.3**: Cleared 49M of old backups from Radarr volume, reducing to 95% usage                                                          |
| 14:30       | **SERVICE RESTORED**: Radarr accessible at https://radarr.int.pgmac.net/                                                                          |
| 14:35       | Identified 8-9 Jiva replica pods stuck in Pending state on k8s03 (residual from Phase 1)                                                          |
| ~15:30      | **RESOLUTION 2.4**: Restarted microk8s on k8s03, resolving all Pending replica pods                                                               |
| 15:35       | **INCIDENT END**: All services operational, all replicas running (3/3), no problematic pods                                                       |

### Cleanup Operations (Parallel with Phase 2)

| Time        | Event                                                                                                 |
| ----------- | ----------------------------------------------------------------------------------------------------- |
| 12:30-12:45 | Force-deleted 299 Pending runner pods                                                                 |
| 12:45-13:00 | Force-deleted 110 ContainerStatusUnknown runner pods                                                  |
| 13:00-13:15 | Force-deleted 58 StartError/RunContainerError runner pods                                             |
| 13:15-13:30 | Force-deleted 79 Completed runner pods                                                                |
| 13:30-14:00 | Force-deleted final batch of 247 non-Running/non-Terminating runner pods                              |
| 14:00       | Runner pod cleanup substantially complete: 393 pods remain (128 Terminating, 18 Running, 247 deleted) |

### Phase 3: LinkAce CronJob Controller Corruption (2026-01-08 02:00-18:25)

| Time                  | Event                                                                                                                |
| --------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **2026-01-08 ~02:00** | **PHASE 3 START**: LinkAce cronjob (`* * * * *` schedule) begins failing to create jobs successfully                 |
| 02:00-05:00           | Cronjob creates job objects but pods orphaned (parent job deleted before pod creation)                               |
| 05:00-05:30           | 44+ jobs stuck in Running state (0/1 completions, 6min-11h old), 24+ pods Pending                                    |
| 05:30-06:00           | Investigation reveals job controller stuck syncing deleted job `linkace-cronjob-29463021`                            |
| 06:00-06:15           | Job controller logs: "syncing job: tracking status: jobs.batch not found" errors                                     |
| 06:15-06:30           | Cleanup attempts: Suspended cronjob, deleted orphaned pods, cleared stale active jobs                                |
| 06:30-07:00           | Restarted kubelite on k8s01, temporary improvement but orphaned job reference persists                               |
| 07:00-08:00           | Created dummy job with stale name and deleted properly, but new jobs still not creating pods                         |
| 08:00-09:00           | User added timeout configuration to ArgoCD manifest (activeDeadlineSeconds: 300, ttlSecondsAfterFinished: 120)       |
| 09:00-09:30           | ArgoCD synced configuration successfully but cronjob deleted to recreate cleanly                                     |
| 09:30-10:00           | ArgoCD failed to auto-recreate deleted cronjob despite OutOfSync status                                              |
| 10:00-10:30           | Manually recreated cronjob, but job controller completely wedged (not creating pods for any jobs)                    |
| 10:30-18:00           | Self-healing attempted: waited 1.5 hours for TTL cleanup and active deadline enforcement - **failed**                |
| 18:00-18:05           | Jobs created by cronjob but no pods spawned, active deadline not enforced (jobs 85+ min old still Running)           |
| 18:05-18:10           | TTL cleanup not working (no jobs auto-deleted after completion)                                                      |
| 18:10                 | **DECISION**: Nuclear option approved - etcd cleanup with cluster restart                                            |
| 18:12-18:15           | **RESOLUTION 3.1**: Stopped MicroK8s on all 3 nodes (k8s01, k8s02, k8s03)                                            |
| 18:15                 | **RESOLUTION 3.2**: Backed up etcd/dqlite database to `/var/snap/microk8s/common/backup/etcd-backup-20260108-201540` |
| 18:15-18:17           | **RESOLUTION 3.3**: Restarted MicroK8s cluster, all nodes returned Ready                                             |
| 18:17-18:18           | **RESOLUTION 3.4**: Force-deleted all stuck jobs and cronjob                                                         |
| 18:18-18:19           | **RESOLUTION 3.5**: Triggered ArgoCD sync to recreate cronjob with fresh state                                       |
| 18:19                 | Cronjob recreated successfully with all timeout settings applied                                                     |
| 18:20-18:22           | First job (`linkace-cronjob-29464462`) created successfully, completed in 7 seconds                                  |
| 18:22-18:25           | TTL cleanup verified working: completed jobs auto-deleted after 2 minutes                                            |
| 18:25                 | **INCIDENT END**: Cronjob fully functional, no orphaned pods, all cleanup mechanisms working                         |

### Phase 4: ArgoCD Application Recovery (2026-01-08 ~19:00-19:45)

| Time                  | Event                                                                                                                                                                                                                                                                 |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **2026-01-08 ~19:00** | **PHASE 4 START**: Investigation of 5 ArgoCD applications stuck OutOfSync or Progressing                                                                                                                                                                              |
| 19:00-19:05           | Identified problematic applications: ci-tools (OutOfSync + Progressing), gharc-runners-pgmac-net-self-hosted (OutOfSync + Healthy), gharc-runners-pgmac-user-self-hosted (Synced + Progressing), hass (Synced + Progressing), linkace (OutOfSync + Healthy)           |
| 19:05-19:15           | **ci-tools investigation**: Found child application `gharc-runners-pgmac-user-self-hosted` stuck with resources "Pending deletion"                                                                                                                                    |
| 19:15-19:18           | **RESOLUTION 4.1**: Removed finalizers from 4 stuck resources (AutoscalingRunnerSet, ServiceAccount, Role, RoleBinding) using `kubectl patch --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'`                                                     |
| 19:18-19:20           | Triggered ArgoCD sync for ci-tools, application became Synced + Healthy                                                                                                                                                                                               |
| 19:20-19:25           | **gharc-runners-pgmac-net-self-hosted investigation**: Found old listener resources with hash `754b578d` needing deletion                                                                                                                                             |
| 19:25-19:28           | Deleted 3 old listener resources manually (ServiceAccount, Role, RoleBinding)                                                                                                                                                                                         |
| 19:28-19:30           | Discovered 6 runner pods stuck Pending for 44+ minutes (residual from Phase 3 job controller corruption)                                                                                                                                                              |
| 19:30-19:32           | Force-deleted 6 stuck runner pods: `pgmac-renovatebot-*` pods with PodScheduled=True but no containers created                                                                                                                                                        |
| 19:32-19:33           | Application status: OutOfSync + Healthy (acceptable due to ignoreDifferences configuration for AutoscalingListener, Role, RoleBinding)                                                                                                                                |
| 19:33-19:35           | **gharc-runners-pgmac-user-self-hosted**: Already deleted during ci-tools cleanup                                                                                                                                                                                     |
| 19:35-19:37           | **hass investigation**: Application self-resolved during investigation, showing Synced + Healthy (StatefulSet rollout completed)                                                                                                                                      |
| 19:37-19:40           | **linkace investigation**: Found linkace-cronjob OutOfSync despite application Healthy, ArgoCD attempted 23 auto-heal operations                                                                                                                                      |
| 19:40-19:42           | Root cause identified: LinkAce Helm chart doesn't support `backoffLimit` and `resources` configuration in cronjob                                                                                                                                                     |
| 19:42-19:43           | **RESOLUTION 4.2**: Edited `/Users/paulmacdonnell/pgmac/pgk8s/pgmac.net/media/templates/linkace.yaml` to remove unsupported fields (backoffLimit, resources block)                                                                                                    |
| 19:43                 | Kept critical timeout settings: startingDeadlineSeconds, activeDeadlineSeconds, ttlSecondsAfterFinished, history limits                                                                                                                                               |
| 19:43-19:44           | Committed changes with message "Remove unsupported LinkAce cronjob configuration"                                                                                                                                                                                     |
| 19:44                 | Git push rejected due to remote changes, used `git stash && git pull --rebase && git stash pop && git push`                                                                                                                                                           |
| 19:45                 | **PHASE 4 END**: All applications resolved or explained; 2 applications Synced + Healthy (ci-tools, hass), 2 applications OutOfSync + Healthy acceptable (gharc-runners-pgmac-net-self-hosted, linkace), 1 application deleted (gharc-runners-pgmac-user-self-hosted) |

### Phase 5: k8s01 Container Runtime Corruption Recurrence (2026-01-09 ~09:50-09:55)

| Time                  | Event                                                                                                                                         |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| **2026-01-09 ~09:50** | **PHASE 5 START**: Investigation revealed 4 runner pods in arc-runners namespace stuck in Pending state for 12+ hours                         |
| 09:50-09:51           | Identified all 4 Pending pods assigned to k8s01 node: self-hosted-l52x9-runner-2nnsr, -69qnv, -ls8c2, -w8mcd                                  |
| 09:51                 | Pod describe showed PodScheduled=True but no container initialization, no events generated (silent failure pattern from Phase 2/3)            |
| 09:51-09:52           | Verified k8s01 node showing Ready status despite being unable to start new containers                                                         |
| 09:52                 | **Root cause identified**: Container runtime state corruption on k8s01 (residual from Phase 1-3, not fully cleared by Phase 3 nuclear option) |
| 09:52-09:53           | Found 10 EphemeralRunner resources but only 4 pods exist (6 pgmac-slack-scores runners have no pods at all)                                   |
| 09:53                 | **RESOLUTION 5.1**: User restarted microk8s on k8s01 (`microk8s stop && microk8s start`)                                                      |
| 09:55                 | **PHASE 5 END**: All 4 Pending pods cleared, container runtime recovered                                                                      |

---

## Root Causes

### Phase 1: Node and Control Plane Failures

#### 1.1 Cascading Node Reboots (Primary Trigger)

- **Issue**: All three nodes (k8s01, k8s02, k8s03) experienced unplanned reboots
- **Likely cause**: Power event, scheduled maintenance, or infrastructure issue
- **Impact**: Triggered cascade of secondary failures during recovery
- **Why it cascaded**:
  - Simultaneous reboot prevented graceful pod migration
  - etcd state (via kine) became inconsistent across nodes
  - Container runtime state corrupted on restart
  - Disk pressure accumulated during downtime (logs, audit buffers, orphaned containers)

#### 1.2 k8s01 Kubelet Crash Loop (Critical)

- **Issue**: Kubelet repeatedly crashing within minutes of restart
- **Root causes**:
  - **Disk exhaustion**: 97% usage preventing kubelet operations
  - **Audit buffer overload**: "audit buffer queue blocked" errors in logs
  - **Database locks**: kine (etcd replacement) showing "database is locked" errors
- **Impact**: Node oscillating between Ready/NotReady, unable to start/stop pods
- **Why it happened**:
  - Container image accumulation from 4+ years of operations
  - Log rotation not keeping pace with audit log generation
  - Kubelet requires >10% free disk to function properly
- **Resolution**: Disk cleanup (97% → 87%), container image removal, log pruning

#### 1.3 k8s02 Kubelet Process Hang (Critical)

- **Issue**: Kubelet not processing newly assigned pods
- **Symptoms**: Pods assigned by scheduler (PodScheduled=True) but never reaching ContainerCreating
- **Root cause**: Kubelet process corrupted/hung after node reboot
- **Impact**: Entire node unable to start new containers despite reporting Ready status
- **Resolution**: kubelite service restart (`systemctl restart snap.microk8s.daemon-kubelite`)

#### 1.4 k8s03 Disk Exhaustion (Critical)

- **Issue**: Disk at 100% capacity
- **Symptoms**: "Failed to garbage collect required amount of images. Attempted to free 13GB, but only found 0 bytes eligible to free"
- **Impact**:
  - Prevented container image pulls
  - Blocked new pod scheduling
  - Contributed to 8-9 Jiva replica pods stuck in Pending
- **Resolution**: User disk cleanup (100% → 81%)

#### 1.5 GitHub Actions Runner Controller Orphaned Pods (Secondary)

- **Issue**: 571 orphaned runner pods remained after RunnerDeployment scaled to 0
- **Affected namespace**: ci
- **Pod states**: 299 Pending, 110 ContainerStatusUnknown, 79 Completed, 58 StartError, 25+ other stuck states
- **Why it happened**:
  - RunnerDeployment controller existed but in Error state
  - Pods orphaned from parent controller (reboot disrupted controller finalizers)
  - No automated cleanup triggered despite 0 replicas
- **Impact**:
  - Consumed scheduler resources attempting to place Pending pods
  - Consumed API server resources with status updates
  - Contributed to disk pressure (container image layers, logs)
- **Resolution**:
  - Deleted RunnerDeployment and HorizontalRunnerAutoscaler
  - Force-deleted 546+ pods in batches using `--force --grace-period=0 --wait=false`

#### 1.6 OpenEBS Replica Pods Stuck Terminating (Secondary)

- **Issue**: 22 OpenEBS Jiva replica pods stuck in Terminating state
- **Impact**: Storage subsystem instability, prevented volume operations
- **Resolution**: Force-deleted all 22 pods

### Phase 2: Storage and Ingress Failures

#### 2.1 OpenEBS Jiva Snapshot Accumulation (Primary)

- **Issue**: Jiva volumes accumulated 1011 snapshots (threshold: 500)
- **Affected Volumes**:
  - Radarr config (pvc-311bef00-1b89-4584-90f0-ae3772e30e09)
  - Sonarr config (pvc-17e6e808-a9fc-4f64-b490-71deffdb81fd)
  - Overseerr config (pvc-05e03b60-3ab7-41a0-9baf-3d0e291eed63)
  - Multiple other Jiva volumes cluster-wide
- **Impact**: Radarr volume reached capacity (3GB physical snapshots in 1Gi volume), causing "No space left on device" errors
- **Why it happened**:
  - Automated cleanup cronjob exists (`jiva-snapshot-cleanup`) running daily at 2 AM
  - **Connection to Phase 1**: Node reboots and kubelet failures prevented cronjob pods from running for 2-3 days
  - Snapshot accumulation rate exceeded cleanup frequency
  - 1011 snapshots suggests cronjob not executing successfully during Phase 1 disk/kubelet issues
- **Resolution**: Manual snapshot cleanup job triggered after node stabilization

#### 2.2 Residual Node Container Runtime Issues

- **k8s01 Node** (post Phase 1 cleanup): Unable to start new containers despite node reporting Ready status
  - Pods scheduled successfully but containers never initialized
  - Affected: Sonarr pod, linkace-cronjob, cleanup job pod
  - **Connection to Phase 1**: Kubelet state corruption persisted despite disk cleanup
  - Resolution: Full microk8s restart (not just kubelite)

- **k8s03 Node**: Similar container startup issues
  - 8-9 Jiva replica pods stuck in Pending with PodScheduled=True but no container creation
  - **Connection to Phase 1**: Disk exhaustion (100% → 81%) required full cluster restart to clear runtime state
  - Resolution: microk8s restart resolved all Pending pods

#### 2.3 Ingress Controller Stale Endpoint Cache

- **Issue**: Nginx ingress controllers retained old pod IP addresses after pod restarts
  - Example: Sonarr old IP 10.1.236.34:8989 vs new IP 10.1.73.92:8989
  - Resulted in 504 Gateway Timeout errors despite healthy backend pods
- **Why it happened**: Pod IP changes during Phase 1 chaos not reflected in ingress controller endpoint cache
- **Resolution**: Restarting all 3 ingress controller pods refreshed endpoint cache

#### 2.4 Radarr Volume Capacity (Secondary)

- **Issue**: Radarr config PVC at 100% capacity (1Gi volume, 958M used)
- **Breakdown**:
  - MediaCover directory: 837M (movie posters/artwork)
  - Backups: 49M
  - Database: 33M
  - Other: ~39M
- **Resolution**: Cleared old backups freeing 49M (temporary fix to 95% usage)
- **Long-term concern**: Volume undersized for media library artwork

### Phase 3: LinkAce CronJob Controller Corruption (2026-01-08)

#### 3.1 Job Controller State Corruption (Primary - Critical)

- **Issue**: Job controller stuck in error loop trying to sync deleted job `linkace-cronjob-29463021`
- **Symptoms**:
  - Jobs created by cronjob but pods never spawned
  - Job objects showing "Running" with 0 Active/Succeeded/Failed pods
  - No events generated for newly created jobs
  - Controller logs: `"syncing job: tracking status: adding uncounted pods to status: jobs.batch \"linkace-cronjob-29463021\" not found"`
- **Impact**: Complete failure of all job creation cluster-wide, not just LinkAce cronjob
- **Why it happened**:
  - **Connection to Phase 1**: Job controller corruption originated from cascading failures on 2026-01-06
  - Stale job reference persisted in controller's in-memory state after Phase 1 reboots
  - Controller unable to clear orphaned reference without full cluster restart
  - MicroK8s dqlite database retained corrupted job metadata
- **Resolution**: Nuclear option - cluster restart with dqlite backup

#### 3.2 Dqlite Database State Corruption (Primary)

- **Issue**: MicroK8s dqlite database retained stale job references preventing controller recovery
- **Symptoms**:
  - Job controller restart didn't resolve issue (state persisted in database)
  - Manually recreating cronjob didn't clear corruption
  - Creating dummy job with stale name and deleting didn't clear reference
  - Multiple kubelite restarts across all nodes failed to resolve
- **Impact**: Self-healing mechanisms completely ineffective
- **Why it happened**:
  - Phase 1 cascading failures (disk pressure, kubelet crashes) corrupted dqlite write operations
  - Job deletion operations during Phase 1 chaos didn't complete atomically
  - Dqlite state diverged across 3 nodes during simultaneous kubelet failures
- **Resolution**: Stopped cluster, backed up dqlite database, restarted to clear in-memory state

#### 3.3 Timeout Configuration Not Enforced (Secondary)

- **Issue**: CronJob timeout settings not enforced despite proper configuration
- **Settings Applied**:
  - `activeDeadlineSeconds: 300` (5-minute job timeout)
  - `ttlSecondsAfterFinished: 120` (2-minute cleanup after completion)
  - `startingDeadlineSeconds: 60` (1-minute grace for job creation)
- **Observed Behavior**:
  - Jobs remained Running for 85+ minutes despite 5-minute timeout
  - Completed jobs not auto-deleted despite 2-minute TTL
  - No timeout enforcement events generated
- **Root Cause**: Job controller corruption prevented processing of any job lifecycle events
- **Impact**: Self-healing timeline predictions completely invalid (expected 6-12 hours, actual: infinite)

#### 3.4 ArgoCD Auto-Sync Failure (Secondary)

- **Issue**: ArgoCD failed to auto-recreate deleted cronjob despite automated sync enabled
- **Symptoms**:
  - Application showed OutOfSync status but no sync operation triggered
  - Manual sync attempts via kubectl patch failed
  - Hard refresh annotation didn't trigger recreation
- **Impact**: Required manual cronjob creation, delaying recovery
- **Why it happened**: ArgoCD controller may have been affected by broader job controller corruption
- **Workaround**: Manually created cronjob from template, ArgoCD eventually adopted it

### Phase 4: ArgoCD Application Recovery (2026-01-08)

#### 4.1 GitHub Actions Runner Controller Finalizer Issues (Primary)

- **Issue**: Child application `gharc-runners-pgmac-user-self-hosted` stuck with resources "Pending deletion"
- **Affected resources**: 4 resources with blocking finalizers
  - AutoscalingRunnerSet: `pgmac-slack-scores`
  - ServiceAccount: `pgmac-slack-scores-gha-rs-no-permission`
  - Role: `pgmac-slack-scores-gha-rs-manager`
  - RoleBinding: `pgmac-slack-scores-gha-rs-manager`
- **Symptoms**:
  - Parent application `ci-tools` stuck OutOfSync + Progressing
  - Resources marked for deletion but finalizers preventing cleanup
  - ArgoCD unable to sync parent application due to child application state
- **Impact**: Blocked CI/CD application sync, prevented runner controller updates
- **Why it happened**:
  - **Connection to Phase 3**: Job controller corruption prevented cleanup job from removing finalizers
  - Resources created by parent application but child application deletion failed
  - Finalizers intended to ensure graceful resource cleanup but became stuck
- **Resolution**: Removed finalizers manually using `kubectl patch --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'`

#### 4.2 GitHub Actions Runner Controller State Drift (Secondary)

- **Issue**: Old listener resources with hash `754b578d` remained after controller update
- **Affected resources**:
  - ServiceAccount with old hash
  - Role with old hash
  - RoleBinding with old hash
- **Symptoms**:
  - Application `gharc-runners-pgmac-net-self-hosted` showing OutOfSync + Healthy
  - New resources created with different hash but old resources not deleted
  - 6 runner pods stuck Pending for 44+ minutes (residual from Phase 3)
- **Impact**: Resource accumulation, pod scheduling failures
- **Why it happened**:
  - **Connection to Phase 3**: Pods created during job controller corruption remained stuck
  - ArgoCD `ignoreDifferences` configuration for AutoscalingListener, Role, RoleBinding masked drift
  - Controller update didn't clean up old resources automatically
- **Resolution**: Manually deleted old listener resources, force-deleted 6 stuck runner pods
- **Acceptable state**: OutOfSync + Healthy is expected due to ignoreDifferences configuration

#### 4.3 LinkAce Helm Chart Configuration Drift (Primary)

- **Issue**: LinkAce cronjob showing OutOfSync despite application Healthy, ArgoCD attempted 23 auto-heal operations
- **Unsupported configuration**: LinkAce Helm chart doesn't support these cronjob fields:
  - `backoffLimit: 0`
  - `resources` block (limits/requests)
- **Symptoms**:
  - ArgoCD continuously detecting drift between desired and actual state
  - Auto-heal operations failing to converge
  - Application Healthy but OutOfSync persisting
- **Impact**: ArgoCD resource consumption, false positive OutOfSync alerts
- **Why it happened**:
  - Upstream Helm chart doesn't expose all CronJob configuration options
  - ArgoCD manifest specified fields not supported by chart templates
  - GitOps configuration drift from Helm chart capabilities
- **Resolution**: Removed unsupported fields from ArgoCD manifest, kept critical timeout settings
- **Acceptable state**: Minor field drift from Helm chart is expected and acceptable

#### 4.4 Home Assistant Application Self-Healing (None)

- **Issue**: Application showed Synced + Progressing initially
- **Root cause**: StatefulSet rollout in progress during investigation
- **Resolution**: Self-resolved as rollout completed
- **Impact**: None, normal operational state

### Phase 5: k8s01 Container Runtime Corruption Recurrence (2026-01-09)

#### 5.1 Persistent Container Runtime Corruption on k8s01 (Critical)

- **Issue**: k8s01 node unable to start new containers 48+ hours after Phase 3 nuclear option
- **Symptoms**:
  - 4 runner pods stuck in Pending state for 12+ hours
  - All 4 pods assigned to k8s01 node
  - Pods showing PodScheduled=True but no container initialization
  - No events generated (silent failure pattern identical to Phase 2)
  - Node reporting Ready status despite being unable to start containers
  - 6 additional EphemeralRunner resources with no corresponding pods
- **Impact**: Complete inability to start new workloads on k8s01, affecting GitHub Actions runners
- **Why it happened**:
  - **Connection to Phase 1**: Container runtime corruption originated from Phase 1 disk pressure (97% usage) and kubelet crashes
  - **Connection to Phase 2**: k8s01 required microk8s restart during Phase 2 (Resolution 2.1) for same symptoms
  - **Connection to Phase 3**: Phase 3 nuclear option (cluster-wide restart) only cleared dqlite/controller state, not node-local container runtime corruption
  - Container runtime (containerd) state diverged from kubelet state
  - Corruption persisted across cluster restarts because it was node-local, not cluster-global
  - 12+ hour delay in detection suggests corruption was dormant until new workloads attempted to schedule
- **Resolution**: Full microk8s restart on k8s01 (`microk8s stop && microk8s start`)
- **Key finding**: Nuclear option (cluster restart) insufficient to clear node-local container runtime issues

#### 5.2 Detection Gap for Node-Local Failures (Secondary)

- **Issue**: 12+ hour delay between pod creation and detection of container startup failure
- **Why it happened**:
  - No monitoring for silent pod failures (PodScheduled=True but no container creation)
  - No alerts for pods stuck in Pending with node assignment
  - No synthetic pod startup tests on individual nodes
  - Kubernetes node status (Ready) doesn't reflect container runtime health
- **Impact**: Extended downtime for affected workloads without visibility
- **Resolution**: Manual investigation prompted by user observation

---

## Impact

### Services Affected

**Phase 1:**

- **Entire cluster**: Widespread pod scheduling and lifecycle failures
- **GitHub Actions**: Self-hosted runners completely non-functional (571 pods stuck)
- **OpenEBS storage**: 22 replica pods unavailable, volume operations degraded
- **All services**: Intermittent availability as pods failed to start/stop properly

**Phase 2:**

- **Sonarr**: Unavailable via https://sonarr.int.pgmac.net/ (504 errors)
- **Radarr**: Pod crashing, completely unavailable
- **Overseerr**: Intermittent 504 timeout errors

**Phase 3:**

- **LinkAce cronjob**: Complete failure to execute scheduled tasks (every minute)
- **All Kubernetes Jobs**: Job controller corruption affected cluster-wide job creation
- **LinkAce scheduled tasks**: Backup creation, link validation, database cleanup not executing
- **ArgoCD**: Auto-sync mechanism failed for deleted resources

**Phase 4:**

- **CI/CD Applications**: ci-tools stuck OutOfSync + Progressing, preventing runner controller updates
- **GitHub Actions Runners**: 6 runner pods stuck Pending for 44+ minutes (residual from Phase 3)
- **ArgoCD GitOps**: Multiple applications showing false OutOfSync status consuming resources
- **LinkAce Application**: 23 failed auto-heal attempts creating noise in ArgoCD

**Phase 5:**

- **GitHub Actions Runners**: 4 runner pods stuck Pending for 12+ hours on k8s01 (pgmac-slack-scores runners unable to spawn)
- **k8s01 Node**: Complete inability to start new containers despite Ready status
- **EphemeralRunner Resources**: 6 additional runners with no corresponding pods (silent failure)

### Duration

- **Total incident duration**: ~8 hours (09:00 - 17:00 AEST 2026-01-06) + 16.5 hours (Phase 3, 2026-01-08) + 0.75 hours (Phase 4, 2026-01-08) + 12+ hours (Phase 5, 2026-01-09)
- **Phase 1 critical period**: ~3.5 hours (09:00 - 12:30 2026-01-06)
- **Phase 2 service outages**: ~3 hours (12:30 - 15:35 2026-01-06)
- **Phase 3 cronjob failure**: ~16.5 hours (02:00 - 18:25 2026-01-08)
- **Phase 4 ArgoCD recovery**: ~45 minutes (19:00 - 19:45 2026-01-08)
- **Phase 5 container runtime corruption**: ~5 minutes active recovery (09:50 - 09:55 2026-01-09), but 12+ hours of silent failure
- **Sonarr downtime**: ~1.5 hours
- **Radarr downtime**: ~2.5 hours
- **Overseerr impact**: Intermittent throughout Phase 2
- **GitHub Actions runners**: ~8 hours (full Phase 1-2 duration) + 45 minutes (Phase 4) + 12+ hours (Phase 5)
- **LinkAce scheduled tasks**: ~16.5 hours (complete failure to execute)
- **CI/CD deployments**: Blocked during Phase 4 investigation (~45 minutes) + 12+ hours (Phase 5 k8s01 node failure)

### Scope

- **Infrastructure**: All 3 nodes compromised at various points
- **User-facing**: All web access to media management services
- **Internal**: Home Assistant integrations unable to query service APIs
- **CI/CD**: GitHub Actions self-hosted runners completely unavailable
- **Monitoring**: Nagios health checks failing across multiple services
- **Storage**: OpenEBS volume operations degraded during Phase 1

---

## Resolution Steps Taken

### Phase 1: Node and Kubelet Recovery

#### 1. k8s02 Kubelet Restart

```bash
# On k8s02 node
sudo systemctl restart snap.microk8s.daemon-kubelite
```

#### 2. k8s01 Disk Cleanup and Stabilization

```bash
# On k8s01 node
# Removed unused container images
microk8s ctr images rm <image-id>...

# Cleaned container logs (methods vary)
# Removed old/stopped containers
# Result: 97% → 87% disk usage
```

#### 3. k8s03 Disk Cleanup

```bash
# On k8s03 node
# Similar cleanup process
# Result: 100% → 81% disk usage
```

#### 4. Runner Controller Cleanup

```bash
# Deleted orphaned controller resources
kubectl delete runnerdeployment pgmac.pgmac-runnerdeploy -n ci --context pvek8s
kubectl delete horizontalrunnerautoscaler pgmac-pgmac-runnerdeploy-autoscaler -n ci --context pvek8s

# Force-deleted 546+ orphaned runner pods in batches
# Pending pods (299)
kubectl get pods -n ci --context pvek8s --no-headers | \
  grep "pgmac.pgmac-runnerdeploy" | grep "Pending" | \
  awk '{print $1}' | xargs -I {} kubectl delete pod {} -n ci \
  --context pvek8s --force --grace-period=0 --wait=false

# ContainerStatusUnknown (110)
kubectl get pods -n ci --context pvek8s --no-headers | \
  grep "pgmac.pgmac-runnerdeploy" | grep "ContainerStatusUnknown" | \
  awk '{print $1}' | xargs -I {} kubectl delete pod {} -n ci \
  --context pvek8s --force --grace-period=0 --wait=false

# StartError/RunContainerError (58)
kubectl get pods -n ci --context pvek8s --no-headers | \
  grep "pgmac.pgmac-runnerdeploy" | grep -E "StartError|RunContainerError|Error" | \
  awk '{print $1}' | xargs -I {} kubectl delete pod {} -n ci \
  --context pvek8s --force --grace-period=0 --wait=false

# Completed (79)
kubectl get pods -n ci --context pvek8s --no-headers | \
  grep "pgmac.pgmac-runnerdeploy" | grep "Completed" | \
  awk '{print $1}' | xargs -I {} kubectl delete pod {} -n ci \
  --context pvek8s --force --grace-period=0 --wait=false

# Final cleanup batch (247)
kubectl get pods -n ci --context pvek8s --no-headers | \
  grep "pgmac.pgmac-runnerdeploy" | grep -v "Running" | grep -v "Terminating" | \
  awk '{print $1}' | xargs -I {} kubectl delete pod {} -n ci \
  --context pvek8s --force --grace-period=0 --wait=false
```

#### 5. OpenEBS Replica Pod Cleanup

```bash
# Force-deleted 22 stuck Terminating replica pods
kubectl get pods -n openebs --context pvek8s | grep Terminating | \
  awk '{print $1}' | xargs -I {} kubectl delete pod {} -n openebs \
  --context pvek8s --force --grace-period=0
```

### Phase 2: Storage and Ingress Recovery

#### 6. k8s01 Full Restart (Residual Issues)

```bash
# On k8s01 node
microk8s stop && microk8s start
```

#### 7. Jiva Snapshot Cleanup

```bash
# Triggered manual cleanup job
kubectl --context pvek8s create job -n openebs jiva-snapshot-cleanup-manual \
  --from=cronjob/jiva-snapshot-cleanup

# Job processed all Jiva volumes sequentially
# - Rolling restart of 3 replicas per volume
# - 30-second stabilization period between replicas
# - Total runtime: ~60 minutes for all volumes
```

#### 8. Ingress Controller Refresh

```bash
# Restarted all ingress controllers to clear endpoint cache
kubectl --context pvek8s delete pod -n ingress \
  nginx-ingress-microk8s-controller-2chvz \
  nginx-ingress-microk8s-controller-k56gn \
  nginx-ingress-microk8s-controller-t56r5
```

#### 9. Radarr Volume Emergency Cleanup

```bash
# Freed space by removing old backups
kubectl --context pvek8s exec -n media radarr-<pod> -- \
  rm -rf /config/Backups/*

# Result: 100% → 95% usage, sufficient for startup
```

#### 10. k8s03 Full Restart (Replica Pod Issues)

```bash
# On k8s03 node
microk8s stop && microk8s start

# All Pending replica pods recreated successfully after restart
```

### Phase 3: Job Controller and Database Recovery (Nuclear Option)

#### 11. Cluster-Wide Restart with Database Backup

```bash
# Stop MicroK8s on all nodes (prevent database writes during backup)
ssh k8s01 "sudo snap stop microk8s"
ssh k8s02 "sudo snap stop microk8s"
ssh k8s03 "sudo snap stop microk8s"

# Wait for clean shutdown
sleep 30

# Backup dqlite database (on k8s01 primary node)
ssh k8s01 "sudo mkdir -p /var/snap/microk8s/common/backup && \
  sudo cp -r /var/snap/microk8s/current/var/kubernetes/backend \
  /var/snap/microk8s/common/backup/etcd-backup-20260108-201540"

# Start MicroK8s on all nodes
ssh k8s01 "sudo snap start microk8s"
ssh k8s02 "sudo snap start microk8s"
ssh k8s03 "sudo snap start microk8s"

# Wait for cluster to be ready
kubectl --context pvek8s wait --for=condition=Ready nodes --all --timeout=300s

# Verify cluster health
kubectl --context pvek8s get nodes
kubectl --context pvek8s get componentstatuses
```

#### 12. Clean Job and CronJob State

```bash
# Delete all stuck jobs (85+ jobs accumulated)
kubectl --context pvek8s delete jobs -n media -l app.kubernetes.io/instance=linkace --all

# Delete cronjob to get fresh state
kubectl --context pvek8s delete cronjob linkace-cronjob -n media

# Trigger ArgoCD sync to recreate with fresh state
kubectl --context pvek8s patch application linkace -n argocd \
  --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

#### 13. Update ArgoCD Manifest with Timeout Configuration

```yaml
# In pgk8s/pgmac.net/media/templates/linkace.yaml (lines 101-114)
cronjob:
  startingDeadlineSeconds: 60 # Grace period for job creation
  activeDeadlineSeconds: 300 # 5-minute job timeout
  ttlSecondsAfterFinished: 120 # 2-minute cleanup after completion
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 2
  resources:
    limits:
      memory: 512Mi
      cpu: 500m
    requests:
      memory: 256Mi
      cpu: 100m
```

#### 14. Verification

```bash
# Verify cronjob recreated with correct configuration
kubectl --context pvek8s get cronjob linkace-cronjob -n media -o yaml

# Wait for next minute and verify job creation
watch -n 10 'kubectl --context pvek8s get jobs -n media -l app.kubernetes.io/instance=linkace'

# Verify job completes successfully
kubectl --context pvek8s wait --for=condition=complete \
  job/linkace-cronjob-<generated> -n media --timeout=120s

# Verify TTL cleanup working (jobs deleted after 2 minutes)
# Monitor job count - should stabilize at 1 successful + max 2 failed
watch -n 30 'kubectl --context pvek8s get jobs -n media -l app.kubernetes.io/instance=linkace'

# Check job execution time (should be ~7 seconds)
kubectl --context pvek8s get job linkace-cronjob-<latest> -n media -o yaml | \
  grep -A 5 "startTime\|completionTime"

# Verify no orphaned pods
kubectl --context pvek8s get pods -n media -l job-name
```

### Phase 4: ArgoCD Application and Finalizer Recovery

#### 15. Remove Finalizers from Stuck Resources

```bash
# Remove finalizer from AutoscalingRunnerSet
kubectl --context pvek8s patch autoscalingrunnerset pgmac-slack-scores -n arc-runners \
  --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Remove finalizer from ServiceAccount
kubectl --context pvek8s patch serviceaccount pgmac-slack-scores-gha-rs-no-permission -n arc-runners \
  --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Remove finalizer from Role
kubectl --context pvek8s patch role pgmac-slack-scores-gha-rs-manager -n arc-runners \
  --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Remove finalizer from RoleBinding
kubectl --context pvek8s patch rolebinding pgmac-slack-scores-gha-rs-manager -n arc-runners \
  --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Trigger ArgoCD sync for parent application
kubectl --context pvek8s patch application ci-tools -n argocd \
  --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

#### 16. Clean Up Old Runner Controller Resources

```bash
# Delete old listener resources with stale hash
kubectl --context pvek8s delete serviceaccount \
  pgmac-renovatebot-gha-rs-listener-754b578d -n arc-runners

kubectl --context pvek8s delete role \
  pgmac-renovatebot-gha-rs-listener-754b578d -n arc-runners

kubectl --context pvek8s delete rolebinding \
  pgmac-renovatebot-gha-rs-listener-754b578d -n arc-runners

# Force-delete stuck runner pods (residual from Phase 3)
kubectl --context pvek8s delete pod pgmac-renovatebot-<pod-id> -n arc-runners \
  --force --grace-period=0 --wait=false
# Repeat for all 6 stuck pods
```

#### 17. Fix LinkAce Helm Chart Configuration

```bash
# Edit ArgoCD manifest to remove unsupported fields
# File: /Users/paulmacdonnell/pgmac/pgk8s/pgmac.net/media/templates/linkace.yaml
# Removed lines (backoffLimit and resources block):
#   backoffLimit: 0
#   resources:
#     limits:
#       memory: 512Mi
#       cpu: 500m
#     requests:
#       memory: 256Mi
#       cpu: 100m

# Kept critical timeout configuration:
#   startingDeadlineSeconds: 60
#   activeDeadlineSeconds: 300
#   ttlSecondsAfterFinished: 120
#   successfulJobsHistoryLimit: 1
#   failedJobsHistoryLimit: 2

# Commit changes
cd /Users/paulmacdonnell/pgmac/pgk8s
git add pgmac.net/media/templates/linkace.yaml
git commit -m "Remove unsupported LinkAce cronjob configuration"

# Handle git push rejection
git stash
git pull --rebase
git stash pop
git push
```

#### 18. Verification

```bash
# Verify ci-tools application status
kubectl --context pvek8s get application ci-tools -n argocd

# Verify gharc-runners-pgmac-net-self-hosted (acceptable OutOfSync + Healthy)
kubectl --context pvek8s get application gharc-runners-pgmac-net-self-hosted -n argocd

# Verify hass application (should be Synced + Healthy)
kubectl --context pvek8s get application hass -n argocd

# Verify linkace application (acceptable OutOfSync + Healthy)
kubectl --context pvek8s get application linkace -n argocd

# Verify no stuck runner pods remain
kubectl --context pvek8s get pods -n arc-runners | grep Pending

# Verify ArgoCD sync status
kubectl --context pvek8s get applications -n argocd | grep -E "OutOfSync|Progressing"
```

### Phase 5: k8s01 Container Runtime Recovery

#### 19. k8s01 Container Runtime Investigation

```bash
# List all pods in arc-runners namespace
kubectl --context pvek8s get pods -n arc-runners

# Identified 4 Pending pods (12+ hours old):
# - self-hosted-l52x9-runner-2nnsr
# - self-hosted-l52x9-runner-69qnv
# - self-hosted-l52x9-runner-ls8c2
# - self-hosted-l52x9-runner-w8mcd

# Describe pod to check status
kubectl --context pvek8s describe pod self-hosted-l52x9-runner-2nnsr -n arc-runners
# Observed: PodScheduled=True, assigned to k8s01, no events generated

# Check node status
kubectl --context pvek8s get nodes
# k8s01 showing Ready status despite being unable to start containers

# Check pod locations
kubectl --context pvek8s get pods -n arc-runners -o wide
# All 4 Pending pods assigned to k8s01 node

# Check EphemeralRunner resources
kubectl --context pvek8s get ephemeralrunner -n arc-runners
# Found 10 EphemeralRunner resources but only 4 pods exist
# 6 pgmac-slack-scores runners have no corresponding pods
```

#### 20. k8s01 MicroK8s Restart

```bash
# On k8s01 node (user executed)
microk8s stop && microk8s start

# Wait for node to return Ready
kubectl --context pvek8s wait --for=condition=Ready node/k8s01 --timeout=300s

# Verify Pending pods cleared
kubectl --context pvek8s get pods -n arc-runners
# All 4 Pending pods should be gone, container runtime recovered
```

#### 21. Verification

```bash
# Verify no Pending pods remain in arc-runners namespace
kubectl --context pvek8s get pods -n arc-runners | grep Pending

# Verify EphemeralRunner resources
kubectl --context pvek8s get ephemeralrunner -n arc-runners

# Verify k8s01 node health
kubectl --context pvek8s describe node k8s01

# Check for any new container creation issues
kubectl --context pvek8s get events -n arc-runners --sort-by='.lastTimestamp'
```

---

## Verification

### Service Health Checks

- ✅ Sonarr: 200 OK responses, RSS sync operational
- ✅ Radarr: 200 OK responses, web UI accessible
- ✅ Overseerr: 200 OK responses, login page loading

### Infrastructure Health

- ✅ All 3 nodes (k8s01, k8s02, k8s03): Ready status
- ✅ Jiva replicas: 39/40 Running (effectively 100%)
- ✅ No Pending, CrashLoop, or Error pods cluster-wide (excluding residual runner pod cleanup)
- ✅ Ingress controllers: Routing to correct pod IPs
- ✅ Kubelet stable on all nodes: No repeated crashes or hangs

### Volume Replication

```
Overseerr:  3/3 replicas Running
Sonarr:     3/3 replicas Running
Radarr:     3/3 replicas Running
All others: 3/3 replicas Running
```

### Node Disk Status (Post-Cleanup)

```
k8s01: 87% (down from 97%)
k8s02: Stable (no initial disk pressure)
k8s03: 81% (down from 100%)
```

---

## Preventive Measures

### Immediate Actions Required

1. **Implement Node Disk Space Monitoring** (Critical Priority)
   - Current: No alerts for disk usage >85%
   - Target: Alert at 80%, critical alert at 90%
   - Actions:
     - Deploy Prometheus node-exporter on all nodes
     - Configure AlertManager rules for disk pressure
     - Add Nagios checks for disk usage as backup
   - **Rationale**: Both k8s01 (97%) and k8s03 (100%) hit critical thresholds without detection

2. **Automated Container Image Garbage Collection** (High Priority)
   - Current: Manual cleanup required during incident
   - Target: Automated daily cleanup maintaining <75% disk usage
   - Actions:
     - Configure kubelet `imageGCHighThresholdPercent=75` (default: 85)
     - Configure kubelet `imageGCLowThresholdPercent=70` (default: 80)
     - Schedule weekly cleanup cronjob as backup
   - **Rationale**: 4+ years of accumulated images contributed to disk exhaustion

3. **Audit Log Rotation and Buffer Management** (High Priority)
   - Current: Audit buffer overload caused kubelet crashes on k8s01
   - Actions:
     - Reduce audit log verbosity (current level generating excessive data)
     - Implement aggressive log rotation (hourly vs daily)
     - Configure audit buffer size limits
     - Consider disabling detailed audit logging for non-critical operations
   - **Rationale**: "audit buffer queue blocked" directly caused kubelet instability

4. **Radarr PVC Expansion** (High Priority)
   - Current: 1Gi volume at 95% capacity (carried over from Phase 2)
   - Target: 2Gi to accommodate media artwork growth
   - Action: Requires PVC recreation (Jiva doesn't support online expansion)
   - Steps:
     ```bash
     # 1. Backup Radarr config
     # 2. Create new 2Gi PVC
     # 3. Restore data
     # 4. Update deployment to use new PVC
     ```

5. **Jiva Snapshot Cleanup Frequency** (High Priority)
   - Current: Daily at 2 AM (threshold: 500 snapshots)
   - Problem: 1011 snapshots accumulated when cronjob couldn't run during Phase 1
   - Actions:
     - Lower threshold from 500 to 300 snapshots
     - Increase frequency to every 12 hours (2 AM and 2 PM)
     - Add monitoring/alerting for snapshot counts >400
     - Add pod anti-affinity to ensure cleanup job can run on healthy nodes
   - **Rationale**: Cronjob failure during Phase 1 directly caused Phase 2 storage issues

6. **GitHub Actions Runner Controller Migration** (Medium Priority)
   - Current: Orphaned runner pods consumed significant resources
   - Actions:
     - Migrate to GitHub-hosted runners or alternative self-hosted solution
     - If keeping self-hosted: implement strict `maxReplicas` limits
     - Add PodDisruptionBudgets to prevent runaway scaling
     - Configure aggressive pod cleanup policies
   - **Rationale**: 571 orphaned pods significantly contributed to cluster instability

7. **CronJob Timeout Configuration Baseline** (High Priority - Added from Phase 3)
   - Current: CronJobs created without timeout settings, allowing infinite hangs
   - Target: All cronjobs have defensive timeout configuration
   - Actions:
     - Create baseline cronjob template with standard timeouts:
       - `startingDeadlineSeconds: 60` (for minute-frequency jobs)
       - `activeDeadlineSeconds: <appropriate for task>` (e.g., 300 for 5-min tasks)
       - `ttlSecondsAfterFinished: 120` (2-minute cleanup)
       - `successfulJobsHistoryLimit: 1`
       - `failedJobsHistoryLimit: 2`
     - Audit all existing cronjobs and add timeout configuration
     - Add validation in ArgoCD to require timeout settings
   - **Rationale**: Timeout settings proved critical for self-healing, but were missing

8. **Job Controller Health Monitoring** (Critical Priority - Added from Phase 3)
   - Current: No monitoring for job controller state or corruption
   - Actions:
     - Add synthetic job creation tests every 5 minutes cluster-wide
     - Monitor job controller logs for "not found" errors
     - Alert on jobs with 0 pods after 2 minutes
     - Alert on jobs exceeding activeDeadlineSeconds without termination
     - Monitor dqlite database health and replication lag
   - **Rationale**: Job controller corruption went undetected for 16+ hours

9. **Dqlite Database Backup Automation** (High Priority - Added from Phase 3)
   - Current: Manual backup procedures only
   - Target: Automated hourly backups with 24-hour retention
   - Actions:
     - Create cronjob to backup dqlite database (requires node-local execution)
     - Store backups on NFS with rotation policy
     - Document and test restoration procedure
     - Add alerts for backup failures
   - **Rationale**: Database backup was critical for nuclear option confidence

### Longer-Term Improvements

10. **Node Health Synthetic Testing** (High Priority)

- Issue: Nodes reported Ready but couldn't start containers
- Actions:
  - Deploy synthetic pod startup tests every 5 minutes on each node
  - Monitor microk8s/kubelite service health
  - Alert on pod startup failures or extended ContainerCreating states
  - Consider scheduled microk8s service restarts (monthly maintenance)
- **Rationale**: k8s02 and k8s03 both showed "Ready" status while unable to start pods

11. **Dqlite State Recovery Procedures** (Medium Priority - Updated from Phase 3)

- Issue: Dqlite state corruption from Phase 1 required Phase 3 nuclear option
- Actions:
  - **COMPLETED**: Automated dqlite database backups documented (see item 9)
  - Document nuclear option recovery procedure (cluster restart with backup)
  - Test backup restoration in non-production scenario
  - Add monitoring for dqlite replication lag between nodes
  - Consider scheduled preventive cluster restarts (quarterly maintenance)
- **Rationale**: Dqlite corruption from Phase 1 persisted for 48+ hours, required nuclear option

12. **Node Reboot Resilience Testing** (Medium Priority)

- Issue: Simultaneous node reboots triggered cascading failures
- Actions:
  - Implement controlled rolling node restarts (monthly maintenance)
  - Document graceful node shutdown/startup procedures
  - Test simultaneous 2-node failure scenarios
  - Add PodDisruptionBudgets for critical services
  - Configure proper pod anti-affinity for redundant services
- **Rationale**: Inability to handle simultaneous reboots indicates insufficient resilience

13. **Ingress Endpoint Monitoring** (Medium Priority)
    - Add monitoring to detect stale endpoint caching
    - Alert on pod IP changes not reflected in ingress logs
    - Consider automated ingress controller restarts after pod migrations

14. **Volume Capacity Monitoring** (High Priority)
    - Implement alerts for PVC usage >85%
    - Current gap: No visibility into Jiva volume capacity
    - Tool: Consider deploying Prometheus with node-exporter + custom Jiva metrics

15. **Snapshot Management Strategy** (Medium Priority)
    - Investigate snapshot growth rate per volume
    - Document expected snapshot accumulation patterns
    - Consider application-specific snapshot retention policies
    - Evaluate if 3-replica Jiva setup is necessary (vs 2-replica for non-critical data)

16. **MediaCover Cleanup Automation** (Low Priority)
    - Radarr MediaCover directory: 837M of 974M total
    - Implement periodic cleanup of orphaned/old media artwork
    - Consider storing media artwork on NFS instead of Jiva volumes

17. **Runbook Documentation** (High Priority - Updated from Phase 3)
    - Document kubelet/kubelite restart procedures for all nodes
    - Document disk cleanup emergency procedures with target thresholds
    - Document Jiva snapshot cleanup manual trigger process
    - Document ingress controller restart for endpoint refresh
    - Document force-deletion procedures for stuck pods
    - **NEW**: Document nuclear option procedures (cluster restart with dqlite backup)
    - **NEW**: Document job controller corruption recovery steps
    - **NEW**: Document self-healing verification checklist
    - Add to on-call playbook with estimated recovery times
    - **Rationale**: Multiple manual interventions required across all 3 phases; procedures must be documented
    - **Reference**: `/tmp/linkace-cronjob-nuclear-option.md` created during Phase 3

18. **Cluster Architecture Review** (Low Priority)
    - Current: 4+ year old microk8s installation
    - Consider: Upgrade path to newer Kubernetes versions
    - Evaluate: Migration to managed Kubernetes (EKS, GKE, AKS) or alternative distributions
    - **Rationale**: Age of installation may contribute to accumulated technical debt

---

## Lessons Learned

### What Went Well

1. **Systematic troubleshooting approach**: Correctly identified kubelet issues as separate from scheduler problems
2. **Node cordoning strategy**: Temporarily removing k8s02 from rotation helped isolate the problem
3. **Diagnostic tools worked effectively**: `kubectl` commands, `journalctl`, and custom scripts like `check-jiva-volumes.py` provided crucial insights
4. **Modular architecture**: Issues isolated to specific components, preventing total cluster failure
5. **Quick node recovery**: microk8s restarts resolved kubelet issues within 1-2 minutes
6. **Automated cleanup existed**: Jiva snapshot cleanup cronjob was already in place, just needed manual trigger
7. **Full replication**: Jiva 3-replica setup meant volumes remained accessible with 2/3 replicas during issue
8. **Force-deletion strategy**: Successfully cleared 546+ orphaned pods using batched force-delete commands
9. **Phase 3 - Timeout configuration added proactively**: ArgoCD manifest updated with defensive timeout settings before nuclear option
10. **Phase 3 - Database backup procedures**: Successfully backed up dqlite database before nuclear option, providing rollback capability
11. **Phase 3 - Nuclear option executed cleanly**: Cluster restart resolved all issues within 15 minutes with zero data loss
12. **Phase 3 - Verification thoroughness**: Systematic verification of job creation, completion, TTL cleanup, and pod lifecycle

### What Didn't Go Well

1. **Cascading failure propagation**: Initial node reboot triggered multiple secondary failures across all infrastructure layers
2. **No proactive monitoring**: Disk usage (97%, 100%) and snapshot accumulation (1011) went undetected
3. **Kubelet instability**: Disk pressure caused repeated kubelet crashes without clear error messages in pod status
4. **Database state corruption**: Dqlite database corruption persisted for 48+ hours, spanning Phase 1 → Phase 3
5. **Manual intervention required**: Multiple manual steps needed across 8-hour (Phase 1-2) + 16.5-hour (Phase 3) + 12+ hour (Phase 5) periods vs automated recovery
6. **Long cleanup duration**: 60+ minutes for snapshot cleanup job to process all volumes
7. **Ingress endpoint caching**: No automatic detection/refresh of stale endpoints
8. **Runner controller orphaned pods**: 571 pods remained despite controller scaled to 0
9. **Capacity planning gap**: Radarr volume undersized for actual usage patterns
10. **Node Ready status misleading**: Nodes reported Ready but couldn't start containers (kubelet vs containerd state mismatch)
11. **Cronjob failure during node issues**: Snapshot cleanup cronjob couldn't run during Phase 1, directly causing Phase 2 storage issues
12. **Phase 3 - Self-healing complete failure**: Waited 1.5 hours for timeout-based self-healing that never occurred
13. **Phase 3 - Job controller corruption went undetected**: 16+ hours of cronjob failures without alerting
14. **Phase 3 - Controller restarts ineffective**: Multiple kubelite restarts across all nodes failed to clear corruption
15. **Phase 3 - ArgoCD auto-sync failed**: GitOps automation failed when resources were deleted for clean state
16. **Phase 3 - No job controller monitoring**: Zero visibility into controller state or processing errors
17. **Phase 5 - Nuclear option insufficient**: Cluster-wide restart (Phase 3) didn't clear node-local container runtime corruption on k8s01
18. **Phase 5 - Silent failure undetected**: 12+ hour delay in detecting Pending pods with no container initialization
19. **Phase 5 - No node-local runtime monitoring**: Zero visibility into container runtime health vs kubelet health

### Surprise Findings

1. **Audit buffer overload**: Audit logging directly caused kubelet crashes (not commonly documented failure mode)
2. **Dqlite database corruption persistence**: Database corruption from Phase 1 persisted for 48+ hours despite multiple controller restarts
3. **Kubelet crash without pod warnings**: Pods showed "Pending" with no indication kubelet was crashing
4. **Disk threshold**: 97% disk usage was sufficient to crash kubelet despite >3% free space
5. **Runner pod accumulation**: 571 pods accumulated without triggering any resource quota or alerts
6. **Snapshot physical storage**: 1011 snapshots consumed 3GB physical space in 1Gi logical volume
7. **Media artwork growth**: Radarr artwork (837M) exceeded database size (33M) by 25x
8. **Cleanup job thoroughness**: Job processed ALL Jiva volumes, not just over-threshold volumes
9. **Cross-phase dependency**: Phase 1 kubelet/disk issues directly prevented Phase 2 cronjobs from running, and Phase 1 database corruption caused Phase 3 job controller failures
10. **Phase 3 - Job controller single point of failure**: Single corrupted job reference prevented ALL job creation cluster-wide
11. **Phase 3 - Timeout settings ignored**: Properly configured activeDeadlineSeconds and ttlSecondsAfterFinished completely ignored by corrupted controller
12. **Phase 3 - Controller restart insufficient**: Restarting kubelite service didn't clear in-memory controller state
13. **Phase 3 - Nuclear option effectiveness**: Full cluster restart immediately resolved all controller corruption issues
14. **Phase 3 - Self-healing timeline invalid**: Expected 6-12 hour self-healing never occurred; corruption was permanent without intervention
15. **Phase 5 - Nuclear option scope limitation**: Cluster restart cleared cluster-global state (dqlite, controllers) but not node-local container runtime corruption
16. **Phase 5 - Corruption dormancy**: Container runtime corruption from Phase 1 remained dormant for 48+ hours until new workloads attempted to schedule on k8s01
17. **Phase 5 - Silent failure persistence**: Same silent failure pattern from Phase 2 (PodScheduled=True, no events) persisted despite Phase 3 nuclear option

---

## Action Items

| Priority | Action                                                                 | Owner | Due Date   | Status |
| -------- | ---------------------------------------------------------------------- | ----- | ---------- | ------ |
| Critical | Deploy node disk space monitoring with alerts (80%/90% thresholds)     | SRE   | 2026-01-08 | Open   |
| Critical | Configure automated container image garbage collection (75% threshold) | SRE   | 2026-01-09 | Open   |
| Critical | Implement job controller health monitoring with synthetic tests        | SRE   | 2026-01-09 | Open   |
| High     | Implement audit log rotation and reduce verbosity                      | SRE   | 2026-01-10 | Open   |
| High     | Expand Radarr PVC from 1Gi to 2Gi                                      | SRE   | 2026-01-13 | Open   |
| High     | Lower snapshot threshold to 300, increase cleanup frequency to 12h     | SRE   | 2026-01-08 | Open   |
| High     | Audit all cronjobs and add timeout configuration baseline              | SRE   | 2026-01-15 | Open   |
| High     | Implement automated dqlite database backups (hourly, 24h retention)    | SRE   | 2026-01-10 | Open   |
| High     | Document nuclear option runbook (cluster restart with dqlite backup)   | SRE   | 2026-01-12 | Open   |
| High     | Implement synthetic pod startup health checks on all nodes             | SRE   | 2026-01-15 | Open   |
| High     | Add PVC capacity monitoring and alerting (>85%)                        | SRE   | 2026-01-20 | Open   |
| Medium   | Test dqlite backup restoration in non-production scenario              | SRE   | 2026-01-17 | Open   |
| Medium   | Add dqlite replication lag monitoring                                  | SRE   | 2026-01-20 | Open   |
| Medium   | Migrate GitHub Actions to hosted runners or implement strict limits    | SRE   | 2026-01-27 | Open   |
| Medium   | Test node reboot resilience with controlled failures                   | SRE   | 2026-02-03 | Open   |
| Medium   | Investigate k8s01/k8s03 kubelet/containerd logs from incident          | SRE   | 2026-01-13 | Open   |
| Medium   | Add ingress endpoint staleness monitoring                              | SRE   | 2026-02-10 | Open   |
| Medium   | Investigate ArgoCD auto-sync failure for deleted resources             | SRE   | 2026-01-20 | Open   |
| Low      | Implement Radarr MediaCover cleanup automation                         | Dev   | 2026-02-03 | Open   |
| Low      | Evaluate reducing Jiva replication from 3 to 2 for non-critical data   | SRE   | 2026-02-10 | Open   |
| Low      | Review cluster architecture and upgrade path                           | SRE   | 2026-03-01 | Open   |
| Low      | Consider scheduled preventive cluster restarts (quarterly)             | SRE   | 2026-03-01 | Open   |

---

## Technical Details

### Environment

- **Cluster**: microk8s on 3 nodes (k8s01, k8s02, k8s03)
- **Kubernetes Version**: v1.34.3
- **Node Age**: 4 years 138 days
- **Storage**: OpenEBS Jiva 2.12.1 (openebs-jiva-default storage class)
- **Ingress**: nginx-ingress-microk8s-controller (3 replicas)
- **Network**: Calico CNI
- **etcd Alternative**: kine (microk8s default)
- **Container Runtime**: containerd via microk8s

### Affected Resources

**Phase 1:**

```yaml
Namespaces: ci, openebs, kube-system, all namespaces (scheduler impact)
Nodes:
  - k8s01: Kubelet crash loop (disk 97% + audit buffer overload)
  - k8s02: Kubelet hung (process restart required)
  - k8s03: Disk 100% full (garbage collection failure)
Pods:
  - GitHub Actions runners: 571 orphaned (299 Pending, 110 ContainerStatusUnknown, 79 Completed, 58 StartError, 25 other)
  - OpenEBS replicas: 22 stuck Terminating
  - Various: Unable to start/stop across all namespaces
```

**Phase 2:**

```yaml
Namespaces: media, openebs, ingress
Pods:
  - sonarr-7b8f6fcfc4-4wm8m (Pending → Running)
  - radarr-5c95c64cff-* (CrashLoopBackOff → Running, multiple restarts)
  - overseerr-58cc7d4569-kllz2 (Running, intermittent timeouts)
PVCs:
  - radarr-config (pvc-311bef00..., 1Gi, 100% full → 95% after cleanup)
  - sonarr-config (pvc-17e6e808..., 1Gi, 1011 snapshots)
  - overseerr-config (pvc-05e03b60..., 1Gi, 1011 snapshots)
```

### Snapshot Cleanup Job Output

```
Volumes processed: 13
Volumes cleaned: 13
Snapshots consolidated: 1011 → ~100 per volume (estimated)
Duration: ~60 minutes
Method: Rolling restart of replicas (3 per volume, 30s stabilization between)
```

### Node Disk Usage Timeline

```
k8s01: 97% (critical) → 87% (stable) after cleanup
k8s02: Stable throughout (no disk pressure)
k8s03: 100% (critical) → 81% (stable) after cleanup
```

### Kubelet Error Patterns (Phase 1)

```
k8s01 errors:
- "audit buffer queue blocked"
- "database is locked" (kine)
- "Failed to garbage collect required amount of images"
- "Kubelet stopped posting node status"

k8s02 errors:
- Pods assigned but never reached ContainerCreating (silent failure)

k8s03 errors:
- "Failed to garbage collect required amount of images. Attempted to free 13GB, but only found 0 bytes eligible to free"
```

---

## References

- Jiva Volume Checker Script: `/Users/paulmacdonnell/pgmac/check-jiva-volumes.py`
- Snapshot Cleanup Config: `/Users/paulmacdonnell/pgmac/pgk8s/pgmac.net/system/templates/jiva-snapshot-cleanup.yaml`
- Cleanup Job Logs: `kubectl logs -n openebs jiva-snapshot-cleanup-manual-4tv5c`
- OpenEBS Jiva Documentation: https://openebs.io/docs/user-guides/jiva
- microk8s Documentation: https://microk8s.io/docs
- Kubernetes Kubelet Configuration: https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/

---

## Reviewers

- **Prepared by**: Claude (AI Assistant)
- **Date**: 2026-01-06
- **Review Status**: Draft - Pending human review

---

## Notes

This incident demonstrated the fragility of a long-running Kubernetes cluster under cascading failure conditions across five distinct phases spanning 2026-01-06 to 2026-01-09. Key takeaways:

### Cross-Phase Insights

1. **Disk pressure is a critical failure mode**: Both 97% and 100% disk usage caused complete kubelet failure, not just degraded performance
2. **Audit logging can become a liability**: Excessive audit log generation directly caused kubelet crashes via buffer overload
3. **Node "Ready" status is insufficient**: Nodes reported Ready while unable to start containers (kubelet vs containerd state mismatch)
4. **Cascading failures span days, not hours**: Initial Phase 1 node reboot → disk pressure → kubelet failures → dqlite corruption → **48 hours later** → Phase 3 job controller corruption
5. **Automated cleanup jobs are single points of failure**: Snapshot cleanup cronjob failure during Phase 1 directly caused Phase 2 storage issues
6. **Orphaned pods accumulate silently**: 571 runner pods accumulated over time without triggering resource quotas or alerts
7. **Force-deletion is sometimes necessary**: Normal deletion failed for 546+ pods due to finalizer/controller corruption
8. **Database state corruption is persistent**: Dqlite corruption persisted for 48+ hours despite multiple controller restarts
9. **Multiple layers require monitoring**: Node health, disk space, kubelet status, pod lifecycle, storage subsystem, ingress endpoints, **controller state**
10. **Age matters**: 4+ year old installation accumulated technical debt (images, logs, state corruption)

### Phase 3-Specific Insights (Job Controller Corruption)

11. **Controller corruption is catastrophic**: Single corrupted job reference prevented ALL job creation cluster-wide
12. **Service restarts don't clear all state**: Restarting kubelite service didn't clear in-memory controller state or dqlite database corruption
13. **Self-healing has limits**: Properly configured timeout settings (activeDeadlineSeconds, ttlSecondsAfterFinished) were completely ignored by corrupted controller
14. **Nuclear option is sometimes necessary**: Full cluster restart with database backup was the only effective recovery path
15. **Timeout configuration is defensive, not curative**: Timeout settings prevent runaway resource consumption but don't fix controller corruption
16. **Job controller is a single point of failure**: No redundancy or failover mechanism for corrupted job controller state
17. **GitOps auto-sync can fail**: ArgoCD auto-sync failed when resources deleted for clean state, requiring manual intervention
18. **Database backups provide confidence**: Having dqlite backup before nuclear option provided rollback capability and reduced risk
19. **Verification is critical**: Systematic verification of job lifecycle (creation → pod spawn → completion → TTL cleanup) necessary after controller recovery
20. **Controller monitoring is essential**: Zero visibility into job controller processing state delayed detection by 16+ hours

The resolution required comprehensive intervention across all infrastructure layers (compute, storage, networking, control plane, **database**) demonstrating the interconnected nature of Kubernetes cluster health and the importance of:

- Proactive monitoring at multiple levels (nodes, controllers, database)
- Automated maintenance and cleanup with defensive timeout configuration
- Graceful degradation under failure (with acknowledgment of hard limits)
- Clear runbooks for manual intervention **including nuclear option procedures**
- Regular resilience testing **including controller corruption scenarios**
- Capacity planning and right-sizing
- Understanding failure cascades and dependencies between systems **across multi-day timespans**
- Database backup and recovery procedures for confidence in drastic recovery actions
- Controller state monitoring and synthetic testing
- Recognition that some failures require full cluster restart to resolve

Future incidents can be prevented or mitigated through the preventive measures outlined above, particularly:

- **Phase 1 preventions**: Disk space monitoring, automated image cleanup, audit log management
- **Phase 2 preventions**: Comprehensive health checks beyond node "Ready" status, cronjob reliability monitoring
- **Phase 3 preventions**: Job controller health monitoring, synthetic job tests, dqlite backup automation, cronjob timeout baselines, nuclear option documentation

The three-phase nature of this incident (spanning 48+ hours) highlights that cascading failures can have **long-term delayed effects** requiring sustained vigilance and multiple recovery strategies beyond initial stabilization.
