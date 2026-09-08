// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Public `kv` surface — the documentation source of truth for the
// tenant key/value store (docs/architecture/builtin-libs.md Phase A).
//
// A FACTORY (`docs/architecture/package-isolation.md`, the
// received-not-ambient model): the engine invokes it once per context
// with the native kv slice as its one capability
// (`_factories_invoke.js`) and installs the returned object at the
// top-level name customers call (`kv.get`, `kv.set`, …). The factory
// has no module-scope bindings for a handler to resolve; its
// capability exists only inside this closure.

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
__rove_factories.kv = function (caps) {
  const sys = caps.kv;
  return {
    /**
     * Read the value for `key`.
     *
     * @param {string} key - The key to look up.
     * @returns {string|null} The stored string, or `null` if the key
     *   does not exist.
     *
     * @example
     * export default ({ kv, response }) => {
     *   const raw = kv.get(`user/${id}`);
     *   if (raw === null) { response.status = 404; return "not found"; }
     *   const user = JSON.parse(raw);
     * };
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
     * export default ({ kv }) => {
     *   kv.set(`user/${user.id}`, JSON.stringify(user));
     * };
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
     * export default ({ kv }) => {
     *   kv.delete(`session/${sid}`);
     * };
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
     * export default ({ kv }) => {
     *   let cursor;
     *   const all = [];
     *   for (;;) {
     *     const page = kv.prefix("user/", cursor, 1000);
     *     if (page.length === 0) break;
     *     all.push(...page);
     *     cursor = page[page.length - 1].key;
     *   }
     * };
     */
    prefix(prefix, cursor, limit) {
      return sys.prefix(prefix, cursor, limit);
    },
  };
};
