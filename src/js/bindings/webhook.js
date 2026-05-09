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
//     want retries arrange them in the `on_result` handler by calling
//     `http.send` again with the failed row's context.
//   - Outbound headers carry `X-Rove-Schedule-Id` (stamped by
//     http.send) instead of `X-Rove-Webhook-Id`. Same idempotency
//     semantics; new name.
//   - `onResult` becomes `on_result.module`. Same module-name
//     resolution rules.
globalThis.webhook = {
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
