// @rove/oidc — OIDC authorization-code + PKCE *provider* (the
// issuance analog of oauth.js's client helper). Dogfooded: the
// platform's own __auth__ IdP runs this exact library; customers can
// run their own IdP with it (auth-domain-plan.md §4).
//
// §0 invariant: `iss` and every endpoint are derived from
// `request.host` — NO compiled-in domain. The same deployment serves
// dev/staging/prod/custom-domain issuers identically.
//
// Client registry at `_oidc/config/{name}` (JSON, a normal kv key —
// NOT the reserved `_config/` prefix; see provider() for why). It's
// operational data: operators register/rotate RP clients via admin
// (X-Rove-Scope: __auth__) without a redeploy:
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
      // §4.6 rotation windows (per-issuer configurable; conservative
      // defaults — the conformance smoke shrinks them).
      rotation_period_ms: config.rotation_period_ms || 90 * 24 * 60 * 60 * 1000,
      publish_window_ms: config.publish_window_ms || 24 * 60 * 60 * 1000,
      retire_window_ms: config.retire_window_ms ||
        ((config.id_token_ttl_ms || 15 * 60 * 1000) + 5 * 60 * 1000),
      rot_handle: "oidc-rot/" + name, // stable → http.send overwrite
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

  // ── keyset (§4.6 state machine: next → current → retiring → drop).
  //    Single kv key ⇒ raft serializes writes last-write-wins; we
  //    only ever SIGN with `current`; the re-arm uses a stable
  //    http.send handle — together that makes a concurrent
  //    leadership double-fire dedup-safe with no schedule-version
  //    header (see §4.6 "Grounded correction 2026-05-16"). ──
  _keyset() {
    const raw = kv.get(this.cfg.keyset_path);
    if (raw != null) return JSON.parse(raw);
    // Genesis: first request to a fresh issuer mints one `current`
    // key. Safe to sign immediately — no prior key, no stale RP
    // JWKS cache to contradict (§4.6). Capture the issuer host NOW
    // (genesis always runs on a real wire request; the internal
    // rotate fire has request.host === "").
    const now = Date.now();
    const k = crypto.oidcGenerateKey(); // { priv, jwk, kid }
    const keyset = {
      min_iat: 0, // emergency-revocation floor (§4.6)
      issuer_host: request.host || "",
      keys: [{
        kid: k.kid, status: "current", priv: k.priv, jwk: k.jwk,
        since: now,
      }],
    };
    kv.set(this.cfg.keyset_path, JSON.stringify(keyset));
    // Arm the first scheduled rotation (only if we know our host).
    if (keyset.issuer_host) {
      this._armRotation(keyset.issuer_host, now + this.cfg.rotation_period_ms);
    }
    return keyset;
  }

  _currentKey(keyset) {
    for (const e of keyset.keys) if (e.status === "current") return e;
    return null;
  }

  // Self-scheduled rotation tick (§4.6 / http-send-plan §10.5
  // order-timeout pattern): stable handle ⇒ a re-arm overwrites the
  // prior row; the issuer host can't come from request.host on the
  // internal fire so it's threaded explicitly.
  _armRotation(host, fire_at_ms) {
    http.send({
      handle: this.cfg.rot_handle,
      url: "https://" + host + "/_oidc/rotate",
      method: "POST",
      body: "",
      fire_at_ns: BigInt(Math.floor(fire_at_ms)) * 1000000n,
    });
  }

  // Pure-ish deadline-gated state machine. Loops so a long-overdue
  // fire converges (catches up multiple transitions). Returns the
  // soonest future deadline (ms) to re-arm at.
  _advance(keyset, now) {
    const cfg = this.cfg;
    for (;;) {
      let nextK = null, curK = null;
      const retiring = [];
      for (const e of keyset.keys) {
        if (e.status === "next") nextK = e;
        else if (e.status === "current") curK = e;
        else if (e.status === "retiring") retiring.push(e);
      }
      // Drop fully-retired keys (no token signed by them can still
      // be live: retire_window ≥ id_token TTL + skew).
      const live = keyset.keys.filter((e) =>
        !(e.status === "retiring" && now - e.since >= cfg.retire_window_ms));
      if (live.length !== keyset.keys.length) {
        keyset.keys = live;
        continue;
      }
      // current aged out and no next yet → mint next (published in
      // JWKS immediately; NOT signed with until promoted).
      if (curK && !nextK && now - curK.since >= cfg.rotation_period_ms) {
        const k = crypto.oidcGenerateKey();
        keyset.keys.push({
          kid: k.kid, status: "next", priv: k.priv, jwk: k.jwk, since: now,
        });
        continue;
      }
      // next published long enough → promote (current → retiring).
      if (nextK && now - nextK.since >= cfg.publish_window_ms) {
        if (curK) { curK.status = "retiring"; curK.since = now; }
        nextK.status = "current"; nextK.since = now;
        continue;
      }
      // No transition fired → compute the soonest upcoming deadline.
      let soonest = now + cfg.rotation_period_ms;
      if (curK && !nextK) {
        soonest = Math.min(soonest, curK.since + cfg.rotation_period_ms);
      }
      if (nextK) {
        soonest = Math.min(soonest, nextK.since + cfg.publish_window_ms);
      }
      for (const r of retiring) {
        soonest = Math.min(soonest, r.since + cfg.retire_window_ms);
      }
      return soonest;
    }
  }

  // POST /_oidc/rotate — the scheduled fire. Deadline-gated + single
  // kv key (last-write-wins) ⇒ a concurrent leadership double-fire
  // is safe with no header dedupe (§4.6 grounded correction). kv.set
  // + the http.send re-arm commit atomically (http-send-plan §6).
  handleRotate() {
    const keyset = this._keyset(); // genesis if somehow absent
    const host = keyset.issuer_host;
    const now = Date.now();
    const next_deadline = this._advance(keyset, now);
    kv.set(this.cfg.keyset_path, JSON.stringify(keyset));
    if (host) this._armRotation(host, next_deadline);
    response.status = 200;
    response.headers = { "content-type": "application/json" };
    return JSON.stringify({ ok: true, keys: keyset.keys.length });
  }

  // Emergency rotation (§4.6 distinct path): mint a fresh `current`,
  // drop ALL prior keys immediately (skip the publish/retire
  // windows — accept that tokens signed by the old key stop
  // verifying), and bump `min_iat` so every refresh token / session
  // older than now is rejected. Operator-triggered; intentionally
  // NOT exposed as an unauthenticated route — the trigger lands with
  // the admin/operator surface in step 3-6.
  _emergencyRotate(keyset, now, host) {
    const k = crypto.oidcGenerateKey();
    keyset.keys = [{
      kid: k.kid, status: "current", priv: k.priv, jwk: k.jwk, since: now,
    }];
    keyset.min_iat = Math.floor(now / 1000);
    kv.set(this.cfg.keyset_path, JSON.stringify(keyset));
    if (host) this._armRotation(host, now + this.cfg.rotation_period_ms);
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
    // Internal-routed scheduled key-rotation tick (§4.6). Reached
    // only via the in-cluster http.send self-fire; an external POST
    // here is benign — _advance is deadline-gated, so it can't force
    // a premature rotation (worst case: a no-op extra tick).
    if (m === "POST" && path === "/_oidc/rotate") {
      return this.handleRotate();
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

// ── OIDC Relying Party (the client analog of OIDCProvider) ──────────
//
// `oidc.rp()` is to `oidc.provider()` what `oauth.js` is to a generic
// OAuth2 server: the dogfooded client. The platform's own admin
// dashboard uses it (auth-domain-plan §4.7 "3-6 part 2"); customers
// and the future replay/logs RPs reuse the same code.
//
// Grounded constraints this shape encodes (auth-domain-plan §4.7
// "Grounded correction 2026-05-16"):
//   - `on_result` modules run platform-driven in dispatchCallbacks
//     with a SYNTHESIZED request: no browser response (can't set a
//     cookie / 302), and crucially NO `request.session`. So the
//     session anchor (`sid`) is captured on the real browser request
//     in beginLogin and threaded through state → http.send context →
//     the completion modules. The RP session binds to the platform's
//     already-host-only `__Host-rove_sid` via `_rp/sess/{sid}` —
//     the session.zig "bind the sid to your user in your own kv"
//     model that web/auth/index.mjs itself uses (no new cookie).
//   - Token exchange + JWKS verify are TWO async http.send hops; the
//     browser sits on a poll page until `_rp/sess/{sid}` lands.
//
// Config at `_oidc/rp/{name}` (a normal kv key — operational, like
// the provider's `_oidc/config/*`):
//   { "issuer":      "https://auth.rewindjs.com",  // the IdP host
//     "client_id":   "admin-dashboard",
//     "redirect_uri":"https://app.rewindjs.com/_rp/callback",
//     "post_login":  "/",                  // default return_to
//     "operator_prefix": "_admin/operator/" }  // is_root allowlist
// `issuer`/`redirect_uri` are config, NOT compiled-in literals — §0
// is about no *platform* literal in library code; per-deploy config
// is the §0-compliant carrier (same as oidc.provider's issuer host).
class OIDCRelyingParty {
  constructor(config, name) {
    if (!config.issuer || !config.client_id || !config.redirect_uri) {
      throw new TypeError(
        "oidc.rp: config needs issuer, client_id, redirect_uri");
    }
    this.cfg = {
      issuer: config.issuer.replace(/\/+$/, ""), // no trailing slash
      client_id: config.client_id,
      redirect_uri: config.redirect_uri,
      post_login: config.post_login || "/",
      // Empty ⇒ no email is ever operator (is_root always false).
      operator_prefix: config.operator_prefix || "",
      state_path: config.state_path || ("_rp/state/" + name),
      sess_path: config.sess_path || "_rp/sess",
      jwks_path: config.jwks_path || ("_rp/jwks/" + name),
      complete_module: config.complete_module || "_rp/complete",
      jwks_module: config.jwks_module || "_rp/jwks",
      state_ttl_ms: config.state_ttl_ms || 10 * 60 * 1000,
      session_ttl_ms: config.session_ttl_ms || 7 * 24 * 60 * 60 * 1000,
      // jwt.validateClaims clock-skew tolerance.
      leeway_s: config.leeway_s != null ? config.leeway_s : 30,
    };
  }

  // return_to must be a same-origin absolute PATH (open-redirect
  // defense — the login is otherwise an attacker-aimable redirector).
  // Reject protocol-relative `//evil` and anything not starting `/`.
  _safePath(p) {
    if (typeof p === "string" && p.length > 0 && p[0] === "/" &&
        !(p.length > 1 && p[1] === "/")) {
      return p;
    }
    return this.cfg.post_login;
  }

  // GET /_rp/login — capture the platform sid HERE (real browser
  // request; the on_result completion has none), stash PKCE state,
  // 302 to the IdP /authorize.
  beginLogin() {
    const sid = request.session && request.session.id;
    if (!sid) {
      response.status = 400;
      return "no session context";
    }
    const q = new URLSearchParams(request.query || "");
    const return_to = this._safePath(q.get("return_to"));

    const state = _b64urlRandom(32);
    const verifier = _b64urlRandom(32);
    const challenge = _s256(verifier);

    kv.set(this.cfg.state_path + "/" + state, JSON.stringify({
      verifier, sid, return_to, created_at: Date.now(),
    }));

    const p = new URLSearchParams({
      client_id: this.cfg.client_id,
      redirect_uri: this.cfg.redirect_uri,
      response_type: "code",
      scope: "openid",
      state,
      code_challenge: challenge,
      code_challenge_method: "S256",
    });
    response.status = 302;
    response.headers = {
      location: this.cfg.issuer + "/authorize?" + p.toString(),
    };
    return null;
  }

  // The "Signing in…" page: polls /_rp/poll until the background
  // completion chain has written `_rp/sess/{sid}`, then navigates to
  // the (already same-origin-validated) return_to. return_to is
  // embedded server-side, escaped — never echoed into an attribute.
  _pollPage(return_to) {
    response.status = 202;
    response.headers = { "content-type": "text/html; charset=utf-8" };
    const rt = JSON.stringify(return_to); // safe JS string literal
    return "<!doctype html><meta charset=utf-8><title>Signing in…</title>" +
      "<p>Completing sign-in…</p><script>" +
      "var rt=" + rt + ";" +
      "function p(){fetch('/_rp/poll',{credentials:'same-origin'})" +
      ".then(function(r){return r.json()}).then(function(j){" +
      "if(j&&j.authed){location.replace(rt)}else{setTimeout(p,600)}})" +
      ".catch(function(){setTimeout(p,1200)})}p();</script>";
  }

  // GET /_rp/callback?code&state — validate+consume state, kick the
  // async token exchange, park the browser on the poll page.
  handleCallback() {
    const q = new URLSearchParams(request.query || "");
    const state = q.get("state");
    const code = q.get("code");
    const err = q.get("error");
    if (err) {
      response.status = 400;
      return "sign-in failed at identity provider: " + err;
    }
    if (!state || !code) {
      response.status = 400;
      return "missing code or state";
    }
    const skey = this.cfg.state_path + "/" + state;
    const raw = kv.get(skey);
    kv.delete(skey); // single-use: consume before any check
    if (raw == null) {
      response.status = 400;
      return "unknown or used sign-in state";
    }
    const st = JSON.parse(raw);
    if (Date.now() - st.created_at > this.cfg.state_ttl_ms) {
      response.status = 400;
      return "sign-in state expired";
    }

    const body = new URLSearchParams({
      grant_type: "authorization_code",
      code,
      redirect_uri: this.cfg.redirect_uri,
      client_id: this.cfg.client_id,
      code_verifier: st.verifier,
    });
    http.send({
      url: this.cfg.issuer + "/token",
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body.toString(),
      on_result: {
        module: this.cfg.complete_module,
        context: { sid: st.sid, return_to: st.return_to },
      },
    });
    return this._pollPage(st.return_to);
  }

  // The callback event the on_result modules receive (synthesized
  // request, body = the http-send-plan §8 event).
  _event() {
    try { return JSON.parse(request.body || "{}"); } catch (_) { return {}; }
  }

  // on_result of the /token send. We have the id_token but need the
  // IdP JWKS to verify it. Verify synchronously if the signing kid
  // is already cached; otherwise refetch JWKS (the §4.6-mandated
  // controlled-RP unknown-kid refetch) and finish in completeJwks.
  completeToken() {
    const ev = this._event();
    const ctx = ev.context || {};
    if (!ev.ok) {
      // Token exchange failed; nothing to do — the poll page keeps
      // polling and the user can retry login. Log via response body
      // (callback responses are dropped, but tape/logs capture it).
      response.status = 200;
      return "token exchange failed: " + (ev.status || "?");
    }
    let tok = null;
    try { tok = JSON.parse(ev.body || "{}"); } catch (_) {}
    const id_token = tok && tok.id_token;
    if (!id_token) { response.status = 200; return "no id_token"; }

    const dec = jwt.decode(id_token);
    if (!dec) { response.status = 200; return "malformed id_token"; }

    const cachedRaw = kv.get(this.cfg.jwks_path);
    if (cachedRaw != null) {
      const cached = JSON.parse(cachedRaw);
      const kid = dec.header && dec.header.kid;
      const have = (cached.keys || []).some((k) => k.kid === kid);
      if (have) {
        return this._finish(id_token, cached, ctx.sid, ctx.return_to);
      }
    }
    // Unknown/absent kid → refetch JWKS, finish in completeJwks.
    http.send({
      url: this.cfg.issuer + "/.well-known/jwks.json",
      method: "GET",
      on_result: {
        module: this.cfg.jwks_module,
        context: {
          sid: ctx.sid, return_to: ctx.return_to, id_token,
        },
      },
    });
    response.status = 200;
    return "fetching jwks";
  }

  // on_result of the JWKS fetch: cache it, then verify + mint.
  completeJwks() {
    const ev = this._event();
    const ctx = ev.context || {};
    if (!ev.ok) { response.status = 200; return "jwks fetch failed"; }
    let jwks = null;
    try { jwks = JSON.parse(ev.body || "{}"); } catch (_) {}
    if (!jwks || !Array.isArray(jwks.keys)) {
      response.status = 200;
      return "malformed jwks";
    }
    kv.set(this.cfg.jwks_path, JSON.stringify({
      keys: jwks.keys, fetched_at: Date.now(),
    }));
    return this._finish(ctx.id_token, jwks, ctx.sid, ctx.return_to);
  }

  // Cryptographic verify + claim validation + session mint. Runs in
  // a background callback (no browser response) — it ONLY writes
  // `_rp/sess/{sid}`; the poll page picks the session up.
  _finish(id_token, jwks, sid, return_to) {
    if (!id_token || !sid) { response.status = 200; return "missing inputs"; }
    let v = null;
    try { v = jwt.verify(id_token, jwks); }
    catch (_) { response.status = 200; return "verify error"; }
    if (!v.valid) { response.status = 200; return "bad id_token signature"; }
    const claim_err = jwt.validateClaims(v.payload, {
      iss: this.cfg.issuer,
      aud: this.cfg.client_id,
      leeway_s: this.cfg.leeway_s,
    });
    if (claim_err) { response.status = 200; return "id_token " + claim_err; }

    const sub = v.payload.sub;
    if (!sub) { response.status = 200; return "id_token has no sub"; }

    // is_root iff the verified subject is on the operator allowlist.
    // Empty operator_prefix ⇒ never root (safe default for non-admin
    // RPs that have no operator concept).
    let is_root = false;
    if (this.cfg.operator_prefix) {
      is_root = kv.get(this.cfg.operator_prefix + crypto.sha256(sub)) != null;
    }
    kv.set(this.cfg.sess_path + "/" + sid, JSON.stringify({
      sub, is_root,
      exp: Date.now() + this.cfg.session_ttl_ms,
    }));
    response.status = 200;
    return "ok";
  }

  // Called from `_middlewares/index.mjs`: returns the auth payload
  // for this request's sid, or null. Expired rows are swept.
  guard() {
    const sid = request.session && request.session.id;
    if (!sid) return null;
    const key = this.cfg.sess_path + "/" + sid;
    const raw = kv.get(key);
    if (raw == null) return null;
    let s = null;
    try { s = JSON.parse(raw); } catch (_) {}
    if (!s) { kv.delete(key); return null; }
    if (Date.now() >= s.exp) { kv.delete(key); return null; }
    return { sub: s.sub, is_root: !!s.is_root };
  }

  // GET /_rp/poll — the poll page asks "am I signed in yet?".
  pollStatus() {
    const a = this.guard();
    response.status = 200;
    response.headers = { "content-type": "application/json" };
    return JSON.stringify({ authed: !!a });
  }

  // POST /_rp/logout — drop this sid's RP session. The IdP session
  // is the IdP's own concern (v1: no front/back-channel logout, §4.5).
  logout() {
    const sid = request.session && request.session.id;
    if (sid) kv.delete(this.cfg.sess_path + "/" + sid);
    response.status = 200;
    response.headers = { "content-type": "application/json" };
    return JSON.stringify({ ok: true });
  }
}

globalThis.oidc = {
  // oidc.provider("name") → reads `_oidc/config/name`
  // oidc.provider()       → `_oidc/config/default`
  // oidc.provider({...})  → inline config object
  //
  // The client registry lives at `_oidc/config/{name}` — a normal
  // (non-reserved) kv key, NOT `_config/oidc/*`. Grounded reasons
  // (auth-domain-plan §4.7 correction): `_config/` is a
  // platform-reserved prefix handlers/admin can't write, and its
  // only writer (`config_mirror` via `loop46 seed`) is not wired
  // into the files-server release/loader path anyway (same gap
  // affects oauth.js). And a client registry is *operational* data —
  // operators add/remove RP clients without a redeploy — so an
  // admin-managed kv key is the more correct model than a
  // deploy-mirrored static file.
  provider(arg) {
    if (arg == null || typeof arg === "string") {
      const name = arg || "default";
      const raw = kv.get("_oidc/config/" + name);
      if (raw == null) {
        throw new Error(
          "oidc.provider: no client registry at _oidc/config/" + name +
          " (register via admin setKv, X-Rove-Scope: __auth__).");
      }
      return new OIDCProvider(JSON.parse(raw), name);
    }
    if (typeof arg === "object") {
      return new OIDCProvider(arg, arg.name || "_inline");
    }
    throw new TypeError("oidc.provider: expected string name or config object");
  },

  // oidc.rp("name") → reads `_oidc/rp/name`  (the client analog of
  // oidc.provider). oidc.rp() → `_oidc/rp/default`. oidc.rp({...}) →
  // inline config. See OIDCRelyingParty for the (grounded) flow.
  rp(arg) {
    if (arg == null || typeof arg === "string") {
      const name = arg || "default";
      const raw = kv.get("_oidc/rp/" + name);
      if (raw == null) {
        throw new Error(
          "oidc.rp: no RP config at _oidc/rp/" + name +
          " (seeded at bootstrap; or set via admin setKv).");
      }
      return new OIDCRelyingParty(JSON.parse(raw), name);
    }
    if (typeof arg === "object") {
      return new OIDCRelyingParty(arg, arg.name || "_inline");
    }
    throw new TypeError("oidc.rp: expected string name or config object");
  },
};
