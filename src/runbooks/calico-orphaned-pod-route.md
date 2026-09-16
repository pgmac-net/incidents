---
title: "Calico orphaned pod route"
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

### Second presentation: the pod's own outbound traffic fails (2026-09-15)

There need not be a probe at all. A blackholed pod also cannot reach anything
*outbound* — including ClusterIPs — and the only evidence is in its own log:

```
Failed to check replica state, err: Get "http://10.152.183.78:9501/v1/replicas":
  dial tcp 10.152.183.78:9501: connect: network is unreachable, will retry
Retry count exceeded, Shutting down...
```

`connect: network is unreachable` from inside the pod, against a Service whose
endpoints are healthy, is the same fault as `connect: invalid argument` from the
node — the pod has no route in either direction. Check the Service endpoint
first so the controller/backend is ruled out, then test the route (step 1 below).

---

## Root Cause

Calico programs one host route per pod veth (`10.1.x.y dev caliXXXX scope link`) plus per-IPAM-block blackhole routes (`blackhole 10.1.x.0/26 proto 80`). If the per-pod route is missing, traffic to that pod IP from its own node falls through to the blackhole route, and `connect()` returns **EINVAL** (`invalid argument`) — the kernel signature of a blackhole route, and the key discriminator from ordinary network failures.

The kubelet liveness probe therefore fails forever and kills a perfectly healthy container. Container restarts never fix it because CNI only programs the route at pod **sandbox** creation, and a liveness-probe restart reuses the existing sandbox.

Observed triggers:

- **calico-node restart** (2026-07-07) — dropped, or failed to re-program, the route for one existing pod. On k8s01, 63 cali veths existed but only 62 pod routes: exactly one orphan.
- **Node-wide I/O stall** (2026-09-15) — a Proxmox `vzdump` guest-agent `fs-freeze` froze k8s01's filesystems; the CNI log recorded `CNI_CONTAINERID does not match WorkloadEndpoint ContainerID, don't delete WEP` in the same minute, and the pod ended up with **neither a veth nor a route**. See [PIR 2026-09-15](../incidents/2026-09-15-vzdump-fsfreeze-jiva-replica-triple-fault.md).

The second trigger matters for diagnosis: with no veth, the pod contributes to
neither side of the veth/route comparison in step 2, so the counts match on every
node and the heuristic reads clean. **The per-pod `ip route get` test in step 1 is
the reliable one; the count comparison only finds additional affected pods.**

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

2. Check the veth/route counts per node to find **additional** affected pods.
   A surplus proves orphans exist; matching counts do **not** prove they don't
   (a pod with no veth leaves the counts equal — 2026-09-15):

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

- **PIR:** [pvek8s Triple Replica Fault — Proxmox Backup fs-freeze, Corrupt Snapshot Chains, and an Orphaned Pod Route](../incidents/2026-09-15-vzdump-fsfreeze-jiva-replica-triple-fault.md) — second occurrence; added the outbound presentation and demoted the count heuristic
- Related: [calico-cni-unauthorized.md](calico-cni-unauthorized.md) — CNI failure at sandbox creation (pods stuck ContainerCreating), whereas this mode hits already-running pods
- Related: cross-node calico VXLAN route repair — wrong VTEP gateway on *peer* nodes after calico-node restarts; this runbook covers the *local* per-pod route
