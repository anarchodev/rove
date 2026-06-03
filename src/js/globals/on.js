// Public `on` surface — connection wake triggers (docs/handler-shape.md
// §2.3). Thin shim over the native `_system.on` binding.
//
// `on.*` registers a wake **for the current connection**: a held
// handler (one that returns `next()` / streams) is re-invoked when the
// wake fires — a kv key under a watched prefix changes, or a timer
// elapses — while it still holds the socket. Ephemeral (dropped with
// the connection) and node-local (never replicated). On a
// connectionless activation (a `cron`/`schedule`/`webhook.send`
// callback) there is no connection, so `on.*` is inert.
//
// Evaluated as a global script (no module/exports) after the native
// bindings install.

(function () {
  const sys = _system.on;

  /**
   * Connection wake triggers — re-invoke a held handler when something
   * changes, while it still holds the socket. Register them in the body
   * before returning `next()` (or while streaming). The runtime arms
   * every `on.*` wake before firing any connectionless effect of the
   * same activation, so a wake is never missed even when a callback
   * writes the key it watches.
   *
   * @namespace on
   * @example
   * // SSE-style: stream rows, then wait for more under a prefix.
   * stream.start();
   * on.kv(`notif/${user}/`, { to: "onNotify" });
   * return next({ user });
   */
  globalThis.on = {
    /**
     * Wake the held connection after `ms` milliseconds. Without `to`,
     * the wake lands in the `onWake` export.
     *
     * @param {number} ms - Delay in milliseconds (must be > 0).
     * @param {object} [opts]
     * @param {string} [opts.to] - Export to resume into
     *   (`"module.method"` or a bare `"method"`); defaults to `onWake`.
     * @returns {void}
     * @example
     * on.timer(30_000, { to: "onTimeout" }); // deadline for a join
     */
    timer(ms, opts) {
      return sys.timer(ms, opts);
    },

    /**
     * Wake the held connection when any key under `prefix` changes
     * since the version this activation read (anchored to the read
     * view, so a write between "you read" and "you parked" still
     * fires it). Without `to`, the wake lands in the `onWake` export.
     *
     * @param {string} prefix - Tenant-scoped key prefix to watch.
     * @param {object} [opts]
     * @param {string} [opts.to] - Export to resume into; defaults to
     *   `onWake`.
     * @returns {void}
     * @example
     * on.kv(`rooms/${roomId}/`);            // default onWake
     * on.kv(`jobs/${id}/`, { to: "onJob" }); // explicit target
     */
    kv(prefix, opts) {
      return sys.kv(prefix, opts);
    },

    /**
     * Perform an outbound HTTP request and wake the held connection on
     * its result. Connection-scoped: the result resumes THIS chain's
     * `{to}` export (default `onFetchChunk`) while it still holds the
     * socket; if the activation doesn't hold the socket the fetch is
     * inert (its durable twin is `webhook.send`). With `opts.stream`
     * each upstream writeback wakes the handler as it arrives.
     *
     * @param {string} url - Upstream URL.
     * @param {object} [opts]
     * @param {string} [opts.method="GET"] - HTTP method.
     * @param {Object<string,string>} [opts.headers] - Request headers.
     * @param {string} [opts.body] - Request body.
     * @param {boolean} [opts.stream=false] - false → one result event;
     *   true → one event per upstream chunk as it arrives.
     * @param {number} [opts.timeout_ms=30000] - Per-request timeout.
     * @param {object} [to]
     * @param {string} [to.to] - Export the result wakes; defaults to
     *   `onFetchChunk`.
     * @returns {string} The fetch id (for `http.cancelFetch`).
     * @example
     * on.fetch('https://api.example.com/stream', { stream: true },
     *          { to: 'onUpstream' });
     * return next();
     */
    fetch(url, opts, to) {
      return sys.fetch(url, opts, to);
    },
  };
})();
