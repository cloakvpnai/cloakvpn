#!/usr/bin/env python3
"""Render privacy-policy.md and terms-of-service.md into clean HTML
suitable for hosting at https://cloakvpn.ai/privacy and /terms.

No external deps — uses Python's stdlib for markdown-ish rendering
(handles headings, lists, links, code, paragraphs, em/strong).
Output goes to ./build/ alongside this script.
"""
import os
import re
import sys
import html
import datetime
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE / "build"
OUT.mkdir(exist_ok=True)

TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} · CLOAK VPN</title>
<link rel="canonical" href="https://cloakvpn.ai{path}">
<style>
:root {{
  --gold: #FFD700;
  --green: #1FBE5C;
  --bg: #0a0a0a;
  --fg: #e8e8e8;
  --fg-muted: #999;
  --border: #2a2a2a;
}}
* {{ box-sizing: border-box; }}
html, body {{ margin: 0; padding: 0; }}
body {{
  background: var(--bg);
  color: var(--fg);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", system-ui, sans-serif;
  font-size: 16px;
  line-height: 1.6;
  -webkit-font-smoothing: antialiased;
}}
header {{
  border-bottom: 1px solid var(--border);
  padding: 24px 16px;
  text-align: center;
}}
header .brand {{
  font-family: "New York", Georgia, serif;
  font-weight: 600;
  font-size: 22px;
  letter-spacing: 2px;
  color: var(--gold);
}}
header nav {{
  margin-top: 12px;
  font-size: 14px;
  color: var(--fg-muted);
}}
header nav a {{
  color: var(--fg-muted);
  margin: 0 10px;
  text-decoration: none;
}}
header nav a:hover {{ color: var(--gold); }}
main {{
  max-width: 760px;
  margin: 0 auto;
  padding: 40px 24px 80px;
}}
h1 {{
  font-family: "New York", Georgia, serif;
  font-weight: 600;
  font-size: 32px;
  margin-top: 0;
  letter-spacing: 0.5px;
}}
h2 {{
  font-family: "New York", Georgia, serif;
  font-weight: 600;
  font-size: 22px;
  margin-top: 40px;
  border-bottom: 1px solid var(--border);
  padding-bottom: 6px;
}}
h3 {{
  font-size: 17px;
  margin-top: 28px;
  color: var(--fg);
}}
p, li {{ color: var(--fg); }}
a {{ color: var(--green); text-decoration: underline; text-underline-offset: 2px; }}
a:hover {{ color: var(--gold); }}
ul, ol {{ padding-left: 24px; }}
li {{ margin: 6px 0; }}
code {{
  background: #1a1a1a;
  border: 1px solid var(--border);
  padding: 1px 6px;
  border-radius: 4px;
  font-size: 14px;
  font-family: "SF Mono", Menlo, Consolas, monospace;
}}
strong {{ color: var(--fg); }}
em {{ color: var(--fg); }}
.last-updated {{ color: var(--fg-muted); font-size: 14px; }}
footer {{
  border-top: 1px solid var(--border);
  padding: 20px 16px;
  text-align: center;
  color: var(--fg-muted);
  font-size: 13px;
}}
footer a {{ color: var(--fg-muted); text-decoration: none; }}
footer a:hover {{ color: var(--gold); }}
</style>
</head>
<body>
<header>
  <div class="brand">CLOAK VPN</div>
  <nav>
    <a href="/">Home</a>
    <a href="/privacy">Privacy</a>
    <a href="/terms">Terms</a>
    <a href="mailto:support@cloakvpn.ai">Support</a>
  </nav>
</header>
<main>
{body}
</main>
<footer>
  &copy; {year} Neuro AI Studios. CLOAK VPN is a trademark of Neuro AI Studios.<br>
  <a href="/privacy">Privacy Policy</a> · <a href="/terms">Terms of Service</a>
</footer>
</body>
</html>
"""


def md_to_html(md: str) -> str:
    """Minimal markdown renderer covering what our policy docs use:
    headings (#, ##, ###), unordered lists (- ), ordered lists (1.),
    bold (**...**), em (*...*), inline code (`...`), links
    [text](url), paragraphs, line breaks, hr (---). No nested lists,
    no tables, no images — we don't need them."""
    out = []
    lines = md.split("\n")
    i = 0
    in_list = None  # None, "ul", or "ol"

    def close_list():
        nonlocal in_list
        if in_list:
            out.append(f"</{in_list}>")
            in_list = None

    def inline(s: str) -> str:
        s = html.escape(s)
        # links
        s = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', s)
        # bold
        s = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', s)
        # italics
        s = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', r'<em>\1</em>', s)
        # inline code
        s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
        # auto-link bare URLs (not already in <a>)
        s = re.sub(r'(?<!href=")(?<!&lt;)(https?://\S+?)(?=[\s.,;)]|$)', r'<a href="\1">\1</a>', s)
        return s

    while i < len(lines):
        line = lines[i].rstrip()
        # Headings
        if line.startswith("# "):
            close_list()
            out.append(f"<h1>{inline(line[2:])}</h1>")
        elif line.startswith("## "):
            close_list()
            out.append(f"<h2>{inline(line[3:])}</h2>")
        elif line.startswith("### "):
            close_list()
            out.append(f"<h3>{inline(line[4:])}</h3>")
        # Horizontal rule
        elif line.strip() == "---":
            close_list()
            out.append("<hr>")
        # Unordered list
        elif re.match(r'^[-*] ', line):
            if in_list != "ul":
                close_list()
                out.append("<ul>")
                in_list = "ul"
            out.append(f"  <li>{inline(line[2:])}</li>")
        # Ordered list
        elif re.match(r'^\d+\. ', line):
            if in_list != "ol":
                close_list()
                out.append("<ol>")
                in_list = "ol"
            stripped = re.sub(r'^\d+\. ', '', line)
            out.append(f"  <li>{inline(stripped)}</li>")
        # Blank line — paragraph break
        elif line.strip() == "":
            close_list()
        # Regular paragraph
        else:
            close_list()
            # Greedy: gather subsequent non-blank, non-special lines
            buf = [line]
            while (i + 1 < len(lines)
                   and lines[i + 1].strip() != ""
                   and not lines[i + 1].startswith("#")
                   and not lines[i + 1].startswith("- ")
                   and not lines[i + 1].startswith("* ")
                   and not re.match(r'^\d+\. ', lines[i + 1])
                   and lines[i + 1].strip() != "---"):
                i += 1
                buf.append(lines[i].rstrip())
            out.append(f"<p>{inline(' '.join(buf))}</p>")
        i += 1
    close_list()
    return "\n".join(out)


def build(md_path: Path, html_path: Path, title: str, url_path: str):
    md = md_path.read_text()
    body = md_to_html(md)
    page = TEMPLATE.format(
        title=title,
        body=body,
        path=url_path,
        year=datetime.datetime.now().year,
    )
    html_path.write_text(page)
    print(f"  wrote {html_path}  ({html_path.stat().st_size} bytes)")


# Landing page (lightweight redirector + intro)
LANDING = """# CLOAK VPN

A post-quantum VPN combining WireGuard with Rosenpass key-exchange. Your traffic is protected against both classical and quantum-capable adversaries.

## Get Cloak VPN

Coming soon to the iOS App Store.

## Documents

- [Privacy Policy](/privacy)
- [Terms of Service](/terms)

## Contact

`support@cloakvpn.ai`
"""

if __name__ == "__main__":
    build(HERE / "privacy-policy.md", OUT / "privacy.html",
          "Privacy Policy", "/privacy")
    build(HERE / "terms-of-service.md", OUT / "terms.html",
          "Terms of Service", "/terms")
    # Landing page (in-memory markdown)
    landing_md_path = OUT / "_landing.md"
    landing_md_path.write_text(LANDING)
    build(landing_md_path, OUT / "index.html", "CLOAK VPN", "/")
    landing_md_path.unlink()
    print("Done.")
