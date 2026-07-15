// A handler that holds with the CROSS-MODULE continuation — `next(target, ctx)`
// parks flows/step2.mjs as the chain's module, so every later resume on the
// held connection (timer wake, kv wake, bound fetch result, disconnect)
// re-enters step2, not this file (docs/handler-shape.md §2.1).
// This module's own resume exports are decoys: each writes an `index/*` key
// the test asserts ABSENT — a resume that wrongly re-enters the parent is
// caught by its distinct write, not just its return value.
export default function () {
  response.status = 202;
  after.ms(30_000);
  after.kv("job/");
  after.fetch("https://api.example.com/ping", { method: "GET" });
  return next("flows/step2.mjs", { job: "j1" });
}

export function onWake() {
  kv.set("index/woke", "wrong-module");
  return { wrong: true };
}

export function onFetchResult() {
  kv.set("index/fetched", "wrong-module");
  return { wrong: true };
}

export function onDisconnect() {
  kv.set("index/bye", "wrong-module");
  return { wrong: true };
}
