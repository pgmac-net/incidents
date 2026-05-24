---
tags:
  - runbook
  - calico
  - cni
  - networking
---

# Calico CNI Unauthorized — Stale or Expired calico-kubeconfig Token

**Service:** Calico CNI (pvek8s)
**Linear:** [PGM-208](https://linear.app/pgmac-net-au/issue/PGM-208), [PGM-209](https://linear.app/pgmac-net-au/issue/PGM-209)
**Nagios check:** `check_calico_kubeconfig` (per-node)
**First observed:** 2026-05-23 (PGM-204 — wrong SA after upgrade), 2026-05-24 (expired JWT)

---

## Overview

Each k8s node has a local kubeconfig at `/var/snap/microk8s/current/args/cni-network/calico-kubeconfig`.
The Calico CNI plugin uses this kubeconfig to authenticate to the Kubernetes API (to read `ClusterInformation` and manage IPAM) when creating or deleting pod network interfaces.

If the JWT in this file is **expired** or **bound to the wrong service account**, the API server returns `401 Unauthorized`. Every new pod sandbox creation on the node fails silently:

```
FailedCreatePodSandBox: rpc error: code = Unknown desc = failed to setup network for
sandbox "...": plugin type="calico" failed (add): error getting ClusterInformation:
connection is unauthorized: Unauthorized
```

Existing pods continue running. Only new pod starts (including replacements) are blocked.

---

## Root Causes

| Cause | How to identify |
|-------|----------------|
| **Expired JWT** | `expires_in < 0` in check output; calico-node pod older than 24h without restart | 
| **Wrong SA (stale pre-upgrade token)** | `sa_name != calico-cni-plugin`; typically `calico-node` (v3.13.x SA name) |

**Expired JWT:** Calico writes the kubeconfig token when `calico-node` starts. The token has a 24h TTL. If calico-node runs longer than 24h without being restarted, the token expires and calico-node does not refresh it automatically.

**Wrong SA after upgrade:** During the Calico v3.13 → v3.29 upgrade, the CNI plugin service account was renamed from `calico-node` to `calico-cni-plugin`. If a node's calico-node pod was not restarted as part of the upgrade rollout, the kubeconfig retains the old SA name. The old SA no longer has API permissions, so every CNI call returns Unauthorized.

---

## Detection

### Nagios alert

The `check_calico_kubeconfig` NRPE check runs hourly on each node. It fires:

- **WARNING** if the token expires within 4 hours
- **CRITICAL** if the token is expired or has the wrong service account

### Pod events (symptom)

Pods stuck in `ContainerCreating` on the affected node with events like:

```bash
kubectl --context pvek8s describe pod <pod> -n <namespace> | grep -A5 "^Events:"
# Warning  FailedCreatePodSandBox  ...  plugin type="calico" failed (add): ... Unauthorized
```

### Identify affected node(s)

```bash
# Which nodes have pods stuck ContainerCreating?
kubectl --context pvek8s get pods -A --field-selector=status.phase=Pending -o wide | grep ContainerCreating

# Check kubelet logs on a suspected node (ssh or journalctl via node exec)
kubectl --context pvek8s debug node/<node> -it --image=busybox -- chroot /host \
  journalctl -u snap.microk8s.daemon-kubelite --since "-30m" | grep -i "calico\|unauthorized\|FailedCreate"

# Decode the token on each node manually
python3 - <<'EOF'
import json, base64, time
path = "/var/snap/microk8s/current/args/cni-network/calico-kubeconfig"
with open(path) as f:
    token = next(l.split("token:",1)[1].strip() for l in f if "token:" in l)
payload = token.split(".")[1] + "=="
claims = json.loads(base64.urlsafe_b64decode(payload))
sa = claims.get("kubernetes.io",{}).get("serviceaccount",{}).get("name","")
exp = claims.get("exp",0)
now = int(time.time())
print(f"SA: {sa}  exp: {exp}  now: {now}  expires_in: {exp-now}s")
EOF
```

---

## Recovery

**Fix: delete the calico-node pod on the affected node.** The DaemonSet controller recreates it, and calico-node writes a fresh kubeconfig with a valid token and the correct SA.

```bash
# 1. Identify the calico-node pod on the affected node
kubectl --context pvek8s get pod -n kube-system -l k8s-app=calico-node -o wide
# NAME                READY   STATUS    NODE
# calico-node-4t5hk   1/1     Running   k8s01   <-- affected node

# 2. Delete it — DaemonSet recreates immediately
kubectl --context pvek8s delete pod calico-node-4t5hk -n kube-system

# 3. Wait for the new pod to be Ready (~30s)
kubectl --context pvek8s wait pod -n kube-system -l k8s-app=calico-node \
  --for=condition=Ready --timeout=90s

# 4. Verify the new token is valid
# (run on the node via ansible or node debug pod)
# Or wait for the next Nagios check cycle

# 5. Check that stuck pods are now creating successfully
kubectl --context pvek8s get pods -A | grep -E 'ContainerCreating|Pending'
```

If pods are still stuck after the calico-node pod is Ready, they may need to be deleted (their sandbox creation failed and the kubelet won't automatically retry indefinitely):

```bash
# Force-restart pods still stuck in ContainerCreating on the fixed node
kubectl --context pvek8s get pods -A --field-selector=status.phase=Pending -o wide \
  | grep <node-name> | awk '{print $1, $2}' \
  | xargs -r -n2 kubectl --context pvek8s delete pod -n
```

---

## Prevention

| Mechanism | Coverage |
|-----------|----------|
| Nagios `check_calico_kubeconfig` (hourly, per-node) | Catches expiry before it causes failures; warns 4h ahead |
| Phase 4 of `calico-upgrade.yml` (`--tags cni-verify`) | One-shot post-upgrade check for wrong-SA tokens |
| calico-node DaemonSet rolling update during upgrade | Refreshes token on every node during planned upgrades |

### calico-upgrade.yml post-upgrade verification

```bash
# Run only the CNI verification phase on all nodes:
ansible-playbook -i inventory/hosts.ini calico-upgrade.yml --tags cni-verify
```

This checks both the symlink and the JWT SA name on every node.

---

## Related

- **PGM-204** — original incident: wrong SA after v3.13 → v3.29 upgrade on k8s01
- **PGM-205** — Phase 4 CNI verification added to `calico-upgrade.yml`
- **PGM-208** — Nagios NRPE check implementation
- **PIR:** [2026-05-23 Calico CNI Unauthorized Stale Kubeconfig](../incidents/2026-05-23-k8s01-calico-cni-unauthorized-stale-kubeconfig.md)
