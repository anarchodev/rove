// Arms a bound fetch; the resume reads prod's per-event activation bag
// (globals.zig fetch_chunk arm): fetchId/seq/byteOffset/bytes/final +
// terminal status, with the upstream's headers on the seq-0 event.
export default function () {
  after.fetch("https://upstream.example/data", { on: "onDone" });
  return next();
}

export function onDone() {
  const a = request.activation;
  return JSON.stringify({
    kind: a.kind,
    seq: a.seq,
    byteOffset: a.byteOffset,
    final: a.final,
    status: a.status,
    bytesLen: a.bytes.length,
    headers: a.headers,
  });
}
