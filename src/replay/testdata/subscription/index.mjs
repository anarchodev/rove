// http.subscribe (held outbound stream) + the kv-reactive onSubscription side.
// The inbound handler opens a subscription (recorded with its full option bag);
// onSubscription is the detached kv-react activation the platform fires when a
// watched name changes (driven standalone via scenario.subscriptionFire).
export default function () {
  // A held OUTBOUND subscription — fire-and-forget from the connection's view:
  // events fire independently to the `on` module (an unbound cross-module chain),
  // so it does NOT hold this connection (like an unbound http.fetch). The handler
  // responds terminally; the platform runs the transfer.
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
