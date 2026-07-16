// Streaming-activation cross-module hold: the first hop opens the stream
// (`stream.start()` + a frame), arms a kv watch, and parks the chain at
// flows/sink.mjs — the target rides the stream descriptor (not dropped), so
// the kv wake runs the TARGET's onWake. This module's own onWake is a decoy.
export default function () {
  response.status = 200;
  response.headers = { "content-type": "text/event-stream" };
  stream.start();
  stream.write("event: ready\n\n");
  after.kv("job/");
  return next("flows/sink.mjs", { origin: "sse" });
}

export function onWake() {
  kv.set("sse/decoy", "1");
  after.kv("job/");
  return next();
}
