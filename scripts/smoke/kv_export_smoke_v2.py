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

The final arm is rove#429: the tenant is pinned AT its storage quota and must
still be able to export. Export parts go to an unmetered `exports/` pool, so
the customer most likely to be leaving — the one at their cap — is not the one
the feature refuses. Before that pool existed the parts landed in the metered
`app-blobs/`, the PUT was refused with a 507, and the job retried the same
part forever with the customer seeing only "running".

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
// An ORDINARY metered write, used as the control for the at-cap arm: it must
// be refused once the storage quota is pinned, or "the export still works at
// the cap" would be passing against a cap that never bit.
//
// `blob.put` is a Cmd — the handler returns before the PUT is attempted — so
// the response says nothing about whether it landed. The platform's record is
// the owed marker: cleared on success, kept and stamped on failure (the same
// observation `storage_cap_smoke_v2.py` makes).
export function store() {
    const hash = blob.put("payload-" + _param("k"));
    kv.set("h/" + _param("k"), hash);
    return hash;
}
export function marker() {
    const h = kv.get("h/" + _param("k"));
    if (!h) return "no-hash";
    const m = kv.get("_blob/owed/" + h);
    return m === null ? "cleared" : "owed " + m;
}
"""

# The customer-facing surface: a handler starts an export and reads it back
# with no operator involvement. `start()` writes the marker + arms the wake;
# `get()` returns the manifest, and `links()` turns each part into a
# download link.
START_SRC = """\
import { start, get, links } from "@rewind/export";
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
    // `links()`, not `blob.url`: parts live in the tenant's unmetered
    // `exports/` pool (rove#429), so signing them against `app-blobs/`
    // would mint URLs that 404.
    if (st.state === "done") {
        st.links = links(_param("id"));
    }
    return JSON.stringify(st);
}
// The code slice's pointer half: a bundle manifest entry's hash presigns
// out of the tenant's own file-blobs (rove#340).
export function fileurl() {
    return blob.fileUrl(_param("h"));
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

        print("step 6b: ⭐ the code slice — the bundle part IS the deploy "
              "manifest, and its hashes download (format 2)")
        bundle_parts = [p for p in parts if p.get("kind") == "bundle"]
        check("exactly one bundle part (this tenant HAS a deployment)",
              len(bundle_parts) == 1, f"parts={parts}")
        check("the marker records which deployment the slice captured",
              isinstance((state.get("bundle") or {}).get("dep_id"), str)
              and len(state["bundle"]["dep_id"]) == 16,
              f"bundle={state.get('bundle')}")
        if bundle_parts:
            bi = parts.index(bundle_parts[0])
            proc = subprocess.run(["curl", "-sS", "--fail-with-body", links[bi]],
                                  capture_output=True, text=True, timeout=60)
            check("GET the bundle part → 200", proc.returncode == 0,
                  f"rc={proc.returncode} {proc.stderr[:120]}")
            try:
                manifest = json.loads(proc.stdout)
            except ValueError:
                manifest = {}
            m_entries = manifest.get("entries") or []
            check("the bundle part parses as the deploy manifest",
                  any(e.get("path") == "seed/index.mjs" for e in m_entries),
                  proc.stdout[:160])
            seed_entry = next((e for e in m_entries
                               if e.get("path") == "seed/index.mjs"), None)
            if seed_entry:
                rr = c.request(TENANT, f"/start?fn=fileurl&h={seed_entry['hash']}",
                               method="POST", data=b"x")
                check("blob.fileUrl mints a link for a manifest hash",
                      rr.status == 200 and rr.body.strip().startswith("http"),
                      f"got {rr.status} {rr.body[:100]!r}")
                proc = subprocess.run(
                    ["curl", "-sS", "--fail-with-body", rr.body.strip()],
                    capture_output=True, text=True, timeout=60)
                check("the fileUrl link returns the DEPLOYED SOURCE bytes",
                      proc.returncode == 0
                      and proc.stdout == HANDLERS["seed/index.mjs"],
                      f"rc={proc.returncode} got={proc.stdout[:80]!r}")

        print("step 7: ⭐ a tenant AT its storage cap can still export (#429)")
        # Pin the quota below what this tenant already stores, so any metered
        # write is refused. The export must be unaffected — that is the whole
        # point of the separate pool.
        pr = c._cp_post("/_control/plan", {"tenant": TENANT, "plan": json.dumps({
            "tier": "free", "overrides": {"max_stored_bytes": 1},
        })})
        check("pin max_stored_bytes=1 → 2xx", pr.status in (200, 204),
              f"got {pr.status} {pr.body!r}")
        # A metered write really is refused at this cap — otherwise the arm
        # below proves nothing (it would pass on a cap that never bit). The
        # usage figure the gate reads is TTL-cached, so let it expire first.
        time.sleep(2.5)
        c.request(TENANT, "/seed?fn=store&k=capped", method="POST", data=b"x")
        refused = ""
        for _ in range(40):
            rr = c.request(TENANT, "/seed?fn=marker&k=capped", method="POST", data=b"x")
            if rr.status == 200 and rr.body.strip().startswith("owed ") and "failed" in rr.body:
                refused = rr.body.strip()
                break
            time.sleep(0.5)
        check("a metered blob.put at the cap → refused (507 on the owed marker)",
              '"last_status":507' in refused, f"marker={refused[:160]!r}")

        r = c.request(TENANT, "/start?fn=begin", method="POST", data=b"x")
        capped_id = r.body.strip()
        check("export.start() at the cap → an id", r.status == 200 and len(capped_id) > 10,
              f"got {r.status} {r.body[:120]!r}")
        capped = None
        for _ in range(120):
            rr = c.request(TENANT, f"/start?fn=status&id={capped_id}", method="POST", data=b"x")
            if rr.status == 200 and rr.body.strip() not in ("none", ""):
                st = json.loads(rr.body)
                if st.get("state") in ("done", "failed"):
                    capped = st
                    break
            time.sleep(0.5)
        check("the at-cap export reached done (not failed, not stuck)",
              bool(capped) and capped.get("state") == "done",
              f"state={(capped or {}).get('state')} error={(capped or {}).get('error')}")
        if capped and capped.get("state") == "done":
            check("the at-cap export produced parts",
                  len(capped.get("parts") or []) > 0, f"parts={len(capped.get('parts') or [])}")
            cl = capped.get("links") or []
            check("its links download", bool(cl) and subprocess.run(
                ["curl", "-sS", "--fail-with-body", "-o", "/dev/null", cl[0]],
                capture_output=True, timeout=60).returncode == 0,
                f"links={cl[:1]}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS kv-export smoke (v2) — the store walks into content-addressed "
          "parts, the job only ever sees a cursor and a digest, and a tenant at "
          "its storage cap can still get its data out")
    return 0


if __name__ == "__main__":
    sys.exit(main())
