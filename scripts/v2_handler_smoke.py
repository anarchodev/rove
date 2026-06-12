#!/usr/bin/env python3
"""V2 deployed-handler smoke — the first end-to-end JS-handler deploy on the
V2 stack (branch `v2`). Closes the cutover-checklist follow-up "a deployed-handler
e2e smoke (move smokes exercise only raw v2-kv, not deployed handlers)".

Topology (single-node cluster, the production publish path — CP-routed):

  files-server-v2 :18250   (cluster-free deploy publisher → S3 blobs)
  rewind-cp       :18255   (directory + provisioning)
    └─ cluster-1 → rewind :18251  (1-node; the tenant's raft group)
  rewind-front    :18250→  proxies Host→cluster via the CP

Flow:
  1. provision {handlertenant, cluster-1, handler.localhost} via the CP → 204
     (forms the tenant's raft group on the node + writes the host mapping).
  2. files-server-v2 compiles + writes the handler bytecode + manifest to the
     SHARED S3 prefix (`upload` then `deploy` → dep_id). Cluster-free: the V1
     files-server's willemt-raft path is excised on V2.
  3. flip `_deploy/current` via the WORKER's `/_system/release` (envelope-0
     through the per-tenant bridge) — the V2 deployment loader picks it up.
  4. GET the handler through the FRONT DOOR (Host=handler.localhost) → 200 +
     the handler's body. Proves: CP provision → publish → load → serve.

Build first:
  zig build rewind && zig build rewind-cp && zig build rewind-front \
    && zig build files-server-v2
Needs S3 env (the V2 blob backend is S3-only): `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from v2_topology import spawn_cp, spawn_front, await_line, CP_BIN, FRONT_BIN  # noqa: E402

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind")
FILES_V2 = os.path.join(BINDIR, "files-server-v2")

PNODE = int(os.environ.get("NODE_PORT", "18251"))
RPNODE = int(os.environ.get("NODE_RAFT_PORT", "18261"))
PCP = int(os.environ.get("CP_PORT", "18255"))
PF = int(os.environ.get("FRONT_PORT", "18250"))
PFILES = int(os.environ.get("FILES_PORT", "18256"))

MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
ROOT_TOKEN = "smoke-nonprod-root-token-0123456789abcdef"  # non-default: rewind rejects the default
JWT_SECRET_HEX = "a" * 64  # LOOP46_SERVICES_JWT_SECRET (shared with the mint below)
ADMIN_HOST = "n1.localhost"  # REWIND_ADMIN_DOMAIN for the node

TENANT = "handlertenant"
PUBLIC_SUFFIX = "localhost"
# Wildcard host: `{tenant}.{suffix}` resolves to the instance via the worker's
# public-suffix wildcard (no explicit domain alias needed). The CP host mapping
# (provision host=...) routes the same host at the front door.
HOST = f"{TENANT}.{PUBLIC_SUFFIX}"
HANDLER_SRC = 'export default function () { return "hello from a v2 deployed handler\\n"; }\n'
HANDLER_BODY = "hello from a v2 deployed handler\n"

# Unique S3 prefix per run so the worker + files-server share blobs without
# colliding with other runs. The per-tenant key is `{prefix}{tenant}/...`.
S3_PREFIX = f"v2hsmoke-{os.getpid()}/"

procs = []


def mint_jwt(secret_hex: str, exp_ms: int) -> str:
    """HS256 JWT `{"exp":<unix_ms>}` — the files-server verifies signature + exp
    only (no caps). Compact separators (see feedback_python_jwt_compact_json)."""
    def b64u(b: bytes) -> str:
        import base64
        return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    header = json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode()
    body = json.dumps({"exp": exp_ms}, separators=(",", ":")).encode()
    signing_input = (b64u(header) + "." + b64u(body)).encode()
    sig = hmac.new(bytes.fromhex(secret_hex), signing_input, hashlib.sha256).digest()
    return signing_input.decode() + "." + b64u(sig)


def _curl(args, deadline_s=15):
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-m", str(deadline_s),
         "--http2-prior-knowledge"] + args,
        capture_output=True, text=True)
    text = out.stdout
    nl = text.rfind("\n")
    if nl < 0:
        return (0, text)
    body, code = text[:nl], text[nl + 1:].strip()
    try:
        return (int(code), body)
    except ValueError:
        return (0, body)


NODE_LOG = None


def spawn_rewind(name, port, data_dir):
    global NODE_LOG
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = ADMIN_HOST
    env["REWIND_PUBLIC_SUFFIX"] = PUBLIC_SUFFIX
    env["REWIND_ROOT_TOKEN"] = ROOT_TOKEN
    env["REWIND_MOVE_SECRET"] = MOVE_SECRET
    env["REWIND_NODE_ID"] = "1"
    env["REWIND_VOTERS"] = "1"
    env["REWIND_PEERS"] = f"127.0.0.1:{RPNODE}"
    env["S3_KEY_PREFIX_BASE"] = S3_PREFIX
    # Log to a file (not a PIPE) so the deployment-loader logs are retained
    # AND the unread pipe never fills + blocks the worker after boot.
    NODE_LOG = f"/tmp/v2hsmoke-n1-{os.getpid()}.log"
    logf = open(NODE_LOG, "w+")
    p = subprocess.Popen([REWIND, data_dir, str(port)],
                         stdout=logf, stderr=subprocess.STDOUT, env=env)
    p._name = name
    p._logf = logf
    procs.append(p)
    await_line(p, name, "listening on")
    return p


def spawn_files_v2(name, port, data_dir):
    env = dict(os.environ)
    env["LOOP46_SERVICES_JWT_SECRET"] = JWT_SECRET_HEX
    env["S3_KEY_PREFIX_BASE"] = S3_PREFIX
    p = subprocess.Popen(
        [FILES_V2, "--data-dir", data_dir, "--listen", f"127.0.0.1:{port}"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    p._name = name
    procs.append(p)
    await_line(p, name, "listening on")
    return p


def provision(cp_port, tenant, cluster, host):
    return _curl([
        "-X", "POST", f"http://127.0.0.1:{cp_port}/_control/provision",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", json.dumps({"tenant": tenant, "cluster": cluster, "host": host}),
    ])


def files_origin():
    return f"http://127.0.0.1:{PFILES}"


def upload(tenant, path, content, jwt):
    return _curl([
        "-X", "POST", f"{files_origin()}/{tenant}/upload",
        "-H", f"Authorization: Bearer {jwt}",
        "-H", f"X-Rove-Path: {path}",
        "--data-binary", content,
    ])


def deploy(tenant, jwt):
    return _curl([
        "-X", "POST", f"{files_origin()}/{tenant}/deploy",
        "-H", f"Authorization: Bearer {jwt}",
    ])


def release(tenant, dep_id):
    # The flip is the WORKER's job (envelope-0 via the per-tenant bridge),
    # admin-gated by the root token, addressed at the node's admin host.
    return _curl([
        "-X", "POST", f"http://127.0.0.1:{PNODE}/_system/release",
        "-H", f"Host: {ADMIN_HOST}",
        "-H", f"Authorization: Bearer {ROOT_TOKEN}",
        "-H", "Content-Type: application/json",
        "--data", json.dumps({"tenant_id": tenant, "dep_id": int(dep_id)}),
    ])


def get_via_front(host, path="/"):
    return _curl([f"http://127.0.0.1:{PF}{path}", "-H", f"Host: {host}"])


def get_handler_retry(host, want_body, deadline_s=25):
    """The deployment loader runs async after the release flip — poll the front
    until the handler loads + serves (200 + body)."""
    deadline = time.time() + deadline_s
    last = None
    while time.time() < deadline:
        st, body = get_via_front(host)
        last = (st, body)
        if st == 200 and want_body in body:
            return last
        time.sleep(0.4)
    return last


def stop_all():
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
    for p in procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def main():
    for b in (REWIND, CP_BIN, FRONT_BIN, FILES_V2):
        if not os.path.exists(b):
            raise SystemExit(
                f"{b} not found — run `zig build rewind && zig build rewind-cp "
                f"&& zig build rewind-front && zig build files-server-v2`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    pid = os.getpid()
    dnode = f"/tmp/v2hsmoke-node-{pid}"
    dcp = f"/tmp/v2hsmoke-cp-{pid}"
    dfiles = f"/tmp/v2hsmoke-files-{pid}"
    for d in (dnode, dcp, dfiles):
        subprocess.run(["rm", "-rf", d])

    failures = []

    def check(label, got, want, predicate="eq"):
        ok = (got == want) if predicate == "eq" else (got != want)
        sign = "==" if predicate == "eq" else "!="
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} ({sign} {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    try:
        print(f"boot: 1-node cluster-1 + CP + front + files-server-v2 (S3 prefix {S3_PREFIX})")
        spawn_rewind("n1", PNODE, dnode)
        nodes_csv = f"http://127.0.0.1:{PNODE}"
        spawn_cp(procs, PCP, clusters=f"cluster-1={nodes_csv}",
                 hosts="", placement="", cp_data_dir=dcp, move_secret=MOVE_SECRET)
        spawn_front(procs, PF, f"http://127.0.0.1:{PCP}", route_cache_ms=0)
        spawn_files_v2("files-v2", PFILES, dfiles)

        # 1. provision the tenant onto the cluster (forms group + host map).
        print("step 1: provision the tenant via the CP")
        st, body = provision(PCP, TENANT, "cluster-1", HOST)
        check("provision status", st, 204)

        # 2. publish: compile + blob-write via files-server-v2.
        print("step 2: upload + deploy the handler (compile → S3 blobs)")
        jwt = mint_jwt(JWT_SECRET_HEX, int((time.time() + 3600) * 1000))
        st, body = upload(TENANT, "index.mjs", HANDLER_SRC, jwt)
        check("upload status", st, 204)
        st, dep_id = deploy(TENANT, jwt)
        check("deploy status", st, 200)
        dep_id = dep_id.strip()
        print(f"         dep_id={dep_id!r}")

        # 3. flip _deploy/current via the worker (envelope-0 through the bridge).
        print("step 3: release (flip _deploy/current via the worker)")
        st, body = release(TENANT, dep_id)
        check("release status", st, 204)

        # 4. serve the handler through the front door.
        print("step 4: GET the handler through the front door")
        st, body = get_handler_retry(HOST, HANDLER_BODY)
        check("GET handler status", st, 200)
        check("GET handler body", HANDLER_BODY in (body or ""), True)
        if st != 200:
            # Diagnostics: probe the node directly (bypass the front) + dump
            # the worker's deployment-loader logs.
            dst, dbody = _curl([f"http://127.0.0.1:{PNODE}/", "-H", f"Host: {HOST}"])
            print(f"  diag: direct node GET → {dst} {dbody!r}")
            if NODE_LOG and os.path.exists(NODE_LOG):
                with open(NODE_LOG) as f:
                    lines = [ln for ln in f.read().splitlines()
                             if any(k in ln.lower() for k in
                                    ("deploy", "loader", "manifest", "bytecode",
                                     "resolve", "404", "error", "warn", "blob", "s3"))]
                print("  diag: node log (filtered):")
                for ln in lines[-30:]:
                    print(f"    | {ln}")

        if failures:
            print(f"\nFAILURES ({len(failures)}):")
            for f in failures:
                print(f"  - {f}")
            return 1
        print("\nall v2 deployed-handler smoke checks passed")
        return 0
    finally:
        stop_all()
        for d in (dnode, dcp, dfiles):
            subprocess.run(["rm", "-rf", d])


if __name__ == "__main__":
    sys.exit(main())
