---
tags:
  - runbook
  - microk8s
  - upgrade
  - endpointslice
  - calico
---

# k8s Upgrade Post-Upgrade Validation

**Service:** microk8s (pvek8s)
**First observed:** 2026-05-16
**PIR:** [microk8s 1.34 → 1.35 Upgrade](../incidents/2026-05-16-microk8s-1.35-upgrade-cgroup-v2-containerd-disk-pressure.md)
**Linear:** [PGM-193](https://linear.app/pgmac-net-au/issue/PGM-193)

---

## Purpose

After any microk8s rolling upgrade, two controller components can silently retain stale state that causes service disruptions:

1. **Endpoint controller** — may hold pre-upgrade pod IPs in EndpointSlices for pods that restarted and got new IPs during the upgrade window
2. **Ingress-nginx Lua backend cache** — may route requests to pod IPs that no longer exist

Both are now checked automatically by `k8s-upgrade.yml`. This runbook documents the manual procedure for when the automated checks flag issues or need to be run outside the playbook.

---

## Automated checks in k8s-upgrade.yml

The upgrade playbook runs two post-upgrade validation plays:

| Play tag | Script | What it checks | Failure action |
|----------|--------|----------------|----------------|
| `endpoint-validate` | `files/endpoints/check_endpoints.py` | EndpointSlice IPs vs actual pod IPs | Fails loudly — manual recovery required |
| `ingress-validate` | `files/ingress/check_backends.py` | ingress-nginx Lua backend IPs vs Running pods | Auto-restarts stale ingress-nginx pods |

Run only the validation plays (no upgrade) with:

```bash
ansible-playbook -i inventory/hosts.ini k8s-upgrade.yml \
  --tags endpoint-validate,ingress-validate
```

---

## Failure Mode 1 — Stale EndpointSlice IPs

### When it occurs

After a rolling upgrade where kubelite restarts cause kubelets to evict and reschedule pods. The endpoint controller (part of kube-controller-manager) uses an informer with a watch bookmark. Pods that changed IP *during the restart window* — before the controller reestablished its watch — fall outside the controller's resync scope. The EndpointSlice retains the old IP; the new pod IP is never recorded.

This is not a fixed k8s regression. It's an inherent property of the informer model under upgrade chaos. The detection check exists to catch it before services are affected.

### Detection

```bash
# Run the check script directly
cd /home/paul/pgmac/ansible
python3 files/endpoints/check_endpoints.py | python3 -m json.tool
```

**Healthy output:**
```json
{
  "ok": true,
  "stale_count": 0,
  "details": []
}
```

**Stale output:**
```json
{
  "ok": false,
  "stale_count": 2,
  "details": [
    {
      "namespace": "argocd",
      "endpointslice": "argocd-redis-ha-abc123",
      "service": "argocd-redis-ha",
      "pod": "argocd-redis-ha-pkm99",
      "stale_ip": "10.1.237.21",
      "actual_ip": "10.1.237.25"
    }
  ]
}
```

Cross-check a single EndpointSlice manually:
```bash
kubectl --context pvek8s get endpointslice -n <namespace> <endpointslice> -o yaml
# Look at .endpoints[].addresses[0] — should match the pod's actual IP

kubectl --context pvek8s get pod -n <namespace> <pod> -o jsonpath='{.status.podIP}'
```

The Nagios NRPE check runs continuously from all nodes:
```bash
# Run on any k8s node
sudo /usr/lib/nagios/plugins/check_k8s_endpoints.sh
```

### Recovery — Option A: delete and recreate the EndpointSlice

The endpoint controller recreates the EndpointSlice within ~5 seconds with correct IPs. This is the fast, low-risk fix.

```bash
# 1. Verify the stale entry
kubectl --context pvek8s get endpointslice -n <namespace> <endpointslice> -o yaml

# 2. Delete — controller recreates immediately
kubectl --context pvek8s delete endpointslice -n <namespace> <endpointslice>

# 3. Wait for recreation and verify correct IP
kubectl --context pvek8s get endpointslice -n <namespace> -w
# Should appear within 5s with the correct pod IP

# 4. Confirm the service is routing correctly
kubectl --context pvek8s get endpoints -n <namespace> <service>
```

**Script for bulk recovery** (all stale slices from the check output):
```bash
python3 files/endpoints/check_endpoints.py | \
  python3 -c "
import json, sys, subprocess
data = json.load(sys.stdin)
for d in data['details']:
    cmd = ['kubectl', '--context', 'pvek8s', 'delete', 'endpointslice',
           '-n', d['namespace'], d['endpointslice']]
    print('Deleting:', ' '.join(cmd))
    subprocess.run(cmd, check=True)
print('Done — controller will recreate within 5s')
"
```

### Recovery — Option B: restart the kcm leader to force full resync

Use when multiple namespaces are affected or when Option A doesn't clear all mismatches (e.g., controller has a corrupted in-memory view).

```bash
# 1. Identify the kcm leader node
LEADER=$(kubectl --context pvek8s -n kube-system get lease kube-controller-manager \
  -o jsonpath='{.spec.holderIdentity}' | cut -d_ -f1)
echo "kcm leader: $LEADER"

# 2. Cordon the leader node to prevent scheduling disruption
kubectl --context pvek8s cordon $LEADER

# 3. Restart k8s-dqlite first (prevents kine connection errors)
ssh $LEADER "sudo systemctl restart snap.microk8s.daemon-k8s-dqlite.service"
sleep 10

# 4. Restart kubelite on the leader (forces new leader election, fresh informer sync)
ssh $LEADER "sudo systemctl restart snap.microk8s.daemon-kubelite.service"
kubectl --context pvek8s wait node/$LEADER --for=condition=Ready --timeout=120s

# 5. Uncordon
kubectl --context pvek8s uncordon $LEADER

# 6. Wait ~30s for informer resync, then re-run the check
sleep 30
python3 files/endpoints/check_endpoints.py | python3 -m json.tool
```

### Verification

```bash
# Re-run the endpoint check — should show ok: true
python3 files/endpoints/check_endpoints.py | python3 -m json.tool

# Re-run the full upgrade validation plays
ansible-playbook -i inventory/hosts.ini k8s-upgrade.yml \
  --tags endpoint-validate,ingress-validate
```

---

## Failure Mode 2 — Ingress-nginx Stale Lua Backend Cache

### When it occurs

ingress-nginx caches pod IP → backend mappings in its Lua state. When pods restart with new IPs, the Lua cache isn't updated until ingress-nginx is restarted. Affects all services behind ingress-nginx (502 Bad Gateway).

This is handled automatically by the `ingress-validate` play in `k8s-upgrade.yml` — it restarts stale ingress-nginx pods automatically.

### Detection

```bash
cd /home/paul/pgmac/ansible
python3 files/ingress/check_backends.py | python3 -m json.tool
```

### Recovery

The `ingress-validate` play handles this automatically. Manual procedure:

```bash
# Delete stale ingress-nginx pods (they restart with fresh Lua state)
kubectl --context pvek8s delete pod -n ingress -l app.kubernetes.io/name=ingress-nginx

# Wait for Ready
kubectl --context pvek8s wait pod -n ingress -l app.kubernetes.io/name=ingress-nginx \
  --for=condition=Ready --timeout=120s

# Verify
python3 files/ingress/check_backends.py | python3 -m json.tool
```

---

## Full Post-Upgrade Checklist

Run these after every microk8s rolling upgrade:

```bash
cd /home/paul/pgmac/ansible

# 1. All nodes Ready
kubectl --context pvek8s get nodes

# 2. EndpointSlice staleness check (automated in k8s-upgrade.yml)
python3 files/endpoints/check_endpoints.py | python3 -m json.tool

# 3. Ingress-nginx backend check (automated in k8s-upgrade.yml)
python3 files/ingress/check_backends.py | python3 -m json.tool

# 4. ArgoCD sync health
kubectl --context pvek8s -n argocd get applications

# 5. Cluster component health
kubectl --context pvek8s get componentstatuses 2>/dev/null || \
  kubectl --context pvek8s get pods -n kube-system

# 6. Check for pods in non-Running/non-Completed state
kubectl --context pvek8s get pods -A \
  --field-selector='status.phase!=Running,status.phase!=Succeeded' \
  | grep -v Completed
```

---

## References

- Linear: [PGM-193](https://linear.app/pgmac-net-au/issue/PGM-193) — endpoint staleness discovery and root cause
- PIR: [microk8s 1.34 → 1.35 Upgrade](../incidents/2026-05-16-microk8s-1.35-upgrade-cgroup-v2-containerd-disk-pressure.md)
- Scripts: `ansible/files/endpoints/check_endpoints.py`, `ansible/files/ingress/check_backends.py`
- NRPE: `ansible/files/nagios/check_k8s_endpoints.sh`
- Related: [dqlite-write-contention runbook](dqlite-write-contention.md) — kcm leader restart context
