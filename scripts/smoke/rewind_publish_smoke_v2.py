#!/usr/bin/env python3
"""End-to-end: the `rewind` CLI as the SINGLE deploy/ops tool for rewind-apps.

Unlike `rewind_customer_smoke_v2.py` (which exercises the server protocol with
scripted HTTP), this drives the REAL `rewind` binary against a live cluster as
an OPERATOR (is_root OIDC session), proving Phase-1 deploy parity:

  • rewind login          — device grant → operator approves → session stored
  • rewind status         — whoami → is_root:true
  • rewind provision      — create+place a tenant via the CP chokepoint, AND
                            re-provision → "already placed (ok)" (this only
                            works if the admin app relays the CP 409 instead of
                            flattening it to 502 — the onFetchResult fix)
  • rewind deploy/rollback— deploy v1+v2, then roll back to v1
  • rewind deployments    — list release history + the live pointer (the new
                            GET /v1/history/{tenant})
  • rewind route          — resolve host → tenant via the CP read chokepoint
  • rewind publish        — manifest-driven: provision+deploy+release a tenant
                            from a manifest.json (replaces publish_firstparty.py)
  • _tests/ strip         — a `_tests/` file in the bundle is never shipped

No platform secret is given to the CLI — only REWIND_CACERT/REWIND_RESOLVE for
the self-hosted TLS front, plus the OIDC session it earns at login.

Run: zig build rewind rewind-worker rewind-cp rewind-front   (+ default build for rewind-logs)
     set -a; . ./.env; set +a
     REWIND_APPS_DIR=~/src/rewind-apps python3 scripts/smoke/rewind_publish_smoke_v2.py
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, REPO_ROOT, APPS_DIR  # noqa: E402

OPERATOR = "op@example.com"
CLIENT_ID = "admin-dashboard"
REWIND_BIN = REPO_ROOT / "zig-out" / "bin" / "rewind"


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def _sid(r) -> str | None:
    m = re.search(r"__Host-rove_sid=[^;]+", r.headers.get("set-cookie", ""))
    return m.group(0) if m else None


ADMIN_HOST = "admin.localhost"
AUTH_HOST = "auth.localhost"
# Hosts the real `rewind` binary verifies the front cert against. curl rejects a
# `*.localhost` wildcard (single-label base = too broad), so the front must serve
# a cert with these EXACT SAN entries.
CLI_HOSTS = [ADMIN_HOST, AUTH_HOST, "pubapp.localhost", "manifestapp.localhost", "localhost"]


def gen_cert(hosts: list[str]) -> tuple[str, str]:
    cert = f"/tmp/rwpub-cert-{os.getpid()}.pem"
    key = f"/tmp/rwpub-key-{os.getpid()}.pem"
    san = ",".join(f"DNS:{h}" for h in hosts)
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", cert, "-days", "1",
         "-subj", "/CN=" + hosts[0], "-addext", "subjectAltName=" + san],
        check=True, capture_output=True)
    return cert, key


def idp_session(c: V2Cluster, *, email: str, auth_base: str) -> str:
    """Magic-link login on the IdP; return the IdP session cookie (used to
    approve the binary's device code)."""
    r = c.tls_curl(auth_base + "/login")
    auth_cookie = _sid(r)
    if not auth_cookie:
        raise RuntimeError(f"IdP /login minted no sid: {r.status}")
    r = c.tls_curl(auth_base + "/login", method="POST",
                   headers={"content-type": "application/x-www-form-urlencoded",
                            "Cookie": auth_cookie},
                   data="email=" + urllib.parse.quote(email) + "&return_to=%2F")
    if r.status != 200:
        raise RuntimeError(f"IdP /login {r.status}: {r.body[:200]}")
    magic = json.loads(r.body)["magic_link"]
    r = c.tls_curl(magic, headers={"Cookie": auth_cookie})
    if r.status != 302:
        raise RuntimeError(f"magic verify {r.status}: {r.body[:200]}")
    return auth_cookie


def main() -> int:
    if not REWIND_BIN.exists():
        print(f"missing {REWIND_BIN} — run `zig build rewind` first")
        return 1

    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail.strip()) if (not ok and detail) else ''}")
        if not ok:
            failures.append(label)

    auth_src = (APPS_DIR / "auth/index.mjs").read_text()
    auth_cfg = (APPS_DIR / "auth/_config/oidc/default.json").read_text()
    admin_files = {p: (APPS_DIR / "admin" / p).read_text() for p in
                   ("index.mjs", "_middlewares/index.mjs",
                    "_rp/complete.mjs", "_rp/jwks.mjs")}

    print("=== rewind CLI as the single deploy/ops tool (Phase 1) ===")
    cert, key = gen_cert(CLI_HOSTS)
    with V2Cluster.spawn("rwpub", nodes=1, http_base=19980, raft_base=20080,
                         tls_idp=True, tls_cert=cert, tls_key=key) as c:
        tls_port = c.tls_front_port
        # Phase 2 needs the request-log query surface: the `__admin__`
        # `rewind-logs.internal` door (LOG_DOOR) reads tenant logs from the
        # co-spawned log-server (the worker is already wired to its port).
        c.spawn_log_server()
        # Tenant ids and hosts are distinct: the system tenants are `__admin__` /
        # `__auth__`, but underscored labels are invalid hostnames that TLS cert
        # verification rejects (the harness only gets away with it via `curl -k`).
        # The real binary verifies, so alias VALID hosts to those tenants and
        # point the CLI + OIDC config at the valid hosts.
        admin_host = ADMIN_HOST
        auth_host = AUTH_HOST
        app_origin = f"https://{admin_host}:{tls_port}"
        auth_base = f"https://{auth_host}:{tls_port}"

        # Stand up __auth__ (IdP) + web/admin (RP), admin last.
        c._ensure_admin_app()
        c.provision("__auth__")
        try:
            c.deploy_with_static(
                "__auth__", {"index.mjs": auth_src},
                {"_config/oidc/default.json": (auth_cfg, "application/json")})
        except RuntimeError as e:
            check("deploy web/auth → __auth__", False, str(e)); return 1
        c.admin_kv_put("__auth__", "_oidc/config/default", json.dumps({
            "clients": [{"client_id": CLIENT_ID,
                         "redirect_uris": [app_origin + "/_rp/callback"]}],
            "login_path": "/login",
        }, separators=(",", ":")))
        try:
            c.deploy_handlers("__admin__", admin_files)
        except RuntimeError as e:
            check("deploy web/admin → __admin__", False, str(e)); return 1
        c.admin_kv_put("__admin__", "_oidc/rp/default", json.dumps({
            "issuer": auth_base, "client_id": CLIENT_ID,
            "redirect_uri": app_origin + "/_rp/callback",
            "post_login": "/", "operator_prefix": "_admin/operator/",
        }, separators=(",", ":")))
        # Seed the OPERATOR so their OIDC session resolves is_root.
        c.admin_kv_put("__admin__", "_admin/operator/" + sha256_hex(OPERATOR), "")
        # Alias the valid hosts → the system tenants (front routing + worker alias).
        c._cp_post("/_control/host", {"host": admin_host, "tenant": "__admin__"})
        c._cp_post("/_control/host", {"host": auth_host, "tenant": "__auth__"})
        check("deployed __auth__ + web/admin + seeded operator + host aliases", True)

        # Readiness.
        r = None
        for _ in range(60):
            r = c.tls_curl(app_origin + "/_rp/login?return_to=%2F")
            if r.status == 302:
                break
            time.sleep(0.4)
        check("__admin__ RP live", r and r.status == 302, f"got {r.status if r else '-'}")
        for _ in range(40):
            rr = c.tls_curl(auth_base + "/login")
            if rr.status == 200:
                break
            time.sleep(0.25)
        if failures:
            c.dump_node_log(grep=["rp", "oidc", "deploy", "error", "warn"])
            print(f"\nFAILED: {failures}"); return 1

        # ── the binary's environment (self-hosted TLS front) ──────────────
        jar = tempfile.NamedTemporaryFile(suffix=".session", delete=False).name
        env = dict(os.environ)
        env.update({
            "REWIND_ADMIN_URL": app_origin,
            "REWIND_IDP_URL": auth_base,
            "REWIND_CLIENT_ID": CLIENT_ID,
            "REWIND_SESSION": jar,
            "REWIND_CACERT": c.tls_cert_path,
            "REWIND_RESOLVE": f"{admin_host}:{tls_port}:127.0.0.1,"
                              f"{auth_host}:{tls_port}:127.0.0.1",
        })

        def rw(*args, timeout=90):
            # The binary writes everything to stderr (Zig std.debug.print); merge
            # it into stdout so a single field carries the full output.
            return subprocess.run([str(REWIND_BIN), *args], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  text=True, timeout=timeout)

        # ── rewind login (device grant), operator approves out-of-band ────
        login = subprocess.Popen([str(REWIND_BIN), "login"], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True)
        user_code = None
        out_acc: list[str] = []
        deadline = time.time() + 40
        while time.time() < deadline and user_code is None:
            line = login.stdout.readline()
            if not line:
                if login.poll() is not None:
                    break
                continue
            out_acc.append(line)
            m = re.search(r"enter the code:\s*(\S+)", line)
            if m:
                user_code = m.group(1)
        check("rewind login printed a user_code", bool(user_code), "".join(out_acc)[:300])

        if user_code:
            try:
                opc = idp_session(c, email=OPERATOR, auth_base=auth_base)
                r = c.tls_curl(auth_base + "/device", method="POST",
                               headers={"content-type": "application/x-www-form-urlencoded",
                                        "Cookie": opc},
                               data="user_code=" + urllib.parse.quote(user_code) + "&action=approve")
                check("operator approved the device code", r.status == 200 and "Approved" in r.body,
                      f"got {r.status} {r.body[:120]!r}")
            except RuntimeError as e:
                check("operator IdP login", False, str(e)[:200])
            try:
                login.wait(timeout=45)
            except subprocess.TimeoutExpired:
                login.kill()
            try:
                out_acc.append(login.stdout.read() or "")
            except Exception:
                pass
            check("rewind login stored a session (exit 0)", login.returncode == 0,
                  "".join(out_acc)[-400:])

        if failures:
            c.dump_node_log(grep=["rp", "oidc", "exchange", "device", "token", "jwks", "error", "warn"])
            print(f"\nFAILED: {failures}"); return 1

        # ── status → operator session ─────────────────────────────────────
        r = rw("status")
        check("rewind status → is_root operator", r.returncode == 0 and '"is_root":true' in r.stdout,
              r.stdout[:300])

        # ── provision (+ idempotent re-provision: the 409 relay) ──────────
        r = rw("provision", "pubapp", "--cluster", c.cluster_id, "--host", "pubapp.localhost")
        check("rewind provision pubapp → provisioned",
              r.returncode == 0 and "provisioned pubapp" in r.stdout, r.stdout[:300])
        r = rw("provision", "pubapp", "--cluster", c.cluster_id, "--host", "pubapp.localhost")
        check("rewind provision pubapp (again) → idempotent (409 relayed, not 502)",
              r.returncode == 0 and "already placed" in r.stdout, r.stdout[:300])

        # ── deploy v1 (+ _tests/ strip) and v2, releasing each ────────────
        def bundle(tmp, body, with_test=False):
            d = Path(tempfile.mkdtemp(prefix=tmp))
            (d / "index.mjs").write_text("export default function(){ return '" + body + "'; }")
            if with_test:
                (d / "_tests").mkdir()
                (d / "_tests" / "x.mjs").write_text("// never shipped")
            return d

        def dep_hex_from(stdout):
            m = re.search(r"released \S+ @ ([0-9a-fA-F]+)", stdout)
            return m.group(1) if m else None

        r = rw("deploy", "pubapp", str(bundle("v1", "v1", with_test=True)), "--release")
        check("rewind deploy pubapp v1 --release → released",
              r.returncode == 0 and "released pubapp" in r.stdout, r.stdout[:400])
        check("deploy stripped _tests/ (skipped, not shipped)",
              "_tests/x.mjs" in r.stdout, r.stdout[:400])
        dep1 = dep_hex_from(r.stdout)

        r = rw("deploy", "pubapp", str(bundle("v2", "v2")), "--release")
        check("rewind deploy pubapp v2 --release → released",
              r.returncode == 0 and "released pubapp" in r.stdout, r.stdout[:400])
        dep2 = dep_hex_from(r.stdout)
        check("two distinct deployments", bool(dep1) and bool(dep2) and dep1 != dep2,
              f"dep1={dep1} dep2={dep2}")

        # v2 is live now.
        for _ in range(35):
            resp = c.tls_curl(c.tls_origin("pubapp") + "/")
            if resp.status == 200 and "v2" in resp.body:
                break
            time.sleep(1.0 if resp.status == 429 else 0.3)
        check("pubapp serves v2 after release", resp.status == 200 and "v2" in resp.body,
              f"got {resp.status} {resp.body[:80]!r}")

        # ── deployments (the new /v1/history) shows both, v2 live ─────────
        r = rw("deployments", "pubapp")
        live_line = next((ln for ln in r.stdout.splitlines() if "LIVE" in ln), "")
        check("rewind deployments lists history + flags v2 LIVE",
              r.returncode == 0 and dep1 and dep2 and dep1 in r.stdout and dep2 in r.stdout
              and dep2 in live_line, r.stdout[:400])

        # ── rollback to v1 ────────────────────────────────────────────────
        if dep1:
            r = rw("rollback", "pubapp", dep1)
            check("rewind rollback pubapp <dep1> → released", r.returncode == 0 and "released pubapp" in r.stdout,
                  r.stdout[:300])
            # Time-based with 429 backoff: under the busier cluster the
            # per-tenant token bucket can stay drained for a while, so give the
            # rollback propagation a generous window rather than a fixed count.
            rb_deadline = time.time() + 40.0
            resp = None
            while time.time() < rb_deadline:
                resp = c.tls_curl(c.tls_origin("pubapp") + "/")
                if resp.status == 200 and "v1" in resp.body:
                    break
                time.sleep(1.0 if resp.status == 429 else 0.3)
            check("pubapp serves v1 after rollback", resp.status == 200 and "v1" in resp.body,
                  f"got {resp.status} {resp.body[:80]!r}")
            r = rw("deployments", "pubapp")
            live_line = next((ln for ln in r.stdout.splitlines() if "LIVE" in ln), "")
            check("deployments now flags v1 LIVE", dep1 in live_line, (r.stdout)[:300])

        # ── route (CP read chokepoint) ────────────────────────────────────
        r = rw("route", "pubapp.localhost")
        check("rewind route pubapp.localhost → resolves to pubapp",
              r.returncode == 0 and '"tenant"' in r.stdout and "pubapp" in r.stdout,
              r.stdout[:300])

        # ── publish (manifest-driven) from a synthetic apps dir ───────────
        proot = Path(tempfile.mkdtemp(prefix="apps"))
        (proot / "manifest.json").write_text(json.dumps({
            "defaults": {"cluster": c.cluster_id, "release": True},
            "tenants": [{"tenant": "manifestapp", "dir": "app",
                         "hosts": ["manifestapp.localhost"],
                         "kind": "operator", "provision": True}],
        }))
        (proot / "app").mkdir()
        (proot / "app" / "index.mjs").write_text("export default function(){ return 'from-manifest'; }")
        r = rw("publish", "--apps-dir", str(proot))
        check("rewind publish (manifest) → provisioned+deployed+released manifestapp",
              r.returncode == 0 and "publish complete" in r.stdout
              and "released manifestapp" in r.stdout, r.stdout[:500])
        for _ in range(20):
            resp = c.tls_curl(c.tls_origin("manifestapp") + "/")
            if resp.status == 200 and "from-manifest" in resp.body:
                break
            time.sleep(1.0 if resp.status == 429 else 0.3)
        check("manifestapp serves after publish", resp.status == 200 and "from-manifest" in resp.body,
              f"got {resp.status} {resp.body[:80]!r}")

        # ── Phase 2: pull a recorded request + replay it natively ─────────
        # Deploy a handler that READS kv, WRITES kv, and logs — so the recorded
        # request carries a kv read tape + console the native replay must
        # reproduce. Then logs → pull → replay, asserting the replay reproduces
        # the record's OWN console + write-set (no hardcoded counter), and that
        # a working-tree change (--source-dir) surfaces a tape divergence.
        rep_dir = Path(tempfile.mkdtemp(prefix="replayapp"))
        (rep_dir / "index.mjs").write_text(
            "export default function(){\n"
            "  const n = kv.get('hits');\n"
            "  const cur = n === null ? 0 : (+n);\n"
            "  kv.set('hits', String(cur + 1));\n"
            "  console.log('hit ' + cur);\n"
            "  return 'hits=' + cur;\n"
            "}\n")
        r = rw("provision", "replayapp", "--cluster", c.cluster_id, "--host", "replayapp.localhost")
        check("rewind provision replayapp", r.returncode == 0 and
              ("provisioned replayapp" in r.stdout or "already placed" in r.stdout), r.stdout[:300])
        r = rw("deploy", "replayapp", str(rep_dir), "--release")
        check("rewind deploy replayapp --release", r.returncode == 0 and "released replayapp" in r.stdout,
              r.stdout[:400])

        # Drive a real request through the front so the worker records it.
        served = False
        for _ in range(25):
            resp = c.tls_curl(c.tls_origin("replayapp") + "/")
            if resp.status == 200 and resp.body.startswith("hits="):
                served = True
                break
            time.sleep(1.0 if resp.status == 429 else 0.3)
        check("replayapp serves (recorded request)", served, f"got {resp.status} {resp.body[:80]!r}")

        # logs: poll until the indexer surfaces a SERVED replayapp request. We
        # want a status-200 record (one that actually dispatched the handler +
        # taped kv/console) — a rate-limited 429 is rejected before dispatch and
        # carries deployment_id 0 (no manifest to pull), so skip those.
        req_id = None
        last = ""
        deadline = time.time() + 60.0
        while time.time() < deadline:
            r = rw("logs", "replayapp")
            last = r.stdout
            if r.returncode == 0:
                try:
                    recs = json.loads(r.stdout).get("records", [])
                except (json.JSONDecodeError, ValueError):
                    recs = []
                served = [rec for rec in recs if rec.get("status") == 200]
                if served:
                    req_id = served[0].get("request_id")
                    break
            time.sleep(1.0)
        if not req_id:
            # Isolate: does the log-server itself (bypassing the admin door)
            # have replayapp records, or any tenant's at all?
            try:
                direct = c.log_get("replayapp/list?limit=5", timeout=15.0)
                pub = c.log_get("pubapp/list?limit=5", timeout=15.0)
                print(f"  [diag] direct replayapp/list: {direct.status} {direct.body[:160]!r}")
                print(f"  [diag] direct pubapp/list:    {pub.status} {pub.body[:160]!r}")
            except Exception as e:
                print(f"  [diag] direct log_get failed: {e}")
        check("rewind logs lists a recorded request_id", bool(req_id), last[:300])

        if req_id:
            fixture = Path(tempfile.mkdtemp(prefix="fix")) / "req.json"
            r = rw("pull", "replayapp", req_id, "-o", str(fixture))
            check("rewind pull writes a self-contained fixture",
                  r.returncode == 0 and fixture.exists(), r.stdout[:300])

            # Replay it natively — no Node/WASM/network. Reproduce the record.
            r = rw("replay", str(fixture))
            try:
                art = json.loads(r.stdout)
            except (json.JSONDecodeError, ValueError):
                art = {}
            rec_console = (art.get("recorded") or {}).get("console", "")
            effects = art.get("effects", [])
            rep_console = " ".join(e.get("message", "") for e in effects if e.get("kind") == "log")
            writes = [e for e in effects if e.get("kind") == "write"]
            wrote_hits = any(w.get("key") == "hits" for w in writes)
            check("rewind replay reproduces the run (no divergence)",
                  r.returncode == 0 and art.get("divergence") is None, r.stdout[:400])
            check("replay reproduces the recorded console",
                  rec_console.strip() != "" and rec_console.strip() == rep_console.strip(),
                  f"recorded={rec_console!r} replay={rep_console!r}")
            check("replay reproduces the kv write-set (hits set)", wrote_hits, str(writes)[:200])
            check("replay status matches the recording", art.get("status_match") is True,
                  f"replayed={art.get('replayed_status')} match={art.get('status_match')}")

            # --source-dir: a working-tree handler that reads an OFF-TAPE key
            # must surface a divergence (the simulate lever), not a silent pass.
            local = Path(tempfile.mkdtemp(prefix="local"))
            (local / "index.mjs").write_text(
                "export default function(){ const x = kv.get('not-on-tape'); return 'x=' + x; }\n")
            r = rw("replay", str(fixture), "--source-dir", str(local))
            try:
                art2 = json.loads(r.stdout)
            except (json.JSONDecodeError, ValueError):
                art2 = {}
            check("rewind replay --source-dir surfaces a divergence on an off-tape read",
                  art2.get("divergence") is not None and art2.get("status_match") is False,
                  r.stdout[:400])

        # ── log-server metrics: scrape the loopback Prometheus endpoint ───
        # Validates the instrumentation AND positively proves the worker→log-
        # server batch PUSH fast-path is live (push_indexed > 0) — distinct
        # from the S3 LIST poll doing the indexing.
        try:
            mtext = urllib.request.urlopen("http://127.0.0.1:9113/metrics", timeout=5).read().decode()
        except Exception as e:  # noqa: BLE001
            mtext = f"(scrape failed: {e})"

        def mval(name):
            m = re.search(rf"^{re.escape(name)} (\d+)$", mtext, re.M)
            return int(m.group(1)) if m else -1

        check("log-server /metrics scrapeable + poll running",
              mval("log_indexer_poll_cycles_total") > 0, mtext[:200])
        check("log-server metrics: push fast-path live (push_indexed>0)",
              mval("log_push_indexed_total") > 0,
              f"received={mval('log_push_received_total')} indexed={mval('log_push_indexed_total')} "
              f"errors={mval('log_push_errors_total')}")

        if failures:
            c.dump_node_log(grep=["deploy", "cp", "provision", "release", "history",
                                  "log", "tape", "error", "warn"])

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — `rewind` drives login → provision → deploy → deployments → "
          "rollback → route → publish, then logs → pull → replay (native, "
          "offline) reproduces a recorded request and catches a working-tree "
          "divergence. One CLI for deploy + replay, no platform secret.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
