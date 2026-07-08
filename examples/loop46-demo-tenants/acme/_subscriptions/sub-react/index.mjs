// Gap 2.1 exerciser — durable-kv-subscriptions shape. A kv-react
// subscription that fires when anything under `sub-react-in/` changes.
// The fire is a coalesced LEVEL trigger: the payload names only the
// dirty prefix (`request.activation.source = {kind:"kv", prefix}`),
// never a key/op — N writes coalesce into ≥1 fire — so the handler
// reads current committed state under the prefix and reconciles: one
// `sub-react-out/<tail>` marker per present row. At-least-once: a
// redundant re-fire re-reads and rewrites the same values.
export function onSubscription() {
    const a = request.activation;
    const rows = kv.prefix(a.source.prefix, "", 100);
    for (const r of rows) {
        const tail = r.key.slice(a.source.prefix.length);
        kv.set("sub-react-out/" + tail, r.value);
    }
    return { status: 200 };
}
