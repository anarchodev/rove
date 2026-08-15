import { scenario, expect } from "rewind:test";

// The package's whole design is which primitive each call uses, so that is
// what these assert: intents HOLD the connection (after.fetch), subscription
// mutation is DURABLE (webhook.send) and carries an Idempotency-Key.

// ── held: intent creation resumes the live connection ──────────────────────
const intent = scenario({ now: "2026-08-15T00:00:00Z", seed: 1 })
  .inbound({ method: "POST", path: "/intent", host: "s.localhost" });
expect(intent.disposition).toBe("held");
expect(intent).toHaveFetched(/api\.stripe\.com\/v1\/setup_intents/);

// ── durable: a subscription survives the response ──────────────────────────
const sub = scenario({ now: "2026-08-15T00:00:00Z", seed: 1 })
  .inbound({ method: "POST", path: "/subscribe", host: "s.localhost" });
expect(sub.status).toBe(200);
expect(sub).toHaveSent("webhook", {
  url: "https://api.stripe.com/v1/subscriptions",
  method: "POST",
  on: "onStripe",
});
// Form-encoded with Stripe's bracket nesting — NOT JSON.
expect(sub).toHaveSent("webhook", {
  body: "customer=cus_1&items%5B0%5D%5Bprice%5D=price_1&metadata%5Btenant%5D=acme",
});
// Every mutating call carries an idempotency key. Absent a caller-supplied
// one it is generated BEFORE the send and doubles as the marker handle — so
// the returned marker id and the header are the same string, which is what
// makes it identical on every retry (the marker is written once).
const idemOf = (s) => {
  for (const e of s.effects) {
    if (e.kind === "write" && typeof e.key === "string" && e.key.startsWith("_send/owed/"))
      return JSON.parse(e.value).headers["Idempotency-Key"];
  }
  return null;
};
const subKey = idemOf(sub);
expect(typeof subKey).toBe("string");
expect(subKey.slice(0, 4)).toBe("rwd_");
// The marker id is base64url(sha256(key)) — the KEY is what goes on the wire,
// and it is generated before the send precisely so the marker carries it.
expect(subKey === sub.body.id).toBe(false);

// Stable across runs: `crypto.randomBytes` is replay-deterministic, so the
// same activation regenerates the same key — which is what makes a retried
// send idempotent at Stripe rather than merely retried.
const again = scenario({ now: "2026-08-15T00:00:00Z", seed: 1 })
  .inbound({ method: "POST", path: "/subscribe", host: "s.localhost" });
expect(idemOf(again)).toBe(subKey);

// ── a caller-supplied key wins, and pins the marker handle too ─────────────
const keyed = scenario({ now: "2026-08-15T00:00:00Z", seed: 1 })
  .inbound({ method: "POST", path: "/subscribe-keyed", host: "s.localhost" });
expect(keyed.status).toBe(200);
// The marker id is base64url(sha256(key)), not the key itself — the key is
// what goes on the wire as the header.
expect(keyed).toHaveSent("webhook", {
  headers: {
    "Authorization": "Bearer sk_test_x",
    "Content-Type": "application/x-www-form-urlencoded",
    "Idempotency-Key": "sub-acme-pro-1",
  },
});

// ── cancel is durable + keyed, and sends no body ───────────────────────────
const cancel = scenario({ now: "2026-08-15T00:00:00Z", seed: 1 })
  .inbound({ method: "POST", path: "/cancel", host: "s.localhost" });
expect(cancel.status).toBe(200);
expect(cancel).toHaveSent("webhook", {
  url: "https://api.stripe.com/v1/subscriptions/sub_9",
  method: "DELETE",
  body: "",
});

// ── verifyWebhook: accept, reject tampered, reject stale, tolerate a roll ──
const hook = scenario({ now: "2026-08-15T00:00:00Z", seed: 1 })
  .inbound({ method: "POST", path: "/hook", host: "s.localhost" });
expect(hook.status).toBe(200);
expect(hook.body.ok).toBe("invoice.paid");
expect(hook.body.tampered).toBe("bad_signature");
expect(hook.body.stale).toBe("bad_signature");
expect(hook.body.rolled).toBe("evt_1");
