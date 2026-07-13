// A two-activation checkout handler — the fixture the `rewind test` smoke
// (build.zig `rewind-test-smoke`) exercises through the saga test library.
// Inbound reads a cart, opens a pending order, and fires an upstream charge;
// the charge result (a dependent `fetch_chunk` activation) settles the order.
export default function () {
  const user = request.json.user;
  const cart = JSON.parse(kv.get("cart/" + user) || "{}");
  response.status = 202;
  kv.set("order/" + user, JSON.stringify({ status: "pending", price: cart.price }));
  after.fetch("https://api.stripe.com/charge", {
    method: "POST",
    body: JSON.stringify({ amount: cart.price }),
    ctx: { user },
    on: "onCharge",
  });
  return next({ user });
}

export function onCharge() {
  const user = request.ctx.user;
  if (request.status >= 200 && request.status < 300) {
    kv.set("order/" + user, JSON.stringify({ status: "paid" }));
    email.send({ apiKey: "re_test_key", from: "orders@shop.test", to: user + "@example.com", subject: "Your order is paid" });
    return { ok: true };
  }
  kv.set("order/" + user, JSON.stringify({ status: "failed" }));
  return { ok: false };
}
