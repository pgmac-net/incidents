import os
import re


def on_page_markdown(markdown, page, config, files, **kwargs):
    """Auto-generate incident list on the incidents index page."""
    if page.file.src_path != "incidents/index.md":
        return markdown

    docs_dir = config["docs_dir"]
    incidents_dir = os.path.join(docs_dir, "incidents")

    entries = []
    for fname in sorted(os.listdir(incidents_dir), reverse=True):
        if not fname.endswith(".md") or fname == "index.md":
            continue

        fpath = os.path.join(incidents_dir, fname)
        with open(fpath) as f:
            content = f.read()

        title_match = re.search(r"^#\s+(.+)$", content, re.MULTILINE)
        title = title_match.group(1).strip() if title_match else fname[:-3]

        date_match = re.search(r"\*\*Date:\*\*\s*(.+)", content)
        date = date_match.group(1).strip() if date_match else ""

        slug = fname[:-3]
        suffix = f" — {date}" if date else ""
        entries.append(f"- [{title}]({slug}.md){suffix}")

    if entries:
        return markdown + "\n\n" + "\n".join(entries) + "\n"
    return markdown
