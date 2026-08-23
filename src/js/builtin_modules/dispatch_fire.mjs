// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// The wake-fired half of `platform.dispatch` (rove#691) — the exact shape
// `__system/webhook_fire` has for `webhook.send`, pointed inward instead of
// outward.
//
// `platform.dispatch` writes a `_dispatch/owed/{id}` marker and arms a
// watchdog in the SAME writeset as the activation that called it, so intent
// and its recovery commit together or not at all. Every deferred attempt —
// a crash-recovery watchdog, or a retry after the target's group refused the
// propose — arrives here as a `durable_wake` carrying `{ id }`, under the
// idempotency key `_dispatch/{id}` (one wake entry per in-flight dispatch).
//
// Why a dispatch needs this at all: the activation lands on the worker
// anchoring the TARGET tenant, and that node may not lead the target's raft
// group. The propose then faults and the activation is gone. Today's release
// door answers 421 and the client re-aims; a dispatched action has no client
// to re-aim, so the marker IS the retry.
//
// Flow per fire:
//   1. Read the marker. Absent ⇒ the dispatch was resolved (the result
//      activation deleted it and cancelled the wake, though a stale watchdog
//      can still fire once — at-least-once) — no-op.
//   2. Re-arm the watchdog BEFORE dispatching. The fired entry's `_sched/`
//      rows are deleted in THIS writeset, so without the re-arm a crash
//      mid-attempt orphans the marker forever.
//   3. Dispatch via the gated `__rove.dispatch`. Commit-gated with this
//      activation's writeset, so a raft fault rolls the whole attempt back
//      and the still-due entry re-fires on a later tick.
//
// The target activation is idempotent by contract — it is the platform's own
// baked code, and re-running it must be safe. That is what makes at-least-once
// delivery the right posture rather than a compromise.

// One dispatch attempt's outside bound plus grace. A wake only re-fires a
// dispatch whose attempt has definitively failed to resolve.
const WATCHDOG_MS = 40_000;

// Durable-scheduler arm, inlined over the ambient `kv`/`crypto`: a baked
// `__system/*` module runs post-harden and cannot reach the private
// `_system.sched` closure. Writes the exact `_sched/` rows
// globals/schedule.js + scheduler_tick.mjs use. Mirrors webhook_fire.mjs —
// keep the two in step.
const SCHED_TICK_NS = 1_000_000_000n;
// `_sched/by_id/{id}` record version (`format-versioning.md` §1f). The
// record shape is written from every module that arms a wake, so the
// field is what stops one of them shipping a new shape that the tick
// reads at the old one. An unknown `v` is treated exactly like an
// unparseable record — this is a shim-writable namespace, so a value
// this reader does not understand is as likely a customer's write as an
// engine skew, and dropping the entry is the response both deserve.
const SCHED_REC_V = 1;

// `_dispatch/owed/{id}` marker version (`format-versioning.md` §1f).
const DISPATCH_OWED_V = 1;

function schedByTimeKey(whenNs, id) {
    return "_sched/by_time/" + String(whenNs).padStart(20, "0") + "/" + id;
}
function schedArm(whenNs, target, msg, key) {
    const rounded = whenNs <= 0n ? 0n
        : ((whenNs + SCHED_TICK_NS - 1n) / SCHED_TICK_NS) * SCHED_TICK_NS;
    const id = key ? crypto.sha256b64url(key) : crypto.randomUUID();
    const byIdKey = "_sched/by_id/" + id;
    const prev = kv.get(byIdKey);
    if (prev !== null) {
        try {
            const old = JSON.parse(prev);
            if (old.v !== SCHED_REC_V) throw new Error("version");
            const oldWhen = BigInt(old.when_ns);
            if (oldWhen !== rounded) kv.delete(schedByTimeKey(oldWhen, id));
        } catch (_e) { /* corrupt or unknown-version prior — overwrite below */ }
    }
    const rec = { v: SCHED_REC_V, when_ns: String(rounded), target: target, msg: msg === undefined ? null : msg };
    if (typeof request !== "undefined" && typeof request.sagaId === "string" && request.sagaId) rec.armed_by = request.sagaId;
    if (key) rec.key = key;
    kv.set(byIdKey, JSON.stringify(rec));
    kv.set(schedByTimeKey(rounded, id), "");
    return id;
}

export default function () {
    const a = request.activation;
    if (a.kind !== "durable_wake") return { status: 200 };

    const msg = request.ctx || {};
    const id = msg.id;
    if (typeof id !== "string" || id.length === 0) return { status: 200 };

    const markerKey = "_dispatch/owed/" + id;
    const raw = kv.get(markerKey);
    // Resolved already. A stale watchdog firing once after the resolve is
    // expected, not an error.
    if (raw === null) return { status: 200 };

    let marker;
    try {
        marker = JSON.parse(raw);
    } catch (_e) {
        // Unparseable marker: drop the chain rather than re-fire forever.
        // Same defensive posture `__system/export_run` takes on its record.
        kv.delete(markerKey);
        return { status: 200 };
    }
    // A version this build does not implement gets the same answer, for
    // the same reason: the namespace is shim-writable, so an unknown
    // `v` is as likely a customer's write as a newer engine, and
    // re-dispatching from fields we may be misreading is worse than
    // dropping the chain.
    if (marker.v !== DISPATCH_OWED_V) {
        kv.delete(markerKey);
        return { status: 200 };
    }

    // Re-arm BEFORE dispatching — see the header. Same key ⇒ same entry, so
    // this moves the existing wake rather than adding one.
    schedArm(
        BigInt(Date.now() + WATCHDOG_MS) * 1_000_000n,
        "__system/dispatch_fire",
        { id: id },
        "_dispatch/" + id,
    );

    __rove.dispatch(
        marker.tenant,
        marker.module,
        JSON.stringify(marker.ctx === undefined ? null : marker.ctx),
        typeof marker.fn === "string" && marker.fn ? marker.fn : null,
        marker.actor,
        // The marker this dispatch resolves: the target's completion reports
        // back here and clears it. Without this the watchdog would re-fire
        // forever, since nothing else can tell this tenant the work landed —
        // the target cannot write into this store, which is the point.
        id,
    );

    return { status: 200 };
}
