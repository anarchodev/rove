// Public `console` surface — the documentation source of truth for
// handler logging (docs/builtin-libs-docs-plan.md Phase A).
//
// Thin shim over the native `_system.console` binding. The top-level
// name (`console.log`) is unchanged; `_system.*` is the internal ABI
// and customer code must never reference it directly.
//
// Evaluated as a global script (no module/exports) into every
// dispatcher context after the native bindings install.

(function () {
  const sys = _system.console;

  /**
   * Handler logging. Output is captured into the per-request log
   * buffer (not stdout) and surfaces in the tenant's request logs and
   * the replay shell — it is part of the recorded, replay-deterministic
   * request trace.
   *
   * @namespace console
   */
  globalThis.console = {
    /**
     * Write a line to the request log. Arguments are converted to
     * strings, space-joined, and terminated with a newline — the same
     * shape as a single `console.log` call in a browser or Node.
     *
     * @param {...*} args - Values to log. Each is coerced to a string;
     *   pass `JSON.stringify(obj)` to log structured data readably.
     * @returns {void}
     *
     * @example
     * console.log("charge ok", chargeId, JSON.stringify({ amount }));
     * // → "charge ok 42 {"amount":1999}" in the request log
     */
    log(...args) {
      return sys.log(...args);
    },
  };
})();
