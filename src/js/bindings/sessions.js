// @rove/sessions — cookie-backed session storage on top of kv.
//
// Same convention as @rove/oauth: config lives at
// `_config/sessions/{name}` (a JSON file in the customer's tree
// mirrored read-only to kv at deploy). State lives at
// `state/sessions/{name}/{session_id}`.
//
//   _config/sessions/default.json:
//     {
//       "cookie_name": "session",
//       "max_age_s":   2592000,
//       "same_site":   "Lax",
//       "secure":      true,
//       "http_only":   true,
//       "path":        "/"
//     }
//
//   // After successful auth (e.g. inside oauth's on_complete handler)
//   sessions.fromConfig().create({
//     user_sub: payload.sub,
//     email:    payload.email,
//   });
//
//   // In any handler that needs the current user
//   const sess = sessions.fromConfig().get();
//   if (!sess) { response.status = 401; return "no session"; }
//   // sess = { user_sub, email, created_at }
//
//   // Logout
//   sessions.fromConfig().destroy();
//
//   // Privilege change — rotate the id, keep the data, fresh cookie
//   sessions.fromConfig().rotate();

const SESSION_DEFAULTS = {
  cookie_name: "session",
  max_age_s: 30 * 24 * 60 * 60,   // 30 days
  same_site: "Lax",
  secure: true,
  http_only: true,
  path: "/",
};

class Sessions {
  constructor(config) {
    this.cfg = Object.assign({}, SESSION_DEFAULTS, config);
    if (!this.cfg.state_path) {
      throw new TypeError("sessions: config.state_path required");
    }
  }

  /// Create a session row, set the cookie on the response, return the id.
  create(data) {
    const id = crypto.randomUUID();
    kv.set(this.cfg.state_path + "/" + id, JSON.stringify(Object.assign({}, data, {
      created_at: Date.now(),
    })));
    _appendSetCookie(this._cookieHeader(id, this.cfg.max_age_s));
    return id;
  }

  /// Read the current request's session payload, or null if absent.
  get() {
    const id = this._currentId();
    if (!id) return null;
    const raw = kv.get(this.cfg.state_path + "/" + id);
    if (raw == null) return null;
    return JSON.parse(raw);
  }

  /// Merge `patch` into the current session row (or pass a function for
  /// (current) → next). Returns the updated payload, or null if no session.
  update(patch) {
    const id = this._currentId();
    if (!id) return null;
    const raw = kv.get(this.cfg.state_path + "/" + id);
    if (raw == null) return null;
    const current = JSON.parse(raw);
    const next = typeof patch === "function" ? patch(current) : Object.assign({}, current, patch);
    kv.set(this.cfg.state_path + "/" + id, JSON.stringify(next));
    return next;
  }

  /// Delete the current session and clear the cookie.
  destroy() {
    const id = this._currentId();
    if (id) kv.delete(this.cfg.state_path + "/" + id);
    _appendSetCookie(this._cookieHeader("", 0));
  }

  /// Rotate session id, keeping the data. Use after privilege change
  /// (login, role grant) to defend against fixation attacks.
  rotate() {
    const old_id = this._currentId();
    if (!old_id) return null;
    const raw = kv.get(this.cfg.state_path + "/" + old_id);
    if (raw == null) return null;
    kv.delete(this.cfg.state_path + "/" + old_id);
    const new_id = crypto.randomUUID();
    kv.set(this.cfg.state_path + "/" + new_id, raw);
    _appendSetCookie(this._cookieHeader(new_id, this.cfg.max_age_s));
    return new_id;
  }

  _currentId() {
    // Platform parses the inbound `cookie:` header into
    // `request.cookies` for us. Fall back to nothing if the request
    // didn't carry any.
    const c = (request && request.cookies) || {};
    return c[this.cfg.cookie_name] || null;
  }

  _cookieHeader(value, max_age_s) {
    const parts = [this.cfg.cookie_name + "=" + value];
    parts.push("Path=" + this.cfg.path);
    parts.push("Max-Age=" + max_age_s);
    parts.push("SameSite=" + this.cfg.same_site);
    if (this.cfg.http_only) parts.push("HttpOnly");
    if (this.cfg.secure) parts.push("Secure");
    return parts.join("; ");
  }
}

/// Parse a `Cookie:` header value into a `{name: value}` object.
function parseCookies(header) {
  const out = {};
  if (!header) return out;
  for (const pair of header.split(";")) {
    const eq = pair.indexOf("=");
    if (eq < 0) continue;
    const k = pair.slice(0, eq).trim();
    const v = pair.slice(eq + 1).trim();
    if (k) out[k] = v;
  }
  return out;
}

// Cookies on the response go through `response.cookies` (an array of
// raw `set-cookie` values) — the platform sanitizes + emits them as
// individual headers. Setting `response.headers["set-cookie"]`
// directly is rejected.
function _appendSetCookie(value) {
  if (!response.cookies) response.cookies = [];
  response.cookies.push(value);
}

globalThis.sessions = {
  /// Resolve a config and return a sessions instance.
  ///   - sessions.fromConfig("admin") → reads `_config/sessions/admin`
  ///   - sessions.fromConfig()        → reads `_config/sessions/default`
  ///   - sessions.fromConfig({...})   → inline config
  /// state_path defaults to `state/sessions/{name}`.
  fromConfig(arg) {
    if (arg == null || typeof arg === "string") {
      const name = arg || "default";
      const raw = kv.get("_config/sessions/" + name);
      if (raw == null) {
        throw new Error("sessions.fromConfig: config not found at _config/sessions/" + name + ". Did you deploy the file?");
      }
      return new Sessions(_sessionsDefaults(JSON.parse(raw), name));
    }
    if (typeof arg === "object") {
      const name = arg.name || "_inline";
      return new Sessions(_sessionsDefaults(arg, name));
    }
    throw new TypeError("sessions.fromConfig: expected string name or inline config object");
  },
  parseCookies,
};

function _sessionsDefaults(cfg, name) {
  return Object.assign({}, cfg, {
    state_path: cfg.state_path || ("state/sessions/" + name),
  });
}
