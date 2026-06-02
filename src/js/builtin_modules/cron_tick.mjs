// Handler-surface Phase 5 — the recurrence engine behind the public
// `cron(spec, target, ctx?)` verb (docs/handler-shape.md §2.4). A
// `cron(...)` registration schedules a durable wake aimed at THIS
// baked module; each fire (a) re-arms itself for the next crontab
// occurrence and (b) dispatches the customer's `target` as its own
// connectionless fire. Recurrence rides the gap-2.6 scheduler
// (durable, survives leader change) — no engine support beyond the
// one-shot durable wake; "recurring = a one-shot that re-arms itself."
//
// Both effects commit atomically with this activation (the fired
// entry's `_sched/` keys are deleted in this same writeset by
// fireDurableWakeActivation), so a crash before commit leaves the
// original entry for an at-least-once re-fire.
//
// Resolved via `__system/` module resolution; compiled once at
// NodeState init, shared across tenants. Runs as a `durable_wake`
// activation carrying `{ spec, target, ctx }` as `request.activation.msg`
// and the cron's stable idempotency key as `request.activation.key`.
export default function () {
    const a = request.activation;
    if (a.kind !== "durable_wake") return { status: 200 };

    const { spec, target, ctx } = a.msg || {};
    if (typeof spec !== "string" || typeof target !== "string") {
        // Malformed registration — drop it (the fired entry's cleanup
        // deletes already committed; not re-arming ends the cron).
        return { status: 200 };
    }

    // Re-arm for the next crontab occurrence. Same key ⇒ same id ⇒
    // last-write-wins, so a cron stays exactly one durable entry.
    try {
        const nextNs = cron.next(spec);
        scheduler.at(nextNs, "__system/cron_tick", { spec, target, ctx }, { key: a.key });
    } catch (_e) {
        // A spec that no longer parses (shouldn't happen — `cron()`
        // validated it) just stops recurring rather than crashing.
    }

    // Dispatch the actual target as its own connectionless one-shot
    // (fires on the next tick). cron_tick is a durable_wake, so it
    // can't chain via the disposition return (those are inert on a
    // wake origin); routing through the scheduler keeps the target a
    // clean independent activation.
    scheduler.after(0, target, ctx === undefined ? null : ctx);

    return { status: 200 };
}
