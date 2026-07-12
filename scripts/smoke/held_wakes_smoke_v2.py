#!/usr/bin/env python3
"""`request.activation.wakes[]` is surfaced on a HELD (buffered `next()`)
resume — not just the streaming path (issue #8).

A buffered `after.kv` chain (holds the socket with `next()`, no `stream.start`)
used to receive an EMPTY `wakes[]` on resume — the worker drained + freed the
match ring without surfacing it. This drives that exact path and asserts the
matched entry rides along: `{ kind:"kv", key, op:"put", firedAt:<ms> }`, with
`op` the full word and `firedAt` in MILLISECONDS (the one JS-facing encoding).

Held POST `/held` (arms `after.kv("hw/")`, returns `next()`), a second request
writes `hw/flag` ~0.5s later, the wake resumes `onWake`, which echoes the ring.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import concurrent.futures
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

PREFIX = "hw/"
WRITE_DELAY_S = 0.5

# HELD buffered chain — no `stream.start()`, so the resume runs through
# worker_drain (the path that dropped wakes[] before #8). `onWake` echoes the
# surfaced match ring so the smoke can assert its contents + encoding.
HELD_SRC = """\
export default function () {
    kv.get("hw/flag");                       // read baseline → the write is 'after'
    after.kv("hw/", { on: "onWake" });
    return next({ prefix: "hw/" });          // held BUFFERED (no stream.start)
}

export function onWake() {
    const a = request.activation;
    response.status = 200;
    return JSON.stringify({
        wakes: a.wakes,
        lost_oldest: a.overflow ? a.overflow.lost_oldest : null,
    });
}
"""

WRITEKV_SRC = """\
export default function () {
    const body = JSON.parse(request.text || "{}");
    if (!body.key) { response.status = 400; return "missing key"; }
    kv.set(body.key, body.value ?? "");
    response.status = 204;
    return "";
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("heldwakes", nodes=1) as c:
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(READY_SRC),
                "held/index.mjs": HELD_SRC,
                "writekv/index.mjs": WRITEKV_SRC,
            })
            check("deploy → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("deployment loaded", ready.status == 200, f"got {ready.status} {ready.body!r}")
        if failures:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        def held():
            r = c.request("acme", "/held", method="POST",
                          headers={"content-type": "application/json"},
                          data="{}", timeout=30.0)
            return r.status, r.body

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            fut = pool.submit(held)
            time.sleep(WRITE_DELAY_S)  # let the inbound hop park before writing
            w = c.node_request("/writekv", method="POST", host=c.host_for("acme"),
                               headers={"content-type": "application/json"},
                               data=json.dumps({"key": PREFIX + "flag", "value": "hello"}))
            check("trigger writekv → 204", w.status == 204, f"got {w.status} {w.body!r}")
            status, body = fut.result(timeout=35.0)

        check("held resume → 200", status == 200, f"got {status} {body!r}")
        if status != 200:
            c.dump_node_log(grep=["kv", "wake", "park", "resume", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        try:
            data = json.loads(body)
            wakes = data.get("wakes")
        except Exception as e:  # noqa: BLE001
            check("held resume body is JSON", False, f"{e}: {body!r}")
            print("\nFAILURES:", failures)
            return 1

        # The core #8 assertion: the ring is surfaced, NOT an empty array.
        check("wakes[] surfaced (non-empty)", isinstance(wakes, list) and len(wakes) >= 1,
              f"wakes={wakes!r}")
        if wakes:
            w0 = wakes[0]
            check("wakes[0].kind == 'kv'", w0.get("kind") == "kv", f"got {w0!r}")
            check("wakes[0].key == 'hw/flag'", w0.get("key") == "hw/flag", f"got {w0.get('key')!r}")
            check("wakes[0].op == 'put' (full word)", w0.get("op") == "put", f"got {w0.get('op')!r}")
            fa = w0.get("firedAt")
            # ms-since-epoch is ~1.75e12 (13 digits); ns would be ~1.75e18.
            check("wakes[0].firedAt in ms (not ns)",
                  isinstance(fa, int) and 1_000_000_000_000 < fa < 10_000_000_000_000,
                  f"firedAt={fa!r}")
        check("overflow.lost_oldest == 0", data.get("lost_oldest") == 0,
              f"got {data.get('lost_oldest')!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS held wakes[] smoke (v2): buffered next() resume surfaces the "
          "match ring (kind/key/op=put/firedAt=ms)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
