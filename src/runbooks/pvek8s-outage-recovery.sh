#!/usr/bin/env bash
# =============================================================================
# pvek8s-outage-recovery.sh
# General post-outage cluster recovery for pvek8s (microk8s, 3-node HA)
#
# Derived from: recover-post-outage.sh (2026-05-28 incident)
# Stripped: hardcoded pod names, incident-specific IP checks, one-off fixes
# =============================================================================

set -uo pipefail

K="kubectl --context pvek8s"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
die()   { error "$*"; exit 1; }

preflight() {
    info "=== PRE-FLIGHT CHECKS ==="
    $K get nodes --no-headers 2>/dev/null || die "Cannot reach cluster. Check kubeconfig."
    for node in k8s01 k8s02 k8s03; do
        ssh -o ConnectTimeout=5 "$node" true 2>/dev/null || die "Cannot SSH to $node"
    done
    KCM_LEADER=$($K -n kube-system get lease kube-controller-manager \
        -o jsonpath='{.spec.holderIdentity}' 2>/dev/null | cut -d_ -f1 || echo "unknown")
    info "KCM lease holder: ${KCM_LEADER}"
    [[ "$KCM_LEADER" == "k8s02" ]] && warn "k8s02 is KCM leader — will NOT be restarted."
    DQLITE_LOCK=$(ssh k8s01 "sudo journalctl -u snap.microk8s.daemon-k8s-dqlite \
        --since '5 minutes ago' 2>/dev/null | grep -c 'database is locked'; exit 0" 2>/dev/null) || DQLITE_LOCK=0
    DQLITE_LOCK="${DQLITE_LOCK:-0}"
    [[ "$DQLITE_LOCK" -gt 5 ]] && die "dqlite lock contention active (${DQLITE_LOCK}/5min). Wait before proceeding."
    info "Pre-flight passed."
}

wait_dqlite_stable() {
    local node="$1"; local attempts=0
    info "Waiting for k8s-dqlite to stabilise on ${node}..."
    while true; do
        attempts=$((attempts + 1))
        [[ $attempts -gt 36 ]] && die "k8s-dqlite on ${node} did not stabilise after 3 min."
        LOCK_COUNT=$(ssh "$node" "sudo journalctl -u snap.microk8s.daemon-k8s-dqlite \
            --since '30 seconds ago' 2>/dev/null | grep -c 'database is locked'; exit 0" 2>/dev/null) || LOCK_COUNT=99
        LOCK_COUNT="${LOCK_COUNT:-99}"
        ACTIVE=$(ssh "$node" "sudo systemctl is-active snap.microk8s.daemon-k8s-dqlite.service 2>/dev/null" \
            || echo "inactive")
        if [[ "$ACTIVE" == "active" && "$LOCK_COUNT" -eq 0 ]]; then
            info "k8s-dqlite stable on ${node}."; break
        fi
        warn "  Attempt ${attempts}: active=${ACTIVE}, locks=${LOCK_COUNT}. Waiting 5s..."; sleep 5
    done
}

wait_node_ready() {
    local node="$1" timeout="${2:-300}"
    info "Waiting up to ${timeout}s for ${node} to be Ready..."
    $K wait node/"$node" --for=condition=Ready --timeout="${timeout}s" \
        || die "${node} not Ready within ${timeout}s"
    info "Node ${node} Ready."
}

wait_between_restarts() {
    info "=== STABILISATION WAIT (60s) ==="
    sleep 60
    for node in k8s01 k8s02 k8s03; do
        LOCKS=$(ssh "$node" "sudo journalctl -u snap.microk8s.daemon-k8s-dqlite \
            --since '60 seconds ago' 2>/dev/null | grep -c 'database is locked'; exit 0" 2>/dev/null) || LOCKS=0
        LOCKS="${LOCKS:-0}"
        [[ "$LOCKS" -gt 3 ]] && { warn "dqlite still active on ${node}: ${LOCKS} errors. Waiting +60s..."; sleep 60; }
    done
}

# Warn if jiva-ctrl pods are running on a node that is about to be restarted.
# Evicting jiva-ctrl kills the iSCSI target — workload pods on other nodes that
# have active sessions will hit error 1020 and may remount their filesystems ro.
check_jiva_ctrls_on_node() {
    local node="$1"
    local ctrls
    ctrls=$($K get pods -n openebs -o wide --no-headers 2>/dev/null | \
        awk -v n="$node" '/jiva.*ctrl/ && $7==n {print $1}')
    [[ -z "$ctrls" ]] && return 0
    warn "jiva-ctrl pods running on ${node}:"
    while IFS= read -r pod; do warn "  $pod"; done <<< "$ctrls"
    warn "Restarting ${node} will evict these iSCSI targets — workload pods may get read-only filesystems."
    warn "Check active sessions: for pod in \$($K get pods -n openebs -l app=openebs-jiva-csi-node -o name);"
    warn "  do echo \"=== \$pod ===\"; $K exec -n openebs \$pod -c jiva-csi-plugin -- iscsiadm -m session 2>/dev/null; done"
    if [[ "$yes_flag" == "false" ]]; then
        read -r -p "Continue anyway? [y/N] " C < /dev/tty
        [[ "$C" =~ ^[Yy]$ ]] || die "Aborted."
    fi
}

phase1_cordon_k8s03() {
    info ""; info "=== PHASE 1: CORDON k8s03 ==="
    $K cordon k8s03
    STATUS=$($K get node k8s03 --no-headers | awk '{print $2}')
    [[ "$STATUS" != *"SchedulingDisabled"* ]] && die "k8s03 cordon failed: ${STATUS}"
    info "k8s03 cordoned: ${STATUS}"
}

phase2_jiva_cleanup() {
    info ""; info "=== PHASE 2: JIVA CSI MOUNT CLEANUP ON k8s03 ==="
    JIVA_COUNT=$(ssh k8s03 "grep -c 'jiva.csi.openebs.io' /proc/mounts" 2>/dev/null || echo 0)
    info "Jiva mounts on k8s03: ${JIVA_COUNT} (normal: ≤4)"
    [[ "$JIVA_COUNT" -le 4 ]] && { info "Mounts clean. Skipping."; return 0; }
    ssh k8s03 'sudo bash -s' << 'ENDSSH'
echo "Before: $(grep -c 'jiva.csi.openebs.io' /proc/mounts) jiva mounts"
while IFS= read -r PATH; do
    COUNT=$(grep -c "$PATH" /proc/mounts 2>/dev/null || echo 0)
    if [[ "$COUNT" -gt 1 ]]; then
        REMOVED=0
        while [ "$(grep -c "$PATH" /proc/mounts 2>/dev/null || echo 0)" -gt 1 ]; do
            umount "$PATH" 2>/dev/null && REMOVED=$((REMOVED + 1))
        done
        echo "  Cleaned $PATH: removed ${REMOVED}"
    fi
done < <(grep 'jiva.csi.openebs.io' /proc/mounts | awk '{print $2}' | sort -u)
echo "After: $(grep -c 'jiva.csi.openebs.io' /proc/mounts) jiva mounts"
ENDSSH
    JIVA_AFTER=$(ssh k8s03 "grep -c 'jiva.csi.openebs.io' /proc/mounts" 2>/dev/null || echo 0)
    info "Jiva mounts after cleanup: ${JIVA_AFTER}"
}

phase3_kill_shims() {
    info ""; info "=== PHASE 3: KILL ORPHANED SHIMS ON k8s03 ==="
    SHIM_COUNT=$(ssh k8s03 "pgrep -c containerd-shim-runc-v2 2>/dev/null || echo 0")
    TASK_COUNT=$(ssh k8s03 "sudo /snap/microk8s/current/bin/ctr \
        --address /var/snap/microk8s/common/run/containerd.sock \
        -n k8s.io tasks list 2>/dev/null | awk 'NR>1{print \$1}' | wc -l" 2>/dev/null || echo 0)
    info "shims=${SHIM_COUNT}, running tasks=${TASK_COUNT}"
    if [[ "$SHIM_COUNT" -gt "$((TASK_COUNT + 2))" ]]; then
        ssh k8s03 'bash -s' << 'ENDSSH'
RUNNING=$(sudo /snap/microk8s/current/bin/ctr \
    --address /var/snap/microk8s/common/run/containerd.sock \
    -n k8s.io tasks list 2>/dev/null | awk 'NR>1 {print $1}')
KILLED=0
for PID in $(pgrep -f containerd-shim 2>/dev/null); do
    CID=$(sudo cat /proc/$PID/cmdline 2>/dev/null | tr '\0' '\n' | grep -A1 '^-id$' | tail -1)
    if [ -n "$CID" ] && ! echo "$RUNNING" | grep -q "^${CID}$"; then
        sudo kill -9 $PID 2>/dev/null && KILLED=$((KILLED + 1))
    fi
done
echo "Killed ${KILLED} orphaned shims"
ENDSSH
    fi
    SHIM_AFTER=$(ssh k8s03 "pgrep -c containerd-shim-runc-v2; exit 0" 2>/dev/null) || SHIM_AFTER=0
    SHIM_AFTER="${SHIM_AFTER:-0}"
    info "Shims after kill: ${SHIM_AFTER}"
}

phase4_restart_k8s03() {
    info ""; info "=== PHASE 4: RESTART k8s-dqlite + kubelite ON k8s03 ==="
    STATUS=$($K get node k8s03 --no-headers | awk '{print $2}')
    [[ "$STATUS" != *"SchedulingDisabled"* ]] && die "k8s03 is NOT cordoned. Aborting."
    check_jiva_ctrls_on_node k8s03
    info "Restarting k8s-dqlite on k8s03..."
    ssh k8s03 "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
    wait_dqlite_stable k8s03
    info "Restarting kubelite on k8s03..."
    ssh k8s03 "sudo systemctl restart snap.microk8s.daemon-kubelite.service"
    wait_node_ready k8s03 300
    sleep 15
    LOG_LINES=$(ssh k8s03 "sudo journalctl -u snap.microk8s.daemon-kubelite \
        --since '30 seconds ago' 2>/dev/null | grep -v '^--' | wc -l") || LOG_LINES=0
    LOG_LINES="${LOG_LINES:-0}"
    [[ "$LOG_LINES" -lt 3 ]] && die "kubelite on k8s03 appears stalled (${LOG_LINES} log lines). Investigate."
    info "k8s03 healthy: ${LOG_LINES} log lines."
}

phase5_force_delete_stuck_pods() {
    info ""; info "=== PHASE 5: FORCE-DELETE TERMINATING/UNKNOWN PODS ==="
    local count=0
    while IFS= read -r line; do
        local ns pod state
        ns=$(awk '{print $1}' <<< "$line")
        pod=$(awk '{print $2}' <<< "$line")
        state=$(awk '{print $4}' <<< "$line")
        warn "  Force-deleting ${ns}/${pod} (${state})"
        $K delete pod -n "$ns" "$pod" --grace-period=0 --force 2>/dev/null || true
        count=$((count + 1))
    done < <($K get pods -A --no-headers 2>/dev/null | awk '$4=="Terminating"||$4=="Unknown"')
    [[ "$count" -eq 0 ]] && info "No stuck pods found." || info "Force-deleted ${count} stuck pods."
}

phase6_restart_k8s01() {
    info ""; info "=== PHASE 6: RESTART k8s01 kubelite (HIGHEST IMPACT) ==="
    check_jiva_ctrls_on_node k8s01
    info "Cleaning stale completed jobs first..."
    $K delete job --all-namespaces --field-selector=status.conditions[0].type=Complete 2>/dev/null || true
    info "Cordoning k8s01..."
    $K cordon k8s01
    info "Restarting k8s-dqlite on k8s01..."
    ssh k8s01 "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
    wait_dqlite_stable k8s01
    info "Restarting kubelite on k8s01..."
    ssh k8s01 "sudo systemctl restart snap.microk8s.daemon-kubelite.service"
    wait_node_ready k8s01 300
    info "Uncordoning k8s01..."
    $K uncordon k8s01
    info "Waiting 30s for RS controller to process deployments..."
    sleep 30
}

phase7_fix_coredns() {
    info ""; info "=== PHASE 7: VERIFY AND FIX CoreDNS ENDPOINTS ==="
    local coredns_running=false
    for i in $(seq 1 24); do
        COUNT=$($K -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c Running; true)
        if [[ "$COUNT" -gt 0 ]]; then coredns_running=true; info "CoreDNS Running (${COUNT} pods)."; break; fi
        warn "  Attempt ${i}/24: CoreDNS not Running. Waiting 5s..."; sleep 5
    done
    [[ "$coredns_running" == "false" ]] && die "CoreDNS pods never started. Investigate."
    ENDPOINT_ADDR=$($K -n kube-system get endpoints kube-dns \
        -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
    if [[ -z "$ENDPOINT_ADDR" ]]; then
        warn "kube-dns endpoint has no addresses. Force-deleting to trigger recreation..."
        $K -n kube-system delete endpoints kube-dns --grace-period=0 --force 2>/dev/null || true
        sleep 10
    fi
    NEW_IPS=$($K -n kube-system get endpoints kube-dns \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
    info "kube-dns endpoint IPs: ${NEW_IPS:-<none>}"
    [[ -z "$NEW_IPS" ]] && warn "kube-dns endpoints still empty — DNS may not be working."
    info "Testing DNS resolution..."
    $K run dns-test --image=busybox:1.36 --rm -i --restart=Never --command -- \
        sh -c "nslookup kubernetes.default.svc.cluster.local" --timeout=30s 2>/dev/null \
        && info "DNS: OK" || warn "DNS test failed — may still be recovering."
}

phase8_reset_openebs() {
    info ""; info "=== PHASE 8: RESET OpenEBS REPLICA BACKOFF ==="
    local count=0
    while IFS= read -r pod; do
        info "  Deleting openebs/${pod}"
        $K -n openebs delete pod "$pod" --grace-period=0 --force 2>/dev/null || true
        count=$((count + 1))
    done < <($K -n openebs get pods --no-headers 2>/dev/null | \
        awk '$4=="CrashLoopBackOff"||$4=="Error"{print $1}')
    [[ "$count" -eq 0 ]] && info "No OpenEBS pods in backoff." || info "Reset ${count} OpenEBS pods."
}

phase9_uncordon_k8s03() {
    info ""; info "=== PHASE 9: VERIFY k8s03 AND UNCORDON ==="
    REJECT_COUNT=$(ssh k8s03 "sudo iptables -L -n 2>/dev/null | grep -c REJECT; exit 0" 2>/dev/null) \
        || REJECT_COUNT=999
    REJECT_COUNT="${REJECT_COUNT:-999}"
    info "k8s03 iptables REJECT rules: ${REJECT_COUNT}"
    [[ "$REJECT_COUNT" -gt 10 ]] && { warn "High REJECT count. Waiting 30s for kube-proxy resync..."; sleep 30; }
    SHIM_COUNT=$(ssh k8s03 "pgrep -c containerd-shim-runc-v2; exit 0" 2>/dev/null) || SHIM_COUNT=0
    SHIM_COUNT="${SHIM_COUNT:-0}"
    info "k8s03 remaining shims: ${SHIM_COUNT}"
    COREDNS_RUNNING=$($K -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null \
        | grep -c Running; true)
    [[ "$COREDNS_RUNNING" -eq 0 ]] && die "CoreDNS not Running. Do not uncordon k8s03 until DNS is healthy."
    info "CoreDNS Running: ${COREDNS_RUNNING} pods. Uncordoning k8s03..."
    $K uncordon k8s03
    $K get nodes
}

phase10_final_verify() {
    info ""; info "=== PHASE 10: FINAL VERIFICATION ==="
    info "--- Nodes:"; $K get nodes
    info "--- Non-Running pods:"
    $K get pods -A --no-headers 2>/dev/null | \
        awk '$4!="Running"&&$4!="Completed"&&$4!="Succeeded"' || info "  All pods Running/Completed."
    info "--- kube-dns Endpoints:"; $K -n kube-system get endpoints kube-dns
    info "--- ArgoCD app health:"
    $K -n argocd get applications --no-headers 2>/dev/null | \
        awk '$3!="Healthy"||$4!="Synced"{print $1,"health="$3,"sync="$4}' \
        || info "  All apps Healthy/Synced."
    info ""; info "=== RECOVERY COMPLETE ==="
}

main() {
    local yes_flag=false
    [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && yes_flag=true

    info "pvek8s post-outage recovery starting at $(date)"
    preflight
    echo ""
    echo "This script will execute 10 phases to recover the cluster."
    echo "k8s02 (dqlite Raft leader) will NOT be restarted."

    if [[ "$yes_flag" == "false" ]]; then
        read -r -p "Proceed? [y/N] " CONFIRM < /dev/tty
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted."
    else
        info "Auto-confirmed via -y flag."
    fi

    phase1_cordon_k8s03
    phase2_jiva_cleanup
    phase3_kill_shims
    phase4_restart_k8s03
    wait_between_restarts
    phase5_force_delete_stuck_pods
    phase6_restart_k8s01
    phase7_fix_coredns
    sleep 30
    phase8_reset_openebs
    phase9_uncordon_k8s03
    phase10_final_verify
}

main "$@"
