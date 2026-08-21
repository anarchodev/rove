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
  // `request.tag` validation. Kept beside the kv prefixes because it is the
  // same question — one rule, several engines — and the answer drifted the
  // same way: this had FOUR hand-copies and they disagreed about the
  // tag-count message (rove#505).
  if (p === "/tags") {
    const out = {
      ok: cap(() => request.tag("order", "123")),
      retag: cap(() => request.tag("order", "456")),
      badKeyChars: cap(() => request.tag("Order-ID", "1")),
      reservedKey: cap(() => request.tag("_internal", "1")),
      longKey: cap(() => request.tag("k".repeat(33), "1")),
      longVal: cap(() => request.tag("v", "x".repeat(65))),
      ctrlVal: cap(() => request.tag("c", "a\u0001b")),
      notString: cap(() => request.tag("n", 5)),
    };
    // Capacity: fill to the cap, then one more. The refusal message is the
    // one that differed between engines, so it has to be compared.
    out.fill2 = cap(() => request.tag("aa", "1"));
    out.fill3 = cap(() => request.tag("bb", "1"));
    out.fill4 = cap(() => request.tag("cc", "1"));
    out.overflow = cap(() => request.tag("dd", "1"));
    return out;
  }
  // A customer prefix READ that every engine can run identically: the prod
  // conformance adapter deploys sources and fires requests — it has no
  // kv-seed channel — so the rows are written by the handler itself. This is
  // the route that executes the prefix element of the interaction digest
  // cross-engine (`p <prefix> 1 <count> <rowsfold>`): the worker folds it in
  // globals_kv.zig foldPrefix, the sim in the epilogue kv wrapper, the arena
  // in request-replay.mjs — three call sites of one accumulator, and this is
  // what proves they agree.
  if (p === "/page-rw") {
    kv.set("pagerw/1", "a");
    kv.set("pagerw/2", "bb");
    kv.set("pagerw/3", "ccc");
    const rows = kv.prefix("pagerw/");
    return { n: rows.length, keys: rows.map((r) => r.key) };
  }
  // The engine-only keyspace: a handler cannot SEE it, which is what lets
  // its writers stay engine writes with no activation behind them. Hidden
  // rather than refused — a refusal would disclose the namespace it protects,
  // and a read of a keyspace that is not the tenant's is honestly empty.
  //
  // `span` is the probe that matters. The world seeds three hidden rows ahead
  // of the visible ones, so at a page size of 2 the first two pages are
  // ENTIRELY hidden. An engine that filters a single page hands back an empty
  // array, and the documented paging idiom stops on an empty page — so a
  // tenant with a few hundred meter rows would silently lose everything
  // sorted after them. Every engine must refill instead.
  if (p === "/hidden") {
    return {
      usageGet: kv.get("_usage/blob/aaa"),
      keysGet: kv.get("_keys/next_slot"),
      configGet: kv.get("_config/mail.json"),
      custGet: kv.get("users/1"),
      hiddenScan: kv.prefix("_usage/").length,
      span: kv.prefix("", "", 2).map((r) => r.key),
    };
  }
  if (p === "/page-default") return { n: kv.prefix("orders/").length };
  if (p === "/page-explicit") return { n: kv.prefix("orders/", null, 5).length };
  if (p === "/page-over") return { n: kv.prefix("orders/", null, 5000).length };
  return {};
}
