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
  // `on.fetch` native (captured before `_harden.js` deletes `_system`) —
  // `platform.compile` lowers to a bound fetch to a trusted compile door.
  const sysOn = _system.on;

  /**
   * Admin control plane: cross-tenant kv access, the platform root
   * store, instance lifecycle, releases, and root-token auth. Only
   * usable from the `__admin__` handler.
   *
   * @namespace platform
   */
  globalThis.platform = {
    /**
     * Get accessors scoped to another instance — the explicit
     * cross-tenant grant (replaces the old X-Rove-Scope global-kv rebind).
     *
     * @param {string} id - Target instance id (non-empty).
     * @returns {{kv:object, blob:object, deploy:object}}
     *   - `kv` — `{get, set, delete, prefix}`, the same as the global
     *     {@link kv}, bound to instance `id`.
     *   - `blob` — `{put(bytes, {content_type})}`: stage a content-addressed
     *     blob into `id`'s file-blobs; returns the sha256 hash synchronously
     *     (the PUT defers off the poll loop). The blob twin of `kv`.
     *   - `deploy` — `{stampManifest(entries)}`: write a deployment manifest
     *     into `id`'s deployments/ from the app's composed `entries`
     *     (`[{path, kind, source_hex, bytecode_hex?, content_type?}]`);
     *     returns the dep_id (16-hex). Compose deploys with
     *     {@link platform.compile} + `blob.put` + `stampManifest`, then
     *     activate with {@link platform.releases.publish}.
     *   Unknown id throws `Error{code:"InstanceNotFound"}`.
     *
     * @example
     * const { kv: tenantKv } = platform.scope(req.instanceId);
     * const profile = tenantKv.get("profile");
     */
    scope(id) {
      return sys.scope(id);
    },

    /**
     * Compile handler sources to bytecode + content-address them into
     * `scope`'s blobs, off the hot path (`rewind-cli-plan.md` §4.1).
     * Admin-only (the issuing tenant is checked natively). Source →
     * bytecode is the one irreducibly-native deploy step; it's async
     * (compile is slow) but its result is deterministic + idempotent, so
     * it needs no replay tape.
     *
     * **Bound, like {@link on.fetch}:** the call binds to the held chain,
     * so you must `return next()` after it; the result resumes your
     * handler at the `name` export (default `onFetchResult`) with
     * `request.ctx = {ok, results:[{path, source_hex, bytecode_hex}]}`
     * (or `{ok:false, status, error}`). Compose the manifest from those
     * hashes + your statics and stamp it there. Stage/activate is still a
     * separate `platform.releases.publish`.
     *
     * @param {Array<{path:string, source:string}>} files - Handler sources.
     * @param {object} opts
     * @param {string} opts.scope - Target instance id (where blobs stage).
     * @param {string} [opts.name="onFetchResult"] - Resume export.
     * @returns {string} The bound fetch id.
     *
     * @example
     * platform.compile(handlers, { scope: tenant, name: "onCompiled" });
     * return next();
     * // export function onCompiled(request) {
     * //   const { results } = request.ctx; ...stamp manifest...
     * // }
     */
    compile(files, opts) {
      opts = opts || {};
      const body = JSON.stringify({ scope: opts.scope, files });
      return sysOn.fetch(
        "http://rove-compile.internal/",
        { method: "POST", body },
        { to: opts.name || "onFetchResult" },
      );
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
