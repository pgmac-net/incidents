# Post-Incident Reviews

Welcome to the internal Post-Incident Review (PIR) documentation site. This site contains detailed analyses of system incidents, root cause investigations, and lessons learned.

## Purpose

Post-incident reviews are critical for:

- **Learning from failures** - Understanding what went wrong and why
- **Preventing recurrence** - Implementing safeguards and preventive measures
- **Improving systems** - Identifying architectural and operational improvements
- **Knowledge sharing** - Building team expertise and institutional memory

## PGMac . Net Service Status

These documents are an artefact to give clarity and detail on incidents discovered and communicated through my [Nagios Status Page](https://statuspage.pgmac.net.au/)

## PIR Structure

Each post-incident review follows a standard structure:

1. **Executive Summary** - High-level overview of the incident
2. **Timeline** - Detailed chronological sequence of events
3. **Root Causes** - Analysis of underlying issues
4. **Impact** - Affected services, duration, and scope
5. **Resolution Steps** - Actions taken to resolve the incident
6. **Verification** - Confirmation of service restoration
7. **Preventive Measures** - Immediate and long-term improvements
8. **Lessons Learned** - Key takeaways and insights
9. **Action Items** - Specific follow-up tasks with owners

## Contributing

### Creating a PIR

1. Use the naming convention: `YYYY-MM-DD-brief-description.md`
2. Place documents in the `src/incidents/` directory — auto-nav picks them up automatically, no `mkdocs.yml` changes needed
3. Add a row to the top of `src/incidents/index.md` (newest-first)
4. Follow the [PIR structure template](doc-templates/pir-template.md) — each section is explained with guidance on what to write and why

### Creating a Runbook

Write a runbook when an incident has a repeatable failure mode with a concrete, step-by-step recovery procedure that an on-call could follow cold.

1. Use a descriptive name: `<service>-<failure-description>.md` (e.g., `calico-cni-unauthorized.md`)
2. Place documents in the `src/runbooks/` directory — auto-nav picks them up automatically
3. Follow the [runbook template](doc-templates/runbook-template.md) — it covers both the simple pattern (one failure mode) and the multi-mode pattern (same symptom, multiple root causes)
4. Consider extending an existing runbook with a new failure mode section instead of creating a new file if the observable symptom is the same

## Navigation

Use the navigation menu to browse incidents by date or search for specific topics using the search functionality.
