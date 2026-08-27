// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Public `config` surface — the documentation source of truth for
// deploy-time configuration (rove#830: the only door to `_config/`).
//
// This is a thin shim over the native `_system.config` binding.
// `_system.*` is the internal ABI — unstable and undocumented; customer
// code must never reference it directly.
//
// Evaluated as a global script (no module/exports) into every
// dispatcher context after the native bindings install.

(function () {
  const sys = _system.config;

  /**
   * Deploy-time configuration, read-only. A config file deployed at
   * `_config/<name>.json` is readable here as `<name>` — and only
   * here: config is not part of the kv keyspace a handler can name.
   *
   * Values are scoped to the deployment the activation runs under, so
   * code and its config switch atomically on release — including a
   * rollback, and a deploy that removes a file (the read then returns
   * `null`).
   *
   * @namespace config
   */
  globalThis.config = {
    /**
     * Read one config value.
     *
     * @param {string} name - The config path without the `_config/`
     *   prefix or the `.json` suffix (e.g. `"oauth/google"` for a
     *   deployed `_config/oauth/google.json`).
     * @returns {string|null} The file's bytes as a string — parse
     *   JSON yourself — or `null` if this deployment carries no such
     *   config.
     *
     * @example
     * const raw = config.get("oauth/google");
     * if (raw === null) { response.status = 500; return "missing config: oauth/google"; }
     * const cfg = JSON.parse(raw);
     */
    get(name) {
      return sys.get(name);
    },
  };
})();
