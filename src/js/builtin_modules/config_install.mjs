// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// A deployment's config rows, written by the TENANT, in the tenant's own
// scope (rove#691 / rove#719).
//
// Before this, `_config/**` was written by the deployment-loader thread: a
// second executor writing a tenant's store outside that tenant's activation
// order, leader-gated, fire-and-forget, and invisible in the tenant's log. It
// was correctly ordered against the tenant's own writes — it proposed into the
// tenant's own group — but nothing in the log said a deployment had changed
// anything, which is the account the log is supposed to be.
//
// Now the deploy path reads the manifest and the blobs off the poll loop,
// where that work belongs, and hands the ROWS to the tenant. This module
// writes them in an ordinary activation: the tenant's own writeset, its own
// position in its own order, and a record.
//
// Rows are immutable and deployment-scoped (`_config/{dep_id}/…`), so this is
// idempotent by construction: re-running writes the same bytes to the same
// keys, and a partially-written deployment is invisible rather than broken —
// nothing reads a deployment's config until `_deploy/current` names it.
// That is what lets the deploy path split large configs across several of
// these without any of them needing to be atomic.

export default function ({ __system }) {
    const msg = request.ctx || {};
    const pairs = msg.pairs;
    if (!Array.isArray(pairs) || pairs.length === 0) return { status: 200 };

    let wrote = 0;
    for (const p of pairs) {
        if (!p || typeof p.key !== "string" || typeof p.value !== "string") continue;
        // Skip a row already present with these bytes. The row is immutable,
        // so an identical write says nothing — and skipping keeps a re-run
        // from spending this activation's write budget, or a raft entry, on
        // work already done.
        //
        // `__system.rootKv` — the storage-rooted kv this baked activation
        // RECEIVES (package-isolation.md, the received-not-ambient model) —
        // not `kv.*`: the pairs arrive PRE-SCOPED (`_config/{dep_id}/…`)
        // and must land in the engine namespace the config door reads
        // (`config.get` resolves against it) — through the rooted handler
        // binding they would reroot into this tenant's own keyspace and
        // every reader would miss.
        if (__system.rootKv.get(p.key) === p.value) continue;
        __system.rootKv.set(p.key, p.value);
        wrote += 1;
    }
    return { status: 200, body: { wrote: wrote, of: pairs.length } };
}
