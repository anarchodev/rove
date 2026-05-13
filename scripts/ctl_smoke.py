#!/usr/bin/env python3
"""End-to-end smoke for the deploy flow against a 3-node loop46 cluster.

Python port of `scripts/ctl_smoke.sh` — same assertions, but cleanup
via `Cluster.shutdown` / `atexit` instead of pkill -f. Run from repo
root after `zig build install`.
"""

from __future__ import annotations

import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import (  # noqa: E402
    Cluster,
    curl,
    expect_eq,
    expect_status,
    mint_jwt,
)


def main() -> int:
    cluster = Cluster.spawn(
        tag="ctl-smoke",
        http_base=8197,
        raft_base=40297,
        files_port=8225,
        log_port=8224,
        seed_manifest={"tenants": [{"id": "acme", "domains": [], "files": []}]},
    )
    with cluster as c:
        c.discover_leader()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        admin_origin = c.admin_origin()
        c.spawn_files_server(cors_origin=admin_origin)
        c.spawn_log_server(cors_origin=admin_origin)

        c.mint_services_token()
        print(f"ok  minted services JWT (log={c.log_base}, files={c.files_base})")

        # Build a small source tree with two routes.
        src_dir = Path(tempfile.mkdtemp(prefix="rove-ctl-smoke-src-"))
        (src_dir / "api").mkdir()
        (src_dir / "index.mjs").write_text('export function handler() { return "ctl-root\\n"; }\n')
        (src_dir / "api" / "index.mjs").write_text('export function handler() { return "ctl-api\\n"; }\n')

        cc = c.curl_ctx(f"acme.{c.addrs.public_suffix}")
        files_loop = f"https://files.{c.addrs.public_suffix}:{c.addrs.files_port}"

        def upload(rel: str) -> None:
            r = curl(
                cc,
                f"{files_loop}/acme/upload",
                method="POST",
                headers={
                    "Authorization": f"Bearer {c.services_jwt}",
                    "X-Rove-Path": rel,
                },
                data=(src_dir / rel).read_bytes(),
            )
            expect_status(f"uploaded {rel}", 204, r)

        upload("index.mjs")
        upload("api/index.mjs")

        r = curl(
            cc,
            f"{files_loop}/acme/deploy",
            method="POST",
            headers={"Authorization": f"Bearer {c.services_jwt}"},
        )
        if r.status != 200:
            sys.exit(f"FAIL deploy: status {r.status} body={r.body}")
        dep_id = r.body.strip()
        if not dep_id:
            sys.exit("FAIL deploy: empty response")
        print(f"deployed 2 file(s) → id={dep_id}")

        # Push the release through the worker. envelope 0 →
        # `_deploy/current`; followers pick it up via raft.
        r = curl(
            cc,
            f"{admin_origin}/_system/release",
            method="POST",
            headers={
                "Authorization": f"Bearer {c.root_token}",
                "Content-Type": "application/json",
            },
            data=f'{{"tenant_id":"acme","dep_id":{dep_id}}}',
        )
        expect_status("release", 204, r)
        print(f"released dep_id={dep_id}")

        # Wait briefly for the worker's deployment loader to pick up the
        # release (S3 fetch + manifest decode + snapshot swap). Phase 2's
        # snapshot reload is async on the loader thread.
        deadline = time.monotonic() + 5.0
        last_status = 0
        last_body = ""
        while time.monotonic() < deadline:
            r = curl(
                cc, f"https://acme.{c.addrs.public_suffix}:{c.leader_port()}/?fn=handler"
            )
            last_status, last_body = r.status, r.body
            if r.status == 200 and r.body.strip() == "ctl-root":
                break
            time.sleep(0.1)
        expect_eq(
            "GET /?fn=handler (ctl-deployed root handler)", "ctl-root\n", last_body
        )

        r = curl(
            cc, f"https://acme.{c.addrs.public_suffix}:{c.leader_port()}/api?fn=handler"
        )
        expect_eq("GET /api?fn=handler (ctl-deployed sub-route)", "ctl-api\n", r.body)

        # Followers should reject with 503 not-leader.
        for i in range(3):
            if i == c.leader_idx:
                continue
            port = c.addrs.http_port(i)
            r = curl(cc, f"https://acme.{c.addrs.public_suffix}:{port}/?fn=handler")
            if r.status != 503:
                sys.exit(f"FAIL: follower {i} should 503, got {r.status}")
        print("ok  followers reject with 503 not-leader")

        # Wrong JWT secret → 401 from the files-server.
        wrong_secret = "00" * 16
        # Note: mint_jwt requires hex; using a deliberately-wrong key.
        wrong_jwt = mint_jwt(wrong_secret, {"exp": int(time.time() * 1000) + 5 * 60 * 1000})
        r = curl(
            cc,
            f"{files_loop}/acme/upload",
            method="POST",
            headers={
                "Authorization": f"Bearer {wrong_jwt}",
                "X-Rove-Path": "index.mjs",
            },
            data=(src_dir / "index.mjs").read_bytes(),
        )
        expect_status("deploy with wrong JWT: rejected", 401, r)

        print("PASS ctl smoke (3-node)")
        return 0


if __name__ == "__main__":
    sys.exit(main())
