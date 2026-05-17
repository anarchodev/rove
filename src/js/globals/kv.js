// Public `kv` surface — the documentation source of truth for the
// tenant key/value store (docs/builtin-libs-docs-plan.md Phase A).
//
// This is a thin shim over the native `_system.kv` binding. The
// top-level name customers call (`kv.get`, `kv.set`, …) is unchanged;
// only the implementation moved behind `_system`. `_system.*` is the
// internal ABI — unstable and undocumented; customer code must never
// reference it directly.
//
// Evaluated as a global script (no module/exports) into every
// dispatcher context after the native bindings install.

(function () {
  const sys = _system.kv;

  /**
   * Tenant-scoped key/value store. Keys and values are strings. Every
   * key lives in this tenant's `app.db`; reads and writes never cross
   * tenant boundaries. All operations are replay-deterministic — the
   * same handler run against the same recorded tape observes identical
   * results.
   *
   * Writes made via `kv.set` / `kv.delete` are buffered in the request
   * transaction and commit atomically when the handler returns; they
   * also replicate through Raft to followers.
   *
   * @namespace kv
   */
  globalThis.kv = {
    /**
     * Read the value for `key`.
     *
     * @param {string} key - The key to look up.
     * @returns {string|null} The stored string, or `null` if the key
     *   does not exist.
     *
     * @example
     * const raw = kv.get(`user/${id}`);
     * if (raw === null) return new Response("not found", { status: 404 });
     * const user = JSON.parse(raw);
     */
    get(key) {
      return sys.get(key);
    },

    /**
     * Write `value` under `key`, overwriting any existing value. The
     * write is staged in the request transaction and commits when the
     * handler returns successfully.
     *
     * Throws if `key` falls in a platform-reserved prefix
     * (`err.code === "reserved_key"`) or if a registered trigger
     * rejects the write (`err.code === "trigger_rejected"`).
     *
     * @param {string} key - The key to write.
     * @param {string} value - The string value to store. Serialize
     *   structured data yourself (e.g. `JSON.stringify`).
     * @returns {void}
     *
     * @example
     * kv.set(`user/${user.id}`, JSON.stringify(user));
     */
    set(key, value) {
      return sys.set(key, value);
    },

    /**
     * Delete `key`. A no-op if the key does not exist. Staged in the
     * request transaction like `set`.
     *
     * @param {string} key - The key to delete.
     * @returns {void}
     *
     * @example
     * kv.delete(`session/${sid}`);
     */
    delete(key) {
      return sys.delete(key);
    },

    /**
     * Scan keys sharing a common prefix, in key order. Paginated: pass
     * the last key of one page back as `cursor` to fetch the next.
     *
     * @param {string} prefix - Key prefix to scan (e.g. `"user/"`).
     * @param {string} [cursor] - Resume after this key. Omit, `null`,
     *   or `""` to start from the beginning of the prefix.
     * @param {number} [limit=100] - Max entries to return. Clamped to
     *   the range 1–1000; non-positive values fall back to 100.
     * @returns {Array<{key: string, value: string}>} Matching entries
     *   in ascending key order. An empty array ends the scan.
     *
     * @example
     * let cursor;
     * const all = [];
     * for (;;) {
     *   const page = kv.prefix("user/", cursor, 1000);
     *   if (page.length === 0) break;
     *   all.push(...page);
     *   cursor = page[page.length - 1].key;
     * }
     */
    prefix(prefix, cursor, limit) {
      return sys.prefix(prefix, cursor, limit);
    },
  };
})();
