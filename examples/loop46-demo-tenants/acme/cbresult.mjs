export default function (event) {
    const record = {
        outcome: event.outcome,
        attempts: event.attempts,
        context: event.context,
        status: event.response ? event.response.status : null,
        body: event.response ? event.response.body : null,
        error: event.error || null,
    };
    kv.set("cb/result/" + event.webhookId, JSON.stringify(record));
}
