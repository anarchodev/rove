#!/usr/bin/env python3
"""Inbound-WebSocket transport smoke (docs/websocket-plan.md §4.6 pieces A/C/E-h2).

Drives the `ws-echo` example server (examples/ws_echo_test.zig) with a raw-socket
RFC 6455 client — no third-party WS library — and asserts the rove-h2 transport:
the 101 handshake (Sec-WebSocket-Accept), text/binary echo, fragmented-message
reassembly, runtime auto-pong, and the close handshake.

Run standalone against an already-running server on :8085, or let it spawn one:
    python3 scripts/ws_echo_smoke.py            # spawns `zig build ws-echo`
    python3 scripts/ws_echo_smoke.py --port 8085 --no-spawn
"""

import argparse
import base64
import hashlib
import os
import signal
import socket
import struct
import subprocess
import sys
import time

ACCEPT_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OP_CONT = 0x0
OP_TEXT = 0x1
OP_BIN = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA


def expected_accept(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + ACCEPT_MAGIC).encode()).digest()).decode()


def send_frame(sock, opcode, payload: bytes, fin=True, mask=True):
    b0 = (0x80 if fin else 0) | opcode
    out = bytearray([b0])
    n = len(payload)
    mask_bit = 0x80 if mask else 0
    if n <= 125:
        out.append(mask_bit | n)
    elif n <= 0xFFFF:
        out.append(mask_bit | 126)
        out += struct.pack(">H", n)
    else:
        out.append(mask_bit | 127)
        out += struct.pack(">Q", n)
    if mask:
        mkey = os.urandom(4)
        out += mkey
        out += bytes(b ^ mkey[i & 3] for i, b in enumerate(payload))
    else:
        out += payload
    sock.sendall(out)


def recv_exact(sock, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed mid-frame")
        buf += chunk
    return buf


def recv_frame(sock):
    """Read one server→client frame. Returns (opcode, fin, payload). Server
    frames are never masked (RFC 6455 §5.1)."""
    b0, b1 = recv_exact(sock, 2)
    fin = bool(b0 & 0x80)
    opcode = b0 & 0x0F
    masked = bool(b1 & 0x80)
    assert not masked, "server frame must not be masked"
    length = b1 & 0x7F
    if length == 126:
        length = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(sock, 8))[0]
    payload = recv_exact(sock, length) if length else b""
    return opcode, fin, payload


def handshake(sock, host):
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET /chat HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(req.encode())
    # Read headers up to CRLFCRLF.
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise EOFError("server closed during handshake")
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    assert rest == b"", "server sent frame bytes before we sent any"
    lines = head.decode("latin1").split("\r\n")
    assert lines[0] == "HTTP/1.1 101 Switching Protocols", f"bad status line: {lines[0]!r}"
    hdrs = {}
    for ln in lines[1:]:
        k, _, v = ln.partition(":")
        hdrs[k.strip().lower()] = v.strip()
    assert hdrs.get("upgrade", "").lower() == "websocket", hdrs
    assert hdrs.get("connection", "").lower() == "upgrade", hdrs
    assert hdrs.get("sec-websocket-accept") == expected_accept(key), (
        hdrs.get("sec-websocket-accept"), expected_accept(key))
    print("  ✓ 101 handshake + Sec-WebSocket-Accept")


def run_checks(host, port):
    sock = socket.create_connection((host, port), timeout=5)
    sock.settimeout(5)
    try:
        handshake(sock, f"{host}:{port}")

        # 1. text echo
        send_frame(sock, OP_TEXT, b"hello rove")
        op, fin, pl = recv_frame(sock)
        assert op == OP_TEXT and fin and pl == b"hello rove", (op, fin, pl)
        print("  ✓ text echo")

        # 2. binary echo
        blob = bytes(range(256)) * 4  # 1024 bytes → 16-bit length path
        send_frame(sock, OP_BIN, blob)
        op, fin, pl = recv_frame(sock)
        assert op == OP_BIN and fin and pl == blob, (op, fin, len(pl))
        print("  ✓ binary echo (16-bit length)")

        # 3. fragmented text message: opener (fin=0) + continuation (fin=1)
        send_frame(sock, OP_TEXT, b"frag-", fin=False)
        send_frame(sock, OP_CONT, b"mented", fin=True)
        op, fin, pl = recv_frame(sock)
        assert op == OP_TEXT and fin and pl == b"frag-mented", (op, fin, pl)
        print("  ✓ fragmented message reassembled")

        # 4. ping → runtime auto-pong (handler never sees it)
        send_frame(sock, OP_PING, b"pingdata")
        op, fin, pl = recv_frame(sock)
        assert op == OP_PONG and pl == b"pingdata", (op, fin, pl)
        print("  ✓ ping auto-pong")

        # text still works after the control frame
        send_frame(sock, OP_TEXT, b"after-ping")
        op, fin, pl = recv_frame(sock)
        assert op == OP_TEXT and pl == b"after-ping", (op, fin, pl)
        print("  ✓ data after control frame")

        # 5. close handshake → server echoes Close, then closes
        send_frame(sock, OP_CLOSE, struct.pack(">H", 1000))
        op, fin, pl = recv_frame(sock)
        assert op == OP_CLOSE, (op, fin, pl)
        print("  ✓ close handshake echoed")
    finally:
        sock.close()


def wait_ready(proc, log_path, timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc and proc.poll() is not None:
            raise RuntimeError(f"server exited early (rc={proc.returncode}); see {log_path}")
        try:
            with open(log_path) as f:
                if "WebSocket echo server" in f.read():
                    return
        except FileNotFoundError:
            pass
        time.sleep(0.25)
    raise TimeoutError("server did not become ready")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8085)
    ap.add_argument("--no-spawn", action="store_true", help="connect to an already-running server")
    args = ap.parse_args()

    proc = None
    log_path = "/tmp/ws_echo_smoke_server.log"
    if not args.no_spawn:
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        logf = open(log_path, "w")
        print("Building + starting ws-echo server (zig build ws-echo)…")
        proc = subprocess.Popen(
            ["zig", "build", "ws-echo"], cwd=repo,
            stdout=logf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    try:
        wait_ready(proc, log_path)
        print(f"Server ready on ws://{args.host}:{args.port}")
        run_checks(args.host, args.port)
        print("\nALL WEBSOCKET TRANSPORT CHECKS PASSED ✓")
    finally:
        if proc is not None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except ProcessLookupError:
                pass


if __name__ == "__main__":
    main()
