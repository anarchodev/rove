#!/usr/bin/env python3
"""End-to-end smoke for webhook.send → scheduler → callback handler.

Python port of `scripts/webhook_smoke.sh`. Stands up a Python echo HTTP
server that the cluster's scheduler delivers to via libcurl, then
verifies the callback handler ran and wrote cb/result/{id} to acme's kv.
"""

from __future__ import annotations

import http.server
import json
import multiprocessing
import re
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl, _TRACKED_PROCS  # noqa: E402
import subprocess  # noqa: E402

TOKEN = "ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc1"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
ADMIN_HOST = f"app.{SYSTEM_SUFFIX}"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
ECHO_PORT = 9197


def _echo_server_main(port: int, log_path: str) -> None:
    """In-process echo server. Logs every POST + headers to log_path."""
    log = open(log_path, "w", buffering=1)

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(n)
            log.write(f"POST {self.path}\n")
            log.write(f"hdr X-Rove-Schedule-Id={self.headers.get('X-Rove-Schedule-Id') or ''}\n")
            log.write(f"hdr X-Rove-Schedule-Version={self.headers.get('X-Rove-Schedule-Version') or ''}\n")
            log.flush()
            self.send_response(200)
            self.send_header("content-type", "text/plain")
            self.send_header("content-length", str(len(body) + 5))
            self.end_headers()
            self.wfile.write(b"echo:" + body)

        def log_message(self, fmt, *args):
            log.write(f"{self.address_string()} {fmt % args}\n")
            log.flush()

    http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent

    echo_log = Path("/tmp/webhook-smoke-echo.out")
    if echo_log.exists():
        echo_log.unlink()
    echo_proc = multiprocessing.Process(
        target=_echo_server_main,
        args=(ECHO_PORT, str(echo_log)),
        daemon=True,
    )
    echo_proc.start()
    # Sanity check the echo server.
    deadline = time.monotonic() + 3.0
    sanity_ok = False
    while time.monotonic() < deadline:
        try:
            r = subprocess.run(
                ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                 "-X", "POST", "--data", "ping",
                 f"http://127.0.0.1:{ECHO_PORT}/"],
                capture_output=True, timeout=2.0,
            )
            if r.stdout == b"200":
                sanity_ok = True
                break
        except subprocess.TimeoutExpired:
            pass
        time.sleep(0.1)
    if not sanity_ok:
        echo_proc.terminate()
        sys.exit(f"FAIL python echo target didn't come up on :{ECHO_PORT}")
    print(f"ok  python echo target up on :{ECHO_PORT}")

    cluster = Cluster.spawn(
        tag="webhook-smoke",
        http_base=8245,
        raft_base=40345,
        files_port=8249,
        log_port=8250,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        admin_api_domain=ADMIN_HOST,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        worker_extra_args=["--dev-webhook-unsafe"],
    )
    try:
        with cluster as c:
            c.discover_leader()
            print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

            admin_origin = c.admin_origin()
            c.spawn_files_server(cors_origin=admin_origin, leader_url=admin_origin)

            cc = c.curl_ctx(ACME_HOST)
            acme_origin = f"https://{ACME_HOST}:{c.leader_port()}"

            # 3. Fire the webhook through acme's cbfire handler. Poll
            # for the handler to be loaded.
            args = urllib.parse.quote(json.dumps([f"http://127.0.0.1:{ECHO_PORT}/hook", "smoke1"]))
            send_id = ""
            deadline = time.monotonic() + 20.0
            while time.monotonic() < deadline:
                r = curl(cc, f"{acme_origin}/cbfire?fn=fire&args={args}")
                if r.status == 200:
                    try:
                        send_id = json.loads(r.body)["id"]
                        if send_id:
                            break
                    except (json.JSONDecodeError, KeyError):
                        pass
                time.sleep(0.2)
            if not send_id:
                sys.exit(f"FAIL fire didn't return an id: {r.body}")
            print(f"ok  handler fired webhook, id={send_id}")

            # 4. Wait for delivery to echo server.
            deadline = time.monotonic() + 6.0
            saw_post = False
            while time.monotonic() < deadline:
                if echo_log.exists() and "POST /hook" in echo_log.read_text(errors="replace"):
                    saw_post = True
                    break
                time.sleep(0.1)
            if not saw_post:
                sys.exit(f"FAIL scheduler never delivered to echo: {echo_log.read_text(errors='replace')}")
            print("ok  scheduler delivered webhook to echo target")

            # 4a. Metadata headers.
            content = echo_log.read_text(errors="replace")
            if f"hdr X-Rove-Schedule-Id={send_id}" not in content:
                sys.exit(f"FAIL X-Rove-Schedule-Id header: {content}")
            if "hdr X-Rove-Schedule-Version=1" not in content:
                sys.exit(f"FAIL X-Rove-Schedule-Version header: {content}")
            print("ok  scheduler stamped X-Rove-Schedule-Id + X-Rove-Schedule-Version")

            # 5. Read the callback result via admin API.
            qs = urllib.parse.quote(json.dumps(["cb/result/", "", 100]))
            deadline = time.monotonic() + 6.0
            result_body = ""
            while time.monotonic() < deadline:
                r = curl(
                    cc, f"{admin_origin}/?fn=listKv&args={qs}",
                    headers={
                        "Authorization": f"Bearer {TOKEN}",
                        "X-Rove-Scope": "acme",
                    },
                )
                if '"key":"cb/result/' in r.body:
                    result_body = r.body
                    break
                time.sleep(0.1)
            if not result_body:
                sys.exit(f"FAIL no cb/result/* row: {r.body}")
            print("ok  callback handler wrote cb/result/{id} to acme kv")

            # Event shape verification.
            doc = json.loads(result_body)
            match = None
            for e in doc.get("entries", []):
                if e["key"] == "cb/result/" + send_id:
                    match = json.loads(e["value"])
                    break
            if match is None:
                sys.exit(f"FAIL no entry for cb/result/{send_id}: {result_body}")
            if match.get("ok") is not True:
                sys.exit(f"FAIL ok: {match.get('ok')!r}")
            if match.get("status") != 200:
                sys.exit(f"FAIL status: {match.get('status')!r}")
            if match.get("body") != "echo:ping":
                sys.exit(f"FAIL body: {match.get('body')!r}")
            if match.get("context", {}).get("tag") != "smoke1":
                sys.exit(f"FAIL context: {match.get('context')!r}")
            print("ok  callback event shape: ok=true, status=200, body='echo:ping', context.tag=smoke1")

            # 6. Receipt cleared.
            qs = urllib.parse.quote(json.dumps(["_callback/", "", 100]))
            r = curl(
                cc, f"{admin_origin}/?fn=listKv&args={qs}",
                headers={
                    "Authorization": f"Bearer {TOKEN}",
                    "X-Rove-Scope": "acme",
                },
            )
            if '"key":"_callback/' in r.body:
                sys.exit(f"FAIL _callback/* receipt not deleted: {r.body}")
            print("ok  _callback/{id} receipt cleared after callback ran")

            print()
            print("all webhook-callback smoke checks passed")
            return 0
    finally:
        echo_proc.terminate()
        echo_proc.join(timeout=2.0)
        if echo_proc.is_alive():
            echo_proc.kill()


if __name__ == "__main__":
    sys.exit(main())
