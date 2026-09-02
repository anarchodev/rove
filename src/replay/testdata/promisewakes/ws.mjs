// The iterable flow (docs/architecture/websockets.md): NO onMessage export —
// the default runs once at connection open and consumes frames in place;
// close ends the loop and the handler runs on to its terminal return.
export default async function ({ request, kv, stream }) {
  let n = 0;
  for await (const m of request.messages) {
    n++;
    stream.write("echo:" + n + ":" + m.text);
  }
  kv.set("ws/count", String(n));
  return "";
}
