// http.subscribe (held outbound stream) + the kv-reactive onSubscription side +
// the dirty-marker injection a watched-prefix write triggers (#36, #38).
export default function () {
  if (request.path === "/order") {
    // Two writes under a watched prefix — the platform injects ONE coalesced
    // _sub/dirty/{name} marker per activation, not one per write.
    kv.set("orders/" + request.json.id, "placed");
    kv.set("orders/" + request.json.id + "/status", "new");
    return { placed: true };
  }
  // A held OUTBOUND subscription — fire-and-forget from the connection's view:
  // events fire independently to the `on` module (an unbound cross-module chain),
  // so it does NOT hold this connection (like an unbound http.fetch).
  http.subscribe({
    url: "https://feed.example.com/stream",
    method: "GET",
    headers: { authorization: "Bearer tok" },
    on: "handlers/onFeed.mjs",
    maxChunkBytes: 8192,
  });
  return { subscribed: true };
}

export function onSubscription() {
  const name = request.activation.name;
  kv.set("subs/" + name, "fired"); // subscription chains persist state in kv
  return { fired: name, kind: request.activation.kind };
}
