// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Durable scheduled wake — the baked `__system/scheduler_tick`
// module (the durable-wake mechanism; docs/architecture/effects-and-handlers.md). Fired by the engine
// (`durable_wake.sweepDurableWakes`) in a tenant's context whenever
// that tenant's `next_wake_ns` watermark falls due, and once per
// tenant on leadership gain to reconstruct the watermark.
//
// Responsibilities (the JS half of the durable scheduler — the engine
// owns only the single per-tenant watermark + the resource caps):
//   1. Range-scan `_sched/by_time/` from the front for due entries
//      (≤ MAX_FIRES_PER_TICK).
//   2. Fan each due entry out to its `target` as a `durable_wake`
//      activation via the capability-scoped `__rove_fire_wake`,
//      handing it the entry's two `_sched/` keys to delete in the
//      target activation's OWN writeset — so the normal path fires
//      exactly once (at-least-once only on a crash between fire and
//      commit, which a boot/promotion re-fire covers).
//   3. Recompute the new minimum next-fire and install it via
//      `__rove_set_wake`, so the engine's 1 Hz sweep re-fires this
//      module at the right time (and stops re-firing once drained).
//
// Resolved by the runtime via `__system/` module path resolution
// (not in any tenant's deployment files); compiled to bytecode once
// at NodeState init and shared across every tenant. Runs with
// `is_system_module = true`, so the gated `__rove.wake.set` /
// `__rove.wake.fire` ops (which throw for customer code) are reachable.

const BY_TIME_PREFIX = "_sched/by_time/";
// `_sched/by_id/{id}` record version (`format-versioning.md` §1f). A
// record this tick cannot read is dropped WITH its index entry — firing
// a target named by fields we may be misreading is worse than not
// firing, and leaving the pair would retry the misread every tick.
// The version an UNSTAMPED record is. Permanently 1: every `_`-namespace
// gained its `v` in one commit, so a row without the field is the shape v1
// describes. It must NOT track the current version — when a format reaches
// v2, an unstamped row is still v1, and defaulting to "whatever we read
// now" would silently reinterpret it.
const UNSTAMPED_V = __rove.formats.unstamped;

const SCHED_REC_V = __rove.formats.sched;

const BY_ID_PREFIX = "_sched/by_id/";

// Thundering-herd bound: at most this many wakes fire per tick when
// many share a due-time; the remainder carries to the next tick.
// (the per-tick fire cap in the durable scheduler,
// docs/architecture/effects-and-handlers.md; a baked constant for now,
// a possible future operator knob.)
const MAX_FIRES_PER_TICK = 256;

// `_sched/by_time/` key = BY_TIME_PREFIX + <whenNs zero-padded to
// WIDTH> + "/" + <id>. The padding (mirrored in globals/scheduler.js)
// makes lexicographic key order == numeric time order, so a forward
// prefix scan yields entries in fire-time order.
const PAD_WIDTH = 20;

export default function () {
    // Date.now() is replay-deterministic (pinned per activation). ms→ns.
    const nowNs = BigInt(Date.now()) * 1_000_000n;

    // +1 over the cap so we can tell "more due entries remain" from
    // "scan reached the end."
    const page = kv.prefix(BY_TIME_PREFIX, "", MAX_FIRES_PER_TICK + 1) || [];

    let fired = 0;
    let nextWatermark = 0n; // 0n ⇒ "no wake pending"
    let deferred = 0; // due entries this build cannot read (see below)

    for (let i = 0; i < page.length; i++) {
        const key = page[i].key;
        const rest = key.slice(BY_TIME_PREFIX.length); // "<padded>/<id>"
        const slash = rest.indexOf("/");
        if (slash < 0) {
            // Malformed index key — drop it (its own writeset; not a fire).
            kv.delete(key);
            continue;
        }
        const whenNs = BigInt(rest.slice(0, slash));
        const id = rest.slice(slash + 1);

        if (whenNs > nowNs) {
            // First future entry → the next watermark. Done.
            nextWatermark = whenNs;
            break;
        }
        if (fired >= MAX_FIRES_PER_TICK) {
            // Due, but the per-tick cap is spent. Re-fire ASAP next
            // sweep to keep draining the backlog.
            nextWatermark = nowNs;
            break;
        }

        const byIdKey = BY_ID_PREFIX + id;
        const recRaw = kv.get(byIdKey);
        if (recRaw == null) {
            // Orphaned index entry (by_id cancelled/lost but by_time
            // left behind). Clean the stale index in THIS module's
            // own writeset; nothing to fire.
            kv.delete(key);
            continue;
        }
        let rec;
        try {
            rec = JSON.parse(recRaw);
        } catch (_e) {
            kv.delete(byIdKey);
            kv.delete(key);
            continue;
        }
        // An ABSENT `v` reads as v1 — the pre-stamp shape — because
        // adding the field changed NOTHING else. `{when_ns, target, msg,
        // key?, armed_by?}` is exactly what this reader wants, so a row
        // without the stamp is fully readable and refusing it would
        // discard a wake the customer armed over a field that carries no
        // information this code needs.
        //
        // That makes v0→v1 the trivial migration: a pure field addition,
        // whose upconversion IS the default below. No table, no branch.
        //
        // And it is permanent, not a genesis-era accommodation. `_sched/`
        // is in `SHIM_WRITABLE_PREFIXES` — the raw shape is documented as
        // one any handler may write directly — so unstamped rows are not
        // only legacy, they arrive whenever a customer authors one.
        //
        // A NON-numeric `v` is different: something claimed a version and
        // it is not one, which is corruption, and the unparseable branch
        // above already owns that answer.
        if (rec.v !== undefined && typeof rec.v !== "number") {
            kv.delete(byIdKey);
            kv.delete(key);
            continue;
        }
        const rec_v = rec.v ?? UNSTAMPED_V;
        if (rec_v !== SCHED_REC_V) {
            // A version we do not implement, from something that DOES
            // version its records. Recoverable by another build — during
            // a rolling upgrade the node beside this one reads it fine —
            // so deleting it would destroy a customer's scheduled work on
            // an ordinary deploy, and it is the OLD node that would do
            // the destroying.
            //
            // Touch neither key, fire nothing, count it. Both rows stay
            // exactly where the build that understands them will look.
            deferred++;
            continue;
        }

        const target = rec.target;
        const msg = rec.msg === undefined ? null : rec.msg;
        const wakeKey = rec.key === undefined || rec.key === null ? null : rec.key;
        // Provenance for the fired record's `_parent` tag; "" = absent
        // (entries written before the field, or armed outside a saga).
        const armedBy = typeof rec.armed_by === "string" ? rec.armed_by : "";

        // Fan out. The two cleanup keys ride into the target's writeset
        // (see fireDurableWakeActivation) so the delete commits with the
        // handler's effects — exactly-once on the normal path.
        //
        // A `false` return means the engine refused the target (a baked
        // module that is not wake-targetable — rove#495). The entry never
        // dispatched, so nothing else will delete its rows: drop them here,
        // exactly as the corrupt-record paths above do. Leaving them would
        // re-offer the same refused entry on every tick forever.
        const ok = __rove.wake.fire(
            target,
            id,
            wakeKey,
            String(whenNs),
            JSON.stringify(msg),
            [byIdKey, key],
            armedBy,
        );
        if (!ok) {
            kv.delete(byIdKey);
            kv.delete(key);
            continue;
        }
        fired++;
    }

    // Watermark policy. If anything fired this tick, set the watermark
    // to NOW so the next 1 Hz sweep re-scans from the front — the
    // owed-sweep's "re-fire while work remains" model. By then each
    // fired entry's `_sched/` deletes have committed (the entry is
    // gone), so the re-scan only re-fires entries that DIDN'T commit:
    // a target that threw (rolled back its cleanup) or a crash between
    // fire and commit. This is what makes the firing contract hold
    // without a per-tick full prefix scan — the watermark advances
    // past a "fired" entry only after the next tick confirms it's
    // gone. A backlog beyond the per-tick cap drains the same way (one
    // batch per tick). When nothing fired, the watermark is the first
    // future entry (or 0n for "no wake pending").
    // A deferred entry has to keep the tick alive. It sits BEFORE
    // `nextWatermark` (it is due), so handing the watermark the first
    // future entry — or 0n, "no wake pending" — would stop the sweep and
    // strand the entry even after a build that can read it takes over.
    // Re-arming at `nowNs` costs one tick per second for as long as the
    // skew lasts, which is the scheduler's normal cadence, not extra load.
    if (deferred > 0) {
        console.warn("scheduler_tick: " + deferred + " due entr" +
                     (deferred === 1 ? "y" : "ies") +
                     " written at a _sched/by_id version this build does not read (v" +
                     SCHED_REC_V + ") — deferred, not dropped");
    }
    __rove.wake.set(String(fired > 0 || deferred > 0 ? nowNs : nextWatermark));
    return { status: 200 };
}
