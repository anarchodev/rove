#!/usr/bin/env python3
"""Certificate distribution + convergence-check smoke (rove#545;
scripts/ops/rove-cert-deploy.sh).

The renewal path is a chain of parts that each look fine alone: lego writes a
pair, a script copies it to every node, the front reloads it, and a check
asserts the fleet agrees. What went wrong in production was the SEAM — the
copy landed on two nodes of three, every node reported healthy, and nothing
asked whether they served the same certificate. So this drives the REAL
distribution script against a REAL front rather than asserting the halves
separately.

`ROVE_CERT_PORT` and `HOME` are what make that possible unprivileged: the
script installs into `$HOME/.rove/tls` when it runs as the deploy user, and
checks :443 unless told otherwise.

Proof legs:
  A. the script installs the source pair and the front serves it — script →
     disk → reload → handshake, end to end.
  B. it reports convergence, and the private key lands 0600.
  C. `--verify-only` against a certificate nobody serves FAILS, and says
     which target is behind. A check that cannot fail is not a check.

Build first: `zig build rewind-front`
"""

import hashlib
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from smoke_ports import alloc_port  # noqa: E402
from v2_topology import spawn_front, FRONT_BIN  # noqa: E402

PF = alloc_port()
DEAD_CP = alloc_port()

HERE = os.path.dirname(os.path.abspath(__file__))
DEPLOY_SH = os.path.join(HERE, "..", "ops", "rove-cert-deploy.sh")

procs = []


def gen_cert(tmp, cn, days):
    cert = os.path.join(tmp, f"{cn}.cert.pem")
    key = os.path.join(tmp, f"{cn}.key.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", cert, "-days", str(days),
         "-subj", f"/CN={cn}", "-addext", f"subjectAltName=DNS:{cn}"],
        check=True, capture_output=True,
    )
    return cert, key


def sha256(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()[:16]


def served_cn():
    p = subprocess.run(
        ["openssl", "s_client", "-connect", f"127.0.0.1:{PF}", "-alpn", "h2"],
        input="", capture_output=True, text=True, timeout=10,
    )
    for line in p.stdout.splitlines():
        s = line.strip()
        if s.startswith("subject="):
            return s.split("CN", 1)[-1].lstrip(" =").strip()
    return ""


def run_deploy(home, cert, key, *args, timeout_s=None):
    env = dict(os.environ)
    env.update({
        "HOME": home,
        "ROVE_DEPLOY_USER": subprocess.run(["id", "-un"], capture_output=True,
                                           text=True).stdout.strip(),
        "ROVE_CERT_SRC": cert,
        "ROVE_KEY_SRC": key,
        "ROVE_CERT_PEERS": "",          # local front only
        "ROVE_CERT_PORT": str(PF),
        "ROVE_CERT_VERIFY_TIMEOUT": str(timeout_s if timeout_s else 30),
    })
    return subprocess.run(["bash", DEPLOY_SH, *args], env=env,
                          capture_output=True, text=True, timeout=180)


def main():
    if not os.path.exists(FRONT_BIN):
        raise SystemExit(f"{FRONT_BIN} not found — run `zig build rewind-front`")

    tmp = f"/tmp/front-cert-deploy-{os.getpid()}"
    home = os.path.join(tmp, "home")
    tls_dir = os.path.join(home, ".rove", "tls")
    os.makedirs(tls_dir, exist_ok=True)
    live_cert = os.path.join(tls_dir, "platform.crt")
    live_key = os.path.join(tls_dir, "platform.key")

    failures = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}, want {want!r}")

    try:
        print("setup: a booted pair, a renewed pair, and one nobody serves")
        v1_cert, v1_key = gen_cert(tmp, "deployed-v1", 5)
        v2_cert, v2_key = gen_cert(tmp, "deployed-v2", 20)
        v3_cert, v3_key = gen_cert(tmp, "never-served", 40)
        shutil.copyfile(v1_cert, live_cert)
        shutil.copyfile(v1_key, live_key)

        print(f"boot: TLS front on :{PF} reading {tls_dir}")
        spawn_front(
            procs, PF, f"http://127.0.0.1:{DEAD_CP}", log_dir=tmp,
            extra_env={
                "REWIND_TLS_CERT": live_cert,
                "REWIND_TLS_KEY": live_key,
                "REWIND_HTTP_PORT": "0",
                "REWIND_CERT_SYNC_MS": "400",
                "REWIND_FRONT_METRICS_PORT": "0",
            },
        )
        check("serving the booted cert", served_cn(), "deployed-v1")

        # ── A + B. distribute a renewal, end to end ───────────────────
        print("leg A/B: the script installs the renewal and the front serves it")
        r = run_deploy(home, v2_cert, v2_key)
        print("  " + "\n  ".join((r.stdout + r.stderr).strip().splitlines()[-4:]))
        check("deploy exit", r.returncode, 0)
        check("reports convergence", "all fronts converged" in r.stdout, True)
        check("front serves the distributed cert", served_cn(), "deployed-v2")
        check("installed cert is the source (sha256)",
              sha256(live_cert), sha256(v2_cert))
        check("private key mode", oct(os.stat(live_key).st_mode & 0o777), "0o600")

        # ── C. the check can fail ─────────────────────────────────────
        print("leg C: --verify-only against a cert nobody serves must FAIL")
        r = run_deploy(home, v3_cert, v3_key, "--verify-only", timeout_s=5)
        check("verify-only exit is nonzero", r.returncode != 0, True)
        check("names the lagging target", "127.0.0.1 serves notAfter=" in r.stderr, True)
        check("did not touch the live pair", served_cn(), "deployed-v2")
    finally:
        for p in procs:
            if p.poll() is None:
                p.terminate()
        for p in procs:
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print(f"\nFAILED ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nfront cert deploy smoke: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
