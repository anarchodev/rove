// Read a single kv key, return its value as text/plain. Body shape:
//   `?key=<keyname>` (URL-encoded). Missing key → 404. Used by
// smokes to verify writes from other paths committed.
export default function () {
    const q = request.query || "";
    let key = null;
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        if (decodeURIComponent(pair.slice(0, eq)) === "key") {
            key = decodeURIComponent(pair.slice(eq + 1));
            break;
        }
    }
    if (!key) {
        response.status = 400;
        return "missing ?key=…\n";
    }
    const v = kv.get(key);
    if (v == null) {
        response.status = 404;
        return "no such key\n";
    }
    return v;
}
