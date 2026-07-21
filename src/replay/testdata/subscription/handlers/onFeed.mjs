// The subscription's per-writeback continuation (UNBOUND — a separate chain).
// Each event carries a chunk on request.activation.bytes; the terminal event
// (final:true, status 0) signals end-of-stream. Accumulate across events in kv.
export default function () {
  const a = request.activation;
  if (a.final) {
    kv.set("feed/ended", "status:" + a.status);
    return { ended: true };
  }
  const text = new TextDecoder().decode(a.bytes);
  kv.set("feed/count", String((Number(kv.get("feed/count")) || 0) + 1));
  kv.set("feed/last", text);
  return { got: text };
}
