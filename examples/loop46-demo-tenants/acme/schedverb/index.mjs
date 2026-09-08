// Smoke helper — exercise the `schedule` verb.
// Query: ?in=<ms>&tag=<str>  → schedule({ kv }, { in: ms }, "schedtarget", { tag }).
// Returns JSON `{ id }`; the fire lands in schedtarget (records the tag).
//
// `schedule` is not ambient — it is the `@rewind/schedule` package, so it
// must be imported and the package staged with the deploy.
import schedule from "@rewind/schedule";

export default function ({ kv }) {
    const q = request.query || "";
    const params = {};
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        params[decodeURIComponent(pair.slice(0, eq))] = decodeURIComponent(pair.slice(eq + 1));
    }
    const inMs = parseInt(params.in || "2000", 10);
    const tag = params.tag || "sched";
    const id = schedule({ kv }, { in: inMs }, "schedtarget", { tag });
    return { id };
}
