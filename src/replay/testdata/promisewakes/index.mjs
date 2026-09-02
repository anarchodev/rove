// The promise flow's HTTP shape (docs/architecture/effects-and-handlers.md,
// the held-request model): await a timer IN PLACE — the handler keeps its
// locals, its request, and the head it sets after the await. Mirrors the
// prod smoke's handler (scripts/smoke/promise_wake_smoke_v2.py) so the sim
// drives the same shape the worker runs.
export default async function ({ request, response, kv, after }) {
  const req = request.text ? request.json : {};
  const tag = req.tag || "t";
  const ms = req.ms || 150;
  const local = "kept";
  kv.set("before/" + tag, String(Date.now()));
  if (req.twice) {
    await after.ms(ms);
    await after.ms(ms);
  } else {
    await after.ms(ms);
  }
  kv.set("after/" + tag, String(Date.now()));
  if (req.throwAfter) throw new Error("boom:" + tag);
  response.status = 201;
  return "woke:" + tag + ":" + local + ":" + request.path;
}
