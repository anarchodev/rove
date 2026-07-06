#!/usr/bin/env python3
"""Render the contract markdown into the docs site.

One source, second direction: where gen_docs_reference.py derives the
reference page from the shim JSDoc, this renders the authored contract
docs — `docs/handler-shape.md` and `docs/effect-algebra.md` — into the
docs tenant, so the site's deep content IS the repo contract (whose
```js examples the doc-examples lint compiles and executes). The
curated intro pages (handlers/effects) stay hand-written; these pages
are the full contracts they link into.

Usage:
  python3 scripts/ops/gen_docs_contract.py --apps-dir ~/src/rewind-apps

Writes <apps-dir>/docs/_static/{handler-contract,effect-algebra}.html.
"""

from __future__ import annotations

import argparse
import html
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import docs_site  # noqa: E402

ROVE = pathlib.Path(__file__).resolve().parents[2]

PAGES = [
    ("handler-shape.md", "handler-contract", "Handler contract",
     "The full customer-facing contract for handler modules — activation "
     "kinds, the request/response surface, effects, dispositions, and "
     "what's deliberately gone."),
    ("effect-algebra.md", "effect-algebra", "Effect algebra",
     "The four-primitive model every effect composes from, and the "
     "trigger-scope axes that make replay possible."),
]


def esc(s: str) -> str:
    return html.escape(s, quote=False)


def inline(text: str) -> str:
    """Inline markdown → HTML. Code spans are lifted first so bold/em
    markers inside them stay literal."""
    spans = []

    def stash(m):
        spans.append(f"<code>{esc(m.group(1))}</code>")
        return f"\x00{len(spans) - 1}\x00"

    text = re.sub(r"`([^`]+)`", stash, text)
    text = esc(text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    return re.sub(r"\x00(\d+)\x00", lambda m: spans[int(m.group(1))], text)


def anchor(text: str) -> str:
    text = re.sub(r"`([^`]+)`", r"\1", text)
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def render_md(md: str):
    """→ (body_html, toc:[(level, text, anchor)], lede)."""
    out, toc = [], []
    lines = md.split("\n")
    i, n = 0, len(lines)
    para: list[str] = []
    lede = None

    def flush_para():
        nonlocal lede
        if para:
            p = inline(" ".join(para))
            if lede is None:
                lede = p
            else:
                out.append(f"<p>{p}</p>")
            para.clear()

    while i < n:
        line = lines[i]

        if line.startswith("```"):
            flush_para()
            lang = line[3:].strip()
            block = []
            i += 1
            while i < n and not lines[i].startswith("```"):
                block.append(lines[i])
                i += 1
            i += 1
            out.append(f"<pre><code>{esc(chr(10).join(block))}</code></pre>")
            _ = lang
            continue

        m = re.match(r"(#{1,4}) (.*)", line)
        if m:
            flush_para()
            level = len(m.group(1))
            text = m.group(2)
            if level == 1:
                i += 1
                continue  # page h1 comes from the site chrome
            a = anchor(text)
            toc.append((level, text, a))
            out.append(f'<h{level} id="{a}">{inline(text)}</h{level}>')
            i += 1
            continue

        if line.startswith(">"):
            flush_para()
            quote = []
            while i < n and lines[i].startswith(">"):
                quote.append(lines[i][1:].lstrip())
                i += 1
            paras = [q for q in re.split(r"\n\s*\n", "\n".join(quote)) if q.strip()]
            body = "".join(f"<p>{inline(p.replace(chr(10), ' '))}</p>" for p in paras)
            out.append(f'<div class="note">{body}</div>')
            continue

        if re.match(r"\|.*\|\s*$", line):
            flush_para()
            rows = []
            while i < n and re.match(r"\|.*\|\s*$", lines[i]):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                rows.append(cells)
                i += 1
            out.append("<table>")
            header = True
            for r_i, cells in enumerate(rows):
                if all(re.fullmatch(r":?-{2,}:?", c) for c in cells):
                    header = False
                    continue
                tag = "th" if header and r_i == 0 else "td"
                out.append("<tr>" + "".join(f"<{tag}>{inline(c)}</{tag}>" for c in cells) + "</tr>")
            out.append("</table>")
            continue

        m = re.match(r"(\s*)([-*]|\d+\.) (.*)", line)
        if m and not re.match(r"\*\*", line.strip()):
            flush_para()
            ordered = m.group(2)[0].isdigit()
            tag = "ol" if ordered else "ul"
            items = []
            while i < n:
                mi = re.match(r"(\s*)([-*]|\d+\.) (.*)", lines[i])
                if mi:
                    items.append(mi.group(3))
                    i += 1
                elif lines[i].startswith(("  ", "\t")) and lines[i].strip() and items:
                    items[-1] += " " + lines[i].strip()  # hanging continuation
                    i += 1
                else:
                    break
            out.append(f"<{tag}>" + "".join(f"<li>{inline(it)}</li>" for it in items) + f"</{tag}>")
            continue

        if re.fullmatch(r"-{3,}", line.strip()):
            flush_para()
            out.append("<hr>")
            i += 1
            continue

        if not line.strip():
            flush_para()
            i += 1
            continue

        para.append(line.strip())
        i += 1

    flush_para()
    return "\n".join(out), toc, lede or ""


def page_html(slug: str, title: str, description: str, body: str, toc, lede: str) -> str:
    toc_html = " · ".join(
        f'<a href="#{a}"><code>{esc(re.sub(r"`", "", t))}</code></a>'
        for lvl, t, a in toc if lvl == 2
    )
    return (
        docs_site.page_open(
            title=title.lower(), description=html.escape(description),
            active=f"/{slug}", kicker="Contract", h1=esc(title), lede=lede)
        + f"  <p>{toc_html}</p>\n" + body
        + docs_site.page_close(f"rendered from docs/{esc(slug)}.md — the repo contract is the source")
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apps-dir", type=pathlib.Path, required=True)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    for src_name, slug, title, desc in PAGES:
        md = (ROVE / "docs" / src_name).read_text()
        body, toc, lede = render_md(md)
        if len(toc) < 5:
            sys.exit(f"gen_docs_contract: {src_name}: only {len(toc)} headings — renderer regression?")
        page = page_html(slug, title, desc, body, toc, lede)
        dest = args.apps_dir / "docs" / "_static" / f"{slug}.html"
        if args.check:
            if not dest.exists() or dest.read_text() != page:
                sys.exit(f"gen_docs_contract: {dest} is stale — re-run the generator")
            print(f"gen_docs_contract: {dest} is current")
        else:
            dest.write_text(page)
            print(f"gen_docs_contract: wrote {dest} ({len(toc)} headings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
