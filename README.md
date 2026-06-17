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

## Contributing

### New PIR

1. Name: `YYYY-MM-DD-brief-description.md`
2. Location: `src/incidents/`
3. Add a row to the top of `src/incidents/index.md` (newest-first)
4. Follow `src/doc-templates/pir-template.md`

### New Runbook

1. Name: `<service>-<failure-description>.md`
2. Location: `src/runbooks/`
3. Add a row to `src/runbooks/index.md`
4. Follow `src/doc-templates/runbook-template.md` (simple or multi-mode pattern)
5. Cross-link from the PIR that documented the failure

### CI

- `validate.yml` — MkDocs strict build on every PR
- `deploy.yml` — builds and deploys to GitHub Pages on merge to `main`
