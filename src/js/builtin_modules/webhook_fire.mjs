// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// durable-wake-plan P5(a) — the wake-fired half of `webhook.send`.
// Replaces the deleted Zig owed sweep (`owed_retry.zig`'s
// `sweepOwedRetries*` + `buildRetryFetch`): every deferred fire of a
// `_send/owed/{id}` marker — a scheduled send (`fire_at_ns > now`), a
// retry re-arm from `__system/webhook_onresult`, or a crash-recovery
// watchdog — now arrives here as a `durable_wake` activation carrying
// `{ id }`, scheduled via the durable `scheduler` lib under the
// idempotency key `_send/{id}` (one wake entry per in-flight send).
//
// Flow per fire:
//   1. Read the marker. Absent ⇒ the send completed (onresult deleted
//      it and cancelled the wake, but a stale watchdog can still fire
//      once — at-least-once firing) — no-op.
//   2. Re-arm the watchdog wake at now + WATCHDOG_MS BEFORE fetching.
//      The fired entry's `_sched/` keys are deleted in THIS writeset
//      (fireDurableWakeActivation injects them), so without the re-arm
//      a crash mid-attempt would orphan the marker forever — the
//      watchdog is the recovery primitive the deleted promotion sweep
//      used to be. Same key ⇒ same entry; onresult later moves it
//      (retry backoff) or cancels it (terminal).
//   3. Fire the fetch via the gated `__rove.fetch`, aimed
//      at `__system/webhook_onresult`, stamping the same
//      `X-Rove-Schedule-Id` / `X-Rove-Schedule-Version` headers the
//      Zig sweep stamped — upstream (id, version) dedup keys keep
//      working across the re-platform.
//
// Both the re-arm and the fetch are commit-gated with this
// activation's writeset (the fetch is a buffered Cmd released
// post-commit), so a raft fault rolls the whole attempt back and the
// still-due entry re-fires on a later tick.

// Watchdog distance: one attempt timeout (the fetch binding's 30 s
// cap) + grace. A wake only re-fires a send whose in-flight attempt
// has definitively timed out — no double-send window (unlike the old
// 1 Hz sweep, which could re-fire a >1 s in-flight first attempt).
const WATCHDOG_MS = 40_000;

// Durable-scheduler arm, inlined over the ambient `kv`/`crypto`: a baked
// `__system/*` module runs post-harden and can't reach the private
// `_system.sched` closure. Writes the exact `_sched/` rows
// globals/schedule.js + scheduler_tick.mjs use.
const SCHED_TICK_NS = 1_000_000_000n;
// `_sched/by_id/{id}` record version (`format-versioning.md` §1f). The
// record shape is written from every module that arms a wake, so the
// field is what stops one of them shipping a new shape that another
// reads at the old one.
//
// An unknown `v` is NOT treated like an unparseable record. Corrupt
// bytes are unrecoverable, so dropping them loses nothing; a record
// written by a newer build is recoverable by that build, and deleting
// it would destroy durable customer work during an ordinary rolling
// deploy. Readers defer such a record and leave both its rows alone.
const SCHED_REC_V = __rove.formats.sched;

// `_send/owed/{id}` marker version (`format-versioning.md` §1f).
const SEND_OWED_V = __rove.formats.sendOwed;

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
    // Provenance: the arming saga rides to the fired record as the
    // reserved `_parent` tag (handler-shape.md §3.2). A re-arm's armer
    // is the CURRENT fire — the linked-list-through-fires shape.
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

    const markerKey = "_send/owed/" + id;
    const raw = kv.get(markerKey);
    if (raw == null) return { status: 200 }; // completed/cancelled — stale watchdog

    let owed;
    try {
        owed = JSON.parse(raw);
    } catch (_e) {
        // Corrupt marker (customer-writable kv) — unrecoverable by
        // the platform; drop it so the watchdog chain ends.
        kv.delete(markerKey);
        return { status: 200 };
    }
    // A version this build does not implement is NOT the same as an
    // unparseable marker, and the difference is the whole point of the
    // field. Corrupt bytes are unrecoverable, so dropping them loses
    // nothing. A version we do not know is recoverable BY A DIFFERENT
    // BUILD — during a rolling upgrade the node beside this one may read
    // it fine — so deleting it would destroy a customer's durable send
    // on an ordinary deploy.
    //
    // Leave the marker, re-arm the watchdog, fire nothing. The re-arm is
    // not optional: the fan-out already staged this entry's `_sched/`
    // cleanup into THIS writeset, so returning without it commits the
    // deletion and orphans the marker forever — trading data loss for a
    // row nothing will ever look at again.
    if (typeof owed.v !== "number") {
        // Absent or non-numeric: pre-versioning or hand-written, not
        // "newer than us". No future build reads it better — drop it,
        // the same answer the unparseable branch above gives.
        kv.delete(markerKey);
        return { status: 200 };
    }
    if (owed.v !== SEND_OWED_V) {
        console.warn("webhook_fire: _send/owed/" + id + " is v" + owed.v +
                     ", this build reads v" + SEND_OWED_V + " — deferred, not dropped");
        schedArm(BigInt(Date.now() + WATCHDOG_MS) * 1_000_000n, "__system/webhook_fire", { id: id }, "_send/" + id);
        return { status: 200 };
    }
    if (typeof owed.url !== "string" || owed.url.length === 0) {
        kv.delete(markerKey);
        return { status: 200 };
    }

    // (2) watchdog re-arm — covers a crash between this fire and the
    // onresult commit.
    schedArm(BigInt(Date.now() + WATCHDOG_MS) * 1_000_000n, "__system/webhook_fire", { id: id }, "_send/" + id);

    // (3) the attempt. A deferred fire is metered against the tenant's
    // outbound quota exactly like an inline one (`bindings/http.zig`), so
    // this throws when the tenant is over budget or its plan grants no
    // third-party egress at all.
    //
    // It MUST be caught. An uncaught throw rolls this activation's writeset
    // back — including the `_sched/` cleanup the fan-out injected — so the
    // entry stays due and re-fires on the next 1 Hz tick, forever, for as
    // long as the tenant is refused. Catching leaves the (2) re-arm
    // committed, which turns a refusal into a WATCHDOG_MS backoff.
    //
    // The refusal still costs an attempt: a permanent one (no quota on this
    // plan) must terminate rather than re-fire until the heat death of the
    // watchdog, and a rate refusal that never counted would let a
    // 40-second retry loop outlive the marker's retry budget.
    const attempts = typeof owed.attempts === "number" ? owed.attempts : 0;
    try {
        fireAttempt(owed, id, attempts);
    } catch (e) {
        const code = (e && e.code) || "";
        const max_attempts = (typeof owed.max_attempts === "number" && owed.max_attempts >= 1)
            ? owed.max_attempts
            : DEFAULT_MAX_ATTEMPTS;
        const permanent = code === "outbound_not_enabled";
        if (permanent || attempts + 1 >= max_attempts) {
            // Terminal: drop the marker and cancel the wake, the same
            // shape `webhook_onresult` uses for a give-up.
            kv.delete(markerKey);
            schedCancel("_send/" + id);
        } else {
            owed.attempts = attempts + 1;
            kv.set(markerKey, JSON.stringify(owed));
        }
    }
    return { status: 200 };
}

// Default cap when the marker omits `max_attempts` — mirrors
// `webhook_onresult`'s, so a refused attempt and a failed one count
// against the same budget.
const DEFAULT_MAX_ATTEMPTS = 5;

/// Cancel the send's scheduler entry (both `_sched/` rows), so a terminal
/// refusal ends the watchdog chain instead of re-firing at WATCHDOG_MS
/// forever. Mirror of `webhook_onresult`'s cancel.
function schedCancel(key) {
    const id = crypto.sha256b64url(key);
    const byIdKey = "_sched/by_id/" + id;
    const raw = kv.get(byIdKey);
    if (raw !== null) {
        try {
            kv.delete(schedByTimeKey(BigInt(JSON.parse(raw).when_ns), id));
        } catch (_e) { /* corrupt record — the by_id delete below still ends it */ }
    }
    kv.delete(byIdKey);
}

function fireAttempt(owed, id, attempts) {
    __rove.fetch({
        url: owed.url,
        method: owed.method || "POST",
        body: owed.body || "",
        headers: Object.assign({}, owed.headers || {}, {
            "X-Rove-Schedule-Id": id,
            "X-Rove-Schedule-Version": String(attempts + 1),
        }),
        on_chunk: "__system/webhook_onresult",
        // Route the callback to the worker holding a §6.4-bound parked
        // continuation, if any (cross-worker-held-state Phase 2B) —
        // same contract as webhook.send's inline first fire.
        bound_send_id: id,
        ctx: {
            id: id,
            on_result: typeof owed.on_result === "string" ? owed.on_result : null,
            context: owed.context !== undefined ? owed.context : null,
        },
    });
}
