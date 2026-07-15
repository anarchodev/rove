// Public `http` surface — the documentation source of truth for the
// outbound HTTP primitive (docs/architecture/builtin-libs.md Phase A,
// docs/effect-reification-plan.md Phase 5).
//
// Thin shim over the native `_system.http` binding. Durability is
// JS-shim'd in `webhook.send` (and `email.send`) on top of the
// internal fetch primitive + `kv` markers + durable scheduled wakes.
// `_system.*` is the internal ABI and customer code must never
// reference it directly.
//
// Evaluated as a global script (no module/exports) into every
// dispatcher context after the native bindings install.

(function () {
  const sys = _system.http;

  /**
   * Long-lived held outbound subscriptions. The one-shot outbound
   * primitives are {@link after.fetch} (connection-scoped; cancel via
   * {@link after.cancel}) and {@link webhook.send} (durable,
   * connectionless); `http.subscribe` holds an upstream that pushes to
   * YOU.
   *
   * @namespace http
   */
  globalThis.http = {
    /**
     * Open a held outbound subscription — `after.fetch`'s held
     * symmetric twin for long-lived upstreams (atproto firehose, Pub/Sub
     * long-poll, SSE consumers, any third-party push where the
     * provider holds the connection). Closes
     * `docs/primitive-gaps.md` §2.5.
     *
     * Same options as `after.fetch` minus `timeoutMs` (held
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
     * @param {string} opts.on - Module path each upstream writeback
     *   wakes (REQUIRED — the universal callback key). Same
     *   activation shape as a streamed `after.fetch`.
     * @param {number} [opts.maxChunkBytes=262144] - Per-chunk cap.
     * @param {number} [opts.maxTotalBytes=52428800] - Cumulative
     *   response cap; exceeding sets `bodyTruncated` on the terminal
     *   event.
     * @param {*} [opts.ctx] - Threaded forward to each activation
     *   as `request.ctx`.
     * @returns {string} The subscription id — the same `ftch_…` form
     *   as `after.fetch`'s return and each chunk's
     *   `request.activation.fetchId`, so you can correlate them
     *   directly. Pass to {@link http.cancelSubscription}.
     *
     * @example
     * const id = http.subscribe({
     *   url: "https://bsky.network/xrpc/com.atproto.sync.subscribeRepos",
     *   on: "ingest_firehose",
     *   ctx: { cursor: kv.get("firehose/cursor") },
     * });
     * kv.set("firehose/subscription_id", id);
     */
    subscribe(opts) {
      opts = opts || {};
      for (const pair of [["on_chunk", "on"], ["max_response_chunk_bytes", "maxChunkBytes"], ["max_total_response_bytes", "maxTotalBytes"]]) {
        if (pair[0] in opts) throw new TypeError("http.subscribe: option `" + pair[0] + "` was renamed — use `" + pair[1] + "`");
      }
      const native = Object.assign({}, opts);
      delete native.on;
      delete native.maxChunkBytes;
      delete native.maxTotalBytes;
      if (typeof opts.on === "string") native.on_chunk = opts.on;
      if (opts.maxChunkBytes != null) native.max_response_chunk_bytes = opts.maxChunkBytes;
      if (opts.maxTotalBytes != null) native.max_total_response_bytes = opts.maxTotalBytes;
      return sys.subscribe(native);
    },

    /**
     * Cancel a held subscription. No-op if the subscription
     * already ended or was never issued. Cooperative: a chunk
     * already in flight may still land in `on_chunk` after the
     * cancel returns.
     *
     * @param {string} id - The id `http.subscribe` returned.
     * @returns {void}
     */
    cancelSubscription(id) {
      return sys.cancelSubscription({ id: id });
    },
  };
})();
