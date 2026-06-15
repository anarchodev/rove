#!/usr/bin/env python3
"""WS strict-reply-ordering + speculative-read-gate smoke.

Two related guarantees on the read-only `onMessage` fast path, both of which
the piece-D baseline got wrong (this smoke was written against the bug first):

1. **Speculative-read gate (the panic).** A writing frame K parks its txn on
   the raft propose (kvexp chain predecessor stays open until commit). If
   frame K+1 arrives before K's commit lands and READS a key K wrote, its
   read resolves against K's uncommitted overlay (`saw_speculation`). kvexp's
   read-only commit fast path requires no-writes AND no-speculation; with
   speculation it demands chain-head → `error.NotChainHead` → the old code's
   `invariantViolated` panic killed the worker. (The HTTP path gates this via
   the idiom-0 barrier propose, `worker_dispatch.zig:707` — the WS path must
   too: the frame's reply also must not reveal un-durable state.)

2. **Strict reply ordering.** Replies on one connection arrive in message
   order even across the durability boundary — a read-only frame's reply must
   not overtake an in-flight writing frame's commit-gated reply (the
   DO-output-gate semantic; docs/websocket-plan.md §4.5).

The client sends a burst WITHOUT waiting for replies:
    persist:v1   (writing → commit-gated reply)
    read:        (read-only, reads the key v1 wrote → speculative)
    echo-a       (read-only, independent)
    persist:v2   (writing)
    echo-b       (read-only, independent)
then asserts every reply arrives, in exact order, with read: seeing v1.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import socket
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402
from ws_worker_smoke_v2 import (  # noqa: E402
    OP_TEXT, OP_CLOSE, encode_frame, send_frame, recv_frame, ws_connect,
)

TENANT = "wsorder"

HANDLER_SRC = """\
export default function () { return "ready"; }

export function onMessage() {
  const { opcode, data } = request.activation;
  if (data.startsWith("persist:")) {
    const v = data.slice(8);
    kv.set("ord/last", v);
    stream.write("persisted:" + v);
    return next();
  }
  if (data.startsWith("read:")) {
    const v = kv.get("ord/last");
    stream.write("value:" + (v ?? "<none>"));
    return next();
  }
  stream.write("echo:" + data);
  return next();
}

export function onDisconnect() {
  // Read-only onDisconnect (no writes) — exercises the disconnect-path
  // commit while a frame's propose may still be in flight.
  kv.get("ord/last");
}
"""

BURST = [
    b"persist:v1",
    b"read:",
    b"echo-a",
    b"persist:v2",
    b"echo-b",
]
EXPECTED = [
    b"persisted:v1",
    b"value:v1",
    b"echo:echo-a",
    b"persisted:v2",
    b"echo:echo-b",
]


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("wsorder", nodes=1) as c:
        # WS goes THROUGH THE FRONT (RFC 8441 Extended CONNECT tunnel) — the
        # worker is h2c-only, so a raw h1 Upgrade must terminate at the front.
        ws_port = c.front_port
        host = c.host_for(TENANT)

        print("step 1: provision + deploy")
        r = c.provision(TENANT)
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")
        c.deploy_handlers(TENANT, {"index.mjs": HANDLER_SRC})
        ready = c.wait_for_handler(TENANT, "/", want_body="ready")
        check("deployment loaded", ready.status == 200, f"got {ready.status} {ready.body!r}")
        if ready.status != 200:
            print(f"\nFAILURES: {failures}")
            return 1

        print("step 2: burst of 5 frames in ONE TCP segment (one wsDrive → "
              "back-to-back activations inside the commit window)")
        sock = ws_connect(ws_port, host)
        try:
            sock.sendall(b"".join(encode_frame(OP_TEXT, p) for p in BURST))
            replies = []
            try:
                for _ in BURST:
                    op, fin, pl = recv_frame(sock)
                    if op == OP_CLOSE:
                        replies.append(b"<CLOSE>")
                        break
                    replies.append(pl)
            except (EOFError, socket.timeout, ConnectionResetError) as e:
                replies.append(f"<{type(e).__name__}>".encode())
            check("all 5 replies arrived (worker alive, no panic)",
                  replies == EXPECTED or len(replies) == len(BURST),
                  f"got {replies}")
            check("replies in exact message order (incl. read-after-write value)",
                  replies == EXPECTED, f"got {replies}")
        finally:
            sock.close()

        # The worker must still be alive (the bug was a worker panic).
        alive = c.node_procs[0].poll() is None
        check("rewind node survived the burst", alive,
              f"rc={c.node_procs[0].poll()}")
        if not alive or failures:
            c.dump_node_log(grep=["panic", "invariant", "ws", "error"])

        print("step 3: second burst then immediate hard drop (onDisconnect "
              "races the in-flight commit)")
        if alive:
            s2 = ws_connect(ws_port, host)
            send_frame(s2, OP_TEXT, b"persist:v3")
            # Drop without reading the reply and without a Close frame — the
            # stale-sweep onDisconnect (read-only, sees v3's speculative
            # overlay if the commit hasn't landed) must not panic.
            s2.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                          struct.pack("ii", 1, 0))
            s2.close()
            # Give the sweep a few ticks, then prove the node survived and
            # still serves.
            import time
            deadline = time.time() + 10
            ok = False
            while time.time() < deadline:
                if c.node_procs[0].poll() is not None:
                    break
                kv = c.admin_kv_get(TENANT, "ord/last")
                if kv.status == 200 and "v3" in kv.body:
                    ok = True
                    break
                time.sleep(0.3)
            check("node alive + v3 committed after abrupt-drop disconnect",
                  ok and c.node_procs[0].poll() is None,
                  f"rc={c.node_procs[0].poll()}")
            if not ok:
                c.dump_node_log(grep=["panic", "invariant", "ws", "error"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nALL WS ORDERING + SPECULATION-GATE CHECKS PASSED ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
