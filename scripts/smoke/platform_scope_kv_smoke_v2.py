#!/usr/bin/env python3
"""V2 platform-global KV smoke — the raw `platform.scope(t).kv.*` primitive +
release-history format, the coverage the deploy smokes don't reach.

The existing platform smokes (platform_deploy / admin_deploy) exercise the
cross-tenant DEPLOY composition (compile → blob.put → stampManifest → release).
They do NOT cover the underlying `scope(t).kv` write primitive with durability
assertions, and two shipped bugs slipped through that gap:

  1. SELF-SCOPE write durability — `scope(self).kv.set` (id == the dispatching
     tenant, i.e. __admin__ writing itself) once appended only to the raft
     writeset and never to the dispatch's speculative overlay (`state.txn`), so
     the write returned 200 but was silently dropped (never locally durable,
     never proposed). Cross-tenant writes were fine, so no deploy smoke caught
     it. Guard: write in ONE request, read it back in ANOTHER.

  2. RELEASE-HISTORY key format — the `_release/{ts_ms}` key formatted a *signed*
     ts with `{d:0>20}`, which emits a leading `+` sign ("_release/000000+<ms>").
     The dashboard reader's `parseInt` then stops at the `+` and reports ts=0.
     Guard: after a release, every `_release/*` key is pure digits + the ts
     round-trips through parseInt.

Runs the primitive through the ONLY handler with platform caps (__admin__),
which makes both self-scope (scope("__admin__")) and cross-tenant
(scope(TARGET)) reachable from one deployed probe.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import time
import urllib.parse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

TARGET = "scopekv-target"

# One admin probe (rpc_wrap named exports, driven via ?fn=). Every op is a
# SEPARATE request/dispatch, which is what makes the durability assertions real
# — a write that only lives in a dispatch-local overlay would read back empty
# from the next request.
PROBE = (
    'const T = "%s";\n' % TARGET
    # cross-tenant
    + 'export function xset({ platform }){ platform.scope(T).kv.set("k/x","XVAL"); return "ok"; }\n'
    + 'export function xget({ platform }){ return JSON.stringify({v: platform.scope(T).kv.get("k/x")}); }\n'
    + 'export function xprefix({ platform }){ return JSON.stringify(platform.scope(T).kv.prefix("k/","",100)); }\n'
    + 'export function xdel({ platform }){ platform.scope(T).kv.delete("k/x"); return "ok"; }\n'
    # self-scope (__admin__ writing itself)
    + 'export function sset({ platform }){ platform.scope("__admin__").kv.set("k/self","SELF"); return "ok"; }\n'
    + 'export function sget({ platform }){ return JSON.stringify({v: platform.scope("__admin__").kv.get("k/self")}); }\n'
    + 'export function sdel({ platform }){ platform.scope("__admin__").kv.delete("k/self"); return "ok"; }\n'
    # Release history. The engine's `_release/` rows carry no root, so they
    # are NOT reachable by naming them through the scoped door any more
    # (rove#850 deleted that spelling escape). They are read through the
    # typed `release` request on the dispatched scope_kv — the same path
    # the dashboard's /v1/deployments uses, so this leg now exercises the
    # real one instead of a carve-out that only tests existed to use.
    + 'export function relStart({ platform }){ return platform.dispatch("__admin__", "__system/scope_kv", { ctx: { release: true } }); }\n'
    + 'export function relRead({ kv }, id){ return kv.get("_dispatch/result/" + id) || ""; }\n'
    # Naming the engine row through the door must now miss: it roots like
    # every other key, so it reads the tenant's own (absent) row.
    + 'export function relNamed({ platform }){ return JSON.stringify(platform.scope("__admin__").kv.prefix("_release/","",100)); }\n'
)


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("scopekv", nodes=1) as c:
        print("step 1: bring up __admin__ + provision the cross-tenant target")
        c._ensure_admin_app()
        r = c.provision(TARGET)
        check("provision target → 200/409", r.status in (200, 409), f"got {r.status} {r.body!r}")

        print("step 2: deploy the platform-probe onto __admin__ (releases → writes a _release key)")
        try:
            dep = c.deploy_handlers("__admin__", {"index.mjs": rpc_wrap(PROBE)})
            check("deploy probe to __admin__ (self-deploy)", bool(dep), f"dep_id={dep}")
        except RuntimeError as e:
            check("deploy probe to __admin__", False, str(e))
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        c.wait_for_handler("__admin__", "/?fn=sget", want_status=200)

        def fn(name):
            return c.get("__admin__", f"/?fn={name}")

        print("step 3: cross-tenant scope(TARGET).kv round-trip (set/get/prefix/delete)")
        fn("xset")
        check("cross-tenant get reads the write", json.loads(fn("xget").body).get("v") == "XVAL")
        rows = json.loads(fn("xprefix").body)
        check("cross-tenant prefix returns the key",
              any(e.get("key") == "k/x" and e.get("value") == "XVAL" for e in rows), repr(rows))
        fn("xdel")
        check("cross-tenant delete removes it", json.loads(fn("xget").body).get("v") is None)

        print("step 4: SELF-SCOPE durability across requests (regression: 200-but-dropped)")
        fn("sset")  # write in one dispatch …
        check("self-scope get reads the write in a LATER request",
              json.loads(fn("sget").body).get("v") == "SELF")  # … read in another
        fn("sdel")
        check("self-scope delete is durable across requests",
              json.loads(fn("sget").body).get("v") is None)

        print("step 5: the engine's release rows are a typed verb, never a spelling")
        # Naming `_release/` through the scoped door roots like any other key
        # (rove#850), so it reads the tenant's own keyspace and finds nothing.
        # That miss IS the assertion: a spelling buys no engine rows.
        named = json.loads(fn("relNamed").body)
        check("naming _release/ through the door reaches no engine row", named == [],
              repr(named))

        print("step 6: release-history key format via the typed verb (regression: signed '+')")
        did = fn("relStart").body.strip()
        check("dispatch of the release read → an id", len(did) > 10, repr(did))
        raw = ""
        for _ in range(50):
            raw = fn("relRead&args=" + urllib.parse.quote(json.dumps([did]))).body.strip()
            if raw:
                break
            time.sleep(0.2)
        check("the dispatched release read resolved", bool(raw), repr(raw[:120]))
        if raw:
            # The result row is the target's terminal body with a request-body
            # trust posture — parse defensively.
            outer = json.loads(raw)
            body = json.loads(outer.get("body") or "{}")
            hist = ((body.get("release") or {}).get("history")) or []
            stamps = [h["ts"] for h in hist]
            check("release wrote at least one _release/ row", len(stamps) >= 1, repr(stamps))
            bad_plus = [t for t in stamps if "+" in t]
            check("no _release ts contains a '+' sign", not bad_plus, repr(bad_plus))
            parsable = all(t.isdigit() and int(t) > 0 for t in stamps)
            check("every _release ts is pure digits + parses > 0", parsable, repr(stamps))

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS platform-scope-kv smoke (v2): cross-tenant + self-scope kv "
          "round-trip durable across requests; release-history keys are clean digits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
