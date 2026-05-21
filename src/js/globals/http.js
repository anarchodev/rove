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
     * Fire a transient streaming HTTP request. Unlike {@link http.send},
     * `http.fetch` is non-durable + best-effort — it does NOT write
     * a raft row, does NOT retry on worker crash, and fires
     * immediately (no commit gate). Right for proxying real-time
     * upstream streams (LLM token streams, large file downloads)
     * where double-fire is bad (cost / bandwidth) and durable
     * retry is overkill.
     *
     * Two patterns:
     *
     *  **Pattern A — per-chunk handler.** Set `on_chunk` to a module
     *  path; each upstream chunk fires a `fetch_chunk` activation
     *  there. `fetch_done` terminal fires on completion (against
     *  `on_done` if set, else against `on_chunk`).
     *
     *  **Pattern B — transparent proxy.** Set `pipe_to: "held_response"`;
     *  the runtime pipes upstream bytes directly into the calling
     *  chain's held client (`__rove_stream`). `fetch_pipe_done`
     *  terminal fires when upstream closes. No per-chunk handler.
     *
     * `on_chunk` and `pipe_to` are mutually exclusive.
     *
     * @param {object} opts
     * @param {string} opts.url - Upstream URL.
     * @param {string} [opts.method="GET"] - HTTP method.
     * @param {Object<string,string>} [opts.headers] - Request headers.
     * @param {string} [opts.body] - Request body.
     * @param {number} [opts.timeout_ms=30000] - Per-request timeout.
     * @param {string} [opts.on_chunk] - Module path for `fetch_chunk`
     *   activations (Pattern A).
     * @param {string} [opts.on_done] - Module path for the terminal
     *   `fetch_done` / `fetch_pipe_done` activation.
     * @param {"held_response"} [opts.pipe_to] - Pattern B; pipe
     *   upstream bytes directly to the held client.
     * @param {boolean} [opts.headers_passthrough=false] - Pattern B;
     *   mirror upstream response headers onto the held client's
     *   response headers.
     * @param {number} [opts.max_response_chunk_bytes=65536] - Per-chunk
     *   cap; libcurl writebacks larger than this are split into
     *   multiple `fetch_chunk` activations.
     * @param {number} [opts.max_total_response_bytes=52428800] - Hard
     *   cap; exceeding cancels the fetch + fires the terminal with
     *   `ok: false`.
     * @param {*} [opts.ctx] - Threaded forward to each activation as
     *   `request.ctx`.
     * @returns {string} The fetch id. Pass to {@link http.cancelFetch}.
     *
     * @example
     * // Pattern A — transform LLM tokens, forward to held client.
     * http.fetch({
     *   url: "https://api.openai.com/v1/chat/completions",
     *   method: "POST",
     *   body: JSON.stringify({ model, messages, stream: true }),
     *   on_chunk: "transform.mjs",
     *   on_done:  "finalize.mjs",
     * });
     * @example
     * // Pattern B — transparent file proxy.
     * http.fetch({
     *   url: "https://cdn.example.com/big.mp4",
     *   pipe_to: "held_response",
     *   headers_passthrough: true,
     * });
     */
    fetch(opts) {
      return sys.fetch(opts);
    },

    /**
     * Cancel an in-flight `http.fetch`. No-op if the fetch already
     * completed or was never issued. Pattern B (pipe_to) fetches
     * still fire `fetch_pipe_done` with `ok: false` after cancel.
     *
     * @param {{id:string}} opts - The id `http.fetch` returned.
     * @returns {void}
     */
    cancelFetch(opts) {
      return sys.cancelFetch(opts);
    },
  };
})();
