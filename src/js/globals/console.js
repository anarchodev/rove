// Public `console` surface — the documentation source of truth for
// handler logging (docs/architecture/builtin-libs.md Phase A).
//
// Thin shim over the native `_system.console` binding. The top-level
// name (`console.log`) is unchanged; `_system.*` is the internal ABI
// and customer code must never reference it directly.
//
// Evaluated as a global script (no module/exports) into every
// dispatcher context after the native bindings install.

(function () {
  const sys = _system.console;

  // The ONE argument formatter. Strings pass through; everything else is
  // JSON-stringified so structured values read as structure in the log —
  // never "[object Object]". Values JSON can't express (undefined,
  // functions, symbols, BigInt, circular graphs) fall back to String(x).
  // The sim's capturing console (src/replay/epilogue.zig __fmtLog) mirrors
  // this byte-for-byte — log assertions transfer between a `rewind test`
  // bundle and a live request log; change one, change both.
  const fmt = (x) => {
    if (typeof x === "string") return x;
    try {
      const s = JSON.stringify(x);
      return s === undefined ? String(x) : s;
    } catch (_) {
      return String(x);
    }
  };

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
     * Write a line to the request log. String arguments pass through;
     * everything else is JSON-stringified (`{a: 1}` logs as `{"a":1}`,
     * never `[object Object]`). Arguments are space-joined and the line
     * is newline-terminated.
     *
     * @param {...*} args - Values to log. Objects/arrays/numbers are
     *   JSON-stringified; values JSON can't express (`undefined`,
     *   functions, circular graphs) log their `String(...)` form.
     * @returns {void}
     *
     * @example
     * console.log("charge ok", chargeId, { amount });
     * // → "charge ok 42 {"amount":1999}" in the request log
     */
    log(...args) {
      return sys.log(...args.map(fmt));
    },

    /**
     * `console.log` with a `[warn]` prefix — the standard quartet all
     * land in the same request log (one stream, replay-deterministic);
     * the prefix is the level.
     *
     * @param {...*} args - Values to log.
     * @returns {void}
     * @example
     * console.warn("retrying", attempt);
     */
    warn(...args) {
      return sys.log("[warn]", ...args.map(fmt));
    },

    /**
     * `console.log` with an `[error]` prefix.
     *
     * @param {...*} args - Values to log.
     * @returns {void}
     * @example
     * console.error("upstream failed", request.status);
     */
    error(...args) {
      return sys.log("[error]", ...args.map(fmt));
    },

    /**
     * `console.log` with an `[info]` prefix.
     * @param {...*} args - Values to log.
     * @returns {void}
     */
    info(...args) {
      return sys.log("[info]", ...args.map(fmt));
    },

    /**
     * `console.log` with a `[debug]` prefix.
     * @param {...*} args - Values to log.
     * @returns {void}
     */
    debug(...args) {
      return sys.log("[debug]", ...args.map(fmt));
    },
  };
})();
