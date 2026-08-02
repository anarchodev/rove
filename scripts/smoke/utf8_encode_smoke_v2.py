#!/usr/bin/env python3
"""TextEncoder/base64url/hash over non-ASCII — prod values.

The offline sim's TextEncoder was latin1-truncating; the fix gives it a real
UTF-8 codec. This smoke deploys the SAME handler as the `utf8encode` sim
fixture to the worker and asserts the worker produces the identical
authoritative UTF-8 (hex / base64url / sha256 / U+FFFD lone surrogate). Passing
both proves sim ≡ prod byte-for-byte, so `rewind test` is a faithful oracle for
internationalized apps.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
HANDLER = (REPO_ROOT / "src/replay/testdata/utf8encode/index.mjs").read_text()

EXPECT = {
    "hex": "68c3a96c6c6f20e282acf09f9a80",
    "b64": "aMOpbGxvIOKCrPCfmoA",
    "sha": "2033a60daf08c0f4d1c096929cbc3b340e8f45ce1211cf38582570e7c67c417c",
    "text": "héllo €🚀",
    # prod encodes a lone surrogate as 3-byte WTF-8 (not WHATWG U+FFFD)…
    "loneHex": "eda080",
    # …but DECODES malformed sequences to U+FFFD (65533) per bad byte.
    "decInvalidLead": [65, 65533, 66],
    "decIncomplete": [65, 65533],
    "decOverlong": [65533, 65533],
    "decSurrogate": [65533, 65533, 65533],
}


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("utf8enc", nodes=1) as c:
        r = c.provision("acme")
        check("provision → 200", r.status == 200, f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers("acme", {"index.mjs": HANDLER})
            check("deploy", True)
        except RuntimeError as e:
            check("deploy", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        r = c.wait_for_handler("acme", "/", want_status=200, timeout_s=25.0)
        check("handler → 200", r.status == 200, f"got {r.status} {r.body!r}")
        if r.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        try:
            got = json.loads(r.body)
        except Exception as e:  # noqa: BLE001
            check("response is JSON", False, f"{e}: {r.body!r}")
            print("\nFAILURES:", failures)
            return 1

        for k, want in EXPECT.items():
            check(f"prod {k} matches authoritative UTF-8",
                  got.get(k) == want, f"got {got.get(k)!r} want {want!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS utf8 encode smoke (v2): worker TextEncoder/base64url/hash match "
          "the sim's utf8encode fixture (sim ≡ prod)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
