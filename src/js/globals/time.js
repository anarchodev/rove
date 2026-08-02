// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Time coercion helpers — the single home for turning human time inputs
// (durations, ms-since-epoch, Date, ISO-8601) into the BigInt
// nanoseconds-since-epoch the scheduler verbs work in. `cron`,
// `schedule`, and `webhook.send` all coerce through here so the edge
// cases (finite checks, duration-vs-ISO, absolute-vs-delay) are defined
// once (docs/handler-shape.md — the connectionless verbs).
//
// - `time.toNs(x)`     absolute: bigint (ns, passthrough) | number
//                      (ms-since-epoch) | Date | string (a `"5m"`-style
//                      duration relative to now, else ISO-8601) |
//                      `null` → `0n` (fire ASAP).
// - `time.parseDuration(s)`  `<n><unit>` (unit ∈ s|m|h|d|w) → ms, or
//                      `null` if `s` isn't a duration (callers fall back
//                      to ISO).
// - `time.inToNs(x)`   a delay FROM NOW: number (ms) | duration string →
//                      absolute ns. (This is why `{at}` and `{in}` differ
//                      on a bare number: `at` is absolute, `in` is a
//                      delay.) `Date.now()` is replay-deterministic
//                      (pinned per activation).
//
// IIFE-wrapped (like every globals/ shim): a bare top-level declaration
// left in the script's global lexical scope corrupts the arenajs
// base-snapshot freeze — scope it.

(function () {
const NS_PER_MS = 1_000_000n;

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

/**
 * Time-coercion helpers shared by `cron` / `schedule` / `webhook.send`:
 * one place to turn human time inputs into the BigInt nanoseconds-since-
 * epoch the scheduler verbs use.
 *
 * @namespace time
 */
globalThis.time = {
  /**
   * Coerce an ABSOLUTE time input to BigInt nanoseconds-since-epoch.
   *
   * @param {bigint|number|Date|string|null} input - bigint (ns,
   *   passed through); number (ms-since-epoch, must be finite); Date;
   *   string (a `"30s"`/`"5m"`/`"2h"`/`"1d"`/`"1w"` duration relative to
   *   now, else ISO-8601); `null` → `0n` (fire ASAP).
   * @returns {bigint} Nanoseconds since epoch.
   * @throws {TypeError} On unrecognized / non-finite input.
   * @example
   * time.toNs("2h");                     // 2 hours from now
   * time.toNs("2026-06-01T03:00:00Z");   // absolute
   */
  toNs(input) {
    if (input == null) return 0n;
    if (typeof input === "bigint") return input;
    if (typeof input === "number") {
      if (!Number.isFinite(input)) {
        throw new TypeError("time.toNs: number must be finite (ms since epoch)");
      }
      return BigInt(Math.floor(input)) * NS_PER_MS;
    }
    if (input instanceof Date) return BigInt(input.getTime()) * NS_PER_MS;
    if (typeof input === "string") {
      const dur = _parseDuration(input);
      if (dur != null) return BigInt(Date.now() + dur) * NS_PER_MS;
      const ms = Date.parse(input);
      if (!Number.isNaN(ms)) return BigInt(ms) * NS_PER_MS;
    }
    throw new TypeError("time.toNs: unrecognized time input");
  },

  /**
   * Parse a duration string to milliseconds.
   *
   * @param {string} s - `<n><unit>`, unit ∈ `s|m|h|d|w` (e.g. `"5m"`).
   * @returns {number|null} Milliseconds, or `null` if `s` isn't a
   *   duration (callers fall back to ISO parsing).
   * @example
   * time.parseDuration("2h"); // 7200000
   */
  parseDuration(s) {
    return _parseDuration(s);
  },

  /**
   * Coerce a DELAY-FROM-NOW to an absolute BigInt ns-since-epoch.
   *
   * @param {number|string} input - number (milliseconds, must be
   *   finite) or a duration string (`"30s"`/`"5m"`/…).
   * @returns {bigint} `now + delay`, in nanoseconds since epoch.
   * @throws {TypeError} On a non-finite number, an unparseable duration
   *   string, or any other type.
   * @example
   * time.inToNs("30m"); // 30 minutes from now
   * time.inToNs(5000);  // 5 seconds from now
   */
  inToNs(input) {
    let ms;
    if (typeof input === "number") {
      if (!Number.isFinite(input)) {
        throw new TypeError("time.inToNs: number must be finite (ms delay)");
      }
      ms = Math.floor(input);
    } else if (typeof input === "string") {
      ms = _parseDuration(input);
      if (ms == null) throw new TypeError("time.inToNs: not a duration: " + input);
    } else {
      throw new TypeError("time.inToNs: expected a number (ms delay) or a duration string");
    }
    return BigInt(Date.now() + ms) * NS_PER_MS;
  },
};
})();
