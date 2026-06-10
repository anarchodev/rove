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
//   3. Fire the fetch via the capability-scoped `__rove_fetch`, aimed
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

export default function () {
    const a = request.activation;
    if (a.kind !== "durable_wake") return { status: 200 };

    const msg = a.msg || {};
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
    if (typeof owed.url !== "string" || owed.url.length === 0) {
        kv.delete(markerKey);
        return { status: 200 };
    }

    // (2) watchdog re-arm — covers a crash between this fire and the
    // onresult commit.
    scheduler.after(WATCHDOG_MS, "__system/webhook_fire", { id: id }, { key: "_send/" + id });

    // (3) the attempt.
    const attempts = typeof owed.attempts === "number" ? owed.attempts : 0;
    __rove_fetch({
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
    return { status: 200 };
}
