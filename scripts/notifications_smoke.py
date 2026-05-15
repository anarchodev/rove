#!/usr/bin/env python3
"""End-to-end cluster smoke for the centralized notifications channel.

Python port of `scripts/notifications_smoke.sh`. Boots 3-node cluster +
files-server + log-server + sse-server-standalone, then exercises:
  - /_session/sse-token returns {token, notifications_url, ...}
  - EventSource open + events.emit → frame round-trip
  - Cross-tenant isolation (B emits with A's sid → invisible on A)
  - Token / URL tenant mismatch → 403
"""

from __future__ import annotations

import json
import os
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
ADMIN_HOST = f"app.{SYSTEM_SUFFIX}"
TENANT_A = "notifsmokea"
TENANT_B = "notifsmokeb"
SSE_PORT = 8268
SSE_HOST = f"sse.{PUBLIC_SUFFIX}"


def signup_redeem(c: Cluster, cc, name: str) -> None:
    r = curl(
        cc, f"{c.admin_origin()}/v1/signup",
        method="POST",
        headers={"Content-Type": "application/json"},
        data=json.dumps({"name": name, "email": f"{name}@example.com"}),
    )
    if '"ok":true' not in r.body:
        sys.exit(f"FAIL signup {name}: {r.body}")
    mt = json.loads(r.body)["magic_link"].split("mt=")[-1]
    r = curl(cc, f"{c.admin_origin()}/v1/auth?mt={mt}")
    if r.status != 302:
        sys.exit(f"FAIL redeem {name}: {r.status}")


HANDLER_SRC = '''export default function () {
  if (request.path === "/emit") {
    events.emit({type: "order.paid", data: {n: 1}});
    events.emit({type: "order.paid", data: {n: 2}});
    return { sid: request.session ? request.session.id : null };
  }
  if (request.path === "/spoof") {
    const target = (request.query || "").split("=")[1];
    events.emit({to: target, type: "order.paid", data: "should_not_arrive"});
    return { spoofed: target };
  }
  return { hello: request.session ? request.session.id : null };
}'''


def main() -> int:
    sse_internal_token = secrets.token_hex(24)
    sse_public_base = f"http://{SSE_HOST}:{SSE_PORT}"

    # SSE_INTERNAL_TOKEN must be in env BEFORE workers spawn so they
    # inherit it (the worker uses it as the Authorization bearer on
    # outbound emit POSTs to sse-server). spawn_sse_server runs after
    # the workers, so set it explicitly here.
    os.environ["SSE_INTERNAL_TOKEN"] = sse_internal_token

    cluster = Cluster.spawn(
        tag="notifications-smoke",
        http_base=8260,
        raft_base=40360,
        files_port=8267,
        log_port=8266,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        worker_extra_args=["--sse-public-base", sse_public_base],
    )
    with cluster as c:
        # sse-server first so the workers' first emit-POST has something
        # to hit when raft starts committing.
        c.spawn_sse_server(
            listen=f"127.0.0.1:{SSE_PORT}",
            internal_token=sse_internal_token,
        )

        c.discover_leader()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        admin_origin = c.admin_origin()
        c.spawn_files_server(cors_origin=admin_origin, leader_url=admin_origin)
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()

        cc = c.curl_ctx(
            f"{TENANT_A}.{PUBLIC_SUFFIX}",
            f"{TENANT_B}.{PUBLIC_SUFFIX}",
        )
        tenant_a_origin = f"https://{TENANT_A}.{PUBLIC_SUFFIX}:{c.leader_port()}"
        tenant_b_origin = f"https://{TENANT_B}.{PUBLIC_SUFFIX}:{c.leader_port()}"

        leader_log = Path(f"/tmp/notifications-smoke-worker-{c.leader_idx}.out")
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            if leader_log.exists() and "tenant __admin__ loaded deployment" in leader_log.read_text(errors="replace"):
                break
            time.sleep(0.1)

        signup_redeem(c, cc, TENANT_A)
        signup_redeem(c, cc, TENANT_B)
        print(f"ok  signed up two tenants ({TENANT_A}, {TENANT_B})")

        # Deploy events.emit handler to both tenants.
        for tenant in (TENANT_A, TENANT_B):
            # Wait for starter to load first (avoids racing the deploy
            # with the slot opening).
            deadline = time.monotonic() + 15.0
            while time.monotonic() < deadline:
                if f"tenant {tenant} loaded deployment" in leader_log.read_text(errors="replace"):
                    break
                time.sleep(0.1)
            dep = c.put_file(tenant, "index.mjs", HANDLER_SRC)
            c.release(tenant, dep)
        print("ok  deployed events.emit handler to both tenants")

        # Wait for the new index.mjs to land.
        for tenant in (TENANT_A, TENANT_B):
            deadline = time.monotonic() + 10.0
            while time.monotonic() < deadline:
                content = leader_log.read_text(errors="replace")
                # The new deployment has 1 handler, 0 static.
                if re.search(rf"tenant {tenant} loaded deployment \d+ \(1 handler\(s\), 0 static", content):
                    break
                time.sleep(0.1)

        # 3. /_session/sse-token.
        cookie_jar = Path("/tmp/notifications-smoke-cookies.txt")
        cookie_jar.unlink(missing_ok=True)
        # curl needs -c to save cookies. Our smoke_lib curl helper
        # doesn't support that directly; shell out manually here.
        rc = subprocess.run(
            ["curl", "-sS", "--cacert", str(c.tls.cacert)]
            + sum((["--resolve", f"{h}:{p}:127.0.0.1"] for h, p in cc.resolves), [])
            + ["-c", str(cookie_jar),
               f"{tenant_a_origin}/_session/sse-token"],
            capture_output=True, timeout=10.0,
        )
        if rc.returncode != 0:
            sys.exit(f"FAIL sse-token: {rc.stderr.decode()}")
        token_resp = json.loads(rc.stdout.decode())
        token_a = token_resp["token"]
        notif_url = token_resp["notifications_url"]
        if token_resp.get("expires_in") != 3600:
            sys.exit(f"FAIL expires_in: {token_resp}")
        if token_resp.get("tenant_id") != TENANT_A:
            sys.exit(f"FAIL tenant_id: {token_resp}")
        if notif_url != f"{sse_public_base}/v1/{TENANT_A}/sse":
            sys.exit(f"FAIL notifications_url: {notif_url}")
        print("ok  /_session/sse-token returns {token, expires_in:3600, notifications_url, tenant_id}")

        # Extract __Host-rove_sid from cookie jar.
        sid_a = ""
        for line in cookie_jar.read_text().splitlines():
            if "__Host-rove_sid" in line:
                cols = line.split("\t")
                if len(cols) >= 7:
                    sid_a = cols[6]
                    break
        if not sid_a or len(sid_a) != 64:
            sys.exit(f"FAIL no __Host-rove_sid (got {sid_a!r})")
        print(f"ok  /_session/sse-token minted __Host-rove_sid={sid_a[:12]}…")

        # 4. EventSource open + emit + frame.
        sse_log = Path("/tmp/notifications-smoke-stream.out")
        sse_log.unlink(missing_ok=True)
        stream_proc = subprocess.Popen(
            ["curl", "-sS", "--http2-prior-knowledge",
             "--no-buffer", "--max-time", "5",
             "--resolve", f"{SSE_HOST}:{SSE_PORT}:127.0.0.1",
             f"{notif_url}?token={token_a}"],
            stdout=open(sse_log, "wb"), stderr=subprocess.DEVNULL,
        )
        time.sleep(0.5)

        # Trigger emit.
        subprocess.run(
            ["curl", "-sS", "--cacert", str(c.tls.cacert)]
            + sum((["--resolve", f"{h}:{p}:127.0.0.1"] for h, p in cc.resolves), [])
            + ["-b", str(cookie_jar), f"{tenant_a_origin}/emit"],
            capture_output=True, timeout=10.0,
        )
        try:
            stream_proc.wait(timeout=6.0)
        except subprocess.TimeoutExpired:
            stream_proc.terminate()
            stream_proc.wait(timeout=2.0)

        stream_content = sse_log.read_text(errors="replace")
        for needle in [
            'data: {"n":1}',
            'data: {"n":2}',
            "event: order.paid",
        ]:
            if needle not in stream_content:
                sys.exit(f"FAIL missing {needle!r}; stream:\n{stream_content}")
        if not re.search(r"id: \d{20}-\d{6}", stream_content):
            sys.exit(f"FAIL missing id: line; stream:\n{stream_content}")
        print("ok  events.emit → worker POST → sse-server push → EventSource frame")

        # 5. Cross-tenant isolation.
        sse_log_x = Path("/tmp/notifications-smoke-cross.out")
        sse_log_x.unlink(missing_ok=True)
        stream_x = subprocess.Popen(
            ["curl", "-sS", "--http2-prior-knowledge",
             "--no-buffer", "--max-time", "3",
             "--resolve", f"{SSE_HOST}:{SSE_PORT}:127.0.0.1",
             f"{notif_url}?token={token_a}"],
            stdout=open(sse_log_x, "wb"), stderr=subprocess.DEVNULL,
        )
        time.sleep(0.5)

        subprocess.run(
            ["curl", "-sS", "--cacert", str(c.tls.cacert)]
            + sum((["--resolve", f"{h}:{p}:127.0.0.1"] for h, p in cc.resolves), [])
            + [f"{tenant_b_origin}/spoof?to={sid_a}"],
            capture_output=True, timeout=10.0,
        )
        try:
            stream_x.wait(timeout=4.0)
        except subprocess.TimeoutExpired:
            stream_x.terminate()
            stream_x.wait(timeout=2.0)

        if "should_not_arrive" in sse_log_x.read_text(errors="replace"):
            sys.exit("FAIL cross-tenant emit leaked into tenant A's stream")
        print("ok  cross-tenant emit isolated")

        # 6. Token / URL tenant mismatch → 403.
        notif_url_b = notif_url.replace(f"/{TENANT_A}/", f"/{TENANT_B}/")
        rc = subprocess.run(
            ["curl", "-sS", "--http2-prior-knowledge",
             "-o", "/dev/null", "-w", "%{http_code}",
             "--max-time", "1",
             "--resolve", f"{SSE_HOST}:{SSE_PORT}:127.0.0.1",
             f"{notif_url_b}?token={token_a}"],
            capture_output=True, timeout=3.0,
        )
        if rc.stdout.decode().strip() != "403":
            sys.exit(f"FAIL tenant mismatch: expected 403, got {rc.stdout.decode()}")
        print(f"ok  tenant A's token rejected at /v1/{TENANT_B}/sse → 403")

        print()
        print("all notifications smoke checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
