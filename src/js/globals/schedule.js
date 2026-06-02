// Public `schedule` verb — a one-shot connectionless durable timer
// (docs/handler-shape.md §2.4). Run `target` once, at a time. A
// connectionless trigger: a fresh durable activation with no held
// socket, surviving leader changes (rides the gap-2.6 `scheduler`).
//
// Thin coercion over `scheduler.at` — `{ at }` is an absolute time,
// `{ in }` is a delay from now. The target sees the `ctx` as
// `request.activation.msg`. `schedule`/`cron`/`webhook.send` are the
// three connectionless verbs; `scheduler.*` is the lower-level lib they
// compose on.
//
// Evaluated as a global script after `scheduler.js` + `cron.js` (it
// reuses `cron.parseDuration` for `{ in }` duration strings).

(function () {
  const NS_PER_MS = 1_000_000n;

  // Absolute time → ns-since-epoch. bigint = ns (passthrough); number =
  // ms-since-epoch; Date; string = ISO-8601.
  function _coerceAt(x) {
    if (typeof x === "bigint") return x;
    if (typeof x === "number" && Number.isFinite(x)) return BigInt(Math.floor(x)) * NS_PER_MS;
    if (x instanceof Date) return BigInt(x.getTime()) * NS_PER_MS;
    if (typeof x === "string") {
      const ms = Date.parse(x);
      if (!Number.isNaN(ms)) return BigInt(ms) * NS_PER_MS;
    }
    throw new TypeError(
      "schedule({ at }): at must be a bigint (ns), number (ms-since-epoch), Date, or ISO-8601 string",
    );
  }

  // Delay from now → absolute ns. number = ms; string = duration
  // ("30s"/"5m"/"2h"/"1d"/"1w", via cron.parseDuration).
  function _coerceIn(x) {
    let ms;
    if (typeof x === "number" && Number.isFinite(x)) {
      ms = Math.floor(x);
    } else if (typeof x === "string") {
      ms = cron.parseDuration(x);
      if (ms == null) throw new TypeError("schedule({ in }): not a duration: " + x);
    } else {
      throw new TypeError("schedule({ in }): in must be a number (ms) or a duration string");
    }
    return BigInt(Date.now() + ms) * NS_PER_MS;
  }

  /**
   * Run `target` once, at a time. Connectionless + durable.
   *
   * @function schedule
   * @param {object} when - `{ at }` (absolute) or `{ in }` (delay).
   *   `at`: bigint ns | number ms-since-epoch | Date | ISO string.
   *   `in`: number ms | duration string (`"24h"`, `"30m"`, …).
   * @param {string} target - Module specifier to run, e.g. `"sendReminder"`.
   * @param {*} [ctx] - JSON-serializable value delivered as
   *   `request.activation.msg`.
   * @returns {string} The schedule id (cancel via `scheduler.cancel(id)`).
   * @throws {TypeError} On a bad `when` shape or empty `target`.
   * @example
   * schedule({ in: "24h" }, "sendReminder", { user });
   * schedule({ at: cron.dailyAt(3, 0) }, "jobs/cleanup");
   */
  globalThis.schedule = function schedule(when, target, ctx) {
    if (typeof target !== "string" || target.length === 0) {
      throw new TypeError("schedule(when, target, ctx?): target must be a non-empty module specifier");
    }
    let whenNs;
    if (when && when.at !== undefined) whenNs = _coerceAt(when.at);
    else if (when && when.in !== undefined) whenNs = _coerceIn(when.in);
    else throw new TypeError("schedule(when, target, ctx?): when must be { at } or { in }");
    return scheduler.at(whenNs, target, ctx);
  };
})();
