// The WS handoff target: after lobby.mjs's `next("rooms/chat.mjs", {room})`,
// every frame on the connection runs THIS module's onMessage with the
// threaded ctx. The distinct `chat/got` write proves which module ran.
export function onMessage({ kv, next, stream }) {
  const { data } = request.activation;
  const room = request.ctx ? request.ctx.room : "<noctx>";
  kv.set("chat/got", data + ":" + room);
  stream.write("chat:" + data + ":" + room);
  return next({ room });
}
