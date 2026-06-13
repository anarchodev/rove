#!/usr/bin/env python3
"""publish_tenant.py — publish a tenant bundle to the production cluster.

The codified form of the proven publish path (deploy-plan §8 item 4):
spawn files-server-v2 locally against the prod S3 backend, upload + compile
handler sources, PUT static blobs, stamp an EXPLICIT manifest (the bundle
is the source of truth — this kills the /deploy carry-forward trap where
prior static entries ride into the new manifest), then flip the release on
a worker over the private plane (leader-aware retry; transient 503s while
group leadership settles are normal).

Bundle layout:
    <bundle>/
      *.mjs / **/*.mjs        handler sources (compiled server-side);
                              _middlewares/, _rp/ etc. ride along
      _static/**              static assets, served at their path sans
                              _static/ (the worker only consults
                              _static/-prefixed manifest keys)
    anything else outside _static/ is skipped with a warning (e.g. a
    source-of-truth index.html that a handler embeds).

Config comes from the operator env file (default .env.prod at the repo
root): S3_* / AWS_*, LOOP46_SERVICES_JWT_SECRET, REWIND_ROOT_TOKEN,
REWIND_ADMIN_DOMAIN, REWIND_MOVE_SECRET (only for --provision/--host),
ADMIN_OPS_SECRET (only for --host), ROVE_PUBLISH_SSH (the host the release
call tunnels through), ROVE_WORKER_URLS, ROVE_CP_URL_INTERNAL.

Usage:
    scripts/publish_tenant.py marketing web/marketing
    scripts/publish_tenant.py docs web/docs --provision --host docs.rewindjs.com
    scripts/publish_tenant.py marketing web/marketing --verify-host rewindjs.com
"""
import argparse
import atexit
import hashlib
import json
import mimetypes
import os
import pathlib
import shlex
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from smoke_lib import mint_jwt  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parent.parent
FILES_PORT = 18180

CONTENT_TYPES = {  # extends mimetypes for the cases we care about
    ".mjs": "text/javascript; charset=utf-8",
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json",
    ".svg": "image/svg+xml",
    ".wasm": "application/wasm",
}


def content_type(path: pathlib.Path) -> str:
    if path.suffix in CONTENT_TYPES:
        return CONTENT_TYPES[path.suffix]
    guess, _ = mimetypes.guess_type(str(path))
    return guess or "application/octet-stream"


def load_env(path: pathlib.Path) -> dict:
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
    return env


def curl(*args, data: bytes | None = None, timeout: int = 120):
    cmd = ["curl", "-s", "--max-time", str(timeout), "-w", "\n%{http_code}", *args]
    r = subprocess.run(cmd, input=data, capture_output=True)
    body, _, code = r.stdout.decode().rpartition("\n")
    return (int(code) if code else 0), body


def ssh_curl(ssh_target: str, *curl_args, timeout: int = 20):
    """curl executed ON the publish host (private-plane reachability)."""
    quoted = " ".join(shlex.quote(a) for a in curl_args)
    r = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", ssh_target,
         f"curl -s --max-time {timeout} -w '\\n%{{http_code}}' {quoted}"],
        capture_output=True)
    body, _, code = r.stdout.decode().rpartition("\n")
    return (int(code) if code else 0), body


def spawn_files_server(env: dict) -> str:
    """Start files-server-v2 against the prod S3 backend; killed at exit."""
    binary = REPO / "zig-out/bin/files-server-v2"
    if not binary.exists():
        sys.exit("zig-out/bin/files-server-v2 missing — run: "
                 "zig build files-server-v2 -Doptimize=ReleaseFast")
    proc_env = dict(os.environ)
    for k in ("S3_ENDPOINT", "S3_REGION", "S3_BUCKET", "S3_KEY_PREFIX_BASE",
              "S3_USE_TLS", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
              "LOOP46_SERVICES_JWT_SECRET"):
        if k in env:
            proc_env[k] = env[k]
    data_dir = pathlib.Path("/tmp/publish-fsv2")
    data_dir.mkdir(exist_ok=True)
    log = open("/tmp/publish-fsv2.log", "w")
    proc = subprocess.Popen([str(binary), "--data-dir", str(data_dir),
                             "--listen", f"127.0.0.1:{FILES_PORT}"],
                            env=proc_env, stdout=log, stderr=log)
    atexit.register(proc.terminate)
    origin = f"http://127.0.0.1:{FILES_PORT}"
    for _ in range(50):
        if proc.poll() is not None:
            sys.exit(f"files-server-v2 exited rc={proc.returncode} — "
                     f"see /tmp/publish-fsv2.log")
        code, _ = curl(f"{origin}/", timeout=2)
        if code:  # any HTTP answer (401 expected) means it's up
            return origin
        time.sleep(0.1)
    sys.exit("files-server-v2 did not come up — see /tmp/publish-fsv2.log")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tenant")
    ap.add_argument("bundle", type=pathlib.Path)
    ap.add_argument("--env", type=pathlib.Path, default=REPO / ".env.prod")
    ap.add_argument("--provision", action="store_true",
                    help="provision the tenant first (409/conflict = already placed, fine)")
    ap.add_argument("--host", action="append", default=[],
                    help="map a custom host to the tenant: CP /_control/host (front "
                         "routing) + worker domain alias via the __admin__ ops handler. "
                         "Repeatable. {tenant}.rewindjs.app needs none of this.")
    ap.add_argument("--verify-host", default=None,
                    help="after release, GET https://<host>/ and require 200")
    args = ap.parse_args()

    env = load_env(args.env)
    ssh_target = env.get("ROVE_PUBLISH_SSH") or sys.exit("ROVE_PUBLISH_SSH not in env file")
    workers = (env.get("ROVE_WORKER_URLS") or sys.exit("ROVE_WORKER_URLS not in env file")).split(",")
    cp_url = env.get("ROVE_CP_URL_INTERNAL", "http://10.0.0.1:9090")
    admin_host = env["REWIND_ADMIN_DOMAIN"]
    jwt = mint_jwt(env["LOOP46_SERVICES_JWT_SECRET"],
                   {"exp": int((time.time() + 3600) * 1000)})
    auth = f"Authorization: Bearer {jwt}"

    if not args.bundle.is_dir():
        sys.exit(f"{args.bundle}: not a directory")

    # ── classify the bundle ──────────────────────────────────────────
    handlers, statics, skipped = [], [], []
    for p in sorted(args.bundle.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(args.bundle).as_posix()
        if rel.startswith("_static/"):
            statics.append((rel, p))
        elif p.suffix == ".mjs":
            handlers.append((rel, p))
        else:
            skipped.append(rel)
    if skipped:
        print(f"  ! skipping (not .mjs, not _static/): {', '.join(skipped)}")
    if not handlers and not statics:
        sys.exit("bundle has nothing to publish")
    print(f"bundle: {len(handlers)} handler(s), {len(statics)} static(s)")

    # ── provision (optional) ─────────────────────────────────────────
    if args.provision:
        ms = env["REWIND_MOVE_SECRET"]
        body = json.dumps({"tenant": args.tenant, "cluster": "prod"})
        code, out = ssh_curl(ssh_target, "-X", "POST", f"{cp_url}/_control/provision",
                             "-H", f"X-Rewind-Move-Secret: {ms}",
                             "-H", "Content-Type: application/json", "-d", body)
        if code == 204:
            print(f"provisioned tenant {args.tenant}")
        elif code == 409:
            print(f"tenant {args.tenant} already placed (409) — continuing")
        else:
            sys.exit(f"provision failed: {code} {out}")

    fs = spawn_files_server(env)

    # ── handlers: upload + compile ───────────────────────────────────
    manifest: dict[str, dict] = {}
    if handlers:
        for rel, p in handlers:
            code, out = curl("-X", "POST", f"{fs}/{args.tenant}/upload",
                             "-H", auth, "-H", f"X-Rove-Path: {rel}",
                             "--data-binary", "@-", data=p.read_bytes())
            if code != 204:
                sys.exit(f"upload {rel}: {code} {out}")
        code, out = curl("-X", "POST", f"{fs}/{args.tenant}/deploy", "-H", auth)
        if code != 200:
            sys.exit(f"deploy (compile) failed: {code} {out}")
        base_id = int(out.strip())
        # Read back the server-authoritative manifest; keep ONLY this
        # bundle's handlers (drops carried-forward entries).
        code, out = curl(f"{fs}/{args.tenant}/deployments/{base_id:016x}", "-H", auth)
        if code != 200:
            sys.exit(f"manifest read-back failed: {code} {out}")
        ours = {rel for rel, _ in handlers}
        for e in json.loads(out)["entries"]:
            if e["kind"] != "static" and e["path"] in ours:
                manifest[e["path"]] = {"hash": e["hash"], "kind": e["kind"],
                                       "content_type": e.get("content_type", "")}
        missing = ours - set(manifest)
        if missing:
            sys.exit(f"compiled manifest is missing handlers: {missing}")

    # ── statics: content-addressed blob PUTs ─────────────────────────
    for rel, p in statics:
        b = p.read_bytes()
        h = hashlib.sha256(b).hexdigest()
        code, out = curl("-X", "PUT", f"{fs}/{args.tenant}/blobs/{h}",
                         "-H", auth, "--data-binary", "@-", data=b)
        if code not in (200, 201, 204):
            sys.exit(f"blob {rel}: {code} {out}")
        manifest[rel] = {"hash": h, "kind": "static", "content_type": content_type(p)}

    # ── stamp the explicit manifest ──────────────────────────────────
    code, out = curl("-X", "POST", f"{fs}/{args.tenant}/deployments",
                     "-H", auth, "-H", "Content-Type: application/json",
                     "--data-binary", "@-",
                     data=json.dumps({"files": manifest}).encode())
    if code != 201:
        sys.exit(f"manifest POST failed: {code} {out}")
    dep_id = int(json.loads(out)["id"], 16)
    print(f"deployment stamped: {dep_id} ({len(manifest)} file(s))")

    # ── release flip (leader-aware + leadership-settling retries) ────
    rt = env["REWIND_ROOT_TOKEN"]
    body = json.dumps({"tenant_id": args.tenant, "dep_id": dep_id})
    released = False
    for attempt in range(6):
        for w in workers:
            code, out = ssh_curl(ssh_target, "--http2-prior-knowledge",
                                 "-X", "POST", f"{w}/_system/release",
                                 "-H", f"Host: {admin_host}",
                                 "-H", f"Authorization: Bearer {rt}",
                                 "-H", "Content-Type: application/json", "-d", body)
            if code == 204:
                released = True
                break
            print(f"  release via {w}: {code} (retrying)")
        if released:
            break
        time.sleep(2)
    if not released:
        sys.exit("release flip failed on every worker after retries")
    print(f"released {args.tenant} @ {dep_id}")

    # ── custom hosts (optional) ──────────────────────────────────────
    for host in args.host:
        ms = env["REWIND_MOVE_SECRET"]
        code, out = ssh_curl(ssh_target, "-X", "POST", f"{cp_url}/_control/host",
                             "-H", f"X-Rewind-Move-Secret: {ms}",
                             "-H", "Content-Type: application/json",
                             "-d", json.dumps({"host": host, "tenant": args.tenant}))
        if code not in (200, 204):
            sys.exit(f"CP host map {host}: {code} {out}")
        ops = env["ADMIN_OPS_SECRET"]
        code, out = ssh_curl(ssh_target, "--http2-prior-knowledge",
                             "-X", "POST", f"{workers[0]}/ops/assign-domain",
                             "-H", f"Host: {admin_host}",
                             "-H", f"Authorization: Bearer {ops}",
                             "-H", "Content-Type: application/json",
                             "-d", json.dumps({"host": host, "tenant": args.tenant}))
        if code != 204:
            sys.exit(f"worker domain alias {host}: {code} {out}")
        print(f"host mapped: {host} → {args.tenant}")

    # ── verify ───────────────────────────────────────────────────────
    if args.verify_host:
        time.sleep(2)  # loader is async
        code, _ = curl(f"https://{args.verify_host}/", timeout=20)
        if code != 200:
            sys.exit(f"verify: https://{args.verify_host}/ returned {code} (wanted 200)")
        print(f"verified: https://{args.verify_host}/ → 200")
    print("publish complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
