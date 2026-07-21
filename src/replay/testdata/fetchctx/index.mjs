// The fetch-resume ctx override (decisions.md §4.14), regression guard:
// on a held WS chain, `request.ctx` on an after.fetch resume is the
// fetch's OWN ctx if it carried one, else the chain's parked next({ctx}) — one
// rule, and the same as HTTP. (Before the fix the sim always used the fetch's
// ctx while prod-WS always used the chain ctx; they disagreed.)
export function onMessage() {
  const msg = browser.message() || {};
  if (msg.t === "noctx") {
    after.fetch("https://x.test/y", { on: "onResp" }); // NO fetch ctx
    return next({ tag: "chain-42" });                  // → resume reads this
  }
  // "withctx": the fetch carries its own ctx → it wins over the chain's next().
  after.fetch("https://x.test/y", { on: "onResp", ctx: { f: "FF" } });
  return next({ tag: "CC" });
}

export function onResp() {
  kv.set("saw", JSON.stringify(request.ctx));
  return "ok";
}
