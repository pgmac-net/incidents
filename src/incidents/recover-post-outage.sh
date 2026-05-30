#!/usr/bin/env bash
# =============================================================================
# post-outage-recovery.sh
# Post-power-outage pvek8s cluster recovery
# Investigation: .incident-response/05-investigation.md
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
    DQLITE_LOCK=$(ssh k8s01 "sudo journalctl -u snap.microk8s.daemon-k8s-dqlite --since '5 minutes ago' 2>/dev/null | grep -c 'database is locked'; exit 0" 2>/dev/null) || DQLITE_LOCK=0
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
        LOCK_COUNT=$(ssh "$node" "sudo journalctl -u snap.microk8s.daemon-k8s-dqlite --since '30 seconds ago' 2>/dev/null | grep -c 'database is locked'; exit 0" 2>/dev/null) || LOCK_COUNT=99
        LOCK_COUNT="${LOCK_COUNT:-99}"
        ACTIVE=$(ssh "$node" "sudo systemctl is-active snap.microk8s.daemon-k8s-dqlite.service 2>/dev/null" || echo "inactive")
        if [[ "$ACTIVE" == "active" && "$LOCK_COUNT" -eq 0 ]]; then
            info "k8s-dqlite stable on ${node}."; break
        fi
        warn "  Attempt ${attempts}: active=${ACTIVE}, locks=${LOCK_COUNT}. Waiting 5s..."; sleep 5
    done
}

wait_node_ready() {
    local node="$1" timeout="${2:-300}"
    info "Waiting up to ${timeout}s for ${node} to be Ready..."
    $K wait node/"$node" --for=condition=Ready --timeout="${timeout}s" || die "${node} not Ready within ${timeout}s"
    info "Node ${node} Ready."
}

wait_between_restarts() {
    info "=== STABILISATION WAIT (60s) ==="
    sleep 60
    for node in k8s01 k8s02 k8s03; do
        LOCKS=$(ssh "$node" "sudo journalctl -u snap.microk8s.daemon-k8s-dqlite --since '60 seconds ago' 2>/dev/null | grep -c 'database is locked'; exit 0" 2>/dev/null) || LOCKS=0
        LOCKS="${LOCKS:-0}"
        [[ "$LOCKS" -gt 3 ]] && { warn "dqlite still active on ${node}: ${LOCKS} errors. Waiting +60s..."; sleep 60; }
    done
}

check_jiva_ctrls_on_node() {
    local node="$1"
    local ctrls
    ctrls=$($K get pods -n openebs -o wide --no-headers 2>/dev/null | \
        awk -v n="$node" '/jiva.*ctrl/ && $7==n {print $1}')
    [[ -z "$ctrls" ]] && return 0
    warn "jiva-ctrl pods running on ${node}:"
    while IFS= read -r pod; do warn "  $pod"; done <<< "$ctrls"
    warn "Restarting ${node} will evict these iSCSI targets — workload pods on other nodes may get read-only filesystems."
    warn "Check active sessions first: for pod in \$($K get pods -n openebs -l app=openebs-jiva-csi-node -o name); do echo \"=== \$pod ===\"; $K exec -n openebs \$pod -c jiva-csi-plugin -- iscsiadm -m session 2>/dev/null; done"
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
    TASK_COUNT=$(ssh k8s03 "sudo /snap/microk8s/current/bin/ctr --address /var/snap/microk8s/common/run/containerd.sock -n k8s.io tasks list 2>/dev/null | awk 'NR>1{print \$1}' | wc -l" 2>/dev/null || echo 0)
    info "shims=${SHIM_COUNT}, running tasks=${TASK_COUNT}"
    if [[ "$SHIM_COUNT" -gt "$((TASK_COUNT + 2))" ]]; then
        ssh k8s03 'bash -s' << 'ENDSSH'
RUNNING=$(sudo /snap/microk8s/current/bin/ctr --address /var/snap/microk8s/common/run/containerd.sock -n k8s.io tasks list 2>/dev/null | awk 'NR>1 {print $1}')
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
    LOG_LINES=$(ssh k8s03 "sudo journalctl -u snap.microk8s.daemon-kubelite --since '30 seconds ago' 2>/dev/null | grep -v '^--' | wc -l") || LOG_LINES=0
    LOG_LINES="${LOG_LINES:-0}"
    [[ "$LOG_LINES" -lt 3 ]] && die "kubelite on k8s03 appears stalled (${LOG_LINES} log lines). Investigate."
    info "k8s03 healthy: ${LOG_LINES} log lines."
}

phase5_force_delete_pods() {
    info ""; info "=== PHASE 5: FORCE-DELETE TERMINATING/UNKNOWN PODS ==="
    declare -a PODS=(
        "arc-runners/buildkitd-74f857997d-cd6pk"
        "argocd/argocd-redis-ha-haproxy-8467cfb56-rlpqp"
        "argocd/argocd-redis-ha-haproxy-8467cfb56-wnvzn"
        "argocd/argocd-redis-ha-server-0"
        "argocd/argocd-redis-ha-server-2"
        "finance/budgeteer-68c64b6bb9-pnbpn"
        "kube-system/calico-kube-controllers-568b6d4dcd-g5vlk"
        "media/linkace-86c474c6c-rkslb"
        "media/sabnzbd-5cdb86df74-glf7l"
        "media/seerr-seerr-chart-0"
        "media/sonarr-68858bcbcf-d74zt"
        "media/hourly-weather-29664600-5w9r6"
        "media/hourly-weather-29665200-flnhg"
        "minecraft/survive-minecraft-5cf8f5cc-zpm5l"
        "netconnectors/cloudflare-tunnel-64594c5b75-mcjs4"
        "netconnectors/hass-home-assistant-0"
        "netconnectors/n8n-67779954cb-pddlz"
        "sec/trivy-server-0"
    )
    for entry in "${PODS[@]}"; do
        NS="${entry%%/*}"; POD="${entry##*/}"
        if $K get pod -n "$NS" "$POD" &>/dev/null; then
            $K delete pod -n "$NS" "$POD" --grace-period=0 --force 2>/dev/null && info "  Deleted: ${NS}/${POD}" || warn "  Delete failed: ${NS}/${POD}"
        else
            info "  Already gone: ${NS}/${POD}"
        fi
    done
    # Sweep any remaining
    $K get pods -A --no-headers 2>/dev/null | awk '$4=="Terminating"||$4=="Unknown"{print $1,$2}' | \
        while read NS POD; do
            warn "  Sweeping stray: ${NS}/${POD}"
            $K delete pod -n "$NS" "$POD" --grace-period=0 --force 2>/dev/null || true
        done
}

phase6_restart_k8s01() {
    info ""; info "=== PHASE 6: RESTART k8s01 kubelite (HIGHEST IMPACT) ==="
    check_jiva_ctrls_on_node k8s01
    info "Cleaning stale jobs first..."
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
    COREDNS_RUNNING=false
    for i in $(seq 1 24); do
        COUNT=$($K -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c Running; true)
        if [[ "$COUNT" -gt 0 ]]; then COREDNS_RUNNING=true; info "CoreDNS Running (${COUNT} pods)."; break; fi
        warn "  Attempt ${i}/24: CoreDNS not Running. Waiting 5s..."; sleep 5
    done
    ENDPOINT_IPS=$($K -n kube-system get endpoints kube-dns -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
    info "kube-dns endpoint IPs: ${ENDPOINT_IPS}"
    if echo "$ENDPOINT_IPS" | grep -q "10.1.73.108"; then
        warn "Dead IP 10.1.73.108 still present. Force-deleting Endpoints..."
        $K -n kube-system delete endpoints kube-dns --grace-period=0 --force 2>/dev/null || true
        sleep 10
        NEW_IPS=$($K -n kube-system get endpoints kube-dns -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
        info "Endpoints after recreation: ${NEW_IPS}"
    fi
    info "Testing DNS resolution..."
    $K run dns-test --image=busybox:1.36 --rm -i --restart=Never --command -- \
        sh -c "nslookup kubernetes.default.svc.cluster.local" --timeout=30s 2>/dev/null \
        && info "DNS: OK" || warn "DNS test failed — may still be recovering."
}

phase8_reset_openebs() {
    info ""; info "=== PHASE 8: RESET OpenEBS REPLICA BACKOFF ==="
    $K -n openebs get pods --no-headers 2>/dev/null | awk '$4=="CrashLoopBackOff"||$4=="Error"{print $1}' | \
        while read POD; do
            info "  Deleting openebs/${POD}"
            $K -n openebs delete pod "$POD" --grace-period=0 --force 2>/dev/null || true
        done
    for prefix in pvc-05e03b60 pvc-0bb83414 pvc-17e6e808 pvc-746b2837 pvc-a3a7e012 pvc-a634b9a3 pvc-d16dc542; do
        $K -n openebs get pods --no-headers 2>/dev/null | awk -v p="$prefix" '$1~p{print $1}' | \
            while read POD; do
                info "  Deleting targeted: openebs/${POD}"
                $K -n openebs delete pod "$POD" --grace-period=0 --force 2>/dev/null || true
            done
    done
}

phase9_n8n_fix() {
    info ""; info "=== PHASE 9: n8n FIX (requires git commit) ==="
    warn "n8n has N8N_PORT env collision (Kubernetes service env injection)."
    warn "ArgoCD selfHeal=true will revert any direct Deployment patch."
    warn ""
    warn "PERMANENT FIX: In pgk8s repo, add to n8n Application valuesObject:"
    warn "  main:"
    warn "    podSpec:"
    warn "      enableServiceLinks: false"
    warn ""
    warn "TEMPORARY (ArgoCD Application patch — will last until next app-of-apps sync):"
    info "kubectl --context pvek8s -n argocd patch application n8n --type=merge -p '"
    info '{"spec":{"source":{"helm":{"valuesObject":{"main":{"podSpec":{"enableServiceLinks":false}}}}}}}'
    info "'"
}

phase10_uncordon_k8s03() {
    info ""; info "=== PHASE 10: VERIFY k8s03 AND UNCORDON ==="
    REJECT_COUNT=$(ssh k8s03 "sudo iptables -L -n 2>/dev/null | grep -c REJECT; exit 0" 2>/dev/null) || REJECT_COUNT=999
    REJECT_COUNT="${REJECT_COUNT:-999}"
    info "k8s03 iptables REJECT rules: ${REJECT_COUNT}"
    [[ "$REJECT_COUNT" -gt 10 ]] && { warn "High REJECT count. Waiting 30s for kube-proxy resync..."; sleep 30; }
    SHIM_COUNT=$(ssh k8s03 "pgrep -c containerd-shim-runc-v2; exit 0" 2>/dev/null) || SHIM_COUNT=0
    SHIM_COUNT="${SHIM_COUNT:-0}"
    info "k8s03 remaining shims: ${SHIM_COUNT}"
    COREDNS_RUNNING=$($K -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c Running; true)
    [[ "$COREDNS_RUNNING" -eq 0 ]] && die "CoreDNS not Running. Do not uncordon k8s03 until DNS is healthy."
    info "CoreDNS Running: ${COREDNS_RUNNING} pods. Uncordoning k8s03..."
    $K uncordon k8s03
    $K get nodes
}

phase11_final_verify() {
    info ""; info "=== PHASE 11: FINAL VERIFICATION ==="
    info "--- Nodes:"; $K get nodes
    info "--- Non-Running pods:"
    $K get pods -A --no-headers 2>/dev/null | awk '$4!="Running"&&$4!="Completed"&&$4!="Succeeded"' || info "  All pods Running/Completed."
    info "--- kube-dns Endpoints:"; $K -n kube-system get endpoints kube-dns
    info "--- ArgoCD app health:"
    $K -n argocd get applications --no-headers 2>/dev/null | awk '$3!="Healthy"||$4!="Synced"{print $1,"health="$3,"sync="$4}' || info "  All apps Healthy/Synced."
    info ""; info "=== RECOVERY COMPLETE ==="
}

main() {
    local yes_flag=false
    [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && yes_flag=true

    info "pvek8s post-outage recovery starting at $(date)"
    preflight
    echo ""
    echo "This script will execute 11 phases to recover the cluster."
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
    phase5_force_delete_pods
    phase6_restart_k8s01
    phase7_fix_coredns
    sleep 30
    phase8_reset_openebs
    phase9_n8n_fix
    phase10_uncordon_k8s03
    phase11_final_verify
}

main "$@"
