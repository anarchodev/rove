// @rove/scheduler — durable, one-shot, absolute-time scheduled wakes
// (docs/primitive-gaps.md §2.6 + docs/durable-wake-plan.md). The
// canonical timer primitive every durable-timer feature (cron,
// webhook retry, delayed jobs, lease/TTL expiry, saga timeouts)
// composes on.
//
// Pure composition over `kv` + `crypto` + the capability-scoped engine
// wake (the engine keeps ONE next-fire watermark per tenant; this lib
// owns the queue/ordering as ordinary `_sched/` kv). At-least-once
// *FIRING*: a scheduled `target` runs at/after `whenNs`, possibly more
// than once across a crash — the target owns dedup (idempotency via
// `opts.key` / a kv guard). Not at-least-once *completion*: the lib
// does NOT retry a failed target; compose retry on top (webhook.send
// is exactly that — kv guard + re-arm).
//
//   // Fire `jobs/reminder` in 30 minutes with a payload.
//   scheduler.after(30 * 60_000, "jobs/reminder", { userId });
//
//   // Idempotent absolute wake; re-arming with the same key moves it.
//   scheduler.at(cron.dailyAt(3, 0), "jobs/cleanup", null,
//                { key: "cleanup/daily" });
//
//   // The target sees the wake on `request.activation`:
//   // jobs/reminder.mjs
//   export default function () {
//     const { id, msg, scheduled_at_ns } = request.activation;
//     // ...do the work; dedup on `id` if exactly-once matters...
//     return { status: 200 };
//   }
//
// Storage (ordinary tenant kv, owned by this lib — no reserved
// semantics; a customer *could* write these, only affecting their own
// tenant):
//   _sched/by_id/{id}                    -> {when_ns, target, msg, key?}
//   _sched/by_time/{when_ns_padded}/{id} -> ""   (time-ordered index)

// 1 s tick resolution (SCHED_TICK_RESOLUTION). `whenNs` rounds UP to
// the next tick; sub-second scheduling is unsupported (matches the
// engine's 1 Hz sweep + cron's ≥1000 ms floor).
const TICK_NS = 1_000_000_000n;

// Fixed-width zero-pad so lexicographic `_sched/by_time/` key order ==
// numeric fire-time order (mirrored in builtin_modules/scheduler_tick.mjs).
// 20 digits covers i64-ns (max ~9.22e18, 19 digits) with headroom.
const PAD_WIDTH = 20;

// ── Caps (docs/primitive-gaps.md §2.6.1) — fail-loud, operator notes ──
// These mirror the spec defaults. SCHED_MAX_OUTSTANDING is a depth
// ceiling (boot-recovery scan cost scales linearly past it);
// SCHED_MAX_MSG_BYTES bounds the durable+taped payload.
const SCHED_MAX_OUTSTANDING = 10_000;
const SCHED_MAX_MSG_BYTES = 16 * 1024;

const BY_ID_PREFIX = "_sched/by_id/";
const BY_TIME_PREFIX = "_sched/by_time/";

function _byIdKey(id) {
  return BY_ID_PREFIX + id;
}

function _byTimeKey(whenNs, id) {
  return BY_TIME_PREFIX + String(whenNs).padStart(PAD_WIDTH, "0") + "/" + id;
}

// Round `whenNs` (BigInt) up to the next tick boundary.
function _roundUpToTick(whenNs) {
  if (whenNs <= 0n) return 0n;
  return ((whenNs + TICK_NS - 1n) / TICK_NS) * TICK_NS;
}

// Deterministic id from an idempotency key: base64url-no-pad(sha256(key)),
// 43 chars (mirrors webhook.send's `handle`). Same key ⇒ same id ⇒
// last-write-wins.
function _idFromKey(key) {
  return base64url.encode(hex.decode(crypto.sha256(key)));
}

// Count outstanding schedules, throwing once the cap is reached. Pages
// `_sched/by_id/` (kv.prefix caps each page at 1000); cost scales with
// the tenant's actual outstanding count — cheap (one short page) for
// the common case of a handful of timers, paid only as a tenant nears
// the ceiling (the point at which we want to reject). Only invoked for
// genuinely-new ids (re-arming an existing key is last-write-wins, not
// a new outstanding entry).
function _enforceOutstandingCap() {
  let cursor = "";
  let count = 0;
  for (;;) {
    const page = kv.prefix(BY_ID_PREFIX, cursor, 1000) || [];
    count += page.length;
    if (count >= SCHED_MAX_OUTSTANDING) {
      throw new Error(
        "scheduler: SCHED_MAX_OUTSTANDING (" + SCHED_MAX_OUTSTANDING +
        ") reached; cancel pending wakes or raise the cap",
      );
    }
    if (page.length < 1000) return; // reached the end, under the cap
    cursor = page[page.length - 1].key;
  }
}

/**
 * Durable, one-shot, absolute-time scheduled wakes. The canonical
 * timer primitive — cron, webhook retry, delayed jobs, lease/TTL
 * expiry all compose on `scheduler.at`. At-least-once *firing*; the
 * target owns dedup + any retry.
 *
 * @namespace scheduler
 * @example
 * scheduler.after(30 * 60_000, "jobs/reminder", { userId });
 * scheduler.at(cron.dailyAt(3, 0), "jobs/cleanup", null,
 *              { key: "cleanup/daily" }); // idempotent, re-armable
 */
globalThis.scheduler = {
  /**
   * Schedule `target` to run at absolute time `whenNs`. At-least-once
   * firing — the target sees `request.activation = { kind:
   * "durable_wake", id, key, scheduled_at_ns, msg }` and owns dedup.
   * `whenNs` rounds up to the next 1 s tick. Re-arming = call again
   * with the same `opts.key` (moves `when`/`target`/`msg`,
   * last-write-wins).
   *
   * @param {bigint} whenNs - Absolute fire time, nanoseconds since
   *   epoch (e.g. from `cron.dailyAt` / `cron.fromNow`). A past time
   *   fires on the next sweep.
   * @param {string} target - Handler module specifier to invoke (same
   *   shape as a subscription module path).
   * @param {*} [msg] - JSON-serializable payload, surfaced as
   *   `request.activation.msg`. Capped at 16 KiB serialized.
   * @param {object} [opts]
   * @param {string} [opts.key] - Idempotency key. Same key ⇒ same id
   *   ⇒ last-write-wins. Omit for a fresh random id.
   * @returns {string} The stable schedule id.
   * @throws {TypeError} On a non-bigint `whenNs` or empty `target`.
   * @throws {Error} If `msg` exceeds 16 KiB or the outstanding cap is hit.
   * @example
   * const id = scheduler.at(cron.fromNow("1h"), "jobs/expire", { leaseId });
   */
  at(whenNs, target, msg, opts) {
    if (typeof whenNs !== "bigint") {
      throw new TypeError("scheduler.at: whenNs must be a bigint (nanoseconds since epoch)");
    }
    if (typeof target !== "string" || target.length === 0) {
      throw new TypeError("scheduler.at: target must be a non-empty module specifier");
    }
    const payload = msg === undefined ? null : msg;
    const msgJson = JSON.stringify(payload);
    // `JSON.stringify` returns undefined for non-serializable values
    // (e.g. a bare function); treat that as "null" rather than crashing
    // downstream JSON.parse.
    const msgJsonSafe = msgJson === undefined ? "null" : msgJson;
    if (msgJsonSafe.length > SCHED_MAX_MSG_BYTES) {
      throw new Error(
        "scheduler.at: msg exceeds SCHED_MAX_MSG_BYTES (" + SCHED_MAX_MSG_BYTES +
        "); store it in your own kv and pass a reference in msg",
      );
    }

    const key = (opts && typeof opts.key === "string" && opts.key.length > 0) ? opts.key : null;
    const id = key !== null ? _idFromKey(key) : crypto.randomUUID();
    const rounded = _roundUpToTick(whenNs);

    // Re-arm vs new: if this id already exists, it's an update
    // (last-write-wins) — drop the stale time-index entry if the fire
    // time moved, and skip the outstanding-cap check.
    const existingRaw = kv.get(_byIdKey(id));
    if (existingRaw !== null) {
      try {
        const old = JSON.parse(existingRaw);
        const oldWhen = BigInt(old.when_ns);
        if (oldWhen !== rounded) kv.delete(_byTimeKey(oldWhen, id));
      } catch (_e) {
        // Corrupt existing record — overwrite it wholesale below.
      }
    } else {
      _enforceOutstandingCap();
    }

    const record = { when_ns: String(rounded), target: target, msg: payload };
    if (key !== null) record.key = key;
    kv.set(_byIdKey(id), JSON.stringify(record));
    kv.set(_byTimeKey(rounded, id), "");
    return id;
  },

  /**
   * Convenience: schedule `target` `delayMs` milliseconds from now.
   * Rounds up to the next 1 s tick (so a sub-second delay fires at the
   * next tick).
   *
   * @param {number} delayMs - Delay from now in milliseconds (≤ 0 ⇒
   *   fire on the next sweep).
   * @param {string} target - Handler module specifier.
   * @param {*} [msg] - JSON-serializable payload (see {@link scheduler.at}).
   * @param {object} [opts]
   * @param {string} [opts.key] - Idempotency key (see {@link scheduler.at}).
   * @returns {string} The stable schedule id.
   * @throws {TypeError} On a non-number `delayMs` or empty `target`.
   * @example
   * scheduler.after(5000, "jobs/poll");
   */
  after(delayMs, target, msg, opts) {
    if (typeof delayMs !== "number" || !Number.isFinite(delayMs)) {
      throw new TypeError("scheduler.after: delayMs must be a finite number");
    }
    // Date.now() is replay-deterministic (pinned per activation).
    const whenNs = BigInt(Date.now() + Math.floor(delayMs)) * 1_000_000n;
    return this.at(whenNs, target, msg, opts);
  },

  /**
   * Cancel a scheduled wake by id. Removes both the `_sched/by_id` and
   * `_sched/by_time` entries. Idempotent: cancelling an unknown /
   * already-fired id returns `false`.
   *
   * @param {string} id - The id returned by `at` / `after` (or
   *   `_idFromKey(opts.key)`).
   * @returns {boolean} `true` iff an entry was removed.
   * @example
   * scheduler.cancel(id);
   */
  cancel(id) {
    if (typeof id !== "string" || id.length === 0) return false;
    const raw = kv.get(_byIdKey(id));
    if (raw === null) return false;
    try {
      const rec = JSON.parse(raw);
      kv.delete(_byTimeKey(BigInt(rec.when_ns), id));
    } catch (_e) {
      // Corrupt record — still drop the by_id entry below. A stale
      // by_time index entry self-heals (scheduler_tick deletes an
      // index entry whose by_id is gone).
    }
    kv.delete(_byIdKey(id));
    return true;
  },

  /**
   * Look up a scheduled wake by id.
   *
   * @param {string} id - The id returned by `at` / `after`.
   * @returns {{id: string, whenNs: bigint, target: string,
   *   key: (string|null)} | null} The schedule, or `null` if unknown /
   *   already fired.
   * @example
   * const s = scheduler.get(id);
   * if (s) console.log(s.target, s.whenNs);
   */
  get(id) {
    if (typeof id !== "string" || id.length === 0) return null;
    const raw = kv.get(_byIdKey(id));
    if (raw === null) return null;
    let rec;
    try {
      rec = JSON.parse(raw);
    } catch (_e) {
      return null;
    }
    return {
      id: id,
      whenNs: BigInt(rec.when_ns),
      target: rec.target,
      key: rec.key === undefined ? null : rec.key,
    };
  },
};
