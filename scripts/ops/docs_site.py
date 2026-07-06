"""Shared chrome for the generated docs-site pages.

One nav for every generated page (gen_docs_reference.py +
gen_docs_contract.py import this). The four hand-written pages carry a
copy — keep them in sync when a page is added (the hand-written set is
small and changes rarely; the generated set regenerates on publish).
"""

NAV_ITEMS = [
    ("Start", [("/", "Overview"), ("/quickstart", "Quickstart")]),
    ("Reference", [("/handlers", "Handlers"),
                   ("/effects", "Effects &amp; replay"),
                   ("/reference", "Globals reference")]),
    ("Contracts", [("/handler-contract", "Handler contract"),
                   ("/effect-algebra", "Effect algebra")]),
    ("More", [("https://rewindjs.com", "rewindjs.com")]),
]

FAVICON = ("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' "
           "viewBox='0 0 16 16'%3E%3Crect width='16' height='16' rx='3' "
           "fill='%2311111b'/%3E%3Cpath d='M9 4 L4.5 8 L9 12 Z M13 4 L8.5 8 "
           "L13 12 Z' fill='%23cba6f7'/%3E%3C/svg%3E")


def nav_html(active: str) -> str:
    out = []
    for group, items in NAV_ITEMS:
        out.append(f'    <div class="group">{group}</div>')
        for href, label in items:
            cls = ' class="active"' if href == active else ""
            out.append(f'    <a href="{href}"{cls}>{label}</a>')
    return "\n".join(out)


def page_open(title: str, description: str, active: str, kicker: str,
              h1: str, lede: str) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>rewind.js docs — {title}</title>
<meta name="description" content="{description}">
<link rel="icon" href="{FAVICON}">
<link rel="stylesheet" href="/docs.css">
</head>
<body>
<div class="wrap">
<aside>
  <a class="brand" href="/"><span class="glyph">◀◀&hairsp;</span>rewind<b>.js</b></a>
  <div class="tagline">documentation</div>
  <nav>
{nav_html(active)}
  </nav>
</aside>
<main>
<article>
  <div class="kicker">{kicker}</div>
  <h1>{h1}</h1>
  <p class="lede">{lede}</p>
"""


def page_close(footer: str) -> str:
    return f"""
  <footer>© 2026 Loop46, Inc. · rewind.js · {footer}</footer>
</article>
</main>
</div>
</body>
</html>
"""
