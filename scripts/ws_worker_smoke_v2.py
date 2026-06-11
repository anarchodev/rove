#!/usr/bin/env python3
"""Inbound-WebSocket WORKER-SEAM smoke (docs/websocket-plan.md §4.6 pieces D+F).

`ws_echo_smoke.py` proved the rove-h2 transport (pieces A/B/C/E-h2) against the
collection-driving `ws-echo` example. This smoke proves the piece-D worker seam
end to end on the real V2 stack: a DEPLOYED JS handler's `onMessage` /
`onDisconnect` exports served over a raw RFC 6455 connection.

Topology: `V2Cluster` (single rewind node + CP + front + files-server-v2).
The WS upgrade goes THROUGH THE FRONT DOOR (websocket-plan §8.5): the front
terminates the handshake and tunnels the connection to the worker as an RFC
8441 Extended CONNECT stream on the pooled h2c conn — the production path.
`Host: {tenant}.localhost` routes the tunnel like any request.

Asserts:
  1. text frame → `onMessage` → `stream.write` text echo (read-only path,
     inline emit)
  2. binary frame with embedded NULs → echoed byte-identical as binary
     (guards the JS_ToCStringLen truncation class: Uint8Array in, raw bytes out)
  3. `persist:` frame → kv.set + reply (WRITING path: the reply frame is
     commit-gated behind the raft propose — batch-of-1 durability), then the
     value is visible via `/_system/v2-kv`
  4. `read:` frame → kv.get round-trip inside `onMessage`
  5. `bye` frame → terminal return → frames ship then the server sends Close
  6. client Close frame → `onDisconnect` runs (its kv write lands)
  7. abrupt TCP drop (no Close) → stale-chain sweep fires `onDisconnect`

Needs S3 env (V2 blob backend is S3-only): `set -a; . ./.env; set +a` first.
Binaries: `zig build rewind rewind-cp rewind-front files-server-v2`.
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

ACCEPT_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OP_CONT = 0x0
OP_TEXT = 0x1
OP_BIN = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

TENANT = "wstest"

# The deployed handler. `onMessage` is the ws_message activation's
# conventional export; `onDisconnect` runs on client close / conn death.
# `request` is a GLOBAL in the handler env (a parameter would shadow it
# with undefined — exports are invoked with no args).
# `request.activation = { kind:"ws_message", opcode, data }` — opcode 1
# surfaces `data` as a string, opcode 2 as a Uint8Array. `stream.write`
# emits a text frame for a string, a binary frame for bytes. `next()`
# parks the chain for the next frame; any terminal return closes.
HANDLER_SRC = """\
export default function () { return "ready"; }

export function onMessage() {
  const { opcode, data } = request.activation;
  if (opcode === 2) {              // binary → echo bytes back verbatim
    stream.write(data);
    return next();
  }
  if (data.startsWith("persist:")) {   // durable frame: reply commit-gated
    const v = data.slice(8);
    kv.set("ws/last", v);
    stream.write("persisted:" + v);
    return next();
  }
  if (data.startsWith("read:")) {      // kv read-back inside onMessage
    const v = kv.get("ws/last");
    stream.write("value:" + (v ?? "<none>"));
    return next();
  }
  if (data.startsWith("tag:")) {       // stamp who the next disconnect is
    const t = data.slice(4);
    kv.set("ws/tag", t);
    stream.write("tagged:" + t);
    return next();
  }
  if (data === "bye") {                // terminal return → server Close
    stream.write("closing");
    return "";
  }
  stream.write("echo:" + data);
  return next();
}

export function onDisconnect() {
  const tag = kv.get("ws/tag") ?? "none";
  kv.set("ws/disc_" + tag, "1");
}
"""


# ── raw RFC 6455 client (same shape as ws_echo_smoke.py) ──────────────


def expected_accept(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + ACCEPT_MAGIC).encode()).digest()).decode()


def encode_frame(opcode, payload: bytes, fin=True) -> bytes:
    """One masked client→server frame as bytes (callers may coalesce
    several into one sendall to land them in a single read/tick)."""
    b0 = (0x80 if fin else 0) | opcode
    out = bytearray([b0])
    n = len(payload)
    if n <= 125:
        out.append(0x80 | n)
    elif n <= 0xFFFF:
        out.append(0x80 | 126)
        out += struct.pack(">H", n)
    else:
        out.append(0x80 | 127)
        out += struct.pack(">Q", n)
    mkey = os.urandom(4)
    out += mkey
    out += bytes(b ^ mkey[i & 3] for i, b in enumerate(payload))
    return bytes(out)


def send_frame(sock, opcode, payload: bytes, fin=True):
    sock.sendall(encode_frame(opcode, payload, fin))


def recv_exact(sock, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed mid-frame")
        buf += chunk
    return buf


def recv_frame(sock):
    """One server→client frame → (opcode, fin, payload). Never masked."""
    b0, b1 = recv_exact(sock, 2)
    fin = bool(b0 & 0x80)
    opcode = b0 & 0x0F
    assert not (b1 & 0x80), "server frame must not be masked"
    length = b1 & 0x7F
    if length == 126:
        length = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(sock, 8))[0]
    payload = recv_exact(sock, length) if length else b""
    return opcode, fin, payload


def ws_connect(port: int, host_header: str, path: str = "/") -> socket.socket:
    """TCP connect to the node + RFC 6455 upgrade with a tenant Host header."""
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    sock.settimeout(10)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host_header}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(req.encode())
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise EOFError("server closed during handshake")
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    assert rest == b"", "server sent frame bytes before any client frame"
    lines = head.decode("latin1").split("\r\n")
    assert lines[0] == "HTTP/1.1 101 Switching Protocols", f"bad status line: {lines[0]!r}"
    hdrs = {}
    for ln in lines[1:]:
        k, _, v = ln.partition(":")
        hdrs[k.strip().lower()] = v.strip()
    assert hdrs.get("sec-websocket-accept") == expected_accept(key), hdrs
    return sock


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("wsworker", nodes=1) as c:
        ws_port = c.front_port
        host = c.host_for(TENANT)

        print("step 1: provision + deploy the onMessage handler")
        r = c.provision(TENANT)
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            dep_id = c.deploy_handlers(TENANT, {"index.mjs": HANDLER_SRC})
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            print(f"\nFAILURES: {failures}")
            return 1
        ready = c.wait_for_handler(TENANT, "/", want_body="ready")
        check("deployment loaded (GET / → ready)",
              ready.status == 200 and "ready" in ready.body,
              f"got {ready.status} {ready.body!r}")
        if ready.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "resolve", "error"])
            print(f"\nFAILURES: {failures}")
            return 1

        print("step 2: WS upgrade through the front (tenant Host)")
        try:
            sock = ws_connect(ws_port, host)
            check("101 handshake + accept key", True)
        except Exception as e:
            check("101 handshake + accept key", False, repr(e))
            c.dump_node_log(grep=["ws", "upgrade", "error"])
            print(f"\nFAILURES: {failures}")
            return 1

        print("step 3: text echo (read-only onMessage, inline emit)")
        try:
            send_frame(sock, OP_TEXT, b"hello")
            op, fin, pl = recv_frame(sock)
            check("text echo", op == OP_TEXT and fin and pl == b"echo:hello",
                  f"op={op} fin={fin} pl={pl!r}")
        except Exception as e:
            check("text echo", False, repr(e))
            c.dump_node_log(grep=["ws", "error", "warn"])

        print("step 4: binary echo with embedded NULs (Uint8Array fidelity)")
        blob = b"\x00\x01\x02\x00" + bytes(range(256)) + b"\x00tail\x00"
        try:
            send_frame(sock, OP_BIN, blob)
            op, fin, pl = recv_frame(sock)
            check("binary echo byte-identical",
                  op == OP_BIN and fin and pl == blob,
                  f"op={op} len={len(pl)} (want {len(blob)})")
        except Exception as e:
            check("binary echo byte-identical", False, repr(e))

        print("step 5: durable frame — kv.set, commit-gated reply")
        try:
            send_frame(sock, OP_TEXT, b"persist:alpha")
            op, fin, pl = recv_frame(sock)
            check("persisted reply (post-commit)",
                  op == OP_TEXT and pl == b"persisted:alpha", f"op={op} pl={pl!r}")
        except Exception as e:
            check("persisted reply (post-commit)", False, repr(e))
        kv = c.admin_kv_get(TENANT, "ws/last")
        check("kv ws/last == alpha via /_system/v2-kv",
              kv.status == 200 and "alpha" in kv.body,
              f"got {kv.status} {kv.body!r}")

        print("step 6: kv read-back inside onMessage")
        try:
            send_frame(sock, OP_TEXT, b"read:")
            op, fin, pl = recv_frame(sock)
            check("read round-trip", op == OP_TEXT and pl == b"value:alpha",
                  f"op={op} pl={pl!r}")
        except Exception as e:
            check("read round-trip", False, repr(e))

        print("step 7: terminal return → frames then server Close")
        try:
            send_frame(sock, OP_TEXT, b"bye")
            op, fin, pl = recv_frame(sock)
            check("terminal frame shipped", op == OP_TEXT and pl == b"closing",
                  f"op={op} pl={pl!r}")
            op, fin, pl = recv_frame(sock)
            check("server Close after terminal", op == OP_CLOSE, f"op={op}")
        except Exception as e:
            check("terminal close sequence", False, repr(e))
        finally:
            sock.close()

        print("step 8: client Close frame → onDisconnect")
        try:
            s2 = ws_connect(ws_port, host)
            send_frame(s2, OP_TEXT, b"tag:clean")
            op, _, pl = recv_frame(s2)
            check("tagged:clean", pl == b"tagged:clean", f"pl={pl!r}")
            send_frame(s2, OP_CLOSE, struct.pack(">H", 1000))
            # Transport echoes the Close; the worker routes opcode 8 → onDisconnect.
            op, _, pl = recv_frame(s2)
            check("close echoed", op == OP_CLOSE, f"op={op}")
            s2.close()
        except Exception as e:
            check("clean close sequence", False, repr(e))
        ok = False
        deadline = time.time() + 10
        while time.time() < deadline:
            kv = c.admin_kv_get(TENANT, "ws/disc_clean")
            if kv.status == 200 and "1" in kv.body:
                ok = True
                break
            time.sleep(0.3)
        check("onDisconnect ran on clean close (ws/disc_clean=1)", ok,
              f"last: {kv.status} {kv.body!r}")

        print("step 9: abrupt TCP drop → stale-chain sweep → onDisconnect")
        try:
            s3 = ws_connect(ws_port, host)
            send_frame(s3, OP_TEXT, b"tag:abrupt")
            op, _, pl = recv_frame(s3)
            check("tagged:abrupt", pl == b"tagged:abrupt", f"pl={pl!r}")
            # Hard drop: RST instead of FIN so the transport sees a dead conn,
            # not a half-close; no Close frame either way.
            s3.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                          struct.pack("ii", 1, 0))
            s3.close()
        except Exception as e:
            check("abrupt drop setup", False, repr(e))
        ok = False
        deadline = time.time() + 15
        while time.time() < deadline:
            kv = c.admin_kv_get(TENANT, "ws/disc_abrupt")
            if kv.status == 200 and "1" in kv.body:
                ok = True
                break
            time.sleep(0.3)
        check("onDisconnect ran via stale sweep (ws/disc_abrupt=1)", ok,
              f"last: {kv.status} {kv.body!r}")
        if not ok:
            c.dump_node_log(grep=["ws", "disconnect", "sweep", "error"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nALL WEBSOCKET WORKER-SEAM CHECKS PASSED ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
