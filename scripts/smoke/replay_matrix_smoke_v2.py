#!/usr/bin/env python3
"""Replay test MATRIX — capture + replay one REAL recording per activation kind
and assert offline `rewind replay` reproduces it. This is the end-to-end
regression guard for `docs/architecture/replay-and-sim.md`: every kind here was,
or could have been, the empty-tape bug (a callback that reads its Msg but never
records it → unreplayable). The complementary broad guard is the capture-time L3
assert (`worker_log.l3AssertMsgRecorded`), which fires in ANY debug smoke.

Kinds covered: `inbound` (request surface), `fetch_chunk` (on.fetch →
onFetchResult), `ws_message` (WS frame → onMessage). wake/disconnect capture
readset+ctx (covered by the L3 assert; their end-to-end replay is a follow-up).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
import urllib.parse as up
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX  # noqa: E402
from ws_worker_smoke_v2 import ws_connect, send_frame, recv_frame  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
REWIND_BIN = REPO_ROOT / "zig-out" / "bin" / "rewind"

_REMAP = [
    ("kv_tape_b64", "kv_b64"), ("request_reads_tape_b64", "request_reads_b64"),
    ("request_body_b64", "request_body_b64"), ("fetch_responses_tape_b64", "fetch_responses_b64"),
    ("trigger_payload_tape_b64", "trigger_payload_b64"), ("activation_bytes_b64", "activation_bytes_b64"),
]

INBOUND_SRC = 'export default function () { return "inbound-ok:" + (request.query || ""); }'
# NB: a {to:'onUpstream'} override with NO onFetchResult export — this doubles as
# the G3 check: if the resolved export weren't recorded, replay would call the
# (missing) conventional onFetchResult and fail. Reproduction proves G3.
FETCH_SRC = """
export default function () {
  const q = request.query || "";
  let url = null;
  for (const p of q.split("&")) { const i = p.indexOf("="); if (i<0) continue;
    if (decodeURIComponent(p.slice(0,i)) === "url") url = decodeURIComponent(p.slice(i+1)); }
  if (!url) { response.status = 400; return "no url"; }
  on.fetch(url, {}, { to: "onUpstream" });
  return next();
}
export function onUpstream() {
  response.status = 200;
  return JSON.stringify({ len: request.body.length, status: request.status });
}
"""
WS_SRC = """
export function onMessage() {
  const m = request.activation;
  kv.set("last_frame", m.opcode === 1 ? m.data : "(binary)");
  return "";
}
"""
BULK_SRC = (REPO_ROOT / "examples" / "loop46-demo-tenants" / "wb" / "bulk" / "index.mjs").read_text()
EXPECTED_BODY = "".join(f"bulk-line-{i:02d}-zzz\n" for i in range(10))


def find_record(c, tenant, activation, tries=60):
    for _ in range(tries):
        lr = c.log_get(f"{tenant}/list?limit=50")
        recs = json.loads(lr.body).get("records", []) if lr.status == 200 else []
        for x in recs:
            rid = x.get("request_id")
            if not rid:
                continue
            sr = c.log_get(f"{tenant}/show/{rid}")
            if sr.status != 200:
                continue
            try:
                r = json.loads(sr.body)["record"]
            except (json.JSONDecodeError, KeyError):
                continue
            if r.get("activation") == activation:
                return r
        time.sleep(0.5)
    return None


def replay(rec, tenant, activation, source):
    tapes = rec.get("tapes", {})
    fixture = {
        "request_id": rec.get("request_id", ""), "tenant": tenant,
        "activation": activation, "entry": "index.mjs",
        "request": {"method": rec.get("method", "GET"), "path": rec.get("path", "/"),
                    "host": rec.get("host", "")},
        "recorded": {"status": rec.get("status", 0)},
        "seed": tapes.get("seed", "0"), "timestamp_ns": tapes.get("timestamp_ns", "0"),
        "tapes": {fx: tapes[rf] for rf, fx in _REMAP if tapes.get(rf)},
        "sources": [{"path": "index.mjs", "kind": "handler", "source": source}],
    }
    if tapes.get("export"):  # the recorded resolved export ({to}) — G3
        fixture["export"] = tapes["export"]
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(fixture, f)
        fx_path = f.name
    # Transcode the base64-tape fixture → the ONE declarative world (what pull
    # does online), then replay the world. replay = sim(fail) over runWorld.
    exp = subprocess.run([str(REWIND_BIN), "export-fixture", fx_path], capture_output=True, text=True, timeout=30)
    if exp.returncode != 0:
        return None
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        f.write(exp.stdout)
        world_path = f.name
    proc = subprocess.run([str(REWIND_BIN), "replay", world_path], capture_output=True, text=True, timeout=30)
    raw = (proc.stdout or "") + (proc.stderr or "")
    return next((json.loads(ln) for ln in raw.splitlines()
                 if ln.strip().startswith("{") and '"effects"' in ln), None)


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("replaymatrix", nodes=1) as c:
        c.spawn_log_server()
        for t, src in (("inb", INBOUND_SRC), ("fch", FETCH_SRC), ("wsm", WS_SRC), ("up", BULK_SRC)):
            c.provision(t)
            c.deploy_handlers(t, {"index.mjs": src})
        c.wait_for_handler("up", "/", want_status=200, want_body=EXPECTED_BODY, timeout_s=25.0)

        # ── inbound ──
        r = c.get("inb", "/?probe=42", timeout=15.0)
        check("[inbound] live", r.status == 200 and r.body == "inbound-ok:probe=42", f"{r.status} {r.body!r}")
        rec = find_record(c, "inb", "inbound")
        art = replay(rec, "inb", "inbound", INBOUND_SRC) if rec else None
        check("[inbound] replay reproduces request.query",
              art and art.get("divergence") is None and art.get("body") == "inbound-ok:probe=42",
              f"art={json.dumps(art)[:200] if art else None}")

        # ── fetch_chunk ──
        bulk_url = f"http://up.{PUBLIC_SUFFIX}:{c.front_port}/"
        r = c.get("fch", f"/?url={up.quote(bulk_url)}", timeout=30.0)
        live_len = (json.loads(r.body).get("len") if r.status == 200 else None)
        check("[fetch_chunk] live on.fetch → onUpstream ({to})", live_len == len(EXPECTED_BODY), f"{r.status} {r.body!r}")
        rec = find_record(c, "fch", "fetch_chunk")
        art = replay(rec, "fch", "fetch_chunk", FETCH_SRC) if rec else None
        summ = {}
        try:
            summ = json.loads(art.get("body") or "{}") if art else {}
        except (json.JSONDecodeError, TypeError):
            pass
        check("[fetch_chunk+G3] replay uses recorded {to} export, reproduces body+status",
              art and art.get("divergence") is None and summ.get("len") == len(EXPECTED_BODY) and summ.get("status") == 200,
              f"summ={summ!r} div={art.get('divergence') if art else None}")

        # ── ws_message ──
        c.wait_for_handler("wsm", "/", want_status=(101, 426, 400, 200, 404), timeout_s=25.0)
        sock = ws_connect(c.front_port, c.host_for("wsm"))
        send_frame(sock, 0x1, b"hello-ws")
        try:
            recv_frame(sock)
        except (EOFError, OSError):
            pass
        try:
            sock.close()
        except OSError:
            pass
        rec = find_record(c, "wsm", "ws_message")
        art = replay(rec, "wsm", "ws_message", WS_SRC) if rec else None
        writes = [e for e in ((art.get("effects") if art else None) or []) if e.get("kind") == "write"]
        last = next((w for w in writes if w.get("key") == "last_frame"), None)
        check("[ws_message] replay reproduces request.activation.data",
              art and art.get("divergence") is None and last and last.get("value") == "hello-ws",
              f"writes={writes!r} div={art.get('divergence') if art else None}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\n✅ replay matrix: inbound + fetch_chunk + ws_message all reproduce from real recordings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
