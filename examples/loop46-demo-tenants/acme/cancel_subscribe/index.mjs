// Helper for the subscription smoke — calls
// http.cancelSubscription({id}) given a query-string id. Separate
// endpoint so the smoke can issue the cancel as its own H2 request
// (no need to thread cancellation through the subscriber chain).
//
//   GET /cancel_subscribe?id=<subscription_id>
export default function () {
    const q = request.query || "";
    let id = null;
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        const k = decodeURIComponent(pair.slice(0, eq));
        const v = decodeURIComponent(pair.slice(eq + 1));
        if (k === "id") id = v;
    }
    if (!id) {
        response.status = 400;
        return "missing ?id=";
    }
    http.cancelSubscription({ id: id });
    response.status = 200;
    return "cancelled";
}
