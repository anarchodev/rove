// A held, SSE-style handler exercising the after.* connection-wake family:
// it arms a timer + a kv watch and holds the socket, so the timer / kv / client
// -disconnect resumes all fold from this one held activation.
export default function ({ after, next, stream }) {
  const room = request.json.room;
  response.status = 200;
  stream.start();
  after.ms(30_000, { on: "onTimeout" });
  after.kv("msg/" + room + "/", { on: "onMsg" });
  return next({ room, seen: 0 });
}

export function onTimeout({ kv }) {
  kv.set("room/" + request.ctx.room + "/closed", "timeout");
  return { closed: true };
}

export function onMsg({ kv, next }) {
  const room = request.ctx.room;
  const wakes = request.activation.wakes;
  kv.set("room/" + room + "/lastwake", JSON.stringify({ count: wakes.length, prefix: wakes[0].prefix }));
  return next({ room, seen: request.ctx.seen + 1 }); // re-hold (SSE loop)
}

export function onDisconnect({ kv }) {
  kv.set("room/" + request.ctx.room + "/closed", "disconnect");
  return { done: true };
}
