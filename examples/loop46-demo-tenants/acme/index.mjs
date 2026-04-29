export function handler() {
    const count = parseInt(kv.get("hits") ?? "0", 10) + 1;
    kv.set("hits", String(count));
    return "acme hit count: " + count + " (path=" + request.path + ")\n";
}
