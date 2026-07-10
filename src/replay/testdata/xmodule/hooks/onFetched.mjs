// A cross-module fetch continuation: reached only as the `on` of the index.mjs
// after.fetch (folded via `.fetch().resolve()`), and also drivable standalone
// via `scenario.fetchResult`. Records the upstream result under the threaded ctx
// key — proving the RIGHT module ran (only this file writes `result/*`).
export default function () {
  const ctx = request.ctx || {};
  kv.set("result/" + ctx.key, JSON.stringify({
    ok: request.ok,
    status: request.status,
    body: request.text,
  }));
  return { done: true, key: ctx.key };
}
