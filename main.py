"""Build-time generation and validation for the incidents site.

Two jobs:

1. Generate the home page's recent-incidents list and the section counts from
   PIR frontmatter, so nothing on the front page has to be maintained by hand
   against facts that already live in the documents.

2. Validate incident frontmatter, so a malformed or un-migrated PIR fails the
   build rather than rendering as a page with no severity badge. This is the
   gate that `/create-pir` has to satisfy — see pgmac-net/claude-plugins#8.

Macro rendering is opt-in (`render_by_default: false` in mkdocs-base.yml).
Two incident records quote Kubernetes CSI errors containing literal `{{ }}`
(`already mounted at more than one place: {{   }}`), which Jinja would try to
evaluate and fail on. Only `src/index.md`, which carries `render_macros: true`,
is rendered. Validation is unaffected: pre-macro functions run for every page
whether or not that page is rendered.
"""

from html import escape
from pathlib import Path

import yaml
from mkdocs.exceptions import PluginError

SEVERITIES = ("P1", "P2", "P3", "P4")
REQUIRED = ("title", "date", "severity", "duration")

SRC = Path(__file__).parent / "src"
INCIDENTS = SRC / "incidents"


def _frontmatter(path: Path) -> dict:
    """Parse a document's YAML frontmatter. Returns {} when there is none."""
    text = path.read_text(encoding="utf8")
    if not text.startswith("---"):
        return {}
    _, _, rest = text.partition("---\n")
    block, sep, _ = rest.partition("\n---")
    if not sep:
        return {}
    return yaml.safe_load(block) or {}


def _incident_files() -> list[Path]:
    return [p for p in sorted(INCIDENTS.glob("*.md")) if p.stem != "index"]


def define_env(env):
    """Register the macros available to pages that opt into rendering."""

    @env.macro
    def recent_incidents(count: int = 5) -> str:
        """Render the most recent incidents, newest first.

        Reads the documents rather than the nav, so the list cannot drift from
        the pages and does not depend on nav ordering being configured
        correctly elsewhere.
        """
        rows = []
        for path in _incident_files():
            meta = _frontmatter(path)
            if not meta.get("date"):
                continue
            rows.append((str(meta["date"]), meta, path))
        rows.sort(key=lambda r: r[0], reverse=True)

        items = []
        for date, meta, path in rows[:count]:
            severity = str(meta.get("severity", "")).strip()
            title = str(meta.get("title", path.stem))
            # Titles are date-prefixed for the sidebar; the date has its own
            # column here, so drop the duplicate.
            label = title[len(date) :].strip() if title.startswith(date) else title
            badge = (
                f'<span class="sev sev--{severity.lower()}">{escape(severity)}</span>'
                if severity
                else ""
            )
            items.append(
                "<li>"
                f'<span class="recent-list__date">{escape(date)}</span>'
                f"{badge}"
                f'<a href="incidents/{escape(path.stem)}/">{escape(label)}</a>'
                "</li>"
            )
        return '<ul class="recent-list">' + "".join(items) + "</ul>"

    @env.macro
    def section_count(section: str) -> int:
        """Number of documents in a section, excluding its index page."""
        directory = SRC / section
        if not directory.is_dir():
            raise PluginError(f"section_count: no such section '{section}'")
        return len([p for p in directory.glob("*.md") if p.stem != "index"])


def on_pre_page_macros(env) -> None:
    """Validate incident frontmatter.

    Runs for every page, including pages that are not macro-rendered, because
    pre-macro functions are invoked before the render decision is made.
    """
    page = env.page
    src = page.file.src_path.replace("\\", "/")
    if not src.startswith("incidents/") or Path(src).stem == "index":
        return

    meta = page.meta or {}

    missing = [key for key in REQUIRED if not meta.get(key)]
    if missing:
        raise PluginError(
            f"{src}: incident is missing required frontmatter {missing}. "
            "PIRs must carry title, date, severity and duration — see "
            "src/doc-templates/pir-template.md."
        )

    severity = str(meta["severity"]).strip()
    if severity not in SEVERITIES:
        raise PluginError(
            f"{src}: severity {severity!r} is not one of {'|'.join(SEVERITIES)}. "
            "The scale changed from Critical/High/Medium/Low: "
            "Critical maps to P1, High to P2, Medium to P3."
        )

    # `status` is reserved by Material — it maps to an extra.status icon and
    # renders a marker beside every nav entry. Catch it here, because using it
    # does not fail the build; it just quietly decorates the nav.
    if "status" in meta:
        raise PluginError(
            f"{src}: use 'resolution', not 'status'. 'status' is reserved by "
            "Material for MkDocs and renders a status marker in the nav."
        )
