# incidents

Post-incident reviews (PIRs) and operational runbooks for the pgmac homelab Kubernetes infrastructure.

Published at **https://incidents.pgmac.net.au/**

## Contents

- **[Incidents](src/incidents/)** — PIRs documenting what went wrong, why, and how it was fixed
- **[Runbooks](src/runbooks/)** — Step-by-step recovery procedures for known failure modes

## Local Development

Requires [mise](https://mise.jdx.dev/) and Python 3.13.

```bash
mise run install   # create venv and install dependencies
mise run serve     # serve at http://localhost:8000 with live reload
mise run build     # build static site
mise run build-strict  # strict build (matches CI)
```

## Skills

PIRs and runbooks are authored with Claude Code / OpenCode skills from
[pgmac-net/claude-plugins](https://github.com/pgmac-net/claude-plugins).

| Skill              | Purpose                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------- |
| `/create-pir`      | Generate a post-incident review: Infinite How's analysis, runbook evaluation, GitHub Issues, commit + PR |
| `/pickup-ticket`   | Work a GitHub Issue end-to-end: read, grill, plan, implement, PR, document                               |
| `/grilling`        | Stress-test plans and decisions one question at a time                                                   |
| `/domain-modeling` | Build and sharpen domain model: glossary, ADRs, terminology                                              |

## Contributing

### New PIR

1. Name: `YYYY-MM-DD-brief-description.md`
2. Location: `src/incidents/`
3. Add a row to the top of `src/incidents/index.md` (newest-first)
4. Follow `src/doc-templates/pir-template.md`
5. Use the `/create-pir` skill to automate the full flow — see [Skills](#skills) above

### New Runbook

1. Name: `<service>-<failure-description>.md`
2. Location: `src/runbooks/`
3. Add a row to `src/runbooks/index.md`
4. Follow `src/doc-templates/runbook-template.md` (simple or multi-mode pattern)
5. Cross-link from the PIR that documented the failure
6. The `/create-pir` skill evaluates runbook needs during PIR generation — see [Skills](#skills) above

### CI

- `validate.yml` — MkDocs strict build on every PR
- `deploy.yml` — builds and deploys to GitHub Pages on merge to `main`
