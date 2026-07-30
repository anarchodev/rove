#!/usr/bin/env python3
"""Does a certificate survive a cold bring-up?

Regression test for rove#269. Certificates live in the directory raft group
(`cert/{host}`), whose state is under `~/.rove/data/cp` — which `--genesis`
wipes. Re-issuing is not free: Let's Encrypt rate-limits duplicate certificates
to five per week for an identical name set, so a deployment brought up a few
times in a week can exhaust issuance and be left unable to serve TLS, and the
wall is hit later on some unrelated renewal rather than during the genesis that
spent the quota.

The fix mirrors every certificate to object storage at
`{key_prefix_base}_certs/{host}` — outside the storage-namespace generation,
because a certificate for a host is valid no matter which cluster lifetime
requested it — and restores from there before any CA is asked for anything.

This drives the CP directly (no ACME, no CA, no TLS handshake) so it tests the
mechanism rather than the issuance path around it:

  1. store a certificate through `/_control/cert`; it lands in the directory
     and, with a mirror configured, in S3;
  2. kill the CP and WIPE its data dir — exactly what genesis does;
  3. restart against the same store: the certificate comes back, BYTE-IDENTICAL
     (a re-issue could not produce the same bytes), with no CA involved;
  4. negative control — repeat the wipe with the mirror disabled, and the
     certificate is gone. Without this the test would pass just as happily if
     the wipe were not really destroying anything.

Ports: 19860 (see the per-smoke port table). Needs S3 credentials:
`set -a; . ./.env; set +a`.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke_lib import BIN_DIR  # noqa: E402

CP_PORT = 19860
DATA_DIR = "/tmp/rove-cert-survives-cp"
MOVE_SECRET = "certsurvivesecret0123456789abcdef"
HOST = "cert-survives.test"
TENANT = "certtenant"
# A per-run prefix so a rerun starts clean and cannot see another run's mirror.
S3_PREFIX = f"certsurvive-{os.getpid()}/"

# A real certificate + key. The bytes are what matters: if the same bytes come
# back after the wipe, they were restored, not re-issued.
CERT_PEM = None
KEY_PEM = None


def make_cert(tmpdir: str) -> tuple[str, str]:
    crt, key = os.path.join(tmpdir, "c.pem"), os.path.join(tmpdir, "k.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", key,
         "-out", crt, "-days", "90", "-nodes", "-subj", f"/CN={HOST}"],
        check=True, capture_output=True)
    return open(crt).read(), open(key).read()


def cp_env(with_mirror: bool) -> dict:
    env = dict(os.environ)
    env["REWIND_CP_DATA_DIR"] = DATA_DIR
    env["REWIND_MOVE_SECRET"] = MOVE_SECRET
    env["REWIND_CLUSTERS"] = f"cluster-1=http://127.0.0.1:{CP_PORT + 1}"
    env["REWIND_PLACEMENT"] = f"{TENANT}=cluster-1"
    env["REWIND_CP_RECONCILE_SECS"] = "1"  # restore runs on the reconcile tick
    if with_mirror:
        env["S3_KEY_PREFIX_BASE"] = S3_PREFIX
    else:
        # No S3 config at all → no mirror. This is the pre-fix world.
        for k in ("S3_ENDPOINT", "S3_REGION", "S3_BUCKET", "S3_KEY_PREFIX_BASE",
                  "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"):
            env.pop(k, None)
    return env


def start_cp(with_mirror: bool) -> subprocess.Popen:
    p = subprocess.Popen(
        [str(BIN_DIR / "rewind-cp"), str(CP_PORT)],
        env=cp_env(with_mirror), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True)
    deadline = time.time() + 30
    while time.time() < deadline:
        if p.poll() is not None:
            raise RuntimeError(f"cp exited early: {p.stdout.read()[-2000:]}")
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{CP_PORT}/_cp/leader", timeout=2)
            return p
        except Exception:
            time.sleep(0.5)
    raise RuntimeError("cp never became ready")


def stop_cp(p: subprocess.Popen) -> None:
    p.terminate()
    try:
        p.wait(timeout=15)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait(timeout=10)


def map_host() -> bool:
    """Map HOST → TENANT in the directory.

    Accepts 503 as well as 200: after recording the mapping the CP tries to push
    the `domain/{host}` alias to the tenant's serving cluster, and this topology
    has no worker to receive it. The directory mapping — the only part this test
    needs — still stands, which is exactly what the CP's own comment says.
    """
    return post_control("/_control/host", {"host": HOST, "tenant": TENANT}) in (200, 503)


def post_control(path: str, payload: dict) -> int:
    req = urllib.request.Request(
        f"http://127.0.0.1:{CP_PORT}{path}", method="POST",
        data=json.dumps(payload).encode(),
        headers={"X-Rewind-Move-Secret": MOVE_SECRET,
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def stored_cert(timeout_s: float = 20.0) -> bytes | None:
    """The packed cert frame the CP holds for HOST, or None."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(
                    f"http://127.0.0.1:{CP_PORT}/_cp/cert?host={HOST}", timeout=5) as r:
                if r.status == 200:
                    body = r.read()
                    if body:
                        return body
        except Exception:
            pass
        time.sleep(0.5)
    return None


def main() -> int:
    global CERT_PEM, KEY_PEM
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    if not os.environ.get("S3_ENDPOINT"):
        print("SKIP: needs S3 credentials — `set -a; . ./.env; set +a`")
        return 0

    tmp = "/tmp/rove-cert-survives-pem"
    os.makedirs(tmp, exist_ok=True)
    CERT_PEM, KEY_PEM = make_cert(tmp)
    shutil.rmtree(DATA_DIR, ignore_errors=True)

    print("=== a certificate survives a cold bring-up (rove#269) ===")
    cp = None
    try:
        # ── 1. store a cert, with the mirror on ───────────────────────
        cp = start_cp(with_mirror=True)
        check("cp up with a certificate mirror", True)
        check("map the host", map_host())
        check("store the certificate",
              post_control("/_control/cert", {"host": HOST, "cert": CERT_PEM, "key": KEY_PEM}) == 200)
        before = stored_cert()
        check("the CP serves the stored certificate", before is not None,
              "nothing else here means anything if this fails")

        # ── 2. genesis: kill + wipe the CP's state ────────────────────
        stop_cp(cp)
        cp = None
        shutil.rmtree(DATA_DIR, ignore_errors=True)
        check("cp stopped and ~/.rove/data/cp equivalent wiped", not os.path.exists(DATA_DIR))

        # ── 3. restart against the same store ─────────────────────────
        cp = start_cp(with_mirror=True)
        check("map the host again (genesis re-provisions hosts)", map_host())
        after = stored_cert()
        check("the certificate comes back after the wipe", after is not None,
              "the mirror did not restore it")
        check("and it is byte-identical — restored, not re-issued",
              after is not None and before is not None and after == before,
              "different bytes mean a new certificate, i.e. CA quota was spent")

        # ── 4. negative control: no mirror, same wipe ─────────────────
        stop_cp(cp)
        cp = None
        shutil.rmtree(DATA_DIR, ignore_errors=True)
        cp = start_cp(with_mirror=False)
        check("map the host again (no mirror configured)", map_host())
        lost = stored_cert(timeout_s=8.0)
        check("WITHOUT the mirror the certificate is gone (the bug)", lost is None,
              "a cert survived without any mirror, so this smoke cannot see the failure "
              "it claims to test")
    finally:
        if cp is not None:
            stop_cp(cp)
        shutil.rmtree(DATA_DIR, ignore_errors=True)

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("PASSED: certificates survive a cold bring-up, and are restored without a CA")
    return 0


if __name__ == "__main__":
    sys.exit(main())
