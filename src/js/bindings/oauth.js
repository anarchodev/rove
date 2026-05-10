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

    http.send({
      url: this.cfg.token_url,
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body_params.toString(),
      on_result: { module: this.cfg.on_complete_module },
      context: Object.assign({}, stored.context, {
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
    return http.send({
      url: this.cfg.token_url,
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body_params.toString(),
      on_result: { module: this.cfg.on_complete_module },
      context: Object.assign({ refresh: true }, extra_context || {}),
    });
  }
}

globalThis.oauth = {
  /// Resolve a config and return a provider instance.
  ///   - oauth.fromConfig("google")  → reads `_config/oauth/google` from kv
  ///   - oauth.fromConfig()          → reads `_config/oauth/default`
  ///   - oauth.fromConfig({...})     → uses the inline object as the config
  ///
  /// Defaults derived from the instance name:
  ///   state_path = `state/oauth/{name}`
  ///   cache_path = `cache/oauth/{name}`
  /// Override either by setting the key in the config row.
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
};

function _oauthDefaults(cfg, name) {
  return Object.assign({}, cfg, {
    state_path: cfg.state_path || ("state/oauth/" + name),
    cache_path: cfg.cache_path || ("cache/oauth/" + name),
  });
}
