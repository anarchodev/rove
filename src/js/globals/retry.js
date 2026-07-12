// Customer-side retry helper layered on top of `webhook.send`.
//
// All retry state lives in the customer tenant — this module's
// surface is pure JS, no platform privileges. The pattern:
//
//   import nothing — `retry` is a global, like `kv` or `webhook`.
//
//   // Fire with a retry policy.
//   retry.send({
//     url: "https://stripe.com/charge",
//     body: "...",
//     headers: { "content-type": "application/json" },
//     on: "charges/handler",           // module path in this tenant
//     maxAttempts: 3,
//     // backoffMs can be a number (constant), an array (per-attempt
//     // schedule), or omitted (default exponential 1s/4s/16s capped
//     // at 1 minute).
//     backoffMs: [1000, 5000, 30000],
//     ctx: { charge_id: 42 },
//   });
//
//   // The {on} handler — every helper reads the ambient flattened
//   // result surface (handler-shape §7) itself; no event assembly.
//   //
//   //   charges/handler.mjs
//   //   export default function () {
//   //     if (retry.shouldRetry()) { retry.again(); return; }
//   //     const ctx = retry.ctx();
//   //     const ok = request.status >= 200 && request.status < 300;
//   //     if (ok) kv.set(`charge/${ctx.charge_id}`, request.text);
//   //     else kv.set(`failed/${ctx.charge_id}`, request.activation.error);
//   //   }
//
// Why `retry.send` exists alongside `webhook.send`'s built-in retry:
// webhook.send retries are platform-driven (fixed exponential
// backoff, 5 attempts, no customer visibility) — the right shape
// for ordinary deliveries. `retry.send` is for the case where the
// CUSTOMER wants to drive the policy: custom backoff, custom max,
// per-attempt context inspection. It sets `max_attempts: 1` on the
// underlying `webhook.send` to suppress the built-in retry, then
// composes its own chain via `retry.again` from the {on} module.

const RETRY_KEY = "_retry";

function backoffMsFor(retry_state, next_attempt) {
  const b = retry_state.backoff_ms;
  // Per-attempt schedule. next_attempt is 1-based; the first retry
  // is index 0 (we only consult on retries, so subtract 2 for 1-based
  // attempt # → 0-based index).
  if (Array.isArray(b)) {
    const idx = Math.min(next_attempt - 2, b.length - 1);
    return b[Math.max(0, idx)];
  }
  if (typeof b === "number") return b;
  // Default: exponential 1s, 4s, 16s, ... capped at 1 minute.
  return Math.min(60_000, 1_000 * Math.pow(4, next_attempt - 2));
}

/**
 * Customer-side retry policy layered on {@link webhook.send}. All retry
 * state lives in this tenant's own ctx — no platform retry loop, no
 * cross-tenant privileges. The chain only advances when the {on}
 * handler explicitly calls {@link retry.again}. Every helper reads the
 * ambient flattened result surface itself — no event assembly, no
 * arguments (`retry.next` was renamed `retry.again` to stop colliding
 * with the `next()` disposition).
 *
 * @namespace retry
 * @example
 * // Fire with a policy.
 * retry.send({
 *   url: "https://stripe.com/charge",
 *   on: "charges/handler",
 *   maxAttempts: 3,
 *   backoffMs: [1000, 5000, 30000], // or a number, or omit
 *   ctx: { charge_id: 42 },
 * });
 *
 * // charges/handler.mjs — the {on} handler.
 * export default function () {
 *   if (retry.shouldRetry()) { retry.again(); return; }
 *   const ctx = retry.ctx();
 *   // ... your terminal handling on request.status/.text ...
 * }
 */
globalThis.retry = {
  /**
   * Fire a one-shot `webhook.send` wrapped with a retry policy. The
   * {on} module drives the chain with the no-arg helpers below (the
   * policy rides `request.ctx._retry`).
   *
   * @param {object} opts
   * @param {string} opts.url - Target URL.
   * @param {string} opts.on - Result handler module path in this
   *   tenant (non-empty).
   * @param {number} [opts.maxAttempts=1] - Total attempts incl. the
   *   first (positive integer).
   * @param {number|number[]} [opts.backoffMs] - Constant delay, a
   *   per-attempt schedule, or omit for exponential 1s/4s/16s…
   *   capped at 60s.
   * @param {string} [opts.method] - HTTP method.
   * @param {Object<string,string>} [opts.headers] - Request headers.
   * @param {string} [opts.body] - Request body.
   * @param {number} [opts.timeoutMs] - Per-request timeout.
   * @param {bigint|number|Date|string} [opts.at] - Fire time for the
   *   first attempt (webhook.send's `{at}`); or use `{in}`.
   * @param {number|string} [opts.in] - Delay the first attempt.
   * @param {*} [opts.ctx] - Echoed back (under your own keys;
   *   `_retry` is reserved).
   * @returns {string} The {@link webhook.send} schedule id.
   * @throws {TypeError} On missing/invalid `url`/`on`/`maxAttempts`.
   */
  send(opts) {
    if (!opts || typeof opts !== "object") {
      throw new TypeError("retry.send: requires an options object");
    }
    if (typeof opts.url !== "string") {
      throw new TypeError("retry.send: `url` must be a string");
    }
    for (const pair of [["max_attempts", "maxAttempts"], ["backoff_ms", "backoffMs"], ["timeout_ms", "timeoutMs"], ["fire_at_ns", "at (or in)"], ["on_result_module", "on"], ["context", "ctx"]]) {
      if (pair[0] in opts) throw new TypeError("retry.send: option `" + pair[0] + "` was renamed — use `" + pair[1] + "`");
    }
    const on_key = opts.on;
    if (typeof on_key !== "string" || on_key.length === 0) {
      throw new TypeError("retry.send: `on` must be a non-empty string");
    }
    const max_attempts = opts.maxAttempts ?? 1;
    if (!Number.isInteger(max_attempts) || max_attempts < 1) {
      throw new TypeError("retry.send: `maxAttempts` must be a positive integer");
    }

    // Internal chain state (`_retry` on the ctx) keeps its wire shape.
    const original = {
      url: opts.url,
      method: opts.method,
      headers: opts.headers,
      body: opts.body,
      timeout_ms: opts.timeoutMs,
    };
    const send_opts = {
      url: opts.url,
      method: opts.method,
      headers: opts.headers,
      body: opts.body,
      timeoutMs: opts.timeoutMs,
      at: opts.at,
      in: opts.in,
      on: on_key,
      // Suppress webhook.send's built-in retry — the customer drives
      // the chain explicitly through `retry.again`.
      maxAttempts: 1,
      ctx: Object.assign({}, opts.ctx || {}, {
        [RETRY_KEY]: {
          attempt: 1,
          max_attempts,
          backoff_ms: opts.backoffMs,
          on_result_module: on_key,
          original,
        },
      }),
    };
    return webhook.send(send_opts.url, send_opts);
  },

  /**
   * Whether this result should be retried: a failure with attempts
   * remaining. Reads the ambient flattened result (`request.status`,
   * `request.ctx._retry`) — no arguments. Always `false` on success or
   * outside a retry.send result activation.
   *
   * @returns {boolean}
   */
  shouldRetry() {
    const req = globalThis.request;
    // Retry a non-2xx result (includes `status === 0` transport
    // failure). Success (2xx) never retries. `status` is the single
    // result signal — there is no `request.ok` (issue #7).
    if (!req || (req.status >= 200 && req.status < 300)) return false;
    const r = req.ctx && req.ctx[RETRY_KEY];
    if (!r) return false;
    return (r.attempt || 1) < (r.max_attempts || 1);
  },

  /**
   * Schedule the next attempt (applies the backoff). Reads the ambient
   * result — no arguments. No-op returning `null` if this result isn't
   * retryable — check {@link retry.shouldRetry} first. (Named `again`,
   * not `next`: `next()` is the hold-the-connection disposition.)
   *
   * @returns {string|null} New marker id, or `null`.
   */
  again() {
    if (!retry.shouldRetry()) return null;
    const req = globalThis.request;
    const r = req.ctx[RETRY_KEY];
    const next_attempt = (r.attempt || 1) + 1;
    const delay = backoffMsFor(r, next_attempt);
    // User-domain ctx is everything except _retry.
    const user_ctx = Object.assign({}, req.ctx);
    delete user_ctx[RETRY_KEY];
    return webhook.send(r.original.url, {
      method: r.original.method,
      headers: r.original.headers,
      body: r.original.body,
      timeoutMs: r.original.timeout_ms,
      in: delay > 0 ? delay : undefined,
      on: r.on_result_module,
      maxAttempts: 1,
      ctx: Object.assign({}, user_ctx, {
        [RETRY_KEY]: Object.assign({}, r, { attempt: next_attempt }),
      }),
    });
  },

  /**
   * Your original ctx with the reserved `_retry` meta removed. Reads
   * the ambient result — no arguments. Fresh object (no mutation);
   * works on results that never went through {@link retry.send}.
   *
   * @returns {object|null}
   */
  ctx() {
    const req = globalThis.request;
    if (!req || !req.ctx || !req.ctx[RETRY_KEY]) {
      return req ? (req.ctx === undefined ? null : req.ctx) : null;
    }
    const out = Object.assign({}, req.ctx);
    delete out[RETRY_KEY];
    return out;
  },

  /**
   * Current 1-based attempt number (1 on the first fire, 2 on the
   * first retry, …). Reads the ambient result — no arguments. `null`
   * when retry context is missing.
   *
   * @returns {number|null}
   */
  attempt() {
    const req = globalThis.request;
    const r = req && req.ctx && req.ctx[RETRY_KEY];
    return r ? (r.attempt || 1) : null;
  },
};
