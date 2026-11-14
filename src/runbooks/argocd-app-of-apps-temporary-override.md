---
title: "ArgoCD app-of-apps temporary override"
tags:
  - runbook
  - argocd
  - gitops
  - microk8s
---

# ArgoCD App-of-Apps Temporary Override

**Service:** ArgoCD on `pvek8s`: any workload whose Application is owned by a parent app-of-apps (`sec`, `media`, …)
**First observed:** 2026-11-15
**PIR:** [hal rpc.mountd OOM Kill — Cluster-Wide Stale NFS Mounts and a 4-Hour Overnight Gap](../incidents/2026-11-15-hal-mountd-oom-kill-stale-mounts.md)

---

## Symptom

During an incident you need to change a live workload for a short time: raise a probe delay, scale to 0 to free a volume, pin an image. You patch it, and the patch is gone within seconds. The StatefulSet or Deployment shows a new `controllerrevision` matching the Git version, and the Application's `status.operationState.operation.initiatedBy` is `{"automated": true}`.

If you already set `selfHeal: false` on the child Application and it is back to `true`, the **parent** reverted it.

---

## Root Cause

Workload Applications here are owned by a parent app-of-apps, and both levels run `automated: {prune: true, selfHeal: true}`. There are three traps:

1. **Child `selfHeal: false` alone is reverted by the parent**, which treats the child Application's spec as drift.
2. **Parent `selfHeal: false` alone is not enough either.** With `automated` still set, ArgoCD auto-syncs the parent as soon as a child it manages drifts. On 2026-11-15 `sec` synced 2 s after the child was patched, re-applied `trivy-server` with `selfHeal: true`, and the child reverted the StatefulSet.
3. **A StatefulSet won't roll a pod that never became Ready.** A crash-looping pod keeps the old template even after a patch that holds, until the pod is deleted.

The parent's name does not always match the namespace. Find it; don't guess.

---

## Prevention

Prefer a Git change when the override can wait for a merge. Use this procedure only during an incident, with the owner's approval, and always restore afterwards. A durable fix (for example a missing startupProbe) goes into Git as a follow-up issue.

---

## Recovery

1. **Find the parent** of the child Application `<child>`:

    ```bash
    kubectl --context pvek8s -n argocd get applications -o json | python3 -c '
    import json,sys
    for a in json.load(sys.stdin)["items"]:
      for r in a.get("status",{}).get("resources",[]):
        if r.get("kind")=="Application" and r.get("name")=="<child>":
          print("parent:", a["metadata"]["name"], a["spec"].get("syncPolicy",{}).get("automated"))'
    # → parent: sec {'prune': True, 'selfHeal': True}
    ```

    Run it again with the parent's name to check for a grandparent. If there is one, pause from the top down.

2. **Turn off automated sync on the parent completely**, then verify it held and no new sync started:

    ```bash
    kubectl --context pvek8s -n argocd patch application <parent> --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
    kubectl --context pvek8s -n argocd get application <parent> -o jsonpath='{.spec.syncPolicy} op_start={.status.operationState.startedAt}{"\n"}'
    # → {"syncOptions":[...]} op_start=<unchanged from before the patch>
    ```

3. **Turn off selfHeal on the child**, and verify:

    ```bash
    kubectl --context pvek8s -n argocd patch application <child> --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
    kubectl --context pvek8s -n argocd get application <parent> <child> -o custom-columns=N:.metadata.name,AUTO:.spec.syncPolicy.automated,OP:.status.operationState.startedAt --no-headers
    # → <parent>  <none>                            <unchanged>
    # → <child>   map[prune:true selfHeal:false]    <unchanged>
    ```

4. **Apply the override** with a JSON patch or a client-side merge patch of the single field. Never server-side-apply a partial container spec. Verify it held:

    ```bash
    kubectl --context pvek8s -n <ns> patch statefulset <name> --type json \
      -p '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds","value":300}]'
    kubectl --context pvek8s -n <ns> get sts <name> -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.initialDelaySeconds} upd={.status.updateRevision}{"\n"}'
    # → 300 upd=<new revision>
    ```

5. **If the pod has never been Ready, delete it** (plain delete, not `--force`) so the controller recreates it from the new template:

    ```bash
    kubectl --context pvek8s -n <ns> delete pod <name>-0
    kubectl --context pvek8s -n <ns> get pod <name>-0 -o jsonpath='{.metadata.labels.controller-revision-hash}{"\n"}'
    # → <new revision>
    ```

6. **Wait for the workload to recover**, then **restore the parent**. ArgoCD restores the child and reverts the override; expect one more rollout.

    ```bash
    kubectl --context pvek8s -n <ns> wait --for=condition=Ready pod/<name>-0 --timeout=420s
    kubectl --context pvek8s -n argocd patch application <parent> --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
    ```

    Restore exactly what the parent had before step 2. If it is managed by terraform-pvek8s Helm values, the next `terraform apply` restores it in any case.

---

## Verification

```bash
# Parent and child back to automated + selfHeal, Synced/Healthy
kubectl --context pvek8s -n argocd get application <parent> <child> -o custom-columns=N:.metadata.name,AUTO:.spec.syncPolicy.automated,SYNC:.status.sync.status,H:.status.health.status --no-headers
# → <parent>  map[prune:true selfHeal:true]  Synced  Healthy
# → <child>   map[prune:true selfHeal:true]  Synced  Healthy

# Override reverted to the Git value, workload healthy on it
kubectl --context pvek8s -n <ns> rollout status statefulset/<name> --timeout=240s

# Nothing else left OutOfSync while the parent was paused
kubectl --context pvek8s -n argocd get applications --no-headers | awk '$2!="Synced"||$3!="Healthy"'
# → (empty)
```

---

## Related

- [hal NFS Failure](hal-nfs-export-failure.md): Mode 3 recovery can need this for trivy-server
- Issue: [pgmac-net/pgk8s#1108](https://github.com/pgmac-net/pgk8s/issues/1108): the trivy startupProbe fix that removes the need for this override
