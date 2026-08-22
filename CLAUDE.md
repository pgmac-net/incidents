# CLAUDE.md

MkDocs site of PIRs and runbooks. Contents, commands, skills, and contribution steps: `README.md`. `mise run build-strict` before committing — CI runs `mkdocs build --strict` and warnings become errors.

## Gotchas

- **Three configs**: `mkdocs-base.yml` holds everything shared; `mkdocs.yml` (internal, `macro.int.pgmac.net/incidents/`) and `incidents-mkdoc.yml` (public, `incidents.pgmac.net.au`) are `INHERIT` plus their own `site_url`/`site_dir`. Change the theme in the base file — editing one target only is how the two sites drift. CI strict-builds both.
- **Nav is auto-discovered** — no `nav:` block anywhere. Order comes from `.nav.yml` files (`mkdocs-awesome-nav`); incidents sort newest-first. New PIRs and runbooks appear automatically.
- **PIR metadata is frontmatter, not prose** — `title`, `date`, `severity`, `resolution`, `duration`, `impact`. `main.py` fails the build on a missing field or a severity outside `P1`–`P4`. The header block under the H1 is rendered; don't write it by hand. Contract: `src/doc-templates/pir-template.md`, rationale: `src/decisions.md`.
- **Never use `status:` in frontmatter** — it's reserved by Material, maps to an `extra.status` icon, and silently puts a marker on every nav entry *without failing the build*. Use `resolution:`. `main.py` rejects `status` to make it loud.
- **`title:` is the nav label, not the heading** — short and date-prefixed. Without it the sidebar fills with identical `Post Incident Review: …` entries.
- **Macros are opt-in** (`render_by_default: false`). Two documents quote Kubernetes CSI errors containing literal `{{ }}`, which Jinja would try to evaluate. Add `render_macros: true` to a page only if it needs `recent_incidents()` or `section_count()`.
- **Theme changes need a visual check.** Several bugs here — the `status` nav marker, an unreadable dark-mode button, a `--sect-hue` bound on the wrong element — all built cleanly and were only visible in a rendered page.
- **Nested lists under ordered items need 4-space indent** — MkDocs Material renders 3-space indented sub-items as flat continuation text, not a nested list.
- **`docs/` in this repo is build output** (GitHub Pages), not a source docs directory — source lives in `src/`, and `docs/` is gitignored.
- Branch prefix: `docs/pir-<slug>` for PIRs, `docs/<description>` otherwise. Never commit directly to `main`.
