# CLAUDE.md

MkDocs site of PIRs and runbooks. Contents, commands, skills, and contribution steps: `README.md`. `mise run build-strict` before committing — CI runs `mkdocs build --strict` and warnings become errors.

## Gotchas

- **Two build targets**: `mkdocs.yml` (internal, `macro.int.pgmac.net/incidents/`, explicit nav) vs `incidents-mkdoc.yml` (public, `incidents.pgmac.net.au`, auto-discovered nav). New PIRs/runbooks don't need adding to `mkdocs.yml` nav — they're reachable via index links and appear automatically on the public build. Only add to nav if internal sidebar visibility matters.
- **Nested lists under ordered items need 4-space indent** — MkDocs Material renders 3-space indented sub-items as flat continuation text, not a nested list.
- **`docs/` in this repo is build output** (GitHub Pages), not a source docs directory — source lives in `src/`.
- Branch prefix: `docs/pir-<slug>` for PIRs, `docs/<description>` otherwise. Never commit directly to `main`.
