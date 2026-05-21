// Gap 2.1 Phase E exerciser. A kv-react subscription that fires
// on writes under `sub-react-in/`. The handler reads the source
// payload (`request.activation.source = {kind:"kv",key,op}`) and
// writes a marker to `sub-react-out/<key-tail>` so the smoke can
// verify the chain origin fired (and fired exactly once on the
// leader, not duplicated across follower nodes).
export default function () {
    const a = request.activation;
    if (a.kind !== "subscription_fire") {
        // This handler is fire-only — an inbound HTTP request would
        // reach the tenant's index.mjs, not this module.
        return { status: 500, body: "unexpected activation" };
    }
    if (a.source.kind !== "kv") {
        return { status: 500, body: "expected kv source" };
    }
    const tail = a.source.key.slice("sub-react-in/".length);
    const value = kv.get(a.source.key) ?? "(absent)";
    kv.set("sub-react-out/" + tail, `${a.source.op}:${value}`);
    return { status: 200 };
}
