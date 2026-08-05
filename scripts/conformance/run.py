#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Loop46, Inc.
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The behavior conformance runner — one corpus, run on every engine, failing
when two engines disagree.

    scripts/conformance/run.py                      # the cheap lane (no cluster)
    scripts/conformance/run.py --engines sim,prod   # the cluster lane
    scripts/conformance/run.py --case utf8encode -v
    scripts/conformance/run.py --json out.json

The corpus is the spec: reading `cases/` should be how you learn what the JS
worker guarantees. A case is a world (or several) plus the app tree it runs
against; the runner drives each world on each engine the case declares and
compares the normalized outcomes pairwise.

What fails the gate:

- a divergence not covered by the allowlist
- an adapter error (an engine crashed, or produced nothing parseable)
- a STALE allowlist entry — one that matched nothing this run

What does not fail the gate, but always prints:

- an engine that cannot run yet, with the issue that builds it
- a field exactly one engine produced, so nothing was compared

That last line is the one worth watching. A run where every field is
`unverified` is a run that proved nothing, and it should read that way rather
than as a pass.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import allowlist  # noqa: E402
from adapters import (  # noqa: E402
    ADAPTERS,
    CHEAP_LANE,
    REPO_ROOT,
    AdapterError,
    EngineUnavailable,
)
from outcome import (  # noqa: E402
    ABSENT,
    COMPARED_FIELDS,
    DEFAULT_COMPARED_HEADERS,
    compare,
)

CASES_DIR = Path(__file__).resolve().parent / "cases"


def load_cases(only: list[str] | None, cases_dir: Path | None = None) -> list[dict]:
    cases = []
    for path in sorted((cases_dir or CASES_DIR).glob("*.json")):
        case = json.loads(path.read_text(encoding="utf-8"))
        case.setdefault("name", path.stem)
        if only and case["name"] not in only:
            continue
        cases.append(case)
    if only:
        missing = set(only) - {c["name"] for c in cases}
        if missing:
            raise SystemExit(f"no such case(s): {', '.join(sorted(missing))}")
    return cases



def augment_world(world: dict, source_dir: Path) -> dict:
    """Fill in the first-party packages a case's `manifest.json` declares.

    A manifest is a DECLARATION, not a deployable file: the customer CLI reads
    it and resolves the dependencies into the deploy (`classify` in
    `src/cli/common.zig` ships only `.mjs`). `rewind test` does the equivalent
    offline — but `rewind sim`, which the sim adapter drives, takes a world and
    resolves nothing, so a case importing `@rewind/jwt` fails to load.

    Resolving here rather than in each adapter keeps every engine running the
    SAME world. Doing it per-adapter is how two engines end up disagreeing
    because they were handed different inputs, which is a divergence the suite
    would report as if it were the engines' fault.

    A world that declares its own `packages` is left alone — an explicit
    declaration beats an inferred one.
    """
    if world.get("packages") or world.get("app_imports"):
        return world
    manifest = source_dir / "manifest.json"
    if not manifest.exists():
        return world
    try:
        deps = (json.loads(manifest.read_text(encoding="utf-8")).get("dependencies") or {})
    except json.JSONDecodeError:
        return world
    specs = [s for s in deps if str(s).startswith("@rewind/")]
    if not specs:
        return world
    try:
        sys.path.insert(0, str(REPO_ROOT / "scripts" / "smoke"))
        from smoke_lib_v2 import V2Cluster

        # A pure helper over the repo's own `src/js/packages/@rewind/` tree —
        # it reads no cluster state, so it needs no live cluster. Called through
        # the class for exactly that reason.
        packages, app_imports = V2Cluster.firstparty_packages(V2Cluster, specs)
    except Exception:  # noqa: BLE001
        # No harness, no packages — the case will fail to load and say so,
        # which is more useful than a world silently missing its imports.
        return world
    out = dict(world)
    out["packages"] = packages
    out["app_imports"] = app_imports
    return out


def run_case(case: dict, engines: list[str], verbose: bool) -> dict:
    name = case["name"]
    source_dir = REPO_ROOT / case["source_dir"]
    if not source_dir.is_dir():
        raise SystemExit(f"{name}: source_dir does not exist: {source_dir}")
    compared_headers = tuple(case.get("compare_headers", DEFAULT_COMPARED_HEADERS))
    declared = [e for e in case.get("engines", list(ADAPTERS)) if e in engines]

    result = {
        "case": name,
        "worlds": [],
        "divergences": [],
        "excused": [],
        "unverified": [],
        "unavailable": [],
        "errors": [],
        "degenerate": [],
    }

    for entry in case["worlds"]:
        label = entry.get("label", "world")
        world = augment_world(entry["world"], source_dir)
        outcomes = []
        for engine in declared:
            try:
                o = ADAPTERS[engine](world, source_dir, compared_headers=compared_headers)
                outcomes.append(o)
                if verbose:
                    print(f"    {engine:<7} {json.dumps(o.fields(), default=str)[:200]}")
            except EngineUnavailable as e:
                result["unavailable"].append(
                    {"world": label, "engine": engine, "why": str(e)}
                )
            except AdapterError as e:
                result["errors"].append(
                    {"world": label, "engine": engine, "error": str(e)}
                )

        # An engine that produced no observable outcome — it crashed, threw
        # before parking, or never terminated — still reports `ok: False`, and
        # two such `ok: False` values COMPARE EQUAL. That reads as agreement
        # while proving nothing: the other engine may have produced a full
        # outcome the failed one never got near. Flag it so the case reports
        # `unproven` rather than `ok`.
        degenerate = [
            o.engine for o in outcomes if len(o.fields()) <= 1
        ]
        result["degenerate"] += [
            {"world": label, "engine": e} for e in degenerate
        ]

        divs, unver = compare(name, label, outcomes)
        unexcused, excused = allowlist.partition(divs)
        # How many fields were actually compared across two or more engines.
        # This, not the pass/fail bit, is what says whether the run proved
        # anything — a world that ran on one engine has zero comparisons and
        # must not read as agreement.
        compared = sum(
            1
            for f in COMPARED_FIELDS
            if sum(1 for o in outcomes if getattr(o, f) is not ABSENT) >= 2
        )
        result["comparisons"] = result.get("comparisons", 0) + compared
        result["worlds"].append(
            {
                "label": label,
                "engines_ran": [o.engine for o in outcomes],
                "comparisons": compared,
            }
        )
        result["divergences"] += [
            {"signature": d.signature(), "detail": d.describe()} for d in unexcused
        ]
        result["excused"] += [
            {
                "signature": d.signature(),
                "pattern": k.pattern,
                "owner": k.owner(),
                "why": k.why,
                "detail": d.describe(),
            }
            for d, k in excused
        ]
        result["unverified"] += [
            {"field": u.field, "engine": u.engine, "detail": u.describe()} for u in unver
        ]
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument(
        "--engines",
        default=",".join(CHEAP_LANE),
        help=f"comma-separated engines (default: the cheap lane, {','.join(CHEAP_LANE)})",
    )
    ap.add_argument("--case", action="append", help="run only this case (repeatable)")
    ap.add_argument("--json", metavar="PATH", help="write the full result as JSON")
    ap.add_argument("-v", "--verbose", action="store_true", help="print each outcome")
    ap.add_argument("--list", action="store_true", help="list cases and exit")
    ap.add_argument(
        "--rewind-bin",
        metavar="PATH",
        help="the `rewind` CLI to drive the sim with (the build step passes the "
        "artifact it just built, so the gate can never run a stale engine)",
    )
    ap.add_argument(
        "--cases-dir", metavar="DIR", help="corpus location (default: ./cases)"
    )
    args = ap.parse_args()
    cases_dir = Path(args.cases_dir) if args.cases_dir else None

    if args.rewind_bin:
        import adapters

        adapters.REWIND_BIN = Path(args.rewind_bin)

    if args.list:
        for c in load_cases(None, cases_dir):
            print(f"{c['name']:<20} {c.get('description', '')[:80]}")
        return 0

    engines = [e.strip() for e in args.engines.split(",") if e.strip()]
    unknown = set(engines) - set(ADAPTERS)
    if unknown:
        raise SystemExit(f"unknown engine(s): {', '.join(sorted(unknown))}")

    cases = load_cases(args.case, cases_dir)
    if not cases:
        raise SystemExit("no cases found")

    print(f"conformance: {len(cases)} case(s) on engines {', '.join(engines)}\n")
    results = [run_case(c, engines, args.verbose) for c in cases]

    for r in results:
        ran = sorted({e for w in r["worlds"] for e in w["engines_ran"]})
        if r["divergences"] or r["errors"]:
            status = "DIVERGED"
        elif r["degenerate"]:
            # One engine produced nothing; whatever "agreed" was agreement
            # between a real outcome and a failure.
            status = "unproven"
        elif r.get("comparisons", 0) == 0:
            # Ran, did not disagree, and compared nothing. "ok" would be a lie
            # by omission — the case established no agreement whatsoever.
            status = "unproven"
        else:
            status = "ok"
        print(
            f"  {status:<9} {r['case']:<20} ran on: {', '.join(ran) or '(none)'}"
            f"  ({r.get('comparisons', 0)} field comparison(s))"
        )

    divergences = [d for r in results for d in r["divergences"]]
    errors = [e for r in results for e in r["errors"]]
    excused = [x for r in results for x in r["excused"]]
    unverified = [u for r in results for u in r["unverified"]]
    unavailable = [u for r in results for u in r["unavailable"]]

    # Rule 3: every exemption prints, every run.
    if excused:
        print("\nexcused divergences (allowlist):")
        for x in excused:
            print(f"  {x['owner']:<10} {x['detail']}\n             {x['why']}")

    if unavailable:
        print("\nengines that did not run:")
        seen = set()
        for u in unavailable:
            key = (u["engine"], u["why"])
            if key in seen:
                continue
            seen.add(key)
            print(f"  {u['engine']:<7} {u['why']}")

    degenerate = [g for r in results for g in r["degenerate"]]
    if degenerate:
        by_engine: dict[str, list[str]] = {}
        for g in degenerate:
            by_engine.setdefault(g["engine"], []).append(g["world"])
        print("\nENGINES THAT PRODUCED NO OUTCOME — these cases proved nothing:")
        for engine, worlds in sorted(by_engine.items()):
            print(f"  {engine:<7} {len(worlds)} world(s)")

    if unverified:
        by_engine: dict[str, list[str]] = {}
        for u in unverified:
            by_engine.setdefault(u["engine"], []).append(u["field"])
        print("\nUNVERIFIED — produced by one engine only, so nothing was compared:")
        for engine, fields in sorted(by_engine.items()):
            counts: dict[str, int] = {}
            for f in fields:
                counts[f] = counts.get(f, 0) + 1
            pretty = ", ".join(f"{f}×{n}" for f, n in sorted(counts.items()))
            print(f"  {engine:<7} {pretty}")

    if errors:
        print("\nADAPTER ERRORS:")
        for e in errors:
            print(f"  {e['engine']} [{e['world']}]: {e['error']}")

    if divergences:
        print("\nDIVERGENCES:")
        for d in divergences:
            print(f"  {d['detail']}\n    signature: {d['signature']}")

    # Rule 4: a stale allowlist entry fails. Either the divergence was fixed or
    # the case stopped exercising it; both need a human. Computed from the
    # patterns that actually fired this run, not by re-matching signatures — a
    # re-match would consult the current KNOWN a second time and could quietly
    # disagree with the first.
    fired = {x["pattern"] for x in excused}
    # Only judge entries whose engines actually ran — see allowlist.stale() —
    # and only on a FULL run. A `--case` subset deliberately skips most of the
    # corpus, so an entry that did not fire there says nothing about whether it
    # is stale; failing on it would make the narrowing flag unusable and train
    # people to ignore the rule.
    engines_ran = {e for r in results for w in r["worlds"] for e in w["engines_ran"]}
    stale = (
        []
        if args.case
        else [
            k
            for k in allowlist.KNOWN
            if k.pattern not in fired and set(k.engines).issubset(engines_ran)
        ]
    )
    if stale:
        print("\nSTALE ALLOWLIST ENTRIES — matched nothing this run:")
        for k in stale:
            print(f"  {k.owner():<10} {k.pattern}\n             {k.why}")

    if args.json:
        Path(args.json).write_text(
            json.dumps(
                {
                    "engines": engines,
                    "cases": results,
                    "stale_allowlist": [k.pattern for k in stale],
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        print(f"\nwrote {args.json}")

    failed = bool(divergences or errors or stale)
    comparisons = sum(r.get("comparisons", 0) for r in results)
    verdict = "FAIL" if failed else ("PASS" if comparisons else "PASS (PROVED NOTHING)")
    print(
        f"\n{verdict} conformance — "
        f"{len(cases)} case(s), {comparisons} field comparison(s), "
        f"{len(divergences)} divergence(s), {len(errors)} adapter error(s), "
        f"{len(excused)} excused, {len(unverified)} unverified field(s)"
    )
    if not failed and not comparisons:
        print(
            "  Nothing was compared: every field came from a single engine. "
            "Set REWIND_APPS_DIR to a rewind-apps checkout to run the replay "
            "engine, or add prod to --engines once rove#417 lands."
        )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
