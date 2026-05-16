// @rove/oidc — OIDC authorization-code + PKCE *provider* (the
// issuance analog of oauth.js's client helper). Dogfooded: the
// platform's own __auth__ IdP runs this exact library; customers can
// run their own IdP with it (auth-domain-plan.md §4).
//
// §0 invariant: `iss` and every endpoint are derived from
// `request.host` — NO compiled-in domain. The same deployment serves
// dev/staging/prod/custom-domain issuers identically.
//
// Config at `_config/oidc/{name}` (JSON, deployed file mirrored to
// kv, exactly like oauth.js's `_config/oauth/{name}`):
//
//   { "clients": [ { "client_id": "admin-dashboard",
//                     "redirect_uris": ["https://app.rewindjs.com/_rp/cb"] } ],
//     "login_path": "/login" }          // IdP's own magic-link UI
//
// The customer's web/auth/index.mjs does:
//   export default function () { return oidc.provider().handle(); }
// plus its magic-link login routes, which bind the per-request sid to
// a user: kv.set("_oidc/session/" + request.session.id,
//                 JSON.stringify({ sub, auth_time }))  // §4.7
//
// v1 scope (§4.5): discovery, JWKS, authorization-code, mandatory
// PKCE (S256 only), id/access/refresh, RS256. No implicit flow, no
// dynamic registration, no consent screen, no client_secret
// (first-party public clients), no userinfo.

const _OIDC_SECONDS = (ms) => Math.floor(ms / 1000);

function _b64urlRandom(n) {
  const b = new Uint8Array(n);
  crypto.getRandomValues(b);
  return base64url.encode(b);
}

// S256: base64url(SHA-256(ascii(verifier))). crypto.sha256 returns
// hex; reuse oauth.js's hex.decode bridge.
function _s256(verifier) {
  return base64url.encode(hex.decode(crypto.sha256(verifier)));
}

class OIDCProvider {
  constructor(config, name) {
    this.cfg = {
      clients: Array.isArray(config.clients) ? config.clients : [],
      login_path: config.login_path || "/login",
      // kv layout — overridable, defaults namespaced by config name.
      session_path: config.session_path || "_oidc/session",
      keyset_path: config.keyset_path || ("_oidc/keyset/" + name),
      code_path: config.code_path || ("_oidc/code/" + name),
      at_path: config.at_path || ("_oidc/at/" + name),
      rt_path: config.rt_path || ("_oidc/rt/" + name),
      code_ttl_ms: config.code_ttl_ms || 60 * 1000,
      id_token_ttl_ms: config.id_token_ttl_ms || 15 * 60 * 1000, // §4.6
      refresh_ttl_ms: config.refresh_ttl_ms || 30 * 24 * 60 * 60 * 1000,
    };
  }

  _iss() {
    // §0: host-relative, never a literal.
    return "https://" + request.host;
  }

  _client(client_id) {
    for (const c of this.cfg.clients) {
      if (c.client_id === client_id) return c;
    }
    return null;
  }

  // ── keyset (§4.6; full rotation state machine is wired in 3-5,
  //    here: lazy genesis + read current + publish public JWKs) ──
  _keyset() {
    const raw = kv.get(this.cfg.keyset_path);
    if (raw != null) return JSON.parse(raw);
    // Genesis: first request to a fresh issuer mints one `current`
    // key. Signing it immediately is safe — no prior key, so no
    // stale RP JWKS cache to contradict (§4.6).
    const k = crypto.oidcGenerateKey(); // { priv, jwk, kid }
    const keyset = {
      min_iat: 0, // emergency-revocation floor (§4.6)
      keys: [{
        kid: k.kid, status: "current", priv: k.priv, jwk: k.jwk,
        created_ns: Date.now() * 1e6,
      }],
    };
    kv.set(this.cfg.keyset_path, JSON.stringify(keyset));
    return keyset;
  }

  _currentKey(keyset) {
    for (const e of keyset.keys) if (e.status === "current") return e;
    return null;
  }

  handle() {
    const path = (request.path || "").split("?")[0];
    const m = request.method;
    if (m === "GET" && path === "/.well-known/openid-configuration") {
      return this._discovery();
    }
    if (m === "GET" && path === "/.well-known/jwks.json") {
      return this._jwks();
    }
    if (m === "GET" && path === "/authorize") {
      return this._authorize();
    }
    if (m === "POST" && path === "/token") {
      return this._token();
    }
    response.status = 404;
    return "not found";
  }

  _json(obj, status) {
    response.status = status || 200;
    response.headers = { "content-type": "application/json" };
    return JSON.stringify(obj);
  }

  _discovery() {
    const iss = this._iss();
    return this._json({
      issuer: iss,
      authorization_endpoint: iss + "/authorize",
      token_endpoint: iss + "/token",
      jwks_uri: iss + "/.well-known/jwks.json",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"],
      code_challenge_methods_supported: ["S256"],
      scopes_supported: ["openid"],
      token_endpoint_auth_methods_supported: ["none"],
    });
  }

  _jwks() {
    const ks = this._keyset();
    const keys = [];
    for (const e of ks.keys) {
      if (e.status === "retired") continue; // never publish retired
      // Publish the PUBLIC jwk only — priv never leaves kv/Zig.
      keys.push({
        kty: e.jwk.kty, alg: e.jwk.alg, use: e.jwk.use,
        kid: e.kid, n: e.jwk.n, e: e.jwk.e,
      });
    }
    // RPs cache this; the §4.6 publish/retire windows assume a
    // bounded TTL.
    response.headers = {
      "content-type": "application/json",
      "cache-control": "public, max-age=600",
    };
    response.status = 200;
    return JSON.stringify({ keys });
  }

  // Redirect back to the RP with an OAuth2 error — ONLY after
  // redirect_uri has been validated (never to an unvalidated uri).
  _redirErr(redirect_uri, state, code, desc) {
    const p = new URLSearchParams({ error: code });
    if (desc) p.set("error_description", desc);
    if (state) p.set("state", state);
    response.status = 302;
    response.headers = { location: redirect_uri + "?" + p.toString() };
    return null;
  }

  _authorize() {
    const q = new URLSearchParams(request.query || "");
    const client_id = q.get("client_id");
    const redirect_uri = q.get("redirect_uri");
    const response_type = q.get("response_type");
    const scope = q.get("scope") || "";
    const state = q.get("state");
    const code_challenge = q.get("code_challenge");
    const ccm = q.get("code_challenge_method");
    const nonce = q.get("nonce");

    // Validate client + redirect_uri FIRST, exact-match, no
    // redirect on failure (open-redirect / mix-up defense).
    const client = this._client(client_id);
    if (!client) {
      response.status = 400;
      return "invalid_request: unknown client_id";
    }
    const uris = Array.isArray(client.redirect_uris) ? client.redirect_uris : [];
    if (!redirect_uri || uris.indexOf(redirect_uri) === -1) {
      response.status = 400;
      return "invalid_request: redirect_uri not registered for this client";
    }
    // From here, errors redirect to the (validated) redirect_uri.
    if (response_type !== "code") {
      return this._redirErr(redirect_uri, state, "unsupported_response_type",
        "only response_type=code is supported");
    }
    if (scope.split(" ").indexOf("openid") === -1) {
      return this._redirErr(redirect_uri, state, "invalid_scope",
        "the openid scope is required");
    }
    // PKCE mandatory, S256 only (no `plain` — downgrade defense).
    if (!code_challenge || ccm !== "S256") {
      return this._redirErr(redirect_uri, state, "invalid_request",
        "PKCE with code_challenge_method=S256 is required");
    }

    // The human must be authenticated TO THIS IdP (§4.7): the
    // magic-link step bound the per-request sid → user in kv. No
    // session ⇒ bounce to the IdP's own login UI, returning here.
    const sid = request.session && request.session.id;
    const sess_raw = sid ? kv.get(this.cfg.session_path + "/" + sid) : null;
    if (sess_raw == null) {
      const here = this._iss() + "/authorize?" + q.toString();
      response.status = 302;
      response.headers = {
        location: this.cfg.login_path + "?return_to=" + encodeURIComponent(here),
      };
      return null;
    }
    const sess = JSON.parse(sess_raw);

    // Mint a single-use authorization code bound to everything the
    // token endpoint must re-check.
    const code = _b64urlRandom(32);
    kv.set(this.cfg.code_path + "/" + code, JSON.stringify({
      client_id,
      redirect_uri,
      code_challenge,
      nonce: nonce || null,
      sub: sess.sub,
      auth_time: sess.auth_time || _OIDC_SECONDS(Date.now()),
      scope,
      exp: Date.now() + this.cfg.code_ttl_ms,
    }));

    const p = new URLSearchParams({ code });
    if (state) p.set("state", state);
    response.status = 302;
    response.headers = { location: redirect_uri + "?" + p.toString() };
    return null;
  }

  _tokenErr(code, desc) {
    return this._json({ error: code, error_description: desc || "" }, 400);
  }

  _signIdToken(keyset, claims) {
    const cur = this._currentKey(keyset);
    if (!cur) throw new Error("oidc: no current signing key");
    const header = { alg: "RS256", typ: "JWT", kid: cur.kid };
    const enc = (o) =>
      base64url.encode(new TextEncoder().encode(JSON.stringify(o)));
    const signing_input = enc(header) + "." + enc(claims);
    const sig = crypto.oidcSign(cur.priv, signing_input); // RS256, Zig
    return signing_input + "." + sig;
  }

  _issueTokens(keyset, client_id, sub, scope, nonce, auth_time) {
    const now = _OIDC_SECONDS(Date.now());
    const id_token = this._signIdToken(keyset, {
      iss: this._iss(),
      sub,
      aud: client_id,
      iat: now,
      exp: now + _OIDC_SECONDS(this.cfg.id_token_ttl_ms),
      auth_time,
      nonce: nonce || undefined,
    });
    // Opaque access + refresh tokens, kv-stored (§4.6: opaque
    // refresh bounds the retired-key window + allows hard revoke).
    const at = _b64urlRandom(32);
    kv.set(this.cfg.at_path + "/" + at, JSON.stringify({
      sub, client_id, scope, exp: Date.now() + this.cfg.id_token_ttl_ms,
    }));
    const rt = _b64urlRandom(32);
    kv.set(this.cfg.rt_path + "/" + rt, JSON.stringify({
      sub, client_id, scope, nonce: nonce || null, auth_time,
      iat: Date.now(), exp: Date.now() + this.cfg.refresh_ttl_ms,
    }));
    return this._json({
      access_token: at,
      token_type: "Bearer",
      expires_in: _OIDC_SECONDS(this.cfg.id_token_ttl_ms),
      id_token,
      refresh_token: rt,
      scope,
    });
  }

  _token() {
    const f = new URLSearchParams(request.body || "");
    const grant = f.get("grant_type");
    const keyset = this._keyset();

    if (grant === "authorization_code") {
      const code = f.get("code");
      const redirect_uri = f.get("redirect_uri");
      const client_id = f.get("client_id");
      const verifier = f.get("code_verifier");
      if (!code) return this._tokenErr("invalid_request", "missing code");

      const key = this.cfg.code_path + "/" + code;
      const raw = kv.get(key);
      // Single-use: consume before any check so a replay can't race.
      kv.delete(key);
      if (raw == null) return this._tokenErr("invalid_grant", "unknown or used code");
      const st = JSON.parse(raw);
      if (Date.now() > st.exp) return this._tokenErr("invalid_grant", "code expired");
      if (st.client_id !== client_id) {
        return this._tokenErr("invalid_grant", "client_id mismatch");
      }
      if (st.redirect_uri !== redirect_uri) {
        return this._tokenErr("invalid_grant", "redirect_uri mismatch");
      }
      // PKCE: the verifier must hash to the stored challenge.
      if (!verifier || _s256(verifier) !== st.code_challenge) {
        return this._tokenErr("invalid_grant", "PKCE verification failed");
      }
      return this._issueTokens(
        keyset, st.client_id, st.sub, st.scope, st.nonce, st.auth_time);
    }

    if (grant === "refresh_token") {
      const rt = f.get("refresh_token");
      const client_id = f.get("client_id");
      if (!rt) return this._tokenErr("invalid_request", "missing refresh_token");
      const key = this.cfg.rt_path + "/" + rt;
      const raw = kv.get(key);
      kv.delete(key); // rotate refresh tokens (single-use)
      if (raw == null) return this._tokenErr("invalid_grant", "unknown refresh_token");
      const st = JSON.parse(raw);
      if (Date.now() > st.exp) return this._tokenErr("invalid_grant", "refresh_token expired");
      if (st.client_id !== client_id) {
        return this._tokenErr("invalid_grant", "client_id mismatch");
      }
      // §4.6 emergency revocation: tokens issued before min_iat die.
      if (keyset.min_iat && st.iat < keyset.min_iat) {
        return this._tokenErr("invalid_grant", "refresh_token revoked");
      }
      return this._issueTokens(
        keyset, st.client_id, st.sub, st.scope, st.nonce, st.auth_time);
    }

    return this._tokenErr("unsupported_grant_type", String(grant));
  }
}

globalThis.oidc = {
  // oidc.provider("name") → reads `_config/oidc/name`
  // oidc.provider()       → `_config/oidc/default`
  // oidc.provider({...})  → inline config object
  provider(arg) {
    if (arg == null || typeof arg === "string") {
      const name = arg || "default";
      const raw = kv.get("_config/oidc/" + name);
      if (raw == null) {
        throw new Error(
          "oidc.provider: config not found at _config/oidc/" + name +
          ". Did you deploy the file?");
      }
      return new OIDCProvider(JSON.parse(raw), name);
    }
    if (typeof arg === "object") {
      return new OIDCProvider(arg, arg.name || "_inline");
    }
    throw new TypeError("oidc.provider: expected string name or config object");
  },
};
