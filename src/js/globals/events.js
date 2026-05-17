// Public `events` surface — the documentation source of truth for
// server-sent events (docs/builtin-libs-docs-plan.md Phase A).
//
// Thin shim over the native `_system.events` binding. Top-level
// `events.emit` is unchanged; `_system.*` is the internal ABI and
// customer code must never reference it directly.
//
// Evaluated as a global script (no module/exports) into every
// dispatcher context after the native bindings install.

(function () {
  const sys = _system.events;

  /**
   * Server-sent events. Emitting writes an event row in the handler's
   * transaction; the SSE pump delivers it to connected `EventSource`
   * clients. Events stay within this tenant. Replay-deterministic: the
   * returned id derives from `(request_id, call_index)`.
   *
   * @namespace events
   */
  globalThis.events = {
    /**
     * Emit one event. String form is shorthand for a `"message"`
     * event to the current session.
     *
     * Rate-limited per instance (one token per call regardless of
     * fan-out) — throws `Error{code:"rate_limited"}` when exhausted.
     *
     * @param {string|object} event - A string (sent as
     *   `{data: <string>, type: "message"}` to the current session),
     *   or an options object.
     * @param {*} [event.data] - Event payload (JSON-serialized onto
     *   the wire).
     * @param {string} [event.type="message"] - SSE event type.
     * @param {string|string[]} [event.to] - Target session id, or an
     *   array of them. Omitted → the current session. Each must be a
     *   64-char lowercase-hex sid (`Error{code:"events_bad_arg"}`
     *   otherwise). `id` is platform-derived and must not be supplied
     *   (`Error{code:"events_id_reserved"}`).
     * @returns {string} The event wire id, `"{request_id}-{call_index}"`.
     *
     * @example
     * // Shorthand: a "message" event to the caller's own stream.
     * events.emit("ping");
     *
     * @example
     * // Typed event fanned out to specific sessions.
     * events.emit({
     *   type: "order_update",
     *   data: { orderId, status: "shipped" },
     *   to: [aliceSid, bobSid],
     * });
     */
    emit(event) {
      return sys.emit(event);
    },
  };
})();
