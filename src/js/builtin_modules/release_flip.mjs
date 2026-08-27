// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// The release flip, as an activation in the tenant's own scope (rove#719).
//
// `_deploy/current` names the tenant's servable deployment; `_release/{ts}`
// is the history row the dashboard's Deploys tab reverse-scans. Before this,
// the `/_system/release` door hand-rolled both writes on the request thread
// — correctly ordered into the tenant's own group, but with no activation
// behind them, so the tenant's log had nothing to explain the one change a
// customer most expects to find in it: a deployment.
//
// The route (`worker_system.zig`) still authenticates the operator,
// validates the body, answers the idempotent fast path, and rejects unknown
// tenants; the WRITE is this module, dispatched against the target tenant on
// the ordinary handler path — record, tape, park-on-commit and the 204's
// durability contract all come from that path. On commit, the pump's
// origin-aware apply observer enqueues the deployment loader on every node,
// proposer included (`ApplyObserver.origin`), replacing the door's explicit
// leader-side nudge.
//
// Writes go through `__system.rootKv` (rove#848): both keys are engine
// namespaces the loader and dashboard read as storage — the handler-rooted
// `kv` would re-file them under the user root where no reader looks.

// The response HEAD is the ambient `response` global — a returned object is
// a BODY, not a head (`handler-shape.md` §3).
function answer(status, body) {
    response.status = status;
    return body;
}

export default function ({ __system }) {
    if (request.method !== "POST") return answer(405, "POST only\n");

    // `dep_id` is a u64 content hash. It must NOT pass through JSON.parse —
    // a Number mangles anything past 2^53 — so pull the digits from the raw
    // body and carry them as a BigInt. `tenant_id` is deliberately ignored:
    // the SCOPE is the tenant, resolved by the route before dispatch, and a
    // body naming someone else must not override it.
    const m = (request.text || "").match(/"dep_id"\s*:\s*(\d+)/);
    if (!m) return answer(400, 'expected {"tenant_id":"...","dep_id":N}\n');
    let dep = 0n;
    try { dep = BigInt(m[1]); } catch (_e) { /* falls through to the check */ }
    if (dep <= 0n || dep > 0xffffffffffffffffn) {
        return answer(400, "dep_id must be a u64 > 0\n");
    }
    const hex = dep.toString(16).padStart(16, "0");

    // Same-id re-release: the route's fast path answers before dispatch;
    // this re-check closes the race between that check and this activation
    // running. Skipping keeps a bootstrap retry from growing `_release/`
    // history — a retry is not the customer hitting deploy again.
    if (__system.rootKv.get("_deploy/current") === hex) return answer(204, "");

    __system.rootKv.set("_deploy/current", hex);
    // Release history: `_release/{ts_ms:020}` → `{id:016x}`, lex-ordered by
    // the zero-padded millisecond timestamp so a reverse scan returns
    // newest-first. Pure digits — a sign column would break the dashboard
    // reader's parseInt (the regression test in worker_system.zig).
    const ts = String(Date.now()).padStart(20, "0");
    __system.rootKv.set("_release/" + ts, hex);
    return answer(204, "");
}
