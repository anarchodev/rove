#!/usr/bin/env python3
"""Minimal read set for kv.prefix — the Stage-3 record-side guard.

kv.prefix's result includes the handler's own uncommitted writes (the kvexp
overlay merge). Those own-write rows must NOT land in the taped readset, else a
replay of a refactored read would be served the stale write value instead of
reconstructing it from re-execution.

This captures a REAL recording and asserts the pulled world's `kv` (the readset)
holds the FOREIGN key a prefix scan returned but NOT the OWN-WRITE key the same
scan surfaced from the overlay.

  1. /setup  → kv.set("pfx/foreign", …)                 (commits a foreign key)
  2. /test   → kv.set("pfx/own", …); kv.prefix("pfx/")  (scan returns BOTH, live)
  3. pull /test → world.json: kv has pfx/foreign, NOT pfx/own
  4. replay the world → reproduces the live scan (own-write refilled by re-exec)

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

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
REWIND_BIN = REPO_ROOT / "zig-out" / "bin" / "rewind"

_REMAP = [
    ("kv_tape_b64", "kv_b64"), ("request_reads_tape_b64", "request_reads_b64"),
    ("request_body_b64", "request_body_b64"),
]

SRC = """
export default function () {
  if (request.path === "/setup") { kv.set("pfx/foreign", "seeded"); response.status = 200; return "setup"; }
  kv.set("pfx/own", "written");
  const scan = kv.prefix("pfx/", "", 100);
  response.status = 200;
  return JSON.stringify({ keys: scan.map(e => e.key).sort() });
}
"""


def find_record(c, tenant, path, tries=60):
    """The most-recent inbound record whose request path matches."""
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
            if r.get("activation") == "inbound" and r.get("path") == path:
                return r
        time.sleep(0.5)
    return None


def to_world(rec, tenant):
    """Transcode a pulled record → the declarative world.json (as `pull` does)."""
    tapes = rec.get("tapes", {})
    fixture = {
        "request_id": rec.get("request_id", ""), "tenant": tenant,
        "activation": "inbound", "entry": "index.mjs",
        "request": {"method": rec.get("method", "GET"), "path": rec.get("path", "/"),
                    "host": rec.get("host", "")},
        "recorded": {"status": rec.get("status", 0)},
        "seed": tapes.get("seed", "0"), "timestamp_ns": tapes.get("timestamp_ns", "0"),
        "tapes": {fx: tapes[rf] for rf, fx in _REMAP if tapes.get(rf)},
        "sources": [{"path": "index.mjs", "kind": "handler", "source": SRC}],
    }
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(fixture, f)
        fx_path = f.name
    exp = subprocess.run([str(REWIND_BIN), "export-fixture", fx_path],
                         capture_output=True, text=True, timeout=30)
    if exp.returncode != 0:
        raise SystemExit(f"export-fixture failed: {exp.stderr}")
    return json.loads(exp.stdout), exp.stdout


def replay(world_json):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        f.write(world_json)
        wp = f.name
    p = subprocess.run([str(REWIND_BIN), "replay", wp], capture_output=True, text=True, timeout=30)
    raw = (p.stdout or "") + (p.stderr or "")
    return next((json.loads(ln) for ln in raw.splitlines()
                 if ln.strip().startswith("{") and '"effects"' in ln), None)


def main() -> int:
    if not REWIND_BIN.exists():
        raise SystemExit("build rewind first: `zig build rewind`")
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("prefixws", nodes=1) as c:
        c.spawn_log_server()
        c.provision("t")
        c.deploy_handlers("t", {"index.mjs": SRC})
        c.wait_for_handler("t", "/setup", want_status=200, timeout_s=25.0)

        c.get("t", "/setup", timeout=15.0)                 # commit the foreign key
        r = c.get("t", "/test", timeout=15.0)              # write own + scan
        live = json.loads(r.body).get("keys") if r.status == 200 else None
        check("[live] prefix scan sees the foreign key AND the own-write (overlay merge)",
              live == ["pfx/foreign", "pfx/own"], f"{r.status} {r.body!r}")

        rec = find_record(c, "t", "/test")
        world, world_json = (to_world(rec, "t") if rec else ({}, "{}"))
        kv = world.get("kv", {})
        check("[readset] the FOREIGN prefix row is taped (in the world's kv)",
              "pfx/foreign" in kv, f"kv={json.dumps(kv)}")
        check("[readset] the OWN-WRITE prefix row is NOT taped (filtered)",
              "pfx/own" not in kv, f"kv={json.dumps(kv)}")

        art = replay(world_json) if rec else None
        body = json.loads(art["body"]) if art and art.get("body") else {}
        check("[replay] reconstructs the scan (own-write refilled by re-execution)",
              art is not None and art.get("divergence") is None
              and body.get("keys") == ["pfx/foreign", "pfx/own"],
              f"art_body={art.get('body') if art else None!r}")

    print(("\n❌ " + ", ".join(failures)) if failures else "\n✅ prefix readset stays disjoint from the writeset")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
