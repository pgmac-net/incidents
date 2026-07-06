---
tags:
  - runbook
  - calico
  - networking
  - microk8s
---

# Calico Orphaned Pod Route — Probe `connect: invalid argument` CrashLoop

**Service:** calico CNI / kubelet probes (pvek8s)
**First observed:** 2026-07-07 (dependency-track-frontend on k8s01)

---

## Symptom

- A pod is in CrashLoopBackOff with a climbing restart count, but its container logs show a healthy application start followed by a graceful shutdown (SIGQUIT from kubelet) every probe cycle.
- Pod events show the liveness probe failing with **`connect: invalid argument`** — not a timeout, not `connection refused`:

```
Liveness probe failed: Get "http://10.1.73.89:8080/": dial tcp 10.1.73.89:8080: connect: invalid argument
Container ... failed liveness probe, will be restarted
```

- Any service fronted by the pod returns 503 through ingress (Nagios HTTP CRITICAL on the exposed URL).
- `curl` to the pod IP from its own node fails instantly with exit code 7.

---

## Root Cause

Calico programs one host route per pod veth (`10.1.x.y dev caliXXXX scope link`) plus per-IPAM-block blackhole routes (`blackhole 10.1.x.0/26 proto 80`). If the per-pod route is missing, traffic to that pod IP from its own node falls through to the blackhole route, and `connect()` returns **EINVAL** (`invalid argument`) — the kernel signature of a blackhole route, and the key discriminator from ordinary network failures.

The kubelet liveness probe therefore fails forever and kills a perfectly healthy container. Container restarts never fix it because CNI only programs the route at pod **sandbox** creation, and a liveness-probe restart reuses the existing sandbox.

Observed trigger: a calico-node restart on the host dropped (or failed to re-program) the route for one existing pod. On k8s01, 63 cali veths existed but only 62 pod routes — exactly one orphan.

---

## Recovery

1. Confirm the route for the pod IP is missing on the pod's node:

    ```bash
    kubectl -n <ns> get pod <pod> -o wide          # note IP and NODE
    ssh <node> "ip route get <pod-ip>"
    # → RTNETLINK answers: Invalid argument       ← blackhole hit, route missing
    ssh <node> "ip route | grep <pod-ip>"
    # → no output (neighbouring pod IPs are present)
    ```

2. Check the veth/route counts per node to find how many pods are affected:

    ```bash
    for n in k8s01 k8s02 k8s03; do
      echo -n "$n veths=";  ssh $n 'ip link show | grep -c "cali[0-9a-f]*@"'
      echo -n "$n routes="; ssh $n 'ip route | grep -c "dev cali"'
    done
    # → counts should match per node; a veth surplus of N = N orphaned pods
    ```

3. Delete the affected pod(s). Sandbox recreation re-runs CNI, which allocates a fresh IP and programs the route:

    ```bash
    kubectl -n <ns> delete pod <pod>
    ```

    Avoid manually adding the route (`ip route add <pod-ip> dev <veth> scope link`) unless the pod genuinely cannot be restarted — matching the correct veth requires resolving the pod's `eth0` peer ifindex, and pod deletion is simpler and self-healing.

---

## Verification

```bash
kubectl -n <ns> get pods -o wide | grep <deployment>
# → replacement pod 1/1 Running, restart count 0

curl -s -o /dev/null -w "%{http_code}\n" https://<service-url>/
# → 200

# veth/route counts match again on all nodes (step 2 loop above)
```

Nagios HTTP check on the fronting URL recovers on its next scheduled check.

---

## References

- Related: [calico-cni-unauthorized.md](calico-cni-unauthorized.md) — CNI failure at sandbox creation (pods stuck ContainerCreating), whereas this mode hits already-running pods
- Related: cross-node calico VXLAN route repair — wrong VTEP gateway on *peer* nodes after calico-node restarts; this runbook covers the *local* per-pod route
