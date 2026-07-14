// Exercises the sim's kv guardrails so they can be asserted from _tests/.
// Each `/guards` case captures the thrown error's shape; the `/page-*` routes
// return how many rows a prefix scan yields under the prod page bounds.
const cap = (fn) => {
  try {
    fn();
    return { ok: true };
  } catch (e) {
    return { name: e.constructor.name, code: e.code ?? null, message: e.message };
  }
};

export default function () {
  const p = request.path;
  if (p === "/guards") {
    return {
      objVal: cap(() => kv.set("k", { a: 1 })),
      arrVal: cap(() => kv.set("k", [1, 2])),
      nullVal: cap(() => kv.set("k", null)),
      undefVal: cap(() => kv.set("k", undefined)),
      objKey: cap(() => kv.set({}, "v")),
      reservedSet: cap(() => kv.set("_secret/x", "v")),
      reservedDel: cap(() => kv.delete("_secret/x")),
      shimOk: cap(() => kv.set("_send/owed/abc", "v")), // shim-writable prefix
      custOk: cap(() => kv.set("orders/1", "v")), // ordinary customer key
      numOk: cap(() => kv.set("n", 42)), // number coerces, no throw
      boolOk: cap(() => kv.set("b", true)),
      bigKey: cap(() => kv.set("K".repeat(257), "v")),
      bigVal: cap(() => kv.set("big", "x".repeat((1 << 20) + 1))),
      maxKeyOk: cap(() => kv.set("K".repeat(256), "v")), // boundary: exactly at cap
    };
  }
  if (p === "/page-default") return { n: kv.prefix("orders/").length };
  if (p === "/page-explicit") return { n: kv.prefix("orders/", null, 5).length };
  if (p === "/page-over") return { n: kv.prefix("orders/", null, 5000).length };
  return {};
}
