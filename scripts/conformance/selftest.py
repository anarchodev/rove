#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Loop46, Inc.
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Non-vacuity check for the conformance machinery itself.

The suite currently runs one engine, so it cannot yet catch a real divergence —
which means the comparison, the allowlist, and the stale-entry rule are all
unexercised, and unexercised gate machinery is decoration. Something has to
prove the gate CAN go red before the engine that would make it go red exists.

So this drives the comparison with synthetic outcomes and asserts each rule the
runner depends on. It is pure Python: no engines, no cluster, ~instant, and it
runs in the same step as the corpus.

The rules under test are the ones whose failure would be silent:

- a divergence in any compared field is reported, not swallowed
- ABSENT (an engine that cannot produce a field) is not equal to a produced null
- a field only one engine produces is UNVERIFIED, never agreement
- key order does not manufacture a divergence; effect ORDER does
- an allowlist entry excuses only its own signature
- an allowlist entry that matches nothing is reported stale
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import allowlist  # noqa: E402
from outcome import ABSENT, Outcome, compare  # noqa: E402

FAILURES: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
    if not ok:
        FAILURES.append(label)


def _cmp(a: Outcome, b: Outcome):
    return compare("selftest", "w", [a, b])


def main() -> int:
    print("conformance selftest — the gate must be able to go red\n")

    # ── a divergence is reported ──
    divs, _ = _cmp(
        Outcome(engine="sim", status=200),
        Outcome(engine="prod", status=500),
    )
    check("status divergence is reported", len(divs) == 1, f"got {len(divs)}")
    if divs:
        check(
            "signature names case/world/field/engine-pair",
            divs[0].signature() == "selftest/w/status/prod~sim",
            divs[0].signature(),
        )

    # ── agreement is not reported ──
    divs, _ = _cmp(
        Outcome(engine="sim", status=200),
        Outcome(engine="prod", status=200),
    )
    check("agreement produces no divergence", not divs)

    # ── ABSENT is not a value ──
    # The trap this guards: the sim folds no interaction digest, so if ABSENT
    # compared equal to a produced null, a prod digest of null would "agree"
    # with a sim that never computed one.
    divs, unver = _cmp(
        Outcome(engine="sim"),  # digest ABSENT
        Outcome(engine="prod", digest=None),  # digest produced, and null
    )
    check("ABSENT never compares as agreement", not divs)
    check(
        "single-producer field is UNVERIFIED",
        any(u.field == "digest" and u.engine == "prod" for u in unver),
        f"{[(u.field, u.engine) for u in unver]}",
    )

    # ── a produced null and a produced null DO agree ──
    divs, unver = _cmp(
        Outcome(engine="sim", digest=None),
        Outcome(engine="prod", digest=None),
    )
    check("two produced nulls agree", not divs and not unver)

    # ── key order is not a divergence; effect order is ──
    divs, _ = _cmp(
        Outcome(engine="sim", body={"a": 1, "b": 2}),
        Outcome(engine="prod", body={"b": 2, "a": 1}),
    )
    check("object key order is not a divergence", not divs)

    divs, _ = _cmp(
        Outcome(engine="sim", effects=[{"verb": "kv.set"}, {"verb": "http.send"}]),
        Outcome(engine="prod", effects=[{"verb": "http.send"}, {"verb": "kv.set"}]),
    )
    check(
        "effect ORDER divergence is reported",
        len(divs) == 1 and divs[0].field == "effects",
        f"{[d.field for d in divs]}",
    )

    # ── every compared field is actually reachable ──
    # Guards the class where a field is added to the Outcome and quietly never
    # compared, which reads as permanent agreement.
    from outcome import COMPARED_FIELDS

    unreached = []
    for f in COMPARED_FIELDS:
        a = Outcome(engine="sim")
        b = Outcome(engine="prod")
        setattr(a, f, "x")
        setattr(b, f, "y")
        d, _ = _cmp(a, b)
        if not any(x.field == f for x in d):
            unreached.append(f)
    check("every COMPARED_FIELD can diverge", not unreached, f"unreachable: {unreached}")

    # ── the allowlist excuses only its own signature ──
    probe = allowlist.Known(
        pattern="selftest/w/status/prod~sim", issue=0, why="selftest probe"
    )
    saved = allowlist.KNOWN
    allowlist.KNOWN = (probe,)
    try:
        divs, _ = _cmp(
            Outcome(engine="sim", status=200), Outcome(engine="prod", status=500)
        )
        unexcused, excused = allowlist.partition(divs)
        check("a matching allowlist entry excuses", not unexcused and len(excused) == 1)
        check("an excused entry is not stale", not allowlist.stale(excused))

        divs, _ = _cmp(
            Outcome(engine="sim", body="a"), Outcome(engine="prod", body="b")
        )
        unexcused, excused = allowlist.partition(divs)
        check(
            "an entry does NOT excuse a different field",
            len(unexcused) == 1 and not excused,
        )
        check(
            "an entry that matched nothing is STALE",
            [k.pattern for k in allowlist.stale(excused)] == [probe.pattern],
        )
    finally:
        allowlist.KNOWN = saved

    # ── the shipped allowlist obeys its own rules ──
    check(
        "every shipped allowlist entry names an issue",
        all(k.issue > 0 and k.why for k in allowlist.KNOWN),
    )

    print()
    if FAILURES:
        print(f"FAIL conformance selftest ({len(FAILURES)}): {FAILURES}")
        return 1
    print("PASS conformance selftest — the comparison, the allowlist, and the "
          "stale rule all fire")
    return 0


if __name__ == "__main__":
    sys.exit(main())
