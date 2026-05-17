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

/**
 * A cookie-backed session store bound to one config. Obtain via
 * {@link sessions.fromConfig}; state rows live in this tenant's kv
 * at `state/sessions/{name}/{id}`.
 *
 * @class Sessions
 */
class Sessions {
  /**
   * @param {object} config - Merged over the defaults
   *   (cookie_name/max_age_s/same_site/secure/http_only/path).
   *   `state_path` is required (set by {@link sessions.fromConfig}).
   */
  constructor(config) {
    this.cfg = Object.assign({}, SESSION_DEFAULTS, config);
    if (!this.cfg.state_path) {
      throw new TypeError("sessions: config.state_path required");
    }
  }

  /**
   * Create a session: write the row, set the cookie on the
   * response, return the new id. `created_at` (ms) is stamped in.
   *
   * @param {object} data - Arbitrary session payload.
   * @returns {string} The new session id.
   * @example
   * sessions.fromConfig().create({ user_sub: payload.sub });
   */
  create(data) {
    const id = crypto.randomUUID();
    kv.set(this.cfg.state_path + "/" + id, JSON.stringify(Object.assign({}, data, {
      created_at: Date.now(),
    })));
    _appendSetCookie(this._cookieHeader(id, this.cfg.max_age_s));
    return id;
  }

  /**
   * Read the current request's session payload.
   *
   * @returns {object|null} The stored payload (incl. `created_at`),
   *   or `null` if there is no/unknown session cookie.
   * @example
   * const sess = sessions.fromConfig().get();
   * if (!sess) { response.status = 401; return "no session"; }
   */
  get() {
    const id = this._currentId();
    if (!id) return null;
    const raw = kv.get(this.cfg.state_path + "/" + id);
    if (raw == null) return null;
    return JSON.parse(raw);
  }

  /**
   * Update the current session row.
   *
   * @param {object|function(object): object} patch - An object
   *   shallow-merged into the current payload, or a
   *   `(current) => next` function.
   * @returns {object|null} The updated payload, or `null` if there
   *   is no session.
   * @example
   * sessions.fromConfig().update({ last_seen: Date.now() });
   */
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

  /**
   * Delete the current session row and clear the cookie (logout).
   * No-op if there is no session.
   *
   * @returns {void}
   * @example
   * sessions.fromConfig().destroy();
   */
  destroy() {
    const id = this._currentId();
    if (id) kv.delete(this.cfg.state_path + "/" + id);
    _appendSetCookie(this._cookieHeader("", 0));
  }

  /**
   * Rotate the session id, keeping the data and refreshing the
   * cookie. Use after a privilege change (login, role grant) to
   * defend against session-fixation.
   *
   * @returns {string|null} The new id, or `null` if there is no
   *   session.
   * @example
   * sessions.fromConfig().rotate(); // call right after login
   */
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

/**
 * Parse a `Cookie:` header value into a `{name: value}` map.
 *
 * @param {string} header - Raw `Cookie:` header value.
 * @returns {Object<string,string>} Empty object when `header` is
 *   falsy or has no valid pairs.
 */
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

/**
 * Cookie-backed session storage on top of {@link kv}. Config lives
 * at `_config/sessions/{name}` (a JSON file in your tree, mirrored
 * read-only to kv at deploy); state at `state/sessions/{name}/{id}`.
 *
 * @namespace sessions
 */
globalThis.sessions = {
  /**
   * Resolve a config and return a {@link Sessions} instance.
   * `state_path` defaults to `state/sessions/{name}`.
   *
   * @param {string|object} [arg] - A name (reads
   *   `_config/sessions/{name}`; default `"default"`) or an inline
   *   config object.
   * @returns {Sessions}
   * @throws {Error} Named config not found (file not deployed).
   * @throws {TypeError} `arg` is neither string nor object.
   * @example
   * const s = sessions.fromConfig();          // "default"
   * const a = sessions.fromConfig("admin");
   */
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
