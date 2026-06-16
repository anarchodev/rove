#!/usr/bin/env python3
"""WS connection-trigger smoke — proves `on.kv` and `on.timer` wake a HELD
WebSocket chain (the `pending_wakes` path), the sibling of the `on.fetch`
WS resume proven by `agent_smoke_v2.py`.

A deployed handler arms a wake from `onMessage` and parks via `next()`; when
the wake fires (a kv write under the watched prefix, or the timer elapsing),
the chain resumes its `onWake`/`onTimer` export and `stream.write`s a frame
back over the SAME socket.

Asserts:
  1. `watch:<prefix>` → on.kv(prefix) armed, reply "watching:<prefix>"
  2. a kv write under the prefix (via /_system/v2-kv) → onWake → "woke:<value>"
  3. `timer` → on.timer armed, reply "armed", then "tick" within ~2s

Needs S3 env: `set -a; . ./.env; set +a` first.
Binaries: `zig build rewind-worker rewind-cp rewind-front`.
"""

from __future__ import annotations

import base64
import hashlib
import os
import socket
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

TENANT = "wswake"
OP_TEXT = 0x1
OP_CLOSE = 0x8
ACCEPT_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

HANDLER_SRC = """\
export default function () {
  // GET /?set=<key>&val=<value> writes via a handler so the commit-gated
  // kv_wake_broadcast fires (admin /_system/v2-kv does not wake watchers).
  const q = request.query || "";
  const params = new URLSearchParams(q);
  const key = params.get("set");
  if (key) { kv.set(key, params.get("val") || ""); return "set:" + key; }
  return "ready";
}

export function onMessage() {
  const { data } = request.activation;
  if (data.startsWith("watch:")) {            // arm an on.kv wake
    const prefix = data.slice(6);
    on.kv(prefix, { to: "onWake" });
    stream.write("watching:" + prefix);
    return next({ prefix });
  }
  if (data === "timer") {                      // arm an on.timer wake
    on.timer(500, { to: "onTimer" });
    stream.write("armed");
    return next();
  }
  stream.write("echo:" + data);
  return next();
}

export function onWake() {                      // kv under the prefix changed
  // Edge "go look" wake: re-read authoritative kv (onWake doesn't get
  // request.ctx — it re-reads the watched prefix it knows it armed).
  const rows = kv.prefix("feed/");
  const last = rows.length ? rows[rows.length - 1].value : "<none>";
  stream.write("woke:" + last);
  return next();
}

export function onTimer() {                     // the timer elapsed
  stream.write("tick");
  return next();
}
"""


def _accept(key):
    return base64.b64encode(hashlib.sha1((key + ACCEPT_MAGIC).encode()).digest()).decode()


def encode_frame(opcode, payload, fin=True):
    b0 = (0x80 if fin else 0) | opcode
    out = bytearray([b0])
    n = len(payload)
    if n <= 125:
        out.append(0x80 | n)
    else:
        out.append(0x80 | 126)
        out += struct.pack(">H", n)
    mkey = os.urandom(4)
    out += mkey
    out += bytes(b ^ mkey[i & 3] for i, b in enumerate(payload))
    return bytes(out)


def send_text(sock, s):
    sock.sendall(encode_frame(OP_TEXT, s.encode()))


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c:
            raise EOFError("closed mid-frame")
        buf += c
    return buf


def recv_text(sock):
    b0, b1 = recv_exact(sock, 2)
    opcode = b0 & 0x0F
    length = b1 & 0x7F
    if length == 126:
        length = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(sock, 8))[0]
    payload = recv_exact(sock, length) if length else b""
    return opcode, payload


def ws_connect(port, host, path="/"):
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    sock.settimeout(10)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((
        f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n"
    ).encode())
    data = b""
    while b"\r\n\r\n" not in data:
        c = sock.recv(4096)
        if not c:
            raise EOFError("closed in handshake")
        data += c
    head = data.split(b"\r\n\r\n", 1)[0].decode("latin1").split("\r\n")
    assert head[0] == "HTTP/1.1 101 Switching Protocols", head[0]
    hdrs = {k.strip().lower(): v.strip() for k, _, v in (ln.partition(":") for ln in head[1:])}
    assert hdrs.get("sec-websocket-accept") == _accept(key), hdrs
    return sock


def main():
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("wswake", nodes=1) as c:
        r = c.provision(TENANT)
        check("provision → 204", r.status == 204, f"got {r.status}")
        try:
            c.deploy_handlers(TENANT, {"index.mjs": HANDLER_SRC})
        except RuntimeError as e:
            check("deploy", False, str(e))
            print(f"FAILURES: {failures}")
            return 1
        ready = c.wait_for_handler(TENANT, "/", want_body="ready")
        check("deployment loaded", ready.status == 200, f"got {ready.status}")

        sock = ws_connect(c.front_port, c.host_for(TENANT), "/")
        check("101 handshake", True)

        print("step: arm on.kv, write a key, expect onWake")
        send_text(sock, "watch:feed/")
        op, pl = recv_text(sock)
        check("on.kv armed", pl == b"watching:feed/", f"pl={pl!r}")
        # Write a key under the watched prefix via a handler (commit-gated
        # kv_wake_broadcast) → should wake the held chain.
        w = c.get(TENANT, "/?set=feed/1&val=hello")
        check("kv write accepted", w.status == 200 and "set:feed/1" in w.body,
              f"got {w.status} {w.body!r}")
        try:
            op, pl = recv_text(sock)
            check("on.kv woke the held chain", op == OP_TEXT and pl == b"woke:hello",
                  f"op={op} pl={pl!r}")
        except Exception as e:
            check("on.kv woke the held chain", False, repr(e))
            c.dump_node_log(grep=["wake", "onWake", "kv", "error", "warn"])

        print("step: arm on.timer, expect a tick")
        send_text(sock, "timer")
        op, pl = recv_text(sock)
        check("on.timer armed", pl == b"armed", f"pl={pl!r}")
        try:
            sock.settimeout(5)
            op, pl = recv_text(sock)
            check("on.timer fired (tick)", op == OP_TEXT and pl == b"tick",
                  f"op={op} pl={pl!r}")
        except Exception as e:
            check("on.timer fired (tick)", False, repr(e))
            c.dump_node_log(grep=["timer", "onTimer", "wake", "sweep", "error"])
        sock.close()

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nALL WS WAKE CHECKS PASSED ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
