// `email.send` — transactional email via Resend, layered on
// `webhook.send` (which composes durable outbound HTTP from `kv`
// markers + the internal fetch primitive + durable scheduled wakes —
// see `webhook.js`). Per-instance rate-limited.

/**
 * Transactional email through Resend.
 *
 * @namespace email
 */
globalThis.email = {
  /**
   * Send an email. Builds the Resend API request and dispatches it
   * via {@link webhook.send} (durable; fires after the handler
   * commits).
   *
   * @param {object} opts
   * @param {string} opts.apiKey - Resend API key (sent as
   *   `Authorization: Bearer`). Named apiKey — `key` means an
   *   idempotency key everywhere else on this surface.
   * @param {string} opts.from - Sender address.
   * @param {string|string[]} opts.to - Recipient(s).
   * @param {string} opts.subject - Subject line.
   * @param {string} [opts.text] - Plain-text body.
   * @param {string} [opts.html] - HTML body.
   * @param {string} [opts.replyTo] - Reply-To address.
   * @param {string|string[]} [opts.cc] - CC recipient(s).
   * @param {string|string[]} [opts.bcc] - BCC recipient(s).
   * @param {string} [opts.on] - Result handler module in this tenant
   *   (forwarded to `webhook.send`).
   * @param {*} [opts.ctx] - Echoed back as `request.ctx` on the result
   *   event.
   * @param {number} [opts.maxAttempts] - Override the built-in
   *   webhook.send retry budget (default 5).
   * @param {number} [opts.timeoutMs] - Per-attempt timeout.
   * @returns {string} The marker id from {@link webhook.send}.
   * @throws {Error} `code:"rate_limited"` when the per-instance outbound
   *   rate limit is exhausted (enforced by the platform at the outbound
   *   boundary — `email.send`, `webhook.send`, and `fetch` share one
   *   per-tenant outbound budget).
   * @throws {TypeError} On missing/invalid `apiKey`/`from`/`subject`/`to`.
   *
   * @example
   * const apiKey = kv.get("secret/resend") ?? "re_dev_placeholder";
   * const user = { email: "ada@example.com", name: "Ada" };
   * email.send({
   *   apiKey,
   *   from: "noreply@acme.dev",
   *   to: user.email,
   *   subject: "Welcome",
   *   html: `<h1>Hi ${user.name}</h1>`,
   * });
   */
  send(opts) {
    if (!opts || typeof opts !== "object")
      throw new TypeError("email.send requires an options object");
    for (const pair of [["key", "apiKey"], ["reply_to", "replyTo"], ["max_attempts", "maxAttempts"], ["timeout_ms", "timeoutMs"]]) {
      if (pair[0] in opts) throw new TypeError("email.send: option `" + pair[0] + "` was renamed — use `" + pair[1] + "`");
    }
    if (typeof opts.apiKey !== "string" || opts.apiKey.length === 0)
      throw new TypeError("email.send: `apiKey` must be a non-empty string");
    if (typeof opts.from !== "string")
      throw new TypeError("email.send: `from` must be a string");
    if (typeof opts.subject !== "string")
      throw new TypeError("email.send: `subject` must be a string");
    if (!opts.to)
      throw new TypeError("email.send: `to` is required");
    const body = {
      from: opts.from,
      to: Array.isArray(opts.to) ? opts.to : [opts.to],
      subject: opts.subject,
    };
    if (opts.text) body.text = opts.text;
    if (opts.html) body.html = opts.html;
    if (opts.replyTo) body.reply_to = opts.replyTo;
    if (opts.cc) body.cc = Array.isArray(opts.cc) ? opts.cc : [opts.cc];
    if (opts.bcc) body.bcc = Array.isArray(opts.bcc) ? opts.bcc : [opts.bcc];
    const env = {
      url: "https://api.resend.com/emails",
      method: "POST",
      headers: {
        "Authorization": "Bearer " + opts.apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    };
    // NOTE: email's `to` is the RECIPIENT — the callback key is `on`.
    if (opts.on) env.on = opts.on;
    if (opts.ctx !== undefined) env.ctx = opts.ctx;
    if (opts.maxAttempts) env.maxAttempts = opts.maxAttempts;
    if (opts.timeoutMs != null) env.timeoutMs = opts.timeoutMs;
    return webhook.send(env.url, env);
  },
};
