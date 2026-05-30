---
tags:
  - k8s01
  - k8s02
  - k8s03
  - kine
  - dqlite
  - kubelet
  - openebs
  - jiva
  - watch-stream
  - storage
  - scheduling
  - iscsi
  - ro-filesystem
---

# Post Incident Review: pvek8s Post-Power-Outage Recovery — kubelet Volume Manager Stall and KCM Stale terminatingReplicas

**Date:** 2026-05-28
**Duration:** ~5h 20m active (~20:55 AEST 2026-05-28 → ~02:15 AEST 2026-05-29) — reconstructed from session notes
**Severity:** High (4 media services fully unavailable; extended recovery requiring kine+kubelite restart on control-plane node)
**Status:** Resolved

---

## Executive Summary

Following a power outage on 2026-05-28, the pvek8s cluster partially recovered but four media applications (radarr, sonarr, readarr, calibreweb) remained stuck in ContainerCreating on k8s03. The power outage disrupted kine/dqlite watch streams on both k8s03 and k8s01. While node heartbeats and the API server continued functioning normally, two independent informer stalls left the cluster in a split-brain state that prevented recovery without manual intervention.

On k8s03, the kubelet's client-go `processorListeners` goroutines became permanently blocked in `select` (confirmed via pprof: 33+ minutes), meaning the kubelet volume manager never received the ADC's volumesAttached update. Four iSCSI-backed pods were stuck in WaitForAttachAndMount indefinitely; the node's `volumesInUse` status listed the volumes, blocking the Attachable-Detachable Controller (ADC) from attaching them to a healthy node. The resolution was to patch k8s03's `volumesAttached` and `volumesInUse` to empty, cordon k8s03, and force-delete the stuck pods — which triggered rescheduling to k8s01/k8s02 where iSCSI attached successfully.

On k8s01, the kube-controller-manager's pod informer was also stale from the same kine disruption. After the stuck pods were force-deleted from k8s03, the KCM never received the DELETE events. The ReplicaSets for the media apps showed `terminatingReplicas: 1` in their status (a K8s 1.35 feature) and refused to create replacement pods, believing one was still terminating. Scale-to-0/back-to-1 did not help because the informer cache itself was stale. A kine+kubelite restart on k8s01 forced the KCM to re-list all pods from the API server, clearing the stale terminatingReplicas state and triggering new pod creation.

As a separate issue discovered during this session, `dependency-track-api-server-0` had been in CrashLoopBackOff for 6 days (501 restarts) due to a misconfigured JDBC URL using the short-form `dtrack-postgresql.ci` hostname, which Java's JVM DNS resolver fails to resolve despite the pod's resolv.conf ndots:5 search domains. Changing the URL to the full FQDN `dtrack-postgresql.ci.svc.cluster.local` resolved the CrashLoop immediately.

---

## Timeline (AEST — UTC+10)

| Time | Event |
|------|-------|
| **~2026-05-28** | Power outage disrupts pvek8s nodes; k8s-dqlite crashes and restarts, breaking existing kine watch streams on k8s01 and k8s03 |
| **~20:10 AEST** | k8s02 k8s-dqlite begins intermittent kine.sock failures (closed connection errors in kubelite log at 20:10, 20:15, 20:20, 20:20); KCM on k8s02 is periodically disconnected from control plane |
| **~20:21 AEST** | k8s01 goes NotReady or receives NoExecute taint during rolling recovery; `topologycache` logs "Can't get CPU or zone information for node k8s01" |
| **20:21:03 AEST** | k8s02 KCM reconnects to dqlite ("quota admission added evaluator for daemonsets.apps"); immediately processes pending eviction backlog |
| **20:21:04 AEST** | taint-eviction-controller fires: **6 jiva-ctrl pods evicted from k8s01 simultaneously**, including `pvc-746b2837-jiva-ctrl` (seerr, ClusterIP 10.152.183.57) and `pvc-a3a7e012-ctrl` (survive/minecraft, ClusterIP 10.152.183.22) |
| **20:21:08 AEST** | Jiva-ctrl containers exit on k8s01; TCP RST sent to iSCSI initiators on k8s02 |
| **20:21:09 AEST** | `connection1:0: detected conn error (1020)` in k8s02 dmesg for both seerr (sdb) and survive (sdc) iSCSI sessions |
| **20:23:09 AEST** | `session recovery timed out after 120 secs` — iSCSI sessions declared dead; SCSI devices go offline on k8s02 |
| **~20:23–20:28 AEST** | EXT4 journal aborts on sdb (seerr) and sdc (survive); both filesystems remounted read-only on k8s02 |
| **~20:27 AEST** | survive-minecraft pod on k8s02 begins I/O errors against sdc; pod becomes unavailable |
| **~20:28 AEST** | seerr pod on k8s02 begins I/O errors against sdb; pod enters read-only mode |
| **~20:55 AEST 2026-05-28** | Session started; cluster review shows radarr, sonarr, readarr, calibreweb stuck in ContainerCreating on k8s03 |
| **~21:00 AEST** | `kubectl get node k8s03 -o jsonpath='{.status.volumesInUse}'` shows 4 iSCSI volumes; `iscsiadm -m session` returns empty — iSCSI sessions not established despite node Ready |
| **~21:15 AEST** | Volume manager metrics checked: `desired_state_of_world{plugin_name="kubernetes.io/iscsi"}=4` present; `actual_state_of_world` entry absent; no `storage_operation_duration_seconds` for iSCSI — reconciler never ran |
| **~21:20 AEST** | pprof goroutine dump from k8s03 kubelet confirms: `processorListener.pop()` blocked in `[select, 33 minutes]`; 4 goroutines stuck in `WaitForAttachAndMount` |
| **~21:30 AEST** | Root cause identified: kine watch disruption from power outage caused ADC informer processorListeners to permanently stall; heartbeats unaffected |
| **~21:45 AEST** | k8s03 `volumesAttached` and `volumesInUse` patched to `[]` via `kubectl patch node k8s03 --subresource=status` |
| **~21:50 AEST** | k8s03 cordoned; 4 stuck pods force-deleted with `--grace-period=0` |
| **~22:00 AEST** | Pods rescheduled to k8s01/k8s02; ADC attached iSCSI volumes successfully on healthy nodes |
| **~22:05 AEST** | Pods Running on k8s01/k8s02 — but RS for 2 apps shows `terminatingReplicas:1`; no new pods created |
| **~22:10 AEST** | RS status checked: `{"terminatingReplicas":1,"replicas":1}` but `kubectl get pods -l <selector>` returns no pods |
| **~22:20 AEST** | Scale-to-0 then scale-to-1 attempted — no effect; terminatingReplicas:1 persists |
| **~22:30 AEST** | Root cause identified: k8s01 KCM pod informer stale (same kine watch disruption); KCM never received DELETE event for force-deleted pods |
| **~00:00 AEST 2026-05-29** | k8s01 cordoned; `snap.microk8s.daemon-k8s-dqlite` restarted first (PGM-201 procedure) |
| **~00:05 AEST** | `snap.microk8s.daemon-kubelite` restarted on k8s01 |
| **~00:15 AEST** | k8s01 returns to Ready; uncordoned; KCM re-lists all pods — terminatingReplicas cleared; RS creates new pods immediately |
| **~01:34 AEST** | All 4 media apps fully Running: radarr/sonarr/readarr on k8s01, calibreweb on k8s02 |
| **~02:15 AEST** | Session notes confirm cluster stable; k8s03 processorListener stall acknowledged as deferred (node remains cordoned) |
| **~2026-05-29 (separate)** | dependency-track-api-server-0 CrashLoopBackOff investigated; JDBC URL `dtrack-postgresql.ci` identified as root cause |
| **~10:35 AEST 2026-05-29** | JDBC URL changed to FQDN; PR #493 merged; pod deleted to trigger StatefulSet rolling update; pod reaches 1/1 Running with 0 restarts |
| **~09:40 AEST 2026-05-30** | Seerr pod investigated: found Failed/Terminating on cordoned k8s02 with read-only filesystem; stale CSI mounts blocking deletion; iSCSI session still logged in from k8s02 blocking mount on k8s01; JivaVolume CR `spec.mountInfo` stale from k8s02; k8s01 cordoned; pod rescheduled to k8s03 where iSCSI attached successfully; seerr 1/1 Running |
| **~10:30 AEST 2026-05-30** | Root cause traced via k8s02 syslog.2.gz: jiva-ctrl eviction at 20:21:04 confirmed as trigger; iSCSI → EXT4 cascade fully documented |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: iSCSI Media Pods Stuck ContainerCreating — kubelet Volume Manager processorListener Stall

##### How did the iSCSI pods get stuck in ContainerCreating on k8s03?

The pods were scheduled to k8s03 and the kubelet volume manager was waiting for iSCSI volumes to be attached before allowing containers to start. The `WaitForAttachAndMount` call in each pod worker goroutine never returned — pods were blocked before container creation could begin.

##### How did WaitForAttachAndMount never return?

`WaitForAttachAndMount` polls until the kubelet's actual-state-of-world (ASW) cache reports volumes as attached. The ASW is populated by the volume reconciler running `VerifyControllerAttachedVolume` for each desired volume, which reads `node.status.volumesAttached`. This check was never triggered because the volume reconciler depends on events from the kubelet's node informer — and those events had stopped flowing.

##### How did the volume reconciler stop receiving events?

The kubelet's node informer processes events via a `processorListener` goroutine that monitors the informer's delta queue. The `processorListener.pop()` goroutine was permanently blocked in a `select` statement — confirmed via pprof goroutine dump showing `[select, 33 minutes]` on multiple goroutines. No new delta queue items arrived; the goroutines were effectively starved.

##### How did the processorListeners become permanently starved?

After the power outage caused k8s-dqlite to crash and restart, kine's internal watch stream state became inconsistent. The kubelet's client-go informer watch connections appeared to reconnect at the TCP level (enough for the node heartbeat to continue), but the kine subscription state was corrupted — new watch events from kine were not delivered to the reconnected watchers. The informer's reflector received no new events, leaving the delta queue permanently empty. The goroutines block in `select` waiting for queue data that will never arrive.

##### How did k8s-dqlite's watch stream corruption leave watchers permanently starved with no error?

kine implements the Kubernetes watch API over SQLite. An abrupt power-loss crash can leave kine's internal tracking of per-watcher "resume-from" revisions in a corrupted or stale state. On kine restart, existing client watch connections re-establish at the transport layer, but kine re-registers them with a stale last-known-revision. New events are generated after the watcher's tracked revision but are silently discarded or missed. The watcher never detects this because the watch connection itself is alive — only the event flow has stopped. No error is logged by the kubelet or the informer.

##### How was this not detected or alerted?

- `kubectl get nodes` shows the node as `Ready: True` — heartbeats use a separate HTTPS endpoint that does not depend on the informer event queue
- `kubectl get pods` shows `ContainerCreating` increasing in age — but no alert is configured for pod age in ContainerCreating
- No Prometheus alert exists for `volume_manager_total_volumes{state="desired_state_of_world"} > 0` AND `actual_state_of_world` absent for > 5 minutes — this combination directly signals the stall
- pprof analysis was required to confirm the root cause; there is no self-diagnostic signal from the kubelet

---

#### Chain 2: RS Refuses to Create Replacement Pods — KCM Stale terminatingReplicas

##### How did the ReplicaSets fail to create replacement pods after stuck pods were force-deleted?

The RS controller on k8s01 showed `terminatingReplicas: 1` in its status (a K8s 1.35 feature). When `terminatingReplicas > 0`, the RS controller intentionally withholds creating new pods to avoid exceeding desired replicas while a deletion is in progress. The RS believed a pod was still terminating.

##### How did terminatingReplicas: 1 persist after force-delete with --grace-period=0?

`--grace-period=0 --force` immediately removes the pod object from the API server, so the pod no longer exists from the API's perspective. However, `terminatingReplicas` is tracked by the RS controller from its own pod informer cache, not by querying the API server directly. The k8s01 KCM's pod informer cache was stale — it had the deleted pod recorded as still existing (in Terminating state) and never received the DELETE event that would clear it.

##### How did the KCM's pod informer become stale?

The same kine watch stream disruption from the power outage that stalled k8s03's kubelet informers also affected k8s01's kube-controller-manager. The KCM's client-go pod informer processorListeners were blocked in `select` for the same underlying reason: after the kine restart, watch events stopped flowing. The KCM's view of the pod world was frozen at the pre-outage snapshot.

##### How was this not caught during initial diagnosis?

K8s 1.35 introduced `terminatingReplicas` as a new RS status field. Prior K8s versions would allow the RS to create a replacement pod immediately after force-delete. The scale-to-0/scale-to-1 workaround (a standard operator technique for forcing RS reconciliation) was tried, but also failed because the informer was stale for all pod events — scale-to-0 set replicas to 0, but the RS never reconciled because pod events were not flowing. There was no prior incident with this specific failure mode documented in this cluster's runbooks.

##### How was this not prevented or detected earlier?

- No alert monitors RS `terminatingReplicas > 0` combined with zero pods matching the RS label selector for > 2 minutes
- The K8s 1.35 terminatingReplicas behaviour was not documented in cluster runbooks or known as a possible failure mode
- kine watch stream stalls on a control-plane component (KCM on k8s01) are indistinguishable from normal operation via `kubectl get nodes` or standard health checks

---

---

#### Chain 4: seerr and survive Read-Only Filesystems — jiva-ctrl Eviction → iSCSI Session Drop → EXT4 Journal Abort

##### How did seerr and survive get read-only filesystems on k8s02?

Both pods ran on k8s02 with iSCSI-backed PVCs (seerr: `pvc-746b2837`, sdb; survive: `pvc-a3a7e012`, sdc). At 20:23–20:28 AEST, the ext4 kernel driver aborted the journal on both devices after pending writes failed, and remounted the filesystems read-only.

##### How did the filesystem writes fail?

The SCSI block devices (sdb, sdc) went offline. The kernel reported `blk_update_request: I/O error` for both devices. Once the block device is offline, in-flight journal commits fail, causing `jbd2` to abort the journal with the `-EIO` error path.

##### How did the SCSI devices go offline?

The iSCSI sessions for both volumes declared recovery failure at 20:23:09 AEST (`session recovery timed out after 120 secs`). The iSCSI initiator had detected TCP connection errors (`connection error 1020 = ISCSI_ERR_CONN_FAILED`) at 20:21:09 AEST, started 120-second session recovery, and gave up when the target did not reappear within that window. A lost iSCSI session causes the kernel to mark the SCSI device as offline.

##### How did the iSCSI TCP connections fail at 20:21:09?

The TCP connections ran from k8s02's iSCSI initiator to the jiva-ctrl pod IPs, reached via kube-proxy ClusterIP iptables rules. When the jiva-ctrl containers on k8s01 exited at 20:21:08, the kernel sent TCP RST to the existing connections — immediately triggering error 1020 on k8s02's initiator.

##### How did the jiva-ctrl pods exit at 20:21:08?

At 20:21:04 AEST, the taint-eviction-controller running on k8s02's kube-controller-manager issued deletion for 6 jiva-ctrl pods simultaneously. The pods were running on k8s01, which was in a NotReady state (confirmed by `topologycache: Can't get CPU or zone information for node k8s01` at 20:21:02). By default, pods receive `node.kubernetes.io/not-ready:NoExecute` toleration with `tolerationSeconds=300` — after 5 minutes of NotReady, they are eligible for eviction.

##### Why did all 6 evictions fire at exactly 20:21:04 rather than spreading over time?

The taint-eviction-controller on k8s02 was intermittently disconnected from k8s-dqlite throughout the recovery (kine.sock connection errors at 20:10, 20:15, 20:20). During disconnection, the controller could not process evictions. At 20:21:03, the kube-controller-manager reconnected to dqlite ("quota admission added evaluator for daemonsets.apps") and immediately processed its entire backlog of pending evictions — firing all 6 deletions within a single second. This **batched eviction** removed all iSCSI targets simultaneously, giving the initiator no time to fail over to individual session recovery.

##### How did the earlier 19:16 AEST iSCSI error differ?

At 19:16:07 AEST, iSCSI session errors also appeared (same error 1020), but the sessions recovered. The dmesg shows `eth0: link becomes ready` at 19:16:14 — a physical link flap that lasted only 7 seconds. Because the iSCSI targets (jiva-ctrl pods) were still alive, the TCP connections re-established after the link recovered. In the 20:21 case, the targets themselves were killed, so no recovery was possible.

##### How was this not detected or prevented?

- No alert exists for kernel-level iSCSI connection errors (`connection error 1020` in dmesg / kern.log)
- No alert exists for EXT4 filesystem remount-to-read-only (`Remounting filesystem read-only` in kern.log)
- The pvek8s rolling restart recovery procedure does not include a step to check whether the node being restarted hosts jiva-ctrl pods before applying taints
- jiva-ctrl pods have the default `tolerationSeconds=300` with no extended toleration to survive brief node NotReady transitions during recovery
- After the jiva-ctrl pods were evicted, no automated remediation attempted to restart affected workloads or alert on their read-only state

---

#### Chain 3: dependency-track API Server 6-Day CrashLoop — Java JVM DNS Resolution Failure

##### How did dependency-track-api-server fail to connect to PostgreSQL for 6+ days?

The JDBC URL was set to `jdbc:postgresql://dtrack-postgresql.ci:5432/dtrack`. This hostname format (`<service>.<namespace>`, one dot) failed DNS resolution inside the Java application.

##### How did the hostname fail to resolve despite being a valid Kubernetes service?

The PostgreSQL service exists as `dtrack-postgresql.ci.svc.cluster.local` (ClusterIP 10.152.183.238). Linux glibc would resolve `dtrack-postgresql.ci` correctly via resolv.conf search domains (`ndots:5` means hostnames with fewer than 5 dots are searched against `svc.cluster.local`, `cluster.local`, etc.). However, Java's JVM DNS resolver (`sun.net.dns.ResolverConfigurationImpl`) does not always honour OS-level ndots search domain expansion consistently. The JVM resolved the hostname literally, found no external DNS record for `dtrack-postgresql.ci`, and threw `UnknownHostException`.

##### How did this misconfiguration persist for 6 days undetected?

The pod entered CrashLoopBackOff immediately on initial deployment. With exponential backoff reaching its maximum interval (~5 minutes), the pod was restarting roughly every 5 minutes — 501 times over 6d23h. There was no Prometheus or Nagios alert configured for pods in CrashLoopBackOff in the `ci` namespace. The pod appeared in `kubectl get pods -A` as `CrashLoopBackOff` but no automated notification was triggered.

##### How was the misconfiguration not caught at deployment time?

There is no deployment smoke test or health check that verifies the application can establish a database connection before committing the deployment. The StatefulSet startup probe (`/health/started`) is never reached because the application crashes during JDBC connection initialisation — before Jetty starts listening. A basic `nslookup dtrack-postgresql.ci` from a test pod in the same namespace would have caught this during initial deployment.

---

## Impact

### Services Affected

| Service | Impact | Duration |
|---------|--------|----------|
| radarr (k8s03) | ContainerCreating, fully unavailable | ~5h 20m |
| sonarr (k8s03) | ContainerCreating, fully unavailable | ~5h 20m |
| readarr (k8s03) | ContainerCreating, fully unavailable | ~5h 20m |
| calibreweb (k8s03) | ContainerCreating, fully unavailable | ~5h 20m |
| k8s03 kubelet volume manager | iSCSI attach broken; processorListeners stalled | Persists (node cordoned; workloads rescheduled) |
| seerr (k8s02) | Filesystem read-only at 20:23 AEST; pod Failed/Terminating on cordoned k8s02; unable to reschedule for ~14h | ~14h (20:23 2026-05-28 → ~09:40 2026-05-30 when recovered on k8s03) |
| survive/minecraft (k8s02) | Filesystem read-only at 20:27 AEST; pod unavailable until rescheduled to k8s01 | ~hours (resolved during primary recovery session) |
| dependency-track API server | CrashLoopBackOff (501 restarts), fully unavailable | ~6d 23h |

### Duration

- **Media apps outage (primary incident):** ~5h 20m
- **dependency-track outage (separate, pre-existing):** ~6d 23h
- **Expected recovery time (with documented procedure):** ~20 min

### Scope

- Nodes affected: k8s03 (kubelet informer stall), k8s01 (KCM informer stall, required restart)
- No data loss: PVC data on iSCSI volumes was not affected; the kubelite restart on k8s01 only reset in-memory informer caches
- User-visible impact: All 4 media management services fully unavailable during the outage window; dependency-track unavailable for ~7 days
- k8s03 kubelet processorListener stall technically persists (mitigated by cordoning and rescheduling all iSCSI workloads to healthy nodes)

---

## Resolution Steps Taken

### Phase 1: Diagnosis of k8s03 Volume Manager Stall

1. Checked pod states — 4 media pods stuck in ContainerCreating for hours on k8s03
2. Verified iSCSI session state on k8s03 — `iscsiadm -m session` returned empty; no active iSCSI sessions despite 4 PVCs claimed
3. Checked node volume status:
   ```bash
   kubectl --context pvek8s get node k8s03 -o jsonpath='{.status.volumesInUse}'
   # → [kubernetes.io/iscsi/..., kubernetes.io/iscsi/..., ...]  (4 volumes listed)
   ```
4. Checked Prometheus volume manager metrics from k8s03 kubelet:
   ```
   volume_manager_total_volumes{plugin_name="kubernetes.io/iscsi",state="desired_state_of_world"} = 4
   # actual_state_of_world entry: absent
   # storage_operation_duration_seconds for iSCSI: absent (zero operations)
   ```
5. Captured pprof goroutine dump:
   ```bash
   sudo kill -SIGUSR1 $(pgrep -f 'snap.microk8s.daemon-kubelite')
   sudo journalctl -u snap.microk8s.daemon-kubelite | grep -A3 "processorListener.pop"
   # → goroutines blocked in [select, 33 minutes]
   sudo journalctl -u snap.microk8s.daemon-kubelite | grep "WaitForAttachAndMount"
   # → 4 goroutines blocked in WaitForAttachAndMount
   ```
6. Confirmed root cause: kine watch disruption from power outage had permanently stalled k8s03 kubelet informers

### Phase 2: Fix k8s03 Volume Manager Stall

1. Patched k8s03 node status to clear stale volumesAttached and volumesInUse (unblocks ADC on other nodes):
   ```bash
   kubectl --context pvek8s patch node k8s03 --subresource=status --type=json \
     -p='[{"op":"replace","path":"/status/volumesAttached","value":[]},{"op":"replace","path":"/status/volumesInUse","value":[]}]'
   ```
2. Cordoned k8s03 to prevent new pod scheduling:
   ```bash
   kubectl --context pvek8s cordon k8s03
   ```
3. Force-deleted the 4 stuck pods:
   ```bash
   kubectl --context pvek8s delete pod -n media radarr-0 sonarr-0 readarr-0 calibreweb-0 --force --grace-period=0
   ```
4. Pods rescheduled to k8s01/k8s02; ADC attached iSCSI volumes successfully within ~2 minutes

### Phase 3: Diagnosis of KCM Stale terminatingReplicas

1. Checked RS status for affected apps:
   ```bash
   kubectl --context pvek8s get rs -n media -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status}{"\n"}{end}'
   # → radarr-XXXXXX  {"terminatingReplicas":1,"replicas":1}
   ```
2. Confirmed no matching pods exist:
   ```bash
   kubectl --context pvek8s get pods -n media -l app.kubernetes.io/name=radarr
   # → No resources found
   ```
3. Attempted scale-to-0 then scale-to-1 — RS reconciled (replicas changed) but terminatingReplicas:1 persisted; no new pod created
4. Identified root cause: k8s01 KCM pod informer stale; force-delete DELETE event never delivered to KCM

### Phase 4: Fix k8s01 KCM Stale Informer

1. Cordoned k8s01:
   ```bash
   kubectl --context pvek8s cordon k8s01
   ```
2. Restarted k8s-dqlite first (kine must precede kubelite restart per PGM-201):
   ```bash
   ssh k8s01 "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
   sleep 10
   ```
3. Restarted kubelite on k8s01:
   ```bash
   ssh k8s01 "sudo systemctl restart snap.microk8s.daemon-kubelite.service"
   ```
4. Waited for k8s01 to return to Ready:
   ```bash
   kubectl --context pvek8s wait node/k8s01 --for=condition=Ready --timeout=120s
   ```
5. Uncordoned k8s01:
   ```bash
   kubectl --context pvek8s uncordon k8s01
   ```
6. KCM immediately re-listed pods; terminatingReplicas cleared; RS created new pods within 30 seconds

### Phase 5: Recovery of seerr from k8s02 Read-Only Filesystem (2026-05-30)

1. Confirmed seerr pod stuck in `Failed` / `Terminating` on cordoned k8s02 — filesystem had gone read-only, preventing jiva-csi from running `chmod` on the mount directory during pod teardown
2. Unmounted stale CSI mounts from inside `openebs-jiva-csi-node-v2pjb` container on k8s02:
   ```bash
   kubectl exec -n openebs openebs-jiva-csi-node-v2pjb -c jiva-csi-plugin -- \
     umount /var/snap/microk8s/common/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/pvc-746b2837.../mount
   kubectl exec -n openebs openebs-jiva-csi-node-v2pjb -c jiva-csi-plugin -- \
     umount /var/snap/microk8s/common/var/lib/kubelet/plugins/jiva.csi.openebs.io/<vol-id>/globalmount
   ```
3. Deleted the stuck pod:
   ```bash
   kubectl delete pod seerr-seerr-chart-0 -n media
   ```
4. New pod on k8s01 reported "already mounted at more than one place" — k8s02 still had active iSCSI session:
   ```bash
   kubectl exec -n openebs openebs-jiva-csi-node-v2pjb -c jiva-csi-plugin -- \
     iscsiadm -m node -T iqn.2016-09.com.openebs.jiva:pvc-746b2837-... \
     -p 10.152.183.57:3260 --logout
   ```
5. JivaVolume CR `spec.mountInfo` was still stale (pointing at k8s02 staging path) — patched to clear:
   ```bash
   kubectl patch jivavolume pvc-746b2837-ca3c-4b95-9168-7b767573f799 -n openebs \
     --type=merge -p '{"spec":{"mountInfo":{"devicePath":"","stagingPath":""}}}'
   ```
6. Cordoned k8s01; force-deleted pod to reschedule to k8s03:
   ```bash
   kubectl cordon k8s01
   kubectl delete pod seerr-seerr-chart-0 -n media --force --grace-period=0
   ```
7. Pod rescheduled to k8s03; jiva-csi on k8s03 successfully logged in iSCSI, mounted volume rw; seerr reached 1/1 Running
8. Uncordoned k8s01

### Phase 6: Fix dependency-track JDBC URL

1. Changed `ALPINE_DATABASE_URL` in `pgmac.net/ci/templates/dtrack.yaml`:
    - From: `jdbc:postgresql://dtrack-postgresql.ci:5432/dtrack`
    - To: `jdbc:postgresql://dtrack-postgresql.ci.svc.cluster.local:5432/dtrack`
2. Raised PR #493 against pgmac-net/pgk8s; merged
3. ArgoCD synced StatefulSet — StatefulSet spec updated but pod revision lagged (CrashLoopBackOff backoff delay)
4. Deleted pod to trigger StatefulSet rolling update:
   ```bash
   kubectl --context pvek8s delete pod dependency-track-api-server-0 -n ci
   ```
5. Pod recreated with new spec; reached 1/1 Running with 0 restarts within 97 seconds

---

## Verification

```bash
# All 4 media apps Running on healthy nodes
kubectl --context pvek8s get pods -n media -l 'app.kubernetes.io/name in (radarr,sonarr,readarr,calibre-web)'
# → All 1/1 Running, RESTARTS=0, on k8s01 or k8s02

# k8s01 healthy after restart
kubectl --context pvek8s get node k8s01
# → Ready   (SchedulingEnabled)

# dependency-track Running
kubectl --context pvek8s get pod dependency-track-api-server-0 -n ci
# → 1/1 Running   RESTARTS 0

# No ContainerCreating pods cluster-wide
kubectl --context pvek8s get pods -A | grep ContainerCreating
# → (empty)

# Verify updated JDBC URL in running pod
kubectl --context pvek8s get pod dependency-track-api-server-0 -n ci \
  -o jsonpath='{.spec.containers[0].env}' | python3 -m json.tool | grep -A2 DATABASE_URL
# → "value": "jdbc:postgresql://dtrack-postgresql.ci.svc.cluster.local:5432/dtrack"
```

---

## Preventive Measures

### Immediate Actions Required

1. **Add Prometheus alert for iSCSI volume manager stall** (High)
    - Alert when `volume_manager_total_volumes{plugin_name="kubernetes.io/iscsi",state="desired_state_of_world"} > 0` AND `volume_manager_total_volumes{plugin_name="kubernetes.io/iscsi",state="actual_state_of_world"}` is absent for > 5 minutes on any node
    - This combination directly signals the processorListener stall before pods have been stuck for 33+ minutes
    - Linear: [PGM-214](https://linear.app/pgmac-net-au/issue/PGM-214)

2. **Restart k8s03 kine+kubelite to clear residual processorListener stall** (Medium)
    - k8s03's kubelet processorListeners are still stalled from the power outage; k8s03 cannot run iSCSI workloads until cleared
    - Schedule during maintenance: kine restart → kubelite restart using PGM-201 procedure (cordon first)
    - Linear: [PGM-215](https://linear.app/pgmac-net-au/issue/PGM-215)

3. **Kubelet volume manager stall runbook** (High) — created as part of this PIR
    - No runbook existed; recovery required ad-hoc pprof analysis and multiple diagnostic steps
    - Runbook: [kubelet-volume-manager-stall.md](../runbooks/kubelet-volume-manager-stall.md)
    - Linear: [PGM-216](https://linear.app/pgmac-net-au/issue/PGM-216)

4. **KCM stale terminatingReplicas runbook** (Medium) — created as part of this PIR
    - No runbook existed; K8s 1.35 terminatingReplicas behaviour was undocumented in cluster runbooks
    - Runbook: [kcm-stale-terminating-replicas.md](../runbooks/kcm-stale-terminating-replicas.md)
    - Linear: [PGM-217](https://linear.app/pgmac-net-au/issue/PGM-217)

5. **jiva-ctrl eviction → iSCSI read-only filesystem runbook** (High) — created as part of this PIR
    - No runbook existed; recovery required ad-hoc investigation across dmesg, syslog, JivaVolume CRs, and iSCSI session state
    - Runbook: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md)
    - Linear: [PGM-224](https://linear.app/pgmac-net-au/issue/PGM-224)

6. **Add log-based alerts for EXT4 read-only remount and iSCSI session failure** (High)
    - Alert on `EXT4-fs.*Remounting filesystem read-only`, `session recovery timed out`, `ISCSI_ERR_CONN_FAILED` in kern.log via Alloy/Promtail
    - These patterns appear in the kernel log before any pod-level signal — earliest possible detection point
    - Linear: [PGM-221](https://linear.app/pgmac-net-au/issue/PGM-221)

7. **Uncordon k8s02** (Medium)
    - Verify stale mounts and iSCSI sessions are fully cleaned up; then uncordon
    - Linear: [PGM-225](https://linear.app/pgmac-net-au/issue/PGM-225)

### Longer-Term Improvements

1. **Add alert for RS terminatingReplicas stale state** (Medium)
    - Alert when a ReplicaSet's `kube_replicaset_status_observed_generation` shows `terminatingReplicas > 0` but `kube_pod_status_phase{phase="Running"}` for the RS selector is 0, for > 3 minutes
    - Catches the KCM informer stall scenario without requiring manual RS inspection
    - Linear: [PGM-218](https://linear.app/pgmac-net-au/issue/PGM-218)

2. **Add extended NoExecute toleration to jiva-ctrl pods** (Medium)
    - Increase `tolerationSeconds` from default 300 to 600 for `node.kubernetes.io/not-ready` and `unreachable` taints
    - Gives more time for transient node issues to resolve before evicting storage infrastructure
    - Linear: [PGM-222](https://linear.app/pgmac-net-au/issue/PGM-222)

3. **Create rolling node restart runbook for nodes hosting jiva-ctrl pods** (Medium)
    - Before tainting/draining a node: identify hosted jiva-ctrl pods, migrate dependent workloads away first, verify iSCSI sessions logged out, then proceed with restart
    - Linear: [PGM-223](https://linear.app/pgmac-net-au/issue/PGM-223)

4. **Add CrashLoopBackOff alert for ci namespace** (Low)
    - dependency-track crashed 501 times over 6d23h with no alert fired
    - Add Nagios/Prometheus alert for `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff",namespace="ci"} > 0`
    - Linear: [PGM-219](https://linear.app/pgmac-net-au/issue/PGM-219)

---

## Lessons Learned

### What Went Well

- The pprof goroutine dump from the kubelet provided an unambiguous diagnosis of the processorListener stall — the `[select, 33 minutes]` signature and `WaitForAttachAndMount` blocked goroutines are definitive
- The `volume_manager_total_volumes` metric correctly reflected the stall (desired_state != actual_state for iSCSI) — this is a reliable, non-invasive diagnostic that can be automated into an alert
- Patching `volumesAttached` + `volumesInUse` on the stalled node was safe (no data at risk) and allowed ADC to reattach the PVCs to healthy nodes without a node restart
- The PGM-201 procedure (kine → kubelite restart) is well-documented and worked reliably to flush the stale KCM informer cache

### What Didn't Go Well

- Initial investigation assumed the iSCSI attachment failure was a transient ADC scheduling issue rather than an informer stall — ~20 minutes elapsed before the pprof dump was captured and the stall was confirmed
- Scale-to-0/scale-to-1 was tried as a standard workaround before understanding the KCM informer itself was stale — this is a valid technique for RS reconciliation issues but does not help when the event delivery mechanism is broken
- dependency-track had been crashing for 7 days with no alert; it was noticed only incidentally during media app recovery
- k8s03's processorListener stall was not cleared as part of this incident — a future scheduled maintenance restart will be needed

- The seerr pod was stuck in `Failed`/`Terminating` for ~36 hours because the read-only filesystem prevented jiva-csi from running `chmod` during pod teardown — `pod.deletionTimestamp` was set but the finalizer was never cleared. The fix required manually unmounting the stale CSI mounts from inside the jiva-csi-node DaemonSet container.
- Clearing stale `spec.mountInfo` on the JivaVolume CR was necessary because jiva-csi on the new node saw the k8s02 staging path and device still set, and refused to proceed (treating it as "already mounted elsewhere").

### Surprise Findings

- **K8s 1.35 terminatingReplicas RS field**: New in K8s 1.35, this field prevents RS from creating replacement pods when it believes a pod is still terminating. With a stale informer, this field gets stuck and scale-to-0/scale-to-1 cannot bypass it — a full KCM informer flush (via kine+kubelite restart) is required.
- **kubelet heartbeats are independent of informer health**: A node can show `Ready: True` with completely stalled informers. The heartbeat mechanism uses a separate HTTPS POST to `/api/v1/nodes/<name>/status` that does not traverse the informer event queue.
- **kine watch stream corruption is silent**: No error is logged by kubelet, kube-controller-manager, or kine when watch events stop flowing after a kine crash-restart. The only observables are stalled goroutines (pprof) and absent metrics (volume manager, RS status).
- **Batched taint eviction is more destructive than staggered**: When the KCM reconnects to dqlite after a disconnect, it processes pending evictions in a burst. Six jiva-ctrl pods deleted in one second is more damaging than one every 30 seconds because all iSCSI initiators lose their targets simultaneously, preventing session recovery.
- **iSCSI session recovery (120s default) is too short for pod restart**: If a jiva-ctrl pod is evicted and rescheduled, it may take >120 seconds to start and register — especially if the node it moves to is also recovering. The 120s timeout causes the EXT4 journal to abort before the new target becomes available.
- **JivaVolume CR `spec.mountInfo` is not cleaned up on pod deletion**: When a pod is force-deleted or fails ungracefully, the JivaVolume CR retains the last node's staging path and device in `spec.mountInfo`. On the next mount attempt from a different node, jiva-csi treats this as an active mount elsewhere and refuses. This requires manual patching to clear.
- **Java JVM DNS does not always honour OS ndots**: `<service>.<namespace>` hostnames (one dot, ndots:5) that glibc would expand correctly via search domains may fail in Java's JVM DNS resolver. Always use full FQDNs (`<service>.<namespace>.svc.cluster.local`) in Java application database URLs.

---

## Action Items

| # | Action | Priority | Linear |
|---|--------|----------|--------|
| 1 | Add Prometheus alert for iSCSI volume manager stall | High | [PGM-214](https://linear.app/pgmac-net-au/issue/PGM-214) ✅ Done |
| 2 | Restart k8s03 kine+kubelite to clear residual processorListener stall | Medium | [PGM-215](https://linear.app/pgmac-net-au/issue/PGM-215) |
| 3 | Kubelet volume manager stall runbook (created) | High | [PGM-216](https://linear.app/pgmac-net-au/issue/PGM-216) ✅ Done |
| 4 | KCM stale terminatingReplicas runbook (created) | Medium | [PGM-217](https://linear.app/pgmac-net-au/issue/PGM-217) ✅ Done |
| 5 | Add alert for RS terminatingReplicas stale state | Medium | [PGM-218](https://linear.app/pgmac-net-au/issue/PGM-218) |
| 6 | Add CrashLoopBackOff alert for ci namespace | Low | [PGM-219](https://linear.app/pgmac-net-au/issue/PGM-219) |
| 7 | jiva-ctrl eviction → iSCSI ro filesystem runbook (created) | High | [PGM-224](https://linear.app/pgmac-net-au/issue/PGM-224) ✅ Done |
| 8 | Add log-based alerts: EXT4 ro remount + iSCSI session failure | High | [PGM-221](https://linear.app/pgmac-net-au/issue/PGM-221) |
| 9 | Add extended NoExecute toleration to jiva-ctrl pods | Medium | [PGM-222](https://linear.app/pgmac-net-au/issue/PGM-222) |
| 10 | Create rolling node restart runbook for jiva-ctrl nodes | Medium | [PGM-223](https://linear.app/pgmac-net-au/issue/PGM-223) |
| 11 | Uncordon k8s02 | Medium | [PGM-225](https://linear.app/pgmac-net-au/issue/PGM-225) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03)
- **Kubernetes version:** v1.35.0 (server), v1.36.1 (client)
- **Storage:** OpenEBS Jiva iSCSI (`openebs-jiva-default` storage class)
- **k8s-dqlite / kine:** microk8s embedded (`snap.microk8s.daemon-k8s-dqlite`)

### Key Error Signatures

**pprof goroutine dump — processorListener stall:**
```
goroutine NNNNN [select, 33 minutes]:
k8s.io/client-go/tools/cache.(*processorListener).pop(...)
  .../client-go/tools/cache/controller.go
```

**pprof goroutine dump — WaitForAttachAndMount blocked:**
```
goroutine NNNNN [semacquire, 33 minutes]:
sync.runtime_SemacquireMutex(...)
k8s.io/kubernetes/pkg/volume/util/operationexecutor.(*volumeToMount).WaitForAttachAndMount(...)
```

**Volume manager metrics showing stall (absent actual_state_of_world):**
```
volume_manager_total_volumes{plugin_name="kubernetes.io/iscsi",state="desired_state_of_world"} 4
# actual_state_of_world: NOT EMITTED → reconciler never ran
# storage_operation_duration_seconds{plugin_name="kubernetes.io/iscsi"}: NOT EMITTED → zero attach operations
```

**RS terminatingReplicas stale state:**
```bash
kubectl --context pvek8s get rs <name> -n <ns> -o jsonpath='{.status}'
# → {"terminatingReplicas":1,"replicas":1}
kubectl --context pvek8s get pods -n <ns> -l <selector>
# → No resources found
```

**Java JVM DNS failure:**
```
java.net.UnknownHostException: dtrack-postgresql.ci
  at alpine.server.upgrade.UpgradeMetaProcessor.createConnection(UpgradeMetaProcessor.java:193)
Caused by: org.postgresql.util.PSQLException: The connection attempt failed.
Caused by: java.net.UnknownHostException: dtrack-postgresql.ci
```

### Key Error Signatures — iSCSI/EXT4 Read-Only Cascade (Chain 4)

**dmesg / kern.log — iSCSI connection failure:**
```
iscsid: connection1:0: detected conn error (1020)
iscsid: session1: session recovery timed out after 120 secs
sd X:0:0:0: [sdX] rejecting I/O to offline device
blk_update_request: I/O error, dev sdX, sector NNNN op 0x1:(WRITE)
```

**dmesg / kern.log — EXT4 journal abort and ro remount:**
```
JBD2: Detected IO errors while flushing file data on sdX-8
Aborting journal on device sdX-8.
EXT4-fs (sdX): I/O error while writing superblock
EXT4-fs error (device sdX): ext4_journal_check_start:61: Detected aborted journal
EXT4-fs (sdX): Remounting filesystem read-only
```

**syslog — taint eviction batch (root cause):**
```
taint_eviction.go:111] "Deleting pod" controller="taint-eviction-controller" pod="openebs/pvc-XXXXXXXX-jiva-ctrl-YYYY-ZZZZ"
```
Six lines at identical timestamps = batched eviction after KCM reconnect.

**syslog — KCM reconnect marker (immediately before eviction burst):**
```
controller.go:667] quota admission added evaluator for: daemonsets.apps
```
This line signals that kube-controller-manager just became active after a dqlite disconnect.

**JivaVolume CR — stale mountInfo blocking remount:**
```bash
kubectl get jivavolume <pvc-name> -n openebs -o jsonpath='{.spec.mountInfo}'
# → {"devicePath":"/dev/disk/by-path/ip-10.152.183.57:3260-iscsi-...", "fsType":"ext4",
#    "stagingPath":"/var/snap/microk8s/.../globalmount", "nodeID":"k8s02"}
# If nodeID does not match current scheduling node → stale, needs patching
```

**Clear stale JivaVolume mountInfo:**
```bash
kubectl patch jivavolume <pvc-name> -n openebs --type=merge \
  -p '{"spec":{"mountInfo":{"devicePath":"","stagingPath":""}}}'
```

**Log out stale iSCSI session from old node (via jiva-csi-node container):**
```bash
kubectl exec -n openebs openebs-jiva-csi-node-<id> -c jiva-csi-plugin -- \
  iscsiadm -m node \
  -T iqn.2016-09.com.openebs.jiva:<pvc-name> \
  -p <controller-clusterip>:3260 --logout
```

**Unmount stale CSI mounts from old node (needed when ro fs blocks pod finalizer):**
```bash
# Inside jiva-csi-node container on the affected node:
kubectl exec -n openebs openebs-jiva-csi-node-<id> -c jiva-csi-plugin -- \
  umount /var/snap/microk8s/common/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pvc>/mount
kubectl exec -n openebs openebs-jiva-csi-node-<id> -c jiva-csi-plugin -- \
  umount /var/snap/microk8s/common/var/lib/kubelet/plugins/jiva.csi.openebs.io/<vol-id>/globalmount
```

### Patch volumesAttached and volumesInUse on Stalled Node

```bash
# Clears stale volume claims on the stalled node, allowing ADC to attach to other nodes
kubectl --context pvek8s patch node <node> --subresource=status --type=json \
  -p='[{"op":"replace","path":"/status/volumesAttached","value":[]},{"op":"replace","path":"/status/volumesInUse","value":[]}]'
```

### Capture pprof Goroutine Dump from Kubelet

```bash
# Signal the kubelite process to dump goroutines to its journal
sudo kill -SIGUSR1 $(pgrep -f 'snap.microk8s.daemon-kubelite')

# Check for processorListener stalls (look for [select, Xmin] patterns)
sudo journalctl -u snap.microk8s.daemon-kubelite | grep -B2 -A5 "processorListener"

# Check for WaitForAttachAndMount blocks
sudo journalctl -u snap.microk8s.daemon-kubelite | grep -A3 "WaitForAttachAndMount"
```

### Trigger StatefulSet Rolling Update After Spec Change with CrashLoopBackOff Backoff

```bash
# After ArgoCD sync, CrashLoopBackOff pods may not restart immediately due to exponential backoff.
# Delete the pod to force StatefulSet controller to recreate with updated spec immediately.
kubectl --context pvek8s delete pod <statefulset-pod-name> -n <namespace>
kubectl --context pvek8s wait pod <statefulset-pod-name> -n <namespace> --for=condition=Ready --timeout=180s
```

---

## References

- Linear: [PGM-213](https://linear.app/pgmac-net-au/issue/PGM-213) — dependency-track JDBC URL fix (fix/dtrack-db-url-pgm-213, PR #493)
- Linear: [PGM-221](https://linear.app/pgmac-net-au/issue/PGM-221) — Add log-based alerts for EXT4 ro remount and iSCSI session failure
- Linear: [PGM-222](https://linear.app/pgmac-net-au/issue/PGM-222) — Add extended NoExecute toleration to jiva-ctrl pods
- Linear: [PGM-223](https://linear.app/pgmac-net-au/issue/PGM-223) — Create safe rolling node restart runbook for jiva-ctrl nodes
- Linear: [PGM-224](https://linear.app/pgmac-net-au/issue/PGM-224) — jiva-ctrl eviction runbook (created)
- Linear: [PGM-225](https://linear.app/pgmac-net-au/issue/PGM-225) — Uncordon k8s02
- Related PIR: [k8s03 Extended Recovery — kine Watch Corruption, VXLAN Route Corruption, and Kubelet Watch Stream Stall](2026-05-18-k8s03-extended-recovery-kine-watch-vxlan-route-corruption.md)
- Related PIR: [dqlite Snapshot Bloat → Watch Stream Failure](2026-04-02-dqlite-snapshot-crash-loop-watch-stream-failure.md)
- Runbook: [jiva-ctrl-eviction-iscsi-ro-filesystem.md](../runbooks/jiva-ctrl-eviction-iscsi-ro-filesystem.md) — jiva-ctrl eviction → iSCSI drop → EXT4 ro cascade (new, from this PIR)
- Runbook: [jiva-ctrl-node-rolling-restart.md](../runbooks/jiva-ctrl-node-rolling-restart.md) — safe pre-restart migration procedure to prevent this failure mode
- Runbook: [kubelet-volume-manager-stall.md](../runbooks/kubelet-volume-manager-stall.md) — iSCSI WaitForAttachAndMount hang from processorListener stall
- Runbook: [kcm-stale-terminating-replicas.md](../runbooks/kcm-stale-terminating-replicas.md) — stale terminatingReplicas after kine watch disruption
- Runbook: [kubelet-silent-stall.md](../runbooks/kubelet-silent-stall.md) — related failure modes (pod watch goroutine stall, PLEG stall)
- Runbook: [dqlite-write-contention.md](../runbooks/dqlite-write-contention.md) — kine restart ordering and safety procedure
- Script: [recover-post-outage.sh](recover-post-outage.sh) — recovery script executed during this incident (archived; for future outages use [pvek8s-outage-recovery.sh](../runbooks/pvek8s-outage-recovery.sh))

---

## Reviewers

- @pgmac
