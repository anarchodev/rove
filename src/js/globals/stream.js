// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
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
   * with `after.*` (to wait for more) and `return next()` (to keep the
   * socket); close by returning a terminal body. The response head is
   * the ambient `response.*` global, committed to the wire by the first
   * `stream.start()` / `stream.write()` (or a terminal return).
   *
   * This is the OUTBOUND direction only. Taking a large body IN is
   * `blob.receive`/`blob.write` (an upload session); an append log you
   * name and query is `segments.*` — neither involves this namespace.
   *
   * @namespace stream
   * @example
   * // SSE: open, emit rows, then wait for more under a prefix.
   * const rows = kv.prefix(`feed/${id}/`, request.ctx?.cursor);
   * response.headers = { 'content-type': 'text/event-stream' };
   * stream.start();
   * for (const r of rows) stream.write(`data: ${r.value}\n\n`);
   * after.kv(`feed/${id}/`, { on: 'onNotify' });
   * return next({ cursor: rows.at(-1)?.key ?? request.ctx?.cursor });
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
