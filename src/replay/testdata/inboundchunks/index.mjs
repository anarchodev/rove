// A streaming-upload handler (the raw onChunk trust boundary): each chunk
// appends to an in-kv buffer and threads a running count via next({ctx}); the
// terminal chunk responds with the assembled body. request.done marks the last.
export function onChunk({ kv, next }) {
  const seq = request.chunkSeq;
  const prev = (request.ctx && request.ctx.count) || 0;
  const buf = kv.get("upload/buf") || "";
  kv.set("upload/buf", buf + request.text);   // read-your-writes across chunks
  kv.set("upload/lastSeq", String(seq));
  // request.bytes is the raw chunk payload — count total wire bytes across the
  // stream (works for text and binary uploads alike).
  kv.set("upload/bytes", String((Number(kv.get("upload/bytes")) || 0) + request.bytes.length));
  if (request.done) {
    return { assembled: kv.get("upload/buf"), chunks: prev + 1, offset: request.activation.byteOffset, bytes: Number(kv.get("upload/bytes")) };
  }
  return next({ count: prev + 1 });           // re-hold, threading the count
}
