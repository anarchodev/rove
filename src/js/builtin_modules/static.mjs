// __system/static — engine-fired deploy-static streamer ("onStatic").
//
// On an LRU MISS for a stable static path (/app.js, /index.html, an image…),
// the engine resolves the friendly path → content hash and dispatches HERE,
// forcing this module's route with {hash, ct} as the route QUERY (it never
// touches tenant kv — the manifest stays engine-internal). We stream the blob
// from the tenant's OWN file-blobs (the `rove-static.internal` door) straight
// to the held connection over the standard on.fetch({stream}) → stream.write()
// pipeline: no worker buffering, and non-blocking (the S3 read runs on the
// FetchPool thread, off the dispatch loop).
//
// Engine-only: the `__system/` prefix is reserved + middleware-skipped, and the
// hash is engine-injected (never customer-supplied) — a tenant cannot reach or
// spoof this module.
//
// LRU HITS never reach here — the engine serves those inline natively. This is
// the cold / oversized-asset path only. Crucially the bytes are served at the
// SAME-ORIGIN friendly path (no 302 to /_assets), so a JS module's relative
// imports (`./api.js`) resolve correctly.
//
// IMPORTANT ordering: committing the response head (stream.start) in the SAME
// activation that issues the bound fetch makes the fetch inert. So the default
// export only ISSUES the fetch (threading {hash,ct} forward via opts.ctx); the
// head is committed in `onChunk` (the first chunk), where response.headers are
// rebuilt from request.ctx.

function headersFor(c) {
  return {
    "content-type": c.ct || "application/octet-stream",
    // Strong ETag = the content hash. The friendly path is mutable per deploy,
    // so revalidate every load; the ETag makes that a cheap 304 (and lets a CF
    // edge cache it). 304-on-match is handled natively before we get here.
    "etag": '"' + c.hash + '"',
    "cache-control": "public, max-age=0, must-revalidate",
  };
}

export default function () {
  const c = JSON.parse(request.query || "{}");
  // HEAD: headers only, never a body (RFC 9110 §9.3.2). A plain terminal
  // response (no bound fetch), so committing here is fine.
  if (request.method === "HEAD") {
    response.status = 200;
    response.headers = headersFor(c);
    return "";
  }
  // GET: issue the bound streaming read and DO NOT commit the response here.
  // `opts.ctx` threads {hash,ct} to each onChunk as request.ctx.
  after.fetch(
    "http://rove-static.internal/" + c.hash,
    { method: "GET", stream: true, maxChunkBytes: 256 * 1024, ctx: c },
    { on: "onChunk" },
  );
  return next();
}

// Each upstream chunk from the file-blobs read arrives here. The first chunk
// commits the response head (with the content-type from request.ctx); every
// chunk relays its bytes. The final event closes the held connection.
export function onChunk() {
  const a = request.activation;
  // Honor the upstream read's outcome on the terminal event. A failed
  // (missing blob / S3 error / timeout) or truncated file-blobs read
  // must NOT be served — and strong-ETag cached — as a well-formed 200.
  // Every sibling {on} builtin gates on request.ok; static must too.
  // (`ok`/`status`/`bodyTruncated` are only set on the final event.)
  if (a.final && (!a.ok || a.status < 200 || a.status >= 300 || a.bodyTruncated)) {
    if (a.seq === 0) {
      // First-and-final chunk (e.g. a missing blob): nothing streamed,
      // the response head isn't committed yet — send a clean 502.
      response.status = 502;
      return "static asset read failed (status " + a.status + ")";
    }
    // The head was committed on an earlier chunk, so the status can't
    // change; abort the held stream (throw → RST) so the client sees an
    // incomplete transfer rather than a well-formed empty/partial 200.
    throw new Error(
      "static asset read failed mid-stream (status " + a.status +
      ", truncated " + a.bodyTruncated + ")");
  }
  response.status = 200;
  response.headers = headersFor(request.ctx || {});
  stream.start(); // commits the head with the headers above (idempotent after first)
  if (a.bytes && a.bytes.length) stream.write(a.bytes);
  if (a.final) return ""; // close the held connection
  return next();
}
