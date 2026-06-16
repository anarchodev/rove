#!/usr/bin/env python3
"""Browser-agent end-to-end smoke — proves the in-page agent loop on the real
V2 stack, with a STUB LLM standing in for Claude.

The pieces under test:
  - `browser.*` server shim (src/js/globals/browser.js)
  - the reference handler loop (web/agent-sample/agent/index.mjs): a held
    WebSocket chain where each page `snapshot` → `on.fetch` the LLM → `browser.act`
  - the wire protocol shared with web/rove-agent.js

This script plays the role of the BROWSER (rove-agent.js): it opens the WS
through the front door, sends `hello` + a hand-built `snapshot`, applies each
`act` the handler sends to a tiny in-Python DOM, and sends back `result` +
a fresh snapshot — exactly as the SDK would. A threaded stub HTTP server
returns scripted Claude-shaped tool_use responses (type → click → done), so
the whole loop runs with no real model and no network egress.

Asserts:
  1. WS upgrade through the front (tenant Host → /agent)
  2. the agent issues `type test@example.com` on the email ref
  3. then `click` on the Continue ref
  4. then requests a `screenshot`, and the page's pixels reach the model as an
     image block AND get stored content-addressed via blob.put (Phase 4)
  5. then finishes (a `done` frame)
  6. the page state reflects the typed value (loop actually round-tripped)
  7. kv holds the goal + a non-empty transcript (durable step-log checkpointed)

Needs S3 env (V2 blob backend is S3-only): `set -a; . ./.env; set +a` first.
Binaries: `zig build rewind rewind-cp rewind-front files-server-v2`.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
AGENT_SRC = (REPO / "web" / "agent-sample" / "agent" / "index.mjs").read_text()
READY_SRC = 'export default function () { return "ready"; }\n'

TENANT = "agentsmoke"
SID = "smokesid1"
GOAL = "Type test@example.com into the email field, then click Continue."

OP_TEXT = 0x1
OP_BIN = 0x2
OP_CLOSE = 0x8
ACCEPT_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


# ── stub LLM: scripted Claude /v1/messages responses ──────────────────
# One tool_use per turn (type → click → screenshot), then a text-only
# turn = done. The screenshot turn proves the brain can TRIGGER a capture
# and that the pixels round-trip back into the next turn as an image.
STUB_RESPONSES = [
    {"role": "assistant", "content": [
        {"type": "tool_use", "id": "t1", "name": "type",
         "input": {"ref": "1", "text": "test@example.com"}}]},
    {"role": "assistant", "content": [
        {"type": "tool_use", "id": "t2", "name": "click", "input": {"ref": "2"}}]},
    {"role": "assistant", "content": [
        {"type": "tool_use", "id": "t3", "name": "screenshot", "input": {}}]},
    {"role": "assistant", "content": [{"type": "text", "text": "Done."}]},
]

# A known fake image the page emulator "captures". Content is opaque to the
# handler (it just stores the bytes + forwards the base64), so any bytes do;
# we only need the hash to be predictable to assert blob.put stored it.
SHOT_BYTES = b"\xff\xd8\xff\xe0\x00\x10JFIF rove-fake-screenshot \xff\xd9"
SHOT_B64 = base64.b64encode(SHOT_BYTES).decode()
SHOT_HASH = hashlib.sha256(SHOT_BYTES).hexdigest()


STUB_HITS = [0]
STUB_BODIES: list = []  # every request body the handler sent the model


class StubLLM(BaseHTTPRequestHandler):
    _n = [0]

    def do_POST(self):
        length = int(self.headers.get("content-length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            STUB_BODIES.append(json.loads(raw))
        except Exception:
            STUB_BODIES.append(None)
        STUB_HITS[0] += 1
        sys.stderr.write(f"[stub] hit #{STUB_HITS[0]} {self.path}\n")
        i = min(self._n[0], len(STUB_RESPONSES) - 1)
        self._n[0] += 1
        body = json.dumps(STUB_RESPONSES[i]).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # quiet
        pass


# ── raw RFC 6455 client (same helpers as ws_worker_smoke_v2.py) ───────
def _accept(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + ACCEPT_MAGIC).encode()).digest()).decode()


def encode_frame(opcode, payload: bytes, fin=True) -> bytes:
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


def send_text(sock, obj):
    sock.sendall(encode_frame(OP_TEXT, json.dumps(obj).encode()))


def recv_exact(sock, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed mid-frame")
        buf += chunk
    return buf


def recv_frame(sock):
    b0, b1 = recv_exact(sock, 2)
    fin = bool(b0 & 0x80)
    opcode = b0 & 0x0F
    length = b1 & 0x7F
    if length == 126:
        length = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(sock, 8))[0]
    payload = recv_exact(sock, length) if length else b""
    return opcode, fin, payload


def ws_connect(port: int, host_header: str, path: str) -> socket.socket:
    sock = socket.create_connection(("127.0.0.1", port), timeout=15)
    sock.settimeout(15)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((
        f"GET {path} HTTP/1.1\r\nHost: {host_header}\r\n"
        f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ).encode())
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise EOFError("server closed during handshake")
        data += chunk
    head = data.split(b"\r\n\r\n", 1)[0].decode("latin1").split("\r\n")
    assert head[0] == "HTTP/1.1 101 Switching Protocols", f"bad status: {head[0]!r}"
    hdrs = {k.strip().lower(): v.strip() for k, _, v in (ln.partition(":") for ln in head[1:])}
    assert hdrs.get("sec-websocket-accept") == _accept(key), hdrs
    return sock


# Does an LLM request body carry an image content block (the screenshot
# the brain saw)? It rides nested inside a tool_result block's content.
def _has_image(body) -> bool:
    for m in (body or {}).get("messages", []):
        content = m.get("content")
        if not isinstance(content, list):
            continue
        for blk in content:
            if not isinstance(blk, dict):
                continue
            if blk.get("type") == "image":
                return True
            inner = blk.get("content")
            if isinstance(inner, list):
                for ib in inner:
                    if isinstance(ib, dict) and ib.get("type") == "image":
                        return True
    return False


# ── the page emulator: drive the loop like rove-agent.js would ────────
def drive(sock):
    elements = [
        {"ref": "1", "role": "textbox", "name": "Email", "value": ""},
        {"ref": "2", "role": "button", "name": "Continue"},
    ]
    seq = [0]

    def snapshot():
        seq[0] += 1
        send_text(sock, {"t": "snapshot", "sid": SID, "seq": seq[0],
                         "url": "https://app.test/", "title": "Sample",
                         "elements": elements})

    send_text(sock, {"t": "hello", "sid": SID, "goal": GOAL,
                     "url": "https://app.test/", "title": "Sample"})
    snapshot()

    acts, done = [], None
    deadline = time.time() + 40
    while time.time() < deadline:
        try:
            op, _fin, pl = recv_frame(sock)
        except Exception:
            break
        if op == OP_CLOSE:
            break
        if op != OP_TEXT:
            continue
        msg = json.loads(pl)
        t = msg.get("t")
        if t == "status":
            continue
        if t == "confirm":
            send_text(sock, {"t": "confirm_result", "sid": SID,
                             "id": msg.get("id"), "approved": True})
            continue
        if t == "done":
            done = msg.get("message")
            break
        if t == "act":
            acts.append(msg)
            op_ = msg.get("op")
            if op_ == "type":
                for e in elements:
                    if e["ref"] == str(msg.get("ref")):
                        e["value"] = msg.get("text", "")
                send_text(sock, {"t": "result", "sid": SID, "id": msg.get("id"), "ok": True})
                snapshot()
            elif op_ == "click":
                send_text(sock, {"t": "result", "sid": SID, "id": msg.get("id"), "ok": True})
                snapshot()
            elif op_ == "snapshot":
                # result BEFORE the snapshot: the snapshot must be the LAST
                # frame so a handler that issues a bound fetch on it (e.g. the
                # screenshot bounce) isn't disrupted by a trailing frame.
                send_text(sock, {"t": "result", "sid": SID, "id": msg.get("id"), "ok": True})
                snapshot()
            elif op_ == "screenshot":
                # Reply with a `screenshot` frame carrying the captured image
                # — this IS the tool result, so no `result`/snapshot follows
                # (mirrors rove-agent.js after getDisplayMedia).
                send_text(sock, {"t": "screenshot", "sid": SID, "id": msg.get("id"),
                                 "ok": True, "mime": "image/jpeg", "data": SHOT_B64})
            else:
                send_text(sock, {"t": "result", "sid": SID, "id": msg.get("id"), "ok": True})
    return acts, done, elements


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    # Stub LLM on loopback (worker reaches it via REWIND_UNSAFE_OUTBOUND).
    httpd = HTTPServer(("127.0.0.1", 0), StubLLM)
    stub_port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print(f"stub LLM on 127.0.0.1:{stub_port}")

    with V2Cluster.spawn("agent", nodes=1) as c:
        print("step 1: provision + deploy reference handler")
        r = c.provision(TENANT)
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers(TENANT, {"index.mjs": READY_SRC,
                                       "agent/index.mjs": AGENT_SRC})
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            print(f"\nFAILURES: {failures}")
            return 1
        ready = c.wait_for_handler(TENANT, "/", want_body="ready")
        check("deployment loaded", ready.status == 200 and "ready" in ready.body,
              f"got {ready.status} {ready.body!r}")
        if ready.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "resolve", "error"])
            print(f"\nFAILURES: {failures}")
            return 1

        print("step 2: point the handler's LLM at the stub (kv _config/*)")
        cfg = {"_config/llm_endpoint": f"http://127.0.0.1:{stub_port}/v1/messages",
               "_config/anthropic_api_key": "test", "_config/llm_model": "stub",
               "_config/screenshots": "1"}  # offer the opt-in screenshot tool
        for k, v in cfg.items():
            r = c.admin_kv_put(TENANT, k, v)
            check(f"set {k}", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 3: WS upgrade through the front (Host → /agent)")
        try:
            sock = ws_connect(c.front_port, c.host_for(TENANT), "/agent")
            check("101 handshake", True)
        except Exception as e:
            check("101 handshake", False, repr(e))
            c.dump_node_log(grep=["ws", "upgrade", "agent", "error"])
            print(f"\nFAILURES: {failures}")
            return 1

        print("step 4: drive the snapshot→act loop")
        try:
            acts, done, elements = drive(sock)
        except Exception as e:
            check("drive loop", False, repr(e))
            c.dump_node_log(grep=["agent", "fetch", "onLLM", "error", "warn"])
            acts, done, elements = [], None, []
        finally:
            try:
                sock.close()
            except Exception:
                pass

        check("stub LLM was called", STUB_HITS[0] >= 1, f"hits={STUB_HITS[0]}")
        type_acts = [a for a in acts if a.get("op") == "type"]
        click_acts = [a for a in acts if a.get("op") == "click"]
        check("agent typed the email",
              bool(type_acts) and str(type_acts[0].get("ref")) == "1"
              and type_acts[0].get("text") == "test@example.com",
              f"acts={[a.get('op') for a in acts]}")
        check("agent clicked Continue",
              bool(click_acts) and str(click_acts[0].get("ref")) == "2",
              f"acts={[a.get('op') for a in acts]}")

        # ── Phase 4: brain-triggered screenshot ─────────────────────────
        shot_acts = [a for a in acts if a.get("op") == "screenshot"]
        check("agent requested a screenshot", bool(shot_acts),
              f"acts={[a.get('op') for a in acts]}")
        check("model received the screenshot as an image block",
              any(_has_image(b) for b in STUB_BODIES),
              "no image content block in any LLM request")

        check("agent finished (done frame)", done is not None, f"done={done!r}")
        check("page state reflects the typed value",
              any(e.get("ref") == "1" and e.get("value") == "test@example.com"
                  for e in elements),
              f"elements={elements}")
        if not (type_acts and click_acts and done is not None):
            c.dump_node_log(grep=["agent", "fetch", "onLLM", "browser", "error", "warn"])

        print("step 5: durable loop state in kv")
        g = c.admin_kv_get(TENANT, f"agent/{SID}/goal")
        check("kv goal stored", g.status == 200 and "test@example.com" in g.body,
              f"got {g.status} {g.body!r}")
        m = c.admin_kv_get(TENANT, f"agent/{SID}/msgs")
        check("kv transcript checkpointed", m.status == 200 and "tool_use" in m.body,
              f"got {m.status} {m.body[:120]!r}")
        # The screenshot bytes were stored content-addressed (blob.put) and a
        # pointer written to the step-log under the known sha256 of SHOT_BYTES.
        s = c.admin_kv_get(TENANT, f"agent/{SID}/shots/{SHOT_HASH}")
        check("screenshot stored via blob.put (kv pointer)",
              s.status == 200 and SHOT_HASH in s.body,
              f"got {s.status} {s.body[:120]!r}")
        if s.status != 200:
            c.dump_node_log(grep=["blob", "shot", "WRITING", "ws ", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nALL BROWSER-AGENT CHECKS PASSED ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
