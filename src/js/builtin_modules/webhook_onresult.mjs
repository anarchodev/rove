// Phase 5 PR-2b: webhook.send shim's on_chunk handler. Baked into
// the binary as the first `__system/` built-in module — proves the
// resolution mechanism + bypass-reserved-prefix-check path are
// wired correctly. NOT YET CALLED at runtime: the customer-facing
// `webhook.send` (globals/webhook.js) still points at the Zig
// http.send path until PR-3 atomically flips the shim AND deletes
// the SendDispatch kernel (the apply.zig `_send/owed/*` classifier
// would double-fire today if both paths were live simultaneously).
//
// The shim (Phase 5 PR-3, planned):
//
//   1. Ignores intermediate chunks (waits for final).
//   2. On final: classifies the result (success / retryable failure
//      / give-up) and updates the durable `_send/owed/{id}` marker:
//        - success (status < 400): kv.delete the marker.
//        - retryable (status >= 500 OR transport !ok): bump
//          attempts + next_at_ns, keep the marker.
//        - give-up (status 4xx, or attempts >= MAX): delete the
//          marker, record the give-up.
//   3. Hands off to the customer's on_result module via __rove_next
//      (Phase 5 PR-2a lifted the cont arm from fetch handlers).
//
// Resolved by the runtime via `__system/` module path resolution
// (not in any tenant's deployment files); compiled to bytecode
// once at NodeState init and shared across every tenant.

// Default cap when the marker omits `max_attempts` (older markers).
// The customer-facing `webhook.send` sets it explicitly to 5 by
// default; `retry.send` sets 1 to disable the built-in retry loop.
const DEFAULT_MAX_ATTEMPTS = 5;
const BACKOFF_BASE_MS = 1_000;   // 1s, 2s, 4s, 8s, 16s — capped at 60s
const BACKOFF_CAP_MS = 60_000;

function computeNextAtNs(attempts) {
    const delay_ms = Math.min(
        BACKOFF_CAP_MS,
        BACKOFF_BASE_MS * Math.pow(2, attempts),
    );
    // Date.now() is taped + replay-deterministic.
    return BigInt(Date.now() + delay_ms) * 1_000_000n;
}

export default function () {
    const a = request.activation;
    if (a.kind !== "send_callback" && a.kind !== "fetch_chunk") {
        // Belt-and-braces — every dispatch via http.fetch hits us
        // with kind=fetch_chunk; via __rove_next chain hop with
        // kind=send_callback (the retry-sweep PR-2d path).
        return { status: 200 };
    }
    if (a.kind === "fetch_chunk" && !a.final) return { status: 200 };

    // Pull the shim's bookkeeping ctx (the originating webhook.send
    // stuffed it onto the fetch's `ctx`). Tolerate the retry-sweep
    // path too: when fired via __rove_next, the same ctx rides as
    // request.body.ctx.
    const ctx = a.kind === "fetch_chunk"
        ? JSON.parse(request.body).ctx
        : JSON.parse(request.body).ctx;
    const { id, on_result, context } = ctx;

    // Read the owed marker — if absent, this is a duplicate fire
    // (the retry sweep + first-attempt callback both completed);
    // no-op.
    const owed_raw = kv.get("_send/owed/" + id);
    if (owed_raw == null) return { status: 200 };
    const owed = JSON.parse(owed_raw);

    // Result shape — the customer's on_result handler receives
    // this as request.body.ctx.result.
    const body_text = (a.kind === "fetch_chunk")
        ? new TextDecoder().decode(a.bytes)
        : (ctx.result_body || "");
    const result_status = (a.kind === "fetch_chunk") ? a.status : ctx.result_status;
    const result_ok = (a.kind === "fetch_chunk") ? a.ok : ctx.result_ok;
    const result_headers = (a.kind === "fetch_chunk")
        ? (a.headers || {})
        : (ctx.result_headers || {});
    const result_truncated = (a.kind === "fetch_chunk") ? !!a.body_truncated : false;

    const result = {
        id: id,
        ok: result_ok && result_status < 400,
        status: result_status,
        body: body_text,
        headers: result_headers,
        body_truncated: result_truncated,
        attempts: owed.attempts + 1,
        context: context,
    };

    // Classify.
    const transport_failed = !result_ok;
    const upstream_5xx = result_status >= 500;
    const upstream_4xx = result_status >= 400 && result_status < 500;
    const max_attempts = (typeof owed.max_attempts === "number" && owed.max_attempts >= 1)
        ? owed.max_attempts
        : DEFAULT_MAX_ATTEMPTS;
    const should_retry = (transport_failed || upstream_5xx)
        && (owed.attempts + 1 < max_attempts);

    if (should_retry) {
        // Update marker; do NOT fire on_result yet (still in flight).
        owed.attempts += 1;
        owed.next_at_ns = String(computeNextAtNs(owed.attempts));
        kv.set("_send/owed/" + id, JSON.stringify(owed));
        return { status: 200 };
    }

    // Terminal: clear marker. Fire on_result if customer registered one.
    kv.delete("_send/owed/" + id);

    // Mark as a give-up vs success in the result the customer sees.
    if (transport_failed || upstream_5xx) {
        // Retry budget exhausted.
        result.error = transport_failed
            ? "transport_failed"
            : ("upstream_" + result_status);
    } else if (upstream_4xx) {
        result.error = "upstream_" + result_status;
    }

    // §6.4 held-sync resume hook. If a parked continuation on this
    // worker is bound to this send-id (the open hop wrote ONE
    // `_send/owed/` marker and returned `__rove_next`), this call
    // resumes the parked socket with the outcome event. Returns
    // true when it matched + dispatched a resume; on a match we
    // SKIP the customer's `on_result` because held-sync's
    // `onResult(ctx, outcome)` already received the event. No-op +
    // returns false for the ordinary (non-held-sync) webhook path.
    const event_for_heldsync = {
        id: id,
        ok: result.ok,
        status: result.status,
        body: result.body,
        headers: result.headers,
        body_truncated: result.body_truncated,
        attempts: result.attempts,
        error: result.error || null,
        context: context,
    };
    // §6.4 held-sync resume hook. `__rove_resume_if_bound` is a
    // persistent global builtin (wired in `globals.zig`'s
    // `GLOBAL_BUILTINS`; survives the `_harden.js` deletion of
    // `_system`). Returns true when a parked continuation on this
    // worker is bound to this send-id (the open hop wrote ONE
    // `_send/owed/` marker and returned `__rove_next`). On match we
    // SKIP the customer's `on_result` — held-sync's `onResult(ctx,
    // outcome)` already received the event via the deferred resume.
    if (__rove_resume_if_bound(id, JSON.stringify(event_for_heldsync))) {
        return { status: 200 };
    }

    if (on_result) {
        return __rove_next(on_result, { ctx: { result: result, context: context } });
    }
    return { status: 200 };
}
