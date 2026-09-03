#!/usr/bin/env python3
"""S3a streamed inbound — one inbound handler, size decides (rove#931).

Proves, against a single rewind node, the stage-1b worker producer for
the streamed-inbound contract the sim pinned (`request.chunks`,
src/js/held.zig): the `default` export is the only inbound entry, and
the BODY SIZE picks the delivery mode —

  - ≤ cap: classic buffered dispatch; `request.text` works and
    `request.chunks` yields the whole payload once (uniform surface).
  - crossing the cap: `default` runs HELD with an empty body; each sink
    fire settles the outstanding `request.chunks` pull
    (`held.SettleInput.chunk`), the iterator ends `{done:true}`, and the
    handler runs on to its terminal. `request.text`/`.bytes`/`.json`
    THROW naming the iterable — never a silent prefix.

Cases:
  1. small POST (front door): buffered — one chunk, text readable
  2. 600 KiB POST, declared length (curl content-length > the 64 KiB
     override cap): streamed — exact byte count, multi-chunk, a kv WRITE
     on every chunk hop (propose + repark backpressure), text throw
     observed in-handler
  3. kv readback: the per-hop writes and the final write all committed
  4. 600 KiB POST, UNDECLARED (curl -T: no content-length — the classic
     buffering path's crossing): streamed through the complete-in-hand
     (sinkless job) arm, same contract
  5. a default that ignores the body answers while the body may still
     be inbound (early terminal on a streamed dispatch)
  6. a default that reads `request.text` on a crossed body fails LOUDLY
     (the old up-front 413's replacement: the error names the iterable)

The tenant's plan carries a `max_body_bytes` override (64 KiB) so the
crossing bodies stay small; the override is verified by read-back before
any case runs (a precondition write must retry AND raise).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import HttpResponse, V2Cluster, rpc_wrap  # noqa: E402
from saga_fold import check_fold, fetch_saga, fold_saga  # noqa: E402

CAP = 64 * 1024

UPLOAD_SRC = """\
export default async function () {
    let wholeErr = "";
    try { void request.text; } catch (e) { wholeErr = String(e); }
    let n = 0, chunks = 0;
    for await (const ck of request.chunks) {
        n += ck.bytes.length;
        chunks += 1;
        kv.set("up/seen", String(chunks));
    }
    const seen = kv.get("up/seen");
    kv.set("up/len", String(n));
    response.status = 201;
    response.headers["content-type"] = "application/json";
    return JSON.stringify({ n: n, chunks: chunks, wholeErr: wholeErr, seen: seen });
}
"""

READ_SRC = """\
export function read() {
    return JSON.stringify({ len: kv.get("up/len"), seen: kv.get("up/seen") });
}
"""

IGNORE_SRC = """\
export default function () {
    response.status = 200;
    return "ignored";
}
"""

TEXTONLY_SRC = """\
export default function () {
    return "len:" + request.text.length;
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'


def _paced_post(c: V2Cluster, path: str, host: str, body: bytes, *,
                saga: str, rate: str = "24k",
                timeout: float = 60.0) -> HttpResponse:
    """Declared-length POST paced by --limit-rate so every sink fire is one
    h2 DATA frame (≤ 16 KiB = the inline tape threshold) — the offline
    fold composer reads inline trigger payloads only."""
    from smoke_lib_v2 import _curl_run
    args = ["curl", "-sS", "--http2-prior-knowledge", "-D", "-", "-o", "-",
            "-m", str(int(timeout)), "-X", "POST", "--limit-rate", rate,
            "--data-binary", "@-",
            "-H", f"Host: {host}", "-H", f"x-rove-correlation-id: {saga}",
            f"{c.node_url()}{path}"]
    return _curl_run(args, body, timeout)


def _undeclared_post(c: V2Cluster, path: str, host: str, body: bytes,
                     timeout: float = 30.0) -> HttpResponse:
    """POST with NO content-length (curl -T streams stdin) — reaches the
    classic buffering path's undeclared crossing, not the declared-length
    pre-buffer decision."""
    from smoke_lib_v2 import _curl_run
    args = ["curl", "-sS", "--http2-prior-knowledge", "-D", "-", "-o", "-",
            "-m", str(int(timeout)), "-X", "POST", "-T", "-",
            "-H", f"Host: {host}", f"{c.node_url()}{path}"]
    return _curl_run(args, body, timeout)


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("streamin", nodes=1) as c:
        print("step 1: provision 'acme' + cap override (max_body_bytes = 64 KiB)")
        r = c.provision("acme")
        check("provision → 200", r.status == 200, f"got {r.status} {r.body!r}")
        c._cp_post("/_control/plan", {
            "tenant": "acme",
            "plan": json.dumps({"overrides": {"outbound_enabled": True,
                                              "max_body_bytes": CAP}}),
        })
        # Precondition read-back: the override must be LIVE on the worker
        # before any size-decided case runs.
        deadline = time.time() + 20.0
        live = False
        while time.time() < deadline:
            pr = c.get_plan("acme")
            if pr.status == 200 and f'"max_body_bytes":{CAP}' in pr.body.replace(" ", ""):
                live = True
                break
            time.sleep(0.5)
        check("cap override live on the worker", live,
              "" if live else "get_plan never showed the override")
        if not live:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 2: deploy (upload consumer, readback, ignore, text-only)")
        dep_id = c.deploy_handlers("acme", {
            "index.mjs": rpc_wrap(READY_SRC),
            "up/index.mjs": UPLOAD_SRC,
            "upread/index.mjs": rpc_wrap(READ_SRC),
            "noread/index.mjs": IGNORE_SRC,
            "textonly/index.mjs": TEXTONLY_SRC,
        })
        check("deploy", bool(dep_id))
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("deployment serves", ready.status == 200, f"got {ready.status} {ready.body!r}")
        host = c.host_for("acme")

        print("step 3: small POST (front door) — buffered, uniform surface")
        small = b"a" * 1024
        r = c.request("acme", "/up", method="POST", data=small, timeout=30.0)
        body = {}
        if r.status == 201:
            try:
                body = json.loads(r.body)
            except ValueError:
                pass
        check("small → 201", r.status == 201, f"got {r.status} {r.body[:120]!r}")
        check("small: one chunk, exact bytes", body.get("n") == 1024 and body.get("chunks") == 1,
              f"body={body}")
        check("small: request.text readable (no throw)", body.get("wholeErr") == "",
              f"body={body}")

        print("step 4: 600 KiB declared POST — streamed held, per-hop kv writes")
        big = bytes(bytearray(range(256)) * (600 * 4))  # 600 KiB, patterned
        t0 = time.monotonic()
        r = c.node_request("/up", method="POST", host=host, data=big)
        elapsed = time.monotonic() - t0
        body = {}
        if r.status == 201:
            try:
                body = json.loads(r.body)
            except ValueError:
                pass
        check("streamed → 201", r.status == 201, f"got {r.status} {r.body[:160]!r} ({elapsed:.1f}s)")
        check("streamed: exact byte count", body.get("n") == len(big), f"body n={body.get('n')} want {len(big)}")
        check("streamed: multi-chunk", (body.get("chunks") or 0) >= 2, f"chunks={body.get('chunks')}")
        check("streamed: request.text threw naming the iterable",
              "request.chunks" in (body.get("wholeErr") or ""), f"wholeErr={body.get('wholeErr')!r}")
        check("streamed: every chunk hop's write visible at the end",
              body.get("seen") == str(body.get("chunks")), f"body={body}")
        if r.status != 201:
            c.dump_node_log(grep=["held", "chunk", "streamed", "error", "warn", "413"])

        print("step 5: kv readback — the hop writes committed")
        r = c.request("acme", "/upread?fn=read", method="GET", timeout=10.0)
        got = {}
        try:
            got = json.loads(r.body) if r.status == 200 else {}
        except ValueError:
            pass
        check("readback: final length committed", got.get("len") == str(len(big)),
              f"got {r.status} {r.body!r}")

        print("step 6: 600 KiB UNDECLARED POST (curl -T) — the buffered-crossing arm")
        r = _undeclared_post(c, "/up", host, big)
        body = {}
        if r.status == 201:
            try:
                body = json.loads(r.body)
            except ValueError:
                pass
        check("undeclared streamed → 201", r.status == 201, f"got {r.status} {r.body[:160]!r}")
        check("undeclared: exact byte count", body.get("n") == len(big),
              f"body n={body.get('n')} want {len(big)}")
        check("undeclared: request.text threw", "request.chunks" in (body.get("wholeErr") or ""),
              f"wholeErr={body.get('wholeErr')!r}")

        print("step 7: a default that ignores the body answers early")
        r = c.node_request("/noread", method="POST", host=host, data=big)
        check("ignore-body → 200 while streaming", r.status == 200 and "ignored" in r.body,
              f"got {r.status} {r.body[:80]!r}")

        print("step 8: whole-body read on a crossed body fails LOUDLY (never a prefix)")
        r = c.node_request("/textonly", method="POST", host=host, data=big)
        check("text-only + crossed body → 500 (a throw, not a truncated 200)",
              r.status == 500, f"got {r.status} {r.body[:120]!r}")
        check("no silent prefix served", "len:" not in r.body, f"got {r.body[:120]!r}")

        print("step 9: ⭐ the saga fold — streamed chain (hold → chunk… → eof → 201)")
        # A pinned saga id + a paced upload (one h2 frame per fire keeps
        # every chunk payload inline on the tape); then pull the saga,
        # fold it offline, and compare per hop — prod is the source of
        # truth (rove#929/#931).
        c.spawn_log_server()
        saga = "fold-stream-1"
        fold_body = b"0123456789abcdef" * 5120  # 80 KiB, ASCII
        r = _paced_post(c, "/up", host, fold_body, saga=saga)
        check("fold chain drove → 201", r.status == 201, f"got {r.status} {r.body[:120]!r}")
        recs = fetch_saga(c, "acme", saga, want_hops=3)
        check("fold saga recorded (hold → chunks → terminal)", bool(recs),
              "saga not indexed in time")
        if recs:
            hops = fold_saga(recs, "acme", {"index.mjs": UPLOAD_SRC}, c=c)
            check_fold(check, "fold-stream", recs, hops)

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streamed-inbound smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
