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
  // Every shim-writable prefix on its own route. The engines each enforce
  // this allowlist from their own copy of one list — the worker from
  // `rove-reserved`, the replay prelude from a fragment generated off it —
  // and those copies drifted once (rove#499). Kept separate from `/guards`
  // so the cross-engine comparison covers exactly this and is not carrying
  // the rest of the guard matrix with it. Deliberately ALLOWLIST-ONLY: a
  // refused prefix belongs here too, but the browser replay arena does not
  // enforce the reserved-key rule at all (its prelude is generated
  // separately from this one) — tracked apart from the drift this case
  // exists for, so one open gap does not keep the other unproven.
  if (p === "/prefixes") {
    return {
      send: cap(() => kv.set("_send/owed/abc", "v")),
      export_: cap(() => kv.set("_export/job-1", "v")),
      blob: cap(() => kv.set("_blob/recipe/s/meta", "v")),
      sched: cap(() => kv.set("_sched/by_id/s", "v")),
      seg: cap(() => kv.set("_seg/idx/1", "v")),
      oidc: cap(() => kv.set("_oidc/session/s", "v")),
      rp: cap(() => kv.set("_rp/sess/s", "v")),
      // The other side of the allowlist: a reserved prefix that is NOT on it
      // must be refused, by the same code and message, in every engine. This
      // probe is why the case exists — the browser arena used to allow it
      // (rove#502), which is replay being more permissive than prod.
      reserved: cap(() => kv.set("_secret/x", "v")),
      // …and the size caps, which came from the same shared file.
      bigKey: cap(() => kv.set("K".repeat(257), "v")),
    };
  }
  if (p === "/page-default") return { n: kv.prefix("orders/").length };
  if (p === "/page-explicit") return { n: kv.prefix("orders/", null, 5).length };
  if (p === "/page-over") return { n: kv.prefix("orders/", null, 5000).length };
  return {};
}
