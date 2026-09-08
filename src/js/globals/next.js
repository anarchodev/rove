// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Public `next` disposition verb (docs/handler-shape.md §2.1). Thin shim
// over the `_system.continuation.next` native, received as its one
// capability. Baked `__system/` modules that need cross-module dispatch
// call this public shim (they have the ambient globals + it holds the
// received ref), so there is no bare `__rove_next` native.
//
// `next` parks the held connection: it keeps the socket open and asks
// the runtime to re-invoke this handler on its next activation (a
// kv/timer wake, an after.fetch chunk, a disconnect, …), routed to the
// conventional named export (onWake / onFetchChunk / onDisconnect / …).
// You close instead by returning a terminal body.
//
// A FACTORY (`docs/architecture/package-isolation.md`, the
// received-not-ambient model): the engine invokes it once per context
// (`_factories_invoke.js`) and installs the returned function at the
// public name. No module-scope bindings escape into the base snapshot.

/**
 * Park the held connection and continue on the next activation. `ctx`
 * threads small per-connection state forward as `request.ctx` (a stream
 * cursor, a fan-in accumulator) — it is NOT heap state across
 * activations (the arena resets); durable state lives in `kv`. The
 * runtime resumes THIS module's conventional export for the activation
 * kind. Close the connection by returning a terminal body instead.
 *
 * Called with two arguments, it continues into a DIFFERENT module:
 * `next(targetModule, ctx)` re-aims the held chain to `targetModule`,
 * so EVERY later resume — timer/kv wake, bound fetch chunk, the next
 * WebSocket frame, disconnect — dispatches at the target's
 * conventional export instead of this one. One semantic on every held
 * chain (plain hold, streaming, WebSocket); the same "name a target
 * module" shape as `schedule(when, target)` / `webhook.send({ on })`.
 *
 * A park must be resumable: at park time the chain needs ≥1 possible
 * resume source (an `after.*` arm — this hop's or riding from an
 * earlier one — an in-flight bound fetch / `blob.receive`, a lone owed
 * send, or the connection's own inbound traffic). A `next()` with
 * none is a defined `500 held with no wake source` at the park site.
 *
 * @param {*} [ctx] - Per-connection state for the next activation.
 *   (When two args are given, this first argument is the target
 *   module path string instead — see below.)
 * @param {*} [crossCtx] - Only with a target: the ctx to thread into
 *   `targetModule`.
 * @returns {object} The opaque park descriptor — return it.
 * @example
 * export default ({ stream, after, next }) => {
 *   stream.write(`data: ${row.value}\n\n`);
 *   after.kv(`feed/${id}/`);
 *   return next({ since: row.seq });
 * };
 */
__rove_factories.next = function (caps) {
  const sysNext = caps.next;

  return function (ctx, crossCtx) {
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
};
