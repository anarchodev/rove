#!/usr/bin/env python3
"""headers_first classic fallback (blob-storage-plan §3.5.1; docs/architecture/routing-and-ingress.md).

Every h2 body-carrying request now flows HEADERS-frame-early through
`request_receiving` → the worker's disposition point. For modules
WITHOUT `onHeaders` (every ordinary POST), the path is: probe (first
request per module fills the export cache) → classic buffering —
attach-in-place when the body already arrived, window-reopen +
re-dispatch when it's still streaming. A 3 MiB body cannot arrive in
one feed pass, so the buffer decision lands mid-stream and the
window-hold + consume arithmetic is on the hot path. The handler
sha256s the body; byte-exact against the local hash proves the whole
chain (including the >16 KB inbound coordinator gate). Plus the
onHeaders basics: early 401 from headers alone, accept-without-body,
GET → default export.

ASCII bodies — request.body is a JS string. Needs S3 env:
`set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import hashlib
import random
import string
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

HASH_SRC = """\
export default function () {
    const data = request.body || "";
    return crypto.sha256(data) + ":" + data.length;
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'

# onHeaders module: decides from headers alone — 401 without the magic
# header (body never accepted), 200 with it (still no body read).
ONHEADERS_SRC = """\
export function onHeaders() {
    if (!request.headers["x-upload-auth"]) {
        response.status = 401;
        return "unauthorized";
    }
    return "accepted:" + (request.body || "").length;
}
export default function () {
    return "default-ran";
}
"""


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    rng = random.Random(42)

    with V2Cluster.spawn("large-inbound", nodes=1) as c:
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status}")
        dep_id = c.deploy_handlers("acme", {
            "index.mjs": READY_SRC,
            "hash/index.mjs": HASH_SRC,
            "upload/index.mjs": ONHEADERS_SRC,
        })
        check("deploy", bool(dep_id))
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("loaded", ready.status == 200, f"got {ready.status} {ready.body!r}")

        for size in (1000, 64 * 1024, 3 * 1024 * 1024):
            body = "".join(rng.choices(string.ascii_letters + string.digits, k=size)).encode()
            want = hashlib.sha256(body).hexdigest()
            r = c.request("acme", "/hash", method="POST",
                          headers={"content-type": "application/octet-stream"},
                          data=body, timeout=60.0)
            check(f"POST {size}B → 200", r.status == 200, f"got {r.status} {r.body!r}")
            got = r.body.strip()
            check(f"{size}B byte-exact (sha256+len)", got == f"{want}:{size}",
                  f"want {want}:{size} got {got!r}")

        # onHeaders dispatch: 401 decided from headers alone — the 3 MiB
        # body is never accepted (response races the upload; ok either way
        # as long as status is 401 and it's fast).
        big = b"x" * (3 * 1024 * 1024)
        r = c.request("acme", "/upload", method="POST",
                      headers={"content-type": "application/octet-stream"},
                      data=big, timeout=60.0)
        check("onHeaders 401 (no auth header)", r.status == 401 and "unauthorized" in r.body,
              f"got {r.status} {r.body!r}")

        r = c.request("acme", "/upload", method="POST",
                      headers={"content-type": "application/octet-stream",
                               "x-upload-auth": "yes"},
                      data=big, timeout=60.0)
        check("onHeaders 200 (auth) — body never read", r.status == 200 and r.body == "accepted:0",
              f"got {r.status} {r.body!r}")

        # GET (no body) on the same module takes the default export —
        # onHeaders only fires for body-carrying requests.
        r = c.request("acme", "/upload", method="GET")
        check("GET → default export", r.status == 200 and r.body == "default-ran",
              f"got {r.status} {r.body!r}")

    if failures:
        print(f"\nFAILURES: {failures}")
        return 1
    print("\nPASS inbound-body smoke (v2): headers-first classic fallback byte-exact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
