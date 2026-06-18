// __system/static — engine-fired deploy-static streamer ("onStatic").
//
// On an LRU MISS for a stable static path (/app.js, /index.html, an image…),
// the engine resolves the friendly path → content hash and dispatches HERE
// with the hash injected via request.ctx {hash, content_type, etag}. We stream
// the blob from the tenant's OWN file-blobs (the `rove-static.internal` door)
// straight to the held connection over the standard on.fetch({stream}) →
// stream.write() pipeline: no worker buffering, and non-blocking (the S3 read
// runs on the FetchPool thread, off the dispatch loop).
//
// Engine-only: the `__system/` prefix is reserved + middleware-skipped, and the
// hash is engine-injected (never customer-supplied) — a tenant cannot reach or
// spoof this module.
//
// LRU HITS never reach here — the engine serves those inline natively. This is
// the cold / oversized-asset path only. Crucially the bytes are served at the
// SAME-ORIGIN friendly path (no 302 to /_assets), so a JS module's relative
// imports (`./api.js`) resolve correctly.

export default function () {
  const ctx = request.ctx || {};
  response.status = 200;
  response.headers = {
    "content-type": ctx.content_type || "application/octet-stream",
    // Strong ETag = the content hash. The friendly path is mutable per deploy,
    // so revalidate every load; the ETag makes that a cheap 304 (and lets a CF
    // edge cache it). 304-on-match is handled natively before we get here.
    "etag": ctx.etag,
    "cache-control": "public, max-age=0, must-revalidate",
  };
  // HEAD: headers only, never a body (RFC 9110 §9.3.2).
  if (request.method === "HEAD") return "";
  stream.start();
  on.fetch(
    "http://rove-static.internal/" + ctx.hash,
    { method: "GET", stream: true, max_response_chunk_bytes: 256 * 1024 },
    { to: "onChunk" },
  );
  return next();
}

// Each upstream chunk from the file-blobs read arrives here; relay it to the
// held connection. The final event closes the stream.
export function onChunk() {
  const a = request.activation;
  if (a.bytes && a.bytes.length) stream.write(a.bytes);
  if (a.final) return ""; // close the held connection
  return next();
}
