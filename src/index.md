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

When creating a new PIR document:

1. Use the naming convention: `YYYY-MM-DD-brief-description.md`
2. Place documents in the `src/incidents/` directory
3. Update the `mkdocs.yml` navigation section
4. Follow the [PIR structure template](incidents/pir-template.md) — each section is explained with guidance on what to write and why
5. Include relevant technical details, commands, and verification steps

## Navigation

Use the navigation menu to browse incidents by date or search for specific topics using the search functionality.
