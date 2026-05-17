// @rove/users — a managed user store (the "Clerk-like" spine).
//
// Dogfic customer library, the oidc.js / oauth.js model: owns no
// platform.*, every kv path is a plain key in the calling tenant.
// Scope: B2C, passwordless (docs/users-lib-plan.md). This file is
// P2a — record schema + CRUD + email index. Account linking (P2b),
// sessions/revocation (P2c) and webhooks (P4b) layer on top.
//
// kv layout (see users-lib-plan.md):
//   users/{uid}                 → the JSON record
//   idx/email/{sha256(email)}   → uid           (lookup + link join)
// Record:
//   { uid, email, email_verified, name, avatar,
//     status: "active"|"disabled", created_at, updated_at,
//     metadata: { public:{}, private:{} } }

// uid = "usr_" + 24 hex (96 bits CSPRNG) — collision-safe, opaque,
// Clerk-ish shape. Not derived from email (email is mutable / PII).
function _uid() {
  const b = crypto.randomBytes(12);
  let s = "";
  for (let i = 0; i < b.length; i++) {
    s += (b[i] + 0x100).toString(16).slice(1);
  }
  return "usr_" + s;
}

function _normEmail(email) {
  return String(email == null ? "" : email).trim().toLowerCase();
}

function _emailKey(email) {
  return "idx/email/" + crypto.sha256(_normEmail(email));
}

function _recKey(uid) {
  return "users/" + uid;
}

function _readRec(uid) {
  if (typeof uid !== "string" || uid.length === 0) return null;
  const raw = kv.get(_recKey(uid));
  if (raw == null) return null;
  try { return JSON.parse(raw); } catch (_) { return null; }
}

function _writeRec(rec) {
  kv.set(_recKey(rec.uid), JSON.stringify(rec));
  return rec;
}

/**
 * Managed user store. B2C, passwordless. The library owns no
 * namespace — all keys are plain kv in the calling tenant
 * (docs/users-lib-plan.md).
 *
 * @namespace users
 */
globalThis.users = {
  /**
   * Create a user. Email is normalized (trim + lowercase) and must
   * be unique — the email index is the link join key (P2b), so a
   * duplicate is a hard error rather than a silent second account.
   *
   * @param {object} input - `{email}` required; optional
   *   `email_verified` (default `false`), `name`, `avatar`,
   *   `metadata:{public,private}`.
   * @returns {object} The created record.
   * @throws {TypeError} Missing/invalid email.
   * @throws {Error} `email_exists` — an account already owns it.
   * @example
   * const u = users.create({ email, email_verified: true });
   */
  create(input) {
    input = input || {};
    const email = _normEmail(input.email);
    if (!email || email.indexOf("@") < 1) {
      throw new TypeError("users.create: valid email required");
    }
    if (kv.get(_emailKey(email)) != null) {
      throw new Error("email_exists");
    }
    const now = Date.now();
    const md = input.metadata || {};
    const rec = {
      uid: _uid(),
      email,
      email_verified: input.email_verified === true,
      name: input.name || null,
      avatar: input.avatar || null,
      status: "active",
      created_at: now,
      updated_at: now,
      metadata: {
        public: md.public || {},
        private: md.private || {},
      },
    };
    // Record first, then index: a crash between leaves an orphan
    // record (harmless, GC-able) rather than an index pointing at
    // nothing (a lookup that resurrects a missing user).
    _writeRec(rec);
    kv.set(_emailKey(email), rec.uid);
    return rec;
  },

  /**
   * Fetch a user by uid.
   *
   * @param {string} uid
   * @returns {object|null} The record, or `null` if absent.
   */
  get(uid) {
    return _readRec(uid);
  },

  /**
   * Fetch a user by email (normalized) via the email index.
   *
   * @param {string} email
   * @returns {object|null} The record, or `null` if no such user.
   */
  byEmail(email) {
    const e = _normEmail(email);
    if (!e) return null;
    const uid = kv.get(_emailKey(e));
    if (uid == null) return null;
    return _readRec(uid);
  },

  /**
   * Patch a user. Only `name`, `avatar`, `email_verified` and
   * `metadata.public`/`metadata.private` are patchable. Changing
   * `email` is a distinct, index-rewriting operation — deliberately
   * not done here (P2b owns identity moves).
   *
   * @param {string} uid
   * @param {object} patch
   * @returns {object} The updated record.
   * @throws {Error} `not_found`.
   */
  update(uid, patch) {
    const rec = _readRec(uid);
    if (!rec) throw new Error("not_found");
    patch = patch || {};
    if ("name" in patch) rec.name = patch.name;
    if ("avatar" in patch) rec.avatar = patch.avatar;
    if ("email_verified" in patch) {
      rec.email_verified = patch.email_verified === true;
    }
    if (patch.metadata) {
      if (patch.metadata.public) {
        rec.metadata.public = Object.assign(
          {}, rec.metadata.public, patch.metadata.public);
      }
      if (patch.metadata.private) {
        rec.metadata.private = Object.assign(
          {}, rec.metadata.private, patch.metadata.private);
      }
    }
    rec.updated_at = Date.now();
    return _writeRec(rec);
  },

  /**
   * List users (records only — session subkeys are filtered out).
   *
   * @param {string} [cursor] - Opaque; pass the prior
   *   `next_cursor`.
   * @param {number} [limit] - 1–1000, default 100.
   * @returns {object} `{users:[record,…], next_cursor?}`.
   */
  list(cursor, limit) {
    const l = Math.max(1, Math.min(parseInt(limit ?? 100, 10) || 100, 1000));
    const rows = kv.prefix("users/", cursor || "", l);
    const out = [];
    for (const e of rows) {
      // Skip P2c session subkeys: a record key is exactly
      // `users/{uid}` with no further `/`.
      if (e.key.indexOf("/", "users/".length) !== -1) continue;
      try { out.push(JSON.parse(e.value)); } catch (_) {}
    }
    const body = { users: out };
    if (rows.length === l && rows.length > 0) {
      body.next_cursor = rows[rows.length - 1].key;
    }
    return body;
  },

  /**
   * Disable a user (status → `"disabled"`). Guards/sessions treat a
   * disabled user as logged-out (enforced in P2c). Reversible via
   * {@link users.enable}.
   *
   * @param {string} uid
   * @returns {object} The updated record.
   * @throws {Error} `not_found`.
   */
  disable(uid) {
    const rec = _readRec(uid);
    if (!rec) throw new Error("not_found");
    rec.status = "disabled";
    rec.updated_at = Date.now();
    return _writeRec(rec);
  },

  /**
   * Re-enable a disabled user (status → `"active"`).
   *
   * @param {string} uid
   * @returns {object} The updated record.
   * @throws {Error} `not_found`.
   */
  enable(uid) {
    const rec = _readRec(uid);
    if (!rec) throw new Error("not_found");
    rec.status = "active";
    rec.updated_at = Date.now();
    return _writeRec(rec);
  },
};
