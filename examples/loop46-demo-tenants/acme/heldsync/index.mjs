// §6.4 held-synchronous third-party call — open hop.
//
// The client makes ONE synchronous request here. We fire an
// http.send to a third party and return a continuation instead of a
// response: the connection stays parked, the customer never sees a
// handle, and the runtime binds this single http.send's completion
// to the continuation (Part A stamps on_result = the continuation
// target so apply.zig emits the `c/` row). When the third party
// answers, `heldsync/onresult#onResult` resumes this parked socket.
//
// Body fields:
//   target         url the http.send hits
//   tag            echo tag threaded through ctx
//   retry_to       (optional) on failure, onResult retries here once
//                  (recipe-1 — customer-composed retry, re-park)
//   send_timeout_ms(optional) http.send libcurl timeout; set high +
//                  point target at an unreachable IP to exercise the
//                  §6.4 mandatory-timeout (deadline) path
export default function () {
    const req = JSON.parse(request.body);
    const opts = {
        url: req.target,
        method: "POST",
        body: JSON.stringify({ from: "heldsync", tag: req.tag }),
        headers: { "content-type": "application/json" },
    };
    if (req.send_timeout_ms) opts.timeout_ms = req.send_timeout_ms;
    // NO on_result here — Part A derives it from the continuation.
    http.send(opts);
    return __rove_next("heldsync/onresult", {
        fn: "onResult",
        ctx: { tag: req.tag, tries: 0, retry_to: req.retry_to || null },
    });
}
