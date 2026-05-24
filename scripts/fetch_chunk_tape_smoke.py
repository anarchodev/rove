#!/usr/bin/env python3
"""Effect-reification Phase 2D / Phase 5 PR-1 — fetch
activation-bytes tape capture.

Algebra worklist #1 (`docs/effect-algebra.md` §7): `fireFetchEventActivation`
historically passed empty `TapePayloads` to `captureLogWithId`, so a
fetch handler reading `request.activation.bytes` (the upstream chunk)
had no record of the input it saw — replay couldn't reconstitute the
same handler invocation. Phase 2D's tape hook fills
`TapePayloads.activation_bytes` for `fetch_chunk` activations; the
flush writer emits it as `activation_bytes_b64` on each log record.

Phase 5 PR-1 collapsed the prior `fetch_done` activation into a
single `fetch_chunk` activation with `final: true`. The fetch chain
now produces N body events + 1 final-empty event (all routed to the
same `on_chunk` module). This smoke updates accordingly:

1. The first N `fetchchunk` records carry the body chunks; each has
   non-empty `activation_bytes_b64`.
2. Concat'd in record order they reconstruct the upstream body
   byte-exactly.
3. The (N+1)-th `fetchchunk` record is the final-empty event; its
   `activation_bytes_b64` is empty/null (an empty Uint8Array; the
   `final: true` flag is what carries terminal info).

This is the precondition for replay-equivalence of fetch chains.
Full replay-equivalence (run the chain twice and compare writesets)
is a follow-on; this smoke is the regression gate for the L3 invariant
"every Msg is recorded, including its bytes."
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl, mint_jwt  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
WB_HOST = f"wb.{PUBLIC_SUFFIX}"
ACME_ID = "acme"

# Mirror of examples/loop46-demo-tenants/wb/bulk/index.mjs — 170 bytes.
EXPECTED_BODY = "".join(f"bulk-line-{i:02d}-zzz\n" for i in range(10))


def _ls(jwt: str, url: str, *, timeout_s: float = 10.0) -> str:
    args = [
        "curl", "-sS", "--http2-prior-knowledge", "--max-time", str(timeout_s),
        "-H", f"Authorization: Bearer {jwt}", url,
    ]
    return subprocess.run(args, capture_output=True, timeout=timeout_s + 5.0).stdout.decode()


def main() -> int:
    cluster = Cluster.spawn(
        tag="fetch-chunk-tape-smoke",
        http_base=8430,
        raft_base=40530,
        files_port=8434,
        log_port=8433,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        seed_manifest=REPO_ROOT / "examples" / "loop46-demo-tenants.json",
        worker_extra_args=["--dev-webhook-unsafe"],
    )
    with cluster as c:
        c.discover_leader()
        admin_origin = c.admin_origin()
        c.spawn_files_server(cors_origin=admin_origin, leader_url=admin_origin)
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()
        print(f"ok  cluster up: leader={c.addrs.http[c.leader_idx]} log={c.log_url()}")

        cc = c.curl_ctx(ACME_HOST, WB_HOST)
        acme_origin = f"https://{ACME_HOST}:{c.leader_port()}"
        bulk_url = f"https://{WB_HOST}:{c.leader_port()}/bulk"

        # Sanity: wb/bulk reachable.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            r = curl(cc, bulk_url, method="GET")
            if r.status == 200 and r.body == EXPECTED_BODY:
                break
            time.sleep(0.2)
        else:
            sys.exit(f"FAIL wb/bulk sanity: status={r.status}")
        print(f"ok  wb/bulk reachable ({len(EXPECTED_BODY)}-byte body)")

        # Drive the fetch. /fetchchunks issues http.fetch with on_chunk
        # + on_done; chunks land as fetch_chunk activations, terminal
        # as fetch_done — all should now tape `activation_bytes`.
        r = curl(cc, f"{acme_origin}/fetchchunks?url={bulk_url}", method="GET")
        if r.status != 200:
            sys.exit(f"FAIL /fetchchunks status={r.status} body={r.body!r}")
        fetch_id = r.body.strip()
        print(f"ok  http.fetch issued; id={fetch_id[:16]}…")

        # Wait for the chain to finish — terminal marker is the signal.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            r = curl(cc, f"{acme_origin}/readkey?key=fetch/done", method="GET")
            if r.status == 200:
                break
            time.sleep(0.2)
        else:
            sys.exit("FAIL fetch_done never landed")
        print("ok  chain completed; querying log-server for taped records")

        jwt = mint_jwt(c.services_jwt_secret, {"exp": int(time.time() * 1000) + 5 * 60 * 1000})

        # Poll log-server for fetch records. Post-PR-1 every fetch
        # event (body chunks + final-empty) fires `fetchchunk.mjs`
        # — expect N+1 records (3 body + 1 final-empty for the
        # 170-byte body @ 64 B/chunk).
        records = []
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            body = _ls(jwt, f"{c.log_url()}/v1/{ACME_ID}/list?limit=50")
            try:
                d = json.loads(body)
            except json.JSONDecodeError:
                d = {}
            records = d.get("records", [])
            chunk_recs = [r for r in records if r.get("path") == "fetchchunk"]
            if len(chunk_recs) >= 4:
                break
            time.sleep(0.5)
        else:
            paths = {}
            for rec in records:
                p = rec.get("path", "?")
                paths[p] = paths.get(p, 0) + 1
            sys.exit(
                f"FAIL log-server records insufficient: {len(records)} total\n"
                f"  path counts: {paths}"
            )

        chunk_recs = sorted(
            (r for r in records if r.get("path") == "fetchchunk"),
            key=lambda r: r["request_id"],
        )
        print(f"ok  surfaced {len(chunk_recs)} fetchchunk records (3 body + 1 final-empty expected)")

        # Fetch the full record for each event. The `list` endpoint
        # returns summaries; the `show` endpoint carries the tape
        # fields.
        full_records = []
        for r in chunk_recs[:4]:
            show = _ls(jwt, f"{c.log_url()}/v1/{ACME_ID}/show/{r['request_id']}")
            rec = json.loads(show)["record"]
            full_records.append(rec)

        # Phase 2D primary assertion (PR-1 update): the FIRST N
        # records are body events with non-empty activation_bytes;
        # the LAST one is the final-empty event with empty bytes.
        body_records = full_records[:3]
        final_record = full_records[3]

        captured_blobs = []
        for i, rec in enumerate(body_records):
            tapes = rec.get("tapes", {})
            b64 = tapes.get("activation_bytes_b64")
            if not b64:
                sys.exit(
                    f"FAIL body fetch_chunk record {i} (request_id={rec['request_id']}) "
                    f"missing activation_bytes_b64. tapes keys={list(tapes.keys())}"
                )
            captured_blobs.append(base64.b64decode(b64))
        print("ok  every body fetch_chunk record carries activation_bytes_b64")

        # Byte-exact reconstruction: concat in record-order = upstream
        # body. The records are ordered by request_id which monotonic-
        # ascends with arrival, mirroring chunk seq.
        reconstructed = b"".join(captured_blobs)
        if reconstructed.decode("utf-8", errors="replace") != EXPECTED_BODY:
            sys.exit(
                f"FAIL reconstructed bytes mismatch.\n"
                f"  got      ({len(reconstructed)}B): {reconstructed!r}\n"
                f"  expected ({len(EXPECTED_BODY)}B): {EXPECTED_BODY!r}"
            )
        print(f"ok  {len(reconstructed)} bytes reconstructed from "
              f"activation_bytes tape — byte-exact match to upstream body")

        # The final-empty event has empty bytes (the `final: true`
        # flag carries the terminal info; the bytes Uint8Array is
        # zero-length).
        tapes = final_record.get("tapes", {})
        b64 = tapes.get("activation_bytes_b64")
        if b64:
            # base64 of empty bytes is "" or absent; some encoders
            # emit "" → both null and "" are acceptable.
            decoded = base64.b64decode(b64)
            if len(decoded) != 0:
                sys.exit(
                    f"FAIL final-empty fetch_chunk record carries "
                    f"non-empty activation_bytes (len={len(decoded)})"
                )
        print("ok  final-empty fetch_chunk record has empty activation_bytes "
              "(correct — final: true carries terminal info, no body)")

        print("\nPhase 2D / Phase 5 PR-1 tape capture smoke passed "
              "(algebra §7 worklist #1 closed: fetch chunk bytes are "
              "taped + replay-reconstructable; the unified `fetch_chunk` "
              "activation tag carries body events + final-empty.)")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
