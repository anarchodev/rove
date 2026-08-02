// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// @rewind/oauth — OAuth 2.0 + OIDC authorization-code flow helper
// (P-Lift, rove#123). The lifted form of the former ambient
// `globalThis.oauth` (was `src/js/globals/oauth.js`).
//
// The library is a pure transformer over its config: it owns no namespace,
// every kv path it touches is derived from (or specified in) the config row
// at `_config/oauth/{name}`. It composes over the ambient primitives
// (`crypto`/`base64url`/`kv`/`webhook`/`request`/`response`/`URLSearchParams`,
// which stay baked) AND over the `@rewind/jwt` PACKAGE — the first real
// intra-set package dependency. `jwt` is imported (not ambient) so the
// resolver freezes the exact jwt version oauth was published against
// (encapsulation).
import jwt from "@rewind/jwt";

/**
 * An OAuth 2.0 / OIDC authorization-code client bound to one provider config.
 * Obtain via {@link fromConfig}. PKCE is on unless `pkce:false`.
 * @class OAuthProvider
 */
class OAuthProvider {
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

  startLogin(opts) {
    opts = opts || {};
    const state = crypto.randomUUID();

    let verifier = null;
    let challenge = null;
    if (this.cfg.pkce) {
      const verifier_bytes = new Uint8Array(32);
      crypto.getRandomValues(verifier_bytes);
      verifier = base64url.encode(verifier_bytes);
      challenge = crypto.sha256b64url(verifier);
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

    webhook.send(this.cfg.token_url, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body_params.toString(),
      on: this.cfg.on_complete_module,
      ctx: Object.assign({}, stored.context, {
        return_to: stored.return_to,
      }),
    });

    response.status = 202;
    response.headers = { "content-type": "text/html; charset=utf-8" };
    return "<!doctype html><meta charset=utf-8><title>Signing in…</title><p>Completing sign-in…</p>";
  }

  refresh(refresh_token, extra_context) {
    const body_params = new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token,
      client_id: this.cfg.client_id,
    });
    if (this.cfg.client_secret) body_params.set("client_secret", this.cfg.client_secret);
    return webhook.send(this.cfg.token_url, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body_params.toString(),
      on: this.cfg.on_complete_module,
      ctx: Object.assign({ refresh: true }, extra_context || {}),
    });
  }
}

/**
 * Resolve a config and return an {@link OAuthProvider}. `arg` is a provider
 * name (reads `_config/oauth/{name}`; default `"default"`) or an inline config.
 */
export function fromConfig(arg) {
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
}

/**
 * Verify a third-party `id_token` against the cached JWKS only (synchronous).
 * Returns `{ok:true, claims}` / `{ok:false, error}` (hard reject) /
 * `{ok:false, need_jwks:true, jwks_uri}` (caller does the async refetch hop).
 */
export function verifyIdToken(id_token, opts) {
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
}

/** Kick the async JWKS fetch; the result lands in the `{on}` module. */
export function fetchJwks(opts, on, ctx) {
  webhook.send(opts.jwks_uri, {
    method: "GET",
    on: on,
    ctx: ctx,
  });
}

/**
 * Cache the JWKS delivered to the {@link fetchJwks} `{on}` module. Reads the
 * ambient result (`request.status` / `request.text`). Returns `true` when a
 * well-formed JWKS was cached.
 */
export function cacheJwks(cache_path) {
  const req = globalThis.request;
  if (!req || !(req.status >= 200 && req.status < 300)) return false;
  let jwks = null;
  try { jwks = JSON.parse(req.text || "{}"); } catch (_) {}
  if (!jwks || !Array.isArray(jwks.keys)) return false;
  kv.set((cache_path || "cache/oauth/_idtok") + "/jwks",
    JSON.stringify({ keys: jwks.keys, fetched_at: Date.now() }));
  return true;
}

// Verify `id_token` against an in-hand JWKS via the `@rewind/jwt` package.
// "No matching kid" is a stale-cache signal (→ refetch), NOT a forgery.
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
    leewaySeconds: opts.leewaySeconds != null ? opts.leewaySeconds : 30,
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

const oauth = { fromConfig, verifyIdToken, fetchJwks, cacheJwks };
export default oauth;
