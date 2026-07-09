---
tags:
  - k8s01
  - k8s02
  - k8s03
  - kine
  - dqlite
  - watch-stream
  - scheduling
  - storage
  - nagios
---

# Post Incident Review: pvek8s Scheduling Outage — k8s03 Watch-Cache Freeze and Auto-Remediation Delivery Failure

**Date:** 2026-07-09
**Duration:** ~5h 19m active (~02:03 AEST → ~07:22 AEST)
**Severity:** High (zero pod scheduling cluster-wide for 5+ hours; existing workloads unaffected; no data loss)
**Status:** Resolved

---

## Executive Summary

At 02:03 AEST a roughly two-minute dqlite write-contention burst hit all three nodes (`database is locked (try: 500)` on k8s01/k8s02, kine range/txn deadline errors on k8s03). The burst broke the k8s03 apiserver's watch on kine, freezing its watch cache. k8s03 held both the kube-scheduler and kube-controller-manager leader leases, so every reflector-based view those leaders relied on went silently stale: from 02:04 AEST until recovery at 07:20 AEST, not a single new pod was scheduled cluster-wide, while leases kept renewing and `kubectl get` looked healthy. 138 pods accumulated Pending — 136 of them microk8s hostpath-provisioner helper pods, recreated every ~8 minutes for two arc-runner PVCs and invisible to the frozen scheduler.

The watch-cache freeze itself is a known failure mode with a runbook and, since 2026-07-04, automated remediation. The automation half-worked: Nagios detected the freeze at 02:07 AEST and fired the `event_watch_cache_remediate` event handler on all three attempts (SOFT 1, SOFT 2, HARD 3) — but none of the NRPE calls resulted in the remediation script running on k8s03. During the freeze every k8s NRPE check on the node was running to its 30–40s timeout against the dead apiserver while nagios' `check_nrpe` gives up at 15s, and Nagios never refires an event handler while a service sits in steady HARD CRITICAL. The automation got exactly three delivery attempts, all during the worst minutes of the incident, then nothing for five hours.

Manual recovery followed the control-plane-watch-cache-freeze runbook: the RV=0 test confirmed k8s03 frozen (cache read 0, quorum read 1; k8s01/k8s02 healthy), then cordon → restart `k8s-dqlite` → restart `kubelite` → canary pod verified in both scheduling and the rebuilt cache → uncordon. The scheduling backlog drained within minutes.

Two pieces of collateral needed separate fixes. First, the two arc-runner PVs provisioned *during* the freeze were created with an empty node in their `nodeAffinity` (`kubernetes.io/hostname In [""]`) — permanently unschedulable claims, and PV nodeAffinity is immutable. Recycling the idle EphemeralRunner CRs produced correctly-provisioned replacements within ~80 seconds. Second, the incident surfaced a chronic leak: orphaned hostpath-provisioner directories (~10.6G across k8s02/k8s03) from every previous incident where provisioner cleanup helpers failed to run. That was fixed the same day with a new `microk8s-hostpath-orphans` Nagios check and an orphan-reclaim pass in `k8s-disk-clean.yml` ([homelabia#135](https://github.com/pgmac-net/homelabia/issues/135)).

This is the third watch-cache freeze PIR (after PGM-241 and the 2026-06-24 k8s02 freeze) but the first where the auto-remediation existed and failed to deliver. The primary preventive action is moving the remediation trigger onto the node itself as a systemd-timer dead-man switch, removing the nagios→NRPE delivery dependency entirely ([homelabia#134](https://github.com/pgmac-net/homelabia/issues/134)).

---

## Timeline (AEST — UTC+10)

| Time | Event |
| --------------- | ------- |
| **02:03 AEST** | dqlite write-contention burst begins: kine `context canceled` / `context deadline exceeded` on k8s03 range and txn queries (first at 02:03:07); `database is locked (try: 500)` on k8s01 and k8s02 |
| **02:03 AEST** | Last successfully scheduled pods for the next 5h17m (two hostpath helper pods started 02:03:55) |
| **02:04 AEST** | arc-runner PVCs `self-hosted-v8tkc-runner-{lm789,r4nnc}-work` created; provisioner begins its helper-pod retry loop |
| **02:05 AEST** | Write burst subsides (last deadline error 02:05:27). k8s03 apiserver watch cache now frozen; scheduler and KCM leaders on k8s03 serving from the frozen cache |
| **02:07 AEST** | Nagios `microk8s-watch-cache` on k8s03 goes CRITICAL (SOFT 1); event handler fires — no remediation unit starts on the node |
| **02:09 AEST** | SOFT 2 event handler attempt — same result |
| **02:11 AEST** | HARD CRITICAL; third and final event handler attempt — `journalctl -u watch-cache-remediate` on k8s03 stays empty. `microk8s-watch-cache` check output degrades to `CHECK_NRPE STATE CRITICAL: Socket timeout after 15 seconds` for the rest of the incident |
| **02:15 AEST** | `check_snap_disk` WARNING on k8s02 (23% free) — image-fs pressure aggravated by helper-pod churn |
| **02:21 AEST** | `microk8s-pending-pods` HARD CRITICAL on k8s03 |
| **02:45 AEST** | `microk8s-scheduler-stall` HARD CRITICAL on k8s01: pods Pending >10m with **zero scheduler events** |
| **02:04–07:14 AEST** | Helper pods for the two arc-runner PVCs accumulate one per ~8min retry, reaching 136 Pending; `FreeDiskSpaceFailed` events on k8s01/k8s02 (kubelet image GC freeing 0 bytes) |
| **07:14 AEST** | Paul reports cluster issues; investigation begins. Nagios shows dqlite-scheduler WARNING x3 (Pending pods: 138), scheduler-stall CRITICAL, pending-pods CRITICAL, watch-cache socket timeout |
| **07:16 AEST** | Leases confirmed renewing (scheduler + KCM held by k8s03); KCM confirmed alive (job created 84s prior); helper pods confirmed to have **no status conditions and no events** — scheduler never saw them |
| **07:17 AEST** | RV=0 test: `cache-canary` visible in quorum read on all nodes, **absent from k8s03's `resourceVersion=0` read** — k8s03 watch cache frozen; k8s01/k8s02 healthy. `journalctl -u watch-cache-remediate` on k8s03: empty — automation never ran |
| **07:18 AEST** | Runbook manual recovery: `kubectl cordon k8s03`; `systemctl restart snap.microk8s.daemon-k8s-dqlite` on k8s03; verified active, zero `database is locked` |
| **07:20 AEST** | `systemctl restart snap.microk8s.daemon-kubelite` on k8s03; node Ready. `kubectl wait` on the canary returned NotFound (documented stale-read gotcha) — verified via quorum read instead |
| **07:21 AEST** | Canary pod Succeeded on k8s03 **and** visible in k8s03's RV=0 cache read; unpinned canary also Succeeded, proving the scheduler was scheduling again; k8s03 uncordoned |
| **07:25 AEST** | Pending backlog drained from 138 to 2; missed CronJob backlog (renovate, heartbeat, weather) executing |
| **07:23 AEST** | Remediation delivery path tested end-to-end (manual `check_nrpe -c event_watch_cache_remediate` from the nagios4 container): unit starts, detects healthy cache, exits `FALSE ALARM ... no action taken` — script logic sound, delivery was the failure |
| **07:30 AEST** | Two arc-runner pods still Pending: `FailedScheduling ... didn't match PersistentVolume's node affinity`. Both PVs found with `nodeAffinity: kubernetes.io/hostname In [""]` — empty hostname recorded during the freeze; PV nodeAffinity immutable |
| **07:36 AEST** | Idle EphemeralRunner CRs `self-hosted-v8tkc-runner-{lm789,r4nnc}` deleted; ARC replacements Running with correctly-provisioned PVs ~80s later; broken PVs garbage-collected |
| **07:40 AEST** | 78 Completed helper pods deleted; kine reconnect-failure spike from the restarts decayed to ~0/3min; `sec/renovate-29725560` pod Errored during the apiserver bounce (deleted by Paul later that morning) |
| **07:45 AEST** | All three node caches re-verified healthy via RV=0 canary; incident resolved |
| **~19:45 AEST** | Follow-up shipped same day: `microk8s-hostpath-orphans` NRPE check + `k8s-disk-clean.yml` orphan pass deployed; ~10.4G of orphaned provisioner dirs reclaimed (homelabia#135) |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: Zero pod scheduling cluster-wide for 5h17m — k8s03 Watch-Cache Freeze

##### How did all pod scheduling stop cluster-wide?

The kube-scheduler and kube-controller-manager leaders both ran on k8s03, and both consume the k8s03 apiserver's watch cache through their informers. That cache froze at 02:05 AEST, so the scheduler never saw any pod created after that moment — the 136 helper pods and 2 runner pods accumulated with no status conditions and no `FailedScheduling` events, because from the scheduler's view they didn't exist.

##### How did the k8s03 watch cache freeze?

The apiserver's watch on kine (`snap.microk8s.daemon-k8s-dqlite`) broke during the write burst and never recovered. Kine returned `context canceled` / `context deadline exceeded` on range and txn queries between 02:03:07 and 02:05:27; the broken watch feed left the cache serving its 02:05 snapshot indefinitely.

##### How did the write burst break the watch stream?

dqlite is single-writer; the burst drove kine queries past their retry budget (`try: 500 ... database is locked` on k8s01/k8s02). Query cancellations on k8s03's kine connection broke the apiserver's long-lived watch, a known consequence documented in the dqlite-write-contention and watch-cache-freeze runbooks. The trigger for the burst itself was transient (a CI `automation-job` started at 02:02:46, immediately before onset, is the only correlated event) — with the datastore vacuumed to 14M and no sustained load, the burst self-resolved in ~2 minutes.

##### How did a 2-minute burst cause a 5-hour outage?

The frozen cache does not self-heal. microk8s ships the apiserver with `DetectCacheInconsistency=false` (kine cannot support the consistency probes), which disables upstream Kubernetes' automatic detection and recovery for exactly this state. Once frozen, only a `k8s-dqlite` + `kubelite` restart clears it.

##### How was the freeze not detected and fixed promptly?

It **was** detected promptly — the purpose-built `microk8s-watch-cache` check went CRITICAL at 02:07 AEST, four minutes after onset, and its event handler fired. The five-hour outage is entirely attributable to Chain 2: the remediation never reached the node, and no human was watching at 2am.

---

#### Chain 2: Auto-remediation never ran — NRPE Delivery Failure Under Saturation

##### How did the remediation script never run on k8s03?

The nagios event handler (`event_watch_cache_remediate`) executes `check_nrpe -H k8s03 -c event_watch_cache_remediate -t 30` from the nagios container. nagios.log shows all three firings (02:07, 02:09, 02:11 AEST), but the NRPE daemon on k8s03 logged only scheduled check executions in that window — the handler's command never executed node-side, so `systemd-run` never started the remediation unit.

##### How were the handler's NRPE calls lost?

During the freeze, every kubectl-based NRPE check on k8s03 (`check_k8s_watch_cache`, `check_k8s_scheduler_stall`, and peers) ran to its full 30–40s internal timeout against the frozen apiserver. The nagios-side `check_nrpe` socket timeout is 15s — the scheduled `microk8s-watch-cache` check itself reported `Socket timeout after 15 seconds` for the entire incident. The same saturation window swallowed the three handler calls.

##### How did the automation get only three attempts in five hours?

Nagios event handlers fire on state *transitions* only: SOFT 1, SOFT 2, and the SOFT→HARD transition. A service sitting in steady HARD CRITICAL never refires its handler. All three attempts landed inside the worst eight minutes of the incident; once they were lost, the automation had no further opportunity.

##### How was this delivery dependency not identified when the automation was built?

The automation was designed and tested (2026-07-03/04) against a node whose NRPE was responsive — the freeze degrades the apiserver, not NRPE itself, and the trigger script deliberately returns instantly via `systemd-run` to avoid timeouts. The failure mode — NRPE *saturation* by sibling checks that all hit their max runtime simultaneously against a frozen apiserver — only manifests during a real freeze, and the 2026-07-04 freezes were remediated successfully before saturation set in. The gap: the remediation trigger depends on network delivery through the exact component the incident degrades, with no retry and no node-local fallback. Fix tracked as [homelabia#134](https://github.com/pgmac-net/homelabia/issues/134) (node-local systemd-timer dead-man switch).

---

#### Chain 3: arc-runner PVCs permanently unschedulable — Empty nodeAffinity PVs

##### How did the two runner pods stay Pending after the scheduler recovered?

Their PVCs were Bound to PVs whose `nodeAffinity` required `kubernetes.io/hostname In [""]` — an empty string matches no node, so the scheduler reported `0/3 nodes ... didn't match PersistentVolume's node affinity` forever.

##### How were PVs created with an empty hostname?

The hostpath provisioner (running on k8s01, whose apiserver was healthy) provisioned the PVs *during* the freeze. Its node-selection input — derived from the helper pod's scheduling outcome — was empty because the helper pods never scheduled, and the provisioner recorded the empty value into the PV's nodeAffinity instead of failing the provision cycle.

##### How was the bad value not correctable in place?

PV `nodeAffinity` is immutable after creation (apiserver validation), so the only fix is recycling: delete the claimant (the idle EphemeralRunner CRs), let ARC recreate runner + PVC, and let the now-healthy provisioner produce correct PVs. This worked in ~80 seconds.

##### How was this failure mode unknown?

Upstream microk8s hostpath-provisioner bug — provisioning proceeds with empty placement data rather than erroring. Not previously observed here because it requires provisioning to occur while the scheduler is blind. Recorded in the watch-cache runbook's post-recovery checks; upstream report tracked as an action item.

---

#### Chain 4: 10.6G of orphaned provisioner directories — Cleanup Helpers Fail During Incidents

##### How did orphaned directories accumulate on k8s02/k8s03?

The hostpath provisioner deletes each PV's backing directory via a helper pod at PV deletion. Any PV deleted during a control-plane incident (this one, and every prior freeze/stall) leaves its directory behind when the helper never runs.

##### How did this go unnoticed until now?

No check compared on-disk directories against live PVs; the only signal was generic node disk usage, which alerted (k8s02 at 78% image-fs, kubelet GC freeing 0 bytes) long after ~10.6G had accumulated — including 4.9G from the Lens metrics stack removed months ago.

##### How was it not prevented?

Missing monitoring capability — closed same-day by the `microk8s-hostpath-orphans` NRPE check (hourly, PV-diff with 60min grace) and an orphan-reclaim pass in `k8s-disk-clean.yml` ([homelabia#135](https://github.com/pgmac-net/homelabia/issues/135), completed).

---

## Impact

### Services Affected

| Service | Impact | Duration |
| --------- | ----------------- | ---------- |
| Pod scheduling (cluster-wide) | Zero new pods scheduled; 138 accumulated Pending | ~5h 17m |
| CronJobs (renovate, heartbeat, gnutemps, hourly-weather) | Missed all windows in the outage; one renovate job pod Errored during recovery | ~5h 17m |
| GitHub Actions self-hosted runners (ARC) | No runner pods schedulable; CI jobs queued | ~5h 33m (incl. PV recycling) |
| hostpath-provisioner | Helper-pod retry loop; 136 junk pods; 2 PVs provisioned broken | ~5h 30m |
| k8s01/k8s02 image filesystems | Kubelet GC failing (72–78% used), aggravated by helper churn | pre-existing, resolved same-day |

### Duration

- **Total incident window:** ~5h 19m (02:03 → 07:22 AEST)
- **Undetected-by-human window:** ~5h 11m (detection was automated at 02:07; no human paged)
- **Active hands-on recovery:** ~8 min for the freeze itself; ~25 min including PV collateral
- **Expected recovery time (had auto-remediation delivered):** ~5 min from HARD CRITICAL

### Scope

- All three nodes affected as consumers of scheduling; freeze itself confined to k8s03's apiserver
- Existing running workloads unaffected throughout; no data loss
- No user-visible service outage (all Deployments stayed at replica count; only new/replacement pods blocked)

---

## Resolution Steps Taken

### Phase 1: Diagnosis

1. Nagios triage: dqlite-scheduler WARNING x3 with `Pending pods: 138`, `microk8s-scheduler-stall` CRITICAL (`0 scheduler events`), `microk8s-pending-pods` CRITICAL, `microk8s-watch-cache` socket-timeout CRITICAL on k8s03.
2. Confirmed control-plane liveness vs progress: leases renewing on k8s03, KCM creating jobs, but newest started pod cluster-wide was 5h old; Pending helper pods had **no status conditions and no events** — scheduler blind, not slow.
3. Checked auto-remediation audit trail first (per runbook): `journalctl -u watch-cache-remediate` on k8s03 empty; nagios.log showed all three event-handler firings — delivery failure, not detection failure.
4. RV=0 test per runbook: canary pod visible in quorum reads everywhere, absent from k8s03's `resourceVersion=0` read → k8s03 watch cache frozen, k8s01/k8s02 healthy.

### Phase 2: Freeze Recovery (runbook manual procedure)

1. `kubectl cordon k8s03`
2. `ssh k8s03 sudo systemctl restart snap.microk8s.daemon-k8s-dqlite` → active, zero `database is locked` after 60s
3. `ssh k8s03 sudo systemctl restart snap.microk8s.daemon-kubelite` → node Ready
4. Canary verification before uncordon: node-pinned canary Succeeded **and** present in k8s03's RV=0 cache read; `kubectl wait` returned a false NotFound (stale-read gotcha documented in the runbook) — verified via quorum read instead
5. `kubectl uncordon k8s03`; backlog drained 138 → 2 Pending within ~4 minutes

### Phase 3: Collateral Cleanup

1. Deleted 78 Completed hostpath helper pods
2. Diagnosed remaining 2 Pending runner pods: PV `nodeAffinity` = `kubernetes.io/hostname In [""]`; patch impossible (immutable) → deleted idle EphemeralRunner CRs `self-hosted-v8tkc-runner-{lm789,r4nnc}`; ARC replacements Running with correct PVs in ~80s
3. Verified remediation delivery path post-recovery: manual `check_nrpe -c event_watch_cache_remediate` from the nagios4 container → unit started, self-detected healthy cache, exited `FALSE ALARM ... no action taken`
4. Same-day follow-up (homelabia#135): shipped `check_hostpath_orphans.sh` + orphan pass in `k8s-disk-clean.yml`; reclaimed ~10.4G (k8s02 65%→54%, k8s03 61%→59%)

---

## Verification

```bash
# All three watch caches reflect a fresh write (RV=0 test)
kubectl --context pvek8s run cache-canary -n default --image=busybox:1.36 --restart=Never --command -- true
for n in k8s01 k8s02 k8s03; do
  ssh $n "sudo /snap/bin/microk8s kubectl get --raw \
    '/api/v1/namespaces/default/pods?resourceVersion=0' | grep -c cache-canary"
done
# → 1 / 1 / 1

# Scheduler actually scheduling (unpinned canary needs the scheduler)
kubectl --context pvek8s get pod -n default cache-canary -o jsonpath='{.status.phase}'
# → Succeeded

# No Pending backlog; newest pod is recent
kubectl --context pvek8s get pods -A --field-selector status.phase=Pending --no-headers | wc -l
# → 0
kubectl --context pvek8s get pods -A --sort-by=.metadata.creationTimestamp --no-headers | tail -1
# → a pod created within the last few minutes

# Runner PVs carry a real node in their affinity
kubectl --context pvek8s get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}{"\n"}{end}'
# → every hostpath PV shows k8s01/k8s02/k8s03, never ""

# Nagios board green
# microk8s-watch-cache, scheduler-stall, pending-pods, dqlite-scheduler all OK
```

---

## Preventive Measures

### Immediate Actions Required

1. **Node-local dead-man switch for watch-cache remediation** (High)
    - Chain 2 root cause: the remediation trigger depends on nagios→NRPE delivery through the saturation the incident itself causes, with only three no-retry attempts. A systemd timer on each node running the RV=0 self-test every 5 minutes and invoking the (already mutex-guarded, false-alarm-safe) remediation script directly removes the delivery dependency; nagios remains the alerting/audit layer.
    - GitHub: [homelabia#134](https://github.com/pgmac-net/homelabia/issues/134)

2. **Raise nagios-side `check_nrpe` timeout for `microk8s-watch-cache` to ≥45s** (Medium)
    - Chain 2 contributing factor: the 15s socket timeout vs the check's 30–40s worst-case runtime meant nagios showed `Socket timeout` instead of the check's real CRITICAL output (and perfdata) for the whole incident, obscuring diagnosis.
    - GitHub: tracked within [homelabia#134](https://github.com/pgmac-net/homelabia/issues/134)

### Longer-Term Improvements

3. **Orphaned hostpath directory detection and cleanup** (High — **completed 2026-07-09**)
    - Chain 4: hourly `microk8s-hostpath-orphans` NRPE check (PV-diff, 60min grace, UNKNOWN on missing/empty PV list) plus guarded orphan-reclaim pass in `k8s-disk-clean.yml`; ~10.4G reclaimed on deployment.
    - GitHub: [homelabia#135](https://github.com/pgmac-net/homelabia/issues/135)

4. **Report empty-nodeAffinity PV provisioning upstream** (Low)
    - Chain 3: the microk8s hostpath provisioner writes an empty hostname into immutable PV nodeAffinity when provisioning proceeds while its helper pods cannot schedule; it should fail the cycle instead. Recycle procedure documented in the watch-cache runbook post-recovery checks.
    - GitHub: [homelabia#136](https://github.com/pgmac-net/homelabia/issues/136)

---

## Lessons Learned

### What Went Well

- Detection was fast and specific: the purpose-built `microk8s-watch-cache` check went CRITICAL 4 minutes after onset — the monitoring investment from PGM-241 works.
- The runbook manual procedure worked exactly as written: RV=0 diagnosis → cordon → dqlite → kubelite → canary-before-uncordon took ~8 minutes hands-on.
- The runbook's stale-read gotcha note prevented a wrong turn when `kubectl wait` falsely reported the canary NotFound.
- Checking the automation's audit trail (`journalctl -u watch-cache-remediate`) *before* manual intervention, as the runbook instructs, immediately reframed the incident from "remediation missing" to "delivery failed" — which is the actionable finding.
- The remediation script's own safety design (false-alarm detection, transient-unit mutex) meant post-recovery delivery testing was risk-free.

### What Didn't Go Well

- Five hours of cluster-wide scheduling outage for a failure mode with working detection and a working remediation script — the entire gap was the delivery path between them.
- Nobody was paged: Slack notifications went out but a 2am HARD CRITICAL relies entirely on the automation the incident had already disabled.
- The `Socket timeout after 15 seconds` check output masked the real check result for the whole incident; the timeout mismatch was a known-but-unfixed cosmetic issue that turned out to matter.
- The provisioner's helper-pod pattern amplified the incident (136 junk pods, PVs provisioned with garbage placement) — a controller retry loop with no backoff cap and no validation of its own inputs.

### Surprise Findings

- Nagios event handlers fire only on state transitions (SOFT 1/2, SOFT→HARD): steady-state HARD CRITICAL never refires. Any event-handler-based remediation gets a hard maximum of three delivery attempts per incident.
- NRPE on the frozen node stayed *up* but effectively lost one-shot commands: scheduled checks kept executing (and timing out nagios-side) while the handler's calls vanished — saturation, not death.
- The hostpath provisioner will happily create an immutable PV with `hostname In [""]` — provisioning during scheduler blindness produces permanently broken volumes rather than errors.
- A pod invisible to the scheduler accumulates *nothing*: no conditions, no events. "Pending with empty describe" is itself a high-signal freeze indicator.

---

## Action Items

| # | Action | Priority | GitHub |
| --- | -------- | -------- | -------- |
| 1 | Node-local dead-man switch for watch-cache remediation (systemd timer + RV=0 self-test) | High | [homelabia#134](https://github.com/pgmac-net/homelabia/issues/134) |
| 2 | Raise nagios-side check_nrpe timeout for microk8s-watch-cache to ≥45s | Medium | [homelabia#134](https://github.com/pgmac-net/homelabia/issues/134) |
| 3 | Orphaned hostpath dir detection + cleanup (check + disk-clean pass) | High | [homelabia#135](https://github.com/pgmac-net/homelabia/issues/135) ✅ done |
| 4 | Report empty-nodeAffinity PV provisioning bug upstream (canonical/microk8s) | Low | [homelabia#136](https://github.com/pgmac-net/homelabia/issues/136) |
| 5 | Update watch-cache runbook: delivery-gap triage + empty-PV post-recovery check | High | ✅ done (this PR) |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03)
- **Kubernetes version:** v1.35.0 (snap rev 8612)
- **Datastore:** dqlite via kine, 14M post-vacuum (2026-07-04)
- **Remediation stack:** nagios4 container on macro; `event_watch_cache_remediate` → NRPE → `systemd-run` → `remediate_watch_cache.sh`

### Key Error Signatures

```
# kine during the write burst (k8s03)
error while range on /registry/leases/kube-system/kube-scheduler : query (try: 0): context deadline exceeded
error in txn: update transaction failed for key ...: exec (try: 5): context canceled

# dqlite retry exhaustion (k8s01/k8s02)
error in txn: update transaction failed for key /registry/leases/kube-system/microk8s.io-hostpath: exec (try: 500): database is locked

# The check that detected the freeze, degraded by NRPE saturation
CHECK_NRPE STATE CRITICAL: Socket timeout after 15 seconds.

# Scheduler-invisible pods (the freeze signature)
#   - pod has NO status.conditions and NO events
# Broken PV from freeze-era provisioning
nodeAffinity: {"required":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"In","values":[""]}]}]}}
```

### Remediation Delivery Audit (distinguish "never fired" from "fired but lost")

```bash
# Nagios side — did the event handler fire?
ssh macro 'docker exec nagios4 grep -a "EVENT HANDLER" /opt/nagios/var/nagios.log | tail'
# → [ts] SERVICE EVENT HANDLER: k8s03;microk8s-watch-cache;CRITICAL;HARD;3;event_watch_cache_remediate

# Node side — did the remediation unit run?
ssh k8s03 'sudo journalctl -u watch-cache-remediate --since "-6 hours" --no-pager'
# → empty = delivery failed; go straight to the manual runbook procedure

# NRPE side — what actually executed in the window?
ssh k8s03 'sudo journalctl -u nagios-nrpe-server --since "<window>" --no-pager -o cat | grep COMMAND'
# → scheduled checks only, no event_watch_cache_remediate.sh = handler calls lost
```

### Empty-nodeAffinity PV Recovery

```bash
# Identify
kubectl --context pvek8s get pv <pv> -o jsonpath='{.spec.nodeAffinity}'
# → values":[""]  ← broken; PV nodeAffinity is immutable, do not try to patch

# Recycle the claimant (ephemeral workloads)
kubectl --context pvek8s -n arc-runners delete ephemeralrunner <runner>
# ARC recreates runner + PVC; healthy provisioner produces a correct PV in ~80s
```

---

## References

- GitHub: [homelabia#134](https://github.com/pgmac-net/homelabia/issues/134) — watch-cache auto-remediation delivery gap / dead-man switch
- GitHub: [homelabia#135](https://github.com/pgmac-net/homelabia/issues/135) — orphaned hostpath dirs (completed)
- GitHub: [homelabia#136](https://github.com/pgmac-net/homelabia/issues/136) — upstream report: empty-nodeAffinity PV provisioning
- Runbook: [Control-Plane Watch-Cache Freeze](../runbooks/control-plane-watch-cache-freeze.md) — updated by this PIR
- Runbook: [dqlite Write Contention](../runbooks/dqlite-write-contention.md)
- Related incident: [k8s02 Watch-Cache Freeze — dqlite Leadership Disruption](2026-06-24-k8s02-watch-cache-freeze-dqlite-leadership-disruption.md)
- Related incident: [pvek8s dqlite WAL Lock Storm — Jiva Controller Endpoint Deadlock](2026-06-28-dqlite-lock-storm-jiva-endpoint-deadlock.md)

---

## Reviewers

- @pgmac
