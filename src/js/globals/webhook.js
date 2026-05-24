// `webhook.send` — durable outbound HTTP, composed in JS on top of
// the four reified primitives: `kv.set` (durable marker), `http.fetch`
// (transient transport), `__system/webhook_onresult` (the baked
// on_chunk shim that classifies + retries + chains to the customer's
// on_result), and the per-worker partitioned retry sweep (cron-like;
// effect-reification-plan.md Phase 5 PR-3 step 1, commit `769bf53`).
//
// Phase 5 PR-3 (this commit) atomically:
//   - Flips this file from `http.send` (Zig binding) to the JS-shim
//     composition below.
//   - Deletes the Zig kernel (`send_dispatch.zig` / `send_inflight.zig`
//     / `send_outbox.zig` / `callback_dispatch.zig`).
//   - Drops the `apply.zig` `_send/owed/*` classifier hook — the
//     marker is now an ordinary envelope-0 kv put.
// The flip + delete MUST be one commit: with both alive the classifier
// double-fires every webhook (legacy SendDispatch armed AND the JS
// shim's `http.fetch` issued in the same tick).
//
// ## Marker JSON shape (the contract the retry sweep + onresult read)
//
//   {
//     "url":        string,                // upstream URL
//     "method":     string,                // "POST" / "GET" / …
//     "body":       string,                // request body
//     "headers":    object | undefined,    // customer headers (X-Rove-* stamped on fire)
//     "attempts":   integer,               // 0 on first write; bumped by onresult
//     "next_at_ns": string,                // BigInt-as-string; "0" or omitted ≡ due now
//     "on_result":  string | null,         // customer module path (null = fire-and-forget)
//     "context":    any | null             // opaque customer payload, echoed back
//   }
//
// `next_at_ns` is a string so it survives `JSON.stringify` without
// precision loss (Date.now() * 1e6 fits an i64 but not a JS number's
// safe-integer range past 2255). The Zig sweep parses it with
// `std.fmt.parseInt(i64, …)`; missing/0 ≡ due now.
//
// ## Id derivation
//
//   - `handle` provided → deterministic: base64url-no-pad(sha256(handle)).
//     Two `webhook.send`s with the same handle write to the same
//     `_send/owed/{id}` row — last write wins (the customer's
//     idempotency mechanism).
//   - No handle → `crypto.randomUUID()`. Replay-deterministic via the
//     existing crypto random tape (Math/Date/crypto all tape).
//
// ## Fire policy
//
//   - Immediate (no `fire_at_ns`, or `fire_at_ns <= now`):
//       1. kv.set the marker.
//       2. http.fetch the request with `on_chunk =
//          __system/webhook_onresult`, ctx = {id, on_result, context}.
//          Customer-visible request carries `X-Rove-Schedule-Id` +
//          `X-Rove-Schedule-Version` headers (version=1).
//   - Scheduled (`fire_at_ns > now`):
//       1. kv.set the marker with `next_at_ns = String(fire_at_ns)`.
//       The retry sweep picks it up when due. No http.fetch from this
//       call site.
//
// The sweep stamps the same `X-Rove-Schedule-Id` + `X-Rove-Schedule-
// Version: {attempts+1}` headers on each retry, so upstream services
// can dedupe by `(id, version)` consistently across first-fire-from-
// handler and retry-from-sweep.

/**
 * Durable outbound HTTP — at-least-once delivery, replay-deterministic.
 * Customer code that hardcoded the previous `http.send` surface should
 * migrate to `webhook.send`; the customer-visible API is the same call
 * shape (`url`/`method`/`body`/`headers`/`on_result`/`context` plus the
 * new `handle` and `fire_at_ns`).
 *
 * @namespace webhook
 */
globalThis.webhook = {
  /**
   * Send a webhook. Writes a durable `_send/owed/{id}` marker through
   * raft, then fires the request via {@link http.fetch}. On failure
   * the platform retries with exponential backoff (1s, 2s, 4s, …,
   * capped at 60s, max 5 attempts) — controlled by the baked
   * `__system/webhook_onresult` shim, not customer code.
   *
   * The handler's commit gates the marker: if the handler throws or
   * raft faults, no marker is written and no request fires. After
   * commit the platform owns delivery; the customer's `on_result`
   * module sees one terminal result event (success or give-up after
   * the retry budget).
   *
   * @param {object} opts
   * @param {string} opts.url - Target URL.
   * @param {string} [opts.method="POST"] - HTTP method.
   * @param {string} [opts.body=""] - Request body.
   * @param {Object<string,string>} [opts.headers] - Extra headers.
   *   `X-Rove-Schedule-Id` and `X-Rove-Schedule-Version` are added
   *   by the platform on fire — don't set them yourself.
   * @param {string} [opts.handle] - Customer-chosen idempotency
   *   handle. Same handle → same id → same `_send/owed/{id}` row
   *   (last write wins). Omit for a fresh random id.
   * @param {bigint|number} [opts.fire_at_ns] - Epoch nanoseconds.
   *   `> now` defers the fire to the retry sweep (the marker is
   *   written but no `http.fetch` happens until the sweep). Omit or
   *   `<= now` for fire-as-soon-as-handler-commits.
   * @param {string} [opts.on_result] - Module path of a customer
   *   result handler. Receives the terminal event as
   *   `request.body.ctx.result = {ok, status, body, headers,
   *   body_truncated, attempts, error?, context, id}` — the
   *   `__system/webhook_onresult` shim chains via `__rove_next`.
   * @param {*} [opts.context] - Opaque customer payload echoed back
   *   on the result event.
   * @returns {string} The marker id. Same value as the `handle` when
   *   one was supplied.
   * @throws {TypeError} If `opts` or `opts.url` is missing/wrong type.
   *
   * @example
   * webhook.send({
   *   url: "https://hooks.example.com/x",
   *   body: JSON.stringify({ event: "order.paid", id }),
   *   on_result: "hooks/onDelivered",
   *   context: { order_id: id },
   * });
   *
   * @example
   * // Scheduled fire — write the marker now, fire in 5 minutes.
   * webhook.send({
   *   url: "https://example.test/reminder",
   *   body: "ping",
   *   handle: "reminder/" + user_id,        // idempotent
   *   fire_at_ns: BigInt(Date.now() + 300_000) * 1_000_000n,
   * });
   */
  send(opts) {
    if (!opts || typeof opts !== "object")
      throw new TypeError("webhook.send requires an options object");
    if (typeof opts.url !== "string")
      throw new TypeError("webhook.send: `url` must be a string");

    // Tolerate the legacy `onResult` (camelCase, as written by
    // older email.js / customer code) plus the new snake_case
    // `on_result`. Modules-only: a plain string, not the legacy
    // `{module: "..."}` object — webhook_onresult.mjs receives it
    // verbatim through `__rove_next(on_result, {ctx: {...}})`.
    let on_result = null;
    if (typeof opts.on_result === "string") {
      on_result = opts.on_result;
    } else if (opts.on_result && typeof opts.on_result === "object" &&
               typeof opts.on_result.module === "string") {
      on_result = opts.on_result.module;
    } else if (typeof opts.onResult === "string") {
      on_result = opts.onResult;
    } else if (opts.onResult && typeof opts.onResult === "object" &&
               typeof opts.onResult.module === "string") {
      on_result = opts.onResult.module;
    }

    // Id derivation: deterministic from handle, else randomUUID
    // (taped → replay-deterministic).
    let id;
    if (typeof opts.handle === "string" && opts.handle.length > 0) {
      // base64url(no pad)(sha256(handle)). 43 chars, URL-safe, no
      // collisions in practice; deterministic so two webhook.sends
      // with the same handle land on the same `_send/owed/{id}`.
      id = base64url.encode(hex.decode(crypto.sha256(opts.handle)));
    } else {
      id = crypto.randomUUID();
    }

    // Resolve fire_at_ns to a BigInt for the marker. now_ns is a
    // BigInt (Date.now() is a Number; multiply by 1e6n converts).
    const now_ns = BigInt(Date.now()) * 1_000_000n;
    let fire_at_ns_big = 0n;
    if (opts.fire_at_ns != null) {
      fire_at_ns_big = typeof opts.fire_at_ns === "bigint"
        ? opts.fire_at_ns
        : BigInt(Math.floor(opts.fire_at_ns));
    }
    const scheduled = fire_at_ns_big > now_ns;

    // `max_attempts` caps the built-in retry loop in
    // `__system/webhook_onresult`. Default 5 (1 initial fire + 4
    // retries with exponential backoff capped at 60s). Customers
    // who want a different policy can set it explicitly; the
    // `retry.send` wrapper sets `1` to disable the built-in retry
    // and drive its own customer-side chain.
    const max_attempts = (opts.max_attempts != null && opts.max_attempts >= 1)
      ? Math.floor(opts.max_attempts)
      : 5;

    const marker = {
      url: opts.url,
      method: opts.method || "POST",
      body: opts.body || "",
      headers: opts.headers || {},
      attempts: 0,
      max_attempts: max_attempts,
      // Scheduled → next_at_ns is the customer-chosen fire time.
      // Immediate → "0" (the sweep treats 0 as due-now, but the
      // immediate http.fetch below pre-empts it).
      next_at_ns: scheduled ? String(fire_at_ns_big) : "0",
      on_result: on_result,
      context: opts.context !== undefined ? opts.context : null,
    };
    kv.set("_send/owed/" + id, JSON.stringify(marker));

    // Phase 5 PR-3: sweep-only fire path. Earlier drafts of this shim
    // called `http.fetch` inline so the customer saw ~10ms latency on
    // an immediate-fire webhook.send. That introduced a fundamental
    // race: the marker is in this handler's writeset (not committed
    // until raft replicates ~10-20ms later) but `http.fetch` enqueues
    // the request immediately. On a fast upstream the fetch can
    // complete BEFORE the marker commits — webhook_onresult opens a
    // fresh `beginTrackedImmediate` that doesn't see the speculative
    // writeset, sees `owed_raw == null`, and bails. The chain to the
    // customer's `on_result` never runs.
    //
    // The fix is commit-gating. Until Phase 4.1 lands a generalized
    // commit-gated Cmd buffer (it currently only stages stream
    // chunks — `effect-reification-plan.md` §6 Phase 4.0.b), the
    // pragmatic shape is: don't fire from the handler. The
    // per-worker partitioned retry sweep wakes within
    // `SEND_SWEEP_INTERVAL_NS` (1s) of `next_at_ns`, after the
    // marker has committed. Worst-case latency is ~1s on first
    // fire; acceptable for v1. The held-sync §6.4 path tolerates
    // this — its 25s mandatory deadline allows for the sweep tick
    // and the round-trip.
    return id;
  },
};
