// Public `next` disposition verb (docs/handler-shape.md §2.1). Thin shim
// over the `_system.continuation.next` native, captured once at
// base-eval (before `delete globalThis._system`) — the same closure-
// capture pattern as kv.js/webhook.js. Baked `__system/` modules that
// need cross-module dispatch call this public shim (they have the
// ambient globals + it holds the captured ref), so there is no bare
// `__rove_next` native.
//
// `next` parks the held connection: it keeps the socket open and asks
// the runtime to re-invoke this handler on its next activation (a
// kv/timer wake, an after.fetch chunk, a disconnect, …), routed to the
// conventional named export (onWake / onFetchChunk / onDisconnect / …).
// You close instead by returning a terminal body.
//
// Evaluated as a global script after the native bindings install.
// IIFE-wrapped (a bare top-level def corrupts the arenajs base-snapshot).

(function () {
  const sysNext = _system.continuation.next;

  /**
   * Park the held connection and continue on the next activation. `ctx`
   * threads small per-connection state forward as `request.ctx` (a stream
   * cursor, a fan-in accumulator) — it is NOT heap state across
   * activations (the arena resets); durable state lives in `kv`. The
   * runtime resumes THIS module's conventional export for the activation
   * kind. Close the connection by returning a terminal body instead.
   *
   * Called with two arguments, it continues into a DIFFERENT module:
   * `next(targetModule, ctx)` parks and re-enters `targetModule`'s
   * conventional export instead of this one — the cross-module
   * continuation (the same "name a target module" shape as
   * `schedule(when, target)` / `webhook.send({ on })`).
   *
   * @param {*} [ctx] - Per-connection state for the next activation.
   *   (When two args are given, this first argument is the target
   *   module path string instead — see below.)
   * @param {*} [crossCtx] - Only with a target: the ctx to thread into
   *   `targetModule`.
   * @returns {object} The opaque park descriptor — return it.
   * @example
   * stream.write(`data: ${row.value}\n\n`);
   * after.kv(`feed/${id}/`);
   * return next({ since: row.seq });
   */
  globalThis.next = function (ctx, crossCtx) {
    // Two args ⇒ cross-module: next(targetModule, ctx). One/zero args is
    // ALWAYS same-module (ctx may itself be a string cursor, so we key on
    // arg count, never on arg type — keeps `next("cursor")` same-module).
    if (arguments.length >= 2) {
      if (typeof ctx !== "string") {
        throw new TypeError("next(target, ctx): target must be a module path string");
      }
      return sysNext(ctx, { ctx: crossCtx });
    }
    return sysNext("", arguments.length === 0 ? {} : { ctx: ctx });
  };
})();
