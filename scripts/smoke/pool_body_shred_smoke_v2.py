#!/usr/bin/env python3
"""Per-identity erasure reaches a request body in the cross-tenant pool.

A body over the inline cap is spilled to `_pool/` BEFORE any handler code
runs, into a content-addressed object shared with other tenants — so it
cannot be sealed where a kv value is. It is sealed as an envelope instead
(`src/keyring/body_seal.zig`): under a data key minted for it alone, whose
wrap rides the tape entry and moves onto the identity the handler names
when the handler returns. Destroying the identity destroys the only copy
of the data key, and the untouched pool bytes become unreadable.

The proof is a CONTRAST, because either half alone proves nothing:

  * a body posted under an identity reads back byte-exact through the
    worker's logs door — so the wrap was moved and the identity key opens it;
  * a body posted with NO identity reads back too, wrapped for the tenant;
  * destroy the identity: the first body now answers 410 `erased` through
    the door, while the anonymous one STILL reads back. Without the second,
    "410 after the destroy" is equally consistent with the destroy (or a
    broken door) taking out every body the tenant ever sent — the tenant
    granularity this whole mechanism exists to improve on.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import base64
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

# Hand-composed default: `shredKey` is a capability on the activation
# object, which the rpc_wrap recipe does not forward (see
# shred_serve_gate_smoke_v2.py). Each fn READS the body — without a read,
# read-taping elides the trigger_payload entry and there is nothing to
# resolve.
SRC = (
    'export default function ({ shredKey }) {\n'
    '  const fn = ((request.query || "").match(/fn=([^&]+)/) || [])[1];\n'
    '  if (fn === "post") {\n'
    '    shredKey("u_body");\n'
    '    return "len:" + (request.text || "").length;\n'
    '  }\n'
    '  if (fn === "anon") return "len:" + (request.text || "").length;\n'
    '  if (fn === "erase") { shredKey.destroy("u_body"); return "erased"; }\n'
    '  if (fn === "ready") return "ready";\n'
    '  response.status = 404;\n'
    '  return "no such fn: " + fn;\n'
    '}\n'
)

DOOR_SRC = r"""export default function ({ after, next }) {
    const rid = new URLSearchParams(request.query || "").get("rid") || "";
    after.fetch("http://rewind-logs.internal/v1/" + request.tenant + "/body/"
                + rid + "/trigger_payload/0");
    return next();
}
export function onFetchResult() {
    response.status = 200;
    return "status:" + (request.status || 0) + "\n" + (request.text || "");
}
"""

BIG_LEN = 64 * 1024


def _payload(n: int, seed: str) -> str:
    out, i = [], 0
    while sum(len(s) for s in out) < n:
        out.append(f"{seed}-{i:08d}-")
        i += 1
    return "".join(out)[:n]


def door_body(c, rid: str):
    """`/body/{rid}/trigger_payload/0` through the worker door → (status, text)."""
    r = c.request("acme", "/door?rid=" + rid, timeout=30.0)
    head, _, body = r.body.partition("\n")
    status = int(head.split(":", 1)[1]) if head.startswith("status:") else 0
    return status, body


def decoded(body: str) -> str:
    try:
        return base64.b64decode(json.loads(body).get("bytes_b64") or "").decode("utf-8", "replace")
    except (json.JSONDecodeError, ValueError):
        return ""


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    named = _payload(BIG_LEN, "named")
    anon = _payload(BIG_LEN, "anon")

    print("=== pool-body shred (a spilled body dies with its identity) ===")
    with V2Cluster.spawn("poolshred", nodes=1) as c:
        c.spawn_log_server(poll_interval_ms=200)
        c._ensure_admin_app()

        r = c.provision("acme")
        check("provision acme → 200/409", r.status in (200, 409), f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers("acme", {"index.mjs": SRC, "door/index.mjs": DOOR_SRC})
        except RuntimeError as e:
            check("deploy acme", False, str(e))
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        c.wait_for_handler("acme", "/?fn=ready", want_body="ready", timeout_s=45.0)

        print("step 1: post one large body under an identity, one with none")
        # The tenant's key pool fills in the background after provisioning,
        # and the hot path never waits on it — an identity bound before the
        # first refill lands fails (`PoolEmpty`). Retry until it binds.
        deadline = time.time() + 45.0
        while True:
            r = c.request("acme", "/?fn=post", method="POST", data=named, timeout=30.0)
            if r.status == 200 or time.time() > deadline or "PoolEmpty" not in r.body:
                break
            time.sleep(1.0)
        check("identity-bound POST → 200", r.status == 200 and r.body == f"len:{BIG_LEN}",
              f"got {r.status} {r.body[:80]!r}")
        r = c.request("acme", "/?fn=anon", method="POST", data=anon, timeout=30.0)
        check("anonymous POST → 200", r.status == 200 and r.body == f"len:{BIG_LEN}",
              f"got {r.status} {r.body[:80]!r}")

        print("step 2: find both records")
        ids: dict[str, str] = {}
        deadline = time.time() + 60.0
        while time.time() < deadline and len(ids) < 2:
            lr = c.log_get("acme/list?limit=50")
            if lr.status == 200:
                for rec in json.loads(lr.body).get("records", []):
                    if rec.get("method") != "POST" or rec.get("status") != 200:
                        continue
                    for fn in ("post", "anon"):
                        if f"fn={fn}" in (rec.get("path") or ""):
                            ids[fn] = rec.get("request_id")
            if len(ids) < 2:
                time.sleep(1.0)
        check("both POSTs indexed", len(ids) == 2, f"ids={ids}")
        if len(ids) < 2:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: both bodies read back through the door")
        status, body = door_body(c, ids["post"])
        check("identity-bound body → 200, byte-exact",
              status == 200 and decoded(body) == named, f"status={status} body={body[:160]!r}")
        status, body = door_body(c, ids["anon"])
        check("anonymous body → 200, byte-exact",
              status == 200 and decoded(body) == anon, f"status={status} body={body[:160]!r}")

        print("step 4: destroy the identity")
        r = c.request("acme", "/?fn=erase", timeout=30.0)
        check("destroy → 200", r.status == 200 and "erased" in r.body, f"got {r.status} {r.body!r}")

        # The destroy is durable through raft; the eviction follows, so poll.
        deadline = time.time() + 60.0
        status, body = 0, ""
        while time.time() < deadline:
            status, body = door_body(c, ids["post"])
            if status == 410:
                break
            time.sleep(1.0)
        check("the identity's body now answers 410 through the door", status == 410,
              f"status={status} body={body[:160]!r}")
        check("…naming the erasure, not a generic failure", '"erased"' in body,
              f"body={body[:160]!r}")
        check("…and none of the plaintext survives", named[:64] not in body)

        print("step 5: CONTROL — the anonymous body is untouched")
        status, body = door_body(c, ids["anon"])
        check("anonymous body STILL → 200, byte-exact",
              status == 200 and decoded(body) == anon,
              f"status={status} — destroying one identity reached a body it never named")

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — a spilled body died with its identity, and only that body.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
