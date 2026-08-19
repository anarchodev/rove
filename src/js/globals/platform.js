// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Public `platform` surface — the documentation source of truth for
// the admin control plane (docs/architecture/builtin-libs.md Phase A;
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
  // `after.fetch` native (captured before `_harden.js` deletes `_system`) —
  // `platform.compile` lowers to a bound fetch to a trusted compile door.
  const sysOn = _system.after;
  // `blob.receive` native — `platform.scope(t).blob.receive` lowers to a
  // cross-tenant streamed upload (extra target + ctx args, admin-gated).
  const sysBlobReceive = _system.blob.receive;
  const sysBlobPresign = _system.blob.presign;

  // Fail loud on a retired option spelling. Each shim keeps its own copy —
  // the helper in after.js is inside that file's IIFE. Silence here is worse
  // than a break: an ignored resume-export key ran the call anyway and
  // resumed at the DEFAULT export, surfacing as a 404 somewhere unrelated.
  function _rejectRenamed(verb, opts, renames) {
    if (!opts || typeof opts !== "object") return;
    for (const k in renames) {
      if (k in opts) throw new TypeError(verb + ": option `" + k + "` was renamed — use `" + renames[k] + "`");
    }
  }

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
     *   - `blob` — `{get(hash, {on}), receive({on, ctx}), exportUrl(hash,
     *     {ttl}), fileUrl(hash, {ttl, contentType})}`: cross-tenant blob READ
     *     (resumes `on` with the bytes), STREAMED write (pipe the inbound
     *     body straight into `id`'s file-blobs, no JS buffering), and the
     *     sync presign twins of {@link blob.exportUrl} / {@link blob.fileUrl}
     *     over `id`'s pools (export download links + bundle file links —
     *     rove#340). There is no sync `put` — cross-tenant writes stream via
     *     `receive`.
     *   - `deploy` — `{stampManifest(entries), readManifest(dep)}`: write/read a
     *     deployment manifest in `id`'s deployments/ from composed `entries`
     *     (`[{path, kind, source_hex, bytecode_hex?, content_type?}]`);
     *     stampManifest returns the dep_id (16-hex). Compose deploys with
     *     {@link platform.compile} (handlers) + `blob.receive` (statics) +
     *     `stampManifest`, then activate with {@link platform.releases.publish}.
     *   Unknown id throws `Error{code:"InstanceNotFound"}`.
     *
     * @example
     * const { kv: tenantKv } = platform.scope(req.instanceId);
     * const profile = tenantKv.get("profile");
     */
    scope(id) {
      const s = sys.scope(id);
      // Cross-tenant blob READ — the read twin of `blob.put`. Bound, like
      // {@link blob.get}: it lowers to an after.fetch at the admin-only
      // `rove-blob-read.internal` door (rewritten to `id`'s S3 prefix +
      // SigV4-signed natively). The bytes resume on `request.bytes` at the
      // `on` export (default onFetchResult); thread state with `opts.ctx`
      // (→ `request.ctx`). Return next() after it. Compose the replay bundle /
      // Code-tab sources from these reads in JS — no native assembly.
      // Cross-tenant STREAMED upload — the streaming twin of blob.put. Pipes
      // the inbound request body straight to `id`'s file-blobs (zero JS
      // buffering, no chunk activations), resuming `on` with
      // `request.ctx = {hash, len, app:<opts.ctx>}` when durable. onHeaders-only
      // (like blob.receive); for large statics the deploy app uses this instead
      // of base64-buffering through blob.put.
      s.blob.receive = function (opts) {
        opts = opts || {};
        return sysBlobReceive(
          typeof opts.on === "string" ? opts.on : undefined, id,
          JSON.stringify(opts.ctx !== undefined ? opts.ctx : null),
        );
      };
      s.blob.get = function (hash, opts) {
        opts = opts || {};
        const fetch_opts = {
          method: "GET",
          max_response_chunk_bytes: opts.max_bytes || 8 * 1024 * 1024,
        };
        if (opts.ctx !== undefined) fetch_opts.ctx = opts.ctx;
        fetch_opts.on = opts.on || "onFetchResult";
        return sysOn.fetch(
          "http://rove-blob-read.internal/" + id + "/blob/" + hash,
          fetch_opts,
        );
      };
      // Cross-tenant presign twins of `blob.exportUrl` / `blob.fileUrl` —
      // sync, admin-only (the native's target arg is gated on the platform
      // grant). The dashboard mints a customer's export-part links and the
      // bundle manifest's per-file links from these; the signed prefix comes
      // from `id`'s resolved storage handle (id + incarnation), never from
      // this argument (rove#340).
      s.blob.exportUrl = function (hash, opts) {
        opts = opts || {};
        return sysBlobPresign(hash, opts.ttl != null ? opts.ttl : null, null,
                              "exports", id);
      };
      s.blob.fileUrl = function (hash, opts) {
        opts = opts || {};
        return sysBlobPresign(hash, opts.ttl != null ? opts.ttl : null,
                              opts.contentType != null ? opts.contentType : null,
                              "file-blobs", id);
      };
      // deploy.stampManifest is the deploy's STAGING BARRIER — it lowers to
      // a bound after.fetch (not a native sync call) so it resumes your handler
      // only once the manifest (the last staging write) AND every prior
      // bytecode/static PUT is durable. Return next() after it; the result
      // arrives at the `on` export (default onStamped) as
      // `request.ctx = {ok, dep_id}`.
      s.deploy = {
        stampManifest(entries, opts) {
          opts = opts || {};
          _rejectRenamed("deploy.stampManifest", opts, { name: "on", to: "on" });
          const req = { scope: id, entries };
          // PM P1: `opts.resolution` bakes the deploy's `{packages,
          // app_imports}` sections into the manifest (and its dep_id).
          if (opts.resolution !== undefined)
            req.resolution = JSON.stringify(opts.resolution);
          return sysOn.fetch(
            "http://rove-stage.internal/",
            { method: "POST", body: JSON.stringify(req), on: opts.on || "onStamped" },
          );
        },
        // readManifest is the READ twin of stampManifest: it reads `id`'s
        // deployment manifest for `dep_id` (16-hex) off the read door. The raw
        // manifest JSON resumes on `request.json` at `on` (default
        // onFetchResult) — parse it in JS, then read each handler entry's
        // source with `scope(id).blob.get(hash)`. The current dep_id is
        // `scope(id).kv.get("_deploy/current")`.
        readManifest(dep_id, opts) {
          opts = opts || {};
          const fetch_opts = { method: "GET", on: opts.on || "onFetchResult" };
          if (opts.ctx !== undefined) fetch_opts.ctx = opts.ctx;
          return sysOn.fetch(
            "http://rove-blob-read.internal/" + id + "/manifest/" + dep_id,
            fetch_opts,
          );
        },
      };
      return s;
    },

    /**
     * Content-address handler sources into `scope`'s blobs WITHOUT
     * compiling them, resuming with `{ok, results:[{path, source_hex}]}`.
     *
     * The staging half of a deploy. Compilation resolves every import
     * eagerly, so a module can only be compiled once everything it imports
     * exists — which, for a deploy that uploads files one at a time, is not
     * true until the last file lands. Stage each file as it arrives, then
     * {@link platform.compile} the finished bundle, where a sibling import
     * resolves.
     *
     * **Bound, like {@link platform.compile}:** `return next()` after it.
     *
     * @param {Array<{path:string, source:string}>} files - Handler sources.
     * @param {object} opts
     * @param {string} opts.scope - Target instance id (where blobs land).
     * @param {string} [opts.on="onFetchResult"] - Resume export.
     * @param {*} [opts.ctx] - Threaded to the resume as `request.ctx.app`.
     * @returns {string} The bound fetch id (`ftch_…`).
     *
     * @example
     * platform.stage([{ path, source }], { scope: tenant, on: "onStaged" });
     * return next();
     */
    stage(files, opts) {
      opts = opts || {};
      _rejectRenamed("platform.stage", opts, { name: "on", to: "on" });
      const body = JSON.stringify({ scope: opts.scope, files, stage: true });
      return sysOn.fetch(
        "http://rove-compile.internal/",
        { method: "POST", body, ctx: opts.ctx, on: opts.on || "onFetchResult" },
      );
    },

    /**
     * Compile handler sources to bytecode + content-address them into
     * `scope`'s blobs, off the hot path (`docs/architecture/cli-and-deploy.md` §4.1).
     * Admin-only (the issuing tenant is checked natively). Source →
     * bytecode is the one irreducibly-native deploy step; it's async
     * (compile is slow) but its result is deterministic + idempotent, so
     * it needs no replay tape.
     *
     * **Bound, like {@link on.fetch}:** the call binds to the held chain,
     * so you must `return next()` after it; the result resumes your
     * handler at the `on` export (default `onFetchResult`) with
     * `request.ctx = {ok, results:[{path, source_hex, bytecode_hex}]}`
     * (or `{ok:false, status, error}`). Compose the manifest from those
     * hashes + your statics and stamp it there. Stage/activate is still a
     * separate `platform.releases.publish`.
     *
     * Imports resolve — and are therefore VALIDATED — across the whole
     * batch: a handler may import a sibling in the same call, and a
     * specifier that resolves to nothing fails the compile.
     *
     * @param {Array<{path:string, source?:string, source_hash?:string}>} files
     *   Handler sources, inline or by the `source_hex` a prior
     *   {@link platform.stage} returned (the engine reads those back from
     *   `scope`'s blobs — they never travel through JS twice).
     * @param {object} opts
     * @param {string} opts.scope - Target instance id (where blobs stage).
     * @param {string} [opts.on="onFetchResult"] - Resume export.
     * @returns {string} The bound fetch id (`ftch_…`).
     *
     * @example
     * platform.compile(handlers, { scope: tenant, on: "onCompiled" });
     * return next();
     * // export function onCompiled(request) {
     * //   const { results } = request.ctx; ...stamp manifest...
     * // }
     */
    compile(files, opts) {
      opts = opts || {};
      // The resume export is `on` everywhere. A retired spelling used to be
      // ignored in silence, so the call ran, resumed at the DEFAULT export,
      // and 404'd somewhere else entirely.
      _rejectRenamed("platform.compile", opts, { name: "on", to: "on" });
      const req = { scope: opts.scope, files };
      // PM P1: `opts.resolution` = the deploy's `{packages, app_imports}`
      // lockfile sections (manifest v2 shapes). The engine fetches the
      // referenced package bytecodes so every `@scope/pkg` import in
      // `files` resolves — and is VALIDATED — at compile. Pre-stringified
      // so the native door needn't re-walk dynamic JSON.
      if (opts.resolution !== undefined)
        req.resolution = JSON.stringify(opts.resolution);
      // PM P1: `opts.pkg_hash` compiles the batch as a PACKAGE's files
      // under `/pkg/<pkg_hash>/…` virtual names (their module identity).
      if (opts.pkg_hash !== undefined) req.pkg_hash = opts.pkg_hash;
      const body = JSON.stringify(req);
      // `opts.ctx` threads forward across the compile re-entry — it's echoed
      // in the result as `request.ctx.app` (the bound resume otherwise only
      // surfaces the compile output). Use it to carry e.g. the deploy's
      // target + composed static entries into the onCompiled handler.
      return sysOn.fetch(
        "http://rove-compile.internal/",
        { method: "POST", body, ctx: opts.ctx, on: opts.on || "onFetchResult" },
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

    // Root-token auth is NOT here. The operator-root verdict is
    // `request.rewind.isRoot` — computed by the engine, which holds both the
    // wire `authorization` header and the secret, and taped as the verdict
    // alone. There is no verb taking the bearer, because a token the handler
    // holds is a token `request.headers` recorded onto the tape; the header is
    // stripped on this handler for the same reason. See
    // `docs/architecture/privileged-surface.md`.
    //
    //   if (!request.rewind.isRoot) { response.status = 403; return { error: "forbidden" }; }
  };
})();
