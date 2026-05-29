# Auto-bind reshape — `http.fetch` binds to its chain by default

Followup unblocked by the chunk spool (`docs/chunk-spool-plan.md`
§Followups). The spool removed the arrival-rate cliff that made
binding every fetch dangerous, so binding can become the default.

**Status: SHIPPED 2026-05-29** (Phases 1–3). `bind: true` removed;
held-handler fetches auto-bind; `detach: true` is the opt-out;
registration happens at the handler-success seam. Remaining polish
(non-blocking, deferred): the loader deploy-time warning (the
`handler-shape.md` §6 text is updated; the loader check itself isn't
wired) and relaxing the binding's `on_chunk`-required check for
auto-bound fetches (today `on_chunk` is still required + ignored on
the bound path).

## Today

`http.fetch` has two chunk-destination modes, chosen by `bind`:

- `http.fetch({bind: true})` — chunks resume the **calling chain's**
  `onFetchChunk` export. Registered **at the binding call**
  (`bindings/http.zig` → `register_bound_fetch` trampoline), which
  requires `activation_entity` to already exist and throws if not.
- `http.fetch({on_chunk: "mod"})` (no bind) — chunks fire a
  **separate** `fetch-<id>` chain (Pattern A): `mod` is dispatched
  fresh per chunk. Fire-and-forget if no `on_chunk`.

Two problems:
1. **Registration is at call time, not outcome time.** The binding
   can't know whether the handler will end up *held* (`next()`/
   `stream()`) or *terminal*. So `bind: true` is an unchecked promise;
   if the handler throws after the call, the registry entry orphans.
2. **Binding is opt-in** (`bind: true`), even though for a held chain
   it's almost always what you want — the common case carries
   boilerplate, and forgetting `bind` silently fires a separate chain.

## Goal

- **Drop `bind: true`.** A fetch issued from a handler that ends up
  *held* (`next()`/`stream()`) **auto-binds** to that chain — chunks
  resume the chain's `onFetchChunk`.
- **Add `detach: true`** as the explicit opt-out: fire-and-forget /
  separate-chain (today's no-bind Pattern A; `on_chunk` still names
  the separate handler).
- **Register at handler-success time**, when the outcome is known —
  not at the binding call. Fixes the orphan-on-throw bug and is what
  makes auto-bind possible (you can't decide "bind" until you know the
  handler held the chain).

## New semantics

| handler outcome | default (no `detach`)            | `detach: true`        |
|---|---|---|
| held (`next`/`stream`) | **auto-bind** → `onFetchChunk` | detached (Pattern A)  |
| terminal `Response`    | detached (no chain to bind to) | detached (Pattern A)  |

- A **terminal** handler has no chain, so its fetches are always
  detached — unchanged from today's behavior.
- The behavior change is for **held** handlers: their fetches now
  auto-bind instead of needing `bind: true`. Existing held handlers
  used `bind: true` (the documented pattern), so they keep working;
  the keyword just becomes unnecessary.
- `on_chunk` is now meaningful only for **detached** fetches (it names
  the separate chain's handler). Auto-bound fetches ignore it and use
  the chain's `onFetchChunk`.

### Decision: held handler, non-detached fetch, no `onFetchChunk`

A held handler that fetches without `onFetchChunk` and without
`detach` has nowhere to put chunks. Chosen behavior:

- **Runtime:** still auto-bind; a chunk that resumes a missing
  `onFetchChunk` surfaces as the existing missing-export resume error
  (logged, chunk dropped) — not silent.
- **Deploy-time:** the loader's existing export validation
  (`handler-shape.md` §6) warns: *"this module issues `http.fetch`
  from a held handler but exports no `onFetchChunk`; add it to handle
  chunks, or pass `detach: true` for fire-and-forget."*

Fail-loud, guided, no "bound to a void" silent drop. (Alternative
considered: auto-fall-back to detached when no `onFetchChunk` — but
that makes the destination depend on an export's presence, which is
more surprising than a clear warning + error.)

## Mechanism — registration at the success seam

`bindings/http.zig` stops registering at the call. It just
accumulates the `PendingFetch` (as today) plus the new `detach` flag,
and drops the call-time `activation_entity`/`register_bound_fetch`
requirement (a held chain may not exist yet — that's fine now).

At the success seam in `worker_dispatch.zig` — right after
`runOutcome` returns and the outcome (`.terminal` / `.continuation` /
`.stream`) + the request's entity `ent` are both in hand, before the
`PendingFetch`es flush via `enqueuePendingFetches` — decide per fetch:

```
held = (outcome == .continuation or outcome == .stream)
for each pending fetch pf:
    if held and not pf.detach:
        registerBoundFetch(pf.id, ent)   // fetch_id→entity, owner, count++
        pf.bind = true                    // engine routes chunks to the owner
    else:
        pf.bind = false                   // detached: Pattern A / fire-and-forget
```

Then flush as today. On handler error/throw, `pending_fetches` are
discarded before this point → no registration → orphan bug gone.

`bind` on `PendingFetch` / `UpstreamFetchEvent` stays (it's the
wire-level "this chunk routes to the held owner" flag); it's just set
at success from the outcome instead of carried from a JS keyword.

## Phasing

1. **Relocate registration to the success seam, keep `bind: true`
   semantics.** Binding accumulates + (new) carries `detach`; the
   success seam registers bound fetches from `bind && held`. No
   default flip yet (`bind: true` still required to bind). Verify the
   existing bound-fetch + heldsync smokes are byte-identical. This
   slice is semantics-preserving and fixes the orphan-on-throw bug on
   its own.
2. **Flip the default.** `held && !detach` auto-binds; `bind` becomes
   a no-op accepted-but-ignored alias (or removed). Add `detach`
   parsing. Update demo handlers (`boundproxy`, `spoolsink`,
   `multibind`, `spoolcancel`) to drop `bind: true`; update any that
   wanted a separate chain to `detach: true`.
3. **Docs + validation.** Rewrite `handler-shape.md` §5.5/§5.7 +
   `streaming-model.md` §7 for auto-bind; add the §6 deploy-time
   warning; remove `bind` from `globals/http.js` (or mark deprecated).

## Files

- `src/js/globals/http.js` — drop `bind` doc, add `detach`.
- `src/js/bindings/http.zig` — parse `detach`; stop call-time
  register; carry `detach` into `PendingFetch`.
- `src/js/globals.zig` (`PendingFetch`) + `components.zig`
  (`BuiltFetch`) — add `detach` field.
- `src/js/worker_dispatch.zig` — success-seam bind decision +
  registration before `enqueuePendingFetches` (both the read-only and
  write/finalize flush paths).
- Demo handlers + smokes — drop `bind: true`, use `detach` where a
  separate chain was intended.
- `docs/handler-shape.md`, `docs/streaming-model.md`.

## Verification

- The bound-fetch smokes now *are* the auto-bind tests: the demo
  handlers (`boundproxy`, `spoolsink`, `multibind`, `spoolcancel`)
  dropped `bind: true`, so `bound_fetch_smoke`,
  `bound_fetch_large_body_smoke`, `bound_fetch_spool_smoke`,
  `bound_fetch_spool_cleanup_smoke`, `bound_fetch_multiworker_smoke`
  all exercise auto-bind (held handler, no keyword → binds).
- `fetch_chunk_smoke`/`_tape` cover the **detached** path (a terminal
  handler's fetch → Pattern A). `detach: true` from a held handler
  routes through the identical `pf.bind = false` branch, so it's the
  same code path.
- `heldsync_smoke`/`_multiworker` confirm `webhook.send` (which sets
  `bound_send_id`) is correctly **excluded** from auto-bind.
- No dedicated orphan-on-throw smoke: a throwing handler's entity is
  destroyed (500 → `cleanupResponses` → `scanAndCancelBoundFetches`),
  which already unregisters — so even the old call-time registration
  was cleaned on destroy. Success-time registration just avoids the
  register-then-cleanup churn; the real driver is auto-bind needing
  the outcome.
