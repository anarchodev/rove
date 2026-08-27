// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// `webhook.send` — durable outbound HTTP, composed in JS on top of
// the reified primitives: `kv.set` (durable marker), `http.fetch`
// (transient transport), `__system/webhook_onresult` (the baked
// on_chunk shim that classifies + retries + chains to the customer's
// on_result), and the durable `scheduler` (the durable-wake primitive
// of the four-primitive effect model, docs/effect-algebra.md):
// scheduled fires, retry re-arms, and the crash-recovery watchdog are
// all ONE `scheduler` entry under the idempotency key `_send/{id}`,
// fired as the baked `__system/webhook_fire`. The privileged Zig owed
// sweep (`owed_retry.zig`'s `sweepOwedRetries*`) is deleted — every
// piece of webhook durability is now a composition a customer could
// write themselves.
//
// ## Marker JSON shape (the contract webhook_fire + onresult read)
//
//   {
//     "url":        string,                // upstream URL
//     "method":     string,                // "POST" / "GET" / …
//     "body":       string,                // request body
//     "headers":    object | undefined,    // customer headers (X-Rove-* stamped on fire)
//     "attempts":   integer,               // 0 on first write; bumped by onresult
//     "max_attempts": integer,             // retry budget (default 5)
//     "on_result":  string | null,         // customer module path (null = fire-and-forget)
//     "context":    any | null             // opaque customer payload, echoed back
//   }
//
// Fire TIMING no longer lives in the marker (`next_at_ns` is gone) —
// the `scheduler` entry under key `_send/{id}` is the single durable
// next-fire authority. The marker is pure send state.
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
//       3. scheduler watchdog at now + WATCHDOG_MS aimed at
//          `__system/webhook_fire` — if the leader dies (or the
//          onresult commit is lost) between the fetch and its
//          terminal event, the wake re-fires the marker on whatever
//          node then leads. Survives leader change by construction
//          (the wake entry is replicated kv; the new leader's
//          promotion pass rebuilds its watermark from it).
//   - Scheduled (`fire_at_ns > now`):
//       1. kv.set the marker.
//       2. scheduler.at(fire_at_ns, "__system/webhook_fire", {id},
//          {key: "_send/" + id}). No http.fetch from this call site —
//          webhook_fire issues it when the wake fires.
//
// All three writes (marker + the scheduler entry's two `_sched/` keys)
// ride the handler's one writeset; the inline fetch is a buffered Cmd
// released post-commit. If the handler throws or raft faults, none of
// it happened.
//
// webhook_fire stamps the same `X-Rove-Schedule-Id` + `X-Rove-
// Schedule-Version: {attempts+1}` headers on each deferred fire, so
// upstream services can dedupe by `(id, version)` consistently across
// first-fire-from-handler and wake-fired retries.

// A FACTORY, not an IIFE (`docs/architecture/package-isolation.md`, the
// received-not-ambient model): the engine invokes it once per context with
// the capabilities a platform shim receives (`_factories_invoke.js`), and
// installs the returned object. webhook.send composes durability over the
// internal fetch PRIMITIVE (`caps.http.fetch` — the retired customer
// `http.fetch` spelling stays retired), the durable scheduler core
// (`caps.sched`), and ordinary rooted kv markers (`caps.kv`).
//
// A parameter is scoped by the language — the reason this shape replaces
// the IIFE + capture convention: an unwrapped shim's top-level `const`s
// landed in the base context's global lexical scope, where a handler
// measurably read `sysHttp` while `_system` was correctly undefined. A
// factory has no module-scope bindings for a handler to resolve, and its
// capabilities exist only inside this closure.
/**
 * Durable outbound HTTP — at-least-once delivery, replay-deterministic.
 * See the `send` JSDoc on the returned object.
 * @namespace webhook
 */
__rove_factories.webhook = function (caps) {
  const { http, sched, kv, formats } = caps;

  // Crash-recovery watchdog distance for the immediate-fire path: one
  // attempt timeout (the fetch binding's 30 s cap) + grace. Mirrored in
  // `__system/webhook_fire.mjs` (its per-attempt re-arm) — keep in sync.
  // `_send/owed/{id}` record version (`format-versioning.md` §1f).
  // Read by `__system/webhook_fire` and `__system/webhook_onresult`,
  // which ship in the worker binary while this shim ships in the
  // tenant's deployment — the two can be from different builds, and
  // the marker is the only thing that crosses between them.
  const SEND_OWED_V = formats.sendOwed;

  const WEBHOOK_WATCHDOG_MS = 40_000;

  /**
   * Durable outbound HTTP — at-least-once delivery, replay-deterministic.
   * The connectionless counterpart to `after.fetch`: the send fires after
   * the handler commits and is owned by the platform until a terminal
   * result, surviving crashes and leader changes.
   */
  return {
    /**
     * Send a webhook. Writes a durable `_send/owed/{id}` marker through
     * raft, then fires the request post-commit. On failure
     * the platform retries with exponential backoff (1s, 2s, 4s, …,
     * capped at 60s, max 5 attempts) — controlled by the baked
     * `__system/webhook_onresult` shim, not customer code. Deferred
     * fires (scheduled sends, retries, crash recovery) ride the durable
     * {@link schedule} and survive leader changes.
     *
     * The handler's commit gates the marker: if the handler throws or
     * raft faults, no marker is written and no request fires. After
     * commit the platform owns delivery; the customer's `on_result`
     * module sees one terminal result event (success or give-up after
     * the retry budget).
     *
     * @param {string} url - Target URL.
     * @param {object} [opts]
     * @param {string} [opts.method="POST"] - HTTP method.
     * @param {string} [opts.body=""] - Request body (string only — the
     *   durable marker is JSON).
     * @param {Object<string,string>} [opts.headers] - Extra headers.
     *   `X-Rove-Schedule-Id` and `X-Rove-Schedule-Version` are added
     *   by the platform on fire — don't set them yourself.
     * @param {string} [opts.key] - Idempotency key — the same word it
     *   is on `schedule`: same key → same id → same `_send/owed/{id}`
     *   row (last write wins). Omit for a fresh random id.
     * @param {bigint|number|Date|string} [opts.at] - Absolute fire time
     *   (bigint ns, number ms-since-epoch, Date, or ISO-8601 — the
     *   `schedule({at})` coercions). A future time defers the fire to a
     *   durable scheduled wake; omitted/past = fire on commit.
     * @param {number|string} [opts.in] - Delay from now (ms, or a
     *   duration string `"30s"`/`"5m"` — the `schedule({in})` shape).
     * @param {number} [opts.maxAttempts=5] - Retry budget (1 first
     *   fire + up to 4 backoff retries).
     * @param {number} [opts.timeoutMs] - Per-attempt timeout, applied
     *   to every fire (first, deferred, retries).
     * @param {string} [opts.on] - Module path of a customer result
     *   handler. Receives the terminal event on the unified flattened
     *   surface (handler-shape §7): the response on `request.bytes` /
     *   `.text` / `.json`, and `request.status` / `.bodyTruncated`
     *   (2xx = delivered; `status === 0` = never reached the endpoint;
     *   no derived `request.ok`); the threaded `ctx` value bare
     *   on `request.ctx`; delivery metadata (`attempts`, `error?`, `id`,
     *   `headers`) on `request.activation.*`. There is no `request.result`.
     * @param {*} [opts.ctx] - Opaque customer payload echoed back as
     *   `request.ctx` on the result event.
     * @returns {string} The marker id — random unless `handle` was
     *   supplied, in which case it is base64url(sha256(handle)) (stable:
     *   the same handle always yields the same id).
     * @throws {TypeError} If `url` is missing/wrong type.
     * @throws {Error} `code:"rate_limited"` when the per-tenant outbound
     *   rate limit is exhausted (email.send / webhook.send / after.fetch
     *   share one per-tenant outbound budget). The immediate fire is
     *   attempted before the durable marker is written, so a rejected send
     *   leaves nothing queued — catch and retry later.
     *
     * Lifecycle: enumerate in-flight sends with
     * `kv.prefix("_send/owed/")` (each value is the marker JSON). To
     * cancel a SCHEDULED send before it fires: `schedule.cancel(id)`
     * kills the durable wake, then `kv.delete("_send/owed/" + id)`
     * removes the marker — both in one handler, so the cancellation is
     * atomic. An already-fired send cannot be recalled.
     *
     * @example
     * webhook.send("https://hooks.example.com/x", {
     *   body: JSON.stringify({ event: "order.paid", id }),
     *   on: "hooks/onDelivered",
     *   ctx: { order_id: id },
     * });
     *
     * @example
     * // Scheduled fire — write the marker now, fire in 5 minutes.
     * webhook.send("https://example.test/reminder", {
     *   body: "ping",
     *   key: "reminder/" + userId,        // idempotent
     *   in: "5m",
     * });
     */
    send(url, maybeOpts) {
      // webhook.send(url, opts) — positional url, matching after.fetch.
      if (typeof url !== "string")
        throw new TypeError("webhook.send(url, opts): `url` must be a string");
      if (maybeOpts != null && typeof maybeOpts !== "object")
        throw new TypeError("webhook.send: opts must be an object");
      const opts = Object.assign({}, maybeOpts || {}, { url: url });
      for (const pair of [["handle", "key"], ["fire_at_ns", "at (or in)"], ["max_attempts", "maxAttempts"], ["timeout_ms", "timeoutMs"], ["on_result", "on"], ["context", "ctx"]]) {
        if (pair[0] in opts) throw new TypeError("webhook.send: option `" + pair[0] + "` was renamed — use `" + pair[1] + "`");
      }

      const on_key = typeof opts.on === "string" ? opts.on : null;
      const ctx_val = opts.ctx !== undefined ? opts.ctx : null;

      // The body must be a string: it JSON-round-trips through the
      // durable `_send/owed/{id}` marker, which would silently mangle a
      // Uint8Array to `{"0":..}` (docs/decisions.md §4.11
      // C3; byte bodies on the durable path are a deferred follow-up).
      const body = opts.body == null ? "" : opts.body;
      if (typeof body !== "string")
        throw new TypeError("webhook.send: `body` must be a string (encode bytes or JSON.stringify explicitly)");

      // `on` is a module path string. Passed verbatim to
      // `__rove_next(on_result, {ctx: {...}})` inside the
      // webhook_onresult.mjs shim.
      const on_result = on_key;

      // Id derivation: deterministic from the idempotency key, else
      // randomUUID (taped → replay-deterministic).
      let id;
      if (typeof opts.key === "string" && opts.key.length > 0) {
        // base64url(no pad)(sha256(key)). 43 chars, URL-safe, no
        // collisions in practice; deterministic so two webhook.sends
        // with the same key land on the same `_send/owed/{id}`.
        id = crypto.sha256b64url(opts.key);
      } else {
        id = crypto.randomUUID();
      }

      // Resolve the fire time via the shared `time` library: {at}
      // (absolute — bigint ns | ms | Date | duration | ISO) or {in}
      // (delay — ms | duration string).
      const now_ns = BigInt(Date.now()) * 1_000_000n;
      let fire_at_ns_big = 0n;
      if (opts.at != null) {
        fire_at_ns_big = time.toNs(opts.at);
      } else if (opts.in != null) {
        fire_at_ns_big = time.inToNs(opts.in);
      }
      const scheduled = fire_at_ns_big > now_ns;

      // `maxAttempts` caps the built-in retry loop in
      // `__system/webhook_onresult`. Default 5 (1 initial fire + 4
      // retries with exponential backoff capped at 60s). Customers
      // who want a different policy can set it explicitly; the
      // `retry.send` wrapper sets `1` to disable the built-in retry
      // and drive its own customer-side chain.
      const max_attempts = (opts.maxAttempts != null && opts.maxAttempts >= 1)
        ? Math.floor(opts.maxAttempts)
        : 5;

      const marker = {
        // `_send/owed/{id}` record version (`format-versioning.md`
        v: SEND_OWED_V,
        url: opts.url,
        method: opts.method || "POST",
        body: body,
        headers: opts.headers || {},
        attempts: 0,
        max_attempts: max_attempts,
        on_result: on_result,
        context: ctx_val,
      };
      if (opts.timeoutMs != null) marker.timeout_ms = Math.floor(opts.timeoutMs);

      // Immediate path: attempt the inline fire FIRST, BEFORE writing the
      // durable marker / watchdog. The per-tenant outbound rate limit is
      // enforced at the fetch primitive (bindings/http.zig `outboundRateOk`);
      // if it throws `rate_limited`, this send must leave NO durable residue
      // — otherwise the crash-recovery watchdog below would still deliver it,
      // and a customer who catches `rate_limited` and retries would
      // double-send. Ordering the fetch ahead of the `kv.set`/`schedule`
      // writes makes a rejected send atomic (nothing written). The fetch is
      // buffered as a `Cmd.http_fetch` and released post-commit, so it still
      // shares the marker's commit gate (docs/architecture/effects-and-handlers.md);
      // moving it earlier in the handler body doesn't change WHEN it fires,
      // only that a rate-limit throw pre-empts the writes.
      //
      // Phase 4.1.2 (inline fire): the earlier sweep-only path was a
      // workaround for a marker-commit race, resolved by the Cmd-pattern
      // commit gate — the worker stages every `http.fetch` from a write-path
      // handler on the parked unit's `BufferedCmds` and `drainRaftPending`
      // submits it STRICTLY AFTER raft commits the writeset. Scheduled fires
      // (`fire_at_ns > now`) go wake-only — the baked `__system/webhook_fire`
      // issues the fetch when the durable wake fires; the held-sync path
      // stays correct either way (the 25s mandatory deadline covers both).
      if (!scheduled) {
        http.fetch({
          url: opts.url,
          method: opts.method || "POST",
          body: body,
          headers: Object.assign({}, opts.headers || {}, {
            "X-Rove-Schedule-Id": id,
            "X-Rove-Schedule-Version": "1",
          }),
          on_chunk: "__system/webhook_onresult",
          // Held state (docs/architecture/effects-and-handlers.md): stamp the
          // send_id so the chunk router (Zig) consults
          // bound_send_owners[id] and routes the callback to the
          // cont's owning worker (instead of hash(tenant_id), which
          // may differ from the SO_REUSEPORT-chosen accept worker).
          // Platform-internal option — customers don't use it
          // directly.
          bound_send_id: id,
          timeout_ms: marker.timeout_ms,
          ctx: {
            id: id,
            on_result: on_result,
            context: ctx_val,
          },
        });
      }

      kv.set("_send/owed/" + id, JSON.stringify(marker));

      // The durable next-fire entry (one per send, idempotency key
      // `_send/{id}` — re-sends with the same handle MOVE it, mirroring
      // the marker's last-write-wins). Scheduled: the customer's fire
      // time. Immediate: the crash-recovery watchdog (onresult cancels
      // it on the terminal event; a retry re-arm moves it to the
      // backoff time).
      if (scheduled) {
        sched({ at: fire_at_ns_big }, "__system/webhook_fire", { id: id }, { key: "_send/" + id });
      } else {
        sched({ in: WEBHOOK_WATCHDOG_MS }, "__system/webhook_fire", { id: id }, { key: "_send/" + id });
      }
      return id;
    },
  };
};
