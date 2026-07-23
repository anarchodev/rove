#!/usr/bin/env python3
"""P-CLI (rove#122) end-to-end: the real `rewind` CLI resolves a bundle's
`@rewind/*` dependencies against a registry and stages the resolved package
graph through the deploy wire.

Unlike `pm_deploy_smoke.py` (which drives the deploy HTTP wire directly in
Python), this drives the actual `zig-out/bin/rewind` binary — exercising the
CLI's package resolver: read manifest.json `dependencies` → POST the
registry's `/v1/resolve` → fetch source blobs → topo-sort → stage
leaves-first (pkgfile with the growing resolution) → handlers + cut carry the
resolution → write rewind.lock.

The CLI runs HEADLESS via `REWIND_ROOT_TOKEN` (no interactive OIDC login), over
h2c to the single front port. A minimal "fake registry" tenant serves the two
open routes the CLI's resolver calls (`POST /v1/resolve`, `GET /v1/blobs/:h`)
with a canned one-package graph — the registry's own resolve logic is covered
by rewind-apps' offline tests; here we prove the CLI ↔ registry ↔ deploy path
against a real worker, then serve the consumer and assert the package ran.

Requires S3 env: `set -a; . ./.env; set +a` first, and the binaries built
(`zig build rewind-worker rewind-cp rewind-front rewind`).
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_lib_v2 import V2Cluster  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
REWIND_BIN = REPO_ROOT / "zig-out" / "bin" / "rewind"

# The one package the fake registry serves + the consumer imports.
PKG_HASH = "ab" * 32          # 64 lowercase hex — the engine's pkg_hash shape
SRC_HASH = "cafe" * 16        # 64 hex — arbitrary blob key (the deploy app
#                               recomputes the authoritative source hash)
GREET_SRC = 'export function greet(n){ return "hello " + n; }\n'

# The canned resolution the fake registry returns for {"@rewind/greet":"^1.0"}.
RESOLUTION = {
    "packages": [{
        "spec": "@rewind/greet", "version": "1.0.0", "pkg_hash": PKG_HASH,
        "files": [{"path": "index.mjs", "source_hash": SRC_HASH}],
        "imports": {}, "capabilities": [], "private": False,
    }],
    "app_imports": {"@rewind/greet": PKG_HASH},
}

# The fake registry: a normal handler tenant answering the CLI's two resolver
# routes. Returns the canned resolution + the package source blob.
FAKE_REGISTRY = (
    "const RESOLUTION = " + json.dumps(RESOLUTION) + ";\n"
    "const SRC_HASH = " + json.dumps(SRC_HASH) + ";\n"
    "const GREET_SRC = " + json.dumps(GREET_SRC) + ";\n"
    "export default function () {\n"
    "  const p = (request.path || '/').split('?')[0];\n"
    "  if (request.method === 'POST' && p === '/v1/resolve') {\n"
    "    response.headers = { 'content-type': 'application/json' };\n"
    "    return JSON.stringify(RESOLUTION);\n"
    "  }\n"
    "  if (request.method === 'GET' && p === '/v1/blobs/' + SRC_HASH) {\n"
    "    response.headers = { 'content-type': 'text/plain; charset=utf-8' };\n"
    "    return GREET_SRC;\n"
    "  }\n"
    "  response.status = 404;\n"
    "  return 'not found';\n"
    "}\n"
)

# The consumer: a handler that imports the @rewind/greet package. NOTE: the
# manifest deliberately does NOT declare the dependency — the CLI's auto-pin
# must add it from the `import` in the handler source (undeclared @rewind/* →
# auto-added; an undeclared third-party import would be a hard error instead).
CONSUMER_MANIFEST = json.dumps({"name": "consumer", "version": "1.0.0"})
CONSUMER_INDEX = (
    'import { greet } from "@rewind/greet";\n'
    "export default function () { return greet(\"world\"); }\n"
)


def main() -> int:
    if not REWIND_BIN.exists():
        print(f"{REWIND_BIN} missing — `zig build rewind`", file=sys.stderr)
        return 1

    with V2Cluster.spawn("pmcli", nodes=1) as c:
        fp = c.front_port

        # ── the fake registry tenant (also stands up __admin__) ──
        c.provision("registry")
        c.deploy_handlers("registry", {"index.mjs": FAKE_REGISTRY})
        r = c.wait_for_handler("registry", "/v1/blobs/" + SRC_HASH, want_body="greet")
        assert r.status == 200 and "greet" in r.body, f"registry not serving: {r.status} {r.body!r}"
        print("  ok   fake registry serves /v1/blobs")

        # An underscore-free alias for the deploy chokepoint (curl rejects the
        # `__admin__.localhost` host in a URL; `adm.localhost` maps to __admin__).
        hr = c._cp_post("/_control/host", {"host": "adm.localhost", "tenant": "__admin__"})
        assert hr.status in (200, 204), f"host alias adm.localhost: {hr.status} {hr.body!r}"

        # ── the consumer tenant ──
        c.provision("consumer")

        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "manifest.json").write_text(CONSUMER_MANIFEST)
            (Path(d) / "index.mjs").write_text(CONSUMER_INDEX)

            env = os.environ.copy()
            env.update({
                "REWIND_ADMIN_URL": f"http://adm.localhost:{fp}",
                "REWIND_REGISTRY_URL": f"http://registry.localhost:{fp}",
                "REWIND_ROOT_TOKEN": c.root_token,
                # required by the CLI config loader; unused in the headless path
                "REWIND_IDP_URL": "http://idp.invalid",
                "REWIND_RESOLVE": (
                    f"adm.localhost:{fp}:127.0.0.1,"
                    f"registry.localhost:{fp}:127.0.0.1"
                ),
            })
            # Stage via the CLI (no --release: the baked __admin__ deploy app
            # has no release route — the harness releases below).
            p = subprocess.run(
                [str(REWIND_BIN), "deploy", "consumer", d],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, timeout=180,
            )
            print("  --- rewind deploy output ---")
            for line in p.stdout.splitlines():
                print("  | " + line)
            assert p.returncode == 0, f"rewind deploy exited {p.returncode}"
            assert "auto-pinned @rewind/greet" in p.stdout, "CLI did not auto-pin the undeclared @rewind import"
            assert "resolved 1 package(s)" in p.stdout, "CLI did not report resolving the package"

            # The CLI writes the hash-locked lockfile alongside the bundle.
            lock = Path(d) / "rewind.lock"
            assert lock.exists(), "rewind.lock not written"
            lock_doc = json.loads(lock.read_text())
            assert lock_doc["app_imports"]["@rewind/greet"] == PKG_HASH, "lockfile app_imports wrong"
            print("  ok   CLI resolved + staged the package; wrote rewind.lock")

            m = re.search(r"deployment staged: ([0-9a-f]+)", p.stdout)
            assert m, f"no dep_id in CLI output:\n{p.stdout}"
            dep_id = int(m.group(1), 16)

        # ── release the CLI-staged deployment + serve ──
        rr = c.release("consumer", dep_id)
        assert rr.status == 204, f"release consumer: {rr.status} {rr.body!r}"
        r = c.wait_for_handler("consumer", "/", want_body="hello world")
        assert r.status == 200 and "hello world" in r.body, f"consumer serve: {r.status} {r.body!r}"
        print("  ok   consumer served the imported package → 'hello world'")

    print("\nPASS pm-cli smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
