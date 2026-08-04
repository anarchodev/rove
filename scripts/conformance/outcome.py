# SPDX-FileCopyrightText: 2026 Loop46, Inc.
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The normalized outcome — what every engine must produce, and how two of them
are compared.

The shape is not invented here. The offline sim already emits a flattened
bundle (`rewind sim` → one `response` head, a `disposition`, a `body`, and one
ordered `effects` log), and that bundle IS the outcome shape; this module only
canonicalizes it so a bundle from a different engine compares field-for-field.
The world/bundle contract itself lives in
`docs/architecture/replay-and-sim.md` ("The model — one run, parameterized").

Two rules carry the weight:

**A field is compared only across engines that supply it.** A field exactly one
engine produces is `unverified`, never agreement. Without this the suite reads
green while proving nothing — the sim folds no interaction digest today, so a
naive comparison would "agree" with itself and call the spec verified.

**Absent is not equal to null.** An engine that cannot produce a field says so
(the field is missing); an engine that produces an empty value says *that*.
Collapsing the two is how a capture gap disguises itself as a match.
"""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass, field
from typing import Any, Optional

# The response headers the suite compares. Deliberately a small declared set:
# prod attaches a pile of transport headers (date, server, content-length,
# alt-svc…) that no engine but prod can have, so comparing "all headers" would
# mean an allowlist entry per header per case. A case may widen this through its
# own `compare_headers`, which is the reviewed way to assert one more.
DEFAULT_COMPARED_HEADERS = (
    "content-type",
    "content-encoding",
    "cache-control",
    "location",
    "etag",
)

# Marker for "this engine cannot produce this field" — distinct from a produced
# null. `None` is a legitimate produced value (a handler returning null), so it
# cannot double as the absence marker.
ABSENT = object()


def _canon(v: Any) -> Any:
    """Recursively key-sort objects so two engines that built the same value in
    a different insertion order compare equal. Arrays keep their order — order
    is meaning for an effect log, and sorting one would hide the exact class of
    divergence the interaction digest exists to catch."""
    if isinstance(v, dict):
        return {k: _canon(v[k]) for k in sorted(v)}
    if isinstance(v, list):
        return [_canon(x) for x in v]
    return v


@dataclass
class Outcome:
    """One engine's observable result for one world.

    Every field defaults to ABSENT. An adapter sets only what its engine can
    actually observe, and the comparison skips the rest — see the module
    docstring.
    """

    engine: str
    status: Any = ABSENT
    headers: Any = ABSENT
    body: Any = ABSENT
    body_sha256: Any = ABSENT
    disposition: Any = ABSENT
    writes: Any = ABSENT
    effects: Any = ABSENT
    digest: Any = ABSENT
    error: Any = ABSENT
    ok: Any = ABSENT
    # Free-form, never compared: rc/oom/timing an engine happens to expose.
    # Useful in a failure report, useless as an assertion.
    notes: dict = field(default_factory=dict)

    def fields(self) -> dict:
        out = {}
        for name in COMPARED_FIELDS:
            v = getattr(self, name)
            if v is not ABSENT:
                out[name] = v
        return out


# Compared in this order, so a report reads head-first: the response, then what
# it did, then the interaction sequence that produced it.
COMPARED_FIELDS = (
    "status",
    "headers",
    "body",
    "body_sha256",
    "disposition",
    "writes",
    "effects",
    "digest",
    "error",
    "ok",
)


@dataclass
class Divergence:
    """Two engines disagreed on one field of one world."""

    case: str
    world: str
    field: str
    engine_a: str
    engine_b: str
    value_a: Any
    value_b: Any

    def signature(self) -> str:
        """Stable identity for allowlist matching. Deliberately excludes the
        VALUES — an allowlist entry keyed to a value goes stale the moment the
        handler changes, and a stale entry that silently stops matching is
        indistinguishable from a fixed bug."""
        a, b = sorted((self.engine_a, self.engine_b))
        return f"{self.case}/{self.world}/{self.field}/{a}~{b}"

    def describe(self) -> str:
        return (
            f"{self.case}[{self.world}] {self.field}: "
            f"{self.engine_a}={_short(self.value_a)} vs "
            f"{self.engine_b}={_short(self.value_b)}"
        )


@dataclass
class Unverified:
    """A field exactly one engine produced — so nothing was proven about it."""

    case: str
    world: str
    field: str
    engine: str

    def describe(self) -> str:
        return (
            f"{self.case}[{self.world}] {self.field}: only {self.engine} "
            f"produced it — nothing compared"
        )


def _short(v: Any, limit: int = 160) -> str:
    s = json.dumps(v, ensure_ascii=False, sort_keys=True, default=str)
    return s if len(s) <= limit else s[: limit - 1] + "…"


def from_sim_bundle(bundle: dict, *, compared_headers=DEFAULT_COMPARED_HEADERS) -> Outcome:
    """Normalize the `rewind sim` bundle.

    The sim's `body` is the handler's RETURN VALUE, not wire bytes, so it sets
    `body` and leaves `body_sha256` absent — the wire-byte comparison starts
    existing when a second engine that has wire bytes lands (rove#417).
    """
    o = Outcome(engine="sim")
    resp = bundle.get("response")
    if isinstance(resp, dict):
        o.status = resp.get("status")
        o.headers = _pick_headers(resp.get("headers"), compared_headers)
    elif "response" in bundle:
        # An explicit null response head is a produced value (no response), not
        # an engine that cannot observe one.
        o.status = None
        o.headers = {}

    if bundle.get("binary") is True and "bodyB64" in bundle:
        raw = base64.b64decode(bundle["bodyB64"])
        o.body = {"kind": "bytes", "b64": base64.b64encode(raw).decode()}
    elif "body" in bundle:
        o.body = _canon(bundle["body"])

    if "disposition" in bundle:
        o.disposition = bundle["disposition"]
    if "effects" in bundle:
        o.effects = normalize_effects(bundle["effects"])
        o.writes = writes_of(o.effects)
    if "error" in bundle:
        o.error = _canon_error(bundle["error"])
    if "ok" in bundle:
        o.ok = bundle["ok"]
    # `divergence` is a replay-only signal and never an assertion — a diverged
    # run is a failed run, surfaced by the adapter, not a field to compare.
    if bundle.get("divergence") is not None:
        o.notes["divergence"] = bundle["divergence"]
    # The sim folds no interaction digest (rove#416), so `digest` stays ABSENT
    # rather than null — see the module docstring on absent-vs-null.
    if "interaction_digest" in bundle:
        o.digest = bundle["interaction_digest"]
    return o


def _pick_headers(headers: Any, compared) -> dict:
    """Lowercase-key the declared subset. A header an engine did not send is
    simply not in the result — the comparison then sees a key on one side only,
    which is a real divergence and reported as one."""
    if not isinstance(headers, dict):
        return {}
    lowered = {str(k).lower(): v for k, v in headers.items()}
    return {k: lowered[k] for k in compared if k in lowered}


def _canon_error(err: Any) -> Any:
    """Errors compare on MESSAGE and NAME only. Stack traces carry engine paths
    and line offsets that legitimately differ; comparing them would mean an
    allowlist entry for every throwing case, which is an allowlist that has
    stopped meaning anything."""
    if err is None:
        return None
    if isinstance(err, dict):
        out = {}
        for k in ("name", "message", "code"):
            if k in err:
                out[k] = err[k]
        return out or {"message": str(err)}
    return {"message": str(err)}


def normalize_effects(effects: Any) -> list:
    """One ordered log, engine-neutral.

    Order is preserved and significant. Two engines emitting the same effects in
    a different order is precisely the divergence a response-only comparison
    cannot see, and the reason the interaction digest exists at all
    (`docs/architecture/replay-and-sim.md`)."""
    if not isinstance(effects, list):
        return []
    out = []
    for e in effects:
        if not isinstance(e, dict):
            out.append({"verb": "?", "raw": _canon(e)})
            continue
        out.append(_canon({k: v for k, v in e.items() if k not in _EFFECT_NOISE}))
    return out


# Per-effect fields that are engine bookkeeping rather than behavior. Kept
# deliberately tiny: every name here is a thing the suite has decided not to
# assert, so it needs to be defensible one by one.
_EFFECT_NOISE = frozenset({"seq", "ts", "ts_ms", "elapsed_ms"})


def writes_of(effects: list) -> list:
    """The committed KV delta, key-sorted.

    Derived from the effect log rather than read back separately, so one engine
    cannot report a write it did not actually perform through the same channel
    the others did. Sorted because a writeset is a set — its ORDER lives in
    `effects`, which is compared order-sensitively, so comparing order twice
    would double-count one divergence."""
    ws = {}
    for e in effects:
        verb = e.get("verb") or e.get("op") or e.get("kind")
        if verb not in ("kv.set", "set", "write", "kv.delete", "delete"):
            continue
        key = e.get("key")
        if key is None:
            continue
        if verb in ("kv.delete", "delete"):
            ws[key] = {"key": key, "deleted": True}
        else:
            ws[key] = {"key": key, "value": _canon(e.get("value"))}
    return [ws[k] for k in sorted(ws)]


def compare(case: str, world: str, outcomes: list[Outcome]) -> tuple[list[Divergence], list[Unverified]]:
    """Compare every engine pair, field by field.

    Pairwise rather than against a designated reference: with three engines a
    pairwise report says WHICH pair disagrees, which is how a three-way
    disagreement localizes the fault (sim+prod agreeing while replay differs
    points at the shell; replay+prod agreeing while sim differs points at the
    sim's recorders). A reference engine would flatten that back to "these
    differ".
    """
    divergences: list[Divergence] = []
    unverified: list[Unverified] = []

    for fname in COMPARED_FIELDS:
        producers = [o for o in outcomes if getattr(o, fname) is not ABSENT]
        if len(producers) == 0:
            continue
        if len(producers) == 1:
            unverified.append(Unverified(case, world, fname, producers[0].engine))
            continue
        for i in range(len(producers)):
            for j in range(i + 1, len(producers)):
                a, b = producers[i], producers[j]
                va, vb = getattr(a, fname), getattr(b, fname)
                if not _eq(va, vb):
                    divergences.append(
                        Divergence(case, world, fname, a.engine, b.engine, va, vb)
                    )
    return divergences, unverified


def _eq(a: Any, b: Any) -> bool:
    """Structural equality over canonical JSON. Both sides are already
    canonicalized on the way in; re-canonicalizing here keeps the comparison
    correct for adapters that build an Outcome by hand."""
    return json.dumps(_canon(a), sort_keys=True, default=str) == json.dumps(
        _canon(b), sort_keys=True, default=str
    )
