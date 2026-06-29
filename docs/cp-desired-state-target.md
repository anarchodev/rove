# Target: CP-owned tenant desired-state + key consolidation

**Status: north-star, not yet built.** This captures an architecture target
that emerged from the Step 3 auth work (`step3-auth-plan.md` B4). It is the
direction the B3/B4 increments point at; it is *not* an active build plan. B3
and B4 (the `rewind-cp.internal` door) are both done (`step3-auth-plan.md`
§B4 — door done/verified; only its delivery rides a prod publish); the
declarative core below (steps 3–5) is the unstarted arc.

## The idea

Make the **control plane the single source of truth for all per-tenant
desired-state** — placement, plan, host aliases, **and release** — and have
**workers reconcile** to match, over the one CP↔worker S2S channel
(`REWIND_MOVE_SECRET`). Today release is *imperative* (the operator POSTs
`/_system/release dep_id` straight at the worker, root-token-gated). Inverting
it to *declarative* ("CP holds tenant X → release Y; converge the data plane")
turns the worker's `/_system/*` operator surface into a **CP-facing** surface
(move-secret only) and lets the **root token retire**.

End state:
- **OIDC for all day-to-day** — humans → dashboard → CP sets desired state.
- **`REWIND_MOVE_SECRET` is the one internal key** — CP↔worker reconcile, and
  the operator's break-glass (operator → CP directly when the dashboard is
  down). "Conceptually there is only the move-secret."
- **`REWIND_ROOT_TOKEN` eliminated** — the worker `/_system/*` operator surface
  becomes CP-facing (move-secret), so there is no operator-held worker key.

## Why (the payoff is declarative state, not the key count)

The one-key tidiness is secondary. The substantive win is **self-healing
declarative state** — the property B3 (CP owns host→tenant) and B4 (CP owns the
ops) already reach for, generalized to *all* tenant state:
- a node **down during a release** catches up on rejoin (CP re-asserts);
- a **newly-added node** gets the current release automatically;
- **no release-pointer drift** — the CP is authoritative; workers converge.

This is the same shape as the CP membership reconciler
([`cp-membership-reconciler-plan.md`](cp-membership-reconciler-plan.md)) —
desired state in the CP, converge the data plane — and would share that
reconciler substrate.

## The per-verb reality (they don't all reconcile cleanly)

- **`release`** — flip `_deploy/current` to a dep_id. **Cleanly** becomes
  desired-state + reconcile; it's a pointer.
- **`deploy`** — decomposes. **Staging** (compile bundle → blobs + manifest →
  dep_id) needs a **JS runtime** to compile; the CP has none, so staging stays a
  worker / `__admin__`-app op, triggered via **OIDC** (the dashboard composes it
  with `platform.compile`/`blob`/`stampManifest` — where B2 already puts it).
  Only the **release** that follows is CP-reconciled. So "deploy" =
  OIDC-staging + CP-reconciled-release, not a single CP task.
- **`reset`** — the genuine break-glass (redeploy the *baked* `__admin__` app
  when it's bricked). Make it a **CP-mediated** worker op (CP→worker, move-
  secret); the operator hits the **CP directly** for break-glass. **No chicken-
  egg** — the CP is a separate binary from the bricked `__admin__` app. This is
  what lets the root token go entirely.

## Incremental path

1. **B3** ✅ — CP owns `host → tenant`, propagates the worker alias.
2. **B4** ✅ (door done/verified; delivery rides a prod publish) —
   `rewind-cp.internal` door: the operator's CP ops (provision/move/host/plan)
   flow through the OIDC dashboard; move-secret leaves the *day-to-day* shell.
3. **release reconciler** — CP stores desired release per tenant; push-on-change
   + periodic/rejoin convergence to workers (move-secret). Release leaves the
   worker-direct/root-token plane.
4. **reset via CP** — operator → CP (break-glass) → worker reset; the worker
   `/_system/*` operator surface becomes move-secret/CP-facing only.
5. **retire `REWIND_ROOT_TOKEN`** — nothing operator-facing needs it.

Steps 3–5 are the larger arc beyond Step 3; they subsume B4's intent and retire
the root token. Capture here so the incremental B3/B4 work stays pointed at it.

## Considered

- **Why not fold move-secret into the services-JWT HMAC** — rejected in
  `rewind-cli-plan.md` §7 (the HMAC is the busy key, likeliest to leak; the
  rarely-used high-destruction orchestration key stays separate). This target
  does the opposite consolidation — it removes the *root token*, not the
  move-secret, and keeps move-secret as the single quiet high-privilege key.
