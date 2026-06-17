# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
mise run install        # create venv and install dependencies (run once)
mise run serve          # local dev server at http://localhost:8000 with live reload
mise run build          # build static site
mise run build-strict   # strict build — matches CI; use before committing
```

CI runs `mkdocs build --strict` on every PR. Warnings become errors.

## Two Build Targets

| Config | Site URL | Nav |
|--------|----------|-----|
| `mkdocs.yml` | `https://macro.int.pgmac.net/incidents/` | Explicit — sidebar only shows listed files |
| `incidents-mkdoc.yml` | `https://incidents.pgmac.net.au/` | Auto-discovered — all files appear in sidebar |

New PIRs and runbooks **do not** need to be added to `mkdocs.yml` nav — they're reachable via links from the index tables and appear automatically on the GitHub Pages build (`incidents-mkdoc.yml`). Add them to `mkdocs.yml` nav only if sidebar visibility on the internal site matters.

## Adding a PIR

1. Filename: `src/incidents/YYYY-MM-DD-<slug>.md`
2. Add row to top of `src/incidents/index.md` (newest-first)
3. Follow `src/doc-templates/pir-template.md` — read it before writing; it contains section-by-section guidance
4. Use the `/create-pir` skill for the full automated flow (Infinite How's analysis, Linear tickets, runbook evaluation, commit, PR)

## Adding a Runbook

1. Filename: `src/runbooks/<service>-<failure-description>.md`
2. Add row to `src/runbooks/index.md`
3. Cross-link from the PIR's References section
4. Follow `src/doc-templates/runbook-template.md` — covers simple pattern (one failure mode) and multi-mode pattern (same symptom, multiple root causes)

## Markdown Gotchas

**Nested lists under ordered items require 4-space indent** — MkDocs Material does not render 3-space indented sub-items as nested:

```markdown
1. **Item title**
    - nested bullet   ← 4 spaces, renders correctly
    - nested bullet

1. **Item title**
   - nested bullet   ← 3 spaces, renders as flat continuation text
```

## Source Layout

```
src/
  index.md                  # site home page
  incidents/
    index.md                # incidents table (update when adding PIRs)
    YYYY-MM-DD-<slug>.md    # PIR documents
  runbooks/
    index.md                # runbooks table (update when adding runbooks)
    <service>-<desc>.md     # runbook documents
  doc-templates/
    pir-template.md         # PIR template with section guidance
    runbook-template.md     # runbook template (simple + multi-mode patterns)
```

## Branch and PR Conventions

- Branch prefix: `docs/pir-<slug>` for PIRs, `docs/<description>` for everything else
- Never commit directly to `main`
- PR title format: `docs(pir): <title> (<primary-linear-ticket>)` or `docs(<scope>): <description>`
