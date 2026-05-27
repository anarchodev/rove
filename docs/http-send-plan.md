# http.send plan — historical reference

> **2026-05-24 retirement notice.** The dedicated `http.send` primitive
> has been **deleted**. Durability is now a JS-shim composition over
> `kv.set("_send/owed/{id}", ...)` (rides envelope-0 atomic with the
> handler's writes) + the outbound HTTP primitive + a
> `_subscriptions/_send_retry/` cron + a boot subscription on
> leader-promotion. **`SendDispatch`, `InflightSet`, `send_outbox`,
> `parkSendOps`, `firePendingSendOps`, and `apply.zig`'s `_send/owed` /
> `_send/proof` special-cases are all gone** (~4.7 kLOC of Zig deleted
> in commit `b908953`). See memory entry `project_durability_as_js_shim`
> + [`effect-reification-plan.md`](effect-reification-plan.md) Phase 5
> for the current architecture.
>
> What stays: the per-tenant `_send/owed/{id}` marker pattern + the
> retry semantics + the on-result chain hop — they just live in JS as
> a composition of existing primitives, not as a baked-in Zig verb.
> Customer-facing API (`webhook.send`, `email.send`) is unchanged.
>
> The current JS shims live at `src/js/bindings/webhook.send.js` and
> `src/js/bindings/email.send.js`; the retry library is
> `src/js/bindings/retry.js`. They compose on `http.fetch` (the
> transient outbound primitive — `docs/upstream-streaming-plan.md`)
> plus `kv.set` for the durable marker.
>
> The historical evolution path documented below:
>
> 1. **Original framing** (PLAN.md §2.6): webhook delivery as a
>    dedicated subsystem with a per-tenant `_outbox/*` scan + retry policy.
> 2. **Phase 5.5(d) shipped 2026-05-06** — cluster-wide `webhooks.db`,
>    envelopes 4/5/6, leader-pinned `webhook-server` thread.
> 3. **2026-05-09 generalization** (commits `deb5bba` → `cf375bf`) —
>    `webhook-server` deleted in favour of `http.send` / `http.cancel`
>    with `schedules.db` + envelopes 8/9/10/11 + a generic leader-pinned
>    `schedule-server` thread. `webhook.send` became a JS polyfill;
>    `retry.*` became a customer-side library.
> 4. **Option-(b) re-platform 2026-05-19** — `schedules.db` + envelopes
>    8/9/10/11 + schedule-server thread + `dispatchCallbacks` /
>    `dispatchInternalSchedules` all deleted. A send's only firing record
>    became the per-tenant `_send/owed/{id}` marker on envelope-0, fired
>    by a leader-local per-node in-memory `SendDispatch`.
> 5. **Durability-as-JS-shim 2026-05-24** (this retirement notice) —
>    `SendDispatch` and the apply-time `_send/owed/*` special-cases
>    deleted; durability composition moved to JS.

---

This document is preserved as a historical reference for cross-doc
citations (`http-send-plan §1`, `§3`, `§7`, `§15`, etc.) that pre-date
the 2026-05-24 retirement. The summaries below preserve the section
anchors so existing citations still resolve; do not extend the design
documented here, since the entire mechanism is now deleted.

## 1. The primitive: `http.send` (retired)

`http.send` was a Zig binding that took a request spec + optional
`fire_at_ns` + optional `on_result` module reference, returned an opaque
`send_id`, and durably scheduled the outbound HTTP call. Companion
`http.cancel` accepted either `{handle}` or `{id}` to cancel a pending
send. The customer-facing surface is preserved by the
`webhook.send` / `email.send` JS shims.

**Why on_result was a module reference, not a URL** (§1.2): customer
handlers run in the rewind.js execution model — the platform owns
dispatch, deployment, and TLS termination. Threading the result back
through a URL would require a self-call cycle through the edge proxy
plus a re-deploy on every change to callback logic. A module reference
binds the callback at the same deploy as the send, lets the runtime
reuse the existing dispatch path, and avoids a TLS-round-trip per
result. The JS shim preserves this — `on_result` in
`webhook.send.js` triggers an internal `__system/webhook_onresult`
module.

## 2. Architecture (retired)

Pre-retirement: a cluster-wide `schedules.db` (then Option-(b)'s
per-tenant `_send/owed/{id}` markers) carried the durable schedule
state, replicated atomically with the originating writeset, and a
leader-pinned thread (then per-node `SendDispatch`) read it to fire
outbound HTTP. The on-result callback path used the existing dispatch
mechanism.

## 3. Transport at each hop (retired)

The Zig dispatcher used libcurl multi against the edge proxy for
external destinations and the in-process h2 listener for in-cluster
targets (the "internal routing fast path" — §3.2, also retired). The
JS shim now does this directly via `http.fetch`.

### 3.1 Edge proxy as a deployment requirement (still current)

Outbound TLS still flows through the operator-deployed proxy described
in [`docs/deployment.md`](deployment.md). That requirement survives the
retirement; `http.fetch` (the live outbound primitive) uses the same
egress path.

## 4. Wire format (retired)

Envelopes 4/5/6 (webhook subsystem 2026-05-06 → 2026-05-09) and 8/9/10/11
(`schedule_upsert` / `schedule_complete` / `schedule_cancel` /
`schedule_demote`, 2026-05-09 → 2026-05-19) all retired. The decoder
rejects each loudly, so any stale raft-log entry surfaces instead of
silently mis-applying. See PLAN.md §10.2 envelope-type table for the
full retirement record.

## 5–6. Scheduler thread + atomicity (retired)

The scheduler thread (originally `webhook-server`, then `schedule-server`,
then `SendDispatch`) provided the leader-pinned single-instance
guarantee + the atomic-with-writeset envelope-merge that made arming a
send commit-with-handler. All retired by the JS-shim composition:
arming a send is now `kv.set("_send/owed/{id}", ...)` inside the
handler's writeset, atomic for free.

## 7. Leadership change + at-least-once (semantics preserved)

The at-least-once contract — that a send arms when the writeset
commits, fires at least once, and dedupes on overlapping fires after
a leadership change — is **preserved** by the JS shim. On leader
promotion, the boot subscription scans `_send/owed/{id}` markers and
re-fires sends without a `_send/proof/{id}` companion. The
`X-Rove-Schedule-Id` + `X-Rove-Schedule-Version` headers (renamed from
the prior `X-Rove-Webhook-Id` / `-Attempt`) still ride every outbound
fire so receivers can dedup overlapping fires. Reader semantics
unchanged for receivers.

The historical pre-retirement implementation (leader-pinned thread
reading raft-replicated row state, version-counter dedup) is
documented in commit `b908953`'s deleted code paths.

## 8. on_result callback path (semantics preserved)

The `on_result` module reference is invoked once the outbound call
completes (success or terminal failure). The JS shim implements this
via the internal `__system/webhook_onresult` dispatcher
(`webhook.send.js`); customer handlers still see a `send_callback`
Msg with `{outcome, attempt, response, ctx}`.

## 9–10. JS libraries + customer escape hatch (current shape)

Customer-facing primitives:

- **`webhook.send(opts) → id`** (`src/js/bindings/webhook.send.js`) —
  durable outbound HTTP. Composes `kv.set("_send/owed/{id}", ...)` for
  arm-with-writeset + `http.fetch` for the actual call + the
  `webhook_onresult` shim for callback dispatch + the
  `_subscriptions/_send_retry/` cron for re-fire.
- **`email.send({key, from, to, subject, ...})`**
  (`src/js/bindings/email.send.js`) — `webhook.send` wrapper for
  Resend's REST API. Customer passes `key` explicitly (§10.4 design
  rule — vendor-neutral; `webhook.send` doesn't ship a baked-in HMAC
  signing scheme either, see memory `feedback_webhook_send_generic`).
- **`retry.{send, shouldRetry, next, stripContext}`**
  (`src/js/bindings/retry.js`) — customer-side retry helpers. State
  lives in the customer's own kv; no platform privileges.

### 10. Recipes (composition shape preserved)

The §10 recipes (§10.1 Stripe-style idempotency, §10.2 scheduled email,
§10.3 abandoned-cart, §10.4 cron-style recurring, §10.5 order-timeout-
pushed-on-activity, §10.6 topics/fanout, §10.7 custom HMAC/oauth2
signing, §10.8 saga orchestration) are all still composable on top of
the JS shims plus `kv.*` and `http.fetch`. See
`examples/loop46-demo-tenants/` for working examples.

## 11–14. Migration plan + locked-in + open / deferred + side benefits (retired)

The pre-2026-05-24 migration plan, locked-in invariants, deferred
items, and side-benefits analyses described tradeoffs of the
now-deleted machinery. The going-forward shape is in
`effect-reification-plan.md` Phase 5.

## 15. Option-(b) N-way re-platform (retired 2026-05-24)

§15 documented the 2026-05-19 transition from cluster-wide
`schedules.db` to per-tenant `_send/owed/{id}` markers + leader-local
per-node `SendDispatch`. The 2026-05-24 durability-as-JS-shim cutover
deleted `SendDispatch` itself (`b908953`); the marker pattern survives,
but now as ordinary envelope-0 kv writes from the JS shim, not as an
apply-time special case.

## See also

- [`PLAN.md`](PLAN.md) §2.6 — the original webhook framing this
  superseded.
- [`effect-reification-plan.md`](effect-reification-plan.md) Phase 5 —
  the current architecture.
- [`effect-algebra.md`](effect-algebra.md) §6 rule 2 + §7 worklist #7
  — the framing principles that drove durability-as-JS-shim.
- [`upstream-streaming-plan.md`](upstream-streaming-plan.md) — the live
  outbound HTTP primitive (`http.fetch`).
