// A WS handler that reads the inbound frame via request.text / browser.message()
// — the canonical agent-SDK pattern. The frame text must be readable as
// request.text regardless of opcode (the runtime browser.message() contract); a
// binary frame's bytes read back via request.bytes. onMessage records what it
// saw and replies, threading a per-connection count.
export function onMessage() {
  const count = (request.ctx.count || 0) + 1;
  // A binary frame carries raw bytes; a text frame carries JSON.
  const a = request.activation;
  if (a.opcode === 2) {
    kv.set("ws/bytes", String(request.bytes.length));
    stream.write("bin:" + request.bytes.length);
    return next({ count });
  }
  const msg = browser.message(); // parses request.text as JSON
  if (!msg) { stream.write("unparseable"); return next({ count }); }
  kv.set("ws/last", JSON.stringify({ t: msg.t, goal: msg.goal, n: count }));
  stream.write(JSON.stringify({ ok: true, echoedText: request.text }));
  return next({ count });
}
