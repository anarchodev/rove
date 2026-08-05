# SPDX-FileCopyrightText: 2026 Loop46, Inc.
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The divergence allowlist — the small, reviewed set of engine differences
that are legitimate, and the discipline that stops it becoming a junk drawer.

Four rules, each of which exists because an allowlist without it decays into
permanent exemptions:

1. **Every entry is either owned or by-design.** A TEMPORARY difference names
   the issue that deletes it; a PERMANENT one is marked `by_design` and carries
   the rationale. An entry that is neither is a bug someone decided to stop
   looking at, and construction rejects it.
2. **Entries match by SIGNATURE, not by value.** A value-keyed entry stops
   matching the moment a handler changes, and a silently-stopped-matching entry
   is indistinguishable from a fixed bug.
3. **Every entry prints on every run.** An exemption nobody reads is an
   exemption nobody revisits.
4. **A stale entry FAILS the gate.** If an entry matches nothing, either the
   divergence was fixed (delete the entry) or the case stopped exercising it
   (a coverage regression). Both need a human; neither should be silent.

Rule 4 is the one that makes the other three hold, and it is stricter than the
replay-fidelity gate this discipline is borrowed from — that gate prints its
known list but tolerates a stale member.

Rule 1's two categories are not a softening. The by-design category was always
implied by this suite's premise — the sim's virtual clock will never equal
prod's wall clock — and collapsing it into "name an issue" would have meant
inventing issues that can never close, which is how an allowlist stops being
read.
"""

from __future__ import annotations

import fnmatch
from dataclasses import dataclass


@dataclass(frozen=True)
class Known:
    """One tolerated divergence class.

    `pattern` is an fnmatch glob over a Divergence signature —
    `case/world/field/engineA~engineB`, engines sorted. Globbing is what lets
    one entry cover "this field, this engine pair, every case", which is the
    honest shape for an engine-wide gap; per-case entries for an engine-wide
    gap would need editing every time a case is added, and that pressure is how
    entries get copy-pasted without thought.

    Breadth is a real cost, though: a pattern wide enough to cover the
    difference you meant will also cover every unrelated divergence in the same
    field. Prefer the narrowest pattern that fires, and widen it only when a
    second case proves the difference is engine-wide rather than case-specific.
    """

    pattern: str
    why: str
    # The engines this entry concerns. Declared rather than parsed out of the
    # pattern (which may glob the engine slot), because the stale rule needs to
    # know whether the entry even had a chance to fire: an entry about sim↔replay
    # cannot be stale on a box where the replay porcelain is absent and only the
    # sim ran. Without this, rule 4 fails the build for the opposite of the
    # reason it exists.
    engines: tuple[str, ...]
    issue: int | None = None
    by_design: bool = False

    def __post_init__(self):
        if bool(self.issue) == bool(self.by_design):
            raise ValueError(
                f"allowlist entry {self.pattern!r} must name EITHER an issue "
                f"that deletes it OR by_design=True with a rationale — never "
                f"both, never neither"
            )
        if not self.why:
            raise ValueError(f"allowlist entry {self.pattern!r} has no rationale")

    def owner(self) -> str:
        return f"rove#{self.issue}" if self.issue else "by design"


# ── the allowlist ────────────────────────────────────────────────────────────
#
# Resist adding an entry before its divergence is observed. An entry written in
# advance is a prediction, and a prediction that turns out wrong reads exactly
# like a real exemption.
#
# More entries are expected with the prod adapter (rove#417), where the rest of
# the genuinely-legitimate differences live: wall clock vs the sim's virtual
# clock, S3-backed blob bytes the sim carries inline, node-partitioned request
# ids.
KNOWN: tuple[Known, ...] = (
    Known(
        pattern="errorsemantics/throw/digest/prod~sim",
        engines=("sim", "prod"),
        issue=459,
        why=(
            "prod folds `response(200, \"\")` for a THROWN handler: the dispatcher "
            "closes the digest before worker_dispatch composes the 500 and its "
            "`handler threw:` body, and never re-closes it. The sim folds the real "
            "result, so the two disagree on every throw. Delete this the moment "
            "#459 lands — the runner fails on a stale entry, so it cannot be "
            "forgotten."
        ),
    ),
    Known(
        # Scoped to the one case that proves it rather than `*/*/effects/…`:
        # a pattern that wide would excuse every effect-log divergence between
        # these two engines, which is most of what the suite is for. Widen it
        # when a second logging case makes the engine-wide claim true.
        pattern="consolefmt/*/effects/replay~sim",
        engines=("sim", "replay"),
        by_design=True,
        why=(
            "the replay engine has no console recorder ON PURPOSE: live console "
            "output is already on the LogRecord, so replay's console is a no-op "
            "sink (scripts/ops/gen_replay_prelude.py excludes console.js from the "
            "generated prelude). The interaction digest does not fold console "
            "either, so the two engines still agree on the sequence that matters."
        ),
    ),
)


# An engine with no adapter yet is NOT an allowlist concern: that is "the
# comparison did not happen", not "the comparison happened and differed", and
# the two must stay distinguishable or the suite reports agreement it never
# established. Each adapter raises `EngineUnavailable` with its own blocking
# issue (see `adapters.py`), and the runner prints those separately — one place
# names each gap, so the two cannot drift.


def matches(signature: str) -> Known | None:
    for k in KNOWN:
        if fnmatch.fnmatch(signature, k.pattern):
            return k
    return None


def partition(divergences) -> tuple[list, list[tuple]]:
    """Split into (unexcused, excused) — excused carries its Known entry."""
    unexcused, excused = [], []
    for d in divergences:
        k = matches(d.signature())
        (excused.append((d, k)) if k else unexcused.append(d))
    return unexcused, excused


def stale(excused, engines_ran=None) -> list[Known]:
    """Entries that matched nothing this run. Rule 4: these fail the gate.

    An entry is only judged when the engines it concerns actually ran. An entry
    about sim↔replay is not stale on a run where replay was unavailable — it
    never had the chance to fire, and failing the build there would punish a
    missing engine rather than a fixed divergence.

    `engines_ran=None` judges every entry, which is what the selftest wants.
    """
    fired = {k.pattern for _, k in excused}
    out = []
    for k in KNOWN:
        if k.pattern in fired:
            continue
        if engines_ran is not None and not set(k.engines).issubset(set(engines_ran)):
            continue
        out.append(k)
    return out
