// A held WebSocket handler: each inbound frame runs onMessage, replies with
// stream.write frames, and threads per-connection state via next({ctx}). The
// upgrade runs no code — the connection starts at the first frame with ctx {}.
export function onMessage({ kv, next, stream }) {
  const count = (request.ctx.count || 0) + 1;
  const msg = request.activation.data; // the inbound frame payload
  if (msg === "ping") {
    stream.write("pong");
  } else {
    stream.write(JSON.stringify({ echo: msg, n: count }));
    kv.set("chat/last", msg);
  }
  return next({ count }); // re-hold, updating the per-connection count
}

export function onDisconnect({ kv }) {
  kv.set("chat/closed", JSON.stringify({ count: request.ctx.count || 0 }));
  return { done: true };
}
