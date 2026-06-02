// Handler-surface Phase 5 smoke helper — exercise the `schedule` verb.
// Query: ?in=<ms>&tag=<str>  → schedule({ in: ms }, "schedtarget", { tag }).
// Returns JSON `{ id }`; the fire lands in schedtarget (records the tag).
export default function () {
    const q = request.query || "";
    const params = {};
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        params[decodeURIComponent(pair.slice(0, eq))] = decodeURIComponent(pair.slice(eq + 1));
    }
    const inMs = parseInt(params.in || "2000", 10);
    const tag = params.tag || "sched";
    const id = schedule({ in: inMs }, "schedtarget", { tag });
    return { id };
}
