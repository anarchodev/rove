// WS module handoff: the join frame re-aims the chain to rooms/chat.mjs via
// the cross-module continuation — every LATER frame on this connection
// dispatches there (the one next() semantic; docs/handler-shape.md §2.1).
// The post-join arm is a decoy: a frame that wrongly re-enters the lobby
// writes `lobby/decoy`, which the test asserts absent.
export function onMessage() {
  const { data } = request.activation;
  if (data === "join") {
    kv.set("lobby/joined", "1");
    stream.write("lobby:ok");
    return next("rooms/chat.mjs", { room: "r1" });
  }
  kv.set("lobby/decoy", data);
  stream.write("lobby:decoy:" + data);
  return next();
}
