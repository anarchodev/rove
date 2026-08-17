// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
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
// activation carrying `{ spec, target, ctx }` as `request.ctx`
// and the cron's stable idempotency key as `request.activation.key`.
//
// The crontab `next`-fire computation and the durable-scheduler arm are
// INLINED (over the ambient `kv`/`crypto`): as a baked `__system/*`
// module this runs post-harden and can reach neither the customer-facing
// `@rewind/cron`/`@rewind/schedule` packages nor the private
// `_system.sched` closure. The inlined arm writes the exact `_sched/`
// rows globals/schedule.js + builtin_modules/scheduler_tick.mjs use.

const NS_PER_MS = 1_000_000n;
const SCHED_TICK_NS = 1_000_000_000n; // 1 s tick; fire times round up

// ── crontab next-fire (inlined from globals/cron.js `next` + `_parseField`) ──
function cronParseField(field, min, max) {
    const out = new Set();
    for (const part of field.split(",")) {
        let p = part;
        let step = 1;
        const slash = p.indexOf("/");
        if (slash >= 0) {
            step = parseInt(p.slice(slash + 1), 10);
            p = p.slice(0, slash);
            if (!Number.isInteger(step) || step < 1) {
                throw new TypeError("cron.next: bad step in field: " + field);
            }
        }
        let lo, hi;
        if (p === "*") {
            lo = min; hi = max;
        } else {
            const dash = p.indexOf("-");
            if (dash >= 0) {
                lo = parseInt(p.slice(0, dash), 10);
                hi = parseInt(p.slice(dash + 1), 10);
            } else {
                lo = hi = parseInt(p, 10);
            }
            if (!Number.isInteger(lo) || !Number.isInteger(hi) || lo < min || hi > max || lo > hi) {
                throw new TypeError("cron.next: bad range in field: " + field);
            }
        }
        for (let v = lo; v <= hi; v += step) out.add(v);
    }
    return out;
}

function cronNext(expr) {
    const fields = String(expr).trim().split(/\s+/);
    if (fields.length !== 5) {
        throw new TypeError("cron.next: expected 5 fields (minute hour dom month dow), got " + fields.length);
    }
    const [minF, hourF, domF, monthF, dowF] = fields;
    const min_set = cronParseField(minF, 0, 59);
    const hour_set = cronParseField(hourF, 0, 23);
    const dom_set = cronParseField(domF, 1, 31);
    const month_set = cronParseField(monthF, 1, 12);
    const dow_set = cronParseField(dowF, 0, 6);

    const now = new Date(Date.now());
    const candidate = new Date(Date.UTC(
        now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(),
        now.getUTCHours(), now.getUTCMinutes() + 1, 0, 0,
    ));
    const limit_ms = candidate.getTime() + 4 * 366 * 24 * 60 * 60 * 1000;
    while (candidate.getTime() < limit_ms) {
        const month = candidate.getUTCMonth() + 1;
        const dom = candidate.getUTCDate();
        const dow = candidate.getUTCDay();
        if (!month_set.has(month)) {
            candidate.setUTCMonth(candidate.getUTCMonth() + 1);
            candidate.setUTCDate(1);
            candidate.setUTCHours(0, 0, 0, 0);
            continue;
        }
        const dom_unrestricted = domF === "*";
        const dow_unrestricted = dowF === "*";
        const dom_ok = dom_set.has(dom);
        const dow_ok = dow_set.has(dow);
        const day_matches = (dom_unrestricted && dow_unrestricted) ||
            (dom_unrestricted ? dow_ok : (dow_unrestricted ? dom_ok : (dom_ok || dow_ok)));
        if (!day_matches) {
            candidate.setUTCDate(candidate.getUTCDate() + 1);
            candidate.setUTCHours(0, 0, 0, 0);
            continue;
        }
        if (!hour_set.has(candidate.getUTCHours())) {
            candidate.setUTCHours(candidate.getUTCHours() + 1);
            candidate.setUTCMinutes(0, 0, 0);
            continue;
        }
        if (!min_set.has(candidate.getUTCMinutes())) {
            candidate.setUTCMinutes(candidate.getUTCMinutes() + 1);
            continue;
        }
        return BigInt(candidate.getTime()) * NS_PER_MS;
    }
    throw new Error("cron.next: no match within 4-year window for " + expr);
}

// ── durable-scheduler arm (inlined from the private _system.sched core) ──
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
        // Re-arm (same key ⇒ same id, last-write-wins): drop the stale
        // time-index entry if the fire time moved.
        try {
            const old = JSON.parse(prev);
            const oldWhen = BigInt(old.when_ns);
            if (oldWhen !== rounded) kv.delete(schedByTimeKey(oldWhen, id));
        } catch (_e) { /* corrupt prior record — overwrite below */ }
    }
    const rec = { when_ns: String(rounded), target: target, msg: msg === undefined ? null : msg };
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

    const { spec, target, ctx } = request.ctx || {};
    if (typeof spec !== "string" || typeof target !== "string") {
        // Malformed registration — drop it (the fired entry's cleanup
        // deletes already committed; not re-arming ends the cron).
        return { status: 200 };
    }

    // Re-arm for the next crontab occurrence. Same key ⇒ same id ⇒
    // last-write-wins, so a cron stays exactly one durable entry.
    try {
        const nextNs = cronNext(spec);
        schedArm(nextNs, "__system/cron_tick", { spec, target, ctx }, a.key);
    } catch (_e) {
        // A spec that no longer parses (shouldn't happen — `cron()`
        // validated it) just stops recurring rather than crashing.
    }

    // Dispatch the actual target as its own connectionless one-shot
    // (fires on the next tick). cron_tick is a durable_wake, so it
    // can't chain via the disposition return (those are inert on a
    // wake origin); routing through the scheduler keeps the target a
    // clean independent activation.
    schedArm(BigInt(Date.now()) * NS_PER_MS, target, ctx === undefined ? null : ctx, null);

    return { status: 200 };
}
