#!/usr/bin/env python3
"""sse-server-standalone end-to-end smoke (docs/sse-plan.md).

Python port of `scripts/sse_server_smoke.sh`. Boots sse-server-standalone,
exercises every wire shape (auth/body validation, EventSource auth +
happy path, end-to-end emit → frame), and asserts cross-tenant isolation.
"""

from __future__ import annotations

import os
import secrets
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import BIN_DIR, _TRACKED_PROCS, mint_jwt  # noqa: E402

PORT = 18230
SID_A_X = "a" * 64
SID_A_Y = "b" * 64


def curl_h2(args: list[str], *, timeout: float = 5.0) -> tuple[int, bytes]:
    """h2-cleartext curl invocation. Returns (exit_status, stdout)."""
    proc = subprocess.run(
        ["curl", "-s", "--http2-prior-knowledge"] + args,
        capture_output=True,
        timeout=timeout,
    )
    return proc.returncode, proc.stdout


def http_status(url: str, *, headers: dict | None = None, method: str = "GET",
                data: str | None = None, max_time: float | None = None) -> int:
    args = ["-o", "/dev/null", "-w", "%{http_code}"]
    if max_time is not None:
        args += ["--max-time", str(max_time)]
    if method != "GET":
        args += ["-X", method]
    if headers:
        for k, v in headers.items():
            args += ["-H", f"{k}: {v}"]
    if data is not None:
        args += ["-d", data]
    args.append(url)
    rc, body = curl_h2(args, timeout=max_time + 2.0 if max_time else 5.0)
    try:
        return int(body.decode().strip())
    except ValueError:
        return 0


def expect_status(label: str, expected: int, got: int) -> None:
    if got != expected:
        sys.exit(f"FAIL ({label}): expected HTTP {expected}, got {got}")
    print(f"ok: {label} → {got}")


def main() -> int:
    bin_path = BIN_DIR / "sse-server-standalone"
    if not bin_path.exists():
        sys.exit(f"error: {bin_path} missing — run 'zig build install' first")

    jwt_secret = secrets.token_hex(32)
    internal_token = secrets.token_hex(24)

    env = os.environ.copy()
    env["SSE_INTERNAL_TOKEN"] = internal_token
    env["LOOP46_SERVICES_JWT_SECRET"] = jwt_secret

    log_path = Path("/tmp/sse-smoke-server.log")
    log_f = open(log_path, "wb")
    proc = subprocess.Popen(
        [str(bin_path), "--listen", f"127.0.0.1:{PORT}"],
        env=env, stdout=log_f, stderr=subprocess.STDOUT,
    )
    _TRACKED_PROCS.append(proc)

    try:
        # Wait for /v1/health.
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            rc, _ = curl_h2(
                ["-sf", f"http://127.0.0.1:{PORT}/v1/health"], timeout=1.0,
            )
            if rc == 0:
                break
            time.sleep(0.05)

        # 1. health
        code = http_status(f"http://127.0.0.1:{PORT}/v1/health")
        expect_status("GET /v1/health", 200, code)

        # 2. /v1/emit auth + body
        good_body = (
            f'{{"v":1,"tenant_id":"acme","request_id":1,'
            f'"events":[{{"event_id":"00000000000000000001-000000",'
            f'"type":"comment_added","data":{{"id":99}},'
            f'"target_sids":["{SID_A_X}"],"created_at_ms":1730764800000}}]}}'
        )
        code = http_status(
            f"http://127.0.0.1:{PORT}/v1/emit",
            method="POST",
            headers={"Authorization": "Bearer wrong-token", "Content-Type": "application/json"},
            data=good_body,
        )
        expect_status("POST /v1/emit (bad bearer)", 401, code)

        code = http_status(
            f"http://127.0.0.1:{PORT}/v1/emit",
            method="POST",
            headers={"Authorization": f"Bearer {internal_token}", "Content-Type": "application/json"},
            data="not-json",
        )
        expect_status("POST /v1/emit (malformed body)", 400, code)

        code = http_status(
            f"http://127.0.0.1:{PORT}/v1/emit",
            method="POST",
            headers={"Authorization": f"Bearer {internal_token}", "Content-Type": "application/json"},
            data=good_body,
        )
        expect_status("POST /v1/emit (worker-shaped body)", 204, code)

        # 3. EventSource auth
        exp = int(time.time() * 1000) + 60_000
        token_a = mint_jwt(jwt_secret, {
            "v": 1, "tenant_id": "acme", "sid": SID_A_X,
            "caps": {"max_conns_per_session": 16, "max_event_payload_bytes": 65536},
            "exp": exp,
        })
        token_b = mint_jwt(jwt_secret, {
            "v": 1, "tenant_id": "beta", "sid": SID_A_X,
            "caps": {"max_conns_per_session": 16, "max_event_payload_bytes": 65536},
            "exp": exp,
        })

        code = http_status(f"http://127.0.0.1:{PORT}/v1/acme/sse", max_time=1.0)
        expect_status("GET /v1/acme/sse (no token)", 401, code)
        code = http_status(f"http://127.0.0.1:{PORT}/v1/acme/sse?token=not-a-jwt", max_time=1.0)
        expect_status("GET /v1/acme/sse (malformed token)", 401, code)
        tampered = token_a[:-1] + "X"
        code = http_status(f"http://127.0.0.1:{PORT}/v1/acme/sse?token={tampered}", max_time=1.0)
        expect_status("GET /v1/acme/sse (bad signature)", 401, code)
        code = http_status(f"http://127.0.0.1:{PORT}/v1/acme/sse?token={token_b}", max_time=1.0)
        expect_status("GET /v1/acme/sse (tenant mismatch)", 403, code)

        # Happy path: 200 + text/event-stream.
        rc, body = curl_h2(
            ["-i", "--max-time", "1", f"http://127.0.0.1:{PORT}/v1/acme/sse?token={token_a}"],
            timeout=3.0,
        )
        text = body.decode(errors="replace")
        if "HTTP/2 200" not in text:
            sys.exit(f"FAIL: EventSource happy path didn't return 200: {text[:300]}")
        if "text/event-stream" not in text.lower():
            sys.exit(f"FAIL: EventSource happy path missing text/event-stream: {text[:300]}")
        print("ok: GET /v1/acme/sse (happy path) → 200 text/event-stream")

        # 4. End-to-end live push.
        def open_stream(url: str) -> subprocess.Popen:
            return subprocess.Popen(
                ["curl", "-s", "--http2-prior-knowledge", "--max-time", "2", url],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            )

        stream_proc = open_stream(f"http://127.0.0.1:{PORT}/v1/acme/sse?token={token_a}")
        time.sleep(0.3)
        emit_e2e = (
            f'{{"v":1,"tenant_id":"acme","request_id":42,'
            f'"events":[{{"event_id":"00000000000000000042-000000",'
            f'"type":"comment_added","data":{{"id":99}},'
            f'"target_sids":["{SID_A_X}"],"created_at_ms":1730764800000}}]}}'
        )
        http_status(
            f"http://127.0.0.1:{PORT}/v1/emit",
            method="POST",
            headers={"Authorization": f"Bearer {internal_token}", "Content-Type": "application/json"},
            data=emit_e2e,
        )
        out, _ = stream_proc.communicate(timeout=4.0)
        stream_text = out.decode(errors="replace")
        for needle in [
            "id: 00000000000000000042-000000",
            "event: comment_added",
            'data: {"id":99}',
        ]:
            if needle not in stream_text:
                sys.exit(f"FAIL: live frame missing {needle!r}: {stream_text[:300]}")
        print("ok: end-to-end emit → EventSource frame")

        # 5. Cross-tenant isolation.
        stream_a = open_stream(f"http://127.0.0.1:{PORT}/v1/acme/sse?token={token_a}")
        time.sleep(0.3)
        emit_b = (
            f'{{"v":1,"tenant_id":"beta","request_id":99,'
            f'"events":[{{"event_id":"00000000000000009999-000000",'
            f'"type":"leak","data":null,'
            f'"target_sids":["{SID_A_X}"],"created_at_ms":1730764800000}}]}}'
        )
        http_status(
            f"http://127.0.0.1:{PORT}/v1/emit",
            method="POST",
            headers={"Authorization": f"Bearer {internal_token}", "Content-Type": "application/json"},
            data=emit_b,
        )
        out, _ = stream_a.communicate(timeout=4.0)
        text = out.decode(errors="replace")
        if "leak" in text or "9999" in text:
            sys.exit(f"FAIL: cross-tenant frame leaked: {text[:300]}")
        print("ok: cross-tenant isolation (beta emit invisible on acme stream)")

        print()
        print("PASS: sse-server-standalone smoke")
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            proc.kill()
        log_f.close()


if __name__ == "__main__":
    sys.exit(main())
