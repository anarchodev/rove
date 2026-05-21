// Gap 2.2 §9.4 overflow smoke helper — fires N kv writes against
// the `overflow/` prefix in ONE handler invocation (a single
// writeset → a single apply-thread broadcast → one drain into the
// `PendingWakes` ring on the watching stream → predictable
// `lost_oldest = N - PENDING_WAKES_CAP` if N exceeds CAP).
//
// Body shape: `{ "count": <int> }` (default 50, > CAP=32 so the
// overflow signal fires). Response: 204.
export default function () {
    const body = JSON.parse(request.body || "{}");
    const count = body.count ?? 50;
    for (let i = 0; i < count; i++) {
        kv.set("overflow/k" + i, "v" + i);
    }
    response.status = 204;
    return "";
}
