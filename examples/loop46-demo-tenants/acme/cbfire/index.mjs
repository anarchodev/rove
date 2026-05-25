export function fire(url, tag) {
    const id = webhook.send({
        url: url,
        method: "POST",
        body: "ping",
        headers: { "content-type": "text/plain" },
        on_result: "cbresult",
        context: { tag: tag },
        max_attempts: 2,
    });
    kv.set("cb/last_fire", id);
    return { id: id };
}
