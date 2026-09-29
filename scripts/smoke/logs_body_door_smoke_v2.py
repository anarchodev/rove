#!/usr/bin/env python3
"""The out-of-line body door — a payload over the inline cap comes back whole.

A request body over 16 KiB is NOT stored in the log record. The worker
spills it to the cross-tenant body pool (`_pool/{written_ms}-{digest}`) and the record
keeps only a `BodyRef {batch_id, offset, len}` on its `trigger_payload`
tape. Until this door existed nothing resolved that pointer, so every large
input replayed as an EMPTY body — a missing input presenting as a plausible
empty value rather than a refusal.

This drives the whole chain against real S3:

    POST 64 KiB → worker spills to _pool/ + records the ref → S3 flush →
    log-server indexes → `/v1/{t}/body/{req}/trigger_payload/0` range-GETs
    the pool object at (offset, len) and hands the bytes back.

Every recorded payload is CIPHERTEXT at rest (`src/keyring/body_seal.zig`):
a spilled body in the pool, and a small body on the tape entry itself. The
log-server holds no keys, so straight off it either body comes back sealed
with its wrap beside it, and only the worker's `rewind-logs.internal` door
hands back plaintext. Both bodies are therefore read BOTH ways — the direct
read is the control that proves there was something to open.

The small body asserts `source == "carried"` and the large one
`source == "pool"` — different resolution paths through one interface, so a
door that passed only because a body rode inline proves nothing about the
pool.

ASCII bodies: `request.text` is a JS string, and the smoke harness decodes
response bodies as text. Byte-exactness for arbitrary octets is the
conformance suite's job, not this one's.

Run:
    zig build rewind-worker rewind-cp rewind-front rewind-logs
    set -a; . ./.env; set +a
    python3 scripts/smoke/logs_body_door_smoke_v2.py
"""
from __future__ import annotations

import base64
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

# Reads the body (flipping `body_read`, without which read-taping elides
# the trigger_payload entry entirely and there is no reference to resolve)
# and reports its length so the request itself proves the handler saw the
# whole payload.
ECHO_LEN_SRC = """\
export default function () {
    const data = request.text || "";
    return "len:" + data.length;
}
"""
READY_SRC = 'export function handler(_a) { return "ready"; }\n'

# Reads one payload back THROUGH the worker's logs door — the only reader
# that can open a sealed pool body. Self-tenant, so the engine pins the read
# to this handler's own id.
DOOR_SRC = r"""export default function ({ after, next }) {
    const q = new URLSearchParams(request.query || "");
    after.fetch("http://rewind-logs.internal/v1/" + request.tenant + "/body/"
                + q.get("rid") + "/" + q.get("addr"));
    return next();
}
export function onFetchResult() {
    response.status = 200;
    return "status:" + (request.status || 0) + "\n" + (request.text || "");
}
"""


def door_body(c, rid: str, addr: str):
    """A body-route read through the worker door → (status, parsed JSON)."""
    r = c.request("acme", f"/door?rid={rid}&addr={addr}", timeout=30.0)
    head, _, body = r.body.partition("\n")
    status = int(head.split(":", 1)[1]) if head.startswith("status:") else 0
    try:
        return status, json.loads(body) if 200 <= status < 300 else {}
    except json.JSONDecodeError:
        return status, {}

# Comfortably over INBOUND_INLINE_THRESHOLD / REQUEST_BODY_CAP (16 KiB),
# so the spill is forced by construction rather than by timing.
BIG_LEN = 64 * 1024
SMALL_LEN = 1024


def _payload(n: int, seed: str) -> str:
    """Deterministic ASCII with no repeating 16-byte window, so a wrong
    offset in the pool object produces a wrong ANSWER and not a
    coincidentally-equal one."""
    out = []
    i = 0
    while sum(len(s) for s in out) < n:
        out.append(f"{seed}-{i:08d}-")
        i += 1
    return "".join(out)[:n]


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    big = _payload(BIG_LEN, "big")
    small = _payload(SMALL_LEN, "sml")

    print("=== out-of-line body door (spill → _pool/ → resolve, real S3) ===")
    with V2Cluster.spawn("bodydoor", nodes=1) as c:
        c.spawn_log_server(poll_interval_ms=200)

        r = c.provision("acme")
        check("provision acme → 200/409", r.status in (200, 409),
              f"got {r.status} {r.body!r}")
        c.deploy_handlers("acme", {
            "index.mjs": rpc_wrap(READY_SRC),
            "echo/index.mjs": ECHO_LEN_SRC,
            "door/index.mjs": DOOR_SRC,
        })
        c.wait_for_handler("acme", "/?fn=handler", want_body="ready", timeout_s=30.0)

        # The two activations: one over the cap (spills), one under (inline).
        rb = c.request("acme", "/echo", method="POST", data=big, timeout=30.0)
        check(f"handler saw all {BIG_LEN} bytes",
              rb.status == 200 and rb.body == f"len:{BIG_LEN}",
              f"status={rb.status} body={rb.body[:80]!r}")
        rs = c.request("acme", "/echo", method="POST", data=small, timeout=30.0)
        check(f"handler saw all {SMALL_LEN} bytes",
              rs.status == 200 and rs.body == f"len:{SMALL_LEN}",
              f"status={rs.status} body={rs.body[:80]!r}")

        # Wait for the flush + index. Both POSTs must be indexed before the
        # door assertions; /list is newest-first.
        records: list = []
        deadline = time.time() + 40.0
        while time.time() < deadline:
            resp = c.log_get("acme/list?limit=50", timeout=15.0)
            if resp.status == 200:
                try:
                    records = json.loads(resp.body).get("records", [])
                except json.JSONDecodeError:
                    records = []
                posts = [r for r in records
                         if r.get("method") == "POST" and r.get("status") == 200]
                if len(posts) >= 2:
                    break
            time.sleep(1.0)

        posts = [r for r in records
                 if r.get("method") == "POST" and r.get("status") == 200]
        check("both POST records indexed", len(posts) >= 2,
              f"got {len(posts)} POST records of {len(records)}")
        if len(posts) < 2:
            print(f"\n{len(failures)} failure(s)")
            return 1

        # /list is newest-first, so posts[0] is the small body.
        small_id = posts[0]["request_id"]
        big_id = posts[1]["request_id"]

        # The record reaches the body only through its trigger_payload tape —
        # it carries no other copy.
        show = c.log_get(f"acme/show/{big_id}", timeout=15.0)
        tapes = {}
        if show.status == 200:
            tapes = json.loads(show.body).get("record", {}).get("tapes", {}) or {}
        check("the record carries no side copy of the body",
              show.status == 200 and "request_body_b64" not in tapes,
              f"status={show.status} keys={sorted(tapes.keys())}")
        check("large record DOES carry a trigger_payload tape",
              bool(tapes.get("trigger_payload_tape_b64")),
              f"keys={sorted(tapes.keys())}")

        # CONTROL: straight off the log-server the pool body is sealed. If
        # this came back as plaintext the pool was never sealed, and the
        # door's plaintext below would prove nothing about opening it.
        d = c.log_get(f"acme/body/{big_id}/trigger_payload/0", timeout=30.0)
        raw = {}
        if d.status == 200:
            try:
                raw = json.loads(d.body)
            except json.JSONDecodeError:
                raw = {}
        check("log-server resolves the spilled body → 200", d.status == 200,
              f"status={d.status} body={d.body[:200]!r}")
        check("CONTROL: the pool bytes carry a wrap beside them",
              bool(raw.get("body_key_b64")), f"keys={sorted(raw.keys())}")
        raw_bytes = base64.b64decode(raw.get("bytes_b64") or "")
        check("CONTROL: the pool bytes are NOT the plaintext",
              big.encode()[:64] not in raw_bytes,
              "the plaintext is in the pool unsealed")

        # The worker door opens it.
        status, got = door_body(c, big_id, "trigger_payload/0")
        check("door resolves the spilled body → 200", status == 200,
              f"status={status}")
        check("door reports it came from the pool",
              got.get("source") == "pool",
              f"source={got.get('source')!r}")
        check("the wrap does not leave the door", "body_key_b64" not in got,
              f"keys={sorted(got.keys())}")
        decoded = ""
        if got.get("bytes_b64") is not None:
            decoded = base64.b64decode(got["bytes_b64"]).decode("utf-8", "replace")
        check(f"resolved body is byte-exact ({BIG_LEN} bytes)",
              decoded == big and got.get("len") == BIG_LEN,
              f"len={len(decoded)} reported={got.get('len')} want={BIG_LEN} "
              f"head={decoded[:32]!r} tail={decoded[-32:]!r}")

        # The small body takes the other resolution path through the same
        # interface — one address shape whatever the payload's fate.
        # CONTROL: the small body is sealed on the tape entry itself.
        raw2 = c.log_get(f"acme/body/{small_id}/trigger_payload/0", timeout=30.0)
        raw2j = json.loads(raw2.body) if raw2.status == 200 else {}
        check("CONTROL: the inline body carries a wrap beside it",
              bool(raw2j.get("body_key_b64")), f"status={raw2.status} keys={sorted(raw2j.keys())}")
        check("CONTROL: the inline bytes are NOT the plaintext",
              small.encode()[:64] not in base64.b64decode(raw2j.get("bytes_b64") or ""),
              "the small body is on the tape unsealed")

        d2_status, got2 = door_body(c, small_id, "trigger_payload/0")
        check("door resolves the inline body → 200", d2_status == 200,
              f"status={d2_status}")
        check("door reports the inline body rode along",
              got2.get("source") == "carried",
              f"source={got2.get('source')!r}")
        decoded2 = ""
        if got2.get("bytes_b64") is not None:
            decoded2 = base64.b64decode(got2["bytes_b64"]).decode("utf-8", "replace")
        check(f"inline body is byte-exact ({SMALL_LEN} bytes)", decoded2 == small,
              f"len={len(decoded2)} want={SMALL_LEN}")

        # ── refusals ────────────────────────────────────────────────────
        # An index past the end is 404, never an empty 200 — the whole
        # point of the arc is that absence is reported, not rendered.
        d3 = c.log_get(f"acme/body/{big_id}/trigger_payload/99", timeout=15.0)
        check("index past the end → 404", d3.status == 404,
              f"status={d3.status} body={d3.body[:120]!r}")

        # A channel that exists on the tape but carries no payload is not
        # addressable here: the ADDRESS is wrong (400), as distinct from a
        # well-formed address that names nothing (404 above).
        d4 = c.log_get(f"acme/body/{big_id}/kv/0", timeout=15.0)
        check("non-payload channel → 400", d4.status == 400,
              f"status={d4.status}")

        # A record with no fetch chain has no fetch_responses tape.
        d5 = c.log_get(f"acme/body/{big_id}/fetch_responses/0", timeout=15.0)
        check("uncaptured channel → 404", d5.status == 404,
              f"status={d5.status} body={d5.body[:120]!r}")

        # Tenant scoping: the door inherits the same `logs-read` gate as
        # /show, so a token minted for another tenant cannot reach these
        # bytes even though the pool object they live in is cross-tenant.
        c.provision("globex")
        d6 = c.log_get(f"acme/body/{big_id}/trigger_payload/0",
                       tenant="globex", timeout=15.0)
        check("a token scoped to another tenant → 401", d6.status == 401,
              f"status={d6.status} body={d6.body[:120]!r}")

    print()
    if failures:
        print(f"{len(failures)} failure(s): {failures}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
