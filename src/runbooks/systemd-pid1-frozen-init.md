---
title: "systemd PID 1 segfault — frozen init"
tags:
  - runbook
  - systemd
  - microk8s
  - kubelite
  - k8s01
  - k8s02
  - k8s03
---

# systemd PID 1 Segfault — Frozen Init Recovery

**Service:** systemd (PID 1) on pvek8s nodes
**First observed:** 2026-09-02
**PIR:** [pvek8s Total Control Plane Loss — systemd +esm4 PID 1 Segfault](../incidents/2026-09-02-systemd-esm4-pid1-segfault-control-plane-loss.md)

---

## Symptom

A node looks alive — it pings, SSH eventually connects — but nothing on it can be started, restarted or supervised. Typical presentation:

- SSH login takes 50–250s instead of 2–4s (`pam_systemd` blocking on a dead bus)
- `systemctl` commands hang ~25s and then fail:
  ```
  Failed to get properties: Failed to activate service 'org.freedesktop.systemd1': timed out (service_start_timeout=25000ms)
  ```
- Nagios reports many services CRITICAL that are in fact running normally, and some checks claim `MicroK8s not installed?`
- Services that exit are never restarted — most damagingly `kubelite`, which self-terminates on `Leaderelection lost` and takes the apiserver, kubelet, scheduler and controller-manager with it
- All systemd timers are dead, including the watch-cache watchdog and jiva mounts auto-remediation

> **This is terminal.** `Freezing execution` means systemd caught a fatal signal and entered a permanent freeze loop. `systemctl daemon-reexec` and `kill -TERM 1` both require a live manager loop, so neither works. The only exit is a reboot.

---

## Root Cause

systemd caught `SIGSEGV`, dumped core, and froze. PID 1 remains alive as a process (`State: S (sleeping)`, one thread) but no longer owns its D-Bus name, so every `systemctl` call fails at bus activation.

On 2026-09-02/03 the trigger was `systemd 245.4-4ubuntu3.24+esm4` on Ubuntu 20.04 ESM. The package `postinst` runs `daemon-reexec`, placing the new binary into PID 1; all three nodes crashed 9–33h later. Any defect in a systemd package that re-execs PID 1 can produce this.

---

## Detection

```bash
# The definitive check — does PID 1 own the bus name?
ssh $NODE 'busctl --system list | grep systemd1'
# HEALTHY:  org.freedesktop.systemd1  1  systemd  root  :1.1  init.scope
# FROZEN:   org.freedesktop.systemd1  -  -        -     (activatable)

# Confirm the crash in the journal
ssh $NODE 'sudo journalctl -b --no-pager | grep -E "Caught <SEGV>|Freezing execution"'
# → systemd[1]: Caught <SEGV>, dumped core as pid NNNNNNN.
# → systemd[1]: Freezing execution.

# Core dump left behind
ssh $NODE 'ls -la /var/crash/_usr_lib_systemd_systemd.0.crash'

# Confirm systemctl is unreachable (expect ~25s then failure)
ssh $NODE 'time systemctl is-system-running'
```

Check **all** nodes — this failure arrives fleet-wide when the fleet is patched together.

---

## Recovery

> **Order matters.** Before rebooting anything, determine which nodes still serve an apiserver and reboot those **last**. The standing order (k8s02 → k8s03 → k8s01) assumes a healthy cluster and must be re-derived here.

### Step 1 — Establish who still has a control plane

```bash
kubectl --context pvek8s get nodes
kubectl --context pvek8s get endpoints -n default kubernetes
# → the ENDPOINTS list is the set of nodes still serving 16443

for h in k8s01 k8s02 k8s03; do
  echo -n "$h: "; ssh $h 'ss -lntp 2>/dev/null | grep -c ":16443"'
done
```

Reboot nodes with **no** apiserver first. Reboot a node that is still serving 16443 only when another node has been confirmed healthy and serving.

### Step 2 — Preserve the core dump before rebooting

```bash
ssh $NODE 'sudo cat /var/crash/_usr_lib_systemd_systemd.0.crash' > ${NODE}_systemd.0.crash
ls -la ${NODE}_systemd.0.crash    # size must match the remote file
```

This is the evidence for an upstream bug report — capture it from every affected node.

### Step 3 — Check for stuck mounts (hang risk on shutdown)

```bash
ssh $NODE 'grep -c "jiva.csi.openebs.io" /proc/mounts; sudo iscsiadm -m session 2>&1 | head'
kubectl --context pvek8s get pods -A --no-headers | awk '$4=="Terminating"' | wc -l
```

Stuck Jiva/iSCSI bind mounts or stuck-Terminating pods can hang the node on shutdown. If present, plan for a possible hard power cycle.

### Step 4 — Confirm sysrq permits what we need

```bash
ssh $NODE 'cat /proc/sys/kernel/sysrq'
# → 176 = 128 (reboot) + 32 (remount-ro) + 16 (sync) — all three already enabled, no change needed
# If it is 0 or lacks those bits:  echo 1 | sudo tee /proc/sys/kernel/sysrq
```

### Step 5 — sysrq reboot (one node at a time)

`reboot`, `systemctl reboot` and Ansible's `reboot` module all route through PID 1 and will hang. Use sysrq:

```bash
# Sync and remount read-only
ssh $NODE 'sudo sync; echo s | sudo tee /proc/sysrq-trigger; echo u | sudo tee /proc/sysrq-trigger'
ssh $NODE 'sudo dmesg | grep -iE "sysrq|emergency" | tail -3'
# → sysrq: Emergency Sync / Emergency Sync complete / sysrq: Emergency Remount R/O
```

**Verify the remount completed before triggering the reboot** — it is asynchronous, and SSH logins may begin timing out once the root filesystem is read-only, so issue the verification and the reboot in the same login:

```bash
ssh $NODE 'findmnt -no OPTIONS /; echo b | sudo tee /proc/sysrq-trigger'
# → ro,relatime          <-- must show ro BEFORE the b takes effect
# → client_loop: send disconnect: Broken pipe   (expected)
```

### Step 6 — Wait for the node and verify it came back healthy

```bash
until ping -c1 -W2 $NODE >/dev/null 2>&1; do sleep 5; done; echo "$NODE up"

ssh $NODE 'busctl --system list | grep systemd1;
           systemctl is-system-running;
           systemctl is-active snap.microk8s.daemon-kubelite snap.microk8s.daemon-k8s-dqlite snap.microk8s.daemon-containerd;
           ss -lntp | grep 16443;
           uname -r;
           sudo journalctl -b --no-pager | grep -cE "Caught <SEGV>|Freezing execution"'
```

Expected: systemd1 owned by PID 1; `degraded` or `running`; three `active`; 16443 listening; `0` SEGV since boot. A single failed `snap.canonical-livepatch.canonical-livepatchd.service` is cosmetic and normal here.

Repeat Steps 2–6 for the next node. **Never reboot two nodes at once** — dqlite needs 2 of 3 voters.

### Step 7 — Prevent an immediate recurrence

The rebooted node is running the *same* systemd binary that crashed, with a fresh PID 1 — the clock has restarted, not stopped. Hold the packages so no further `dist-upgrade` re-execs PID 1 unexpectedly:

```bash
ssh $NODE 'sudo apt-mark hold systemd systemd-sysv libsystemd0 libpam-systemd libnss-systemd udev systemd-timesyncd'
```

Check whether a known-good prior version is available to downgrade to:

```bash
ssh $NODE 'apt-cache policy systemd'
```

---

## Post-Recovery Checks

Rebooting the nodes does **not** end the incident. Containers keep running under containerd while the kubelet is dead, so writes were in flight when the node went down:

1. **Stale Jiva `nodeID` labels** — see [jiva-csi-stale-node-attachment](jiva-csi-stale-node-attachment.md), *Failure Mode 2*. Restoring all nodes to `Ready` re-arms the cross-node guard.
2. **Filesystem integrity on every Jiva volume** — see [jiva-volume-ext4-corruption](jiva-volume-ext4-corruption.md). A volume can mount cleanly and still be flagged `clean with errors`.
3. **Applications that bootstrap from cluster state** — redis-ha style StatefulSets can deadlock permanently when all replicas are lost at once.

---

## Verification

```bash
# All nodes have a live init
for h in k8s01 k8s02 k8s03; do
  echo -n "$h: "; ssh $h 'busctl --system list | grep -q "org.freedesktop.systemd1.*[0-9]" && echo OK || echo FROZEN'
done
# → all OK

# Control plane fully restored
kubectl --context pvek8s get nodes
kubectl --context pvek8s get endpoints -n default kubernetes
# → all nodes Ready; all three IPs in the endpoints list

# SSH latency back to normal (the cheapest smoke test)
time ssh k8s01 true
# → ~2-4s, not 50-250s
```

---

## References

- PIR: [pvek8s Total Control Plane Loss — systemd +esm4 PID 1 Segfault](../incidents/2026-09-02-systemd-esm4-pid1-segfault-control-plane-loss.md)
- Related: [jiva-csi-stale-node-attachment.md](jiva-csi-stale-node-attachment.md) — the mount failures that follow a multi-node reboot
- Related: [jiva-volume-ext4-corruption.md](jiva-volume-ext4-corruption.md) — filesystem damage from the unclean shutdown
- Related: [pvek8s-outage-recovery.sh](pvek8s-outage-recovery.sh) — general cluster recovery helper
