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

    /**
     * Fire a transient HTTP request. Unlike {@link http.send},
     * `http.fetch` is non-durable + best-effort — it does NOT write
     * a raft row, does NOT retry on worker crash, and fires
     * immediately (no commit gate). One callback (`on_chunk`); one
     * knob (`stream`) for "first chunk only" (default) vs. "every
     * chunk as it arrives."
     *
     * Every fetch fires `on_chunk` AT LEAST once — even a 204 / a
     * transport error / a cap-only failure produces one event with
     * `final: true` and empty `bytes`. The customer always learns
     * how the request ended.
     *
     * Two modes:
     *
     *  **`stream: false` (default).** First writeback is captured
     *  (up to `max_response_chunk_bytes`); any further bytes set
     *  `body_truncated: true` and abort the rest of the transfer.
     *  Exactly one `on_chunk` event fires (with `final: true`). The
     *  right shape for webhooks, REST APIs, anything one-shot.
     *
     *  **`stream: true`.** Each upstream writeback fires its own
     *  `on_chunk` event AS IT ARRIVES, so an SSE drip / LLM-token
     *  stream drives the handler in real time. The LAST event
     *  carries `final: true` + terminal fields.
     *  `max_total_response_bytes` is the hard cap; exceeding sets
     *  `body_truncated: true` on the final event.
     *
     * @param {object} opts
     * @param {string} opts.url - Upstream URL.
     * @param {string} [opts.method="GET"] - HTTP method.
     * @param {Object<string,string>} [opts.headers] - Request headers.
     * @param {string} [opts.body] - Request body.
     * @param {number} [opts.timeout_ms=30000] - Per-request timeout.
     * @param {string} opts.on_chunk - Module path for the
     *   `on_chunk` callback (REQUIRED). The activation shape is
     *   `{ kind: "fetch_chunk", fetch_id, seq, byteOffset, bytes,
     *   headers? (seq=0), final, status? (final), ok? (final),
     *   body_truncated? (final), ctx }`.
     * @param {boolean} [opts.stream=false] - false → one event
     *   with `final: true` (default; first chunk only). true →
     *   one event per upstream writeback, last one carries
     *   `final: true`.
     * @param {number} [opts.max_response_chunk_bytes=262144] - Cap
     *   on the first/each chunk's body size. In single-chunk mode
     *   ALSO bounds the total body (overflow → `body_truncated`).
     * @param {number} [opts.max_total_response_bytes=52428800] - Hard
     *   cap for `stream: true`. Exceeding sets `body_truncated:
     *   true` on the final event.
     * @param {*} [opts.ctx] - Threaded forward to each activation as
     *   `request.ctx`.
     * @returns {string} The fetch id. Pass to {@link http.cancelFetch}.
     *
     * @example
     * // Single-shot webhook with response body capture.
     * http.fetch({
     *   url: "https://hooks.example.com/x",
     *   method: "POST",
     *   body: JSON.stringify({ event: "order.paid", id }),
     *   on_chunk: "onresult.mjs",   // sees { final:true, status, ok, bytes, headers }
     * });
     *
     * @example
     * // Streaming LLM tokens — handler forwards each chunk to its
     * // held client (the calling chain is a __rove_stream).
     * http.fetch({
     *   url: "https://api.openai.com/v1/chat/completions",
     *   method: "POST",
     *   body: JSON.stringify({ model, messages, stream: true }),
     *   on_chunk: "transform.mjs",
     *   stream: true,
     * });
     */
    fetch(opts) {
      return sys.fetch(opts);
    },

    /**
     * Cancel an in-flight `http.fetch`. No-op if the fetch already
     * completed or was never issued. The customer still gets one
     * `on_chunk` event with `final: true, ok: false` after a
     * successful cancel.
     *
     * @param {{id:string}} opts - The id `http.fetch` returned.
     * @returns {void}
     */
    cancelFetch(opts) {
      return sys.cancelFetch(opts);
    },
  };
})();
