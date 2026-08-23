// Two concurrently-outstanding after.fetches on ONE held chain. Each result adds
// its amount to a running total and marks its leg seen; the chain terminates only
// once BOTH legs are in. The invariant: the final total is the same regardless of
// which upstream responds first, and each leg is counted exactly once. This is the
// arrival-order-independence property `whenConcurrent` exists to check.
export default function ({ after, next }) {
  after.fetch("https://a.example.com/", { ctx: { amt: 10 }, on: "onResult" });
  after.fetch("https://b.example.com/", { ctx: { amt: 20 }, on: "onResult" });
  return next();
}

export function onResult({ kv, next }) {
  const amt = request.ctx.amt;
  // Idempotent per leg: only apply once even if this leg somehow re-delivers.
  if (kv.get("seen/" + amt) !== "1") {
    const cur = Number(kv.get("total") || "0");
    kv.set("total", String(cur + amt));
    kv.set("seen/" + amt, "1");
  }
  // Terminate once both legs have landed; otherwise re-hold for the other.
  if (kv.get("seen/10") === "1" && kv.get("seen/20") === "1") {
    return { total: Number(kv.get("total")) };
  }
  return next();
}
