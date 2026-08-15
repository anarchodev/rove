// A consumer of @rewind/stripe. Exercises the split the package is built
// around: intent creation is HELD (after.fetch on the live connection, because
// Elements needs the client_secret in this response) while subscription
// mutation is DURABLE (webhook.send, because money moves and the answer can
// arrive later). Also drives verifyWebhook, which is pure.
import stripe from "@rewind/stripe";

const sk = () => stripe.client({ apiKey: "sk_test_x", on: "onStripe" });

export default function () {
  if (request.path === "/intent") {
    sk().setupIntents.create({ customer: "cus_1" }, { on: "onIntent" });
    return next();                      // held — the resume answers the browser
  }
  if (request.path === "/subscribe") {
    return { id: sk().subscriptions.create({
      customer: "cus_1",
      items: [{ price: "price_1" }],
      metadata: { tenant: "acme" },
    }, { ctx: { plan: "pro" } }) };
  }
  if (request.path === "/subscribe-keyed") {
    return { id: sk().subscriptions.create(
      { customer: "cus_1", items: [{ price: "price_1" }] },
      { idempotencyKey: "sub-acme-pro-1" }) };
  }
  if (request.path === "/cancel") {
    return { id: sk().subscriptions.cancel("sub_9", { idempotencyKey: "cancel-1" }) };
  }
  // verifyWebhook — pure, so it runs inline. The body and signature are
  // fixtures computed under the same secret the handler passes.
  if (request.path === "/hook") {
    const secret = "whsec_test";
    const body = '{"type":"invoice.paid","id":"evt_1"}';
    const t = "1782000000";
    const good = crypto.hmacSha256(secret, t + "." + body);
    const header = "t=" + t + ",v1=" + good;
    const now = Number(t) * 1000 + 1000;   // 1s after signing
    const out = {};
    out.ok = stripe.verifyWebhook({ secret, header, body, now }).type;
    // wrong signature → bad_signature
    try {
      stripe.verifyWebhook({ secret, header: "t=" + t + ",v1=" + "0".repeat(64), body, now });
      out.tampered = "accepted";
    } catch (e) { out.tampered = e.code; }
    // stale timestamp → bad_signature, even though the digest is valid
    try {
      stripe.verifyWebhook({ secret, header, body, now: now + 600000 });
      out.stale = "accepted";
    } catch (e) { out.stale = e.code; }
    // a second v1 (secret roll) still verifies
    const rolled = "t=" + t + ",v1=" + "0".repeat(64) + ",v1=" + good;
    out.rolled = stripe.verifyWebhook({ secret, header: rolled, body, now }).id;
    return out;
  }
  return { ok: true };
}

export function onIntent() {
  // The resume that answers the held connection. The client_secret is read
  // from the recorded upstream response, not synthesized here.
  return { secret: (request.json && request.json.client_secret) || null };
}
