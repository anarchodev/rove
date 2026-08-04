# SPDX-FileCopyrightText: 2026 Loop46, Inc.
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The divergence allowlist — the small, reviewed set of engine differences
that are legitimate, and the discipline that stops it becoming a junk drawer.

Four rules, each of which exists because an allowlist without it decays into
permanent exemptions:

1. **Every entry names the issue that deletes it.** An entry with no owner is a
   bug someone decided to stop looking at.
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
    """

    pattern: str
    issue: int
    why: str


# ── the allowlist ────────────────────────────────────────────────────────────
#
# Empty, and that is not an oversight. Phase 0 runs one engine (sim); a
# single-engine run produces no PAIRS, so it produces no divergences to excuse.
# Entries are expected to arrive with the prod adapter (rove#417), where the
# genuinely-legitimate differences live: wall clock vs the sim's virtual clock,
# S3-backed blob bytes the sim carries inline, and node-partitioned request ids.
#
# Resist adding an entry before its divergence is observed. An entry written in
# advance is a prediction, and a prediction that turns out wrong reads exactly
# like a real exemption.
KNOWN: tuple[Known, ...] = ()


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


def stale(excused) -> list[Known]:
    """Entries that matched nothing this run. Rule 4: these fail the gate."""
    fired = {k.pattern for _, k in excused}
    return [k for k in KNOWN if k.pattern not in fired]
