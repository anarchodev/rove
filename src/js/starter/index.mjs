// This is your Loop46 handler. It runs as a pure function of
// (request, kv) — no fetch, no setTimeout, no async IO. All
// outbound effects go through webhook.send / email.send. See
// the docs at https://loop46.me/docs for the full story.
//
// The current request is available on the `request` global
// (request.method, request.path, request.body, request.query).
// Return a string (or an object — we'll JSON.stringify it).
export default function () {
  const count = parseInt(kv.get("starter_hits") ?? "0", 10) + 1;
  kv.set("starter_hits", String(count));
  return {
    message: "Your Loop46 API is live",
    path: request.path,
    hits: count,
  };
}
