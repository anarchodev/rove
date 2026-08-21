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
        kv.delete(schedByTimeKey(BigInt(rec.when_ns), id));
    } catch (_e) { /* corrupt record — still drop by_id below */ }
    kv.delete("_sched/by_id/" + id);
    return true;
}

export default function () {
    const msg = request.ctx || {};
    const id = msg.id;
    if (typeof id !== "string" || id.length === 0) return { status: 200 };

    // Already resolved — a duplicate result, or a watchdog that fired once
    // more before this landed. Nothing to do, and saying so is not an error.
    if (kv.get("_dispatch/owed/" + id) === null) return { status: 200 };

    kv.delete("_dispatch/owed/" + id);
    // Same writeset as the delete: the watchdog exists only to re-fire an
    // unresolved dispatch, so it must not outlive the marker it guards.
    schedCancel(crypto.sha256b64url("_dispatch/" + id));

    return { status: 200 };
}
