// P-Lift (rove#123) lib #2: `@rewind/email` — a leaf that composes over the
// ambient `webhook` primitive (which stays baked). `EMAIL_PKG` is
// `src/js/globals/email.js` lifted from `globalThis.email = { send }` to an ES
// module: `export function send` + a default export of the object (so a
// consumer's `email.send(…)` reads unchanged); the `webhook.send` call is
// unchanged (packages compose over ambient primitives). The validation error
// messages' quote style is normalized (backticks → single quotes) purely to
// keep this inline fixture free of template-literal escaping — the code is
// otherwise faithful. Verified: the lifted email resolves, and `email.send`
// still lands a durable `_send/owed` marker via the ambient `webhook`. Canonical
// source moves to rewind-apps `packages/email/` at the publish piece.
import { scenario, expect } from "rewind:test";

const EMAIL_PKG = `
export function send(opts) {
  if (!opts || typeof opts !== "object")
    throw new TypeError("email.send requires an options object");
  for (const pair of [["key", "apiKey"], ["reply_to", "replyTo"], ["max_attempts", "maxAttempts"], ["timeout_ms", "timeoutMs"]]) {
    if (pair[0] in opts) throw new TypeError("email.send: option '" + pair[0] + "' was renamed — use '" + pair[1] + "'");
  }
  if (typeof opts.apiKey !== "string" || opts.apiKey.length === 0)
    throw new TypeError("email.send: 'apiKey' must be a non-empty string");
  if (typeof opts.from !== "string")
    throw new TypeError("email.send: 'from' must be a string");
  if (typeof opts.subject !== "string")
    throw new TypeError("email.send: 'subject' must be a string");
  if (!opts.to)
    throw new TypeError("email.send: 'to' is required");
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
  if (opts.on) env.on = opts.on;
  if (opts.ctx !== undefined) env.ctx = opts.ctx;
  if (opts.maxAttempts) env.maxAttempts = opts.maxAttempts;
  if (opts.timeoutMs != null) env.timeoutMs = opts.timeoutMs;
  return webhook.send(env.url, env);
}
const email = { send };
export default email;
`;

const HASH = "2b".repeat(32);
const r = scenario({
  packages: [{ spec: "@rewind/email", version: "1.0.0", pkg_hash: HASH, files: { "index.mjs": EMAIL_PKG } }],
  app_imports: { "@rewind/email": HASH },
}).inbound({ method: "GET", path: "/" });

expect(r.status).toBe(200);
// email.send returned the webhook marker id.
expect(typeof r.body.id).toBe("string");
// The lifted email composed over the ambient webhook: a durable Resend send.
expect(r).toHaveSent("email", { subject: "Welcome" });
expect(r).toHaveSent("webhook", { url: "https://api.resend.com/emails" });
