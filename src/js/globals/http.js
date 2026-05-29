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
   * Transient outbound HTTP. For durable, at-least-once delivery use
   * {@link webhook.send} (or {@link email.send} for transactional
   * email through Resend).
   *
   * @namespace http
   */
  globalThis.http = {
    /**
     * Fire a transient HTTP request. `http.fetch` is non-durable +
     * best-effort — it does NOT write a raft row, does NOT retry on
     * worker crash, and fires immediately (no commit gate). One
     * callback (`on_chunk`); one knob (`stream`) for "first chunk
     * only" (default) vs. "every chunk as it arrives."
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
     * @param {string} opts.on_chunk - Module path for the detached
     *   `on_chunk` callback (REQUIRED). The activation shape is
     *   `{ kind: "fetch_chunk", fetch_id, seq, byteOffset, bytes,
     *   headers? (seq=0), final, status? (final), ok? (final),
     *   body_truncated? (final), ctx }`. NOTE: this fires only for a
     *   DETACHED fetch (see `detach`). When the calling handler holds
     *   the chain (returns `next()`/`stream()`), the fetch auto-binds
     *   and chunks resume the chain's `onFetchChunk` export instead —
     *   `on_chunk` is ignored.
     * @param {boolean} [opts.detach=false] - Opt OUT of auto-bind.
     *   By default a fetch from a held handler binds to that chain
     *   (chunks → its `onFetchChunk`). `detach: true` fires a separate
     *   `on_chunk` chain (fire-and-forget) — use it when you don't want
     *   the fetch to drive the held response. A fetch from a terminal
     *   handler is always detached (no chain to bind to).
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
     * // Streaming LLM tokens. The handler returns next()/stream(), so
     * // the fetch AUTO-BINDS: each upstream chunk resumes this module's
     * // `onFetchChunk` export (no `bind` keyword needed). `on_chunk` is
     * // still required by the binding but ignored on the bound path.
     * http.fetch({
     *   url: "https://api.openai.com/v1/chat/completions",
     *   method: "POST",
     *   body: JSON.stringify({ model, messages, stream: true }),
     *   on_chunk: "onFetchChunk",
     *   stream: true,
     * });
     * // export function onFetchChunk() { return stream({ write: transform(request.body) }); }
     */
    fetch(opts) {
      return sys.fetch(opts);
    },

    /**
     * Cancel an in-flight `http.fetch`. No-op if the fetch already
     * completed or was never issued. Cooperative: a chunk already
     * in flight at the engine may still land in `on_chunk` after
     * the cancel returns; track "we moved on" in your chain ctx
     * (the customer is the single source of truth for chain
     * progress).
     *
     * @param {{id:string}} opts - The id `http.fetch` returned.
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
