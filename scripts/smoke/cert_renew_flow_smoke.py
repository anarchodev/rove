#!/usr/bin/env python3
"""Renewal-flow smoke (rove#545; scripts/ops/rove-cert-renew.sh).

What this covers is the DECISION the renew script makes after the ACME client
returns: distribute, or do nothing. A daily timer means the overwhelming
majority of runs are no-ops, so "lego declined the renewal" must not restart
the distribution-and-verification cycle — and the one run that does produce
new bytes must never be mistaken for one of them.

`lego` is STUBBED here, which is the honest limit of this test: it exercises
the script's control flow, not the ACME client or DNS-01. The real client is
proven once, by hand, by the staging dry run in the renewal runbook (in
rewind-infra) before the first production issuance — a stub cannot tell you
your DNS token has the wrong zone scope.

Proof legs:
  A. a wildcard-first SAN list is REFUSED — lego names its files after the
     first entry and sanitizes `*` to `_`, so it would hide the lineage
     under a path the renewal never finds again.
  B. first issuance (no cert on disk) → distribution runs.
  C. lego declines (bytes unchanged) → distribution does NOT run.
  D. a renewal that changes the bytes → distribution runs, with the new pair
     handed over as ROVE_CERT_SRC/ROVE_KEY_SRC.
"""

import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RENEW_SH = os.path.join(HERE, "..", "ops", "rove-cert-renew.sh")

LEGO_STUB = """#!/usr/bin/env bash
# Stub ACME client: writes the PEM named by $STUB_CERT into the lineage the
# real lego would, or exits 0 writing nothing when $STUB_DECLINE is set.
path=""; args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  [ "${args[$i]}" = "--path" ] && path="${args[$((i+1))]}"
done
[ -n "${STUB_DECLINE:-}" ] && { echo "stub: no renewal needed"; exit 0; }
mkdir -p "$path/certificates"
cp "$STUB_CERT" "$path/certificates/$STUB_NAME.crt"
cp "$STUB_KEY"  "$path/certificates/$STUB_NAME.key"
echo "stub: wrote $STUB_NAME"
"""

HOOK_STUB = """#!/usr/bin/env bash
# Stub deploy hook: records that it ran, and with which source pair.
echo "$ROVE_CERT_SRC|$ROVE_KEY_SRC" >> "$HOOK_LOG"
echo "stub hook: distributed"
"""


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


def write_exec(path, body):
    with open(path, "w") as f:
        f.write(body)
    os.chmod(path, 0o755)


def main():
    tmp = f"/tmp/cert-renew-flow-{os.getpid()}"
    binf = os.path.join(tmp, "bin")
    lego_path = os.path.join(tmp, "acme")
    os.makedirs(binf, exist_ok=True)
    hook_log = os.path.join(tmp, "hook.log")

    failures = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}, want {want!r}")

    def run(domains, cert, key, decline=False):
        env = dict(os.environ)
        env.update({
            "PATH": binf + os.pathsep + os.environ["PATH"],
            "ROVE_CERT_DOMAINS": domains,
            "ACME_EMAIL": "ops@example.test",
            "LEGO_PATH": lego_path,
            "DNS_PROVIDER": "cloudflare",
            "ROVE_CERT_DEPLOY_HOOK": os.path.join(binf, "hook.sh"),
            "HOOK_LOG": hook_log,
            "STUB_CERT": cert,
            "STUB_KEY": key,
            "STUB_NAME": domains.split()[0],
        })
        if decline:
            env["STUB_DECLINE"] = "1"
        return subprocess.run(["bash", RENEW_SH], env=env, capture_output=True,
                              text=True, timeout=60)

    def distributions():
        if not os.path.exists(hook_log):
            return []
        return [l for l in open(hook_log).read().splitlines() if l.strip()]

    try:
        write_exec(os.path.join(binf, "lego"), LEGO_STUB)
        write_exec(os.path.join(binf, "hook.sh"), HOOK_STUB)
        v1_cert, v1_key = gen_cert(tmp, "renewed-v1", 5)
        v2_cert, v2_key = gen_cert(tmp, "renewed-v2", 90)

        # ── A. the SAN order that would hide the lineage ──────────────
        print("leg A: a wildcard-first SAN list is refused")
        r = run("*.rewindjs.app rewindjs.app", v1_cert, v1_key)
        check("exit", r.returncode, 2)
        check("says why", "list the apex first" in r.stderr, True)
        check("nothing distributed", distributions(), [])

        # ── B. first issuance ─────────────────────────────────────────
        print("leg B: first issuance distributes")
        r = run("rewindjs.app *.rewindjs.app", v1_cert, v1_key)
        check("exit", r.returncode, 0)
        check("one distribution", len(distributions()), 1)
        check("handed the lineage pair", distributions()[-1],
              f"{lego_path}/certificates/rewindjs.app.crt|"
              f"{lego_path}/certificates/rewindjs.app.key")

        # ── C. the common case: nothing to do ─────────────────────────
        print("leg C: a declined renewal distributes nothing")
        r = run("rewindjs.app *.rewindjs.app", v1_cert, v1_key, decline=True)
        check("exit", r.returncode, 0)
        check("says unchanged", "unchanged" in r.stdout, True)
        check("still one distribution", len(distributions()), 1)

        # ── D. a real renewal ─────────────────────────────────────────
        print("leg D: new bytes distribute")
        r = run("rewindjs.app *.rewindjs.app", v2_cert, v2_key)
        check("exit", r.returncode, 0)
        check("two distributions", len(distributions()), 2)
        check("reports the new expiry", "new certificate, expires" in r.stdout, True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print(f"\nFAILED ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\ncert renew flow smoke: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
