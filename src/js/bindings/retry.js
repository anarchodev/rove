// Customer-side retry helper layered on top of `http.send`.
//
// All retry state lives in the customer tenant — this module's
// surface is pure JS, no platform privileges. The pattern:
//
//   import nothing — `retry` is a global, like `kv` or `http`.
//
//   // Fire with a retry policy.
//   retry.send({
//     url: "https://stripe.com/charge",
//     body: "...",
//     headers: { "content-type": "application/json" },
//     on_result_module: "charges/handler",  // module path in this tenant
//     max_attempts: 3,
//     // backoff_ms can be a number (constant), an array (per-attempt
//     // schedule), or omitted (default exponential 1s/4s/16s capped
//     // at 1 minute).
//     backoff_ms: [1000, 5000, 30000],
//     context: { charge_id: 42 },
//   });
//
//   // The on_result handler. Same shape as any other HTTP handler
//   // in the tenant — no args, event arrives in `request.body`.
//   // charges/handler.mjs
//   export default function () {
//     const event = JSON.parse(request.body);
//     if (retry.shouldRetry(event)) {
//       retry.next(event);
//       return;
//     }
//     const ctx = retry.stripContext(event);  // hide platform meta
//     if (event.ok) kv.set(`charge/${ctx.charge_id}`, event.body);
//     else kv.set(`failed/${ctx.charge_id}`, event.error);
//   }
//
// The retry chain only progresses when the on_result handler
// explicitly calls `retry.next`. There's no platform-level retry
// loop — every fire goes through the same `http.send` envelope path
// the customer would have taken anyway, and the on_result module
// stays in the customer's tenant. No system tenants, no cross-tenant
// privileges.

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

globalThis.retry = {
  // Fire a one-shot http.send wrapped with retry policy. Returns the
  // schedule id from http.send. The on_result module receives events
  // with `event.context._retry` populated; use `retry.shouldRetry` /
  // `retry.next` / `retry.stripContext` from inside the handler.
  send(opts) {
    if (!opts || typeof opts !== "object") {
      throw new TypeError("retry.send: requires an options object");
    }
    if (typeof opts.url !== "string") {
      throw new TypeError("retry.send: `url` must be a string");
    }
    if (typeof opts.on_result_module !== "string" || opts.on_result_module.length === 0) {
      throw new TypeError("retry.send: `on_result_module` must be a non-empty string");
    }
    const max_attempts = opts.max_attempts ?? 1;
    if (!Number.isInteger(max_attempts) || max_attempts < 1) {
      throw new TypeError("retry.send: `max_attempts` must be a positive integer");
    }

    const original = {
      url: opts.url,
      method: opts.method,
      headers: opts.headers,
      body: opts.body,
      timeout_ms: opts.timeout_ms,
      max_body_bytes: opts.max_body_bytes,
    };
    const on_result = { module: opts.on_result_module };
    if (opts.on_result_fn) on_result.fn = opts.on_result_fn;
    if (opts.on_result_args !== undefined) on_result.args = opts.on_result_args;
    const send_opts = {
      url: opts.url,
      method: opts.method,
      headers: opts.headers,
      body: opts.body,
      timeout_ms: opts.timeout_ms,
      max_body_bytes: opts.max_body_bytes,
      fire_at_ns: opts.fire_at_ns,
      on_result,
      context: Object.assign({}, opts.context || {}, {
        [RETRY_KEY]: {
          attempt: 1,
          max_attempts,
          backoff_ms: opts.backoff_ms,
          on_result_module: opts.on_result_module,
          on_result_fn: opts.on_result_fn,
          on_result_args: opts.on_result_args,
          original,
        },
      }),
    };
    return http.send(send_opts);
  },

  // True when the event was a failure AND there are attempts left.
  // Always false on success or when retry context is missing.
  shouldRetry(event) {
    if (!event || event.ok) return false;
    const r = event.context && event.context[RETRY_KEY];
    if (!r) return false;
    return (r.attempt || 1) < (r.max_attempts || 1);
  },

  // Schedule the next attempt. Caller should have checked
  // `shouldRetry` first; calling on a non-retryable event is a no-op
  // returning null. Returns the new schedule id otherwise.
  next(event) {
    if (!retry.shouldRetry(event)) return null;
    const r = event.context[RETRY_KEY];
    const next_attempt = (r.attempt || 1) + 1;
    const delay = backoffMsFor(r, next_attempt);
    let fire_at_ns;
    if (delay > 0) {
      fire_at_ns = BigInt(Date.now()) * 1_000_000n + BigInt(delay) * 1_000_000n;
    }
    // User-domain context is everything except _retry.
    const user_context = Object.assign({}, event.context);
    delete user_context[RETRY_KEY];
    const on_result = { module: r.on_result_module };
    if (r.on_result_fn) on_result.fn = r.on_result_fn;
    if (r.on_result_args !== undefined) on_result.args = r.on_result_args;
    return http.send({
      url: r.original.url,
      method: r.original.method,
      headers: r.original.headers,
      body: r.original.body,
      timeout_ms: r.original.timeout_ms,
      max_body_bytes: r.original.max_body_bytes,
      fire_at_ns,
      on_result,
      context: Object.assign({}, user_context, {
        [RETRY_KEY]: Object.assign({}, r, { attempt: next_attempt }),
      }),
    });
  },

  // Return event.context with the platform's _retry meta removed.
  // Doesn't mutate; returns a fresh object. Idempotent on events
  // that weren't routed through `retry.send`.
  stripContext(event) {
    if (!event || !event.context || !event.context[RETRY_KEY]) {
      return event ? event.context : null;
    }
    const out = Object.assign({}, event.context);
    delete out[RETRY_KEY];
    return out;
  },

  // Current attempt number (1-based). 1 on the first fire, 2 on the
  // first retry, etc. Returns null when retry context is missing.
  attempt(event) {
    const r = event && event.context && event.context[RETRY_KEY];
    return r ? (r.attempt || 1) : null;
  },
};
