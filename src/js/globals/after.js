// Public `after` surface — connection wake triggers (docs/handler-shape.md
// §2.3; handler-api-ergonomics-plan §2.3). Thin shim over the native
// `_system.after` binding.
//
// `after.*` registers a ONE-SHOT wake **for the current connection**: a
// held handler (one that returns `next()` / streams) is re-invoked when
// the wake fires — a duration elapses, a kv key under a watched prefix
// changes, or an outbound fetch produces a result — while it still
// holds the socket. Wakes are re-armed per activation (call `after.*`
// again to keep listening — the SSE loop shape). Ephemeral (dropped
// with the connection) and node-local (never replicated). On a
// connectionless activation (a `cron`/`schedule`/`webhook.send`
// callback) there is no connection, so `after.*` is inert.
//
// The callback-target option is `{on: "module.method"}` — the universal
// spelling across every effect.
//
// Evaluated as a global script (no module/exports) after the native
// bindings install. (The pre-rename `on.*` alias existed for one deploy
// cycle and closed 2026-07-06.)

(function () {
  const sys = _system.after;

  // Lower the public `{on}` key onto the native binding's field.
  function tgt(opts) {
    if (opts && typeof opts === "object" && typeof opts.on === "string") {
      return { to: opts.on };
    }
    return undefined;
  }

  /**
   * Connection wake triggers — re-invoke a held handler when something
   * happens, while it still holds the socket. Register them in the body
   * before returning `next()` (or while streaming). The runtime arms
   * every `after.*` wake before firing any connectionless effect of the
   * same activation, so a wake is never missed even when a callback
   * writes the key it watches.
   *
   * @namespace after
   * @example
   * // SSE-style: stream rows, then wait for more under a prefix.
   * stream.start();
   * after.kv(`notif/${user}/`, { on: "onNotify" });
   * return next({ user });
   */
  globalThis.after = {
    /**
     * Wake the held connection after `ms` milliseconds. Named for its
     * unit — durations are milliseconds; there is deliberately no
     * `after.seconds` family (write `after.ms(5 * 60_000)`). Without
     * `on`, the wake lands in the `onWake` export.
     *
     * @param {number} ms - Delay in milliseconds (must be > 0).
     * @param {object} [opts]
     * @param {string} [opts.on] - Export to resume into
     *   (`"module.method"` or a bare `"method"`); defaults to `onWake`.
     * @returns {void}
     * @example
     * after.ms(30_000, { on: "onTimeout" }); // deadline for a join
     */
    ms(ms, opts) {
      return sys.timer(ms, tgt(opts));
    },

    /**
     * Wake the held connection after any key under `prefix` changes —
     * anchored to the version this activation read, so a write between
     * "you read" and "you parked" still fires it. Without `on`, the
     * wake lands in the `onWake` export.
     *
     * @param {string} prefix - Tenant-scoped key prefix to watch.
     * @param {object} [opts]
     * @param {string} [opts.on] - Export to resume into; defaults to
     *   `onWake`.
     * @returns {void}
     * @example
     * after.kv(`rooms/${roomId}/`);             // default onWake
     * after.kv(`jobs/${id}/`, { on: "onJob" }); // explicit target
     */
    kv(prefix, opts) {
      return sys.kv(prefix, tgt(opts));
    },

    /**
     * Perform an outbound HTTP request and wake the held connection on
     * its result. Connection-scoped: the result resumes THIS chain's
     * `{on}` export (defaults: `onFetchResult` for a non-streamed whole
     * body, `onFetchChunk`/`onFetchDone` for a streamed one) while it
     * still holds the socket; if the activation doesn't hold the socket
     * the fetch is inert (its durable twin is `webhook.send`). With
     * `opts.stream` each upstream writeback wakes the handler as it
     * arrives.
     *
     * @param {string} url - Upstream URL.
     * @param {object} [opts]
     * @param {string} [opts.method="GET"] - HTTP method.
     * @param {Object<string,string>} [opts.headers] - Request headers.
     * @param {string|Uint8Array} [opts.body] - Request body.
     * @param {boolean} [opts.stream=false] - false → one result event;
     *   true → one event per upstream chunk as it arrives.
     * @param {number} [opts.timeout_ms=30000] - Per-request timeout.
     * @param {object} [dst]
     * @param {string} [dst.on] - Export the result wakes; overrides the
     *   per-event-shape defaults for every event of this fetch.
     * @returns {string} The fetch id (`ftch_…`, opaque — compare to
     *   `request.fetchId`).
     * @example
     * after.fetch('https://api.example.com/stream', { stream: true },
     *             { on: 'onUpstream' });
     * return next();
     */
    fetch(url, opts, dst) {
      return sys.fetch(url, opts, tgt(dst));
    },
  };
})();
