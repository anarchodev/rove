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
import hashlib
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


# Digest of the composed pages, committed HERE in rove.
#
# The freshness problem is cross-repo: the artifact lives in rewind-apps, so a
# rove-side check would need that checkout to compare against — and a gate that
# depends on a sibling clone either does not run or is not a gate. But `build()`
# composes the expected pages from rove sources ALONE, so recording their digest
# here makes the contract checkable without leaving the repo: edit
# `docs/handler-shape.md` or `docs/effect-algebra.md` and the digest moves, and
# the gate says so at the moment of the change rather than whenever someone next
# happens to publish.
#
# That timing is the whole point. These pages are GENERATED at publish time, so
# a stale mirror is invisible: the docs site gets correct HTML from the publish
# run while the committed copy rots, and the drift surfaces only as a customer
# reading a contract the engine does not implement.
#
# The two halves catch different drift and both are needed:
#   - this digest  — a rove source doc moved and rewind-apps has not been told.
#                    Runs on every `zig build test`.
#   - `--check`    — the committed page does not match the rove commit
#                    rewind-apps pins. Runs against an apps checkout.
DIGEST_FILE = ROVE / "scripts" / "ops" / "docs-contract.sha256"


def build() -> list[tuple[str, str]]:
    """(slug, rendered page) for every contract page, from rove sources alone."""
    pages = []
    for src_name, slug, title, desc in PAGES:
        md = (ROVE / "docs" / src_name).read_text()
        body, toc, lede = render_md(md)
        if len(toc) < 5:
            sys.exit(f"gen_docs_contract: {src_name}: only {len(toc)} headings — renderer regression?")
        pages.append((slug, page_html(slug, title, desc, body, toc, lede)))
    return pages


def digest(pages: list[tuple[str, str]]) -> str:
    h = hashlib.sha256()
    for slug, page in pages:
        h.update(slug.encode("utf-8"))
        h.update(b"\0")
        h.update(page.encode("utf-8"))
        h.update(b"\0")
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apps-dir", type=pathlib.Path)
    ap.add_argument("--check", action="store_true",
                    help="fail (exit 1) if the committed output is stale instead of writing")
    ap.add_argument("--verify", action="store_true",
                    help="fail (exit 1) if the source docs no longer match the "
                         "recorded digest — the rove-side gate; needs no apps checkout")
    ap.add_argument("--record", action="store_true",
                    help="rewrite the recorded digest; run this WITH regenerating "
                         "the pages in rewind-apps, never instead of it")
    args = ap.parse_args()

    pages = build()

    if args.verify:
        want = DIGEST_FILE.read_text(encoding="utf-8").split()[0] if DIGEST_FILE.exists() else ""
        have = digest(pages)
        if want != have:
            print(
                f"STALE: the contract source docs changed.\n"
                f"  recorded {want or '(none)'}\n"
                f"  current  {have}\n"
                f"\n"
                f"`docs/_static/handler-contract.html` and `effect-algebra.html` in\n"
                f"rewind-apps are GENERATED from docs/handler-shape.md and\n"
                f"docs/effect-algebra.md. They do not update themselves, and nothing\n"
                f"downstream notices — a publish regenerates them in flight, so the\n"
                f"site looks right while the committed copies rot and the repo stops\n"
                f"being the record of what customers are told. Propagate the change:\n"
                f"\n"
                f"  python3 scripts/ops/gen_docs_contract.py --apps-dir <rewind-apps>\n"
                f"  python3 scripts/ops/gen_docs_contract.py --record\n"
                f"\n"
                f"then commit the regenerated pages in rewind-apps AND the digest\n"
                f"here, and bump the `web` pin. Recording without regenerating\n"
                f"defeats the check.",
                file=sys.stderr,
            )
            return 1
        print(f"fresh: contract sources match the recorded digest ({have[:16]}…)")
        return 0

    if args.record:
        DIGEST_FILE.write_text(digest(pages) + "  handler-contract.html effect-algebra.html\n",
                               encoding="utf-8")
        print(f"recorded {digest(pages)} → {DIGEST_FILE}")
        return 0

    if not args.apps_dir:
        sys.exit("gen_docs_contract: --apps-dir is required to write or --check")

    for slug, page in pages:
        dest = args.apps_dir / "docs" / "_static" / f"{slug}.html"
        if args.check:
            if not dest.exists() or dest.read_text() != page:
                sys.exit(f"gen_docs_contract: {dest} is stale — re-run the generator")
            print(f"gen_docs_contract: {dest} is current")
        else:
            dest.write_text(page)
            print(f"gen_docs_contract: wrote {dest}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
