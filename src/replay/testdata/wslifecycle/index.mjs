// WS lifecycle edges the offline fold must match the worker (#31):
//   • a frame that returns TERMINAL (or throws) closes the socket and destroys
//     the chain — only a frame that re-holds via next() keeps it open;
//   • a client close BEFORE any frame runs nothing (the chain is lazy);
//   • a throwing frame closes WITHOUT running onDisconnect.
export function onMessage({ next, stream }) {
  const data = request.text;
  if (data === "bye") return { closed: true };          // terminal → socket closes
  if (data === "boom") throw new Error("frame blew up"); // throw → close, no onDisconnect
  stream.write("echo:" + data);
  return next({ n: (request.ctx && request.ctx.n || 0) + 1 }); // re-hold → stays open
}

export function onDisconnect({ kv }) {
  kv.set("disconnected", "1"); // observable iff onDisconnect actually ran
  return { bye: true };
}
