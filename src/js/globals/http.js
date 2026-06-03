// Public `http` surface — the documentation source of truth for the
// outbound HTTP primitive (docs/builtin-libs-docs-plan.md Phase A,
// docs/effect-reification-plan.md Phase 5).
//
// Thin shim over the native `_system.http` binding. The legacy
// `http.send` / `http.cancel` durable surface retired in Phase 5
// PR-3: durability is now JS-shim'd in `webhook.send` (and
// `email.send`) on top of `http.fetch` + `kv.set` + the per-worker
// partitioned retry sweep. `_system.*` is the internal ABI and
// customer code must never reference it directly.
//
// Evaluated as a global script (no module/exports) into every
// dispatcher context after the native bindings install.

(function () {
  const sys = _system.http;

  /**
   * Held outbound subscriptions + fetch cancellation. The one-shot
   * outbound primitives are {@link on.fetch} (connection-scoped — binds
   * to the held chain) and {@link webhook.send} (durable, connectionless);
   * the transient `http.fetch` spelling is retired. `http.subscribe`
   * remains for long-lived held outbound streams.
   *
   * @namespace http
   */
  globalThis.http = {
    /**
     * Cancel an in-flight fetch (an `on.fetch` id). No-op if it already
     * completed or was never issued. Cooperative: a chunk already
     * in flight at the engine may still land in `on_chunk` after
     * the cancel returns; track "we moved on" in your chain ctx
     * (the customer is the single source of truth for chain
     * progress).
     *
     * @param {{id:string}} opts - The id `on.fetch` returned.
     * @returns {void}
     */
    cancelFetch(opts) {
      return sys.cancelFetch(opts);
    },

    /**
     * Open a held outbound subscription — `http.fetch`'s symmetric
     * twin for long-lived upstreams (atproto firehose, Pub/Sub
     * long-poll, SSE consumers, any third-party push where the
     * provider holds the connection). Closes
     * `docs/primitive-gaps.md` §2.5.
     *
     * Same shape as `http.fetch` minus `timeout_ms` (held
     * subscriptions don't time out — they end on cancel or
     * upstream close) and `stream` (always true — held transfers
     * stream by definition). The `on_chunk` handler fires per
     * upstream writeback as a `fetch_chunk` activation; the
     * terminal event has `final: true, ok: false` to signal
     * "subscription ended" (whether by clean upstream close or
     * transport error). Your handler interprets that as
     * "reconnect if desired."
     *
     * Subject to a per-tenant cap on simultaneous held
     * subscriptions. Exceeding the cap fires one
     * `on_chunk(final: true, ok: false)` event so your handler
     * still runs once and can surface the condition.
     *
     * @param {object} opts
     * @param {string} opts.url - Upstream URL.
     * @param {string} [opts.method="GET"] - HTTP method.
     * @param {Object<string,string>} [opts.headers] - Request headers.
     * @param {string} [opts.body] - Request body.
     * @param {string} opts.on_chunk - Module path for `on_chunk`
     *   (REQUIRED). Same activation shape as `http.fetch`.
     * @param {number} [opts.max_response_chunk_bytes=262144] -
     *   Per-chunk cap.
     * @param {number} [opts.max_total_response_bytes=52428800] -
     *   Cumulative response cap; exceeding sets `body_truncated`
     *   on the terminal event.
     * @param {*} [opts.ctx] - Threaded forward to each activation
     *   as `request.ctx`.
     * @returns {string} The subscription id. Pass to
     *   {@link http.cancelSubscription}.
     *
     * @example
     * const id = http.subscribe({
     *   url: "https://bsky.network/xrpc/com.atproto.sync.subscribeRepos",
     *   on_chunk: "ingest_firehose.mjs",
     *   ctx: { cursor: kv.get("firehose/cursor") },
     * });
     * kv.set("firehose/subscription_id", id);
     */
    subscribe(opts) {
      return sys.subscribe(opts);
    },

    /**
     * Cancel a held subscription. No-op if the subscription
     * already ended or was never issued. Cooperative: a chunk
     * already in flight may still land in `on_chunk` after the
     * cancel returns.
     *
     * @param {{id:string}} opts - The id `http.subscribe` returned.
     * @returns {void}
     */
    cancelSubscription(opts) {
      return sys.cancelSubscription(opts);
    },
  };
})();
