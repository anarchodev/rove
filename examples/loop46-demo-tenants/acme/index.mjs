// The dispatcher serves a route's DEFAULT export; a named export is
// invisible to it (404 "module export \"default\" not found"). Smokes use
// this root as their deploy-loaded readiness probe, so it must answer 200.
export default function () {
    const count = parseInt(kv.get("hits") ?? "0", 10) + 1;
    kv.set("hits", String(count));
    return "acme hit count: " + count + " (path=" + request.path + ")\n";
}
