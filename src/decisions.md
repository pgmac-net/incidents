---
title: Decisions
tags:
  - adr
---

# Architecture Decisions

Decisions about how this site works that were expensive to reach and would be
expensive to reverse. Recorded so the reasoning survives the conversation that
produced it.

---

## ADR-0001 — PIR metadata lives in frontmatter, not prose

**Date:** 2026-08-22 · **Status:** Accepted · pgmac-net/incidents#72

### Context

Every PIR opened with four bold lines under its H1:

```markdown
**Date:** 2026-08-15
**Duration:** ~2d 16h 38m
**Severity:** High (permanent loss of ~2.7 days of recorder history; ...)
**Status:** Resolved
```

Nothing could read them. The same facts had to be maintained by hand in at least
two more places — the incidents index table and, once a landing page existed, a
recent-incidents list — with nothing to detect a disagreement. The severity word
also carried its justification in a parenthetical, so it was simultaneously a
category and a sentence.

### Decision

Incident metadata moves into YAML frontmatter: `title`, `date`, `severity`,
`resolution`, `duration`, `impact`. The header block below the title is rendered
by `overrides/partials/pir-meta.html`. The index table and the home page's
recent-incidents list are generated from the same frontmatter. `main.py`
validates it at build time.

The field is named **`resolution`, not `status`**. `status` is reserved by
Material for MkDocs: it maps front matter to an `extra.status` icon and renders
a marker beside every nav entry. Critically, using it **does not fail the
build** — it silently decorates the navigation, which is why `main.py` rejects
the key explicitly.

### Consequences

- Metadata cannot disagree between a PIR and the pages listing it.
- A malformed or un-migrated PIR fails `mkdocs build --strict` rather than
  publishing a page with no severity badge.
- All 23 existing PIRs required migration, and `/create-pir` had to be updated
  to match — see pgmac-net/claude-plugins#8.
- Frontmatter is now a contract. Adding a field the templates do not render is
  harmless; removing one that they do is a build failure.

### Alternatives considered

**Parse the bold prose at build time.** No file changes, but one reworded line
and an incident silently drops out of the recent list or loses its badge —
failing quietly, which is the failure mode this whole change exists to remove.

**Keep the prose and duplicate it into frontmatter.** Smallest edit, but the
same fact in two places per file is 23 chances to disagree.

---

## ADR-0002 — Severity is graded P1–P4

**Date:** 2026-08-22 · **Status:** Accepted · pgmac-net/incidents#72

### Context

Severity used `Critical` / `High` / `Medium` / `Low`, except for one PIR that
used `P1` and another that used `P2`. The vocabulary was never enforced, so it
had already drifted within 23 documents.

Separately, the site's chrome was red. On a site whose content is severity-graded,
spending the loudest colour on navigation meant red signalled "pgmac" rather than
"this hurt".

### Decision

Severity is `P1`, `P2`, `P3` or `P4`. `main.py` fails the build on anything else.
Existing PIRs migrated as `Critical` → `P1`, `High` → `P2`, `Medium` → `P3`.
`P4` is new and currently unused; it gives the scale a floor rather than forcing
genuinely minor events up into `P3`.

Chrome moved to a neutral graphite, and the **entire warm end of the palette is
reserved for severity**. This is also why section identity is indigo, teal,
violet and slate rather than the amber originally proposed for Incidents — amber
is the natural `P3`, and a section hue colliding with a severity level on the
page where severity matters most defeats the point of reserving it.

### Consequences

- Severity is machine-readable, so badges, sorting and validation are possible.
- A typo fails CI instead of rendering an unstyled badge.
- Action-item priority deliberately stays on High / Medium / Low, because it maps
  to GitHub Issue priority labels. Priority ranks follow-up work; severity grades
  the incident. A `P1` can produce a Low-priority action and vice versa.
- Severity is fixed vocabulary now. Adding a level means updating `main.py`, the
  stylesheet's badge colours, and the PIR template together.

### Alternatives considered

**Keep Critical/High/Medium/Low and just enforce it.** Would have solved the
drift without touching 23 files, but leaves severity sharing a vocabulary with
action-item priority — the same four words meaning two different things on one
page.

**Free-text severity with a neutral fallback badge.** Most flexible, but badge
colour stops being reliable and inconsistency compounds silently, which is how
the original drift happened.
