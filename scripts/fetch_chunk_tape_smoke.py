#!/usr/bin/env python3
"""Effect-reification Phase 2D — fetch-A activation-bytes tape capture.

Algebra worklist #1 (`docs/effect-algebra.md` §7): `fireFetchEventActivation`
historically passed empty `TapePayloads` to `captureLogWithId`, so a
fetch-Pattern-A handler reading `request.activation.bytes` (the upstream
chunk) had no record of the input it saw — replay couldn't reconstitute
the same handler invocation. Phase 2D's tape hook fills
`TapePayloads.activation_bytes` for `fetch_chunk` activations; the
flush writer emits it as `activation_bytes_b64` on each log record.

This smoke proves the capture end-to-end. Drives the same
/fetchchunks handler as `fetch_chunk_smoke.py` (3 chunks of the
170-byte wb/bulk body) and then queries log-server for the captured
records. Asserts:

1. Each `fetch_chunk` log record carries a non-null `activation_bytes_b64`.
2. The base64-decoded bytes reconstruct the upstream body byte-exactly
   when concatenated in seq order.
3. The terminal `fetch_done` record has empty / null `activation_bytes_b64`
   (no chunk bytes on a terminal — only the chunk variant carries them).

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

        # Poll log-server for the chunk + done records. Each
        # activation produces one log record with the matching
        # ActivationSource tag.
        records = []
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            body = _ls(jwt, f"{c.log_url()}/v1/{ACME_ID}/list?limit=50")
            try:
                d = json.loads(body)
            except json.JSONDecodeError:
                d = {}
            records = d.get("records", [])
            # The summary endpoint doesn't include `activation`; filter
            # by path. The fetch chain dispatches `fetchchunk.mjs` per
            # chunk and `fetchdone.mjs` on terminal.
            chunk_recs = [r for r in records if r.get("path") == "fetchchunk"]
            done_recs = [r for r in records if r.get("path") == "fetchdone"]
            if len(chunk_recs) >= 3 and len(done_recs) >= 1:
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
        done_recs = [r for r in records if r.get("path") == "fetchdone"]
        print(f"ok  surfaced {len(chunk_recs)} fetchchunk + {len(done_recs)} fetchdone records")

        # Fetch the full record for each chunk + the terminal. The
        # `list` endpoint returns summaries; the `show` endpoint
        # carries the tape fields.
        full_chunks = []
        for r in chunk_recs[:3]:
            show = _ls(jwt, f"{c.log_url()}/v1/{ACME_ID}/show/{r['request_id']}")
            rec = json.loads(show)["record"]
            full_chunks.append(rec)

        # Phase 2D primary assertion: each fetch_chunk record has
        # non-null activation_bytes_b64.
        captured_blobs = []
        for i, rec in enumerate(full_chunks):
            tapes = rec.get("tapes", {})
            b64 = tapes.get("activation_bytes_b64")
            if not b64:
                sys.exit(
                    f"FAIL fetch_chunk record {i} (request_id={rec['request_id']}) "
                    f"missing activation_bytes_b64. tapes keys={list(tapes.keys())}"
                )
            captured_blobs.append(base64.b64decode(b64))
        print("ok  every fetch_chunk record carries activation_bytes_b64")

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

        # Terminal record carries no activation_bytes (terminals have
        # no input chunk; only chunk variants do).
        for done in done_recs[:1]:
            show = _ls(jwt, f"{c.log_url()}/v1/{ACME_ID}/show/{done['request_id']}")
            rec = json.loads(show)["record"]
            tapes = rec.get("tapes", {})
            b64 = tapes.get("activation_bytes_b64")
            if b64:
                sys.exit(
                    f"FAIL fetch_done record (request_id={rec['request_id']}) "
                    f"unexpectedly carries activation_bytes_b64={b64!r}"
                )
        print("ok  fetch_done record has null activation_bytes_b64 (correct — no chunk on terminal)")

        print("\nPhase 2D tape capture smoke passed (algebra §7 worklist #1 closed: "
              "fetch-A chunk bytes are now taped and replay-reconstructable).")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
