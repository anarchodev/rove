#!/usr/bin/env python3
"""Does a REALISTIC tenant's traffic replay faithfully?

`interaction_digest_smoke_v2.py` proves the digest survives capture and that a
replay of a ONE-FILE handler recomputes it. Real tenants are route-modular: a
module per route, dispatched by path (`order/index.mjs`), each reading and
writing kv. That shape is the interesting one for replay, because an
engine-dispatched module never passes through the loader — so it leaves no
trace in the module tape, and every driver has to re-derive which module ran
from the request path (rove#253, rove#254).

(The other multi-file shape — one module importing a sibling — cannot be
deployed at all: rove#344.)

Every captured record is re-executed in the replay engine and its digest
compared to the one production folded. Digest agreement — not a matching status
— is the claim: two different executions can share a status, so a status check
would call a divergence a pass.

Ports: the shared V2Cluster allocation (do not run two smokes at once). Needs a
rewind-apps checkout (REWIND_APPS_DIR, default: the `web` submodule) for the replay
shell, and S3 credentials: `set -a; . ./.env; set +a`.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke_lib_v2 import V2Cluster, rpc_wrap, APPS_DIR  # noqa: E402

TENANT = "shopdemo"

# The shared helper both route modules import — the shape rove#344 was about.
LIB_SRC = """
export const PRICES = { mug: 900, shirt: 2400, sticker: 300 };
export const fmt = (c) => "$" + (c / 100).toFixed(2);
"""

# Relative to each module's OWN directory, as ES resolution requires: the
# entry sits beside lib.mjs, the /order route module a directory below it.
INDEX_SRC = 'import { PRICES, fmt } from "./lib.mjs";\n' + """
export function catalogue() {
  const items = ["mug", "shirt", "sticker"];
  return { items: items.map((i) => ({ item: i, price: fmt(PRICES[i]) })) };
}
"""

# A second dispatchable module, reached at /order. The engine dispatches it by
# path — it is never imported, so it never passes through the module loader.
ORDER_SRC = 'import { PRICES, fmt } from "../lib.mjs";\n' + """
// Reads, then writes, then answers. The digest folds the read (including
// whether the key was PRESENT), the write, and the response, so a replay that
// took a different branch cannot match by accident.
export function place() {
  const q = request.query || "";
  const item = q.includes("item=")
    ? decodeURIComponent(q.split("item=")[1].split("&")[0])
    : "mug";
  const soldKey = "sold/" + item;
  const prior = kv.get(soldKey);
  const count = (prior === null ? 0 : parseInt(prior, 10)) + 1;
  kv.set(soldKey, String(count));
  return { item: item, price: fmt(PRICES[item] ?? 0), sold: count };
}
"""


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    apps = str(APPS_DIR)
    checker = os.path.join(apps, "e2e", "replay-digest-check.mjs")
    if not os.path.exists(checker):
        print(f"SKIP — no rewind-apps checkout at {apps} (set REWIND_APPS_DIR)")
        return 77  # run_all.SKIP_RC — reported "skip", never "pass"

    with V2Cluster.spawn("demoreplay", nodes=1) as c:
        c.spawn_log_server(poll_interval_ms=200)
        print("step 1: provision + deploy a multi-module tenant")
        r = c.provision(TENANT)
        check("provision → 200/409", r.status in (200, 409), f"got {r.status} {r.body!r}")
        dep = c.deploy_handlers(TENANT, {
            "index.mjs": rpc_wrap(INDEX_SRC),
            "order/index.mjs": rpc_wrap(ORDER_SRC),
            "lib.mjs": LIB_SRC,
        })
        check("deploy → dep_id", bool(dep), f"dep_id={dep}")

        print("step 2: drive traffic — several paths, a repeat, and a cold key")
        c.wait_for_handler(TENANT, "/?fn=catalogue", want_status=200)
        calls = [
            "/?fn=catalogue",
            "/order?fn=place&item=mug",
            "/order?fn=place&item=mug",   # same call again: now the key EXISTS
            "/order?fn=place&item=sticker",
            "/order?fn=place",            # defaulted parameter
        ]
        for path in calls:
            r = c.get(TENANT, path)
            if r.status != 200:
                check(f"GET {path}", False, f"got {r.status} {r.body[:120]!r}")
        # Records land via the log batch; give the batch a moment to flush.
        time.sleep(3)

        print("step 3: every captured record replays to the SAME digest")
        listing = json.loads(c.log_get(f"{TENANT}/list?limit=50", timeout=20.0).body)
        records = listing.get("records", [])
        check("records were captured", len(records) >= len(calls),
              f"got {len(records)} for {len(calls)} requests")

        # A request that arrived before the deployment loaded (503
        # `no_deployment`) ran no handler, so it has no interactions to fold and
        # no digest — null there is the honest answer, not a gap. Excluded by
        # OUTCOME rather than by a null digest, so a record that should have
        # been digested and wasn't still fails.
        NO_EXECUTION = {"no_deployment"}
        replayed_ok, unverified, skipped, diverged = 0, 0, 0, []
        with tempfile.TemporaryDirectory() as td:
            idx_path = os.path.join(td, "index.mjs")
            order_path = os.path.join(td, "order.mjs")
            lib_path = os.path.join(td, "lib.mjs")
            with open(idx_path, "w") as f:
                f.write(rpc_wrap(INDEX_SRC))
            with open(order_path, "w") as f:
                f.write(rpc_wrap(ORDER_SRC))
            with open(lib_path, "w") as f:
                f.write(LIB_SRC)

            for rec in records:
                rid = rec.get("request_id")
                full = json.loads(c.log_get(f"{TENANT}/show/{rid}", timeout=20.0).body)
                full = full.get("record", full)
                captured = (full.get("tapes") or {}).get("interaction_digest")
                label = f"{full.get('method')} {full.get('path')}"
                if full.get("outcome") in NO_EXECUTION:
                    skipped += 1
                    print(f"    skipped (no handler ran): {label} "
                          f"status={full.get('status')} outcome={full.get('outcome')!r}")
                    continue
                rec_path = os.path.join(td, "record.json")
                with open(rec_path, "w") as f:
                    json.dump(full, f)
                # Which module ran is the worker's dispatch decision and is not
                # in the record (rove#254), so the driver re-derives it from the
                # path the same way the worker does — the duplication that issue
                # is about.
                is_order = (full.get("path") or "").startswith("/order")
                entry = order_path if is_order else idx_path
                entry_path = "order/index.mjs" if is_order else "index.mjs"
                proc = subprocess.run(
                    ["node", checker, rec_path, entry,
                     f"--entry-path={entry_path}", f"lib.mjs={lib_path}"],
                    capture_output=True, text=True, timeout=180)
                line = (proc.stdout or "").strip().splitlines()[-1] if proc.stdout.strip() else "{}"
                try:
                    res = json.loads(line)
                except json.JSONDecodeError:
                    res = {"replayed": None,
                           "error": f"unparseable: {proc.stdout[:160]} {proc.stderr[:160]}"}
                if captured is None:
                    # A record whose handler DID run but carries no digest is
                    # unchecked beyond its status — never a pass.
                    unverified += 1
                    print(f"    unverified (handler ran, no digest): {label} "
                          f"status={full.get('status')} outcome={full.get('outcome')!r}")
                elif res.get("replayed") == captured:
                    replayed_ok += 1
                    print(f"    ok {label} → {captured}")
                else:
                    diverged.append((label, captured, res))
                    print(f"    DIVERGED {label}: captured={captured} "
                          f"replayed={res.get('replayed')} {res.get('error') or ''}")
                    for el in (res.get("effects") or []):
                        print(f"        replay folded: {el}")

        print(f"    {replayed_ok} agreed, {len(diverged)} diverged, "
              f"{unverified} unverified, {skipped} skipped (no handler ran)")
        check("every executed record replayed to its captured digest", not diverged,
              f"{len(diverged)} diverged, {replayed_ok} agreed")
        check("every executed record carried a digest", unverified == 0,
              f"{unverified} record(s) ran a handler but carried no digest")
        check("the run actually verified something", replayed_ok >= len(calls) - 1,
              f"only {replayed_ok} record(s) verified for {len(calls)} requests")

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("PASSED: a multi-module tenant's traffic replays to production's digest")
    return 0


if __name__ == "__main__":
    sys.exit(main())
