// @rove/oauth — OAuth 2.0 + OIDC authorization-code flow helper.
//
// Library is a pure transformer over its config: it owns no
// namespace, every kv path it touches is derived from (or specified
// in) the config row.
//
// Config lives at `_config/oauth/{name}` — a JSON file in the
// customer's file tree, mirrored read-only to kv at deploy time.
// Multi-provider apps create one config file per provider:
//
//   _config/oauth/google.json:
//     {
//       "client_id":         "...",
//       "client_secret":     "...",
//       "authorization_url": "https://accounts.google.com/o/oauth2/v2/auth",
//       "token_url":         "https://oauth2.googleapis.com/token",
//       "redirect_uri":      "https://app.example.com/oauth/google/callback",
//       "scopes":            ["openid", "email"],
//       "on_complete_module": "users/oauth_complete"
//     }
//
//   // start handler (oauth/google/start/index.mjs)
//   export default function () {
//     return oauth.fromConfig("google").startLogin({ return_to: "/" });
//   }
//
//   // callback handler (oauth/google/callback/index.mjs)
//   export default function () {
//     return oauth.fromConfig("google").handleCallback();
//   }
//
// State path defaults to `state/oauth/{name}`; cache path to
// `cache/oauth/{name}`. Override either via `state_path`/`cache_path`
// keys in the config file if you want different layouts.

/**
 * An OAuth 2.0 / OIDC authorization-code client bound to one
 * provider config. Obtain via {@link oauth.fromConfig}. PKCE is on
 * unless `pkce:false`. Transient state lives in this tenant's kv at
 * `state/oauth/{name}`.
 *
 * @class OAuthProvider
 */
class OAuthProvider {
  /**
   * @param {object} config - Provider config. Required:
   *   `authorization_url`, `token_url`, `client_id`, `redirect_uri`,
   *   `on_complete_module`, and `scopes` (array). Optional:
   *   `client_secret`, `pkce`, `state_ttl_ms`, `state_path`,
   *   `cache_path`, `extra_authorize_params`.
   * @throws {TypeError} Missing/invalid required key.
   */
  constructor(config) {
    for (const k of ["authorization_url", "token_url", "client_id", "redirect_uri", "on_complete_module"]) {
      if (typeof config[k] !== "string" || !config[k]) {
        throw new TypeError("oauth: missing required config key: " + k);
      }
    }
    if (!Array.isArray(config.scopes)) {
      throw new TypeError("oauth: scopes must be an array");
    }
    this.cfg = {
      authorization_url: config.authorization_url,
      token_url: config.token_url,
      client_id: config.client_id,
      client_secret: config.client_secret,
      redirect_uri: config.redirect_uri,
      scopes: config.scopes,
      on_complete_module: config.on_complete_module,
      pkce: config.pkce !== false,
      state_ttl_ms: config.state_ttl_ms || 10 * 60 * 1000,
      state_path: config.state_path,
      cache_path: config.cache_path,
      extra_authorize_params: config.extra_authorize_params || {},
    };
  }

  /**
   * Begin the login flow: store transient state (+ PKCE verifier),
   * set a 302 to the provider's authorization URL. Return its result
   * from your start handler.
   *
   * @param {object} [opts]
   * @param {string} [opts.return_to] - Where to send the user after
   *   completion (echoed to the on_complete module).
   * @param {object} [opts.context] - Arbitrary data echoed to the
   *   on_complete module.
   * @returns {null} (the redirect is on `response`).
   * @example
   * export default () => oauth.fromConfig("google")
   *   .startLogin({ return_to: "/" });
   */
  startLogin(opts) {
    opts = opts || {};
    const state = crypto.randomUUID();

    let verifier = null;
    let challenge = null;
    if (this.cfg.pkce) {
      const verifier_bytes = new Uint8Array(32);
      crypto.getRandomValues(verifier_bytes);
      verifier = base64url.encode(verifier_bytes);
      challenge = base64url.encode(hex.decode(crypto.sha256(verifier)));
    }

    kv.set(this.cfg.state_path + "/" + state, JSON.stringify({
      verifier,
      return_to: opts.return_to,
      context: opts.context || {},
      created_at: Date.now(),
    }));

    const params = new URLSearchParams({
      client_id: this.cfg.client_id,
      redirect_uri: this.cfg.redirect_uri,
      response_type: "code",
      scope: this.cfg.scopes.join(" "),
      state,
    });
    if (challenge) {
      params.set("code_challenge", challenge);
      params.set("code_challenge_method", "S256");
    }
    for (const k of Object.keys(this.cfg.extra_authorize_params)) {
      params.set(k, String(this.cfg.extra_authorize_params[k]));
    }

    response.status = 302;
    response.headers = {
      location: this.cfg.authorization_url + "?" + params.toString(),
    };
    return null;
  }

  /**
   * Handle the provider redirect: validate `state` (single-use,
   * TTL'd), exchange `code` at the token endpoint via
   * {@link webhook.send}, and invoke `on_complete_module` with the
   * token result (context carries `return_to`). Returns an interim
   * HTML page; sets 4xx on validation failure.
   *
   * @returns {string} HTML body (200/202 interstitial, or 400 text
   *   on error).
   * @example
   * export default () => oauth.fromConfig("google").handleCallback();
   */
  handleCallback() {
    const params = new URLSearchParams(request.query || "");
    const state = params.get("state");
    const code = params.get("code");
    const provider_error = params.get("error");

    if (provider_error) {
      response.status = 400;
      return "OAuth: provider returned error: " + provider_error;
    }
    if (!state || !code) {
      response.status = 400;
      return "OAuth: missing state or code on callback";
    }

    const stored_raw = kv.get(this.cfg.state_path + "/" + state);
    if (stored_raw == null) {
      response.status = 400;
      return "OAuth: unknown state";
    }
    const stored = JSON.parse(stored_raw);
    kv.delete(this.cfg.state_path + "/" + state);

    if (Date.now() - stored.created_at > this.cfg.state_ttl_ms) {
      response.status = 400;
      return "OAuth: state expired";
    }

    const body_params = new URLSearchParams({
      grant_type: "authorization_code",
      code,
      redirect_uri: this.cfg.redirect_uri,
      client_id: this.cfg.client_id,
    });
    if (this.cfg.client_secret) body_params.set("client_secret", this.cfg.client_secret);
    if (stored.verifier) body_params.set("code_verifier", stored.verifier);

    webhook.send({
      url: this.cfg.token_url,
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body_params.toString(),
      on_result: this.cfg.on_complete_module,
      context: Object.assign({}, stored.context, {
        return_to: stored.return_to,
      }),
    });

    response.status = 202;
    response.headers = { "content-type": "text/html; charset=utf-8" };
    return "<!doctype html><meta charset=utf-8><title>Signing in…</title><p>Completing sign-in…</p>";
  }

  /**
   * Redeem a refresh token for new tokens. Fires the token request
   * via {@link webhook.send}; the `on_complete_module` receives the
   * result with `context.refresh === true`.
   *
   * @param {string} refresh_token - The stored refresh token.
   * @param {object} [extra_context] - Merged into the result
   *   context.
   * @returns {string} The {@link webhook.send} schedule id.
   * @example
   * oauth.fromConfig("google").refresh(tok, { user_sub });
   */
  refresh(refresh_token, extra_context) {
    const body_params = new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token,
      client_id: this.cfg.client_id,
    });
    if (this.cfg.client_secret) body_params.set("client_secret", this.cfg.client_secret);
    return webhook.send({
      url: this.cfg.token_url,
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body_params.toString(),
      on_result: this.cfg.on_complete_module,
      context: Object.assign({ refresh: true }, extra_context || {}),
    });
  }
}

/**
 * OAuth 2.0 / OIDC authorization-code helper. The library owns no
 * namespace — every kv path is derived from the config. Config lives
 * at `_config/oauth/{name}` (a JSON file in your tree, mirrored
 * read-only to kv at deploy); one file per provider.
 *
 * @namespace oauth
 */
globalThis.oauth = {
  /**
   * Resolve a config and return an {@link OAuthProvider}.
   * `state_path`/`cache_path` default to `state|cache/oauth/{name}`
   * (override via config keys).
   *
   * @param {string|object} [arg] - A provider name (reads
   *   `_config/oauth/{name}`; default `"default"`) or an inline
   *   config object.
   * @returns {OAuthProvider}
   * @throws {Error} Named config not found (file not deployed).
   * @throws {TypeError} `arg` is neither string nor object.
   * @example
   * const g = oauth.fromConfig("google");
   */
  fromConfig(arg) {
    if (arg == null || typeof arg === "string") {
      const name = arg || "default";
      const raw = kv.get("_config/oauth/" + name);
      if (raw == null) {
        throw new Error("oauth.fromConfig: config not found at _config/oauth/" + name + ". Did you deploy the file?");
      }
      return new OAuthProvider(_oauthDefaults(JSON.parse(raw), name));
    }
    if (typeof arg === "object") {
      const name = arg.name || "_inline";
      return new OAuthProvider(_oauthDefaults(arg, name));
    }
    throw new TypeError("oauth.fromConfig: expected string name or inline config object");
  },

  /**
   * Verify a third-party `id_token` against the cached JWKS only
   * (synchronous — there is no sync HTTP). `jwt.*` is
   * alg-confusion-safe (RS/ES only). On a cache miss / unknown `kid`
   * the caller must run the async {@link oauth.fetchJwks} hop and
   * retry; this mirrors `oidc.rp`'s `completeToken → completeJwks →
   * _finish` chain (auth-domain-plan §4.8).
   *
   * @param {string} id_token - The compact JWS from the token
   *   endpoint response.
   * @param {object} opts - `{issuer, client_id, jwks_uri}` required;
   *   optional `nonce` (checked manually — `validateClaims` doesn't
   *   cover it), `leeway_s` (default 30), `algs` (extra allow-list on
   *   top of jwt.js's RS/ES set), `cache_path`.
   * @returns {object} One of `{ok:true, claims}` /
   *   `{ok:false, error}` (hard reject — do NOT retry) /
   *   `{ok:false, need_jwks:true, jwks_uri}` (caller does the async
   *   refetch hop, then retries).
   * @throws {TypeError} Missing `issuer`/`client_id`/`jwks_uri`.
   * @example
   * let r = oauth.verifyIdToken(tok.id_token, {
   *   issuer: "https://accounts.google.com",
   *   client_id: cfg.client_id,
   *   jwks_uri: "https://www.googleapis.com/oauth2/v3/certs",
   *   nonce: ctx.nonce, cache_path: "cache/oauth/google" });
   */
  verifyIdToken(id_token, opts) {
    if (typeof id_token !== "string" || id_token.length === 0) {
      return { ok: false, error: "missing id_token" };
    }
    if (!opts || !opts.issuer || !opts.client_id || !opts.jwks_uri) {
      throw new TypeError(
        "oauth.verifyIdToken: opts needs issuer, client_id, jwks_uri");
    }
    const cache_key =
      (opts.cache_path || "cache/oauth/_idtok") + "/jwks";
    const raw = kv.get(cache_key);
    if (raw == null) {
      return { ok: false, need_jwks: true, jwks_uri: opts.jwks_uri };
    }
    let jwks = null;
    try { jwks = JSON.parse(raw); } catch (_) { jwks = null; }
    if (!jwks || !Array.isArray(jwks.keys)) {
      return { ok: false, need_jwks: true, jwks_uri: opts.jwks_uri };
    }
    const r = _verifyWithJwks(id_token, jwks, opts);
    if (r.need_jwks) r.jwks_uri = opts.jwks_uri;
    return r;
  },

  /**
   * Kick the async JWKS fetch. `on_result` lands in a module that
   * re-runs {@link oauth.verifyIdToken} (now a cache hit) after
   * calling {@link oauth.cacheJwksFromEvent}.
   *
   * @param {object} opts - Must carry `jwks_uri`.
   * @param {string} on_result_module - Module to receive the fetch
   *   result event.
   * @param {object} [context] - Threaded back on the event (carry
   *   `id_token`, `sid`, `return_to`, …).
   * @example
   * oauth.fetchJwks(opts, "users/oauth_jwks",
   *   { id_token, sid: ctx.sid, return_to: ctx.return_to });
   */
  fetchJwks(opts, on_result_module, context) {
    webhook.send({
      url: opts.jwks_uri,
      method: "GET",
      on_result: on_result_module,
      context: context,
    });
  },

  /**
   * Cache a JWKS fetch event's body. Call from the fetch `on_result`
   * module, then re-run {@link oauth.verifyIdToken}.
   *
   * @param {object} event - The webhook.send result event
   *   (`{ok,status,body}`).
   * @param {string} [cache_path] - Same `cache_path` passed to
   *   {@link oauth.verifyIdToken}.
   * @returns {boolean} `true` when a well-formed JWKS was cached.
   */
  cacheJwksFromEvent(event, cache_path) {
    if (!event || !event.ok) return false;
    let jwks = null;
    try { jwks = JSON.parse(event.body || "{}"); } catch (_) {}
    if (!jwks || !Array.isArray(jwks.keys)) return false;
    kv.set((cache_path || "cache/oauth/_idtok") + "/jwks",
      JSON.stringify({ keys: jwks.keys, fetched_at: Date.now() }));
    return true;
  },
};

// Verify `id_token` against an in-hand JWKS. "No matching kid" is a
// stale-cache signal (→ refetch), NOT a forgery — correct during IdP
// key rotation, matching oidc.rp / §4.6 controlled-RP behavior.
function _verifyWithJwks(id_token, jwks, opts) {
  let v;
  try { v = jwt.verify(id_token, jwks); }
  catch (e) {
    const msg = String(e && e.message);
    if (msg.indexOf("no key") !== -1) return { ok: false, need_jwks: true };
    return { ok: false, error: "verify: " + msg };
  }
  if (!v.valid) return { ok: false, error: "bad signature" };
  if (opts.algs && opts.algs.indexOf(v.header.alg) === -1) {
    return { ok: false, error: "alg not allowed: " + v.header.alg };
  }
  const claim_err = jwt.validateClaims(v.payload, {
    iss: opts.issuer,
    aud: opts.client_id,
    leeway_s: opts.leeway_s != null ? opts.leeway_s : 30,
  });
  if (claim_err) return { ok: false, error: "id_token " + claim_err };
  if (opts.nonce != null && v.payload.nonce !== opts.nonce) {
    return { ok: false, error: "nonce mismatch" };
  }
  return { ok: true, claims: v.payload };
}

function _oauthDefaults(cfg, name) {
  return Object.assign({}, cfg, {
    state_path: cfg.state_path || ("state/oauth/" + name),
    cache_path: cfg.cache_path || ("cache/oauth/" + name),
  });
}
