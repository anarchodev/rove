globalThis.email = {
  send(opts) {
    __rove_check_email_rate();
    if (!opts || typeof opts !== "object")
      throw new TypeError("email.send requires an options object");
    if (typeof opts.key !== "string" || opts.key.length === 0)
      throw new TypeError("email.send: `key` must be a non-empty string");
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
    if (opts.reply_to) body.reply_to = opts.reply_to;
    if (opts.cc) body.cc = Array.isArray(opts.cc) ? opts.cc : [opts.cc];
    if (opts.bcc) body.bcc = Array.isArray(opts.bcc) ? opts.bcc : [opts.bcc];
    const env = {
      url: "https://api.resend.com/emails",
      method: "POST",
      headers: {
        "Authorization": "Bearer " + opts.key,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    };
    if (opts.onResult) env.onResult = opts.onResult;
    if (opts.context !== undefined) env.context = opts.context;
    if (opts.maxAttempts) env.maxAttempts = opts.maxAttempts;
    if (opts.timeout) env.timeout = opts.timeout;
    return webhook.send(env);
  },
};
