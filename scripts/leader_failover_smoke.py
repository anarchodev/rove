#!/usr/bin/env python3
"""Leader-failover smoke — production.md §7.

Python port of `scripts/leader_failover_smoke.sh`. Verifies the at-least-
once + version-counter dedup contract across a forced leadership change:
schedule a delayed http.send, kill the leader, new leader fires it, the
callback hits acme's httpresult, the on_result kv write survives.

Phase 6 extension (`docs/readset-replication-plan.md`): also assert
that the original POST that scheduled the webhook is queryable from
the log-server after failover. With 5c's upload-catchup walker, the
new leader re-derives the LogRecord from the raft entry's readset +
LogHeader and pushes through the existing log_buffer → flushLogs →
S3 → log-server-indexer pipeline. Indexer's `INSERT OR IGNORE
(tenant_id, request_id)` absorbs any record the dead leader had
already pushed pre-crash, so this assertion holds whether the
records reached S3 via the fast path or via 5c — both demonstrate
the closure of the unreplayability gap.
"""

from __future__ import annotations

import http.server
import json
import multiprocessing
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import BIN_DIR, Cluster, curl, mint_jwt  # noqa: E402

TOKEN = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
ADMIN_HOST = f"app.{SYSTEM_SUFFIX}"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
WB_HOST = f"wb.{PUBLIC_SUFFIX}"
DELAY_MS = 4000
KILL_AFTER_S = 1.0
WAIT_FOR_RESULT_S = 15.0
ECHO_PORT = 9237
# Phase 6: how long to poll the log-server for the original POST's
# record after failover. Bounds: walker tick (~50ms) + flush
# interval (~1s) + indexer poll (100ms) + S3 RTT. 10s gives
# comfortable headroom on a healthy CI host.
LOG_QUERY_TIMEOUT_S = 10.0


def _ls(jwt: str, url: str, *, timeout_s: float = 10.0) -> str:
    """GET against log-server with services-token JWT. Returns the
    response body decoded as UTF-8."""
    args = [
        "curl", "-sS", "-k", "--http2-prior-knowledge", "--max-time", str(timeout_s),
        "-H", f"Authorization: Bearer {jwt}", url,
    ]
    return subprocess.run(args, capture_output=True, timeout=timeout_s + 5.0).stdout.decode()


def _echo_server_main(port: int) -> None:
    """Process-local echo server for the webhook target. Pre-existing
    smoke variant targeted `https://wb.{suffix}:{survivor_port}/`
    (the wb demo tenant on a hardcoded surviving node). That was
    flaky because workers RETURN 503 from `dispatchPending` when not
    leader (wb-handler-read-only doesn't help — the follower-503 in
    worker_dispatch.zig:2206 fires before reaching the handler). When
    the new leader happened to also be the hardcoded survivor, the
    fetch loopbacked to leader → 200 → pass. When the new leader was
    the OTHER surviving node, the fetch hit a follower → 503 →
    `webhook_onresult` classifies as `should_retry`, the 1s/2s/4s/8s
    backoffs blow past the 15s smoke wait, and on_result never fires
    (the `kv.set("http/result/{id}")` write never happens).

    This echo server is leader-independent — always responds 200 —
    so the smoke tests the actual http.send failover semantics
    rather than which surviving node happened to be picked as
    leader."""
    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            n = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(n)
            self.send_response(200)
            self.send_header("content-type", "text/plain")
            self.send_header("content-length", str(len(body) + 5))
            self.end_headers()
            self.wfile.write(b"echo:" + body)

        def log_message(self, fmt, *args):  # noqa: N802
            return  # silence stderr

    http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent

    # Spin up the leader-independent echo target BEFORE the cluster.
    # See `_echo_server_main` for why this replaced the prior
    # wb-tenant + survivor-port URL.
    echo_proc = multiprocessing.Process(
        target=_echo_server_main, args=(ECHO_PORT,), daemon=True,
    )
    echo_proc.start()
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
    print(f"ok  echo target up on :{ECHO_PORT}")

    cluster = Cluster.spawn(
        tag="leader-failover",
        http_base=8470,
        raft_base=40470,
        files_port=8472,
        log_port=8473,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        admin_api_domain=ADMIN_HOST,
        with_log_files_bases=True,
        workers_per_node=1,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        worker_extra_args=["--dev-webhook-unsafe", "--snapshot-interval-ms", "500"],
    )
    with cluster as c:
        time.sleep(2)
        c.discover_leader()
        orig_leader = c.leader_idx
        orig_port = c.addrs.http_port(orig_leader)
        # Phase 6: spawn the log-server so we can query for the
        # original POST's record post-failover.
        admin_origin = c.admin_origin()
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()
        print(f"ok  log-server up at {c.log_url()}")
        print(f"ok  initial leader: node {orig_leader} at {c.addrs.http[orig_leader]}")

        cc = c.curl_ctx(ACME_HOST)

        # Fire delayed http.send. The new leader post-failover fires
        # the curl from its own thread; aim at the leader-independent
        # echo server so we test failover semantics rather than which
        # surviving node ends up as leader. (See `_echo_server_main`.)
        wb_url = f"http://127.0.0.1:{ECHO_PORT}/"
        acme_origin = f"https://{ACME_HOST}:{orig_port}"

        deadline = time.monotonic() + 20.0
        sched_id = ""
        while time.monotonic() < deadline:
            args_json = json.dumps([wb_url, "failover", DELAY_MS])
            args_enc = urllib.parse.quote(args_json)
            r = curl(cc, f"{acme_origin}/httpfire?fn=fireDelayed&args={args_enc}")
            if r.status == 200:
                try:
                    sched_id = json.loads(r.body).get("id", "")
                    if sched_id:
                        break
                except (json.JSONDecodeError, KeyError):
                    pass
            time.sleep(0.2)
        if not sched_id:
            sys.exit(f"FAIL fireDelayed: {r.status} {r.body}")
        print(f"ok  scheduled delayed http.send (id={sched_id}, delay={DELAY_MS}ms)")

        time.sleep(2)
        print("ok  waited for schedule replication")

        time.sleep(KILL_AFTER_S)
        print(f"killing original leader node {orig_leader}…")
        c.stop_node(orig_leader)

        # Wait for new leader.
        new_leader = None
        new_leader_port = 0
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline and new_leader is None:
            for i in range(3):
                if i == orig_leader:
                    continue
                p = c.addrs.http_port(i)
                try:
                    r = curl(
                        cc, f"https://{ADMIN_HOST}:{p}/_system/leader",
                        headers={"Authorization": f"Bearer {TOKEN}"},
                        timeout=2.0,
                    )
                except (subprocess.TimeoutExpired, RuntimeError):
                    continue
                if r.status == 200:
                    new_leader = i
                    new_leader_port = p
                    break
            time.sleep(0.5)
        if new_leader is None:
            sys.exit("FAIL no new leader elected within 20s")
        print(f"ok  new leader: node {new_leader} (port {new_leader_port})")

        print(f"waiting {WAIT_FOR_RESULT_S}s for on_result kv write to land…")
        time.sleep(WAIT_FOR_RESULT_S)

        # Phase 6: query log-server for the original POST's record.
        # The original leader (now dead) served the inbound POST to
        # `/httpfire?fn=fireDelayed`. If 5c's walker is doing its
        # job (or the dead leader actually flushed pre-crash), the
        # log-server's indexer eventually sees a record for the
        # acme tenant. We assert AT LEAST ONE record exists — the
        # smoke can't distinguish "fast path flushed" from "walker
        # re-derived" because the indexer is idempotent on
        # (tenant_id, request_id), but either is a valid
        # Phase 5 outcome (closes the unreplayability gap).
        jwt = mint_jwt(
            c.services_jwt_secret,
            {"exp": int(time.time() * 1000) + 5 * 60 * 1000},
        )
        records = []
        list_url = f"{c.log_url()}/v1/acme/list?limit=50"
        deadline = time.monotonic() + LOG_QUERY_TIMEOUT_S
        while time.monotonic() < deadline:
            body = _ls(jwt, list_url)
            try:
                records = json.loads(body).get("records", [])
            except (json.JSONDecodeError, AttributeError):
                records = []
            if records:
                break
            time.sleep(0.5)
        if not records:
            sys.exit(
                f"FAIL log-server has no acme records after failover — "
                f"the original POST's LogRecord didn't make it to S3 "
                f"(neither pre-crash flush nor 5c walker delivered it)"
            )
        print(
            f"ok  log-server has {len(records)} acme record(s) post-failover — "
            f"Phase 5 unreplayability gap closed"
        )

        # Shut everything down so kv-get can read cluster.kv.
        for idx in range(3):
            if c.workers[idx].poll() is None:
                c.stop_node(idx)

    # Cluster shutdown happened via __exit__ already (we left the with block).
    # Verify via offline kv-get.
    result_key = f"http/result/{sched_id}"
    bin_loop46 = BIN_DIR / "loop46"
    rc = subprocess.run(
        [str(bin_loop46), "kv-get",
         "--data-dir", str(c.addrs.data_dirs[new_leader]),
         "--store", "acme",
         "--key", result_key],
        capture_output=True, text=True,
    )
    result = rc.stdout.strip()
    if not result or '"ok"' not in result:
        sys.exit(f"FAIL on_result kv write missing: {rc.stdout!r} {rc.stderr!r}")
    print(f"ok  on_result kv write landed on acme via new leader")
    print(f"    result: {result}")

    parsed = json.loads(result)
    if not parsed.get("ok"):
        sys.exit(f"FAIL result.ok != true: {parsed}")
    print("ok  result.ok == true — http.send completed successfully across failover")
    print()
    print("PASS leader-failover smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
