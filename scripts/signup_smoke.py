#!/usr/bin/env python3
"""End-to-end smoke test for the magic-link signup + auth flow.

Python port of `scripts/signup_smoke.sh`. Covers:
  - POST /v1/signup (fresh / dup / reserved / bad email / per-account limit)
  - GET /v1/auth?mt=<token> → 302 + Set-Cookie + Location:/#/{name}
  - Cookie auth for /v1/session
  - Single-use magic link replay → 401
  - Starter static + handler on the new instance
  - Throwing handler → 500 with exception in body
  - request.headers + request.cookies plumbing
  - With Resend key configured: signup queues a webhook
"""

from __future__ import annotations

import json
import re
import secrets
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl, expect_status  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
ADMIN_HOST = f"app.{SYSTEM_SUFFIX}"


def main() -> int:
    cluster = Cluster.spawn(
        tag="signup-smoke",
        http_base=8230,
        raft_base=40330,
        files_port=8259,
        log_port=8258,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
    )
    with cluster as c:
        c.discover_leader()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        origin = c.admin_origin()
        c.spawn_files_server(cors_origin=origin, leader_url=origin)
        c.spawn_log_server(cors_origin=origin)
        c.mint_services_token()

        cc = c.curl_ctx(
            f"alice.{PUBLIC_SUFFIX}",
            f"bob.{PUBLIC_SUFFIX}",
        )
        alice_origin = f"https://alice.{PUBLIC_SUFFIX}:{c.leader_port()}"

        # Wait for admin tenant to be loaded (deployment loader is async).
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            r = curl(
                cc, f"{origin}/v1/signup",
                method="POST",
                headers={"Content-Type": "application/json"},
                data='{"name":"_probe","email":"probe@example.com"}',
            )
            if r.status != 503:
                break
            time.sleep(0.2)

        # 1. Fresh signup → 202 + magic_link.
        r = curl(
            cc, f"{origin}/v1/signup",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"name":"alice","email":"alice@example.com"}',
        )
        expect_status("POST /v1/signup (fresh)", 202, r)
        parsed = json.loads(r.body)
        if not parsed.get("ok"):
            sys.exit(f"FAIL signup body missing ok:true: {r.body}")
        if parsed.get("name") != "alice":
            sys.exit(f"FAIL signup body missing name: {r.body}")
        magic_link = parsed.get("magic_link")
        if not magic_link:
            sys.exit(f"FAIL signup body missing magic_link: {r.body}")
        print("ok  POST /v1/signup (fresh) → 202 + magic_link")

        mt = magic_link.split("mt=")[-1]
        if len(mt) != 64:
            sys.exit(f"FAIL magic token wrong length: {len(mt)}")
        print("ok  magic token is 64 hex chars")

        # 2. Duplicate name → 409.
        r = curl(
            cc, f"{origin}/v1/signup",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"name":"alice","email":"someone@example.com"}',
        )
        expect_status("duplicate name → 409", 409, r)
        if '"error":"name unavailable"' not in r.body:
            sys.exit(f"FAIL duplicate name body: {r.body}")

        # 3. Reserved name → 409.
        r = curl(
            cc, f"{origin}/v1/signup",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"name":"admin","email":"evil@example.com"}',
        )
        expect_status("reserved name → 409", 409, r)
        if '"error":"name unavailable"' not in r.body:
            sys.exit(f"FAIL reserved name body: {r.body}")

        # 4. Invalid email → 400.
        r = curl(
            cc, f"{origin}/v1/signup",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"name":"bob","email":"no-at-sign"}',
        )
        expect_status("invalid email → 400", 400, r)

        # 4a. Per-account instance limit (pending state).
        r = curl(
            cc, f"{origin}/v1/signup",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"name":"alice2","email":"alice@example.com"}',
        )
        expect_status("second signup same email (pending state) → 403", 403, r)
        if '"error":"account_limit_reached"' not in r.body:
            sys.exit(f"FAIL limit (pending) body: {r.body}")

        r = curl(
            cc, f"{origin}/v1/signup",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"name":"carol","email":"carol@example.com"}',
        )
        expect_status("different email accepted", 202, r)

        # 5. Redeem the magic link → 302 + Set-Cookie + CORS.
        r = curl(cc, f"{origin}/v1/auth?mt={mt}")
        expect_status("GET /v1/auth?mt=...", 302, r)
        if not r.headers.get("location", "").startswith("/#/alice"):
            sys.exit(f"FAIL redeem missing Location: {r.headers}")
        sc = r.headers.get("set-cookie", "")
        if "rove_session=" not in sc:
            sys.exit(f"FAIL redeem missing session cookie: {sc}")
        if "httponly" not in sc.lower():
            sys.exit(f"FAIL redeem cookie missing HttpOnly: {sc}")
        for h, want in [
            ("access-control-allow-origin", origin),
            ("access-control-allow-credentials", "true"),
            ("vary", "origin"),
            ("access-control-expose-headers", "content-type"),
        ]:
            if r.headers.get(h, "").lower() != want.lower():
                sys.exit(f"FAIL redeem missing {h}: {r.headers}")
        m = re.search(r"rove_session=[^;]+", sc)
        if not m:
            sys.exit(f"FAIL extracting rove_session from {sc}")
        cookie = m.group(0)
        print("ok  GET /v1/auth?mt=... → 302 + session cookie + Location + full CORS envelope")

        # 6. Cookie authenticates /v1/session.
        r = curl(cc, f"{origin}/v1/session", headers={"Cookie": cookie})
        if '"is_root":true' not in r.body:
            sys.exit(f"FAIL whoami after magic: {r.body}")
        print("ok  magic-link session authenticates /v1/session")

        # 7. Single-use replay → 401.
        r = curl(cc, f"{origin}/v1/auth?mt={mt}")
        expect_status("second redeem of the same link → 401 (single-use)", 401, r)

        # 8. Malformed / missing magic token → 401.
        r = curl(cc, f"{origin}/v1/auth?mt=zz")
        expect_status("malformed mt → 401", 401, r)
        r = curl(cc, f"{origin}/v1/auth")
        expect_status("missing mt → 401", 401, r)

        # 9. listInstance includes alice.
        r = curl(
            cc, f"{origin}/?fn=listInstance",
            headers={"Authorization": f"Bearer {TOKEN}"},
        )
        if '"id":"alice"' not in r.body:
            sys.exit(f"FAIL listInstance missing alice: {r.body}")
        print("ok  signup-created instance visible via listInstance")

        # 9a. Per-account limit still applies (owned state).
        r = curl(
            cc, f"{origin}/v1/signup",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"name":"alicepost","email":"alice@example.com"}',
        )
        expect_status("limit (owned state) → 403", 403, r)
        if '"error":"account_limit_reached"' not in r.body:
            sys.exit(f"FAIL limit (owned) body: {r.body}")

        # Starter content — poll because alice's starter deploy is
        # async (signup triggers a deploy on the backend).
        r = c.wait_for_handler(
            "alice", "/", expected_status=200, timeout_s=15.0,
        )
        if "Your Loop46 app is live" not in r.body:
            sys.exit(f"FAIL starter HTML body: {r.body[:200]}")
        print(f"ok  starter content: GET {alice_origin}/ → 200")

        r = curl(cc, f"{alice_origin}/api")
        expect_status("starter handler /api", 200, r)
        if "Your Loop46 API is live" not in r.body:
            sys.exit(f"FAIL starter handler body: {r.body[:200]}")
        print(f"ok  starter content: GET {alice_origin}/api → 200")

        # Throwing handler → 500.
        throw_src = 'export default function () { throw new Error("boom from smoke"); }'
        dep_id = c.put_file("alice", "throw/index.mjs", throw_src)
        print(f"ok  PUT throw/index.mjs → dep_id={dep_id}")
        c.release("alice", dep_id)
        print(f"ok  released alice/{dep_id}")
        # Wait until reload picks it up.
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            r = curl(cc, f"{alice_origin}/throw")
            if r.status == 500:
                break
            time.sleep(0.1)
        expect_status("throw handler → 500", 500, r)
        if "handler threw" not in r.body:
            sys.exit(f"FAIL throw body missing 'handler threw': {r.body}")
        if "boom from smoke" not in r.body:
            sys.exit(f"FAIL throw body missing exception message: {r.body}")

        # request.headers + request.cookies.
        echo_src = '''export default function () {
  return JSON.stringify({
    ua: request.headers["user-agent"] ?? null,
    sig: request.headers["x-test-sig"] ?? null,
    sess: request.cookies["sid"] ?? null,
    extra: request.cookies["extra"] ?? null,
    method_pseudo: request.headers[":method"] ?? null,
  });
}'''
        dep_id = c.put_file("alice", "echo/index.mjs", echo_src)
        c.release("alice", dep_id)
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            r = curl(
                cc, f"{alice_origin}/echo",
                headers={
                    "User-Agent": "smoke/1",
                    "X-Test-Sig": "v0=abc",
                    "Cookie": "sid=alice123; extra=x; bare",
                },
            )
            if r.status == 200 and '"ua":"smoke/1"' in r.body:
                break
            time.sleep(0.1)
        for needle, label in [
            ('"ua":"smoke/1"', "user-agent"),
            ('"sig":"v0=abc"', "x-test-sig"),
            ('"sess":"alice123"', "sid cookie"),
            ('"extra":"x"', "extra cookie"),
            ('"method_pseudo":null', "pseudo :method filtered"),
        ]:
            if needle not in r.body:
                sys.exit(f"FAIL {label} missing: {r.body}")
        print("ok  request.headers + request.cookies expose wire data to handler")

        # Resend path: respawn files-server with bootstrap-kv setting
        # resend_key + platform_email_from. New signup should suppress
        # magic_link from response body + queue a webhook.
        resend_key = f"re_smoke_{secrets.token_hex(4)}"
        c.respawn_files_server(
            cors_origin=origin,
            leader_url=origin,
            extra_args=[
                "--bootstrap-kv", f"resend_key={resend_key}",
                "--bootstrap-kv", "platform_email_from=noreply@smoke.test",
            ],
        )
        r = curl(
            cc, f"{origin}/v1/signup",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"name":"bob","email":"bob@example.com"}',
        )
        if '"ok":true' not in r.body:
            sys.exit(f"FAIL resend-path signup: {r.body}")
        if '"name":"bob"' not in r.body:
            sys.exit(f"FAIL resend-path signup missing name: {r.body}")
        if '"magic_link"' in r.body:
            sys.exit(f"FAIL resend-path leaked magic_link: {r.body}")
        print("ok  signup with Resend key → 202, magic_link suppressed")

        # Wait for the webhook delivery line in any worker log. The
        # signup-triggered webhook gets dispatched through the
        # schedule-server (status= outcome=) — the actual API call to
        # api.resend.com fails 401 because resend_key is fake, but the
        # smoke just wants to see "the email made it through the pipeline".
        deadline = time.monotonic() + 8.0
        saw_webhook = False
        while time.monotonic() < deadline:
            for i in range(3):
                log_path = Path(f"/tmp/signup-smoke-worker-{i}.out")
                if log_path.exists():
                    content = log_path.read_text(errors="replace")
                    if re.search(r"(webhook-server|schedule-server):.*outcome=(failed|success)", content):
                        saw_webhook = True
                        break
            if saw_webhook:
                break
            time.sleep(0.3)
        if not saw_webhook:
            tails = []
            for i in range(3):
                log_path = Path(f"/tmp/signup-smoke-worker-{i}.out")
                if log_path.exists():
                    tails.append(f"--- worker {i} log ---\n{log_path.read_text(errors='replace')[-1500:]}")
            sys.exit("FAIL no webhook dispatch in any worker log:\n" + "\n".join(tails))
        print("ok  signup queued a webhook → dispatched (terminal status logged)")

        print()
        print("all signup smoke checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
