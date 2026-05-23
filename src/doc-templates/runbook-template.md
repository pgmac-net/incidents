---
tags: []
---

# Runbook Template

This page explains the two runbook patterns used on this site, describing what belongs in each section and why. Use this as a reference when writing a new runbook.

The raw templates to copy are at the [bottom of this page](#templates).

---

## Why we write runbooks

A runbook is a reusable procedure document. Its purpose is to make the next incident shorter and less stressful by capturing:

- What the failure looks like (so the on-call recognises it fast)
- Why it happens (so the fix isn't guesswork)
- Exactly how to fix it (so any on-call can do it, not just the person who fixed it last time)
- How to confirm it's fixed (so incidents aren't closed prematurely)

A good runbook shortens mean time to recovery (MTTR) from hours to minutes for known failure modes. It also reduces bus-factor: knowledge that lives only in one person's head doesn't survive a team change or a 3am alert.

**When to write a runbook vs a PIR:** Write a PIR for the first occurrence of a failure (see [PIR Structure Template](pir-template.md)). Write a runbook once the failure is understood well enough to document a repeatable recovery procedure — often immediately after writing the PIR.

---

## Two Patterns

This site uses two runbook patterns depending on how many distinct failure modes a symptom has:

| Pattern                                   | When to use                                                                    |
| ----------------------------------------- | ------------------------------------------------------------------------------ |
| [Simple](#simple-runbook-pattern)         | One failure mode, one root cause, one recovery path                            |
| [Multi-mode](#multi-mode-runbook-pattern) | Same symptom, multiple distinct root causes that need different recovery paths |

If you're not sure which to use, start with Simple. Promote to Multi-mode only when a second distinct failure mode is discovered — don't pre-plan for hypothetical modes.

---

## Simple Runbook Pattern

Use this when a symptom has one root cause and one recovery path.

**Examples:** `dqlite-write-contention.md`, `jiva-csi-mount-proliferation.md`

### Frontmatter tags

```yaml
---
tags:
  - runbook
  - dqlite
  - microk8s
---
```

**Why:** Tags integrate with the MkDocs tags index, letting you find all runbooks for a specific technology without reading each one.

**What to include:**

- Always include `runbook` — this distinguishes runbooks from incidents in the tag index
- Add the primary technology or service (e.g., `calico`, `dqlite`, `kubelet`)
- Add the cluster or platform tag (e.g., `microk8s`)
- Add any failure-type tags relevant from the PIR template guidance

---

### Title

```markdown
# [Service/System] [Failure Description]
```

**Why:** The title is the primary search target. It should match the symptom or alert name someone would search for at 3am. Lead with the service name so related runbooks sort together.

**Examples:**

- `# dqlite Write Contention`
- `# Jiva CSI Mount Proliferation — Duplicate Bind Mounts After kubelite Restart`

---

### Service metadata block (optional)

```markdown
**Service:** microk8s (pvek8s)
**First observed:** YYYY-MM-DD
**PIR:** [Title](../incidents/YYYY-MM-DD-filename.md)
```

**Why:** Provides context on how old this failure mode is and links to the full investigation. Omit if the failure is generic enough that no single PIR introduced it.

---

### Symptom

```markdown
## Symptom

[What the on-call will see. Observable state only — what commands show, what alerts fire, what is broken from a user perspective.]
```

**Why:** The symptom section is how an on-call determines they're looking at the right runbook. It must describe the observable state precisely enough to distinguish this failure from others with similar presentations.

**What to include:**

- The specific alert name, if Nagios/monitoring triggers it
- What `kubectl` commands show (exact field values, not just "broken")
- The user-visible impact (pods not scheduling, traffic dropped, etc.)
- Downstream effects that may look like separate issues

**Length:** 2–4 sentences or a short list. No explanation of why — that goes in Root Cause.

---

### Root Cause

```markdown
## Root Cause

[The technical explanation of why this happens. One to three paragraphs.]
```

**Why:** Understanding the root cause is what separates a runbook from a step-list. Without it, the on-call can't adapt when the situation is slightly different, and can't tell if they've actually fixed it or just masked the symptom.

**What to include:**

- The underlying mechanism (not just "X fails because Y fails" — explain why Y fails)
- What conditions trigger it (e.g., "only after kubelite restart", "only under write load")
- Why the symptom looks the way it does (connecting cause to observable effect)

---

### Prevention (optional)

```markdown
## Prevention

[Steps to take before the triggering operation to avoid the failure.]
```

**Why:** If the failure has a known trigger (e.g., kubelite restart causing dqlite write storms), documenting what to do before that trigger prevents the failure entirely. Omit this section when there is no actionable prevention.

**Structure:** Number the steps. Group by phase if there are distinct pre-conditions to check vs. things to do during the operation.

---

### Recovery

```markdown
## Recovery

[Step-by-step procedure to resolve the failure. Use numbered steps and code blocks.]
```

**Why:** The recovery section is the core of the runbook. It must be precise enough to follow without prior knowledge of the failure. Future on-calls (and automated tooling) will execute these exact commands.

**Format rules:**

- Number every step
- Use fenced code blocks for every command
- Show expected output as a comment (`# → expected output here`) where it distinguishes success from failure
- Explain what each diagnostic step is looking for, not just what to run
- Group into sub-sections if there are multiple scenarios (e.g., "If X is also present", "Nuclear option")

**What to include:**

- The minimal fix path (shortest path to recovery)
- Alternative paths for edge cases or when the minimal fix doesn't work
- What to avoid (and why) — especially if there's a common but wrong fix

---

### Verification

```markdown
## Verification

[Commands and expected output that prove the failure is resolved.]
```

**Why:** Proving recovery is as important as applying the fix. This prevents closing the incident prematurely. The verification section answers "how do I know it's actually fixed?" with concrete checks.

**Format:** Code blocks with the command and a comment showing what healthy output looks like:

```bash
kubectl get nodes
# → all nodes Ready with no taints

kubectl -n kube-system get pods | grep dqlite
# → Running
```

---

### References

```markdown
## References

- PIR: [Title](../incidents/YYYY-MM-DD-filename.md)
- Linear: [PGM-NNN](https://linear.app/pgmac-net-au/issue/PGM-NNN)
- Related: [other-runbook.md](other-runbook.md)
```

**Why:** Links to the investigation (PIR), the tracking ticket, and related runbooks. When a failure is complex enough to have a runbook, it almost always has a PIR and a Linear ticket.

---

## Multi-Mode Runbook Pattern

Use this when multiple distinct root causes produce the same observable symptom but require different recovery paths.

**Example:** `kubelet-silent-stall.md` — three independent failure modes all present as "node Ready but pods Pending".

**When to promote from Simple to Multi-mode:** When you discover a second failure mode for an existing symptom, add a new `## Failure Mode N` section to the existing runbook rather than creating a second runbook. The shared symptom is what makes Multi-mode valuable: the on-call finds one runbook and works through the modes sequentially.

### Frontmatter tags, Title, Service metadata block

Same as Simple pattern.

---

### Symptom (top-level)

```markdown
## Symptom

[The shared observable state that all failure modes produce. This is what the on-call sees before they know which mode they're dealing with.]

## N Distinct Root Causes

All N failure modes produce the same symptom. Check [key diagnostic] to distinguish them.
```

**Why:** The top-level symptom section establishes what all modes have in common and tells the on-call they need to diagnose before fixing. The "N Distinct Root Causes" note prevents them from defaulting to the first mode's fix without checking.

---

### Failure Mode sections

```markdown
## Failure Mode N — [Name]

### When it occurs

[The conditions under which this specific mode triggers. Be precise.]

### Detection

[Commands and log signatures that identify this specific mode — distinct from the other modes.]

### Recovery

[Steps to fix this specific mode.]

### Verification

[Commands that confirm this specific mode is resolved.]

### Context (optional)

[Why this mode happens technically. Historical notes. References to prior incidents.]
```

**Why each sub-section:**

**When it occurs:** Allows the on-call to rule modes in or out based on what changed recently (e.g., "after a kubelite restart" vs "after a containerd upgrade"). This is the first branch in the decision tree.

**Detection:** Mode-specific signatures that distinguish it from the others. The on-call uses this to confirm which mode they're in before applying a fix. Include exact log line patterns where available — these are the most reliable identifiers.

**Recovery:** Mode-specific fix. Numbered steps, code blocks, expected output. If there's a "nuclear option" (more destructive but reliable), document it as a sub-section with a clear warning about its impact.

**Verification:** Mode-specific confirmation. What does healthy look like after this specific fix? Some modes have different healthy states than others.

**Context:** Technical explanation of why this mode occurs. Useful for training and for adapting when the situation is slightly different. Can also document when this mode was first seen and which PIR covers it.

---

### Quick Reference table

```markdown
## Quick Reference

| Signal        | Mode 1 (name) | Mode 2 (name) | Mode 3 (name) |
| ------------- | ------------- | ------------- | ------------- |
| [signal A]    | [value]       | [value]       | [value]       |
| [signal B]    | [value]       | [value]       | [value]       |
| Fix           | [one-line]    | [one-line]    | [one-line]    |
| Data at risk? | No            | No            | No            |
```

**Why:** The Quick Reference table is the on-call's triage guide. After identifying which signals are present, the table tells them which mode they're in without re-reading every mode's Detection section. It is the most-used part of a Multi-mode runbook during an active incident.

**What to include:**

- The key discriminating signals as rows (log silence, specific error strings, process state)
- Each failure mode as a column
- The one-line fix for each mode
- Whether data is at risk (pod restarts are usually safe; data deletion is not)

---

### Post-Incident Checks (optional)

```markdown
## Post-Incident Checks

[Additional checks to run after recovery to catch secondary effects that may not be immediately visible.]
```

**Why:** Some recovery procedures (especially "nuclear" options that kill processes) can cause secondary failures that appear minutes to hours later. This section documents what to check proactively, before those failures become new incidents.

---

### References

Same as Simple pattern.

---

## Templates

### Simple Runbook Template

Copy this template for a single-failure-mode runbook.

```markdown
---
tags:
  - runbook
  - [technology]
  - [platform]
---

# [Service] [Failure Description]

**Service:** [service-name] ([cluster])
**First observed:** YYYY-MM-DD
**PIR:** [Title](../incidents/YYYY-MM-DD-filename.md)

---

## Symptom

[Observable state: what alerts fire, what kubectl shows, what is broken from a user perspective.]

---

## Root Cause

[Technical explanation of why this failure occurs and what triggers it.]

---

## Prevention

[Steps to take before the triggering operation to prevent the failure. Remove section if no actionable prevention exists.]

---

## Recovery

1. [First step]

   \`\`\`bash
   [command]

   # → [expected output]

   \`\`\`

2. [Second step]

   \`\`\`bash
   [command]
   \`\`\`

---

## Verification

Cluster/service is healthy when:

\`\`\`bash
[check command]

# → [expected output when healthy]

\`\`\`

---

## References

- PIR: [Title](../incidents/YYYY-MM-DD-filename.md)
- Linear: [PGM-NNN](https://linear.app/pgmac-net-au/issue/PGM-NNN)
- Related: [other-runbook.md](other-runbook.md)
```

---

### Multi-Mode Runbook Template

Copy this template when multiple root causes share the same symptom.

```markdown
---
tags:
  - runbook
  - [technology]
  - [platform]
---

# [Service/System] [Shared Symptom Description]

**Service:** [service-name] ([cluster])
**First observed:** YYYY-MM-DD
**PIR:** [Title](../incidents/YYYY-MM-DD-filename.md)

---

## Symptom

[The shared observable state that all failure modes produce.]

## N Distinct Root Causes

All N failure modes produce the same symptom. Check [key diagnostic] to distinguish them.

---

## Failure Mode 1 — [Name]

### When it occurs

[Conditions that trigger this specific mode.]

### Detection

\`\`\`bash

# [Step description]

[command]

# [What the stall signature looks like]

[log or output pattern]
\`\`\`

### Recovery

\`\`\`bash

# [Step description]

[command]
\`\`\`

### Verification

\`\`\`bash
[check command]

# → [expected output]

\`\`\`

### Context

[Technical explanation. Historical notes. Related tickets/PIRs.]

---

## Failure Mode 2 — [Name]

### When it occurs

### Detection

### Recovery

### Verification

### Context

---

## Quick Reference

| Signal        | Mode 1 ([name]) | Mode 2 ([name]) |
| ------------- | --------------- | --------------- |
| [signal A]    | [value]         | [value]         |
| [signal B]    | [value]         | [value]         |
| Fix           | [one-line]      | [one-line]      |
| Data at risk? | No              | No              |

---

## Post-Incident Checks

[Checks to run after recovery to catch secondary failures from the recovery procedure itself.]

---

## References

- PIR: [Title](../incidents/YYYY-MM-DD-filename.md)
- Linear: [PGM-NNN](https://linear.app/pgmac-net-au/issue/PGM-NNN)
- Related: [other-runbook.md](other-runbook.md)
```
