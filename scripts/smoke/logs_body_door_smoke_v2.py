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

The assertions that matter are the NEGATIVE ones: the record must NOT carry
`request_body_b64` (over the cap, so it was never inlined) while the door
still returns the exact bytes. A door that passed only because the body
rode inline would prove nothing, so the small-body control asserts
`source == "carried"` and the large one asserts `source == "pool"` —
different resolution paths through one interface.

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
READY_SRC = 'export function handler() { return "ready"; }\n'

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

        # The record for the large body must NOT carry the bytes: over the
        # cap they were never inlined. This is what makes the door's answer
        # meaningful rather than a re-read of something already present.
        show = c.log_get(f"acme/show/{big_id}", timeout=15.0)
        tapes = {}
        if show.status == 200:
            tapes = json.loads(show.body).get("record", {}).get("tapes", {}) or {}
        check("large record does NOT inline request_body_b64",
              show.status == 200 and not tapes.get("request_body_b64"),
              f"status={show.status} present={bool(tapes.get('request_body_b64'))}")
        check("large record DOES carry a trigger_payload tape",
              bool(tapes.get("trigger_payload_tape_b64")),
              f"keys={sorted(tapes.keys())}")

        # The door resolves the pointer.
        d = c.log_get(f"acme/body/{big_id}/trigger_payload/0", timeout=30.0)
        got = {}
        if d.status == 200:
            try:
                got = json.loads(d.body)
            except json.JSONDecodeError:
                got = {}
        check("door resolves the spilled body → 200", d.status == 200,
              f"status={d.status} body={d.body[:200]!r}")
        check("door reports it came from the pool",
              got.get("source") == "pool",
              f"source={got.get('source')!r}")
        decoded = ""
        if got.get("bytes_b64") is not None:
            decoded = base64.b64decode(got["bytes_b64"]).decode("utf-8", "replace")
        check(f"resolved body is byte-exact ({BIG_LEN} bytes)",
              decoded == big,
              f"len={len(decoded)} want={BIG_LEN} "
              f"head={decoded[:32]!r} tail={decoded[-32:]!r}")

        # The small body takes the other resolution path through the same
        # interface — one address shape whatever the payload's fate.
        d2 = c.log_get(f"acme/body/{small_id}/trigger_payload/0", timeout=30.0)
        got2 = {}
        if d2.status == 200:
            try:
                got2 = json.loads(d2.body)
            except json.JSONDecodeError:
                got2 = {}
        check("door resolves the inline body → 200", d2.status == 200,
              f"status={d2.status} body={d2.body[:200]!r}")
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
