// Public `platform` surface — the documentation source of truth for
// the admin control plane (docs/builtin-libs-docs-plan.md Phase A;
// auth-domain-plan.md for the admin handler context).
//
// Thin shim over the native `_system.platform` binding. Top-level
// `platform.*` is unchanged; `_system.*` is the internal ABI and
// customer code must never reference it directly.
//
// Every method is admin-only: it throws `TypeError` ("platform is
// only available on the admin handler") when reached from a normal
// tenant handler — the gate is enforced natively, the shim only
// forwards. Evaluated as a global script into every dispatcher
// context after the native bindings install.

(function () {
  const sys = _system.platform;

  /**
   * Admin control plane: cross-tenant kv access, the platform root
   * store, instance lifecycle, releases, and root-token auth. Only
   * usable from the `__admin__` handler.
   *
   * @namespace platform
   */
  globalThis.platform = {
    /**
     * Get a kv accessor scoped to another instance's `app.db`. The
     * explicit cross-tenant accessor (replaces the old X-Rove-Scope
     * global-kv rebind).
     *
     * @param {string} id - Target instance id (non-empty).
     * @returns {{kv:{get:function,set:function,delete:function,prefix:function}}}
     *   `kv` has the same four methods as the global {@link kv}, bound
     *   to instance `id`. Unknown id throws
     *   `Error{code:"InstanceNotFound"}`.
     *
     * @example
     * const { kv: tenantKv } = platform.scope(req.instanceId);
     * const profile = tenantKv.get("profile");
     */
    scope(id) {
      return sys.scope(id);
    },

    /**
     * The platform root store (`__root__.db`) — instance / domain /
     * user / account metadata.
     *
     * @namespace platform.root
     */
    root: {
      /**
       * @param {string} key
       * @returns {string|null} The value, or `null` if absent.
       * @example const acct = JSON.parse(platform.root.get(`account/${id}`));
       */
      get(key) {
        return sys.root.get(key);
      },
      /**
       * Write to the root store. Replicates via the root writeset.
       * @param {string} key
       * @param {string} value
       * @returns {void}
       * @example platform.root.set(`domain/${host}`, JSON.stringify(rec));
       */
      set(key, value) {
        return sys.root.set(key, value);
      },
      /**
       * @param {string} key
       * @returns {void}
       * @example platform.root.delete(`domain/${host}`);
       */
      delete(key) {
        return sys.root.delete(key);
      },
      /**
       * Prefix scan of the root store. Same pagination contract as
       * {@link kv.prefix} (limit default 100, max 1000).
       * @param {string} prefix
       * @param {string} [cursor]
       * @param {number} [limit=100]
       * @returns {Array<{key:string,value:string}>}
       * @example const all = platform.root.prefix("instance/", null, 1000);
       */
      prefix(prefix, cursor, limit) {
        return sys.root.prefix(prefix, cursor, limit);
      },
    },

    /**
     * Instance lifecycle.
     *
     * @namespace platform.instances
     */
    instances: {
      /**
       * Create an instance: its directory + `app.db`, the local
       * `instance/{name}` marker, and the replicated root marker.
       * Idempotent. Throws `Error{code:"InvalidName"}` on a bad name.
       *
       * @param {string} name - Instance id.
       * @returns {void}
       * @example platform.instances.create("acme-prod");
       */
      create(name) {
        return sys.instances.create(name);
      },
      /**
       * Deploy the platform-baked starter app (`index.mjs` +
       * `_static/index.html`) into `name` and flip
       * `_deploy/current` via raft. Sealed primitive in v1 (starter
       * content is not customer-supplied). Throws
       * `Error{code:"InstanceNotFound"}` if `name` doesn't resolve.
       *
       * @param {string} name - Target instance id.
       * @returns {void}
       * @example platform.instances.deployStarter("acme-prod");
       */
      deployStarter(name) {
        return sys.instances.deployStarter(name);
      },
    },

    /**
     * Releases.
     *
     * @namespace platform.releases
     */
    releases: {
      /**
       * Activate deployment `depId` on `tenantId`: stamp
       * `_deploy/current`, propose envelope-0 through raft (no
       * blocking on consensus), and enqueue the deployment loader.
       * Returns sub-millisecond; consensus + bytecode load run async.
       * Throws `Error{code:"InstanceNotFound"}` if `tenantId` doesn't
       * resolve.
       *
       * @param {string} tenantId - Target instance id.
       * @param {string} depId - Deployment id to activate.
       * @returns {void}
       * @example platform.releases.publish("acme-prod", depId);
       */
      publish(tenantId, depId) {
        return sys.releases.publish(tenantId, depId);
      },
    },

    /**
     * Root-token auth.
     *
     * @namespace platform.auth
     */
    auth: {
      /**
       * Validate a platform root token.
       *
       * @param {string} token - The bearer token to check.
       * @returns {boolean} `true` if the token authenticates.
       * @example
       * if (!platform.auth.checkRootToken(bearer))
       *   return new Response("forbidden", { status: 403 });
       */
      checkRootToken(token) {
        return sys.auth.checkRootToken(token);
      },
    },
  };
})();
