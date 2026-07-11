export default function () { return "ready"; }

export function onMessage() {
  const { data } = request.activation;
  if (data.startsWith("fetch:")) {
    // READ-ONLY frame: on.fetch binds to the held chain and the result
    // resumes onUpstream over this socket.
    after.fetch(data.slice(6), { method: "GET", on: "onUpstream" });
    return next();
  }
  if (data.startsWith("fetchctx:")) {
    // issue #3 / §4.14: the fetch carries NO ctx, connection state threads via
    // next({tag}). On the resume request.ctx falls back to the connection's
    // next() ctx (the same value on WS and HTTP — the fix).
    after.fetch(data.slice(9), { method: "GET", on: "onUpstreamCtx" });
    return next({ tag: "chain-42" });
  }
  if (data.startsWith("fetchboth:")) {
    // The fetch carries its OWN ctx → request.ctx is the fetch's, NOT the
    // connection's next({tag}) — the fetch's ctx wins when present.
    after.fetch(data.slice(10), { method: "GET", on: "onUpstreamBoth", ctx: { f: "FF" } });
    return next({ tag: "CC" });
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

export function onUpstreamCtx() {
  if (!request.done) return next();
  // No fetch ctx → request.ctx = the connection's next({tag}).
  stream.write("ctx:" + (request.ctx && request.ctx.tag));
  return next();
}

export function onUpstreamBoth() {
  if (!request.done) return next();
  // Fetch carried a ctx → request.ctx is the fetch's ({f}), not the chain's.
  stream.write("ctx:" + (request.ctx && request.ctx.f));
  return next();
}
