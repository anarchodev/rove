// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// The durable one-shot scheduler core — installed as the PRIVATE
// `_system.sched` (deleted from customer scope by `_harden.js`, like
// every other `_system.*` capability). The customer-facing verb is the
// `@rewind/schedule` package; this ambient core exists only so the
// engine's own primitives can compose durable wakes: the `webhook.js`
// shim captures `_system.sched` at eval time (durable send re-arm), and
// the baked `__system/*` modules that need it (cron_tick, webhook_fire,
// webhook_onresult) write the same `_sched/` rows directly over kv (they
// run post-harden and can't see this closure — see those files).
// `schedule`/`cron`/`webhook.send` are the three connectionless verbs.
//
// `_arm`/`cancel`/`get` and the `{at}`/`{in}` coercions + `opts.key`
// idempotency all live here (the former `scheduler` lib folded in
// 2026-07-06); the `@rewind/schedule` package is the same surface.
//
// Pure composition over `kv` + `crypto` + the capability-scoped engine
// wake (the engine keeps ONE next-fire watermark per tenant; this lib
// owns the queue/ordering as ordinary `_sched/` kv). At-least-once
// *FIRING*: a scheduled `target` runs at/after the fire time, possibly
// more than once across a crash — the target owns dedup (idempotency
// via `opts.key` / a kv guard). Not at-least-once *completion*: the
// lib does NOT retry a failed target; compose retry on top
// (webhook.send is exactly that — kv guard + re-arm).
//
// Storage (ordinary tenant kv, owned by this lib — no reserved
// semantics; a customer *could* write these, only affecting their own
// tenant):
//   _sched/by_id/{id}                    -> {when_ns, target, msg, key?}
//   _sched/by_time/{when_ns_padded}/{id} -> ""   (time-ordered index)
//
// Evaluated as a global script after `time.js` (it coerces `{ at }` /
// `{ in }` through the shared `time` library; `cron.*` fire-time helpers
// are still handy inputs to `{ at }`).

(function () {

  // 1 s tick resolution (SCHED_TICK_RESOLUTION). Fire times round UP to
  // the next tick; sub-second scheduling is unsupported (matches the
  // engine's 1 Hz sweep + cron's ≥1000 ms floor).
  const TICK_NS = 1_000_000_000n;

  // Fixed-width zero-pad so lexicographic `_sched/by_time/` key order ==
  // numeric fire-time order (mirrored in builtin_modules/scheduler_tick.mjs).
  // 20 digits covers i64-ns (max ~9.22e18, 19 digits) with headroom.
  const PAD_WIDTH = 20;

  // ── Caps (the durable-wake primitive, docs/effect-algebra.md) — fail-loud, operator notes ──
  // SCHED_MAX_OUTSTANDING is a depth ceiling (boot-recovery scan cost
  // scales linearly past it); SCHED_MAX_MSG_BYTES bounds the
  // durable+taped payload.
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
    return crypto.sha256b64url(key);
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
          "schedule: SCHED_MAX_OUTSTANDING (" + SCHED_MAX_OUTSTANDING +
          ") reached; cancel pending wakes or raise the cap",
        );
      }
      if (page.length < 1000) return; // reached the end, under the cap
      cursor = page[page.length - 1].key;
    }
  }

  // Absolute `{at}` and delay `{in}` both coerce through the shared
  // `time` library (bigint ns | ms-since-epoch | Date | duration | ISO
  // for `at`; ms | duration for `in`). Date.now() is replay-
  // deterministic (pinned per activation).
  function _coerceAt(x) {
    return time.toNs(x);
  }

  function _coerceIn(x) {
    return time.inToNs(x);
  }

  // The arm: validate, cap, write the two `_sched/` rows. Shared by the
  // verb and every internal composer (cron ticks, webhook retry).
  function _arm(whenNs, target, msg, opts) {
    if (typeof target !== "string" || target.length === 0) {
      throw new TypeError("schedule: target must be a non-empty module specifier");
    }
    const payload = msg === undefined ? null : msg;
    const msgJson = JSON.stringify(payload);
    // `JSON.stringify` returns undefined for non-serializable values
    // (e.g. a bare function); treat that as "null" rather than crashing
    // downstream JSON.parse.
    const msgJsonSafe = msgJson === undefined ? "null" : msgJson;
    if (msgJsonSafe.length > SCHED_MAX_MSG_BYTES) {
      throw new Error(
        "schedule: ctx exceeds SCHED_MAX_MSG_BYTES (" + SCHED_MAX_MSG_BYTES +
        "); store it in your own kv and pass a reference",
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
  }

  /**
   * The durable one-shot timer: run `target` once, at a time — a fresh
   * connectionless activation that survives crashes and leader
   * changes. At-least-once *firing* (the target owns dedup); the lib
   * does not retry a failed target — compose retry on top. Recurrence
   * is `cron(spec, target)`; a connection-scoped delay (dies with the
   * caller) is `after.ms`.
   *
   * @namespace schedule
   * @example
   * const id = schedule({ in: "24h" }, "jobs/reminder", { user: "ada" });
   * // ...or an absolute time, idempotent under a stable key:
   * schedule({ at: cron.dailyAt(3, 0) }, "jobs/cleanup", null,
   *          { key: "cleanup/daily" }); // re-arm = same key, last-write-wins
   */
  /**
   * Schedule `target` to run once. `when` is `{ in }` — a delay
   * (number = ms, or a duration string `"30s"`/`"5m"`/`"2h"`/`"1d"`) —
   * or `{ at }` — an absolute time (Date, ISO-8601 string, number =
   * ms-since-epoch, or bigint = ns for exact composition with the
   * `cron.*` helpers). Fire times round up to the next 1 s tick.
   *
   * The target runs as a fresh activation: your `ctx` arrives as
   * `request.ctx`; delivery metadata (`id`, `key`, `scheduledAtNs`) on
   * `request.activation`. At-least-once firing — dedup on `id` (or
   * your `opts.key`) if exactly-once matters.
   *
   * @param {object} when - `{ in: number|string }` or
   *   `{ at: bigint|number|Date|string }`.
   * @param {string} target - Handler module specifier to invoke: a bare
   *   module (`"jobs/reminder"` → its `default` export) or the
   *   `module.method` form (`"reports.mjs.weekly"` → the `weekly` export).
   *   The method suffix is only recognized after a `.mjs`/`.js` module —
   *   so `"reports.mjs"` is a whole module, and to name a method include
   *   the extension.
   * @param {*} [ctx] - JSON-serializable payload, surfaced as
   *   `request.ctx`. Capped at 16 KiB serialized.
   * @param {object} [opts]
   * @param {string} [opts.key] - Idempotency key. Same key ⇒ same id ⇒
   *   last-write-wins (re-arming moves the fire time — the
   *   self-re-arming interval recipe). Omit for a fresh random id.
   * @returns {string} The stable schedule id (feed to `schedule.cancel`
   *   / `schedule.get`).
   * @throws {TypeError} On a malformed `when` or empty `target`.
   * @throws {Error} If `ctx` exceeds 16 KiB or the outstanding cap is hit.
   * @example
   * const id = schedule({ in: 5000 }, "jobs/poll");
   * schedule({ in: "1h" }, "jobs/expire", { leaseId: "l-7" });
   */
  _system.sched = Object.assign(function schedule(when, target, ctx, opts) {
    let whenNs;
    if (when && when.at !== undefined) whenNs = _coerceAt(when.at);
    else if (when && when.in !== undefined) whenNs = _coerceIn(when.in);
    else throw new TypeError("schedule(when, target, ctx?, opts?): when must be { at } or { in }");
    return _arm(whenNs, target, ctx, opts);
  }, {
    /**
     * Cancel a scheduled wake by id. Removes both the `_sched/by_id`
     * and `_sched/by_time` entries. Idempotent: cancelling an unknown /
     * already-fired id returns `false`.
     *
     * @param {string} id - The id `schedule(...)` returned.
     * @returns {boolean} `true` iff an entry was removed.
     * @example
     * const id = schedule({ in: "1h" }, "jobs/expire");
     * if (!schedule.cancel(id)) throw new Error("cancel missed");
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
     * @param {string} id - The id `schedule(...)` returned.
     * @returns {{id: string, whenNs: bigint, target: string,
     *   key: (string|null)} | null} The schedule, or `null` if unknown /
     *   already fired.
     * @example
     * const id = schedule({ in: "1h" }, "jobs/expire");
     * const s = schedule.get(id);
     * if (!s || s.target !== "jobs/expire") throw new Error("lookup failed");
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
  });
})();
