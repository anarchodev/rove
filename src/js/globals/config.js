// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Public `config` surface — the documentation source of truth for
// deploy-time configuration (rove#830: the only door to `_config/`).
//
// This is a thin shim over the native `_system.config` binding.
// `_system.*` is the internal ABI — unstable and undocumented; customer
// code must never reference it directly.
//
// A FACTORY (`docs/architecture/package-isolation.md`, the
// received-not-ambient model): the engine invokes it once per context
// with its capability slice as the one argument (`_factories_invoke.js`)
// and installs the returned surface at the public name. The factory has
// no module-scope bindings for a handler to resolve; its capabilities
// exist only inside this closure.

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
__rove_factories.config = function (caps) {
  const sys = caps.config;

  return {
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
     * export default ({ config, response }) => {
     *   const raw = config.get("oauth/google");
     *   if (raw === null) { response.status = 500; return "missing config: oauth/google"; }
     *   const cfg = JSON.parse(raw);
     * };
     */
    get(name) {
      return sys.get(name);
    },
  };
};
