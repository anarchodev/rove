#!/usr/bin/env python3
"""Replay is order-robust — the regression guard for the map-resolution replay
path (`docs/architecture/replay-and-sim.md` §1). Offline: builds a fixture with
a hand-made RTAP kv tape (no cluster / no S3), then drives `rewind replay`.

Asserts:
  1. Reordering two INDEPENDENT reads (recorded a,b; replayed b,a) does NOT
     diverge — the false negative the ordered cursor produced. Both keys resolve
     by key; the JS behaves the same.
  2. A genuinely NEW read (a key the recording never captured) resolves to
     not_found (closed world) and surfaces in the effect log as a read with
     present:false — the honest "your code read something the world doesn't
     have" signal, visible rather than a hard divergence.
"""

from __future__ import annotations

import base64
import json
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
REWIND_BIN = REPO_ROOT / "zig-out" / "bin" / "rewind"


def _lp(b: bytes) -> bytes:
    return struct.pack(">I", len(b)) + b


def _kv_tape(entries) -> str:
    """Build a base64 RTAP kv tape. entries: [(key, value_or_None)] in order."""
    hdr = struct.pack(">IHHI", 0x52544150, 5, 0, len(entries))  # MAGIC, VER=5, kv(0), count
    body = b""
    for key, val in entries:
        outcome = 0 if val is not None else 1  # ok / not_found
        payload = bytes([0, outcome]) + _lp(key.encode()) + _lp((val or "").encode())
        body += _lp(payload)
    return base64.b64encode(hdr + body).decode()


def _fixture(kv_b64: str, source: str) -> str:
    fx = {
        "request_id": "req_x", "tenant": "t", "activation": "inbound", "entry": "index.mjs",
        "request": {"method": "GET", "path": "/", "host": ""},
        "recorded": {"status": 200, "console": "", "exception": ""},
        "seed": "1", "timestamp_ns": "0",
        "tapes": {"kv_b64": kv_b64},
        "sources": [{"path": "index.mjs", "kind": "handler", "source": source}],
    }
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(fx, f)
    f.close()
    return f.name


def _srcdir(source: str) -> str:
    d = tempfile.mkdtemp()
    (Path(d) / "index.mjs").write_text(source)
    return d


def _export_to_world(fixture: str) -> str:
    """Transcode the base64-tape fixture → the declarative world (what pull does
    online). This is the ONE format replay/sim consume."""
    p = subprocess.run([str(REWIND_BIN), "export-fixture", fixture],
                       capture_output=True, text=True, timeout=30)
    if p.returncode != 0:
        raise SystemExit(f"export-fixture failed:\n{p.stdout}\n{p.stderr}")
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    f.write(p.stdout)
    f.close()
    return f.name


def _replay(world: str, srcdir: str) -> dict:
    cmd = [str(REWIND_BIN), "replay", world, "--source-dir", srcdir]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    raw = (p.stdout or "") + (p.stderr or "")
    for ln in raw.splitlines():
        ln = ln.strip()
        if ln.startswith("{") and '"effects"' in ln:
            return json.loads(ln)
    raise SystemExit(f"no artifact:\n{raw[:400]}")


def main() -> int:
    if not REWIND_BIN.exists():
        raise SystemExit("build rewind first: `zig build rewind`")
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    # Recorded read order: a, b → base64 tape → transcode to the ONE format.
    tape = _kv_tape([("a", "1"), ("b", "2")])
    orig = 'export default function(){ const a=kv.get("a"); const b=kv.get("b"); return JSON.stringify({a,b}); }'
    world = _export_to_world(_fixture(tape, orig))

    # 1. Reordered reads (b then a) — must NOT diverge.
    reordered = 'export default function(){ const b=kv.get("b"); const a=kv.get("a"); return JSON.stringify({a,b}); }'
    art = _replay(world, _srcdir(reordered))
    res = art.get("body")
    check("reordered independent reads do not diverge",
          art.get("divergence") is None and res == '{"a":"1","b":"2"}',
          f"div={art.get('divergence')!r} result={res!r}")

    # 2. New read (key 'c', never recorded) — closed world: resolves to
    #    not_found (null), no divergence, and surfaces in the effect log as a
    #    read with present:false (the honest "your code read something the world
    #    doesn't have" signal — visible, not a hard divergence).
    newkey = 'export default function(){ const a=kv.get("a"); const c=kv.get("c"); return JSON.stringify({a,c}); }'
    art = _replay(world, _srcdir(newkey))
    res = art.get("body")
    read_c = next((e for e in art.get("effects", [])
                   if e.get("kind") == "read" and e.get("key") == "c"), None)
    check("a new read resolves to not_found (closed world) and shows in the effects",
          art.get("divergence") is None and res == '{"a":"1","c":null}'
          and read_c is not None and read_c.get("present") is False,
          f"div={art.get('divergence')!r} result={res!r} read_c={read_c!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\n✅ replay is order-robust; new reads fail-loud (fail) / resolve (resolve)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
