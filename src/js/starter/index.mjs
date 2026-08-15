// This is your rewind handler. It runs as a pure function of
// (request, kv) — no ambient IO, no timers, nothing to await.
// Outbound effects are DECLARED and run after the handler
// returns: `after.fetch`, `webhook.send`, `email.send`. See the
// docs at https://docs.rewindjs.com for the full story.
//
// The current request is available on the `request` global
// (request.method, request.path, request.text, request.query).
// Return a string (or an object — we'll JSON.stringify it).
export default function () {
  const count = parseInt(kv.get("starter_hits") ?? "0", 10) + 1;
  kv.set("starter_hits", String(count));
  return {
    message: "Your rewind API is live",
    path: request.path,
    hits: count,
  };
}
