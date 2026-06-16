#!/usr/bin/env python3
"""WS `on.fetch` smoke — proves a held WebSocket chain can call out via
`on.fetch` from `onMessage` and resume its `{to}` export over the SAME socket
(the engine fix's on.fetch half; `ws_wake_smoke_v2.py` covers on.kv/on.timer).

A deployed handler, on a `fetch:<url>` frame, issues `on.fetch(url)` from a
read-only frame and parks; when the result lands it resumes `onUpstream`,
reads the bound-fetch surface (`request.body` + `request.status` +
`request.done`), and `stream.write`s the body back. A threaded stub HTTP
server stands in for the upstream (reached via REWIND_UNSAFE_OUTBOUND).

Asserts:
  1. `fetch:<stub-url>` → on.fetch binds, parks (no immediate reply)
  2. the result resumes onUpstream → "fetched:200:hello-upstream" frame

Needs S3 env: `set -a; . ./.env; set +a` first.
Binaries: `zig build rewind-worker rewind-cp rewind-front files-server-v2`.
"""

from __future__ import annotations

import base64
import hashlib
import os
import socket
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

TENANT = "wsfetch"
OP_TEXT = 0x1
OP_CLOSE = 0x8
ACCEPT_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
UPSTREAM_BODY = "hello-upstream"

HANDLER_SRC = """\
export default function () { return "ready"; }

export function onMessage() {
  const { data } = request.activation;
  if (data.startsWith("fetch:")) {
    // READ-ONLY frame: on.fetch binds to the held chain and the result
    // resumes onUpstream over this socket.
    on.fetch(data.slice(6), { method: "GET" }, { to: "onUpstream" });
    return next();
  }
  stream.write("echo:" + data);
  return next();
}

export function onUpstream() {
  // Bound-fetch surface: bytes on request.body, status/done at top level.
  if (!request.done) return next();
  const body = request.body ? new TextDecoder().decode(request.body) : "";
  stream.write("fetched:" + request.status + ":" + body);
  return next();
}
"""


class Stub(BaseHTTPRequestHandler):
    def do_GET(self):
        body = UPSTREAM_BODY.encode()
        self.send_response(200)
        self.send_header("content-type", "text/plain")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def _accept(key):
    return base64.b64encode(hashlib.sha1((key + ACCEPT_MAGIC).encode()).digest()).decode()


def encode_frame(opcode, payload, fin=True):
    out = bytearray([(0x80 if fin else 0) | opcode])
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

    httpd = HTTPServer(("127.0.0.1", 0), Stub)
    stub_port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    with V2Cluster.spawn("wsfetch", nodes=1) as c:
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

        print("step: on.fetch from onMessage → resume onUpstream over the socket")
        send_text(sock, f"fetch:http://127.0.0.1:{stub_port}/x")
        try:
            op, pl = recv_text(sock)
            check("on.fetch resumed onUpstream",
                  op == OP_TEXT and pl == f"fetched:200:{UPSTREAM_BODY}".encode(),
                  f"op={op} pl={pl!r}")
        except Exception as e:
            check("on.fetch resumed onUpstream", False, repr(e))
            c.dump_node_log(grep=["fetch", "onUpstream", "ws-fetch", "error", "warn"])
        sock.close()

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nALL WS FETCH CHECKS PASSED ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
