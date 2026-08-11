#!/usr/bin/env python3
"""The kv-export door is not callable from handler code (rove#494).

`rewriteKvExport` (`src/js/worker.zig`) turns a Cmd at
`rove-kvexport.internal` into a content-addressed PUT flagged for the
tenant's UNMETERED `exports/` pool (rove#429). That flag is engine-set and
has no JS spelling — but the REWRITE was reachable by anything that could
name the URL, and `after.fetch` passes its URL straight through while
`.internal` hosts are exempt from the outbound gate rather than forbidden.

So a handler could call the door directly. The cursor is caller-chosen, and a
different cursor means a different page boundary, hence different bytes and a
different hash — so a loop over cursors minted a distinct unmetered object per
call and `max_stored_bytes` bounded nothing. Measured before the fix: 8
cursors over a ~12 KB store produced 8 distinct objects.

This smoke pins the refusal, plus the over-tightening control: an ordinary
internal door (`blob.*`) must stay reachable from handler code, since the
failure mode of a too-broad gate is silent — it reads as storage being broken
rather than as a policy being applied.

The supported export path has its own end-to-end coverage in
`kv_export_smoke_v2.py`; run both when touching this gate.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

TENANT = "acme"

HANDLER_SRC = r'''
export function handler() { return "ready"; }

export function seed() {
    for (let i = 0; i < 40; i++) kv.set("k/" + i, "v".repeat(256));
    return "seeded";
}

// Name the engine's export door directly, with the body its rewrite parses.
// The refusal is synchronous at the fetch native, so it lands as a throw here
// rather than as a failed transfer later.
export function probe(cursor) {
    try {
        after.fetch("http://rove-kvexport.internal/", {
            method: "POST",
            body: JSON.stringify({ id: "probe", cursor: cursor || "" }),
            on: "onres",
        });
    } catch (e) {
        return "refused:" + ((e && e.code) || String(e));
    }
    return next();
}

export function onres() {
    if (!request.done) return next();
    const p = (request.ctx && request.ctx.part) || request.ctx || {};
    return "reached:status=" + request.status + " ctx=" + JSON.stringify(p);
}

// The control: an ordinary internal door, reached the way customer code
// always reaches one. This must keep working — a gate that closed every
// `.internal` origin would look like a pass above and a broken product here.
export function storage() {
    const hash = blob.put("bytes", { contentType: "text/plain", on: "stored" });
    return "storage-ok:" + (hash ? "hashed" : "nohash");
}

export function stored() { return { status: 200 }; }
'''


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("expdoor", nodes=1) as c:
        r = c.provision(TENANT)
        check("provision → 200", r.status == 200, f"got {r.status}")
        try:
            c.deploy_handlers(TENANT, {"index.mjs": rpc_wrap(HANDLER_SRC)})
        except RuntimeError as e:
            check("deploy", False, str(e))
            print(f"FAILURES: {failures}")
            return 1
        ready = c.wait_for_handler(TENANT, "/?fn=handler", want_body="ready")
        check("deployment loaded", ready.status == 200, f"got {ready.status}")

        r = c.get(TENANT, "/?fn=seed")
        check("seed", "seeded" in r.body, f"got {r.body[:80]!r}")

        # ── the door is closed to handler code ───────────────────────────
        print("\nstep: a handler names the export door")
        for cur in ["", "k/1", "k/12"]:
            args = urllib.parse.quote(json.dumps([cur]))
            r = c.get(TENANT, f"/?fn=probe&args={args}")
            refused = "refused:door_forbidden" in r.body
            check(f"cursor={cur!r} refused as door_forbidden", refused,
                  f"got {r.body[:160]!r}")
            if "reached:" in r.body:
                print("      ^ the rewrite ran for a handler-issued fetch — "
                      "an unmetered object was just written")

        # ── and ordinary internal doors stay open ───────────────────────
        print("\nstep: an ordinary internal door (blob) from the same handler")
        r = c.get(TENANT, "/?fn=storage")
        check("blob door still reachable from handler code",
              "storage-ok:hashed" in r.body, f"got {r.status} {r.body[:160]!r}")

    print()
    if failures:
        print(f"FAILURES: {failures}")
        return 1
    print("PASS — the door is closed to handler code, ordinary doors are not")
    return 0


if __name__ == "__main__":
    sys.exit(main())
