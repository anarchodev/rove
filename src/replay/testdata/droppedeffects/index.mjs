// Connection-scoped effect disposition fixture. The same handler arms the
// full `after.*` trio, then either HOLDS the socket (`mode: "hold"` →
// `next()`, the wakes arm) or returns a terminal body (prod discards every
// connection-scoped effect at the success seam — they must not satisfy
// matchers offline either).
export default function ({ after, kv, next }) {
  const mode = request.json.mode;
  after.fetch("https://api.example.test/poll", { on: "onPoll", ctx: { mode } });
  after.ms(5000, { on: "onTick" });
  after.kv("jobs/", { on: "onJob" });
  kv.set("visited", "1"); // an ordinary write — survives either way
  if (mode === "hold") return next({ waiting: true });
  return { ok: true };
}

export function onPoll() {
  return { polled: request.status };
}
