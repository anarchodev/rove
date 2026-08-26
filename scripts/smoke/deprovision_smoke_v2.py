#!/usr/bin/env python3
"""Tenant lifecycle, both directions (rove#292/#293) — on a production-shaped
3-node cluster.

provision → deploy → serve → **delete** → gone → provision the SAME NAME again.

The last step is the one that matters. A deprovision that merely stops serving
is not a deprovision: the name has to become reusable, which means the
`instance/{id}` root marker is gone from every node, not just the placement
row. Until #292 the directory could not remove a placement at all, so nothing
here was possible.

Also pins the ordering guarantee #293 asks for. Delete withdraws the placement
FIRST and evicts after, so the only window is "unroutable, group not yet gone"
— invisible and retryable. The reverse order would route live traffic at a
cluster that no longer holds the tenant. That ordering is asserted indirectly:
after a delete the front door must 404 (not 421, not 502), which is only true
if the placement went first.

And the guards: a retried delete converges instead of erroring, and a platform
singleton refuses to be deleted at all.

STEP 6 CURRENTLY FAILS, ON PURPOSE (rove#357). Storage identity is the tenant
NAME — `{data_dir}/{id}/app.db` and `{prefix}{id}/{file-blobs,log-blobs}/` —
and nothing distinguishes one tenant's lifetime from the next, so the second
holder of a reused name reads the first holder's data. That was unreachable
until deprovision made names reusable, which is precisely why the assertion
lives here: this smoke is the gate that stops deprovision shipping a
cross-customer leak. It goes green when tenant storage is scoped to an
incarnation.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import (  # noqa: E402
    MOVE_SECRET, PUBLIC_SUFFIX, V2Cluster, _curl, attach_join, rpc_wrap,
)

TENANT = "tobedeleted"
SRC = 'export function handler() { return "alive\\n"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    # Generation 1, not the default 0 (rove#606). At generation 0
    # `namespace.apply` is a no-op, so a consumer that scopes to the
    # generation and one that does not compose the SAME prefix — and the
    # sweep assertion below cannot fail however wrong the CP is. Production
    # runs at generation 1, where the two diverge, and that is where the CP
    # was found sweeping `prod/{tenant}/…` while the bytes sat in
    # `prod/1/{tenant}/…`.
    with V2Cluster.spawn("deprov", nodes=3, storage_generation=1) as c:
        cp_url = c.front_url().replace(str(c.front_port), str(c.cp_port))

        def cp(op: str, body: dict):
            return _curl(f"{cp_url}/_control/{op}", method="POST",
                         headers={"X-Rewind-Move-Secret": MOVE_SECRET,
                                  "Content-Type": "application/json"},
                         data=json.dumps(body))

        print("step 1: provision + deploy + serve")
        check("provision → 200", cp("provision", {"tenant": TENANT}).status == 200)
        dep = c.deploy_handlers(TENANT, {"index.mjs": rpc_wrap(SRC)})
        check("deploy → dep_id", bool(dep), f"dep_id={dep}")
        r = c.wait_for_handler(TENANT, "/?fn=handler", want_body="alive")
        check("serves before delete", r.status == 200 and "alive" in r.body,
              f"got {r.status} {r.body!r}")

        # Write a secret as the FIRST tenant. If a later tenant with the same
        # name can read this, deprovision leaked one customer's data to another.
        # The write is leader-gated (a follower 503s) and the leader for a
        # freshly-born group is whichever node won its election, so try each
        # node until one accepts rather than assuming node 0.
        put_ok = False
        for _ in range(20):
            for n in range(len(c.node_ports)):
                if c.node_kv_put(TENANT, "secret", "alice-private-data", node=n).status == 204:
                    put_ok = True
                    break
            if put_ok:
                break
            time.sleep(0.3)
        check("the first tenant's secret was written", put_ok, "no node accepted the write")
        # Through the helper, not a hand-rolled URL: the write above went via
        # `node_kv_put`, and a read that spells the key itself is reading a
        # different keyspace than the write wrote to.
        rr = c.node_kv_get(TENANT, "secret")
        check("first tenant's secret is stored", "alice-private" in rr.body, f"got {rr.status} {rr.body!r}")

        print("step 2: delete")
        r = cp("delete", {"tenant": TENANT})
        check("delete → 204", r.status == 204, f"got {r.status} {r.body!r}")

        # rove#350: the delete must also remove the tenant's STORED OBJECTS.
        # Nothing else ever GCs them, so without the sweep a deleted tenant
        # bills forever and an account-closure erasure promise has no code
        # behind it. The deploy above wrote `file-blobs/` + `deployments/`, so
        # a correct sweep reports a non-zero count. Asserted through the CP's
        # own report (there is no operator surface that lists S3); the
        # primitives themselves are covered against a real endpoint by
        # `examples/s3_blob_smoke.zig`'s prefix-sweep section.
        swept = None
        cp_log = c.log_paths.get("cp")
        if cp_log:
            with open(cp_log) as f:
                for ln in f:
                    if f"deleted {TENANT} (" in ln and "object(s)" in ln:
                        swept = int(ln.split(", ")[-1].split(" object(s)")[0])
        check("delete swept the tenant's stored objects (#350)",
              swept is not None and swept > 0, f"objects deleted={swept}")

        print("step 3: it is gone — and gone the RIGHT way")
        r = c.get(TENANT, "/?fn=handler")
        # 404 (host maps to no tenant), NOT 421/502 — a 421 would mean the
        # placement outlived the group, i.e. the eviction ran first.
        check("front door 404s the deleted tenant", r.status == 404,
              f"got {r.status} {r.body[:80]!r}")
        rt = _curl(f"{cp_url}/_cp/route?host={TENANT}.{PUBLIC_SUFFIX}", method="GET")
        check("CP has no placement for it", rt.status == 404, f"got {rt.status} {rt.body!r}")

        print("step 4: a retried delete converges (it does not error)")
        r = cp("delete", {"tenant": TENANT})
        check("re-delete → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 5: ⭐ the name is REUSABLE — the whole point of deprovision")
        r = cp("provision", {"tenant": TENANT})
        check("re-provision the same name → 200", r.status == 200, f"got {r.status} {r.body!r}")
        dep2 = c.deploy_handlers(TENANT, {"index.mjs": rpc_wrap(
            'export function handler() { kv.set("reborn_key", "reborn_val");'
            ' return "reborn\\n"; }\n')})
        check("deploy to the reborn tenant → dep_id", bool(dep2), f"dep_id={dep2}")
        r = c.wait_for_handler(TENANT, "/?fn=handler", want_body="reborn")
        check("serves the NEW content (fresh state, not the old store)",
              r.status == 200 and "reborn" in r.body, f"got {r.status} {r.body!r}")

        print("step 6: ⭐ the reborn tenant must NOT inherit the deleted one's data")
        leaked = c.node_kv_get(TENANT, "secret")
        check("previous tenant's KV is NOT readable by the new one",
              "alice-private" not in leaked.body,
              f"LEAK: got {leaked.status} {leaked.body!r}")

        print("step 7: the platform's own singletons refuse deletion")
        r = cp("delete", {"tenant": "__admin__"})
        check("delete __admin__ → 403", r.status == 403, f"got {r.status} {r.body!r}")
        r = c.get("__admin__", "/", host=c.host_for("__admin__"))
        check("__admin__ still serves", r.status in (200, 405), f"got {r.status}")

        print("step 8: ⭐ residue of a previous lifetime yields to the minted"
              " incarnation (rove#531)")
        # Plant a stale-lifetime instance on node 1 ONLY — the shape a node is
        # left in when its instance-marker deletion doesn't survive a restart.
        # On prod, one node re-attached a reborn tenant under the DELETED
        # lifetime's incarnation while its peers minted fresh: the deploy then
        # staged its manifest under one storage prefix, the serving leader
        # loaded from another, and the tenant answered "no deployment"
        # forever. The attach door is how the CP creates instances, so it is
        # also the door that plants one.
        T2 = "reborn531"
        st = attach_join(f"{c.node_url(0)}/_system/v2-attach",
                         tenant=T2, incarnation="deadbeefdeadbeef")
        check("plant a stale-lifetime instance on node 1 → 204", st == "204",
              f"got {st}")
        r = cp("provision", {"tenant": T2})
        check("provision the same name → 200 (mints a fresh incarnation)",
              r.status == 200, f"got {r.status} {r.body!r}")
        dep = c.deploy_handlers(T2, {"index.mjs": rpc_wrap(
            'export function handler() { kv.set("alive531", "yes");'
            ' return "reborn531-alive\\n"; }\n')})
        check("deploy despite the planted residue → dep_id", bool(dep),
              f"dep_id={dep}")
        r = c.wait_for_handler(T2, "/?fn=handler", want_body="reborn531-alive")
        check("serves through the front (no 'no deployment')",
              r.status == 200 and "reborn531-alive" in r.body,
              f"got {r.status} {r.body!r}")
        # Every node must resolve the SAME (minted) store: a node still
        # holding the planted marker resolves the stale store and reads
        # absent. The write replicates via raft; poll briefly per node.
        for i in range(len(c.node_ports)):
            deadline = time.time() + 15.0
            rr = None
            while time.time() < deadline:
                # The HANDLER wrote this key, so it resolves under the user
                # root; the helper spells that once instead of every caller.
                rr = c.node_kv_get(T2, "alive531", node=i)
                if rr.status == 200 and "yes" in rr.body:
                    break
                time.sleep(0.5)
            check(f"node {i + 1} resolves the reborn store (kv readable)",
                  rr is not None and rr.status == 200 and "yes" in rr.body,
                  f"got {rr.status} {rr.body!r}" if rr else "no response")
        # THE decisive assertion: no node's deployment loader may be spinning
        # on the reborn tenant. With split incarnations the deploy stages its
        # manifest under ONE node's prefix, and every node on the other side
        # of the split retries `NoDeployment` forever — whichever node the
        # stale marker survives on. The serve-through-the-front check above
        # can pass regardless (the front reaches whichever node loaded), so
        # the loader logs are the only place the split is always visible.
        time.sleep(3.0)  # give a mis-keyed loader a beat to log its retry
        for i in range(len(c.node_ports)):
            log_path = c.log_paths.get(f"n{i + 1}", "")
            spinning = False
            if log_path and Path(log_path).exists():
                spinning = f"deployment loader: tenant {T2}" in \
                    Path(log_path).read_text(errors="replace")
            check(f"node {i + 1} loader is not spinning on {T2}", not spinning,
                  "" if not spinning else
                  "loader retries NoDeployment — incarnations split across nodes")
        # The system seed door has NO authority over the incarnation: a PUT
        # through it must land in the live token-keyed instance, not re-key
        # the tenant to a default and orphan its deployment (the regression
        # the first cut of the #531 fix shipped — every seed 503'd the
        # tenant afterward).
        seeded = None
        for i in range(len(c.node_ports)):
            rr = _curl(f"{c.node_url(i)}/_system/v2-kv", method="PUT",
                       headers={"X-Rewind-Move-Secret": MOVE_SECRET,
                                "Content-Type": "application/json"},
                       data=json.dumps({"tenant": T2, "key": "seeded531",
                                        "value": "ok"}))
            if rr.status in (200, 204):
                seeded = rr
                break
        check("v2-kv seed onto the reborn tenant → 204", seeded is not None,
              "" if seeded is not None else "no node accepted the seed")
        r = c.wait_for_handler(T2, "/?fn=handler", want_body="reborn531-alive")
        check("still serves after the seed (the door re-keyed nothing)",
              r.status == 200 and "reborn531-alive" in r.body,
              f"got {r.status} {r.body!r}")

        print("step 9: ⭐ the reborn tenant's writes reach every node's CURRENT"
              " store (rove#534)")
        # Followers apply through the pump's name-keyed store-handle cache. A
        # handle cached during the FIRST lifetime is attached at the deleted
        # store's id, so the reborn tenant's replicated writes land there
        # while each node's serving side reads the new store. The leader's
        # own (correct) writes hide it — so read the store DIRECTLY on every
        # node: the reborn handler's kv write must be visible everywhere.
        for i in range(len(c.node_ports)):
            deadline = time.time() + 15.0
            rr = None
            while time.time() < deadline:
                rr = c.node_kv_get(TENANT, "reborn_key", node=i)
                if rr.status == 200 and "reborn_val" in rr.body:
                    break
                time.sleep(0.5)
            check(f"node {i + 1} holds the reborn write in the CURRENT store",
                  rr is not None and rr.status == 200 and "reborn_val" in rr.body,
                  f"got {rr.status} {rr.body!r}" if rr else "no response")

        print("step 10: the reborn tenant survives a failover")
        leader = None
        for i in range(len(c.node_ports)):
            rr = _curl(f"{c.node_url(i)}/_system/v2-leader?tenant={TENANT}",
                       headers={"X-Rewind-Move-Secret": MOVE_SECRET})
            if rr.status == 200:
                leader = i
                break
        check("found the reborn tenant's serving leader", leader is not None,
              f"leader=node {leader + 1}" if leader is not None else "no node claims it")
        if leader is not None:
            c.stop_node(leader)
            rr = c.request_retry(TENANT, "/?fn=handler", want_body="reborn",
                                 deadline_s=40.0)
            check("a survivor serves the reborn content after failover",
                  rr.status == 200 and "reborn" in rr.body,
                  f"got {rr.status} {rr.body[:80]!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS deprovision smoke (v2) — the lifecycle closes: a deleted name comes back")
    return 0


if __name__ == "__main__":
    sys.exit(main())
