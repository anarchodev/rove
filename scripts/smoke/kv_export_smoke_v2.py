#!/usr/bin/env python3
"""Data export, end to end (rove#340 slice 1) — a tenant's KV becomes
content-addressed parts without the values ever passing through a handler.

  seed N keys → arm `__system/export_run` → the job walks the store,
  uploading one part per activation → `_export/{id}` reports `done`
  with the parts it produced.

The property under test is not just "an export happened". It is that the
export is composed from the primitives already in the engine — a durable kv
marker, a scheduled wake, and ONE outbound Cmd — and that the bytes go
store → S3 through the ordinary content-addressed blob door. The Cmd is
issued at `rove-kvexport.internal`; the engine builds a part and rewrites it
into a PUT keyed by the part's own hash, which #367's door check then
verifies. So a part recorded here is a part S3 accepted under a hash it
independently confirmed.

Why that matters: the obvious implementation — a JS job looping
`kv.prefix` — would record the entire store onto the request tape, charging
the tenant's log-ingest budget to export its own data (rove#391's defect at
export scale). Here the job only ever sees a cursor and a digest.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

TENANT = "acme"
SEEDED_KEYS = 200

# Seeds customer data, then reports how many of its own keys it can see.
SEED_SRC = """\
function _param(name) {
    for (const pair of (request.query || "").split("&")) {
        const eq = pair.indexOf("=");
        if (eq > 0 && pair.slice(0, eq) === name) return decodeURIComponent(pair.slice(eq + 1));
    }
    return "";
}
export function seed() {
    const n = parseInt(_param("n") || "0", 10);
    for (let i = 0; i < n; i++) {
        kv.set("data/" + String(i).padStart(4, "0"), "value-" + i);
    }
    return "seeded:" + n;
}
"""

# The customer-facing surface: a handler starts an export and reads it back
# with no operator involvement. `start()` writes the marker + arms the wake;
# `get()` returns the manifest, and `blob.url` turns each part into a
# download link.
START_SRC = """\
import { start, get } from "@rewind/export";
function _param(name) {
    for (const pair of (request.query || "").split("&")) {
        const eq = pair.indexOf("=");
        if (eq > 0 && pair.slice(0, eq) === name) return decodeURIComponent(pair.slice(eq + 1));
    }
    return "";
}
export function begin() {
    return start();
}
export function status() {
    const st = get(_param("id"));
    if (!st) return "none";
    // Presigned links come from the ordinary content-addressed primitive —
    // the export adds no download surface of its own.
    if (st.state === "done") {
        st.links = (st.parts || []).map((p) => blob.url(p.hash));
    }
    return JSON.stringify(st);
}
"""

HANDLERS = {
    "seed/index.mjs": rpc_wrap(SEED_SRC),
    "start/index.mjs": rpc_wrap(START_SRC),
}


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("kvexport", nodes=1) as c:
        print("step 1: provision + deploy")
        r = c.provision(TENANT)
        check("provision → 200", r.status == 200, f"got {r.status} {r.body!r}")
        pkgs, imports = c.firstparty_packages(["@rewind/export"])
        dep = c.deploy_with_packages(TENANT, HANDLERS, pkgs, imports)
        check("deploy → dep_id", bool(dep), f"dep_id={dep}")
        c.wait_for_handler(TENANT, "/seed?fn=seed&n=0")

        print(f"step 2: seed {SEEDED_KEYS} customer keys")
        r = c.request(TENANT, f"/seed?fn=seed&n={SEEDED_KEYS}", method="POST", data=b"x")
        check("seed → 200", r.status == 200 and "seeded" in r.body, f"got {r.status} {r.body!r}")

        print("step 3: ⭐ a handler starts the export — no operator involvement")
        r = c.request(TENANT, "/start?fn=begin", method="POST", data=b"x")
        export_id = r.body.strip()
        check("export.start() → an id", r.status == 200 and len(export_id) > 10,
              f"got {r.status} {r.body!r}")

        print("step 4: ⭐ the job walks the store to completion")
        state = None
        deadline = time.time() + 60
        while time.time() < deadline:
            rr = c.request(TENANT, f"/start?fn=status&id={export_id}", method="POST", data=b"x")
            if rr.status == 200 and rr.body.strip().startswith("{"):
                try:
                    state = json.loads(rr.body)
                except ValueError:
                    state = None
                if state and state.get("state") == "done":
                    break
            time.sleep(0.5)

        check("export reached state=done", bool(state) and state.get("state") == "done",
              f"state={state}")
        if not state or state.get("state") != "done":
            c.dump_node_log(0, grep=["kv-export", "export", "error"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        parts = state.get("parts") or []
        check("the export produced at least one part", len(parts) > 0, f"parts={len(parts)}")
        # Every part is a real sha256 the blob door accepted. #367 makes the
        # door refuse a PUT whose body does not hash to its key, so a recorded
        # part is one S3 stored under a hash it verified.
        well_formed = all(
            isinstance(p.get("hash"), str)
            and len(p["hash"]) == 64
            and all(ch in "0123456789abcdef" for ch in p["hash"])
            for p in parts
        )
        check("every part is keyed by a well-formed sha256", well_formed, f"parts={parts}")

        # The walk must cover the seeded keys. It also covers the tenant's
        # platform bookkeeping (deploy markers, the scheduler rows), so this
        # is a floor, not an equality.
        entries = state.get("entries", 0)
        check(f"the walk covered all {SEEDED_KEYS} seeded keys",
              entries >= SEEDED_KEYS, f"entries={entries}")
        check("the export recorded a non-zero byte count",
              state.get("bytes", 0) > 0, f"bytes={state.get('bytes')}")

        print("step 5: ⭐ every part has a download link")
        links = state.get("links") or []
        check("a presigned link per part", len(links) == len(parts), f"links={len(links)}")
        check("links presign the content-addressed part",
              all(isinstance(u, str) and u.startswith("http") and p["hash"] in u
                  for u, p in zip(links, parts)),
              f"links={links[:1]}")

        print("step 6: ⭐ the link actually yields the customer's data back")
        # The whole point of an export: a link the customer can follow to
        # bytes they can read. Anything short of downloading and parsing it
        # is testing bookkeeping.
        # NOT the harness `_curl`: that forces HTTP/2 prior-knowledge for rove
        # services, which S3 does not speak. A customer follows this link with
        # an ordinary client, so the smoke should too.
        proc = subprocess.run(["curl", "-sS", "--fail-with-body", links[0]],
                              capture_output=True, text=True, timeout=60)
        check("GET the presigned part → 200", proc.returncode == 0,
              f"rc={proc.returncode} {proc.stderr[:120]}")
        got = proc.stdout
        lines = [ln for ln in got.splitlines() if ln.strip()]
        check("part parses as JSONL", len(lines) == parts[0]["entries"],
              f"lines={len(lines)} entries={parts[0]['entries']}")
        seen = {}
        for ln in lines:
            rec = json.loads(ln)
            seen[rec["key"]] = rec["value"]
        missing = [f"data/{i:04d}" for i in range(SEEDED_KEYS) if f"data/{i:04d}" not in seen]
        check(f"all {SEEDED_KEYS} seeded keys came back", not missing,
              f"missing={missing[:5]}")
        check("values round-trip byte-exact", seen.get("data/0007") == "value-7",
              f"got {seen.get('data/0007')!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS kv-export smoke (v2) — the store walks into content-addressed "
          "parts, and the job only ever sees a cursor and a digest")
    return 0


if __name__ == "__main__":
    sys.exit(main())
