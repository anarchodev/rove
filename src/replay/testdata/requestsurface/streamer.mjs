// Streams an upstream fetch chunk by chunk, recording each event's
// activation-bag fields (seq/byteOffset/final + seq-0 headers) so the test
// can assert the per-event bag matches prod's fetch_chunk arm.
export default function () {
  after.fetch("http://upstream.example/s", { stream: true, maxChunkBytes: 4, on: "onChunk" });
  return next();
}

export function onChunk() {
  const a = request.activation;
  kv.set("chunk/" + a.seq, JSON.stringify({
    off: a.byteOffset,
    final: a.final,
    hasHeaders: a.headers !== undefined,
  }));
  if (!request.done) return next();
  return kv.get("chunk/0") + "|" + kv.get("chunk/1") + "|" + kv.get("chunk/2");
}
