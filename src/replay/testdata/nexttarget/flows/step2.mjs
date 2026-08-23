// The cross-module continuation target: index.mjs holds with
// `next("flows/step2.mjs", { job })`, parking THIS module as the chain's, so
// its resumes land on these exports. Each writes a distinct `step2/*` key
// carrying the threaded ctx — the write proves which module ran.
export function onWake({ kv }) {
  const kind = request.activation.wakes[0].kind; // "timer" | "kv"
  kv.set("step2/woke-" + kind, JSON.stringify({ ctx: request.ctx }));
  return { done: kind };
}

export function onFetchResult({ kv }) {
  kv.set("step2/fetched", JSON.stringify({
    status: request.status,
    body: request.text,
    ctx: request.ctx,
  }));
  return { done: "fetch" };
}

export function onDisconnect({ kv }) {
  kv.set("step2/bye", JSON.stringify({ ctx: request.ctx }));
  return { done: "bye" };
}
