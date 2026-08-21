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
import hashlib
import html
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import docs_site  # noqa: E402

ROVE = pathlib.Path(__file__).resolve().parents[2]
GLOBALS = ROVE / "src" / "js" / "globals"
# First-party package sources — surface that used to be a global shim and
# now ships as `@rewind/<name>` (import-gated, same doc conventions). A
# GROUPS stem resolves to the globals shim first, then the package entry.
PACKAGES = ROVE / "src" / "js" / "packages" / "@rewind"

# Curated page layout: (group heading, [shim file stems]). A shim absent
# here is skipped (request/http are contract territory — the Handlers
# page); a NEW shim must be added to a group or the generator fails
# loudly below, so the reference can't silently omit surface.
GROUPS = [
    ("Model & state",
     "Durable, replicated tenant state. `kv` is the Model; `blob` is "
     "content-addressed object storage (one-shot `put`/`get`, or the "
     "`receive` → `write` → `seal` upload session for large inbound "
     "bodies); `segments` is the append-log recipe on top of both — a "
     "hot kv tail whose history is sealed into blobs.",
     ["kv", "blob", "segments"]),
    ("Connection & wakes",
     "The held socket. `stream` pushes response bytes out over time; "
     "`after.*` arms one-shot wakes; `next()` keeps the connection "
     "held between activations; `http.subscribe` holds a long-lived "
     "OUTBOUND stream (firehoses, SSE consumers). All ephemeral — "
     "they die with the caller.",
     ["after", "next", "stream", "http"]),
    ("Durable effects",
     "Connectionless work that survives anything: outbound delivery "
     "(`webhook`, `email`, `retry`) and future activations "
     "(`schedule`, `cron`).",
     ["webhook", "email", "retry", "schedule", "cron"]),
    ("Browser agent", None, ["browser"]),
    ("Utilities", None,
     ["crypto", "jwt", "base64", "textcodec", "urlsearchparams",
      "console", "time"]),
    ("Identity & federation", None,
     ["users", "sessions", "oauth", "oidc", "activitypub"]),
    ("Admin (the __admin__ tenant only)", None, ["platform"]),
]
# `request` is contract territory — the Handlers page documents it.
# `export` and `stripe` are held back deliberately: the reference page is a
# claim about live surface, and advertising one that is merged but not
# switched on is the same false-claim class this page is audited for
# (rove#322). Promote each into a GROUPS entry when it goes live.
SKIPPED = {"request", "export", "stripe"}

# Files whose surface has no @namespace block: section name + one-line
# description fallback (the file header covers the rest in-repo).
BARE_FILES = {
    "cron": ("cron", "Recurring durable timer, plus the fire-time helpers it carries as statics.", "cron"),
    "next": ("next", "The held-connection disposition.", ""),
    "textcodec": ("TextEncoder / TextDecoder", "UTF-8 bytes ↔ string.", ""),
    "urlsearchparams": ("URLSearchParams", "Query/form-body parsing.", ""),
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
    g = GLOBALS / f"{stem}.js"
    src = g.read_text() if g.exists() else \
        (PACKAGES / stem / "index.mjs").read_text()
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
            ns = tagmap["namespace"].strip()
            cur = {"name": ns, "desc": desc, "prefix": ns,
                   "example": examples[0] if examples else None, "members": []}
            sections.append(cur)
            continue
        # `@function name` names a bare `function name(…)` declaration
        # the code-line patterns can't see (the callable cron verb).
        name = tagmap.get("function", "").strip() or member_name(code)
        if not name or name.startswith("_"):
            continue
        if cur is None:
            title, fallback, prefix = BARE_FILES.get(stem, (stem, "", stem))
            cur = {"name": title, "desc": [fallback], "prefix": prefix,
                   "example": None, "members": []}
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


def signature(member, prefix: str = "") -> str:
    args = []
    for p in member["params"]:
        name, _typ, opt, _d = param_pieces(p)
        if "." in name:
            continue  # opts.on — folded into the params table
        args.append(name + ("?" if opt else ""))
    dotted = member["name"]
    if prefix and dotted != prefix:
        dotted = f"{prefix}.{dotted}"
    return f"{dotted}({', '.join(args)})"


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



def render(all_groups) -> str:
    out = [docs_site.page_open(
        title="reference",
        description="Generated reference for every rewind.js handler global — signatures, options, examples — straight from the shipped shims.",
        active="/reference",
        kicker="Reference",
        h1="Globals reference",
        lede="Every ambient global a handler can reach, generated from the "
             "shipped shims' own documentation — the same source whose "
             "examples are compiled and executed by the engine's test gate. "
             "This page cannot lag the code, because it is the code.",
    )]
    # Jump index — one row per system.
    out.append("<table>")
    for heading, _gdesc, sections in all_groups:
        links = " · ".join(
            f'<a href="#{anchor(sec["name"])}"><code>{esc(sec["name"])}</code></a>'
            for sec in sections
        )
        out.append(f"<tr><td>{esc(heading)}</td><td>{links}</td></tr>")
    out.append("</table>")

    for heading, gdesc, sections in all_groups:
        out.append(f"<h2>{esc(heading)}</h2>")
        if gdesc:
            out.append(render_prose([gdesc]))
        for sec in sections:
            out.append(f'<h3 id="{anchor(sec["name"])}"><code>{esc(sec["name"])}</code></h3>')
            out.append(render_prose(sec["desc"]))
            if sec["example"]:
                out.append(f"<pre><code>{esc(sec['example'])}</code></pre>")
            for m in sec["members"]:
                out.append(f'<h4 id="{anchor(sec["name"] + "-" + m["name"])}"><code>{esc(signature(m, sec.get("prefix", "")))}</code></h4>')
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
    out.append(docs_site.page_close("generated by scripts/ops/gen_docs_reference.py — do not edit by hand"))
    return "\n".join(out)


# Digest of the composed page, committed HERE in rove. Same cross-repo
# freshness problem, same two halves, as the contract pages
# (`gen_docs_contract.py`): the artifact lives in rewind-apps, but `build()`
# composes it from rove sources alone, so its digest is checkable without a
# sibling checkout. The source here is the shim JSDoc rather than an authored
# doc — edit a shim's docblock and this moves.
DIGEST_FILE = ROVE / "scripts" / "ops" / "docs-reference.sha256"


def build() -> str:
    """The rendered reference page, from rove sources alone."""
    grouped = set(SKIPPED)
    for _h, _d, stems in GROUPS:
        grouped.update(stems)
    on_disk = {p.stem for p in GLOBALS.glob("*.js")}
    on_disk |= {p.name for p in PACKAGES.iterdir() if p.is_dir()}
    missing = sorted(on_disk - grouped)
    if missing:
        sys.exit(f"gen_docs_reference: new shim(s) not assigned to a "
                 f"reference group (or SKIPPED): {', '.join(missing)} — "
                 f"add them to GROUPS in {__file__}")

    all_groups = []
    for heading, gdesc, stems in GROUPS:
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
        all_groups.append((heading, gdesc, sections))

    n_members = sum(len(s["members"]) for _h, _d, ss in all_groups for s in ss)
    if n_members < 40:
        sys.exit(f"gen_docs_reference: only {n_members} members extracted — "
                 f"parser regression?")

    return render(all_groups)


def digest(page: str) -> str:
    return hashlib.sha256(page.encode("utf-8")).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apps-dir", type=pathlib.Path)
    ap.add_argument("--check", action="store_true",
                    help="verify the generated page is current (no write)")
    ap.add_argument("--verify", action="store_true",
                    help="fail (exit 1) if the shim JSDoc no longer matches the "
                         "recorded digest — the rove-side gate; needs no apps checkout")
    ap.add_argument("--record", action="store_true",
                    help="rewrite the recorded digest; run this WITH regenerating "
                         "the page in rewind-apps, never instead of it")
    args = ap.parse_args()

    page = build()

    if args.verify:
        want = DIGEST_FILE.read_text(encoding="utf-8").split()[0] if DIGEST_FILE.exists() else ""
        have = digest(page)
        if want != have:
            print(
                f"STALE: the shim JSDoc behind the reference page changed.\n"
                f"  recorded {want or '(none)'}\n"
                f"  current  {have}\n"
                f"\n"
                f"`docs/_static/reference.html` in rewind-apps is GENERATED from the\n"
                f"shim docblocks. It does not update itself, and a publish regenerates\n"
                f"it in flight — so the site looks right while the committed copy rots.\n"
                f"Propagate the change:\n"
                f"\n"
                f"  python3 scripts/ops/gen_docs_reference.py --apps-dir <rewind-apps>\n"
                f"  python3 scripts/ops/gen_docs_reference.py --record\n"
                f"\n"
                f"then commit the regenerated page in rewind-apps AND the digest here,\n"
                f"and bump the `web` pin. Recording without regenerating defeats the\n"
                f"check.",
                file=sys.stderr,
            )
            return 1
        print(f"fresh: shim JSDoc matches the recorded digest ({have[:16]}…)")
        return 0

    if args.record:
        DIGEST_FILE.write_text(digest(page) + "  reference.html\n", encoding="utf-8")
        print(f"recorded {digest(page)} → {DIGEST_FILE}")
        return 0

    if not args.apps_dir:
        sys.exit("gen_docs_reference: --apps-dir is required to write or --check")

    dest = args.apps_dir / "docs" / "_static" / "reference.html"
    if args.check:
        if not dest.exists() or dest.read_text() != page:
            sys.exit(f"gen_docs_reference: {dest} is stale — re-run the generator")
        print(f"gen_docs_reference: {dest} is current")
        return 0
    dest.write_text(page)
    print(f"gen_docs_reference: wrote {dest}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
