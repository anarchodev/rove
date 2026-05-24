// §6.4 held-synchronous third-party call — open hop.
//
// The client makes ONE synchronous request here. We fire a
// webhook.send to a third party and return a continuation instead of
// a response: the connection stays parked, the customer never sees a
// handle, and the runtime binds this single webhook.send's
// completion to the continuation (the §6.4 binding scans the
// writeset for the lone `_send/owed/` put). When the third party
// answers, the JS-shim `__system/webhook_onresult` calls
// `_system.continuation.resumeIfBound` and `heldsync/onresult#onResult`
// resumes this parked socket.
//
// Body fields:
//   target         url the webhook.send hits
//   tag            echo tag threaded through ctx
//   retry_to       (optional) on failure, onResult retries here once
//                  (recipe-1 — customer-composed retry, re-park)
//   send_timeout_ms(optional) webhook libcurl timeout; set high +
//                  point target at an unreachable IP to exercise the
//                  §6.4 mandatory-timeout (deadline) path
export default function () {
    const req = JSON.parse(request.body);
    const opts = {
        url: req.target,
        method: "POST",
        body: JSON.stringify({ from: "heldsync", tag: req.tag }),
        headers: { "content-type": "application/json" },
        // Disable webhook.send's built-in retry — held-sync owns
        // its own retry policy via __rove_next.
        max_attempts: 1,
    };
    if (req.send_timeout_ms) opts.timeout_ms = req.send_timeout_ms;
    // NO on_result here — the resume engine is bound to the lone
    // `_send/owed/` put in this writeset and resumes our cont when
    // webhook_onresult fires `resumeIfBound`.
    webhook.send(opts);
    return __rove_next("heldsync/onresult", {
        fn: "onResult",
        ctx: { tag: req.tag, tries: 0, retry_to: req.retry_to || null },
    });
}
