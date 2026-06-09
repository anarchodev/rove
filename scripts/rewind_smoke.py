#!/usr/bin/env python3
"""V2 `rewind` exit smoke (docs/v2-build-order.md §Phase 2e).

Boots the single-node `rewind` worker binary and drives the built-in
`/_system/admin-kv` write path, which exercises the whole Phase-2
mechanism end to end:

    POST → TrackedTxn on __admin__/app.db → bridge.propose(gid, env)
         → park RaftWait{group_id, seq} → pump commits the entry
         → committedSeq(gid) >= seq → worker txn.commit() → 204

A 204 (not a 503 timeout) proves the per-tenant watermark + leader-skip
apply + pump thread compose under a real HTTP/2 request. The restart leg
proves the committed write is durable (LMDB persisted by txn.commit) — the
store reopens and a follow-up write still commits.

Requires S3 env (there is no fs BlobBackend) — source the repo `.env`
first, e.g.  `set -a; . ./.env; set +a; python3 scripts/rewind_smoke.py`.

Build first:  `zig build rewind`
"""

import json
import os
import signal
import subprocess
import sys
import time

PORT = int(os.environ.get("REWIND_SMOKE_PORT", "18097"))
DATA_DIR = f"/tmp/rewind-smoke-{os.getpid()}"
BIN = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin", "rewind")
ADMIN_HOST = "admin.localhost"
ROOT_TOKEN = "rewindtestroottokenpadding0123456789abcd"  # matches src/rewind/main.zig


def spawn():
    p = subprocess.Popen(
        [BIN, DATA_DIR, str(PORT)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    # Wait for the listen line.
    deadline = time.time() + 15
    while time.time() < deadline:
        line = p.stdout.readline()
        if not line:
            if p.poll() is not None:
                raise SystemExit(f"rewind exited early: rc={p.returncode}")
            continue
        sys.stdout.write("  [rewind] " + line)
        if "listening on" in line:
            return p
    raise SystemExit("rewind did not reach 'listening' within 15s")


def curl_put(key, value):
    """rewind is HTTP/2-only (prior knowledge); use curl --http2-prior-knowledge."""
    out = subprocess.run(
        [
            "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "10",
            "--http2-prior-knowledge", "-X", "POST",
            f"http://127.0.0.1:{PORT}/_system/admin-kv",
            "-H", f"Host: {ADMIN_HOST}",
            "-H", f"Authorization: Bearer {ROOT_TOKEN}",
            "-H", "Content-Type: application/json",
            "--data", json.dumps({"pairs": [{"key": key, "value": value}]}),
        ],
        capture_output=True, text=True,
    )
    return out.stdout.strip()


def stop(p):
    p.send_signal(signal.SIGTERM)
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()


def main():
    if not os.path.exists(BIN):
        raise SystemExit(f"{BIN} not found — run `zig build rewind` first")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    subprocess.run(["rm", "-rf", DATA_DIR])
    failures = []

    # ── Leg 1: write path ────────────────────────────────────────────
    print("leg 1: boot + admin-kv write (propose → bridge commit → 204)")
    p = spawn()
    try:
        code = curl_put("rewind/hello", "world-v2")
        print(f"  write rewind/hello -> HTTP {code}")
        if code != "204":
            failures.append(f"first write expected 204, got {code}")
        code2 = curl_put("rewind/second", "again")  # 2nd propose: per-tenant seq advances
        print(f"  write rewind/second -> HTTP {code2}")
        if code2 != "204":
            failures.append(f"second write expected 204, got {code2}")
    finally:
        stop(p)

    # ── Leg 2: durability across restart (same data_dir) ─────────────
    print("leg 2: restart (reopen __admin__/app.db) + write again")
    p = spawn()
    try:
        code = curl_put("rewind/after-restart", "persisted")
        print(f"  write after restart -> HTTP {code}")
        if code != "204":
            failures.append(f"post-restart write expected 204, got {code}")
    finally:
        stop(p)
        subprocess.run(["rm", "-rf", DATA_DIR])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — rewind serves the Phase-2 write path end to end.")


if __name__ == "__main__":
    main()
