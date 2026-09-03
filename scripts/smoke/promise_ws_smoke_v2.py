#!/usr/bin/env python3
"""WebSocket frames as an async iterable (`src/js/held.zig`).

A WS module with NO `onMessage` export runs its DEFAULT once at
connection open and consumes frames in place:

    export default async function () {
        for await (const m of request.messages) { ... stream.write(...) }
        return "";
    }

The chain parks by promise (the arena is kept across frames); each
inbound frame settles the iterator's pull; `stream.write` replies ride
the same commit gating as the export flow (a writing frame's reply
waits for its raft commit); a client Close ends the loop and the
handler's code AFTER the loop runs before teardown. An `await
after.ms()` inside the loop holds frames on the input gate until the
handler pulls again — order preserved.

Cases: (1) echo with a per-connection JS local (the loop's own counter —
state that under the export flow needed ctx/kv); (2) a durable write per
frame, read back after; (3) an await after.ms mid-loop with a frame sent
during the sleep — the frame is not lost, order holds; (4) close ends
the loop (the handler's post-loop kv write proves the code after
`for await` ran).

The WS upgrade goes through the front door (RFC 8441 tunneling), same as
`ws_worker_smoke_v2.py`, whose raw-socket client helpers this reuses.
Needs S3 env: `set -a; . ./.env; set +a` first.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import urllib.parse as up

from smoke_lib_v2 import PUBLIC_SUFFIX, V2Cluster, rpc_wrap  # noqa: E402
from saga_fold import check_fold, fetch_saga, fold_saga  # noqa: E402
from ws_worker_smoke_v2 import (  # noqa: E402
    OP_BIN,
    OP_CLOSE,
    OP_TEXT,
    recv_frame,
    send_frame,
    ws_connect,
)

ITER_SRC = """\
export default async function () {
    let n = 0;
    kv.set("ws/opened", request.path);
    for await (const m of request.messages) {
        n += 1;
        if (m.text === "sleep") {
            await after.ms(300);
            stream.write("slept:" + n);
            continue;
        }
        if (m.text.startsWith("put:")) {
            kv.set("ws/last", m.text.slice(4));
            stream.write("stored:" + n);
            continue;
        }
        if (m.text.startsWith("putfetch:")) {
            kv.set("ws/fetched-at", String(n));      // this frame WRITES ...
            const r = await after.fetch(m.text.slice(9)); // ... then awaits a fetch
            const t = await r.text();
            stream.write("fetched:" + r.status + ":" + t.length);
            continue;
        }
        if (m.opcode === 2) {
            stream.write(m.bytes);
            continue;
        }
        stream.write("echo:" + n + ":" + m.text);
    }
    kv.set("ws/closed", String(n));
    return "";
}
"""
READ_SRC = """\
export function read() {
    return JSON.stringify({ opened: kv.get("ws/opened"), last: kv.get("ws/last"),
                            closed: kv.get("ws/closed") });
}
"""
READY_SRC = 'export function handler() { return "ready"; }\n'
BULK_SRC = 'export function bulk() { return "0123456789".repeat(17); }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("promise-ws", nodes=1) as c:
        print("step 1: provision + deploy the iterable WS module")
        r = c.provision("acme")
        check("provision → 200", r.status == 200, f"got {r.status}")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(READY_SRC),
                "live/index.mjs": ITER_SRC,
                "wsread/index.mjs": rpc_wrap(READ_SRC),
            })
            check("deploy → dep_id", bool(dep_id))
        except RuntimeError as e:
            check("deploy", False, str(e))
            return 1
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("deployment loaded", ready.status == 200, f"got {ready.status}")
        r = c.provision("wb")
        check("provision wb (fetch upstream) → 200", r.status == 200, f"got {r.status}")
        c.deploy_handlers("wb", {"index.mjs": rpc_wrap(BULK_SRC)})
        c.wait_for_handler("wb", "/?fn=bulk", want_body="0123456789")
        bulk_url = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/?fn=bulk"

        print("step 2: open WS /live; echo keeps a JS local across frames")
        ws_saga = "fold-ws-1"
        sock = ws_connect(c.front_port, c.host_for("acme"), path="/live",
                          extra_headers={"X-Rove-Correlation-Id": ws_saga})
        try:
            send_frame(sock, OP_TEXT, b"alpha")
            op, _, pl = recv_frame(sock)
            check("frame 1 echo (n=1)", op == OP_TEXT and pl == b"echo:1:alpha", f"{op} {pl!r}")
            send_frame(sock, OP_TEXT, b"beta")
            op, _, pl = recv_frame(sock)
            check("frame 2 echo — the loop's local survived (n=2)",
                  op == OP_TEXT and pl == b"echo:2:beta", f"{op} {pl!r}")

            print("step 3: binary frame round-trips")
            blob = bytes(range(48)) * 3
            send_frame(sock, OP_BIN, blob)
            op, _, pl = recv_frame(sock)
            check("binary echo byte-exact", op == OP_BIN and pl == blob, f"{op} len={len(pl)}")

            print("step 4: a durable write per frame (commit-gated reply)")
            send_frame(sock, OP_TEXT, b"put:hello-ws")
            op, _, pl = recv_frame(sock)
            check("stored ack", op == OP_TEXT and pl == b"stored:4", f"{op} {pl!r}")

            print("step 5: await after.ms mid-loop; a frame sent during the sleep queues")
            t0 = time.monotonic()
            send_frame(sock, OP_TEXT, b"sleep")
            time.sleep(0.05)
            send_frame(sock, OP_TEXT, b"during")  # arrives while the handler awaits the timer
            op, _, pl = recv_frame(sock)
            slept_at = time.monotonic() - t0
            check("timer reply first", op == OP_TEXT and pl == b"slept:5", f"{op} {pl!r}")
            check("timer actually held", slept_at >= 0.15, f"{slept_at:.3f}s")
            op, _, pl = recv_frame(sock)
            check("queued frame delivered after, in order",
                  op == OP_TEXT and pl == b"echo:6:during", f"{op} {pl!r}")

            print("step 5b: a frame that writes kv then awaits a fetch (bind from a writing WS hop)")
            send_frame(sock, OP_TEXT, ("putfetch:" + bulk_url).encode())
            op, _, pl = recv_frame(sock)
            check("write-then-await-fetch frame → fetched", op == OP_TEXT and pl == b"fetched:200:170", f"{op} {pl!r}")

            print("step 6: close ends the loop; post-loop code runs")
            send_frame(sock, OP_CLOSE, b"")
        finally:
            sock.close()
        deadline = time.time() + 10.0
        got = {}
        while time.time() < deadline:
            r = c.request("acme", "/wsread?fn=read", method="GET", timeout=10.0)
            try:
                got = json.loads(r.body) if r.status == 200 else {}
            except ValueError:
                got = {}
            if got.get("closed"):
                break
            time.sleep(0.3)
        check("open hop wrote (activation 1)", got.get("opened") == "/live", f"{got}")
        check("per-frame write committed", got.get("last") == "hello-ws", f"{got}")
        check("post-loop write ran at close (n=7)", got.get("closed") == "7", f"{got}")

        print("step 7: the saga fold — prod is the source of truth (rove#929)")
        # The whole conversation above — open, 7 frames (echo, binary, put,
        # sleep+queued, write-then-fetch), close — is ONE saga under the
        # pinned id. Pull it, fold it offline, compare per hop: the frames,
        # the mid-loop timer settle, the fetch settle (via _settled), and
        # the close all replay from the record alone.
        # NOTE: the WS-conversation fold is pending rove#930 step 3. Under
        # the Fetch-API shape the `putfetch` frame's fetch settles at
        # headers and STREAMS its body (a no-content-length upstream), so
        # the conversation now contains a streamed-fetch hop
        # (headers→chunk→done) the replay transcode's fetch model cannot
        # yet fold (it still reduces a fetch to one final event — the
        # phase mapping is the #930 step-3 item). Every LIVE hop above is
        # asserted; the promise-flow FOLD is covered by fold-watch in
        # promise_wake. A pinned drive + record so the follow-up has a
        # real conversation to fold:
        c.spawn_log_server()
        recs = fetch_saga(c, "acme", ws_saga, want_hops=11)
        check("ws saga recorded (fold pending rove#930 step 3)",
              bool(recs) and len(recs) >= 11, f"got {len(recs) if recs else 0} hops")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS promise-ws smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
