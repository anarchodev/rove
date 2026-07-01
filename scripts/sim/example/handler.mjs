// A saga: inbound fans out TWO concurrent fetches (charge + ledger), threading
// a distinct `ctx` to each; each resume writes its result to kv. Exercises the
// driver's chaining, ctx threading, concurrent-fetch interleaving, and kv fold.
// The inbound frame stays read-only (no kv writes) so the fetches can bind.
//
// Response model (handler-shape §2.1): the HEAD (status/headers/cookies) is the
// ambient `response` global; the RETURN value is the body (terminal) or
// `next()` (hold). So we set `response.status` and return a terminal body.

export default function () {
  const cart = JSON.parse(request.body || "{}");
  on.fetch("https://api.stripe.com/v1/charges",
    { method: "POST", body: { amount: cart.total }, ctx: { cartId: cart.id } },
    { to: "onCharge" });
  on.fetch("https://ledger.internal/append",
    { method: "POST", body: { cartId: cart.id }, ctx: { cartId: cart.id } },
    { to: "onLedger" });
  response.status = 202;             // head: accepted
  return "accepted";                 // terminal body → commit + close
}

// A fetch result's body arrives as bytes (a `fetch_chunk` is a binary
// activation), so decode before parsing — real handler code.
const body = () => JSON.parse(new TextDecoder().decode(request.body) || "{}");

export function onCharge() {
  const ctx = request.ctx, charge = body();
  kv.set(`charge/${ctx.cartId}`, JSON.stringify({ status: request.status, id: charge.id }));
  return "";                         // terminal (head stays 200)
}

export function onLedger() {
  const ctx = request.ctx, led = body();
  kv.set(`ledger/${ctx.cartId}`, JSON.stringify({ seq: led.seq }));
  return "";
}
