#!/usr/bin/env python3
"""Browser-in-the-loop smoke for the Stripe-style RPC-via-notifications recipe.

Python port of `scripts/notifications_browser_smoke.sh` (the bash wrapper).
The Playwright runner itself was already Python — this rewrite folds the
orchestration in too. Drives a 3-node loop46 cluster + sse-server (TLS) +
fake-Stripe HTTP target, deploys a customer app (handler + callback +
rove.js + test page), then runs Chromium and asserts on the result.

Lazily installs Playwright into /tmp/rove-pw-venv on first run.
"""

from __future__ import annotations

import http.server
import json
import multiprocessing
import os
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import BIN_DIR, Cluster, _TRACKED_PROCS, curl  # noqa: E402

TOKEN = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
ADMIN_HOST = f"app.{SYSTEM_SUFFIX}"
TENANT = "notifbrowsmoke"
SSE_HOST = f"sse.{PUBLIC_SUFFIX}"
SSE_PORT = 8278
STRIPE_PORT = 9202


def _stripe_server(port: int, log_path: str) -> None:
    log = open(log_path, "w", buffering=1)

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("content-length", 0))
            self.rfile.read(n)
            body = json.dumps({
                "id": "cs_test_smoke_session",
                "url": "https://stripe.example.test/c/cs_test_smoke_session",
                "object": "checkout.session",
            })
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode())

        def log_message(self, fmt, *args):
            log.write(f"stripe {fmt % args}\n")

    http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()


def ensure_playwright() -> Path:
    """Lazy-install Playwright into /tmp/rove-pw-venv (~250 MB)."""
    venv = Path("/tmp/rove-pw-venv")
    pw_exe = venv / "bin" / "playwright"
    if not pw_exe.exists():
        print(f"Installing Playwright into {venv} (one-time, ~250 MB)...")
        subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
        pip = venv / "bin" / "pip"
        subprocess.run([str(pip), "install", "--quiet", "--upgrade", "pip"], check=True)
        subprocess.run([str(pip), "install", "--quiet", "playwright"], check=True)
        subprocess.run([str(pw_exe), "install", "chromium"], check=True)
        print("Playwright installed.")
    return venv / "bin" / "python"


# The Playwright runner is small — inline it here so this smoke file is
# self-contained.
RUNNER_SOURCE = '''
import argparse, asyncio, sys
from playwright.async_api import async_playwright

async def run(url, timeout_ms):
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True, args=[
            "--host-resolver-rules=MAP * 127.0.0.1",
            "--ignore-certificate-errors",
            "--disable-features=NetworkServiceInProcess2",
        ])
        try:
            ctx = await browser.new_context(ignore_https_errors=True)
            page = await ctx.new_page()
            page.on("console", lambda m: print(f"[console] {m.type}: {m.text}", file=sys.stderr))
            page.on("pageerror", lambda err: print(f"[pageerror] {err}", file=sys.stderr))
            page.on("requestfailed", lambda req: print(f"[requestfailed] {req.method} {req.url}: {req.failure}", file=sys.stderr))
            page.on("response", lambda r: print(f"[response] {r.status} {r.request.method} {r.url}", file=sys.stderr))
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=timeout_ms)
            except Exception as exc:
                print(f"[runner] page.goto failed: {exc}", file=sys.stderr); return 1
            try:
                await page.wait_for_function(
                    """() => {
                        const s = document.getElementById('status');
                        if (!s) return false;
                        const t = s.textContent.trim();
                        return t === 'ok' || t.startsWith('fail');
                    }""",
                    timeout=timeout_ms,
                )
            except Exception as exc:
                print(f"[runner] wait_for_function failed: {exc}", file=sys.stderr)
                try:
                    html = await page.content()
                    print(f"[runner] page.content() at timeout (first 2KB):", file=sys.stderr)
                    print(html[:2048], file=sys.stderr)
                except Exception:
                    pass
                return 1
            status = (await page.text_content("#status") or "").strip()
            result = (await page.text_content("#result") or "").strip()
            if status == "ok":
                print("PASS")
                if result: print(result)
                return 0
            print(f"FAIL browser status: {status}", file=sys.stderr)
            if result: print(f"--- #result ---\\n{result}", file=sys.stderr)
            return 1
        finally:
            await browser.close()

ap = argparse.ArgumentParser()
ap.add_argument("--url", required=True)
ap.add_argument("--timeout-ms", type=int, default=30_000)
args = ap.parse_args()
sys.exit(asyncio.run(run(args.url, args.timeout_ms)))
'''


TEST_HTML = '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>rove notifications smoke</title>
<style>
body { font-family: ui-monospace, monospace; padding: 2rem; max-width: 60ch; }
#status { font-size: 1.25rem; }
#status.ok { color: #0a7; }
#status.fail { color: #b00; }
pre { background: #f4f4f4; padding: 1rem; border-radius: 4px; }
</style>
<script src="/rove.js"></script>
</head>
<body>
<h1>rove notifications smoke</h1>
<p id="status">starting</p>
<pre id="result"></pre>
<script>
(async () => {
  const setStatus = (s, cls) => {
    const el = document.getElementById('status');
    el.textContent = s;
    el.className = cls || '';
  };
  const setResult = (s) => { document.getElementById('result').textContent = s; };
  try {
    const events = await rove.events.subscribe();
    setStatus('subscribed');
    const cid = (crypto.randomUUID && crypto.randomUUID()) ||
                (Math.random().toString(36).slice(2) + Date.now());
    const promise = events.waitFor(
      'checkout.created',
      e => e.data && e.data.correlation_id === cid,
      { timeoutMs: 20000 },
    );
    const r = await fetch('/api/checkout/start', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ correlation_id: cid, items: [{ sku: 'foo', qty: 1 }] }),
    });
    if (!r.ok) throw new Error('start ' + r.status + ': ' + await r.text());
    setStatus('awaiting webhook callback');
    const evt = await promise;
    if (!evt.data || !evt.data.session_id || !evt.data.stripe_url) {
      throw new Error('event missing fields: ' + JSON.stringify(evt));
    }
    setResult(JSON.stringify({
      correlation_id: evt.data.correlation_id,
      stripe_url: evt.data.stripe_url,
      session_id: evt.data.session_id,
      event_id: evt.id,
    }, null, 2));
    setStatus('ok', 'ok');
  } catch (err) {
    setStatus('fail: ' + (err && err.message || String(err)), 'fail');
    console.error('smoke error:', err);
  }
})();
</script>
</body>
</html>'''


HANDLER_SRC = '''const STRIPE_URL = "http://localhost:9202/v1/checkout/sessions";

export default function () {
  if (request.method === "POST" && request.path === "/api/checkout/start") {
    const body = JSON.parse(request.body || "{}");
    if (!body.correlation_id) {
      response.status = 400;
      return { error: "correlation_id required" };
    }
    webhook.send({
      url: STRIPE_URL,
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ items: body.items, correlation_id: body.correlation_id }),
      onResult: "on_stripe_response",
      context: { correlation_id: body.correlation_id, sid: request.session.id },
    });
    response.status = 202;
    return { queued: true };
  }
  response.status = 404;
  return { error: "not found" };
}'''


CALLBACK_SRC = '''export default function () {
  const event = JSON.parse(request.body);
  const ctx = event.context || {};
  if (!event.ok) {
    events.emit({
      to: ctx.sid,
      type: "checkout.failed",
      data: {
        correlation_id: ctx.correlation_id,
        status: event.status,
        error: event.error || null,
      },
    });
    return;
  }
  const stripe = JSON.parse(event.body);
  const result = {
    correlation_id: ctx.correlation_id,
    stripe_url: stripe.url,
    session_id: stripe.id,
  };
  kv.set("checkouts/" + ctx.correlation_id, JSON.stringify(result));
  events.emit({
    to: ctx.sid,
    type: "checkout.created",
    data: result,
  });
}'''


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent

    python_exe = ensure_playwright()

    # Stripe echo server.
    stripe_log = Path(f"/tmp/notif-browser-smoke-stripe.out")
    if stripe_log.exists():
        stripe_log.unlink()
    stripe_proc = multiprocessing.Process(
        target=_stripe_server, args=(STRIPE_PORT, str(stripe_log)), daemon=True,
    )
    stripe_proc.start()
    # Wait for stripe up.
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        try:
            with socket.socket() as s:
                s.settimeout(0.5)
                s.connect(("127.0.0.1", STRIPE_PORT))
                break
        except OSError:
            pass
        time.sleep(0.1)

    # Per-run secrets BEFORE Cluster.spawn so workers inherit them.
    os.environ["SSE_INTERNAL_TOKEN"] = secrets.token_hex(24)
    os.environ["LOOP46_SSE_INSECURE_TLS"] = "1"

    sse_public_base = f"https://{SSE_HOST}:{SSE_PORT}"

    cluster = Cluster.spawn(
        tag="notif-browser-smoke",
        http_base=8270,
        raft_base=40370,
        files_port=8277,
        log_port=8276,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        worker_extra_args=["--dev-webhook-unsafe", "--sse-public-base", sse_public_base],
    )

    # Spawn sse-server with TLS (browser can't speak h2c).
    sse_log = Path("/tmp/notif-browser-smoke-sse.out")
    sse_proc = subprocess.Popen(
        [str(BIN_DIR / "sse-server-standalone"),
         "--listen", f"127.0.0.1:{SSE_PORT}",
         "--tls-cert", str(cluster.tls.cert),
         "--tls-key", str(cluster.tls.key)],
        stdout=open(sse_log, "wb"), stderr=subprocess.STDOUT,
    )
    cluster.sse_server = sse_proc
    _TRACKED_PROCS.append(sse_proc)

    try:
        with cluster as c:
            # Wait for sse-server health.
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                rc = subprocess.run(
                    ["curl", "-sk", "-f", "--http2",
                     f"https://127.0.0.1:{SSE_PORT}/v1/health"],
                    capture_output=True, timeout=2.0,
                )
                if rc.returncode == 0:
                    break
                time.sleep(0.1)

            c.discover_leader()
            print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

            admin_origin = c.admin_origin()
            c.spawn_files_server(cors_origin=admin_origin, leader_url=admin_origin)
            c.spawn_log_server(cors_origin=admin_origin)
            c.mint_services_token()

            cc = c.curl_ctx(f"{TENANT}.{PUBLIC_SUFFIX}")
            tenant_origin = f"https://{TENANT}.{PUBLIC_SUFFIX}:{c.leader_port()}"

            # Wait for admin tenant.
            leader_log = Path(f"/tmp/notif-browser-smoke-worker-{c.leader_idx}.out")
            deadline = time.monotonic() + 15.0
            while time.monotonic() < deadline:
                if leader_log.exists() and "tenant __admin__ loaded deployment" in leader_log.read_text(errors="replace"):
                    break
                time.sleep(0.1)

            # Signup.
            r = curl(
                cc, f"{admin_origin}/v1/signup",
                method="POST",
                headers={"Content-Type": "application/json"},
                data=json.dumps({"name": TENANT, "email": f"{TENANT}@example.com"}),
            )
            if '"ok":true' not in r.body:
                sys.exit(f"FAIL signup: {r.body}")
            mt = json.loads(r.body)["magic_link"].split("mt=")[-1]
            r = curl(cc, f"{admin_origin}/v1/auth?mt={mt}")
            if r.status != 302:
                sys.exit(f"FAIL redeem: {r.status}")
            print(f"ok  signed up tenant {TENANT}")

            # Wait for starter to land first.
            deadline = time.monotonic() + 15.0
            while time.monotonic() < deadline:
                if f"tenant {TENANT} loaded deployment" in leader_log.read_text(errors="replace"):
                    break
                time.sleep(0.1)

            # Deploy customer files via PUT.
            rove_js = (repo_root / "web" / "rove.js").read_text()
            dep_id = c.put_file(TENANT, "_static/rove.js", rove_js, content_type="application/javascript")
            c.release(TENANT, dep_id)
            print("ok  deployed _static/rove.js")

            dep_id = c.put_file(TENANT, "_static/index.html", TEST_HTML, content_type="text/html; charset=utf-8")
            c.release(TENANT, dep_id)
            print("ok  deployed _static/index.html")

            dep_id = c.put_file(TENANT, "index.mjs", HANDLER_SRC)
            c.release(TENANT, dep_id)
            print("ok  deployed customer handler (index.mjs)")

            dep_id = c.put_file(TENANT, "on_stripe_response.mjs", CALLBACK_SRC)
            c.release(TENANT, dep_id)
            print("ok  deployed callback handler (on_stripe_response.mjs)")

            # Wait for the final manifest to load (3 handlers + 2 statics).
            deadline = time.monotonic() + 10.0
            target = f"tenant {TENANT} loaded deployment {dep_id} (2 handler(s), 2 static(s)"
            while time.monotonic() < deadline:
                if target in leader_log.read_text(errors="replace"):
                    break
                time.sleep(0.1)

            # Write the runner script to a temp file.
            runner_path = Path("/tmp/notif-browser-runner.py")
            runner_path.write_text(RUNNER_SOURCE)

            target_url = f"{tenant_origin}/"
            print(f"running headless browser against {target_url}")
            rc = subprocess.run(
                [str(python_exe), str(runner_path),
                 "--url", target_url, "--timeout-ms", "30000"],
                timeout=60.0,
            )
            if rc.returncode != 0:
                sys.exit("FAIL browser smoke did not reach #status === 'ok'")
            print("ok  browser observed checkout.created with matching correlation_id")

            # Confirm recovery row in kv.
            list_args = urllib.parse.quote(json.dumps(["checkouts/", "", 5]))
            recovery = ""
            for _ in range(30):
                r = curl(
                    cc, f"{admin_origin}/?fn=listKv&args={list_args}",
                    headers={
                        "Authorization": f"Bearer {TOKEN}",
                        "X-Rove-Scope": TENANT,
                    },
                )
                if '"key":"checkouts/' in r.body:
                    recovery = r.body
                    break
                time.sleep(0.1)
            if '"key":"checkouts/' not in recovery:
                sys.exit(f"FAIL no checkouts/* recovery row: {recovery}")
            print("ok  callback persisted recovery row to kv (checkouts/<id>)")

            print()
            print("all browser-in-the-loop notifications smoke checks passed")
            return 0
    finally:
        stripe_proc.terminate()
        stripe_proc.join(timeout=2.0)
        if stripe_proc.is_alive():
            stripe_proc.kill()


if __name__ == "__main__":
    sys.exit(main())
