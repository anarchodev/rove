#!/usr/bin/env python3
"""Spin up a dev cluster + files-server + log-server with the demo
seed manifest, drive a few requests through replay_demo so the
dashboard has captured records to replay, signs up an admin user
(prints the magic-link URL), and blocks until Ctrl-C.

Browse to the printed dashboard URL. Click an instance to see the
replay_demo records, then either:
  - "Replay" → opens the iframe debugger (DevTools)
  - "⚙"      → opens the WASM scrubber at replay.<suffix>/wasm

Iteration loop:
  1. Edit any file under web/admin/ or web/replay/
  2. Kill files-server-standalone:  pkill -x files-server-standalone
  3. Re-run this script (or just respawn files-server-standalone)
     — bootstrap reads the new bytes from disk and re-deploys
  4. Hard-refresh the browser tab

Note: by default the bootstrap is content-blind (returns the
existing deploy_id when `_deploy/current` is already set), so for
admin UI changes to land you currently need to also wipe the data
dir between runs — the script does that for you on `--reset`.
"""

from __future__ import annotations

import json
import signal
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
PUBLIC_SUFFIX = "loop46.localhost"
TENANT_ID = "replay_demo"
TENANT_HOST = f"replay-demo.{PUBLIC_SUFFIX}"
TOKEN = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"


def main() -> int:
    print("== replay-wasm dev bringup ==", flush=True)
    cluster = Cluster.spawn(
        tag="replay-wasm-dev",
        http_base=8290,
        raft_base=40390,
        files_port=8294,
        log_port=8293,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        seed_manifest=REPO_ROOT / "examples" / "loop46-demo-tenants.json",
    )

    # Cluster.spawn returns a context manager that tears down on exit
    # — invoke __enter__ manually so we can keep it alive across the
    # main loop. A signal handler cleans up.
    c = cluster.__enter__()
    stopped = {"flag": False}

    def shutdown(*_):
        if stopped["flag"]:
            return
        stopped["flag"] = True
        print("\n== tearing down ==", flush=True)
        try:
            cluster.__exit__(None, None, None)
        except Exception as err:
            print(f"  shutdown error: {err}", flush=True)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    try:
        c.discover_leader()
        admin_origin = c.admin_origin()
        leader_port = c.leader_port()
        c.spawn_files_server(cors_origin=admin_origin, leader_url=admin_origin)
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()
        print(f"  leader:       {c.addrs.http[c.leader_idx]}", flush=True)
        print(f"  admin host:   {admin_origin}", flush=True)
        print(f"  files-server: {c.files_url()}", flush=True)
        print(f"  log-server:   {c.log_url()}", flush=True)

        # Drive a handful of requests so the dashboard has something
        # to show. Mix of /?fn=handler (200 with captured tapes) and
        # /throw?fn=handler (500 with the trimmed throw record).
        cc = c.curl_ctx(TENANT_HOST)
        tenant_origin = f"https://{TENANT_HOST}:{leader_port}"
        c.wait_for_handler(TENANT_ID, "/?fn=handler", expected_status=200, timeout_s=15.0)
        for _ in range(5):
            r = curl(cc, f"{tenant_origin}/?fn=handler")
            if r.status != 200:
                print(f"  warn: {TENANT_ID} GET / → {r.status}", flush=True)
        for _ in range(2):
            r = curl(cc, f"{tenant_origin}/throw?fn=handler")
            if r.status != 500:
                print(f"  warn: {TENANT_ID} /throw → {r.status} (expected 500)", flush=True)
        print(f"  drove 5 ok + 2 throw requests through {TENANT_ID}", flush=True)

        # Sign up an admin user so there's a session to log into the
        # dashboard with. In dev (no email backend) /v1/signup
        # returns the magic-link inline; click it once to mint the
        # cookie, then the dashboard works like normal.
        admin_cc = c.curl_ctx()
        r = curl(
            admin_cc,
            f"{admin_origin}/v1/signup",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"name":"dev","email":"dev@example.com"}',
        )
        # Signup returns 202 (accepted) in dev. When no Resend key is
        # configured, the response body carries `magic_link` inline so
        # we can paste it; otherwise the link was emailed and we'd
        # have to read the user's inbox.
        magic_link = None
        if r.status in (200, 202):
            try:
                magic_link = json.loads(r.body).get("magic_link")
            except json.JSONDecodeError:
                pass

        print("", flush=True)
        print("══════════════════════════════════════════════════════════════", flush=True)
        print(" dashboard URLs (paste into your browser)", flush=True)
        print("══════════════════════════════════════════════════════════════", flush=True)
        if magic_link:
            print(f"  1. one-click login (mints the session cookie):", flush=True)
            print(f"     {magic_link}", flush=True)
            print(f"  2. dashboard root after login:", flush=True)
            print(f"     {admin_origin}/", flush=True)
        else:
            print(f"  signup didn't return a magic link (status={r.status})", flush=True)
            print(f"  visit {admin_origin}/ and sign up by hand", flush=True)
        print("", flush=True)
        print("  replay shells (opened automatically by the Replay buttons):", flush=True)
        print(f"    iframe: https://replay.{PUBLIC_SUFFIX}:{leader_port}/", flush=True)
        print(f"    wasm:   https://replay.{PUBLIC_SUFFIX}:{leader_port}/wasm", flush=True)
        print("", flush=True)
        print("  tenant + sample request:", flush=True)
        print(f"    {tenant_origin}/?fn=handler", flush=True)
        print("══════════════════════════════════════════════════════════════", flush=True)
        print("", flush=True)
        print(" iteration loop (no zig build needed for UI edits):", flush=True)
        print("   1. edit web/admin/* or web/replay/*", flush=True)
        print("   2. Ctrl-C this script", flush=True)
        print("   3. re-run it — Cluster.spawn wipes data dirs, so", flush=True)
        print("      bootstrap re-deploys the admin/replay tenants", flush=True)
        print("      with the new bytes (you'll click the new magic", flush=True)
        print("      link each run since the session is fresh)", flush=True)
        print("", flush=True)
        print(" Ctrl-C to shut down.", flush=True)
        print("", flush=True)

        # Block until a signal lands. shutdown() is wired to both
        # SIGINT and SIGTERM; the existing _TRACKED_PROCS atexit also
        # backs us up if the script dies any other way.
        while not stopped["flag"]:
            time.sleep(1.0)
    finally:
        shutdown()

    return 0


if __name__ == "__main__":
    sys.exit(main())
