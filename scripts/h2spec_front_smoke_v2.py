#!/usr/bin/env python3
"""HTTP/2 conformance smoke — run `h2spec` against the front door.

Motivation: getting the front's graceful connection close (GOAWAY on idle
reap, GOAWAY on shutdown — commits `600d941`/`1c4a409`) exactly right is
fiddly, and unit tests can't exercise the wire-level frame sequencing the way
a conformance suite can. `h2spec` (https://github.com/summerwind/h2spec) is
the standard HTTP/2 conformance tester; this points it at a live front door.

Why this works without TLS: the front in h2c mode (no `REWIND_TLS_CERT`/
`REWIND_TLS_KEY` — exactly how `V2Cluster` spawns it) speaks plaintext HTTP/2
prior-knowledge, which is `h2spec`'s default transport (no `-t`). So we point
`h2spec` straight at the front port.

Why `-h h2spec.localhost`: `h2spec` derives `:authority` from its `-h` connect
target (there is no separate authority flag), so every request arrives with
`:authority: h2spec.localhost[:port]`. glibc resolves any `*.localhost` to
loopback (RFC 6761), and the front binds IPv4 `0.0.0.0`, so the dial lands on
127.0.0.1. The worker maps host→tenant by stripping the `localhost` public
suffix, so `h2spec.localhost` routes to tenant `h2spec` with no custom-domain
alias needed — giving `h2spec` a real, routable 200 backend, which the
request-processing conformance cases (not just the pure frame-error cases)
need. (A bare IP `:authority` would 404 at the worker: no suffix, no alias.)

Usage:
    set -a; . ./.env; set +a            # S3 env (V2 has no fs blob backend)
    zig build rewind rewind-cp rewind-front files-server-v2
    python3 scripts/h2spec_front_smoke_v2.py                 # full suite
    python3 scripts/h2spec_front_smoke_v2.py http2/6.8       # just GOAWAY
    python3 scripts/h2spec_front_smoke_v2.py http2/5.1 http2/6.8 generic/4

Any extra argv are passed through as h2spec spec selectors (empty = the full
generic + hpack + http2 suite). Returns nonzero if any h2spec case fails.

Needs `h2spec` on PATH (or at ~/.local/bin/h2spec or /tmp/h2spec). It is not
an apt package — install the upstream static binary:
    curl -sSL https://github.com/summerwind/h2spec/releases/download/v2.6.0/h2spec_linux_amd64.tar.gz \\
      | tar xz -C ~/.local/bin h2spec
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

# Always-200 handler: h2spec hits GET / (and a few other shapes) and only
# cares about the protocol behavior, but a routable 200 keeps the
# request-processing cases honest. Conventional default export — no rpc shim.
HANDLER = 'export default function () { return "h2spec-ok\\n"; }\n'

# h2spec's own per-case timeout. The front proxies to the worker, so a healthy
# response is sub-second; 5s gives slack without dragging out the (legitimately
# timing-based) connection-close cases.
H2SPEC_TIMEOUT_S = "5"

SUMMARY_RE = re.compile(r"(\d+)\s+tests?,\s+(\d+)\s+passed,\s+(\d+)\s+skipped,\s+(\d+)\s+failed")


def find_h2spec() -> str | None:
    on_path = shutil.which("h2spec")
    if on_path:
        return on_path
    for cand in (Path.home() / ".local/bin/h2spec", Path("/tmp/h2spec")):
        if cand.exists() and os.access(cand, os.X_OK):
            return str(cand)
    return None


def main() -> int:
    h2spec = find_h2spec()
    if not h2spec:
        print("h2spec not found (not on PATH, ~/.local/bin, or /tmp).")
        print("It is NOT an apt package — install the upstream static binary:")
        print("  mkdir -p ~/.local/bin && curl -sSL \\")
        print("    https://github.com/summerwind/h2spec/releases/download/"
              "v2.6.0/h2spec_linux_amd64.tar.gz \\")
        print("    | tar xz -C ~/.local/bin h2spec")
        return 2

    specs = sys.argv[1:]  # spec selectors; empty = full suite
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("h2spec", nodes=1) as c:
        host = c.host_for("h2spec")  # h2spec.localhost — resolved by suffix-strip
        print(f"step 1: provision tenant 'h2spec' (host {host})")
        r = c.provision("h2spec")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy a trivial always-200 handler")
        dep = None
        try:
            dep = c.deploy_handlers("h2spec", {"index.mjs": HANDLER})
            check("deploy → dep_id", bool(dep), f"dep_id={dep}")
        except RuntimeError as e:
            check("deploy", False, str(e))

        print(f"step 3: wait for the front to serve GET / on host {host}")
        ready = None
        deadline = time.time() + 25.0
        while time.time() < deadline:
            rr = c.get("h2spec", "/", host=host)
            if rr.status == 200 and "h2spec-ok" in rr.body:
                ready = rr
                break
            time.sleep(0.4)
        check(f"front serves GET / on {host} → 200", ready is not None,
              "" if ready else f"last={getattr(rr, 'status', None)} {getattr(rr, 'body', '')!r}")
        if ready is None:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "route",
                                  "resolve", "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        sel = " ".join(specs) if specs else "[full suite]"
        print(f"step 4: run h2spec against the front door :{c.front_port}  sections={sel}")
        cmd = [h2spec, "-h", host, "-p", str(c.front_port),
               "-o", H2SPEC_TIMEOUT_S, *specs]
        print("  $ " + " ".join(cmd))
        proc = subprocess.run(cmd, capture_output=True, text=True)
        out = (proc.stdout or "") + (proc.stderr or "")
        for line in out.splitlines():
            print("  | " + line)

        m = SUMMARY_RE.search(out)
        if not m:
            check("h2spec produced a result summary", False,
                  f"exit={proc.returncode}; no 'N tests, ...' line")
        else:
            total, passed, skipped, failed = (int(x) for x in m.groups())
            print(f"\n  h2spec: {total} tests, {passed} passed, "
                  f"{skipped} skipped, {failed} failed")
            check("h2spec: 0 failures", failed == 0,
                  f"{failed} failing case(s) — see the × lines above")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS h2spec front smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
