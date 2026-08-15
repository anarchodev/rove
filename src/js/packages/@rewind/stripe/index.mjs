// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// `@rewind/stripe` — subscriptions, Elements intents, and webhook
// signature verification. An INTEGRATION lib: it wraps the vendor and
// composes the frozen primitives; it builds no engine of its own
// (`docs/strategy/saas-in-a-box.md` §3).
//
// Two dispatch shapes, chosen per call rather than for the package:
//
//   held    (`after.fetch` + `next()`) — the caller needs the answer
//           INSIDE this response. Elements cannot start without the
//           `client_secret`, so intent creation must resume the live
//           connection.
//   durable (`webhook.send`)           — the world changes and the
//           answer can arrive later. Money moves here, so losing the
//           call is worse than answering slowly.
//
// The rule, applied to every method below: if the caller needs the
// answer in this response it is held; if the world changes and the
// answer can arrive later it is durable. That is the effect algebra's
// connection-scoped vs durable axis (`docs/effect-algebra.md`), not a
// taxonomy this package invents.
//
// Every DURABLE call carries an `Idempotency-Key`. `webhook.send`
// retries from one marker, so a key derived at marker-write time is
// stable across every attempt — which is exactly what Stripe's
// idempotency window wants. A mutating call without one is a second
// subscription waiting to happen.
//
// Outbound is a paid capability (`outbound_enabled`, `src/plan/root.zig`),
// so this package cannot run on a free tenant at all. The platform's own
// billing traffic runs in `__admin__`, which resolves to the platform
// tier by id.

const API = "https://api.stripe.com/v1";

/**
 * Stripe's API takes `application/x-www-form-urlencoded` with bracket
 * nesting (`items[0][price]=…`, `metadata[user]=…`), not JSON. Encode
 * nested objects/arrays into that shape.
 *
 * @param {object} obj - Parameters to encode.
 * @returns {string} Form-encoded body.
 */
function form(obj) {
  const p = new URLSearchParams();
  const walk = (prefix, value) => {
    if (value === undefined || value === null) return;
    if (Array.isArray(value)) {
      for (let i = 0; i < value.length; i++) walk(prefix + "[" + i + "]", value[i]);
      return;
    }
    if (typeof value === "object") {
      for (const k of Object.keys(value)) walk(prefix + "[" + k + "]", value[k]);
      return;
    }
    p.append(prefix, String(value));
  };
  for (const k of Object.keys(obj || {})) walk(k, obj[k]);
  return p.toString();
}

/**
 * Constant-time string comparison by double HMAC. There is no
 * `timingSafeEqual` primitive, and `===` on hex digests is not
 * constant-time — but HMAC-ing both sides under a FRESH random key
 * makes the compared values unpredictable to an attacker, so the
 * comparison's timing reveals nothing about the secret.
 *
 * @param {string} a
 * @param {string} b
 * @returns {boolean}
 */
function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const k = crypto.randomBytes(32);
  return crypto.hmacSha256(k, a) === crypto.hmacSha256(k, b);
}

/**
 * Lowercase hex of a byte array — used for idempotency keys, so they are
 * URL/header safe and fixed-width.
 *
 * @param {Uint8Array} bytes
 * @returns {string}
 */
function hex(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += bytes[i].toString(16).padStart(2, "0");
  return s;
}

function requireKey(apiKey, where) {
  if (typeof apiKey !== "string" || apiKey.length === 0)
    throw new TypeError(where + ": `apiKey` must be a non-empty string");
}

function rejectRenamed(where, opts) {
  for (const pair of [["key", "idempotencyKey"], ["api_key", "apiKey"],
                      ["on_result", "on"], ["max_attempts", "maxAttempts"],
                      ["timeout_ms", "timeoutMs"]]) {
    if (opts && pair[0] in opts)
      throw new TypeError(where + ": option `" + pair[0] + "` was renamed — use `" + pair[1] + "`");
  }
}

/**
 * A Stripe client bound to one secret key.
 *
 * @namespace stripe
 */
const stripe = {
  /**
   * Bind an API key (and an optional default result handler).
   *
   * @param {object} cfg
   * @param {string} cfg.apiKey - Stripe secret key (`sk_…`). Sent as
   *   `Authorization: Bearer`; never reaches a request body, so it is
   *   not recorded as one.
   * @param {string} [cfg.on] - Default result-handler module for calls
   *   that do not name one.
   * @returns {object} The client.
   *
   * @example
   * const sk = stripe.client({ apiKey: kv.get("stripe_key") });
   * sk.setupIntents.create({ customer: cid, on: "onIntent" });
   * return next();                       // held — resumes with the secret
   */
  client(cfg) {
    if (!cfg || typeof cfg !== "object")
      throw new TypeError("stripe.client requires an options object");
    rejectRenamed("stripe.client", cfg);
    requireKey(cfg.apiKey, "stripe.client");
    const apiKey = cfg.apiKey;
    const defaultOn = typeof cfg.on === "string" ? cfg.on : undefined;

    const auth = () => ({
      "Authorization": "Bearer " + apiKey,
      "Content-Type": "application/x-www-form-urlencoded",
    });

    // ── held: the caller needs the answer in THIS response ──────────
    const held = (where, method, path, params, opts) => {
      rejectRenamed(where, opts);
      const o = opts || {};
      const on = typeof o.on === "string" ? o.on : defaultOn;
      if (!on)
        throw new TypeError(where + ": `on` is required (no default was set on the client)");
      const req = { method: method, headers: auth(), on: on };
      if (params !== null) req.body = form(params);
      if (o.ctx !== undefined) req.ctx = o.ctx;
      if (o.timeoutMs != null) req.timeoutMs = o.timeoutMs;
      return after.fetch(API + path, req);
    };
    const heldWithHeaders = (where, method, path, params, opts, extra) => {
      rejectRenamed(where, opts);
      const o = opts || {};
      const on = typeof o.on === "string" ? o.on : defaultOn;
      if (!on)
        throw new TypeError(where + ": `on` is required (no default was set on the client)");
      const headers = auth();
      for (const k of Object.keys(extra)) headers[k] = extra[k];
      const req = { method: method, headers: headers, on: on, body: form(params) };
      if (o.ctx !== undefined) req.ctx = o.ctx;
      if (o.timeoutMs != null) req.timeoutMs = o.timeoutMs;
      return after.fetch(API + path, req);
    };

    // ── durable: survives the response, retried, idempotency-keyed ──
    const durable = (where, method, path, params, opts) => {
      rejectRenamed(where, opts);
      const o = opts || {};
      // The key is decided BEFORE the send, because the marker is written
      // at send time and every retry re-fires from that marker — so a key
      // stamped afterwards would never reach the wire. A caller-supplied
      // key also dedupes across THEIR retries; absent one, a fresh random
      // key is generated (replay-deterministic, per `crypto.randomBytes`)
      // and doubles as the marker handle, so the marker id and the
      // Idempotency-Key are the same string.
      const idem = typeof o.idempotencyKey === "string" && o.idempotencyKey.length > 0
        ? o.idempotencyKey
        : "rwd_" + hex(crypto.randomBytes(16));
      const headers = auth();
      headers["Idempotency-Key"] = idem;
      const env = {
        method: method,
        headers: headers,
        body: params === null ? "" : form(params),
        key: idem,
      };
      if (typeof o.on === "string" || defaultOn) env.on = o.on || defaultOn;
      if (o.ctx !== undefined) env.ctx = o.ctx;
      if (o.maxAttempts) env.maxAttempts = o.maxAttempts;
      if (o.timeoutMs != null) env.timeoutMs = o.timeoutMs;
      return webhook.send(API + path, env);
    };

    return {
      customers: {
        /**
         * Create a customer. HELD — the id is needed before the flow
         * can continue.
         *
         * @param {object} params - Stripe customer params (`email`, …).
         * @param {object} [opts] - `{on, ctx, timeoutMs}`.
         * @returns {string} The `ftch_…` id.
         */
        create(params, opts) {
          return held("stripe.customers.create", "POST", "/customers", params || {}, opts);
        },
        /**
         * Fetch a customer by id. HELD.
         *
         * @param {string} id - `cus_…`.
         * @param {object} [opts] - `{on, ctx, timeoutMs}`.
         * @returns {string} The `ftch_…` id.
         */
        get(id, opts) {
          if (typeof id !== "string" || id.length === 0)
            throw new TypeError("stripe.customers.get: `id` must be a non-empty string");
          return held("stripe.customers.get", "GET", "/customers/" + encodeURIComponent(id), null, opts);
        },
      },

      setupIntents: {
        /**
         * Create a SetupIntent. HELD — the browser cannot start
         * Elements without the `client_secret` this returns.
         *
         * The `client_secret` reaches the browser through the resume,
         * and response bodies are recorded (rove#381). That exposure is
         * accepted deliberately: the capability confirms one short-lived
         * intent, and these records live in `__admin__`, whose logs are
         * operator-only. See rove#307; rove#559 is the durable fix.
         *
         * @param {object} params - Stripe SetupIntent params.
         * @param {object} [opts] - `{on, ctx, timeoutMs}`.
         * @returns {string} The `ftch_…` id.
         */
        create(params, opts) {
          return held("stripe.setupIntents.create", "POST", "/setup_intents", params || {}, opts);
        },
      },

      paymentIntents: {
        /**
         * Create a PaymentIntent. HELD — same reason as
         * {@link setupIntents.create}.
         *
         * @param {object} params - Requires `amount` + `currency`.
         * @param {object} [opts] - `{on, ctx, timeoutMs}`.
         * @returns {string} The `ftch_…` id.
         */
        create(params, opts) {
          const p = params || {};
          if (p.amount == null || typeof p.currency !== "string")
            throw new TypeError("stripe.paymentIntents.create: `amount` and `currency` are required");
          return held("stripe.paymentIntents.create", "POST", "/payment_intents", p, opts);
        },
      },

      subscriptions: {
        /**
         * Create a subscription. DURABLE — money moves, so this must
         * survive the response; retried, with an `Idempotency-Key` so a
         * retry cannot become a second subscription.
         *
         * @param {object} params - Requires `customer` and `items`.
         * @param {object} [opts] - `{on, ctx, idempotencyKey, maxAttempts, timeoutMs}`.
         * @returns {string} The marker id.
         */
        create(params, opts) {
          const p = params || {};
          if (typeof p.customer !== "string")
            throw new TypeError("stripe.subscriptions.create: `customer` is required");
          if (!Array.isArray(p.items) || p.items.length === 0)
            throw new TypeError("stripe.subscriptions.create: `items` must be a non-empty array");
          return durable("stripe.subscriptions.create", "POST", "/subscriptions", p, opts);
        },
        /**
         * Create a subscription in Stripe's `default_incomplete` mode and
         * return `latest_invoice.payment_intent` expanded — the embedded
         * Payment Element flow. HELD, and deliberately so: the browser
         * cannot mount Elements without the payment intent's
         * `client_secret` in THIS response, and no money moves
         * server-side — an incomplete subscription charges nothing until
         * the browser confirms it with Stripe directly, and expires
         * unconfirmed, exactly like an abandoned intent. The durable
         * rule ("money moves → webhook.send") applies to the browser
         * confirmation, which Stripe owns, and to {@link create}, which
         * stays durable for server-driven subscribing.
         *
         * `idempotencyKey` (optional) rides Stripe's Idempotency-Key
         * header: a double-submit inside Stripe's window returns the
         * SAME incomplete subscription rather than a second one.
         *
         * @param {object} params - Requires `customer` and `items`.
         * @param {object} [opts] - `{on, ctx, timeoutMs, idempotencyKey}`.
         * @returns {string} The `ftch_…` id.
         */
        createIncomplete(params, opts) {
          const p = params || {};
          if (typeof p.customer !== "string")
            throw new TypeError("stripe.subscriptions.createIncomplete: `customer` is required");
          if (!Array.isArray(p.items) || p.items.length === 0)
            throw new TypeError("stripe.subscriptions.createIncomplete: `items` must be a non-empty array");
          const body = Object.assign({}, p, {
            payment_behavior: "default_incomplete",
            payment_settings: { save_default_payment_method: "on_subscription" },
            expand: ["latest_invoice.payment_intent"],
          });
          const o = opts || {};
          if (typeof o.idempotencyKey === "string" && o.idempotencyKey.length > 0) {
            return heldWithHeaders("stripe.subscriptions.createIncomplete", "POST",
              "/subscriptions", body, o, { "Idempotency-Key": o.idempotencyKey });
          }
          return held("stripe.subscriptions.createIncomplete", "POST", "/subscriptions", body, o);
        },
        /**
         * Update a subscription (plan change). DURABLE.
         *
         * @param {string} id - `sub_…`.
         * @param {object} params - Stripe update params.
         * @param {object} [opts] - As {@link create}.
         * @returns {string} The marker id.
         */
        update(id, params, opts) {
          if (typeof id !== "string" || id.length === 0)
            throw new TypeError("stripe.subscriptions.update: `id` must be a non-empty string");
          return durable("stripe.subscriptions.update", "POST",
                         "/subscriptions/" + encodeURIComponent(id), params || {}, opts);
        },
        /**
         * Cancel a subscription. DURABLE.
         *
         * @param {string} id - `sub_…`.
         * @param {object} [opts] - As {@link create}.
         * @returns {string} The marker id.
         */
        cancel(id, opts) {
          if (typeof id !== "string" || id.length === 0)
            throw new TypeError("stripe.subscriptions.cancel: `id` must be a non-empty string");
          return durable("stripe.subscriptions.cancel", "DELETE",
                         "/subscriptions/" + encodeURIComponent(id), null, opts);
        },
      },
    };
  },

  /**
   * Verify a `Stripe-Signature` header against the raw request body.
   * PURE — no I/O, so it is safe anywhere in a handler.
   *
   * Pass `request.bytes`, never a re-serialized object: the signature
   * is over the raw bytes, and `JSON.parse` → `JSON.stringify` changes
   * them.
   *
   * @param {object} opts
   * @param {string} opts.secret - Endpoint signing secret (`whsec_…`).
   * @param {string} opts.header - The `Stripe-Signature` header value.
   * @param {string|Uint8Array} opts.body - Raw request body.
   * @param {number} [opts.toleranceMs=300000] - Max age of the signed
   *   timestamp. A captured signature outside this window is refused,
   *   so a replayed request cannot be accepted forever.
   * @param {number} [opts.now] - Override the clock (tests).
   * @returns {object} The parsed event.
   * @throws {Error} `code:"bad_signature"` — malformed header, no
   *   matching `v1`, or the timestamp is outside tolerance.
   *
   * @example
   * const event = stripe.verifyWebhook({
   *   secret: kv.get("stripe_whsec"),
   *   header: request.headers["stripe-signature"],
   *   body: request.bytes,
   * });
   */
  verifyWebhook(opts) {
    if (!opts || typeof opts !== "object")
      throw new TypeError("stripe.verifyWebhook requires an options object");
    if (typeof opts.secret !== "string" || opts.secret.length === 0)
      throw new TypeError("stripe.verifyWebhook: `secret` must be a non-empty string");
    if (typeof opts.header !== "string" || opts.header.length === 0)
      throw new TypeError("stripe.verifyWebhook: `header` must be a non-empty string");
    if (opts.body === undefined || opts.body === null)
      throw new TypeError("stripe.verifyWebhook: `body` is required (pass request.bytes)");

    const fail = (why) => {
      const e = new Error("stripe.verifyWebhook: " + why);
      e.code = "bad_signature";
      throw e;
    };

    // `t=1712345678,v1=<hex>,v1=<hex>,v0=<hex>` — multiple v1 entries
    // are legal during a signing-secret roll, and any one matching is
    // acceptance.
    let t = null;
    const v1 = [];
    for (const part of opts.header.split(",")) {
      const eq = part.indexOf("=");
      if (eq < 1) continue;
      const k = part.slice(0, eq).trim();
      const v = part.slice(eq + 1).trim();
      if (k === "t") t = v;
      else if (k === "v1") v1.push(v);
    }
    if (t === null || v1.length === 0) fail("malformed header");

    const ts = Number(t);
    if (!Number.isFinite(ts)) fail("malformed timestamp");
    const tolerance = opts.toleranceMs == null ? 300000 : opts.toleranceMs;
    const now = opts.now == null ? Date.now() : opts.now;
    if (Math.abs(now - ts * 1000) > tolerance) fail("timestamp outside tolerance");

    const payload = typeof opts.body === "string"
      ? opts.body
      : new TextDecoder().decode(opts.body);
    const expected = crypto.hmacSha256(opts.secret, t + "." + payload);
    let ok = false;
    // Compare EVERY candidate — no early exit, so the number of
    // signatures present does not leak through timing either.
    for (const cand of v1) if (safeEqual(expected, cand)) ok = true;
    if (!ok) fail("no matching v1 signature");

    try {
      return JSON.parse(payload);
    } catch (_) {
      fail("body is not JSON");
    }
  },
};

export default stripe;
