// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// The return half of `platform.dispatch` (rove#691): the target's activation
// landed, so resolve the owed marker HERE, in the origin tenant's own scope.
//
// This exists because the target cannot write into the origin's store — that
// cross-tenant write is precisely what the arc removes. So completion has to
// come back as its own activation in the origin's scope, and this is it. The
// engine enqueues it after the target activation commits; nothing in the
// target's module has to remember to report, which is the only version of
// this that survives a second platform module being written.
//
// Resolve-once by construction: deleting an absent marker is a no-op, so a
// duplicate result (the delivery is at-least-once, like every other hop here)
// costs nothing. The watchdog entry is cancelled in the SAME writeset as the
// marker delete, so the pair cannot half-apply and leave a wake firing for
// work that is already done.

// `_sched/by_id/{id}` record version (`format-versioning.md` §1f). The
// shape is written from every module that arms a wake, so the field is
// what stops one of them shipping a new shape that another reads at the
// old one.
//
// This module CANCELS a wake rather than firing one, which is why an
// unknown `v` here is benign: it means the by_time key cannot be
// derived, so that row is left behind as an orphan and the tick's own
// orphan sweep collects it. Nothing durable is destroyed either way.
const SCHED_REC_V = __rove.formats.sched;
// `_dispatch/result/{id}` record version (`format-versioning.md` §1f).
const DISPATCH_RESULT_V = __rove.formats.dispatchResult;

// Durable-scheduler cancel, inlined over the ambient `kv`: a baked
// `__system/*` module runs post-harden and cannot reach the private
// `_system.sched` closure. Mirrors `webhook_onresult.mjs` — keep in step.
function schedByTimeKey(whenNs, id) {
    return "_sched/by_time/" + String(whenNs).padStart(20, "0") + "/" + id;
}
function schedCancel(id) {
    const raw = kv.get("_sched/by_id/" + id);
    if (raw === null) return false;
    try {
        const rec = JSON.parse(raw);
        if (rec.v !== SCHED_REC_V) throw new Error("version");
        kv.delete(schedByTimeKey(BigInt(rec.when_ns), id));
    } catch (_e) { /* corrupt or unknown-version record — still drop by_id below */ }
    kv.delete("_sched/by_id/" + id);
    return true;
}

export default function () {
    const msg = request.ctx || {};
    const id = msg.id;
    if (typeof id !== "string" || id.length === 0) return { status: 200 };

    // Already resolved — a duplicate result, or a watchdog that fired once
    // more before this landed. Nothing to do, and saying so is not an error.
    // Resolve-once also covers the result row below: only the FIRST result
    // writes it, so a late duplicate cannot clobber a value the origin's
    // wake may already have consumed and deleted.
    if (kv.get("_dispatch/owed/" + id) === null) return { status: 200 };

    // The target's committed terminal outcome, engine-carried. Written in
    // the SAME writeset as the marker delete so the origin's kv wake on the
    // marker cannot fire without the result being readable. The bytes are
    // another tenant's output — the reader treats them like a request body
    // (untrusted data), and `overflow` says the engine's carry cap
    // truncated them. The origin's wake consumes and deletes the row; a
    // chain that dies parked leaks one bounded row; nothing re-fires it.
    if (typeof msg.status === "number") {
        kv.set("_dispatch/result/" + id, JSON.stringify({
            v: DISPATCH_RESULT_V,
            status: msg.status,
            overflow: msg.overflow === true,
            body: typeof msg.body === "string" ? msg.body : "",
        }));
    }

    kv.delete("_dispatch/owed/" + id);
    // Same writeset as the delete: the watchdog exists only to re-fire an
    // unresolved dispatch, so it must not outlive the marker it guards.
    schedCancel(crypto.sha256b64url("_dispatch/" + id));

    return { status: 200 };
}
