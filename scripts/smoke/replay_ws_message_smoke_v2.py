#!/usr/bin/env python3
"""Validate ws_message (onMessage) capture → replay against a REAL recording.

The WS resume paths used to log with empty tapes (the same class as the
fetch_chunk bug). This proves the fix: a live WS text frame → `onMessage` now
tapes its Msg (the frame, on `activation_bytes`, + ctx on trigger_payload), and
offline `rewind replay` reconstructs `request.activation = {opcode, data}` and
reproduces the handler's output.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402
from ws_worker_smoke_v2 import ws_connect, send_frame, recv_frame  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
REWIND_BIN = REPO_ROOT / "zig-out" / "bin" / "rewind"
TENANT = "wsmsg"

# onMessage writes the frame text to kv (captured as kv_writes in replay — the
# bare replay arena has no stream.*/next, so we assert via the write, not a
# reply frame) then returns terminal. Reading request.activation.data is the
# thing under test.
HANDLER = r"""
export function onMessage() {
  const m = request.activation;
  const text = m.opcode === 1 ? m.data : "(binary)";
  kv.set("last_frame", text);
  return "";
}
"""


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("wsmsg", nodes=1) as c:
        c.spawn_log_server()
        c.provision(TENANT)
        c.deploy_handlers(TENANT, {"index.mjs": HANDLER})
        c.wait_for_handler(TENANT, "/", want_status=(101, 426, 400, 200, 404), timeout_s=25.0)

        host = c.host_for(TENANT)
        sock = ws_connect(c.front_port, host)
        send_frame(sock, 0x1, b"hello-ws")  # text frame → onMessage (terminal close)
        try:
            recv_frame(sock)  # server close frame after the terminal return
        except (EOFError, OSError):
            pass
        try:
            sock.close()
        except OSError:
            pass

        # ── find the ws_message record ──
        rec = None
        for _ in range(60):
            lr = c.log_get(f"{TENANT}/list?limit=50")
            recs = json.loads(lr.body).get("records", []) if lr.status == 200 else []
            for x in recs:
                rid = x.get("request_id")
                if not rid:
                    continue
                sr = c.log_get(f"{TENANT}/show/{rid}")
                if sr.status != 200:
                    continue
                try:
                    r_full = json.loads(sr.body)["record"]
                except (json.JSONDecodeError, KeyError):
                    continue
                if r_full.get("activation") == "ws_message":
                    rec = r_full
                    break
            if rec is not None:
                break
            time.sleep(0.5)
        check("log server surfaced a ws_message record", rec is not None)
        if rec is None:
            print("\nFAILURES:", failures)
            return 1

        tapes = rec.get("tapes", {})
        check("ws_message record carries the frame (activation_bytes tape)",
              bool(tapes.get("activation_bytes_b64")),
              f"tape keys={sorted(tapes.keys())}")

        # ── reshape → fixture, replay ──
        remap = [("kv_tape_b64", "kv_b64"),
                 ("request_reads_tape_b64", "request_reads_b64"),
                 ("request_body_b64", "request_body_b64"),
                 ("trigger_payload_tape_b64", "trigger_payload_b64"),
                 ("activation_bytes_b64", "activation_bytes_b64")]
        fixture = {
            "request_id": rec.get("request_id", ""), "tenant": TENANT,
            "activation": "ws_message", "entry": "index.mjs",
            "request": {"method": rec.get("method", "POST"), "path": rec.get("path", "/"),
                        "host": rec.get("host", "")},
            "recorded": {"status": rec.get("status", 0)},
            "seed": tapes.get("seed", "0"), "timestamp_ns": tapes.get("timestamp_ns", "0"),
            "tapes": {fx: tapes[rf] for rf, fx in remap if tapes.get(rf)},
            "sources": [{"path": "index.mjs", "kind": "handler", "source": HANDLER}],
        }
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(fixture, f)
            fixture_path = f.name

        proc = subprocess.run([str(REWIND_BIN), "replay", fixture_path],
                              capture_output=True, text=True, timeout=30)
        raw = (proc.stdout or "") + (proc.stderr or "")
        art = next((json.loads(ln) for ln in raw.splitlines()
                    if ln.strip().startswith("{") and '"run_rc"' in ln), None)
        print(f"  · DIAG replay artifact: {json.dumps(art)[:400] if art else raw[:300]}")
        check("replay driver emitted an artifact", art is not None)
        if art is None:
            print("\nFAILURES:", failures)
            return 1
        replay = art.get("replay") or {}
        writes = art.get("kv_writes") or []
        last = next((w for w in writes if w.get("key") == "last_frame"), None)
        check("replay: no divergence", art.get("divergence") is None,
              f"divergence={art.get('divergence')!r}")
        check("replay: no handler error", replay.get("error") is None,
              f"error={replay.get('error')!r}")
        check("replay: onMessage reproduced request.activation.data (kv last_frame=hello-ws)",
              last is not None and last.get("value") == "hello-ws",
              f"kv_writes={writes!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\n✅ ws_message capture → replay validated against a REAL recording")
    return 0


if __name__ == "__main__":
    sys.exit(main())
