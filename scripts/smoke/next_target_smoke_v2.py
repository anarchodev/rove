#!/usr/bin/env python3
"""One `next()` semantic on every held chain: a returned continuation's
cross-module target re-aims the chain — WS and stream families included —
and a park with no possible resume source fails loud at park time instead
of hanging to the 25 s hold-deadline 504 (docs/handler-shape.md §2.1).

Legs:
  A. WS module handoff — a lobby `onMessage` returns
     `next("rooms/chat.mjs", {room})`; every later frame dispatches at the
     TARGET module (distinct kv write + reply prefix prove it; a decoy
     write proves the lobby module did NOT re-enter).
  B. Streaming-activation cross-module hold — an SSE first hop
     (`stream.start()` + `after.kv`) parks at `next("flows/sink.mjs", …)`;
     the kv wake runs the target's `onWake` (distinct kv write + frame),
     with the origin ctx threaded.
  C. Wake-less park — `return next({})` with no arm/binding/fetch is an
     immediate defined 500 naming the mistake ("held with no wake
     source"), not a 25 s 504.

Single-node. WS goes through the front door (the WS smokes' shape); the
held SSE GET goes DIRECT to the node (the front does not pass an open
event-stream through — same posture as stream_effect_smoke_v2.py).

Needs S3 env: `set -a; . ./.env; set +a` first.
Binaries: `zig build rewind-worker rewind-cp rewind-front`.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402
from ws_wake_smoke_v2 import ws_connect, send_text, recv_text, OP_TEXT  # noqa: E402

TENANT = "nexttar"

# Root probe + query-driven kv read/write (the wswake shape: writes go
# through a handler so the commit-gated kv_wake_broadcast fires).
INDEX_SRC = r"""export default function () {
  const params = new URLSearchParams(request.query || "");
  const setk = params.get("set");
  if (setk) { kv.set(setk, params.get("val") || ""); return "set:" + setk; }
  const getk = params.get("get");
  if (getk) { const v = kv.get(getk); return v === null ? "<null>" : v; }
  return "ready";
}
"""

# Leg A: the lobby hands the connection off to rooms/chat.mjs on join.
LOBBY_SRC = r"""export function onMessage() {
  const { data } = request.activation;
  if (data === "join") {
    kv.set("lobby/joined", "1");
    stream.write("lobby:ok");
    return next("rooms/chat.mjs", { room: "r1" });
  }
  // Decoy: if a post-handoff frame re-enters the lobby, this write exists.
  kv.set("lobby/decoy", data);
  stream.write("lobby:decoy:" + data);
  return next();
}
"""

CHAT_SRC = r"""export function onMessage() {
  const { data } = request.activation;
  const room = request.ctx ? request.ctx.room : "<noctx>";
  kv.set("chat/got", data + ":" + room);
  stream.write("chat:" + data + ":" + room);
  return next({ room });
}
"""

# Leg B: SSE first hop parks the chain at flows/sink.mjs.
SSE_SRC = r"""export default function () {
  response.status = 200;
  response.headers = { "content-type": "text/event-stream" };
  stream.start();
  stream.write("event: ready\n\n");
  after.kv("job/");
  return next("flows/sink.mjs", { origin: "sse" });
}

// Decoy: a wake that re-enters THIS module (ignoring the target) writes it.
export function onWake() {
  kv.set("sse/decoy", "1");
  after.kv("job/");
  return next();
}
"""

SINK_SRC = r"""export function onWake() {
  kv.set("sink/woke", request.ctx ? request.ctx.origin : "<noctx>");
  stream.write("event: sink\n\n");
  after.kv("job/");
  return next({ origin: "sink" });
}
"""

# Leg C: a park with no possible resume source.
ORPHAN_SRC = r"""export default function () {
  return next({ n: 1 });
}
"""


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("nexttarget", nodes=1) as c:
        r = c.provision(TENANT)
        check("provision → 200", r.status == 200, f"got {r.status}")
        try:
            c.deploy_handlers(TENANT, {
                "index.mjs": INDEX_SRC,
                "lobby/index.mjs": LOBBY_SRC,
                "rooms/chat.mjs": CHAT_SRC,
                "sse/index.mjs": SSE_SRC,
                "flows/sink.mjs": SINK_SRC,
                "orphan/index.mjs": ORPHAN_SRC,
            })
        except RuntimeError as e:
            check("deploy", False, str(e))
            print(f"FAILURES: {failures}")
            return 1
        ready = c.wait_for_handler(TENANT, "/", want_body="ready")
        check("deployment loaded", ready.status == 200, f"got {ready.status}")

        # ── Leg A: WS module handoff ──
        print("leg A: WS onMessage cross-module handoff (lobby → rooms/chat.mjs)")
        sock = ws_connect(c.front_port, c.host_for(TENANT), "/lobby")
        send_text(sock, "join")
        op, pl = recv_text(sock)
        check("lobby handled the join frame", pl == b"lobby:ok", f"pl={pl!r}")
        send_text(sock, "hello")
        try:
            op, pl = recv_text(sock)
            check("post-handoff frame ran the TARGET module with threaded ctx",
                  op == OP_TEXT and pl == b"chat:hello:r1", f"op={op} pl={pl!r}")
        except Exception as e:
            check("post-handoff frame ran the TARGET module", False, repr(e))
            c.dump_node_log(grep=["ws", "chat", "lobby", "next", "error", "warn"])
        sock.close()
        time.sleep(0.4)  # let the writing frame commit before reading back
        got = c.get(TENANT, "/?get=chat/got")
        check("target module's distinct kv write landed",
              got.status == 200 and "hello:r1" in got.body,
              f"got {got.status} {got.body!r}")
        decoy = c.get(TENANT, "/?get=lobby/decoy")
        check("lobby did NOT re-enter after the handoff",
              decoy.status == 200 and "<null>" in decoy.body,
              f"got {decoy.status} {decoy.body!r}")

        # ── Leg B: streaming activation parks at the cross-module target ──
        print("leg B: SSE hold parks at flows/sink.mjs; kv wake runs it")
        args = ["curl", "-sS", "--http2-prior-knowledge", "-N",
                "--max-time", "4.0", "-o", "-", "-X", "GET",
                "-H", f"Host: {c.host_for(TENANT)}",
                f"{c.node_url(0)}/sse"]
        watcher = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.6)  # let the inbound hop park + arm
        w = c.node_request("/?set=job/1&val=go", host=c.host_for(TENANT))
        check("trigger write accepted", w.status == 200 and "set:job/1" in w.body,
              f"got {w.status} {w.body!r}")
        try:
            stdout, _ = watcher.communicate(timeout=6.0)
        except subprocess.TimeoutExpired:
            watcher.kill()
            stdout, _ = watcher.communicate()
        body = (stdout or b"").decode(errors="replace")
        check("first-hop frame shipped", "event: ready" in body, f"body={body!r}")
        check("kv wake ran the TARGET module (sink frame)",
              "event: sink" in body, f"body={body!r}")
        woke = c.get(TENANT, "/?get=sink/woke")
        check("target onWake wrote with the threaded ctx",
              woke.status == 200 and "sse" in woke.body,
              f"got {woke.status} {woke.body!r}")
        sse_decoy = c.get(TENANT, "/?get=sse/decoy")
        check("parking module's onWake did NOT run",
              sse_decoy.status == 200 and "<null>" in sse_decoy.body,
              f"got {sse_decoy.status} {sse_decoy.body!r}")
        if "event: sink" not in body:
            c.dump_node_log(grep=["sink", "sse", "wake", "stream", "park",
                                  "error", "warn"])

        # ── Leg C: wake-less park fails loud at park time ──
        print("leg C: wake-less next() → immediate defined 500")
        t0 = time.monotonic()
        orphan = c.get(TENANT, "/orphan")
        elapsed = time.monotonic() - t0
        check("wake-less park → 500", orphan.status == 500,
              f"got {orphan.status} {orphan.body!r}")
        check("error names the mistake", "held with no wake source" in orphan.body,
              f"body={orphan.body!r}")
        check("failure is immediate (not the 25 s deadline 504)", elapsed < 5.0,
              f"elapsed={elapsed:.1f}s")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS next()-target smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
