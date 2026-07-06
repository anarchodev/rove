#!/usr/bin/env python3
"""Generate the docs site's reference page from the shim JSDoc.

One source: `src/js/globals/*.js` — the same JSDoc that documents the
shims in-repo (and whose @example blocks the executable-examples lint
compiles + runs) renders the customer reference at docs.rewindjs.com.
The site cannot lag the shims because it IS the shims.

Usage:
  python3 scripts/ops/gen_docs_reference.py --apps-dir ~/src/rewind-apps

Writes <apps-dir>/docs/_static/reference.html. Deterministic output
(curated section order, source member order) so diffs are reviewable.
Invoked automatically by publish_firstparty.py via the docs tenant's
manifest `generate` hook.
"""

from __future__ import annotations

import argparse
import html
import pathlib
import re
import sys

ROVE = pathlib.Path(__file__).resolve().parents[2]
GLOBALS = ROVE / "src" / "js" / "globals"

# Curated page layout: (group heading, [shim file stems]). A shim absent
# here is skipped (request/http are contract territory — the Handlers
# page); a NEW shim must be added to a group or the generator fails
# loudly below, so the reference can't silently omit surface.
GROUPS = [
    ("Effects & state", ["kv", "after", "next", "stream", "webhook", "email",
                         "scheduler", "schedule", "cron", "retry", "blob",
                         "segments", "browser"]),
    ("Utilities", ["crypto", "jwt", "base64", "textcodec", "urlsearchparams",
                   "console"]),
    ("Identity & federation", ["users", "sessions", "oauth", "oidc",
                               "activitypub"]),
    ("Admin (the __admin__ tenant only)", ["platform"]),
]
SKIPPED = {"request", "http"}  # documented by the Handlers page / contract

# Files whose surface has no @namespace block: section name + one-line
# description fallback (the file header covers the rest in-repo).
BARE_FILES = {
    "cron": ("cron helpers", "Fire-time helpers for durable scheduling."),
    "next": ("next", "The held-connection disposition."),
    "schedule": ("schedule / cron", "Durable, connectionless timers."),
    "textcodec": ("TextEncoder / TextDecoder", "UTF-8 bytes ↔ string."),
    "urlsearchparams": ("URLSearchParams", "Query/form-body parsing."),
}


def parse_jsdoc_blocks(src: str):
    """Yield (block_lines, following_code_line) for each /** … */."""
    lines = src.split("\n")
    i = 0
    while i < len(lines):
        if lines[i].strip().startswith("/**"):
            block = []
            i += 1
            while i < len(lines) and "*/" not in lines[i]:
                text = lines[i].strip()
                block.append(text[1:].lstrip() if text.startswith("*") else text)
                i += 1
            i += 1  # past */
            code = ""
            j = i
            while j < len(lines):
                cand = lines[j].strip()
                if cand and not cand.startswith("//"):
                    code = cand
                    break
                j += 1
            yield block, code
        else:
            i += 1


def split_tags(block):
    """Description lines + [(tag, text)] with continuation lines folded."""
    desc, tags = [], []
    cur = None
    for line in block:
        if line.startswith("@"):
            if cur:
                tags.append(cur)
            parts = line.split(None, 1)
            cur = [parts[0][1:], parts[1] if len(parts) > 1 else ""]
        elif cur:
            cur[1] += "\n" + line
        else:
            desc.append(line)
    if cur:
        tags.append(cur)
    return desc, tags


MEMBER_PATTERNS = [
    re.compile(r"globalThis\.(\w+)\s*="),
    re.compile(r"get\s+(\w+)\s*\("),
    re.compile(r"(\w+)\s*:\s*(?:async\s+)?(?:function)?\s*\("),
    re.compile(r"(?:async\s+)?(\w+)\s*\([^)]*\)\s*\{"),
    re.compile(r"(\w+)\s*:"),
]


def member_name(code: str):
    for pat in MEMBER_PATTERNS:
        m = pat.match(code)
        if m:
            return m.group(1)
    return None


def parse_shim(stem: str):
    """→ list of sections: {name, desc, example, members:[{...}]}"""
    src = (GLOBALS / f"{stem}.js").read_text()
    sections = []
    cur = None
    for block, code in parse_jsdoc_blocks(src):
        desc, tags = split_tags(block)
        tagmap = {}
        params, examples = [], []
        for tag, text in tags:
            if tag == "param":
                params.append(text)
            elif tag == "example":
                examples.append(text.strip("\n"))
            else:
                tagmap.setdefault(tag, text)
        if "namespace" in tagmap:
            cur = {"name": tagmap["namespace"].strip(), "desc": desc,
                   "example": examples[0] if examples else None, "members": []}
            sections.append(cur)
            continue
        name = member_name(code)
        if not name or name.startswith("_"):
            continue
        if cur is None:
            title, fallback = BARE_FILES.get(stem, (stem, ""))
            cur = {"name": title, "desc": [fallback], "example": None,
                   "members": []}
            sections.append(cur)
        cur["members"].append({
            "name": name, "desc": desc, "params": params,
            "returns": tagmap.get("returns"),
            "examples": examples,
        })
    return sections


def param_pieces(p: str):
    """'{type} [name] - desc' → (name, type, optional, desc)."""
    m = re.match(r"(?:\{([^}]*)\}\s*)?(\[?[\w.$]+(?:=[^\]]*)?\]?)\s*-?\s*(.*)",
                 p, re.S)
    if not m:
        return p, "", False, ""
    typ, name, desc = m.group(1) or "", m.group(2), m.group(3)
    opt = name.startswith("[")
    name = name.strip("[]").split("=")[0]
    return name, typ, opt, desc


def signature(member) -> str:
    args = []
    for p in member["params"]:
        name, _typ, opt, _d = param_pieces(p)
        if "." in name:
            continue  # opts.on — folded into the params table
        args.append(name + ("?" if opt else ""))
    return f"{member['name']}({', '.join(args)})"


def esc(s: str) -> str:
    return html.escape(s, quote=False)


def render_prose(lines) -> str:
    """JSDoc prose → HTML: `code` spans, paragraph breaks on blank lines."""
    text = esc("\n".join(lines).strip())
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    paras = [p.replace("\n", " ") for p in re.split(r"\n\s*\n", text) if p.strip()]
    return "".join(f"<p>{p}</p>" for p in paras)


def anchor(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


PAGE_HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>rewind.js docs — reference</title>
<meta name="description" content="Generated reference for every rewind.js handler global — signatures, options, examples — straight from the shipped shims.">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Crect width='16' height='16' rx='3' fill='%2311111b'/%3E%3Cpath d='M9 4 L4.5 8 L9 12 Z M13 4 L8.5 8 L13 12 Z' fill='%23cba6f7'/%3E%3C/svg%3E">
<link rel="stylesheet" href="/docs.css">
</head>
<body>
<div class="wrap">
<aside>
  <a class="brand" href="/"><span class="glyph">◀◀&hairsp;</span>rewind<b>.js</b></a>
  <div class="tagline">documentation</div>
  <nav>
    <div class="group">Start</div>
    <a href="/">Overview</a>
    <a href="/quickstart">Quickstart</a>
    <div class="group">Reference</div>
    <a href="/handlers">Handlers</a>
    <a href="/effects">Effects &amp; replay</a>
    <a href="/reference" class="active">Globals reference</a>
    <div class="group">More</div>
    <a href="https://rewindjs.com">rewindjs.com</a>
  </nav>
</aside>
<main>
<article>
  <div class="kicker">Reference</div>
  <h1>Globals reference</h1>
  <p class="lede">Every ambient global a handler can reach, generated from the
     shipped shims' own documentation — the same source whose examples are
     compiled and executed by the engine's test gate. This page cannot lag the
     code, because it is the code.</p>
"""

PAGE_FOOT = """
  <footer>© 2026 Loop46, Inc. · rewind.js · generated by scripts/ops/gen_docs_reference.py — do not edit by hand</footer>
</article>
</main>
</div>
</body>
</html>
"""


def render(all_groups) -> str:
    out = [PAGE_HEAD]
    # Jump index.
    out.append("<p>")
    links = []
    for _heading, sections in all_groups:
        for sec in sections:
            links.append(f'<a href="#{anchor(sec["name"])}"><code>{esc(sec["name"])}</code></a>')
    out.append(" · ".join(links))
    out.append("</p>")

    for heading, sections in all_groups:
        out.append(f"<h2>{esc(heading)}</h2>")
        for sec in sections:
            out.append(f'<h3 id="{anchor(sec["name"])}"><code>{esc(sec["name"])}</code></h3>')
            out.append(render_prose(sec["desc"]))
            if sec["example"]:
                out.append(f"<pre><code>{esc(sec['example'])}</code></pre>")
            for m in sec["members"]:
                out.append(f'<h4 id="{anchor(sec["name"] + "-" + m["name"])}"><code>{esc(signature(m))}</code></h4>')
                out.append(render_prose(m["desc"]))
                if m["params"]:
                    out.append("<table><tr><th>Param</th><th>Type</th><th></th></tr>")
                    for p in m["params"]:
                        name, typ, opt, desc = param_pieces(p)
                        d = render_prose(desc.split("\n"))
                        label = esc(name) + (" <em>(optional)</em>" if opt else "")
                        out.append(f"<tr><td><code>{label}</code></td><td><code>{esc(typ)}</code></td><td>{d}</td></tr>")
                    out.append("</table>")
                if m["returns"]:
                    rm = re.match(r"(?:\{([^}]*)\}\s*)?(.*)", m["returns"], re.S)
                    rtyp, rdesc = rm.group(1) or "", rm.group(2).strip()
                    bits = "<p><b>Returns</b>"
                    if rtyp:
                        bits += f" <code>{esc(rtyp)}</code>"
                    if rdesc:
                        body = render_prose(rdesc.split("\n"))
                        bits += " — " + body[3:-4].replace("</p><p>", " ")
                    out.append(bits + "</p>")
                for ex in m["examples"]:
                    out.append(f"<pre><code>{esc(ex)}</code></pre>")
    out.append(PAGE_FOOT)
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apps-dir", type=pathlib.Path, required=True)
    ap.add_argument("--check", action="store_true",
                    help="verify the generated page is current (no write)")
    args = ap.parse_args()

    grouped = set(SKIPPED)
    for _h, stems in GROUPS:
        grouped.update(stems)
    on_disk = {p.stem for p in GLOBALS.glob("*.js")}
    missing = sorted(on_disk - grouped)
    if missing:
        sys.exit(f"gen_docs_reference: new shim(s) not assigned to a "
                 f"reference group (or SKIPPED): {', '.join(missing)} — "
                 f"add them to GROUPS in {__file__}")

    all_groups = []
    for heading, stems in GROUPS:
        sections = []
        for stem in stems:
            for sec in parse_shim(stem):
                # A JSDoc'd member above the @namespace block lands in a
                # stem-named fallback section — merge same-name sections.
                prior = next((x for x in sections if x["name"] == sec["name"]), None)
                if prior:
                    prior["members"].extend(sec["members"])
                    if not prior["desc"] or not any(l.strip() for l in prior["desc"]):
                        prior["desc"] = sec["desc"]
                    prior["example"] = prior["example"] or sec["example"]
                else:
                    sections.append(sec)
        all_groups.append((heading, sections))

    n_members = sum(len(s["members"]) for _h, ss in all_groups for s in ss)
    if n_members < 40:
        sys.exit(f"gen_docs_reference: only {n_members} members extracted — "
                 f"parser regression?")

    page = render(all_groups)
    dest = args.apps_dir / "docs" / "_static" / "reference.html"
    if args.check:
        if not dest.exists() or dest.read_text() != page:
            sys.exit(f"gen_docs_reference: {dest} is stale — re-run the generator")
        print(f"gen_docs_reference: {dest} is current")
        return 0
    dest.write_text(page)
    print(f"gen_docs_reference: wrote {dest} "
          f"({sum(len(ss) for _h, ss in all_groups)} sections, {n_members} members)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
