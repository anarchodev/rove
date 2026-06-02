// Handler-surface Phase 5 smoke helper — exercise the recurring `cron`
// verb. Query: ?spec=<crontab>&tag=<str> → cron(spec, "schedtarget",
// { tag }). Returns JSON `{ key }` (the stable registration id); each
// occurrence fires schedtarget (records the tag) and re-arms.
export default function () {
    const q = request.query || "";
    const params = {};
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        params[decodeURIComponent(pair.slice(0, eq))] = decodeURIComponent(pair.slice(eq + 1));
    }
    const spec = params.spec || "* * * * *";
    const tag = params.tag || "cron";
    const key = cron(spec, "schedtarget", { tag });
    return { key };
}
