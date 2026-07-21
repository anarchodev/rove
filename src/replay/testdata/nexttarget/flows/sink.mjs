// The streaming handoff target: sse.mjs held with `next("flows/sink.mjs",
// {origin})`, so its kv wake runs THIS onWake with the threaded ctx.
export function onWake() {
  kv.set("sink/woke", request.ctx ? request.ctx.origin : "<noctx>");
  stream.write("event: sink\n\n");
  after.kv("job/");
  return next({ origin: "sink" });
}
