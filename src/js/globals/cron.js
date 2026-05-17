// @rove/cron — time helpers for scheduling http.send fires.
//
// The platform's `http.send({fire_at_ns: BigInt})` already does
// scheduled delivery; this module is just convenience for converting
// human time inputs (durations, "tomorrow at 3am", crontab strings)
// to the BigInt nanosecond-since-epoch the binding expects.
//
//   // Daily cleanup, self-rescheduling.
//   // tasks/cleanup.mjs
//   export default function () {
//     // ...do the daily work...
//     http.send({
//       url: `https://${request.host}${request.path}`,
//       fire_at_ns: cron.dailyAt(3, 0),  // tomorrow at 03:00
//     });
//   }
//
//   // Fire once in 30 minutes.
//   http.send({ url, fire_at_ns: cron.fromNow("30m") });
//
//   // Fire on the next cron expression match.
//   http.send({ url, fire_at_ns: cron.next("0 3 * * *") }); // daily 3am

const NS_PER_MS = 1_000_000n;

/**
 * Time helpers that convert human inputs (durations, daily/weekly
 * slots, crontab strings) into the BigInt nanoseconds-since-epoch
 * that `http.send({fire_at_ns})` expects. All slot math is UTC.
 *
 * @namespace cron
 * @example
 * // Daily 03:00 UTC cleanup, self-rescheduling.
 * http.send({ url, fire_at_ns: cron.dailyAt(3, 0) });
 * @example
 * http.send({ url, fire_at_ns: cron.fromNow("30m") }); // in 30 min
 * http.send({ url, fire_at_ns: cron.next("0 3 * * *") }); // daily 3am
 */
globalThis.cron = {
  /**
   * Coerce a time input to BigInt nanoseconds-since-epoch.
   *
   * @param {bigint|number|Date|string|null} input - BigInt (ns,
   *   passed through); number/Date (ms-since-epoch); string
   *   (duration suffix like `"30s"`/`"5m"`/`"2h"`/`"1d"`/`"1w"`
   *   relative to now, or ISO-8601); `null` → `0n` (fire ASAP).
   * @returns {bigint} Nanoseconds since epoch.
   * @throws {TypeError} On unrecognized input.
   * @example
   * cron.toFireAtNs("2h");                     // 2 hours from now
   * cron.toFireAtNs("2026-06-01T03:00:00Z");   // absolute
   */
  toFireAtNs(input) {
    if (input == null) return 0n;
    if (typeof input === "bigint") return input;
    if (typeof input === "number") return BigInt(Math.floor(input)) * NS_PER_MS;
    if (input instanceof Date) return BigInt(input.getTime()) * NS_PER_MS;
    if (typeof input === "string") {
      const dur = _parseDuration(input);
      if (dur != null) return BigInt(Date.now() + dur) * NS_PER_MS;
      const ms = Date.parse(input);
      if (!Number.isNaN(ms)) return BigInt(ms) * NS_PER_MS;
    }
    throw new TypeError("cron.toFireAtNs: unrecognized time input");
  },

  /**
   * Parse a duration string to milliseconds.
   *
   * @param {string} s - `<n><unit>`, unit ∈ `s|m|h|d|w`
   *   (e.g. `"5m"`, `"1w"`).
   * @returns {number|null} Milliseconds, or `null` if `s` isn't a
   *   duration (callers fall back to ISO parsing).
   * @example
   * cron.parseDuration("2h"); // 7200000
   */
  parseDuration(s) {
    return _parseDuration(s);
  },

  /**
   * `now + parseDuration(s)` as a fire time.
   *
   * @param {string} s - Duration string (see
   *   {@link cron.parseDuration}).
   * @returns {bigint} Nanoseconds since epoch.
   * @throws {TypeError} If `s` isn't a duration.
   * @example
   * http.send({ url, fire_at_ns: cron.fromNow("30m") });
   */
  fromNow(s) {
    const dur_ms = _parseDuration(s);
    if (dur_ms == null) throw new TypeError("cron.fromNow: not a duration: " + s);
    return BigInt(Date.now() + dur_ms) * NS_PER_MS;
  },

  /**
   * Next occurrence of `hour:minute` UTC; tomorrow's slot if today's
   * has passed.
   *
   * @param {number} hour - 0–23.
   * @param {number} minute - 0–59.
   * @returns {bigint} Nanoseconds since epoch.
   * @throws {RangeError} If `hour`/`minute` are out of range.
   * @example
   * cron.dailyAt(3, 0); // next 03:00 UTC
   */
  dailyAt(hour, minute) {
    if (!Number.isInteger(hour) || hour < 0 || hour > 23) {
      throw new RangeError("cron.dailyAt: hour must be 0..23");
    }
    if (!Number.isInteger(minute) || minute < 0 || minute > 59) {
      throw new RangeError("cron.dailyAt: minute must be 0..59");
    }
    const now = new Date();
    const target = new Date(Date.UTC(
      now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(),
      hour, minute, 0, 0,
    ));
    if (target.getTime() <= now.getTime()) {
      target.setUTCDate(target.getUTCDate() + 1);
    }
    return BigInt(target.getTime()) * NS_PER_MS;
  },

  /**
   * Next occurrence of `dayOfWeek` at `hour:minute` UTC.
   *
   * @param {number} dayOfWeek - 0=Sunday … 6=Saturday.
   * @param {number} hour - 0–23.
   * @param {number} minute - 0–59.
   * @returns {bigint} Nanoseconds since epoch.
   * @throws {RangeError} If `dayOfWeek` is out of range.
   * @example
   * cron.weeklyAt(1, 9, 0); // next Monday 09:00 UTC
   */
  weeklyAt(dayOfWeek, hour, minute) {
    if (!Number.isInteger(dayOfWeek) || dayOfWeek < 0 || dayOfWeek > 6) {
      throw new RangeError("cron.weeklyAt: dayOfWeek must be 0..6");
    }
    const now = new Date();
    const target = new Date(Date.UTC(
      now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(),
      hour, minute, 0, 0,
    ));
    let diff = (dayOfWeek - target.getUTCDay() + 7) % 7;
    if (diff === 0 && target.getTime() <= now.getTime()) diff = 7;
    target.setUTCDate(target.getUTCDate() + diff);
    return BigInt(target.getTime()) * NS_PER_MS;
  },

  /**
   * Top of the next hour (UTC).
   *
   * @returns {bigint} Nanoseconds since epoch.
   * @example
   * http.send({ url, fire_at_ns: cron.hourly() });
   */
  hourly() {
    const now = new Date();
    const next = new Date(now.getTime());
    next.setUTCMinutes(0, 0, 0);
    next.setUTCHours(next.getUTCHours() + 1);
    return BigInt(next.getTime()) * NS_PER_MS;
  },

  /**
   * Next match of a 5-field crontab expression (UTC), at minute
   * granularity. Day-of-month / day-of-week follow Vixie cron: when
   * both are restricted, a match on *either* counts.
   *
   * Fields: `minute hour day-of-month month day-of-week`. Each
   * accepts `*` (any), `N`, `N,M,...` (list), `N-M` (range), or a
   * trailing `/N` step on `*` or a range (e.g. a star then slash-15
   * in the minute field = every 15 minutes).
   *
   * @param {string} expr - e.g. `"0 3 * * *"` (daily 03:00) or
   *   `"0 9 * * 1-5"` (weekdays 09:00).
   * @param {number} [now_ms] - Base time (ms since epoch); defaults
   *   to `Date.now()`. Mainly for testing.
   * @returns {bigint} Nanoseconds since epoch of the next match.
   * @throws {TypeError} On a malformed expression/field.
   * @throws {Error} If no match within a 4-year window.
   * @example
   * http.send({ url, fire_at_ns: cron.next("0 3 * * *") });
   */
  next(expr, now_ms) {
    const fields = String(expr).trim().split(/\s+/);
    if (fields.length !== 5) {
      throw new TypeError("cron.next: expected 5 fields (minute hour dom month dow), got " + fields.length);
    }
    const [minF, hourF, domF, monthF, dowF] = fields;
    const min_set = _parseField(minF, 0, 59);
    const hour_set = _parseField(hourF, 0, 23);
    const dom_set = _parseField(domF, 1, 31);
    const month_set = _parseField(monthF, 1, 12);
    const dow_set = _parseField(dowF, 0, 6);

    const now = new Date(now_ms != null ? now_ms : Date.now());
    // Round up to the next minute boundary — cron only fires at
    // minute granularity.
    const candidate = new Date(Date.UTC(
      now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(),
      now.getUTCHours(), now.getUTCMinutes() + 1, 0, 0,
    ));

    // Brute-force search up to ~4 years out (worst-case: every-29-Feb
    // on a non-leap-year-anchored search). Fast in practice — most
    // expressions match within minutes/hours.
    const limit_ms = candidate.getTime() + 4 * 366 * 24 * 60 * 60 * 1000;
    while (candidate.getTime() < limit_ms) {
      const month = candidate.getUTCMonth() + 1; // crontab months are 1-12
      const dom = candidate.getUTCDate();
      const dow = candidate.getUTCDay();
      if (!month_set.has(month)) {
        candidate.setUTCMonth(candidate.getUTCMonth() + 1);
        candidate.setUTCDate(1);
        candidate.setUTCHours(0, 0, 0, 0);
        continue;
      }
      // Day matches if EITHER dom or dow matches when both are
      // restricted (Vixie cron's quirk); when one is `*` use the
      // other's check.
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
  },
};

function _parseDuration(s) {
  if (typeof s !== "string") return null;
  const m = s.match(/^(\d+)([smhdw])$/);
  if (!m) return null;
  const n = parseInt(m[1], 10);
  switch (m[2]) {
    case "s": return n * 1000;
    case "m": return n * 60 * 1000;
    case "h": return n * 60 * 60 * 1000;
    case "d": return n * 24 * 60 * 60 * 1000;
    case "w": return n * 7 * 24 * 60 * 60 * 1000;
  }
  return null;
}

function _parseField(field, min, max) {
  // Returns a Set of integer values the field matches.
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
