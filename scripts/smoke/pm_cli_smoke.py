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
— the registry's own resolve logic is covered by rewind-apps' offline tests;
here we prove the CLI ↔ registry ↔ deploy path against a real worker, then
serve the consumer and assert the package ran.

It also proves the LOCKFILE actually pins (rove#630). The fake registry
publishes `@rewind/greet` at two versions and honours `overrides`, so the
smoke can watch a deploy resolve to the newest version, pin it back to the
older one in `rewind.lock`, and see the next deploy SERVE the older package —
the byte-level evidence that the lock is an input and not a souvenir. `--update`
moves the pin again and `--frozen` refuses a lock that has fallen behind
manifest.json.

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

# `@rewind/greet` at TWO versions. Two is the minimum that can tell a pin from
# a coincidence: with one version on the shelf, a "pinned" resolve and an
# unpinned one return the same thing and the test proves nothing.
#
# The two differ in their SOURCE, not just their metadata, so the assertion at
# the end is what the handler actually served rather than what the lockfile
# claimed.
VERSIONS = {
    "1.0.0": {"pkg_hash": "ab" * 32, "src_hash": "cafe" * 16,
              "src": 'export function greet(n){ return "hello " + n; }\n',
              "greeting": "hello world"},
    "2.0.0": {"pkg_hash": "cd" * 32, "src_hash": "beef" * 16,
              "src": 'export function greet(n){ return "HELLO " + n.toUpperCase(); }\n',
              "greeting": "HELLO WORLD"},
}
NEWEST = "2.0.0"
OLDEST = "1.0.0"

# The fake registry: a normal handler tenant answering the CLI's two resolver
# routes. Honours `overrides` exactly as rewind-apps' `resolveGraph` does —
# an exact-version pin wins over the range, and an unknown pin is unresolved
# rather than quietly falling back to the newest.
FAKE_REGISTRY = (
    "const VERSIONS = " + json.dumps(VERSIONS) + ";\n"
    "const NEWEST = " + json.dumps(NEWEST) + ";\n"
    "export default function () {\n"
    "  const p = (request.path || '/').split('?')[0];\n"
    "  if (request.method === 'POST' && p === '/v1/resolve') {\n"
    # `request.json`, not `request.body` — the latter is retired
    # (handler-shape.md §7) and reads as `undefined`, so the overrides
    # would go unnoticed and the registry would answer with the newest
    # version as if no pin had been sent. That is precisely the bug this
    # smoke exists to catch, so it must not be in the fixture.
    "    const body = request.json || {};\n"
    "    const want = (body.overrides || {})['@rewind/greet'] || NEWEST;\n"
    "    const v = VERSIONS[want];\n"
    "    response.headers = { 'content-type': 'application/json' };\n"
    "    if (!v) {\n"
    "      response.status = 422;\n"
    "      return JSON.stringify({ error: { code: 'unresolved', spec: '@rewind/greet', range: want } });\n"
    "    }\n"
    "    return JSON.stringify({\n"
    "      packages: [{ spec: '@rewind/greet', version: want, pkg_hash: v.pkg_hash,\n"
    "                   files: [{ path: 'index.mjs', source_hash: v.src_hash }],\n"
    "                   imports: {}, capabilities: [], private: false }],\n"
    "      app_imports: { '@rewind/greet': v.pkg_hash },\n"
    "    });\n"
    "  }\n"
    "  if (request.method === 'GET' && p.startsWith('/v1/blobs/')) {\n"
    "    const h = p.slice('/v1/blobs/'.length);\n"
    "    for (const k of Object.keys(VERSIONS)) {\n"
    "      if (VERSIONS[k].src_hash === h) {\n"
    "        response.headers = { 'content-type': 'text/plain; charset=utf-8' };\n"
    "        return VERSIONS[k].src;\n"
    "      }\n"
    "    }\n"
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
        r = c.wait_for_handler("registry", "/v1/blobs/" + VERSIONS[NEWEST]["src_hash"],
                               want_body="greet")
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
            lock = Path(d) / "rewind.lock"

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

            def cli(*args, expect_ok=True):
                """Run the CLI, echo its output, return the completed process."""
                pr = subprocess.run(
                    [str(REWIND_BIN), *args],
                    env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, timeout=180,
                )
                print(f"  --- rewind {' '.join(args[:2])} ---")
                for line in pr.stdout.splitlines():
                    print("  | " + line)
                if expect_ok:
                    assert pr.returncode == 0, f"rewind {args[0]} exited {pr.returncode}"
                return pr

            def locked_version():
                doc = json.loads(lock.read_text())
                pkg_hash = doc["app_imports"]["@rewind/greet"]
                for pkg in doc["packages"]:
                    if pkg["pkg_hash"] == pkg_hash:
                        return pkg["version"]
                raise AssertionError("lockfile app_imports names no package")

            def serve_and_release(pr, want_body):
                m = re.search(r"deployment staged: ([0-9a-f]+)", pr.stdout)
                assert m, f"no dep_id in CLI output:\n{pr.stdout}"
                rr = c.release("consumer", int(m.group(1), 16))
                assert rr.status == 204, f"release consumer: {rr.status} {rr.body!r}"
                got = c.wait_for_handler("consumer", "/", want_body=want_body)
                assert got.status == 200 and want_body in got.body, \
                    f"consumer serve: {got.status} {got.body!r} (wanted {want_body!r})"
                return got

            # ── 1. no lockfile: resolve the range, take the newest ──
            pr = cli("deploy", "consumer", d)
            assert "auto-pinned @rewind/greet" in pr.stdout, "CLI did not auto-pin the undeclared @rewind import"
            assert "resolved 1 package(s)" in pr.stdout, "CLI did not report resolving the package"
            assert lock.exists(), "rewind.lock not written"
            assert locked_version() == NEWEST, f"first deploy locked {locked_version()}, wanted {NEWEST}"
            serve_and_release(pr, VERSIONS[NEWEST]["greeting"])
            print(f"  ok   no lockfile → newest ({NEWEST}); lock written")

            # ── 2. pin BACKWARDS: the lock is an input, not a souvenir ──
            # Hand the CLI a lock naming the older version and deploy again.
            # Nothing else changes — same manifest, same range, same registry.
            # If the lock were ignored the registry would hand back the newest
            # again, which is exactly the drift rove#630 is about.
            cli("lock", d)   # first: `lock` is the UPDATE verb, stays newest
            assert locked_version() == NEWEST, "`rewind lock` should resolve to the newest"
            lock.write_text(json.dumps({
                # `v` is the lockfile format version the CLI stamps and
                # checks (`src/cli/packages.zig` LOCKFILE_VERSION). This
                # fixture is a SECOND implementation of the format — it
                # hand-writes what `rewind lock` would — so it has to carry
                # the field or the deploy below refuses it, correctly.
                "v": 1,
                "packages": [{
                    "spec": "@rewind/greet", "version": OLDEST,
                    "pkg_hash": VERSIONS[OLDEST]["pkg_hash"],
                    "files": [{"path": "index.mjs", "source_hash": VERSIONS[OLDEST]["src_hash"]}],
                    "imports": {}, "capabilities": [], "private": False,
                }],
                "app_imports": {"@rewind/greet": VERSIONS[OLDEST]["pkg_hash"]},
            }))
            pr = cli("deploy", "consumer", d)
            assert "all 1 pinned by rewind.lock" in pr.stdout, \
                f"CLI did not report using the lock:\n{pr.stdout}"
            assert locked_version() == OLDEST, f"pin did not hold — locked {locked_version()}"
            # The decisive assertion: the HANDLER serves the old package's
            # bytes. A lockfile that only changed the metadata would still
            # serve the newest greeting here.
            serve_and_release(pr, VERSIONS[OLDEST]["greeting"])
            print(f"  ok   lockfile pin held → served {OLDEST}, not {NEWEST}")

            # ── 3. --update: the deliberate way to move a pin ──
            pr = cli("deploy", "consumer", d, "--update")
            assert "--update: every range re-resolved" in pr.stdout, \
                f"--update did not report re-resolving:\n{pr.stdout}"
            assert locked_version() == NEWEST, f"--update did not move the pin: {locked_version()}"
            serve_and_release(pr, VERSIONS[NEWEST]["greeting"])
            print(f"  ok   --update moved the pin back to {NEWEST}")

            # ── 4. --frozen refuses a lock that has fallen behind ──
            manifest = json.loads((Path(d) / "manifest.json").read_text())
            manifest["dependencies"] = {"@rewind/nonesuch": "^1.0"}
            (Path(d) / "manifest.json").write_text(json.dumps(manifest))
            pr = cli("deploy", "consumer", d, "--frozen", expect_ok=False)
            assert pr.returncode != 0, "--frozen accepted a lockfile missing a declared dependency"
            assert "@rewind/nonesuch" in pr.stdout, f"--frozen did not name the missing dep:\n{pr.stdout}"
            # And it refused BEFORE touching the tenant: a deploy that resets
            # the tenant and then declines to proceed is worse than one that
            # never started.
            assert "reset" not in pr.stdout.lower(), \
                f"--frozen reset the tenant before refusing:\n{pr.stdout}"
            print("  ok   --frozen refused, before mutating the tenant")

    print("\nPASS pm-cli smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
