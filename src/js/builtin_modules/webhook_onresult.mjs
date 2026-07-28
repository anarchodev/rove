// `webhook.send`'s result classifier — the baked on_chunk handler
// every webhook fetch (inline first fire from the shim, or a deferred
// fire from `__system/webhook_fire`) reports into.
//
//   1. Ignores intermediate chunks (waits for final).
//   2. On final: classifies the result (success / retryable failure
//      / give-up) against the durable `_send/owed/{id}` marker:
//        - success (status < 400): kv.delete the marker + cancel the
//          send's scheduler entry (the webhook_fire watchdog).
//        - retryable (status >= 500 OR transport !ok): bump attempts,
//          keep the marker, re-arm the scheduler entry to the backoff
//          time (the durable-wake backoff re-arm; docs/architecture/effects-and-handlers.md).
//        - give-up (status 4xx, or attempts >= max): delete the
//          marker + cancel the entry, record the give-up.
//   3. Hands off to the customer's on_result module via __rove_next
//      (unless a §6.4 held-sync continuation is bound to this send —
//      then the deferred resume gets the event instead).
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

// Durable-scheduler arm/cancel, inlined over the ambient `kv`/`crypto`: a
// baked `__system/*` module runs post-harden and can't reach the private
// `_system.sched` closure. Writes the exact `_sched/` rows
// globals/schedule.js + scheduler_tick.mjs use.
const SCHED_TICK_NS = 1_000_000_000n;
function schedByTimeKey(whenNs, id) {
    return "_sched/by_time/" + String(whenNs).padStart(20, "0") + "/" + id;
}
function schedArm(whenNs, target, msg, key) {
    const rounded = whenNs <= 0n ? 0n
        : ((whenNs + SCHED_TICK_NS - 1n) / SCHED_TICK_NS) * SCHED_TICK_NS;
    const id = key ? crypto.sha256b64url(key) : crypto.randomUUID();
    const byIdKey = "_sched/by_id/" + id;
    const prev = kv.get(byIdKey);
    if (prev !== null) {
        try {
            const old = JSON.parse(prev);
            const oldWhen = BigInt(old.when_ns);
            if (oldWhen !== rounded) kv.delete(schedByTimeKey(oldWhen, id));
        } catch (_e) { /* corrupt prior record — overwrite below */ }
    }
    const rec = { when_ns: String(rounded), target: target, msg: msg === undefined ? null : msg };
    if (key) rec.key = key;
    kv.set(byIdKey, JSON.stringify(rec));
    kv.set(schedByTimeKey(rounded, id), "");
    return id;
}
function schedCancel(id) {
    const raw = kv.get("_sched/by_id/" + id);
    if (raw === null) return false;
    try {
        const rec = JSON.parse(raw);
        kv.delete(schedByTimeKey(BigInt(rec.when_ns), id));
    } catch (_e) { /* corrupt record — still drop by_id below */ }
    kv.delete("_sched/by_id/" + id);
    return true;
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

    // The shim's bookkeeping ctx (the originating webhook.send
    // stuffed it onto the fetch's `ctx`) — lifted to `request.ctx`
    // on both the unbound-fetch and the chained-hop paths.
    const ctx = request.ctx || {};
    const { id, on_result, context } = ctx;

    // Read the owed marker — if absent, this is a duplicate fire
    // (the retry sweep + first-attempt callback both completed);
    // no-op.
    const owed_raw = kv.get("_send/owed/" + id);
    if (owed_raw == null) return { status: 200 };
    const owed = JSON.parse(owed_raw);

    // Result shape — handed to __rove_next as {ctx:{result, context}};
    // the runtime then flattens it onto the customer's `{on}` request
    // surface (request.bytes/.status + request.ctx; globals.zig).
    // The response bytes ride base64url-encoded (`body_b64`) — the
    // JSON envelope can't carry raw bytes (decisions.md
    // §4.11); the consumer's text view derives from the bytes.
    const body_b64 = (a.kind === "fetch_chunk")
        ? base64url.encode(a.bytes)
        : base64url.encode(ctx.result_body || "");
    const result_status = (a.kind === "fetch_chunk") ? a.status : ctx.result_status;
    // Raw transport bit — did the delivery attempt reach an HTTP
    // response at all? The retry classifier below must keep an upstream
    // 5xx distinct from a hard transport failure, so it can't lean on a
    // single 2xx/not-2xx flag. Convention: `status === 0` ⟺
    // no HTTP response reached us; 4xx/5xx are transport-ok with a real
    // status.
    const transport_ok = (a.kind === "fetch_chunk") ? (result_status !== 0) : !!ctx.result_ok;
    const result_headers = (a.kind === "fetch_chunk")
        ? (a.headers || {})
        : (ctx.result_headers || {});
    const result_truncated = (a.kind === "fetch_chunk") ? !!a.bodyTruncated : false;

    const result = {
        id: id,
        ok: transport_ok && result_status < 400,
        status: result_status,
        body_b64: body_b64,
        headers: result_headers,
        body_truncated: result_truncated,
        attempts: owed.attempts + 1,
        context: context,
    };

    // Classify.
    const transport_failed = !transport_ok;
    const upstream_5xx = result_status >= 500;
    const upstream_4xx = result_status >= 400 && result_status < 500;
    const max_attempts = (typeof owed.max_attempts === "number" && owed.max_attempts >= 1)
        ? owed.max_attempts
        : DEFAULT_MAX_ATTEMPTS;
    const should_retry = (transport_failed || upstream_5xx)
        && (owed.attempts + 1 < max_attempts);

    if (should_retry) {
        // Update marker; do NOT fire on_result yet (still in flight).
        // The durable scheduler entry under key `_send/{id}` moves to
        // the backoff time (same key ⇒ last-write-wins re-arm); the
        // wake fires `__system/webhook_fire`, which re-fetches.
        owed.attempts += 1;
        delete owed.next_at_ns; // legacy timing field — scheduler owns timing now
        kv.set("_send/owed/" + id, JSON.stringify(owed));
        schedArm(computeNextAtNs(owed.attempts), "__system/webhook_fire",
                 { id: id }, "_send/" + id);
        return { status: 200 };
    }

    // Terminal: clear marker + cancel the send's scheduler entry (the
    // crash-recovery watchdog / pending retry). The schedule id is
    // deterministic from the key — same recipe as schedule's opts.key
    // opts.key handling (base64url-no-pad(sha256(key))).
    kv.delete("_send/owed/" + id);
    schedCancel(crypto.sha256b64url("_send/" + id));

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
        body_b64: result.body_b64,
        headers: result.headers,
        body_truncated: result.body_truncated,
        attempts: result.attempts,
        error: result.error || null,
        context: context,
    };
    // §6.4 held-sync resume hook. `__rove.resumeIfBound` is a gated
    // privileged op (STATIC_NAMESPACES `__rove.*`; persistent across the
    // `_harden.js` deletion of `_system`; throws for customer code).
    // Returns true when a parked continuation on this worker is bound to
    // this send-id (the open hop wrote ONE `_send/owed/` marker and
    // parked via `next()`). On match we SKIP the customer's `on_result`
    // — held-sync's `onResult(ctx, outcome)` already received the event
    // via the deferred resume.
    if (__rove.resumeIfBound(id, JSON.stringify(event_for_heldsync))) {
        return { status: 200 };
    }

    if (on_result) {
        // Cross-module continuation into the customer's on_result handler
        // — the widened public `next(target, ctx)` (baked modules use the
        // public shim; no bare native).
        return next(on_result, { result: result, context: context });
    }
    return { status: 200 };
}
