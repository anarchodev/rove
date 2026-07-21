// Fetch-recorder parity surface:
//   /        — two concurrent after.fetch with headers + ctx; the returned ids
//              are stored so each resume can correlate request.fetchId back to
//              the logical fetch it armed.
//   /stream  — one stream:true fetch; onChunk records which fields each
//              chunk event carries (prod stamps status/bodyTruncated only on
//              the terminal event; request.ok does not exist).
export default function () {
  if (request.path === "/stream") {
    after.fetch("https://s.example/stream", { stream: true, on: "onChunk" });
    return next();
  }
  const a = after.fetch("https://a.example/x", { headers: { "x-tok": "A" }, ctx: { leg: "a" }, on: "onLeg" });
  const b = after.fetch("https://b.example/y", { headers: { "x-tok": "B" }, ctx: { leg: "b" }, on: "onLeg" });
  kv.set("ids", JSON.stringify({ a, b }));
  return next();
}

export function onLeg() {
  const ids = JSON.parse(kv.get("ids"));
  const leg = request.ctx.leg;
  kv.set("seen/" + leg, JSON.stringify({
    idMatches: request.fetchId === ids[leg],
    pending: request.fetchesPending,
    status: request.status,
    hasOk: request.ok !== undefined, // request.ok is GONE
    done: request.done,
  }));
  return { leg };
}

export function onChunk() {
  if (!request.done) {
    kv.set("chunk/" + request.chunkSeq, JSON.stringify({
      hasStatus: request.status !== undefined,
      hasOk: request.ok !== undefined,
      hasTruncated: request.bodyTruncated !== undefined,
      pending: request.fetchesPending,
    }));
    kv.set("acc", (kv.get("acc") || "") + request.text);
    return next();
  }
  kv.set("final", JSON.stringify({
    status: request.status,
    hasOk: request.ok !== undefined, // absent even on the terminal event
    truncated: request.bodyTruncated,
    seq: request.chunkSeq,
    pending: request.fetchesPending,
    acc: kv.get("acc") || "",
  }));
  return { streamed: true };
}
