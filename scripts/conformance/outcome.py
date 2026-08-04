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
green while proving nothing — for a stretch only the replay engine folded an
interaction digest, and a naive comparison would have "agreed" with itself and
called the sequence verified.

**Absent is not equal to null.** An engine that cannot produce a field says so
(the field is missing); an engine that produces an empty value says *that*.
Collapsing the two is how a capture gap disguises itself as a match.
"""

from __future__ import annotations

import base64
import hashlib
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


def _wire_text(value: Any) -> Any:
    """The response body as it goes on the wire, mirroring the replay
    epilogue's `__ser`: null/undefined → None, a string passes through
    UNCHANGED, anything else is JSON-serialized.

    Mirrored rather than chosen. `__ser` is what the replay engine parks and
    what its interaction digest folds, and prod puts the same text on the wire,
    so deriving it identically for every engine is what makes one `body` field
    comparable at all.
    """
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _body_from_wire(text: Any) -> Any:
    """Wire text → the comparable body value.

    Parsed when the text is JSON so that two engines building the same object in
    a different key order still compare equal. Note this cannot distinguish a
    handler that returned the object `{"a":1}` from one that returned the
    STRING `'{"a":1}'` — `__ser` erases that difference before anything can
    observe it, so no engine can report it. Exact wire-text equality is the
    interaction digest's job (it folds `__ser`'s output), not this field's.
    """
    if text is None or not isinstance(text, str):
        return _canon(text)
    try:
        return _canon(json.loads(text))
    except json.JSONDecodeError:
        return text


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

    `interaction_digest` is present since rove#416; a bundle without it (an
    older `rewind` binary) leaves the field ABSENT rather than null, so the
    runner reports the comparison as unverified instead of manufacturing
    agreement with an engine that did fold one.
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
        # Through wire text, the same route the replay engine's body takes —
        # the sim reports the handler's RETURN VALUE while replay reports
        # `__ser` of it, and comparing those directly made a returned string
        # look like a divergence from an identical wire body.
        o.body = _body_from_wire(_wire_text(bundle["body"]))

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
    # ABSENT (not null) when the bundle carries none — see the module docstring
    # on absent-vs-null.
    if "interaction_digest" in bundle:
        o.digest = bundle["interaction_digest"]
    return o


def from_replay_result(res: dict, *, stderr: str = "") -> Outcome:
    """Normalize the WASM replay engine's parked outcome.

    The epilogue parks `{status, result, effects, digest}` under
    `__replay_output__` in the host kv overlay — the same side channel the
    native driver's OUTPUT_KEY uses.

    What this engine can observe is narrower than the sim's, and the gaps are
    left ABSENT rather than filled with a plausible value:

    - **headers** — the parked outcome carries only a status, so response
      headers cannot be read back (rove#437). Filling in `{}` would assert the handler set
      none, which is a different claim from "this engine cannot see them".
    - **error** — a throwing handler parks nothing at all, so the message is not
      recoverable here. `ok` still compares, because a non-zero rc with no
      parked output IS observable.
    """
    o = Outcome(engine="replay")
    parked = res.get("parked")
    rc = res.get("rc")
    o.notes["rc"] = rc
    if res.get("oom"):
        o.notes["oom"] = True
    if stderr.strip():
        o.notes["stderr"] = stderr.strip()[:2000]

    # A non-zero rc with nothing parked is how an undeclared kv read surfaces:
    # the binding returns -4, the epilogue throws REPLAY DIVERGENCE, and the run
    # dies before parking. Name it, because "the replay engine has no
    # closed-world default" is a finding about the engine, not a driver bug.
    if parked is None:
        o.ok = False
        if rc != 0 and "REPLAY DIVERGENCE" in stderr:
            o.notes["divergence"] = (
                "undeclared read — the replay engine has no closed-world "
                "default (rove#436)"
            )
        return o

    o.ok = rc == 0
    if "status" in parked:
        o.status = parked["status"]

    # `result` is already the wire text (`__ser` of the return value), so it
    # goes through the same wire→body route as every other engine.
    if "result" in parked:
        body = _body_from_wire(parked["result"])
        o.body = body
        # `result` is the engine's OWN wire text, so its hash is a genuine
        # byte-exact check against prod's wire bytes — the equality `body`
        # deliberately gives up by canonicalizing key order. The sim cannot
        # join: its bundle body has already been through Zig's JSON
        # re-serialization, so hashing it would test that round-trip rather
        # than the engine.
        if isinstance(parked["result"], str):
            o.body_sha256 = hashlib.sha256(parked["result"].encode("utf-8")).hexdigest()
        # Same rule the sim applies: a returned `next(...)` holds the
        # connection. Derived identically on both sides so the comparison tests
        # the engines rather than two different definitions of "held".
        if isinstance(body, dict) and body.get("__rove_disposition") == "next":
            o.disposition = "held"
        else:
            o.disposition = "terminal"

    if "effects" in parked:
        o.effects = normalize_effects(parked["effects"])
        o.writes = writes_of(o.effects)
    if parked.get("digest") is not None:
        o.digest = parked["digest"]
    return o


def from_prod_response(resp, *, record=None, compared_headers=DEFAULT_COMPARED_HEADERS) -> Outcome:
    """Normalize a live worker's response plus its captured log record.

    Prod is the only engine with a real HTTP response, so it is the only one
    that can supply `headers` from the wire. It is also the only one whose
    `effects` cannot be supplied: the record carries tapes (the reads the run
    made), not the ordered read/write/effect log the two offline engines build,
    and half a log compared against a whole one is worse than none. `writes` is
    absent for the same reason — the record has no writeset, and there is no
    read-only kv listing door to reconstruct one (rove#83).

    What prod does bring is the interaction digest as a THIRD producer, which
    is what lets a disagreement be localized rather than merely noticed.
    """
    o = Outcome(engine="prod")
    o.status = getattr(resp, "status", None)
    o.headers = _pick_headers(getattr(resp, "headers", None), compared_headers)

    raw_body = getattr(resp, "body", None)
    o.body = _body_from_wire(raw_body)
    if isinstance(raw_body, str):
        # Prod's actual wire bytes. The replay engine supplies the same field
        # from its own `__ser` output, so this is a real two-way byte-exact
        # check — it catches a key-ordering difference that `body` forgives by
        # canonicalizing.
        o.body_sha256 = hashlib.sha256(raw_body.encode("utf-8")).hexdigest()

    if record is None:
        # The response is real but the record never surfaced — the digest and
        # the exception are unknowable, so they stay ABSENT rather than null.
        # `ok` still follows from the status.
        o.notes["record"] = "no log record found for this request"
    else:
        tapes = record.get("tapes") or {}
        if "interaction_digest" in tapes:
            o.digest = tapes["interaction_digest"]
        exc = record.get("exception")
        o.error = _canon_error(exc) if exc else None
        o.notes["request_id"] = record.get("request_id")
        o.notes["outcome"] = record.get("outcome")

    # A thrown handler is a 500 in prod, which is what the sim reports as
    # `ok: false` — so the two agree on the thrown-handler path rather than
    # disagreeing about how to spell it.
    o.ok = bool(o.status) and int(o.status) < 500
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
