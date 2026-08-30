---
title: Home
render_macros: true
---

# Post-Incident Reviews

What broke on the pvek8s homelab cluster, why it broke, and how it was fixed.
Every incident here is a real outage with a real recovery — written up so the
next person hitting it, usually future-me, does not have to rediscover it.

<div class="home-grid">
  <a class="home-card" href="incidents/" style="--card-hue: var(--sect-incidents); --card-icon: var(--icon-incidents);">
    <span class="home-card__title">Incidents</span>
    <span class="home-card__desc">{{ section_count('incidents') }} reviews — what went wrong, and the causal chain behind it</span>
  </a>
  <a class="home-card" href="runbooks/" style="--card-hue: var(--sect-runbooks); --card-icon: var(--icon-runbooks);">
    <span class="home-card__title">Runbooks</span>
    <span class="home-card__desc">{{ section_count('runbooks') }} procedures — recover a known failure mode, cold</span>
  </a>
  <a class="home-card" href="doc-templates/" style="--card-hue: var(--sect-doc-templates); --card-icon: var(--icon-doc-templates);">
    <span class="home-card__title">Templates</span>
    <span class="home-card__desc">{{ section_count('doc-templates') }} templates — start a new PIR or runbook</span>
  </a>
  <a class="home-card" href="tags/" style="--card-hue: var(--sect-tags); --card-icon: var(--icon-tags);">
    <span class="home-card__title">Tags</span>
    <span class="home-card__desc">Browse by node, service or technology</span>
  </a>
</div>

## Recent incidents

{{ recent_incidents(5) }}

[All incidents](incidents/){ .md-button }

## About this site

Incidents are discovered and communicated through my
[Nagios status page](https://statuspage.pgmac.net.au/); these documents are the
detail behind those alerts. Live incidents are worked with the `/start-incident`
skill, which opens a tracking issue the moment triage starts so the timeline
below is captured as it happens rather than reconstructed afterward.

A post-incident review is not a blame document. Each one exists to extract the
maximum learning from a failure: what the causal chain actually was, which
monitoring gap let it run undetected, and what concrete work came out of it.
Every PIR ends with trackable action items. If an incident produced none, it
was either trivial or not investigated deeply enough.

Severity is graded **P1** (cluster-wide outage) through **P4** (minor, contained).

??? contributing "Contributing — writing a PIR"

    1. Name the file `YYYY-MM-DD-brief-description.md`
    2. Put it in `src/incidents/` — the nav discovers it automatically, newest first
    3. Add a row to the top of [the incidents index](incidents/)
    4. Follow the [PIR structure template](doc-templates/pir-template.md), which explains
       what belongs in each section and why
    5. Frontmatter must carry `title`, `date`, `severity`, `resolution`, `duration` and
       `impact` — the build fails on a missing or invalid severity

    The `/create-pir` skill from
    [pgmac-net/claude-plugins](https://github.com/pgmac-net/claude-plugins) automates the
    whole flow: root cause analysis, runbook evaluation, GitHub Issues, commit and PR. If
    the incident was worked with `/start-incident`, its tracking issue is read as the
    primary source instead of reconstructing the timeline from conversation alone.

??? contributing "Contributing — writing a runbook"

    Write a runbook once a failure is understood well enough that someone could follow
    the recovery cold.

    1. Name it `<service>-<failure-description>.md`, e.g. `calico-cni-unauthorized.md`
    2. Put it in `src/runbooks/`
    3. Add a row to [the runbooks index](runbooks/)
    4. Follow the [runbook template](doc-templates/runbook-template.md) — it covers both the
       simple pattern and the multi-mode pattern for one symptom with several root causes
    5. Cross-link the PIR that documented the failure

    Prefer extending an existing runbook with a new failure mode over creating a new file
    when the observable symptom is the same.
