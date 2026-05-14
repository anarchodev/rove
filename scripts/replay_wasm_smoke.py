#!/usr/bin/env python3
"""End-to-end smoke for the WASM replay path (replay-wasm-plan §8.1).

Spawns a 3-node cluster + files-server + log-server with the demo
seed manifest. Hits the acme tenant a few times so its kv handler
produces a captured log record with tape entries. Composes a replay
bundle JSON the same way `web/admin/api.js::composeReplay` would
(deployment manifest from files-server + source files by content
hash + base64 tape blobs from the log record). Hands the bundle to
`scripts/replay_wasm_smoke.mjs` which boots arenajs-WASM via Node,
runs the captured handler under SCAN-mode tracing, and prints a
JSON summary. The Python side asserts the summary looks plausible
(rc=0, non-zero events, non-zero output).

The WASM browser UI is not exercised here — this smoke validates
the wire format + WASM driver chain end-to-end against bytes from
a real capture, which is the concrete §8.1 milestone.
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, CurlContext, curl, mint_jwt  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
PUBLIC_SUFFIX = "loop46.localhost"
TENANT_ID = "replay_demo"
TENANT_HOST = f"replay-demo.{PUBLIC_SUFFIX}"
TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"


def _ls(jwt: str, url: str, *, timeout_s: float = 10.0) -> str:
    """Plain curl against log-server's HTTP/1 (or h2c) port."""
    args = [
        "curl", "-sS", "--http2-prior-knowledge", "--max-time", str(timeout_s),
        "-H", f"Authorization: Bearer {jwt}", url,
    ]
    return subprocess.run(args, capture_output=True, timeout=timeout_s + 5.0).stdout.decode()


def main() -> int:
    cluster = Cluster.spawn(
        tag="replay-wasm-smoke",
        http_base=8260,
        raft_base=40360,
        files_port=8264,
        log_port=8263,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        seed_manifest=REPO_ROOT / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        admin_origin = c.admin_origin()
        c.spawn_files_server(cors_origin=admin_origin, leader_url=admin_origin)
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()
        print(f"ok  cluster up: leader={c.addrs.http[c.leader_idx]} log={c.log_url()} files={c.files_url()}")

        cc = c.curl_ctx(TENANT_HOST)
        leader_origin = f"https://{TENANT_HOST}:{c.leader_port()}"

        # Drive a few requests through the demo handler. It exercises
        # every captured tape channel: kv.get + kv.set (kv), Date.now
        # (date), Math.random (math_random), crypto.getRandomValues
        # (crypto_random), and one local import (module).
        c.wait_for_handler(TENANT_ID, "/?fn=handler", expected_status=200, timeout_s=15.0)
        last_body = ""
        for _ in range(3):
            r = curl(cc, f"{leader_origin}/?fn=handler")
            if r.status != 200:
                sys.exit(f"FAIL {TENANT_ID} GET /?fn=handler: {r.status} {r.body[:200]}")
            last_body = r.body
        print(f"ok  drove 3 {TENANT_ID} requests — last response: {last_body.strip()!r}")

        # Mint a services JWT for log-server + files-server (both
        # accept the same secret per smoke_lib's setup).
        jwt = mint_jwt(c.services_jwt_secret, {"exp": int(time.time() * 1000) + 5 * 60 * 1000})

        # Poll log-server for the records.
        recs = []
        for _ in range(60):
            body = _ls(jwt, f"{c.log_url()}/v1/{TENANT_ID}/list?limit=20")
            try:
                d = json.loads(body)
            except json.JSONDecodeError:
                d = {}
            recs = [r for r in d.get("records", []) if r.get("status") == 200]
            if len(recs) >= 1:
                break
            time.sleep(0.5)
        if not recs:
            sys.exit(f"FAIL no {TENANT_ID} records surfaced in log-server")
        rec_summary = recs[0]
        rid = rec_summary["request_id"]
        print(f"ok  log-server surfaced {TENANT_ID} record {rid}")

        # Fetch the full record (carries the base64 tape fields).
        show_body = _ls(jwt, f"{c.log_url()}/v1/{TENANT_ID}/show/{rid}")
        rec = json.loads(show_body)["record"]
        tapes_field = rec.get("tapes", {})
        present = [
            ch for ch in ("kv_tape_b64", "date_tape_b64", "math_random_tape_b64",
                          "crypto_random_tape_b64", "module_tree_b64")
            if tapes_field.get(ch)
        ]
        if "kv_tape_b64" not in present:
            sys.exit(f"FAIL kv_tape_b64 missing from record: tapes keys={list(tapes_field.keys())}")
        print(f"ok  fetched full log record — tape channels present: {present}")

        # Fetch the historical deployment manifest by hex id.
        dep_id = rec["deployment_id"]
        dep_hex = f"{dep_id:016x}"
        mf_body = _ls(jwt, f"{c.files_url()}/{TENANT_ID}/deployments/{dep_hex}")
        manifest = json.loads(mf_body)
        entries = manifest.get("entries", [])
        handler_entries = [e for e in entries if e.get("kind") == "handler"]
        if not handler_entries:
            sys.exit(f"FAIL no handler entries in deployment {dep_hex}: {entries}")
        print(f"ok  manifest dep_id={dep_hex} has {len(handler_entries)} handler entry(ies)")

        # Fetch source for every handler entry (mirrors composeReplay
        # so multi-file imports resolve at replay time).
        modules = []
        for e in handler_entries:
            src_url = f"{c.files_url()}/{TENANT_ID}/source/{e['hash']}"
            args = [
                "curl", "-sS", "--http2-prior-knowledge", "--max-time", "10",
                "-H", f"Authorization: Bearer {jwt}", src_url,
            ]
            r = subprocess.run(args, capture_output=True, timeout=15.0)
            if r.returncode != 0:
                sys.exit(f"FAIL source fetch {e['path']}: rc={r.returncode}")
            modules.append({
                "path": e["path"],
                "hash": e["hash"],
                "source": r.stdout.decode(errors="replace"),
            })

        # Pick the entry handler (index.mjs / index.js, else the first).
        entry_path = None
        for e in handler_entries:
            if e["path"] in ("index.mjs", "index.js"):
                entry_path = e["path"]
                break
        if not entry_path:
            entry_path = handler_entries[0]["path"]
        entry_source = next((m["source"] for m in modules if m["path"] == entry_path), None)
        if not entry_source:
            sys.exit(f"FAIL no source for entry {entry_path}")

        # Compose the bundle. tape_blobs as base64 strings (the .mjs
        # driver decodes back to Uint8Array). Channel name mapping
        # matches buildTapesFromBlobs.
        def get_b64(key: str) -> str | None:
            return tapes_field.get(key) or None

        # Reconstruct the request object the handler reads. The
        # driver stamps globalThis.request before calling handler()
        # so handlers that read request.path / request.body don't
        # diverge from the captured execution.
        req_body = ""
        if tapes_field.get("request_body_b64"):
            try:
                req_body = base64.b64decode(tapes_field["request_body_b64"]).decode("utf-8", errors="replace")
            except Exception:
                req_body = ""
        bundle = {
            "request_id": rid,
            "deployment_id": dep_id,
            "entry_path": entry_path,
            "entry_source": entry_source,
            "entry_fn": "handler",
            "request": {
                "method": rec.get("method", "GET"),
                "path": rec.get("path", "/"),
                "host": rec.get("host", ""),
                "body": req_body,
            },
            "modules": modules,
            "tape_blobs": {
                "kv": get_b64("kv_tape_b64"),
                "date": get_b64("date_tape_b64"),
                "math_random": get_b64("math_random_tape_b64"),
                "crypto_random": get_b64("crypto_random_tape_b64"),
                # `module_tree_b64` is the wire-format tape for the
                # module channel; the WASM module loader treats it
                # the same as any other channel even though replay
                # resolves imports out of Module.module_sources.
                "module": get_b64("module_tree_b64"),
            },
        }
        bundle_path = Path("/tmp/replay-wasm-smoke-bundle.json")
        bundle_path.write_text(json.dumps(bundle))
        print(f"ok  composed bundle ({bundle_path.stat().st_size} bytes, "
              f"{sum(1 for v in bundle['tape_blobs'].values() if v)} tape channel(s))")

        # Hand off to the Node-runnable WASM driver.
        node_args = ["node", str(REPO_ROOT / "scripts" / "replay_wasm_smoke.mjs"), str(bundle_path)]
        proc = subprocess.run(node_args, capture_output=True, timeout=60, cwd=REPO_ROOT)
        if proc.returncode != 0:
            sys.stderr.write(proc.stderr.decode(errors="replace"))
            sys.exit(f"FAIL WASM driver exited {proc.returncode}")
        try:
            summary = json.loads(proc.stdout.decode())
        except json.JSONDecodeError:
            sys.stderr.write(proc.stdout.decode(errors="replace"))
            sys.exit("FAIL WASM driver stdout was not JSON")

        if not summary.get("ok"):
            sys.exit(f"FAIL WASM rc={summary['rc']} summary={summary}")
        # Module body enter + handler() + at least one of rollDie /
        # bumpCount / fmtSalt called inside handler ⇒ 3+ FUNC_ENTERs.
        # Tighter than the earlier acme-based 1-enter floor; catches
        # a regression where the trace emitter drops nested-call
        # events.
        if summary["func_enter_count"] < 3:
            sys.exit(f"FAIL want >=3 FUNC_ENTER events (module body + handler + inner call): {summary}")
        if summary["name_count"] < 2:
            sys.exit(f"FAIL want >=2 NAME entries (function + file atoms): {summary}")
        # We exercised 4 channels in the original capture (kv, date,
        # math_random, crypto_random). Assert they all reached the
        # log record so the bundle composer has something to feed
        # into the WASM replay's tape readers.
        expected_channels = {"kv_tape_b64", "date_tape_b64", "math_random_tape_b64", "crypto_random_tape_b64"}
        missing = expected_channels - set(present)
        if missing:
            sys.exit(f"FAIL captured record missing channels: {missing}. Present: {present}")
        # The handler returns a non-empty string — output_lines tracks
        # printf/stderr lines, NOT the handler return value, so it's
        # expected to be 0 here. Still a useful smoke for when a
        # future handler logs something.
        print(f"ok  WASM replay ran handler {entry_path}: "
              f"rc={summary['rc']} events={summary['event_count']} "
              f"enters={summary['func_enter_count']} names={summary['name_count']} "
              f"output_lines={summary['output_lines']}")
        if summary["output_sample"]:
            print(f"    sample output: {summary['output_sample'][0]!r}")

        print()
        print("all replay-wasm smoke checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
