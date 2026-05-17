// Public `http` surface — the documentation source of truth for the
// outbound HTTP primitive (docs/builtin-libs-docs-plan.md Phase A,
// docs/http-send-plan.md for full semantics).
//
// Thin shim over the native `_system.http` binding. Top-level
// `http.send` / `http.cancel` are unchanged; `_system.*` is the
// internal ABI and customer code must never reference it directly.
// The bundled retry/webhook/email libraries compose on this shim.
//
// Evaluated as a global script (no module/exports) into every
// dispatcher context after the native bindings install.

(function () {
  const sys = _system.http;

  /**
   * Outbound HTTP as a durable, replay-deterministic Cmd. `http.send`
   * does not perform the request inline — it records intent that
   * commits through Raft atomically with the handler's kv writeset,
   * then a leader-pinned scheduler fires the actual request and
   * (optionally) invokes a result handler in this tenant.
   *
   * @namespace http
   */
  globalThis.http = {
    /**
     * Enqueue an outbound HTTP request. Returns immediately with a
     * stable id; the request fires after the handler commits.
     *
     * @param {object} opts
     * @param {string} opts.url - Target URL.
     * @param {string} [opts.method="POST"] - HTTP method.
     * @param {Object<string,string>} [opts.headers] - Request headers.
     * @param {string} [opts.body] - Request body.
     * @param {string} [opts.handle] - Caller-chosen id (idempotency /
     *   cancel handle). Omitted → a deterministic id derived from
     *   `(request_id, call_index)`.
     * @param {number|bigint} [opts.fire_at_ns] - Fire time in epoch
     *   nanoseconds. Omitted → fire as soon as possible.
     * @param {number} [opts.timeout_ms] - Per-request timeout.
     * @param {number} [opts.max_body_bytes] - Cap on captured response
     *   body size.
     * @param {{module:string, fn?:string, args?:Array, context?:*}}
     *   [opts.on_result] - Result handler in this tenant. `module` is
     *   the handler module path; `fn` its export (default export if
     *   omitted); `args` JSON-serializable positional args; `context`
     *   is echoed back on the result event. Omit for fire-and-forget.
     * @returns {string} The schedule row id (the `handle` if supplied,
     *   else the derived id). Pass it to {@link http.cancel}.
     *
     * @example
     * const id = http.send({
     *   url: "https://api.stripe.com/v1/charges",
     *   headers: { authorization: `Bearer ${key}` },
     *   body: form,
     *   on_result: { module: "charges/handler", context: { orderId } },
     * });
     */
    send(opts) {
      return sys.send(opts);
    },

    /**
     * Cancel a pending (not-yet-fired) `http.send` row.
     *
     * @param {{handle?:string, id?:string}} opts - Identify the row by
     *   the `handle` passed to `send`, or by the id `send` returned.
     * @returns {void}
     *
     * @example
     * const id = http.send({ url, body, fire_at_ns: inOneHour });
     * // …later, before it fires:
     * http.cancel({ id });
     */
    cancel(opts) {
      return sys.cancel(opts);
    },
  };
})();
