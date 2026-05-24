// @rove/activitypub — minimal ActivityPub (S2S) server helper.
//
// Lets a rewind.js app *be* a fediverse actor: discoverable via
// WebFinger, followable from Mastodon/Pleroma/etc., and able to
// publish notes that fan out to followers. Server-to-server only
// (no C2S client API, no media, no threading) — the smallest
// surface that is a real, interoperable federated participant.
//
// The library owns no namespace. Config lives at
// `_config/activitypub.json` (a JSON file in the customer's tree,
// mirrored read-only to kv at deploy time, exactly like
// `_config/oauth/*`):
//
//   _config/activitypub.json:
//     {
//       "domain":          "social.example.com",
//       "username":        "announce",
//       "name":            "Announce Bot",
//       "summary":         "Release notes, federated.",
//       "type":            "Service",
//       "verified_module": "ap/inbox_verified"
//     }
//
// All HTTP-Signature key material is RSA-2048 (the de-facto fediverse
// scheme — "draft-cavage" rsa-sha256). The platform's RSA primitives
// (`crypto.oidcGenerateKey` / `crypto.oidcSign` / `crypto.verifyRsa`)
// speak JWK; ActivityPub exchanges keys as SPKI PEM, so this library
// carries a minimal self-contained ASN.1 DER codec to bridge the two
// (a composition, not a missing primitive — same call the atproto
// lib makes for dag-cbor).
//
// Determinism: the inbox cannot verify a signature inline (it must
// fetch the *sender's* key — an outbound call). It therefore follows
// the platform's async-accept pattern verbatim (the
// `oauth.verifyIdToken → fetchJwks → cacheJwksFromEvent` chain):
// respond 202 immediately, fetch the key via `webhook.send`, finish
// verification + dispatch in the result module. Nothing connection-
// stateful leaks into a pure handler.

// ─────────────────────────── ASN.1 DER ───────────────────────────

function _derLen(n) {
  if (n < 0x80) return [n];
  const out = [];
  let v = n;
  while (v > 0) { out.unshift(v & 0xff); v >>= 8; }
  return [0x80 | out.length].concat(out);
}

function _der(tag, contentArr) {
  return [tag].concat(_derLen(contentArr.length)).concat(contentArr);
}

// Unsigned big-endian INTEGER: drop leading zero bytes, then prepend
// a 0x00 if the high bit is set (DER integers are signed).
function _derUint(bytes) {
  let i = 0;
  while (i < bytes.length - 1 && bytes[i] === 0) i++;
  let body = Array.prototype.slice.call(bytes, i);
  if (body.length === 0) body = [0];
  if (body[0] & 0x80) body = [0].concat(body);
  return _der(0x02, body);
}

function _pemWrap(derBytes, label) {
  const b64 = _b64std(Uint8Array.from(derBytes));
  let lines = "";
  for (let i = 0; i < b64.length; i += 64) lines += b64.slice(i, i + 64) + "\n";
  return "-----BEGIN " + label + "-----\n" + lines + "-----END " + label + "-----\n";
}

// rsaEncryption AlgorithmIdentifier: OID 1.2.840.113549.1.1.1 + NULL.
const _RSA_ALG_ID = [
  0x30, 0x0d,
  0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
  0x05, 0x00,
];

// JWK {n,e} (base64url) → SubjectPublicKeyInfo PEM ("PUBLIC KEY").
function _pemFromJwk(jwk) {
  const n = Array.prototype.slice.call(base64url.decode(jwk.n));
  const e = Array.prototype.slice.call(base64url.decode(jwk.e));
  const rsaSeq = _der(0x30, _derUint(n).concat(_derUint(e)));
  // BIT STRING wraps the key sequence with a leading 0 unused-bits byte.
  const bitStr = _der(0x03, [0x00].concat(rsaSeq));
  const spki = _der(0x30, _RSA_ALG_ID.concat(bitStr));
  return _pemWrap(spki, "PUBLIC KEY");
}

function _readTLV(buf, pos) {
  const tag = buf[pos++];
  let len = buf[pos++];
  if (len & 0x80) {
    let cnt = len & 0x7f;
    len = 0;
    while (cnt-- > 0) len = (len << 8) | buf[pos++];
  }
  return { tag: tag, start: pos, end: pos + len, next: pos + len };
}

function _trimInt(buf, t) {
  let s = t.start;
  while (s < t.end - 1 && buf[s] === 0) s++;
  return buf.subarray(s, t.end);
}

// SPKI ("PUBLIC KEY") or PKCS#1 ("RSA PUBLIC KEY") PEM → JWK {n,e}.
// Mastodon emits SPKI; some implementations emit bare PKCS#1.
function _jwkFromPem(pem) {
  const m = /-----BEGIN (RSA )?PUBLIC KEY-----([\s\S]+?)-----END/.exec(pem);
  if (!m) throw new Error("activitypub: unrecognized public key PEM");
  const der = base64url.decode(m[2].replace(/\s+/g, ""));
  let seq;
  if (m[1]) {
    // PKCS#1 RSAPublicKey ::= SEQUENCE { n INTEGER, e INTEGER }
    seq = _readTLV(der, 0);
  } else {
    // SPKI: SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }
    const outer = _readTLV(der, 0);
    const alg = _readTLV(der, outer.start);
    const bits = _readTLV(der, alg.next);
    seq = _readTLV(der, bits.start + 1); // skip unused-bits byte
  }
  const nT = _readTLV(der, seq.start);
  const eT = _readTLV(der, nT.next);
  return {
    kty: "RSA",
    n: base64url.encode(_trimInt(der, nT)),
    e: base64url.encode(_trimInt(der, eT)),
  };
}

// ───────────────────────── signature glue ────────────────────────

// Bytes → padded standard base64 (HTTP-Signature wants standard, but
// crypto.oidcSign returns base64url; this bridges both ways).
function _b64std(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

function _sha256b64(body) {
  return _b64std(hex.decode(crypto.sha256(body)));
}

function _httpDate(ms) {
  return new Date(ms).toUTCString();
}

// Manual URL split (no global URL in the QJS context). Returns
// host (with port) and path (defaulting to "/").
function _splitUrl(u) {
  const m = /^https?:\/\/([^/]+)(\/[^?#]*)?/.exec(u);
  if (!m) throw new Error("activitypub: bad URL " + u);
  return { host: m[1], path: m[2] || "/" };
}

// Parse a draft-cavage `Signature:` header into a flat map.
function _parseSigHeader(h) {
  const out = {};
  const re = /([a-zA-Z]+)="([^"]*)"/g;
  let m;
  while ((m = re.exec(h)) !== null) out[m[1]] = m[2];
  return out;
}

// Rebuild the signing string from the `headers` list, drawing values
// from a captured request snapshot (so it is identical on replay).
function _signingStringFromSnapshot(snap, headerList) {
  const lines = [];
  for (const name of headerList.split(" ")) {
    if (name === "(request-target)") {
      lines.push("(request-target): " + snap.method.toLowerCase() + " " + snap.path);
    } else {
      lines.push(name + ": " + (snap.headers[name] || ""));
    }
  }
  return lines.join("\n");
}

const _AS_CONTEXT = "https://www.w3.org/ns/activitystreams";
const _PUBLIC = "https://www.w3.org/ns/activitystreams#Public";
const _AP_CT = "application/activity+json";

/**
 * One federated actor, bound to its config. Obtain via
 * {@link activitypub.fromConfig}. The actor is a single account
 * (`@username@domain`) that others follow and that publishes notes.
 * All state lives in this tenant's kv under config-derived paths;
 * the library owns no reserved prefix.
 *
 * @class ActivityPubActor
 */
class ActivityPubActor {
  /**
   * @param {object} cfg - Config. Required: `domain`, `username`,
   *   `verified_module` (the module that finishes inbox processing
   *   after the async key fetch). Optional: `name`, `summary`,
   *   `type` (`"Service"` default, or `"Person"`), `icon_url`,
   *   `key_path` (default `ap/key`), `followers_path` (default
   *   `ap/followers`), `outbox_path` (default `ap/outbox`),
   *   `keycache_path` (default `cache/ap/keys`).
   * @throws {TypeError} Missing a required key.
   */
  constructor(cfg) {
    for (const k of ["domain", "username", "verified_module"]) {
      if (typeof cfg[k] !== "string" || !cfg[k]) {
        throw new TypeError("activitypub: missing required config key: " + k);
      }
    }
    const base = "https://" + cfg.domain;
    this.cfg = {
      domain: cfg.domain,
      username: cfg.username,
      name: cfg.name || cfg.username,
      summary: cfg.summary || "",
      type: cfg.type === "Person" ? "Person" : "Service",
      icon_url: cfg.icon_url || null,
      verified_module: cfg.verified_module,
      key_path: cfg.key_path || "ap/key",
      followers_path: cfg.followers_path || "ap/followers",
      outbox_path: cfg.outbox_path || "ap/outbox",
      keycache_path: cfg.keycache_path || "cache/ap/keys",
    };
    this.base = base;
    this.actorId = base + "/actor";
    this.inboxUrl = base + "/actor/inbox";
    this.outboxUrl = base + "/actor/outbox";
    this.followersUrl = base + "/actor/followers";
    this.keyId = this.actorId + "#main-key";
    this.acct = "acct:" + cfg.username + "@" + cfg.domain;
  }

  /**
   * Idempotently create and store this actor's RSA-2048 keypair.
   * Safe to call on every request; generates only on first call.
   * The private key is stored in kv (page-encrypted at rest by the
   * platform — no extra ceremony). Call once before serving the
   * actor document, e.g. from your setup route or lazily.
   *
   * @returns {void}
   * @example
   * export default function () {
   *   activitypub.fromConfig().ensureKeypair();
   *   return "ok";
   * }
   */
  ensureKeypair() {
    if (kv.get(this.cfg.key_path) != null) return;
    const k = crypto.oidcGenerateKey();
    kv.set(this.cfg.key_path, JSON.stringify({ priv: k.priv, jwk: k.jwk }));
  }

  _key() {
    const raw = kv.get(this.cfg.key_path);
    if (raw == null) {
      throw new Error("activitypub: no keypair — call ensureKeypair() first");
    }
    return JSON.parse(raw);
  }

  _json(status, obj, contentType) {
    response.status = status;
    response.headers = { "content-type": contentType || _AP_CT };
    return JSON.stringify(obj);
  }

  /**
   * Handle `GET /.well-known/webfinger?resource=acct:user@domain`.
   * Resolves the `acct:` URI to this actor. Return its result from
   * your webfinger route.
   *
   * @returns {string} JRD JSON body (200), or a 404 body if the
   *   resource does not match this actor.
   * @example
   * export default () => activitypub.fromConfig().webfinger();
   */
  webfinger() {
    const params = new URLSearchParams(request.query || "");
    const resource = params.get("resource");
    if (resource !== this.acct) {
      response.status = 404;
      return "not found";
    }
    return this._json(200, {
      subject: this.acct,
      links: [
        { rel: "self", type: _AP_CT, href: this.actorId },
      ],
    }, "application/jrd+json");
  }

  /**
   * The actor object (JSON-LD). Use {@link ActivityPubActor#actor}
   * to serve it directly; this returns the plain object if you need
   * to embed or extend it.
   *
   * @returns {object} The ActivityStreams actor document.
   */
  actorDocument() {
    const key = this._key();
    const doc = {
      "@context": [
        _AS_CONTEXT,
        "https://w3id.org/security/v1",
      ],
      id: this.actorId,
      type: this.cfg.type,
      preferredUsername: this.cfg.username,
      name: this.cfg.name,
      summary: this.cfg.summary,
      inbox: this.inboxUrl,
      outbox: this.outboxUrl,
      followers: this.followersUrl,
      url: this.base + "/",
      publicKey: {
        id: this.keyId,
        owner: this.actorId,
        publicKeyPem: _pemFromJwk(key.jwk),
      },
    };
    if (this.cfg.icon_url) {
      doc.icon = { type: "Image", url: this.cfg.icon_url };
    }
    return doc;
  }

  /**
   * Handle `GET /actor`. Return its result from your actor route.
   *
   * @returns {string} The actor document as `application/activity+json`.
   * @example
   * export default () => activitypub.fromConfig().actor();
   */
  actor() {
    return this._json(200, this.actorDocument());
  }

  /**
   * Handle `GET /actor/outbox`. An `OrderedCollection` of the
   * `Create` activities published via {@link ActivityPubActor#publishNote},
   * newest first. Return its result from your outbox route.
   *
   * @param {number} [limit=20] - Max items to include.
   * @returns {string} The collection as `application/activity+json`.
   * @example
   * export default () => activitypub.fromConfig().outbox();
   */
  outbox(limit) {
    limit = limit > 0 ? limit : 20;
    const rows = kv.prefix(this.cfg.outbox_path + "/", null, 1000);
    const items = rows
      .map((r) => JSON.parse(r.value))
      .reverse()
      .slice(0, limit);
    return this._json(200, {
      "@context": _AS_CONTEXT,
      id: this.outboxUrl,
      type: "OrderedCollection",
      totalItems: rows.length,
      orderedItems: items,
    });
  }

  /**
   * Handle `POST /actor/inbox`. Cannot verify inline — verifying the
   * HTTP Signature needs the *sender's* public key, an outbound
   * fetch. So this responds **202 Accepted immediately** (which
   * ActivityPub mandates: delivery is fire-and-forget), kicks an
   * {@link webhook.send} fetch of the signer's actor, and carries a
   * frozen request snapshot + the activity through `context`. The
   * `verified_module` then calls
   * {@link ActivityPubActor#completeInbox} to finish.
   *
   * @returns {string} An empty 202 body. Sets 400 on a malformed
   *   request (no Signature header / unparseable body).
   * @example
   * // ap/inbox/index.mjs
   * export default () => activitypub.fromConfig().inbox();
   */
  inbox() {
    const sigHeader = request.headers["signature"];
    if (!sigHeader) {
      response.status = 400;
      return "missing Signature header";
    }
    let activity;
    try {
      activity = JSON.parse(request.body || "{}");
    } catch (_) {
      response.status = 400;
      return "bad activity JSON";
    }
    const sig = _parseSigHeader(sigHeader);
    if (!sig.keyId || !sig.signature) {
      response.status = 400;
      return "malformed Signature header";
    }

    // Frozen snapshot of every header the signature could cover, plus
    // the raw body — verification in the result module is then a pure
    // function of taped inputs (replay-identical).
    const wantHeaders = (sig.headers || "(request-target) host date").split(" ");
    const snapHeaders = {};
    for (const h of wantHeaders) {
      if (h !== "(request-target)") snapHeaders[h] = request.headers[h] || "";
    }
    const snapshot = {
      method: request.method,
      path: request.path,
      headers: snapHeaders,
      body: request.body || "",
    };

    // keyId is "<actor-url>#main-key" — fetch the actor doc itself.
    const actorUrl = sig.keyId.split("#")[0];
    webhook.send({
      url: actorUrl,
      method: "GET",
      headers: { accept: _AP_CT },
      on_result: this.cfg.verified_module,
      context: {
        ap_kind: "inbox_verify",
        keyId: sig.keyId,
        signature: sig.signature,
        headerList: sig.headers || "(request-target) host date",
        snapshot: snapshot,
        activity: activity,
      },
    });

    response.status = 202;
    return "";
  }

  /**
   * Finish inbox processing. Call from your `verified_module` with
   * the {@link webhook.send} result event. Caches the signer's key,
   * verifies the HTTP Signature + `Digest`, then dispatches the
   * activity: `Follow` → record follower and auto-send `Accept`;
   * `Undo Follow` → drop follower; everything else → acknowledged
   * no-op. Mirrors `oauth.cacheJwksFromEvent` + re-verify.
   *
   * @param {object} event - The webhook.send result event
   *   (`{ok,status,body,context}`).
   * @returns {{ok:boolean, action?:string, error?:string}} Outcome
   *   (for logging / your own bookkeeping). Side effects — follower
   *   writes, the `Accept` send — are already applied/queued.
   * @example
   * // ap/inbox_verified/index.mjs
   * export default (event) =>
   *   activitypub.fromConfig().completeInbox(event);
   */
  completeInbox(event) {
    const ctx = (event && event.context) || {};
    if (!event || !event.ok) {
      return { ok: false, error: "actor fetch failed" };
    }
    let signerActor;
    try { signerActor = JSON.parse(event.body || "{}"); }
    catch (_) { return { ok: false, error: "signer actor not JSON" }; }

    const pem = signerActor.publicKey && signerActor.publicKey.publicKeyPem;
    if (!pem) return { ok: false, error: "signer has no publicKeyPem" };
    kv.set(this.cfg.keycache_path + "/" + _safeKey(ctx.keyId),
      JSON.stringify({ pem: pem, cached_at: Date.now() }));

    // 1. Digest binds the body to the signature.
    const snap = ctx.snapshot;
    if (snap.headers["digest"]) {
      const want = "SHA-256=" + _sha256b64(snap.body);
      if (snap.headers["digest"] !== want) {
        return { ok: false, error: "digest mismatch" };
      }
    }
    // 2. Verify the signature over the reconstructed signing string.
    const signingStr = _signingStringFromSnapshot(snap, ctx.headerList);
    let jwk;
    try { jwk = _jwkFromPem(pem); }
    catch (e) { return { ok: false, error: "bad signer key: " + e.message }; }
    const ok = crypto.verifyRsa(
      jwk, "sha256",
      new TextEncoder().encode(signingStr),
      base64url.decode(ctx.signature),
    );
    if (!ok) return { ok: false, error: "bad signature" };

    // 3. Verified — dispatch.
    return this._dispatch(ctx.activity, signerActor);
  }

  _dispatch(activity, signerActor) {
    const type = activity && activity.type;
    if (type === "Follow") {
      kv.set(this.cfg.followers_path + "/" + _safeKey(signerActor.id),
        JSON.stringify({
          actor: signerActor.id,
          inbox: signerActor.inbox,
          since: Date.now(),
        }));
      this._sendAccept(activity, signerActor.inbox);
      return { ok: true, action: "follow" };
    }
    if (type === "Undo" && activity.object && activity.object.type === "Follow") {
      kv.delete(this.cfg.followers_path + "/" + _safeKey(signerActor.id));
      return { ok: true, action: "unfollow" };
    }
    return { ok: true, action: "ignored:" + (type || "unknown") };
  }

  _sendAccept(followActivity, targetInbox) {
    this._deliver(targetInbox, {
      "@context": _AS_CONTEXT,
      id: this.actorId + "/accepts/" + crypto.randomUUID(),
      type: "Accept",
      actor: this.actorId,
      object: followActivity,
    });
  }

  /**
   * Publish a `Note`, wrapped in a `Create`, and fan it out to every
   * follower's inbox via signed, durable {@link webhook.send} (retried
   * by the platform; down followers don't block the others). The
   * `Create` is also appended to the outbox.
   *
   * @param {string} content - The note's HTML content.
   * @param {object} [opts]
   * @param {string} [opts.in_reply_to] - A note URI this replies to.
   * @returns {{id:string, delivered:number}} The note id and the
   *   number of follower inboxes the delivery was queued to.
   * @example
   * // POST /post  (authenticate this yourself)
   * export default function () {
   *   const { content } = JSON.parse(request.body);
   *   return JSON.stringify(activitypub.fromConfig().publishNote(content));
   * }
   */
  publishNote(content, opts) {
    opts = opts || {};
    const now = Date.now();
    const uid = crypto.randomUUID();
    const published = new Date(now).toISOString();
    const noteId = this.actorId + "/notes/" + uid;
    const note = {
      id: noteId,
      type: "Note",
      attributedTo: this.actorId,
      content: content,
      published: published,
      to: [_PUBLIC],
      cc: [this.followersUrl],
    };
    if (opts.in_reply_to) note.inReplyTo = opts.in_reply_to;
    const create = {
      "@context": _AS_CONTEXT,
      id: noteId + "/activity",
      type: "Create",
      actor: this.actorId,
      published: published,
      to: [_PUBLIC],
      cc: [this.followersUrl],
      object: note,
    };

    // Sortable outbox key: zero-padded ms timestamp + uid.
    const seq = ("0000000000000000" + now).slice(-16);
    kv.set(this.cfg.outbox_path + "/" + seq + "-" + uid, JSON.stringify(create));

    let delivered = 0;
    let cursor = null;
    for (;;) {
      const page = kv.prefix(this.cfg.followers_path + "/", cursor, 1000);
      if (page.length === 0) break;
      for (const row of page) {
        const f = JSON.parse(row.value);
        if (f.inbox) { this._deliver(f.inbox, create); delivered++; }
      }
      cursor = page[page.length - 1].key;
    }
    return { id: noteId, delivered: delivered };
  }

  // Signed POST of an activity to a remote inbox, as a durable Cmd.
  _deliver(targetInbox, activity) {
    const key = this._key();
    const body = JSON.stringify(activity);
    const u = _splitUrl(targetInbox);
    const date = _httpDate(Date.now());
    const digest = "SHA-256=" + _sha256b64(body);
    const headerList = "(request-target) host date digest content-type";
    const signingStr = [
      "(request-target): post " + u.path,
      "host: " + u.host,
      "date: " + date,
      "digest: " + digest,
      "content-type: " + _AP_CT,
    ].join("\n");
    const sigB64 = _b64std(base64url.decode(crypto.oidcSign(key.priv, signingStr)));
    webhook.send({
      url: targetInbox,
      method: "POST",
      headers: {
        host: u.host,
        date: date,
        digest: digest,
        "content-type": _AP_CT,
        signature:
          'keyId="' + this.keyId + '",algorithm="rsa-sha256",headers="' +
          headerList + '",signature="' + sigB64 + '"',
      },
      body: body,
    });
  }
}

// kv keys can't contain arbitrary URL chars cleanly; hash the id to a
// stable, prefix-safe token. Collision-resistant and deterministic.
function _safeKey(s) {
  return crypto.sha256(String(s));
}

/**
 * Minimal ActivityPub (server-to-server) helper. Makes a rewind.js
 * app a followable fediverse actor. The library owns no namespace —
 * config lives at `_config/activitypub.json` (a file in your tree,
 * mirrored read-only to kv at deploy).
 *
 * @namespace activitypub
 */
globalThis.activitypub = {
  /**
   * Resolve config and return an {@link ActivityPubActor}.
   *
   * @param {string|object} [arg] - A config name (reads
   *   `_config/activitypub[/{name}].json`; default file is
   *   `_config/activitypub.json`) or an inline config object.
   * @returns {ActivityPubActor}
   * @throws {Error} Named config not found (file not deployed).
   * @throws {TypeError} `arg` is neither string nor object.
   * @example
   * const ap = activitypub.fromConfig();
   */
  fromConfig(arg) {
    if (arg == null || typeof arg === "string") {
      const path = arg ? "_config/activitypub/" + arg : "_config/activitypub";
      const raw = kv.get(path);
      if (raw == null) {
        throw new Error(
          "activitypub.fromConfig: config not found at " + path +
          ". Did you deploy the file?");
      }
      return new ActivityPubActor(JSON.parse(raw));
    }
    if (typeof arg === "object") {
      return new ActivityPubActor(arg);
    }
    throw new TypeError(
      "activitypub.fromConfig: expected string name or inline config object");
  },
};
