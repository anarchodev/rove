// `webhook.send` JS polyfill, layered on top of `http.send`.
//
// Pre-launch the platform exposed `webhook.send` as a native C
// binding with its own envelope shape (envelope-4/5/6) and a
// dedicated webhook-server thread. Both are retired in favor of
// the generic `http.send` primitive (docs/http-send-plan.md). This
// polyfill keeps `webhook.send` available as a thin convenience
// wrapper so customer recipes that already use it keep working
// while we migrate.
//
// Differences from the legacy webhook.send:
//   - No built-in retries (`maxAttempts` is ignored). Customers who
//     want retries use `retry.send` directly + `retry.shouldRetry`/
//     `retry.next` in their on_result handler — same JS surface,
//     no system tenant, all retry state visible in the customer's
//     own kv. See `globals/retry.js`.
//   - Outbound headers carry `X-Rove-Schedule-Id` (stamped by
//     http.send) instead of `X-Rove-Webhook-Id`. Same idempotency
//     semantics; new name.
//   - `onResult` becomes `on_result.module`. Same module-name
//     resolution rules.
/**
 * Convenience wrapper for one-shot outbound webhooks, layered on
 * {@link http.send}. No built-in retries — use {@link retry} for
 * that. Outbound requests carry `X-Rove-Schedule-Id` for idempotency.
 *
 * @namespace webhook
 */
globalThis.webhook = {
  /**
   * Send a webhook. Durable: fires after the handler commits, with
   * an optional result callback module in this tenant.
   *
   * @param {object} opts
   * @param {string} opts.url - Target URL.
   * @param {string} [opts.method="POST"] - HTTP method.
   * @param {string} [opts.body=""] - Request body.
   * @param {Object<string,string>} [opts.headers] - Extra headers.
   * @param {string} [opts.onResult] - Module path of a result
   *   handler in this tenant (becomes `on_result.module`).
   * @param {*} [opts.context] - Echoed back on the result event.
   * @param {number} [opts.timeout_ms] - Per-request timeout.
   * @returns {string} The {@link http.send} schedule id.
   * @throws {TypeError} If `opts` or `opts.url` is missing/wrong type.
   *
   * @example
   * webhook.send({
   *   url: "https://hooks.example.com/x",
   *   body: JSON.stringify({ event: "order.paid", id }),
   *   onResult: "hooks/onDelivered",
   * });
   */
  send(opts) {
    if (!opts || typeof opts !== "object")
      throw new TypeError("webhook.send requires an options object");
    if (typeof opts.url !== "string")
      throw new TypeError("webhook.send: `url` must be a string");

    const env = {
      url: opts.url,
      method: opts.method || "POST",
      body: opts.body || "",
      headers: Object.assign({}, opts.headers || {}),
    };
    if (opts.onResult) env.on_result = { module: opts.onResult };
    if (opts.context !== undefined) env.context = opts.context;
    if (opts.timeout_ms != null) env.timeout_ms = opts.timeout_ms;
    return http.send(env);
  },
};
