// Public `next` disposition verb (docs/handler-shape.md §2.1). Thin shim
// over the native `__rove_next` global.
//
// `next` parks the held connection: it keeps the socket open and asks
// the runtime to re-invoke this handler on its next activation (a
// kv/timer wake, an on.fetch chunk, a disconnect, …), routed to the
// conventional named export (onWake / onFetchChunk / onDisconnect / …).
// You close instead by returning a terminal body.
//
// Evaluated as a global script after the native bindings install.
// IIFE-wrapped (a bare top-level def corrupts the arenajs base-snapshot).

(function () {
  /**
   * Park the held connection and continue on the next activation. `ctx`
   * threads small per-connection state forward as `request.ctx` (a stream
   * cursor, a fan-in accumulator) — it is NOT heap state across
   * activations (the arena resets); durable state lives in `kv`. The
   * runtime resumes THIS module's conventional export for the activation
   * kind. Close the connection by returning a terminal body instead.
   *
   * @param {*} [ctx] - Per-connection state for the next activation.
   * @returns {object} The opaque park descriptor — return it.
   * @example
   * stream.write(`data: ${row.value}\n\n`);
   * on.kv(`feed/${id}/`);
   * return next({ since: row.seq });
   */
  globalThis.next = function (ctx) {
    return __rove_next("", arguments.length === 0 ? {} : { ctx: ctx });
  };
})();
