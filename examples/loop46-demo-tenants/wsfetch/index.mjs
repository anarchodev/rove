export default function () { return "ready"; }

export function onMessage() {
  const { data } = request.activation;
  if (data.startsWith("fetch:")) {
    // READ-ONLY frame: on.fetch binds to the held chain and the result
    // resumes onUpstream over this socket.
    after.fetch(data.slice(6), { method: "GET", on: "onUpstream" });
    return next();
  }
  stream.write("echo:" + data);
  return next();
}

export function onUpstream() {
  // Bound-fetch surface: bytes on request.body, status/done at top level.
  if (!request.done) return next();
  const body = request.text || "";
  stream.write("fetched:" + request.status + ":" + body);
  return next();
}
