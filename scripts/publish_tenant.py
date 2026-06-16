#!/usr/bin/env python3
"""publish_tenant.py — publish a tenant bundle to the production cluster.

DEPRECATED / BROKEN (2026-06-16): the `/_system/deploy` route this posts to was
removed when deploy moved into the standing __admin__ app (rewind-cli-plan §4.2).
Use the `rewind-ops` operator CLI instead: `zig build rewind-ops` then
`rewind-ops bootstrap` / `provision <tenant> --host H` / `deploy <tenant> <bundle>
--release` / `move` / `plan set` / `status` — it covers every operation this
script welded together (host add lands once the full admin app exposes
/ops/assign-domain on the bootstrapped path). This file is retained only for
historical reference.

The codified form of the proven publish path (deploy-plan §8 item 4). The
build/stage step now lives IN the worker (files-server dissolved,
docs/rewind-cli-plan.md §4): one `POST /_system/deploy` over the private plane
hands the whole bundle (handlers + statics, base64) to a worker, which
compiles, content-addresses every file into the tenant's own blobs, and stamps
an EXPLICIT manifest (the bundle is the source of truth — no carry-forward).
Then flip the release on a worker (leader-aware retry; transient 503s while
group leadership settles are normal).

Bundle layout:
    <bundle>/
      *.mjs / **/*.mjs        handler sources (compiled server-side);
                              index.mjs, _middlewares/, _rp/ etc. ride along
      _static/**              static assets, served at their path sans
                              _static/ (the worker only consults
                              _static/-prefixed manifest keys)
      _config/**              deployed as static; config_mirror replicates
                              it to kv at release (e.g. the auth tenant's
                              _config/oidc/default.json client registry)
    codemirror-entry.mjs (build source) and anything else is skipped.
    Classification mirrors classify() in src/files_server/bootstrap.zig.

Config comes from the operator env file (default ~/.config/rove/prod.env,
legacy fallback .env.prod at the repo root): REWIND_ROOT_TOKEN (gates both
/_system/deploy and /_system/release), REWIND_ADMIN_DOMAIN, REWIND_MOVE_SECRET
(only for --provision/--host), ADMIN_OPS_SECRET (only for --host),
ROVE_PUBLISH_SSH (the host the deploy + release calls tunnel through),
ROVE_WORKER_URLS, ROVE_CP_URL_INTERNAL. (S3_*/AWS_* + the services-JWT secret
are no longer needed here — the worker owns the blob backend now.)

Usage:
    scripts/publish_tenant.py marketing web/marketing
    scripts/publish_tenant.py docs web/docs --provision --host docs.rewindjs.com
    scripts/publish_tenant.py marketing web/marketing --verify-host rewindjs.com
"""
import argparse
import json
import mimetypes
import os
import pathlib
import shlex
import subprocess
import base64
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent


def default_env_file() -> pathlib.Path:
    """Operator secrets live at ~/.config/rove/prod.env (survives worktree
    churn; mirrors the hosts' ~/.config/rove/common.env). Fall back to the
    legacy repo-root .env.prod if the XDG copy isn't present."""
    xdg = pathlib.Path(os.environ.get("XDG_CONFIG_HOME") or pathlib.Path.home() / ".config")
    cand = xdg / "rove" / "prod.env"
    return cand if cand.exists() else REPO / ".env.prod"

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


def ssh_curl_stdin(ssh_target: str, *curl_args, data: bytes, timeout: int = 120):
    """Like ssh_curl, but streams the request body over ssh stdin
    (`curl --data-binary @-`) so a large deploy bundle doesn't hit ARG_MAX on
    the remote command line."""
    quoted = " ".join(shlex.quote(a) for a in curl_args)
    r = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", ssh_target,
         f"curl -s --max-time {timeout} -w '\\n%{{http_code}}' {quoted}"],
        input=data, capture_output=True)
    body, _, code = r.stdout.decode().rpartition("\n")
    return (int(code) if code else 0), body


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tenant")
    ap.add_argument("bundle", type=pathlib.Path)
    ap.add_argument("--env", type=pathlib.Path, default=default_env_file())
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
    rt = env["REWIND_ROOT_TOKEN"]

    if not args.bundle.is_dir():
        sys.exit(f"{args.bundle}: not a directory")

    # ── classify the bundle ──────────────────────────────────────────
    # Mirrors classify() in src/files_server/bootstrap.zig EXACTLY (the
    # platform-bundle walker): _static/ AND _config/ are static (the
    # latter mirrors to kv via config_mirror at release — e.g. the auth
    # tenant's _config/oidc/default.json client registry); the build
    # source codemirror-entry.mjs is dropped; every other .mjs (index,
    # _middlewares/*, _rp/*, …) compiles to a handler.
    handlers, statics, skipped = [], [], []
    for p in sorted(args.bundle.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(args.bundle).as_posix()
        if rel.startswith("_static/") or rel.startswith("_config/"):
            statics.append((rel, p))
        elif rel == "codemirror-entry.mjs":
            skipped.append(rel)
        elif rel.endswith(".mjs"):
            handlers.append((rel, p))
        else:
            skipped.append(rel)
    if skipped:
        print(f"  ! skipping (build source / non-deployable): {', '.join(skipped)}")
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

    # ── compile + stage on a worker (/_system/deploy) over the private plane ─
    # files-server is dissolved (docs/rewind-cli-plan.md §4): one POST hands
    # the whole bundle (handlers + statics, base64) to the worker, which
    # compiles, content-addresses every file into the tenant's own blobs, and
    # stamps an EXPLICIT manifest (no carry-forward). Deploy isn't raft-gated
    # so any worker accepts it; try each until one answers 200.
    files_payload = []
    for rel, p in handlers:
        files_payload.append({"path": rel, "kind": "handler", "content_type": "",
                              "b64": base64.b64encode(p.read_bytes()).decode()})
    for rel, p in statics:
        files_payload.append({"path": rel, "kind": "static",
                              "content_type": content_type(p),
                              "b64": base64.b64encode(p.read_bytes()).decode()})
    deploy_body = json.dumps({"tenant_id": args.tenant, "files": files_payload}).encode()

    dep_id = None
    for w in workers:
        code, out = ssh_curl_stdin(
            ssh_target, "--http2-prior-knowledge", "-X", "POST",
            f"{w}/_system/deploy", "-H", f"Host: {admin_host}",
            "-H", f"Authorization: Bearer {rt}",
            "-H", "Content-Type: application/json", "--data-binary", "@-",
            data=deploy_body)
        if code == 200:
            dep_id = int(json.loads(out)["dep_id"], 16)
            break
        print(f"  deploy via {w}: {code} {out[:200]} (trying next)")
    if dep_id is None:
        sys.exit("deploy (/_system/deploy) failed on every worker")
    print(f"deployment staged: {dep_id} ({len(files_payload)} file(s))")

    # ── release flip (leader-aware + leadership-settling retries) ────
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
