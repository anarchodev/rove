export function fire(url, tag) {
    const id = webhook.send(url, {
        method: "POST",
        body: "ping",
        headers: { "content-type": "text/plain" },
        on: "cbresult",
        ctx: { tag: tag },
        maxAttempts: 2,
    });
    kv.set("cb/last_fire", id);
    return { id: id };
}
