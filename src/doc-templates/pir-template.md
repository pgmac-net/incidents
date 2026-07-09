---
tags: []
---

# PIR Structure Template

This page explains the structure of every Post-Incident Review (PIR) on this site, describing what belongs in each section and why. Use this as a reference when writing a new PIR.

The raw template to copy is at the [bottom of this page](#template).

---

## Why we write PIRs

A PIR is not a blame document — it is an investment in reliability. Its purpose is to extract the maximum learning from each incident so that:

- The same failure doesn't recur undetected
- The next on-call person has a faster path to diagnosis
- Monitoring and runbook gaps get tracked and closed
- The cluster's failure modes are collectively understood rather than held in one person's head

Every PIR should end with concrete, trackable action items (GitHub Issues). If an incident generates no action items, it was either trivial or not investigated deeply enough.

---

## Section Guide

### Frontmatter tags

```yaml
---
tags:
  - k8s01
  - calico
  - networking
---
```

**Why:** The `tags` MkDocs plugin generates the [Tags index](../tags.md), letting you find all incidents involving a specific node or technology without reading each one. Tag liberally.

**What to include:**

| Category      | Values                                                                           |
| ------------- | -------------------------------------------------------------------------------- |
| Nodes         | `k8s01`, `k8s02`, `k8s03`                                                        |
| Technologies  | `calico`, `kine`, `dqlite`, `kubelet`, `containerd`, `argocd`, `openebs`, `jiva` |
| Failure types | `watch-stream`, `vxlan`, `ipam`, `pleg`, `crash-loop`, `oom`, `cni`              |
| Domain        | `networking`, `storage`, `scheduling`                                            |

---

### Metadata block (Date, Duration, Severity, Status)

```
**Date:** YYYY-MM-DD
**Duration:** ~Xh Ym active (~HH:MM AEST → ~HH:MM AEST)
**Severity:** High (one-line justification)
**Status:** Resolved
```

**Why:** The metadata block lets readers instantly gauge the scope before investing time in the full document. Severity and duration together communicate urgency. Use the same severity level in the incidents index row.

**Severity guide:**

| Level    | Criteria                                                                      |
| -------- | ----------------------------------------------------------------------------- |
| Critical | Full cluster outage or data loss; multiple services completely down           |
| High     | Single major service down; significant workload disruption; extended recovery |
| Medium   | Degraded redundancy; intermittent failures; no user-visible outage            |
| Low      | Near-miss; caught before user impact; brief self-healing issue                |

---

### Executive Summary

**Why:** The executive summary is the only section most readers will read in full. It should stand alone — someone who reads only this section should understand what happened, why, and what fixed it. It covers all three root cause chains at a high level without requiring knowledge of the rest of the document.

**What to include:**

- What was observed (user-visible symptom or initial alert)
- What the root cause turned out to be (one sentence per distinct chain)
- What fixed it and in what order
- Any relationship to prior incidents or ongoing work

**Length:** 3–5 paragraphs. No bullet lists — write prose.

---

### Timeline (AEST — UTC+10)

**Why:** The timeline is the factual record of the incident. It is the most-referenced section during retrospectives and when debugging a recurrence. The chronology makes it possible to answer "why wasn't X noticed sooner?" or "did Y cause Z or was Z already failing?".

**Format:**

```markdown
| Time            | Event                                                         |
| --------------- | ------------------------------------------------------------- |
| **~09:00 AEST** | Brief description of what happened or was observed            |
| **09:15 AEST**  | Specific times when known; approximate (~) when reconstructed |
```

**Guidelines:**

- Use AEST (UTC+10) consistently throughout the document
- Bold the time column: `**~14:30 AEST**`
- Include both diagnostic actions and state transitions ("calico-node became Ready")
- Note when key error messages first appeared (with exact timestamps from logs when available)
- Record commands run and what they found, not just conclusions
- Mark approximate times with `~` prefix

---

### Root Causes — The Infinite How's Chain

**Why:** Surface symptoms are never root causes. "The pod was stuck Terminating" is a symptom. The root cause is what made that possible — and usually there are several layers. The Infinite How's method ensures we drill past the proximate cause to the systemic gap (missing monitoring, undocumented procedure, unchecked assumption) that allowed the failure to happen and go undetected.

**Method:** For each distinct failure chain, ask "How did X happen?" at each level until reaching one of these stopping conditions:

- A missing monitoring or alerting capability
- A missing or undocumented procedure
- An upstream software bug not actionable on our side
- A deliberate architectural trade-off
- An external dependency or hardware failure

Target **4–7 "how" levels** per chain. Stopping at 2–3 levels usually means you haven't found the systemic cause yet.

**Format:**

```markdown
#### Chain N: [Surface Symptom] — [Short Title]

##### How did [symptom] happen?

[Proximate cause — the immediate technical reason]

##### How did [proximate cause] happen?

[Contributing factor — what enabled the proximate cause]

##### How did [contributing factor] happen?

[Deeper cause]

... continue drilling ...

##### How was [root cause] not prevented or detected?

[The process gap, monitoring gap, or knowledge gap — this is the actual root cause]
```

**Identifying distinct chains:** Each chain should represent an independent failure that, on its own, would have been an incident. If removing one chain would not have prevented the incident, it's a separate chain.

---

### Impact

**Why:** Impact quantifies what actually broke and for how long. It answers "should I care about this?" for future readers, and provides the data needed to evaluate whether action items are worth the effort. A 5-minute impact and a 5-hour impact warrant different levels of remediation.

**Services Affected table:**

```markdown
| Service                      | Impact                             | Duration |
| ---------------------------- | ---------------------------------- | -------- |
| calico-node (k8s01)          | Not scheduling new pods            | ~35 min  |
| All k8s03 cross-node traffic | Silently dropped (VXLAN blackhole) | ~35 min  |
```

Include: service name, what went wrong (not just "down"), and duration.

**Duration section:** List both total incident window and any distinct sub-phases (e.g. "active blackhole: 35 min" separate from "total recovery window: 2h10m").

**Scope:** Note which nodes were affected, whether there was data loss, and what was not affected (e.g. "no user-visible outage").

---

### Resolution Steps Taken

**Why:** The resolution section is the runbook for the next time this happens. Write it precisely enough that someone else could follow it cold. Future on-calls — and automated diagnostics — benefit from exact commands with expected outputs.

**Structure:** Group steps into named phases (Diagnosis, Fix, Verification). Within each phase, number the steps.

**Include:**

- Exact commands run (with expected output where it distinguishes healthy from broken)
- What each diagnostic step found
- Why each fix was chosen over alternatives
- Any steps that didn't work (and why they were abandoned)

---

### Verification

**Why:** Proving recovery is as important as applying the fix. This section provides the commands and expected outputs that confirm all affected systems are back to a known-good state. It prevents closing an incident prematurely.

**Format:** Code blocks with the command and a comment showing expected output:

```bash
kubectl --context pvek8s get pods -A | grep -v Running | grep -v Completed
# → (empty — all pods healthy)
```

---

### Preventive Measures

**Why:** This section translates root causes into concrete work. Every "How did X not get detected?" answer should map to at least one action here. Preventive Measures is the contract between the PIR and the backlog.

**Structure:**

- **Immediate Actions Required** — things that must be done before the next incident to reduce risk (monitoring gaps, missing runbooks, known-broken state)
- **Longer-Term Improvements** — architectural changes, tool improvements, process changes

Each item should:

1. State what the action is
2. Explain why it's needed (link back to the root cause chain)
3. Link to the GitHub Issue

---

### Lessons Learned

**Why:** The lessons section captures institutional knowledge that doesn't fit neatly into a procedure or a ticket. It records what surprised us, what worked well, and what would have made the incident shorter — so that knowledge survives even if the on-call person changes.

**Three subsections:**

**What Went Well** — diagnostic techniques that worked, decisions that shortened recovery, runbooks that existed and helped. Recording successes is as important as recording failures: if something worked, we want to keep doing it.

**What Didn't Go Well** — actions that extended the incident, assumptions that turned out to be wrong, things we tried before the actual fix. Be specific: "we assumed the iptables rules were correct before checking the routing table" is more useful than "diagnosis took too long".

**Surprise Findings** — facts about the system's behaviour that were genuinely unexpected. These often reveal undocumented assumptions and are valuable for training future on-calls.

---

### Action Items table

**Why:** The action items table is the machine-readable contract. It maps to GitHub Issues, enabling tracking and prioritisation outside the PIR document. The table format (number, description, priority, GitHub link) is consistent across all PIRs so the incidents site can eventually auto-generate a backlog view.

**Format:**

```markdown
| #   | Action                   | Priority | GitHub                                                            |
| --- | ------------------------ | -------- | ----------------------------------------------------------------- |
| 1   | Short action description | High     | [owner/repo#NN](https://github.com/owner/repo/issues/NN)          |
```

Issues live in the repo whose code/config the action touches; `pgmac-net/homelabia` is the fallback for cluster-operational items with no single owning repo. Historical PIRs reference Linear tickets (`PGM-NNN`) — those links remain valid as past-incident pointers; do not rewrite them.

Priority: High / Medium / Low (matching the PIR text).

---

### Technical Details

**Why:** The technical details section preserves diagnostic artefacts for future incidents. Error signatures, commands, and procedures here are often the most-searched content when debugging a recurrence.

**Include:**

- **Environment** — cluster, Kubernetes version, CNI version, any relevant snap revision
- **Key Error Signatures** — exact log lines or error strings that identify this failure mode
- **Diagnostic/Fix procedures** — bash code blocks with exact commands, reusable for future incidents

---

### References

List all GitHub Issues, related PIRs, and runbooks referenced by the document. This enables navigation between related incidents.

---

## Template

Copy this template to start a new PIR. Replace all `[...]` placeholders with actual content.

```markdown
---
tags:
  - k8s01
  - calico
---

# Post Incident Review: [System] [Root Problem] — [Technical Detail]

**Date:** YYYY-MM-DD
**Duration:** ~Xh Ym active (~HH:MM AEST → ~HH:MM AEST)
**Severity:** [Critical / High / Medium / Low] ([one-line justification])
**Status:** [Resolved / Partially Resolved / Monitoring]

---

## Executive Summary

[3–5 paragraphs. What was observed, what the root cause was (one sentence per chain),
what fixed it, any connection to prior incidents.]

---

## Timeline (AEST — UTC+10)

| Time            | Event   |
| --------------- | ------- |
| **~HH:MM AEST** | [Event] |

---

## Root Causes

### The Infinite How's Chain

> _"The infinite how's" methodology: at each causal step, ask "how?" rather than accepting
> the surface answer. Keep drilling until reaching an actionable, preventable cause._

---

#### Chain 1: [Surface Symptom] — [Short Title]

##### How did [symptom] happen?

[Proximate cause]

##### How did [proximate cause] happen?

[Contributing factor]

##### How was [root cause] not prevented or detected?

[The gap — monitoring, runbook, knowledge, architecture]

---

## Impact

### Services Affected

| Service   | Impact            | Duration   |
| --------- | ----------------- | ---------- |
| [service] | [what went wrong] | [duration] |

### Duration

- **Total incident window:** ~Xh Ym
- **Expected recovery time (with documented procedure):** ~X min

### Scope

- [Nodes affected]
- [Data loss: yes/no]
- [User-visible impact]

---

## Resolution Steps Taken

### Phase 1: [Diagnosis / Fix / Verification]

1. [Step]
2. [Step]

---

## Verification

\`\`\`bash

# [Check description]

kubectl --context pvek8s [command]

# → [expected output]

\`\`\`

---

## Preventive Measures

### Immediate Actions Required

1. **[Action title]** (High / Medium / Low)
    - [Why needed — link to root cause chain]
    - Issue: [owner/repo#NN](https://github.com/owner/repo/issues/NN)

### Longer-Term Improvements

2. **[Action title]** (Medium / Low)
    - [Why needed]
    - Issue: [owner/repo#NN](https://github.com/owner/repo/issues/NN)

---

## Lessons Learned

### What Went Well

- [Thing that worked]

### What Didn't Go Well

- [Thing that extended the incident]

### Surprise Findings

- [Unexpected behaviour or fact about the system]

---

## Action Items

| #   | Action   | Priority | GitHub                                                    |
| --- | -------- | -------- | --------------------------------------------------------- |
| 1   | [Action] | High     | [owner/repo#NN](https://github.com/owner/repo/issues/NN)  |

---

## Technical Details

### Environment

- **Cluster:** `pvek8s` (microk8s HA, 3 nodes: k8s01/k8s02/k8s03)
- **Kubernetes version:** vX.YY.Z
- **CNI:** Calico vX.Y.Z

### Key Error Signatures

\`\`\`
[Exact log line or error string that identifies this failure mode]
\`\`\`

### [Procedure Name]

\`\`\`bash

# [Step description]

[command]
\`\`\`

---

## References

- GitHub Issue: [owner/repo#NN](https://github.com/owner/repo/issues/NN) — [description]
- Related incident: [Title](filename.md)

---

## Reviewers

- @pgmac
```
