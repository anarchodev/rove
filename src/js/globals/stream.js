// Public `stream` surface — connection output effects
// (docs/handler-shape.md §2.2). Thin shim over the native
// `_system.stream` binding.
//
// `stream` is an effect **namespace** (ambient, like `kv`), not a
// return verb: a held handler produces its streamed response over time
// by calling `stream.start()` / `stream.write(chunk)`, and controls the
// connection by returning `next()` (keep producing) or a terminal value
// (close). The head — status / headers / cookies — is the ambient
// `response.*` global. `stream.*` is connection-only: on a
// connectionless activation (a `cron`/`schedule`/`webhook.send`
// callback) there is no held socket, so these calls are inert.
//
// Evaluated as a global script (no module/exports) after the native
// bindings install. IIFE-wrapped: a bare top-level definition corrupts
// the arenajs base-snapshot freeze.

(function () {
  const sys = _system.stream;

  /**
   * Connection output — produce a streamed response over time. Pair
   * with `on.*` (to wait for more) and `return next()` (to keep the
   * socket); close by returning a terminal body. The response head is
   * the ambient `response.*` global, committed to the wire by the first
   * `stream.start()` / `stream.write()` (or a terminal return).
   *
   * @namespace stream
   * @example
   * // SSE: open, emit rows, then wait for more under a prefix.
   * response.headers = { 'content-type': 'text/event-stream' };
   * stream.start();
   * for (const r of rows) stream.write(`data: ${r}\n\n`);
   * on.kv(`feed/${id}/`, { to: 'onNotify' });
   * return next({ since: rows.at(-1)?.seq });
   */
  globalThis.stream = {
    /**
     * Open the streamed response: commit the ambient `response.*` head
     * and begin the stream so the client's `onopen` fires before any
     * data. Optional — the first `stream.write()` opens it implicitly.
     *
     * @returns {void}
     */
    start() {
      return sys.start();
    },

    /**
     * Emit one chunk to the held socket. **Commit-gated**: the chunk
     * reaches the wire only after this activation's writes commit. Call
     * it as many times per activation as you like; raw bytes (SSE
     * `data:` framing is yours to write).
     *
     * @param {string|Uint8Array} chunk - The bytes to emit.
     * @returns {void}
     */
    write(chunk) {
      return sys.write(chunk);
    },
  };
})();
