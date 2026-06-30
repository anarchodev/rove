#!/usr/bin/env python3
"""End-to-end smoke for files-server-standalone (single process, no raft).

Python port of `scripts/files_server_smoke.sh`. Exercises upload / deploy /
blob-check / two-phase deploy / CAS / mismatched-hash error paths.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import (  # noqa: E402
    BIN_DIR, _TRACKED_PROCS, _install_signal_handlers, _load_dotenv,
    CurlContext, curl, gen_jwt_secret, mint_jwt,
)


def expect(label: str, expected, actual) -> None:
    if actual != expected:
        sys.exit(f"FAIL {label}: expected {expected}, got {actual}")
    print(f"ok  {label}: {actual}")


def main() -> int:
    _load_dotenv()
    _install_signal_handlers()

    data_dir = Path("/tmp/rove-cs-smoke")
    shutil.rmtree(data_dir, ignore_errors=True)

    os.environ.setdefault(
        "S3_KEY_PREFIX_BASE",
        f"smoke-files-server-{os.environ.get('HOSTNAME', 'host')}-{os.getuid()}-{int(time.time())}/",
    )
    jwt_secret = gen_jwt_secret()
    os.environ["LOOP46_SERVICES_JWT_SECRET"] = jwt_secret

    bin_path = BIN_DIR / "files-server-standalone"
    log_path = Path("/tmp/cs-smoke.out")
    log_path.write_text("")
    f = open(log_path, "wb")
    proc = subprocess.Popen(
        [str(bin_path), "--data-dir", str(data_dir), "--listen", "127.0.0.1:0"],
        stdout=f, stderr=subprocess.STDOUT,
    )
    _TRACKED_PROCS.append(proc)

    try:
        port = 0
        for _ in range(30):
            content = log_path.read_text(errors="replace")
            if "listening on" in content:
                m = re.search(r"port (\d+)", content)
                if m:
                    port = int(m.group(1))
                    break
            time.sleep(0.1)
        if not port:
            sys.exit(f"FAIL files-server didn't bind: {log_path.read_text(errors='replace')}")
        print(f"files-server listening on port {port}")

        jwt = mint_jwt(jwt_secret, {"exp": int(time.time() * 1000) + 5 * 60 * 1000})
        auth = {"Authorization": f"Bearer {jwt}"}
        cc = CurlContext(cacert=Path("/dev/null"))  # h2c, no TLS

        def h2c(url: str, **kwargs) -> any:
            """curl helper for h2c (no TLS)."""
            args = ["curl", "-s", "--http2-prior-knowledge", "-D", "-", "-o", "-"]
            method = kwargs.pop("method", "GET")
            args += ["-X", method]
            for k, v in (kwargs.pop("headers", None) or {}).items():
                args += ["-H", f"{k}: {v}"]
            data = kwargs.pop("data", None)
            if data is not None:
                if isinstance(data, str):
                    data = data.encode()
                args += ["--data-binary", "@-"]
            args.append(url)
            r = subprocess.run(args, input=data or b"", capture_output=True, timeout=10.0)
            raw = r.stdout
            split = raw.rfind(b"\r\n\r\n")
            if split < 0:
                return type("R", (), {"status": 0, "body": raw.decode(errors="replace"), "headers": {}})()
            header_block = raw[:split].decode(errors="replace")
            body = raw[split + 4:].decode(errors="replace")
            lines = header_block.splitlines()
            status_line = next((l for l in reversed(lines) if l.startswith("HTTP/")), "")
            status = int(status_line.split(" ", 2)[1]) if status_line else 0
            return type("R", (), {"status": status, "body": body, "headers": {}})()

        source = 'export function handler() { return "hi from smoke"; }'

        # Upload index.mjs.
        r = h2c(f"http://127.0.0.1:{port}/acme/upload", method="POST",
                headers={**auth, "X-Rove-Path": "index.mjs"}, data=source)
        expect("upload /acme index.mjs", 204, r.status)

        # Missing header → 400.
        r = h2c(f"http://127.0.0.1:{port}/acme/upload", method="POST",
                headers=auth, data="x")
        expect("upload without header", 400, r.status)

        # Deploy. dep_id is content-addressed (truncated sha-256), so
        # we don't know the exact value upfront — just that it's a
        # non-zero decimal integer.
        r = h2c(f"http://127.0.0.1:{port}/acme/deploy", method="POST", headers=auth)
        body = r.body.strip()
        try:
            dep_int = int(body, 10)
        except ValueError:
            sys.exit(f"FAIL deploy non-numeric id: {body!r}")
        if dep_int == 0:
            sys.exit(f"FAIL deploy returned zero id")
        print(f"ok  deploy /acme: id={body}")

        src_hash = hashlib.sha256(source.encode()).hexdigest()
        r = h2c(f"http://127.0.0.1:{port}/acme/source/{src_hash}", headers=auth)
        expect("GET /source valid hash", 200, r.status)
        if "hi from smoke" not in r.body:
            sys.exit(f"FAIL source bytes: {r.body}")
        print("ok  source bytes match")

        r = h2c(f"http://127.0.0.1:{port}/acme/source/" + "0" * 32, headers=auth)
        expect("GET /source bogus hash", 404, r.status)

        r = h2c(f"http://127.0.0.1:{port}/unknown", headers=auth)
        expect("GET /unknown", 404, r.status)

        # ── Content-addressed two-phase flow ─────────────────────────
        blob_bytes = "hello blob storage"
        blob_hash = hashlib.sha256(blob_bytes.encode()).hexdigest()
        r = h2c(f"http://127.0.0.1:{port}/acme/blobs/check", method="POST",
                headers={**auth, "Content-Type": "application/json"},
                data=json.dumps({"hashes": [blob_hash]}))
        if f'"missing":["{blob_hash}"]' not in r.body:
            sys.exit(f"FAIL blobs/check missing: {r.body}")
        if f'"url":"/v1/instances/acme/blobs/{blob_hash}"' not in r.body:
            sys.exit(f"FAIL blobs/check url: {r.body}")
        print("ok  /blobs/check reports missing hash with upload url")

        r = h2c(f"http://127.0.0.1:{port}/acme/blobs/{blob_hash}", method="PUT",
                headers=auth, data=blob_bytes)
        expect("PUT /blobs/{hash} correct bytes", 204, r.status)

        r = h2c(f"http://127.0.0.1:{port}/acme/blobs/check", method="POST",
                headers={**auth, "Content-Type": "application/json"},
                data=json.dumps({"hashes": [blob_hash]}))
        if '"missing":[]' not in r.body:
            sys.exit(f"FAIL blobs/check after upload: {r.body}")
        print("ok  /blobs/check reports present hash after upload")

        bad_hash = hashlib.sha256(b"xxx").hexdigest()
        r = h2c(f"http://127.0.0.1:{port}/acme/blobs/{bad_hash}", method="PUT",
                headers=auth, data=blob_bytes)
        expect("PUT /blobs/{hash} hash mismatch", 400, r.status)

        r = h2c(f"http://127.0.0.1:{port}/acme/blobs/notahash", method="PUT",
                headers=auth, data=blob_bytes)
        expect("PUT /blobs/{hash} malformed hash", 400, r.status)

        # ── Two-phase deploy ─────────────────────────────────────────
        static_bytes = "<!doctype html><title>two-phase</title>"
        static_hash = hashlib.sha256(static_bytes.encode()).hexdigest()
        handler_bytes = 'export function handler() { return "two-phase!"; }'
        handler_hash = hashlib.sha256(handler_bytes.encode()).hexdigest()

        r = h2c(f"http://127.0.0.1:{port}/twophase/blobs/check", method="POST",
                headers={**auth, "Content-Type": "application/json"},
                data=json.dumps({"hashes": [static_hash, handler_hash]}))
        if static_hash not in r.body or handler_hash not in r.body:
            sys.exit(f"FAIL two hashes missing: {r.body}")
        print("ok  /blobs/check on two new hashes → both missing")

        r = h2c(f"http://127.0.0.1:{port}/twophase/blobs/{static_hash}",
                method="PUT", headers=auth, data=static_bytes)
        expect("PUT static blob", 204, r.status)
        r = h2c(f"http://127.0.0.1:{port}/twophase/blobs/{handler_hash}",
                method="PUT", headers=auth, data=handler_bytes)
        expect("PUT handler blob", 204, r.status)

        # First deploy: no parent_id.
        manifest = {
            "files": {
                "_static/index.html": {"hash": static_hash, "kind": "static", "content_type": "text/html"},
                "index.mjs": {"hash": handler_hash, "kind": "handler"},
            }
        }
        r = h2c(f"http://127.0.0.1:{port}/twophase/deployments", method="POST",
                headers={**auth, "Content-Type": "application/json"},
                data=json.dumps(manifest))
        if '"id":"' not in r.body:
            sys.exit(f"FAIL /deployments missing id: {r.body}")
        # dep_id is now content-addressed (truncated sha-256); parse
        # it from the response for the parent_id CAS below.
        m = re.search(r'"id":"([0-9a-f]{16})"', r.body)
        if not m:
            sys.exit(f"FAIL couldn't parse dep_id from {r.body}")
        first_dep_id = m.group(1)
        print(f"ok  POST /deployments commits manifest: id={first_dep_id}")

        r = h2c(f"http://127.0.0.1:{port}/twophase/list", headers=auth)
        if "_static/index.html" not in r.body or "index.mjs" not in r.body:
            sys.exit(f"FAIL /list missing entries: {r.body}")
        print("ok  /list shows both files after deploy")

        # Stale parent → 409.
        r = h2c(f"http://127.0.0.1:{port}/twophase/deployments", method="POST",
                headers={**auth, "Content-Type": "application/json"},
                data=json.dumps({
                    "parent_id": "0000000000000000",
                    "files": {"index.mjs": {"hash": handler_hash, "kind": "handler"}},
                }))
        expect("POST /deployments stale parent_id", 409, r.status)

        # Correct parent → 201, new id (content changed).
        r = h2c(f"http://127.0.0.1:{port}/twophase/deployments", method="POST",
                headers={**auth, "Content-Type": "application/json"},
                data=json.dumps({
                    "parent_id": first_dep_id,
                    "files": {"index.mjs": {"hash": handler_hash, "kind": "handler"}},
                }))
        m = re.search(r'"id":"([0-9a-f]{16})"', r.body)
        if not m:
            sys.exit(f"FAIL second deploy missing id: {r.body}")
        second_dep_id = m.group(1)
        if second_dep_id == first_dep_id:
            sys.exit(f"FAIL second deploy reused first dep_id {first_dep_id}")
        print(f"ok  POST /deployments with matching parent_id → id={second_dep_id}")

        # Missing blob → 400.
        never_hash = hashlib.sha256(b"never uploaded").hexdigest()
        r = h2c(f"http://127.0.0.1:{port}/twophase/deployments", method="POST",
                headers={**auth, "Content-Type": "application/json"},
                data=json.dumps({
                    "files": {"ghost.mjs": {"hash": never_hash, "kind": "handler"}},
                }))
        expect("POST /deployments missing blob", 400, r.status)

        # ── App-manifest seam (docs/handler-shape.md §8) ─────────────
        # A bundle-root manifest.json is a static file; deploy validates
        # it structurally (author feedback) but nothing consumes it yet.
        good_manifest = json.dumps({
            "name": "link-shortener",
            "version": "1.0.0",
            "effects": {"declared": ["kv"]},
        })
        good_hash = hashlib.sha256(good_manifest.encode()).hexdigest()
        r = h2c(f"http://127.0.0.1:{port}/twophase/blobs/{good_hash}",
                method="PUT", headers=auth, data=good_manifest)
        expect("PUT valid manifest.json blob", 204, r.status)
        r = h2c(f"http://127.0.0.1:{port}/twophase/deployments", method="POST",
                headers={**auth, "Content-Type": "application/json"},
                data=json.dumps({"files": {
                    "index.mjs": {"hash": handler_hash, "kind": "handler"},
                    "manifest.json": {"hash": good_hash, "kind": "static",
                                      "content_type": "application/json"},
                }}))
        if '"id":"' not in r.body:
            sys.exit(f"FAIL valid manifest deploy rejected: {r.status} {r.body}")
        print("ok  deploy with valid manifest.json accepted")

        # Invalid manifest.json (missing required `version`) → 400.
        bad_manifest = json.dumps({"name": "oops"})
        bad_hash = hashlib.sha256(bad_manifest.encode()).hexdigest()
        r = h2c(f"http://127.0.0.1:{port}/twophase/blobs/{bad_hash}",
                method="PUT", headers=auth, data=bad_manifest)
        expect("PUT invalid manifest.json blob", 204, r.status)
        r = h2c(f"http://127.0.0.1:{port}/twophase/deployments", method="POST",
                headers={**auth, "Content-Type": "application/json"},
                data=json.dumps({"files": {
                    "index.mjs": {"hash": handler_hash, "kind": "handler"},
                    "manifest.json": {"hash": bad_hash, "kind": "static",
                                      "content_type": "application/json"},
                }}))
        expect("deploy with invalid manifest.json", 400, r.status)
        if "InvalidAppManifest" not in r.body:
            sys.exit(f"FAIL expected InvalidAppManifest in body: {r.body}")
        print("ok  invalid manifest.json rejected as InvalidAppManifest")

        print("PASS files-server smoke")
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
