# Phase 5.5 rollout — multi-node production readiness

This document is the **orchestration plan** across the five Phase 5.5
sub-plans. Each sub-plan (`logs-plan.md`, `webhook-server-plan.md`,
`snapshot-plan.md`, `files-server-plan.md`, plus the in-PLAN tape body
capture work) describes the implementable detail for one subsystem.
This doc tracks ordering, dependencies, status, and the cross-cutting
"definition of production-ready" so future sessions can pick up the
work without re-deriving the sequence.

The motivating context: PLAN.md commits to a "first customer can take
real production traffic" boundary at the end of Phase 5.5. Specifically
that means a node operator (loop46-the-project, in the v1 case) is
willing to take responsibility for paying customer data. Today the
shipped code can run multi-node, but not without operational gaps that
would bite under sustained traffic or leader failover (see PLAN §12
"Multi-node setup"). Phase 5.5 closes those gaps.

## Ordering rationale

The five pieces are ordered by **dependency × risk × value**:

1. **Tape body capture (b)** first — smallest, most contained,
   infrastructure pre-staged (`LogRecord.tape_refs`, `LogStore.blob`).
   Doesn't touch raft path. Good way to learn the codebase shape with
   bounded blast radius. Without it, multi-node tape replay 404s for
   old request IDs after leader change, which is the most user-visible
   gap.

2. **Webhook subsystem (d)** next — biggest engineering risk because
   it touches the raft entry layout (multi-envelope-per-raft-entry),
   the apply path (envelopes 4/5/6), the dispatcher (envelope-4 rides
   with envelope-0 atomically), AND adds a new leader-pinned thread.
   Should land second so its testing pressure validates the
   raft-entry-layout change before more subsystems depend on it.

3. **Logs (a)** — log-server moves to its own subdomain with TLS,
   batches to S3 directly, sidecar-indexed. Drops envelope type 1.
   Independent of (b)/(d) but builds on the pattern of "subsystem on
   own subdomain with JWT-handoff auth from worker."

4. **Files-server (e)** — same pattern as (a): own subdomain, S3
   manifest, marker-driven release, drops envelope type 3. Reuses the
   JWT-handoff machinery from (a).

5. **Snapshot (c)** — most subtle (per-tenant snapshot indices,
   always-refresh discipline, S3 transport). Last because (a) + (e)
   reduce raft.log.db pressure (envelopes 1 + 3 retire), buying time
   to land snapshots without the disk-fill clock running.

Each step is independently shippable + smoke-testable per its
sub-plan's migration order. No big-bang cutovers between them.

## Per-piece status

### 1. Tape body capture — **done 2026-05-05**

**What it delivers**: request and response bodies stored
content-addressed in the per-tenant blob backend
(`{inst.dir}/log-blobs/`); log records carry the hash + meta only.
Replay path resolves blobs by hash. Truncation marker preserved so
the simulator (Phase 12) sees the same bytes.

**Why it's first**: smallest contained piece; pre-staged
infrastructure means it's mostly wiring; doesn't touch raft path so
no risk of breaking the kv hot path; closes the biggest user-visible
multi-node gap (replay-after-failover).

**Definition of done**:
- Request body capture site writes the body bytes to
  `LogStore.blob`, computes the hash, populates the matching
  `tape_refs` entry on `LogRecord`. Truncation cap = 256 KB from
  PLAN §2.4 (`max_event_payload_bytes`); truncation flag preserved
  in the tape entry.
- Response body capture site does the same for outbound bytes.
- Replay path reads the hash from the log record, fetches bytes via
  `LogStore.blob`, hands them to the simulator / replay UI.
- Smoke test in `scripts/` exercises the end-to-end flow:
  fire a request with a body > 1 KB, observe `tape_refs` in the
  resulting log record, fetch the blob by hash, verify byte-equal.
- Existing log smoke tests still pass (no regression).
- Documented in PLAN §9 status block.

**Sub-plan**: PLAN §3 Phase 5.5 (b) is the spec; no separate
sub-plan because the work is contained.

### 2. Webhook subsystem — **in progress (step 1 done 2026-05-05)**

- **Step 1 — done.** `src/webhook_server/root.zig` ships: `WebhookRow`,
  `WebhookStore` (kv-backed at `{data_dir}/webhooks.db`), apply
  primitives `applyEnqueueBatch` / `applyComplete` /
  `applyRetrySchedule`, and the wire-format encode/decode for
  envelope types 4 / 5 / 6. Module wired into `build.zig`; unit
  tests cover envelope round-trips, idempotent enqueue, retry
  schedule, missing-row no-op completes. The kv-backed store is the
  step-1 stand-in for the real partial-index sqlite schema; step 2
  swaps in the schema-from-webhook-server-plan.md §2.2 when the
  delivery loop's "ready rows" query needs the index.
- Remaining steps (per webhook-server-plan.md §7):
  2. **Apply path integration** — add envelope types 4/5/6 to
     `src/js/apply.zig`'s `EnvelopeType` enum + introduce
     multi-envelope-per-raft-entry wrapper (envelope type 7). Wire
     `applyOne` dispatch to the new types. ApplyCtx gets a
     `webhooks_store: ?*WebhookStore` lazily opened on first
     webhook envelope.
  3. **Webhook-server thread** — leader-pinned spawn/stop,
     delivery loop reading `WebhookStore`, raft proposer for
     envelopes 5/6.
  4. **Dispatcher cutover** — `webhook.send` accumulates per-handler
     into a webhook batch on the dispatch state. Combined propose
     at handler-batch commit emits a multi-envelope (type 7)
     containing envelope 0 (writeset) + envelope 4 (webhook batch).
     Behind feature flag `webhook.path = drainer | direct`.
  5. **Cut over to `direct`** in dev, run all webhook smokes,
     verify `_outbox/*` empty during steady state.
  6. **Drop the feature flag** + **delete `src/outbox/drainer.zig`**.

**What it delivers**: cluster-wide raft-replicated `webhooks.db`,
new envelope types 4 (enqueue batch), 5 (complete), 6 (retry
schedule), multi-envelope-per-raft-entry support so envelope 4
rides with envelope 0 in the same raft entry, leader-pinned
`webhook-server` thread inside the loop46 binary that owns the
delivery loop. Drops `src/outbox/drainer.zig` outright. Drops
`_outbox/*` / `_outbox_inflight/*` / `_dlq/*` per-tenant prefixes.

**Why second**: highest engineering risk in Phase 5.5; getting it
done early means the multi-envelope-per-raft-entry change is
battle-tested before later subsystems lean on it (none currently
do, but the option to use it stays open).

**Definition of done**: see `docs/webhook-server-plan.md` §7
"Migration order." The 6 steps land independently; smoke tests in
each step.

**Sub-plan**: `docs/webhook-server-plan.md`.

### 3. Logs — **not started**

**What it delivers**: log-server runs on its own subdomain
(`logs.{public_suffix}`) with its own TLS and JWT-handoff auth.
Worker batches log records in memory and PUTs `.ndjson.gz` payloads
+ `.idx.json` sidecars directly to S3. log-server polls sidecars,
maintains a local SQLite `log_index.db`, serves dashboard queries.
Drops envelope type 1, per-tenant `log.db`, and the worker's
`/_system/log/*` proxy.

**Definition of done**: see `docs/logs-plan.md` §10 (final cleanup)
and the migration sequence above it.

**Sub-plan**: `docs/logs-plan.md`.

### 4. Files-server architectural move — **not started**

**What it delivers**: files-server moves to its own subdomain
(`files.{public_suffix}`), manifest in S3
(`tenants/{id}/deployments/{dep_id}.json`), runtime release signal
becomes `_deploy/active` kv marker observed via
`markDirtyFromWriteset`. Worker drops `files.db` per tenant, the
`/_system/files/*` proxy, and envelope type 3.

**Definition of done**: see `docs/files-server-plan.md` §9
"Migration order."

**Sub-plan**: `docs/files-server-plan.md`.

### 5. Snapshot — **not started**

**What it delivers**: per-tenant snapshot indices with
always-refresh-all-tenants discipline. Snapshots transport via S3
(per-tenant `app.db` files captured via `VACUUM INTO`,
content-addressed). No global write-pause during capture. Followers
load by downloading from S3 in parallel. Per-tenant `_apply_state`
table filters duplicate applies during catch-up. Replaces the
row-level delta protocol in `src/kv/raft_snapshot.zig`.

**Why last**: most subtle, and (a)+(e) retire two of the
three big envelope-1/envelope-3 contributors to raft log growth,
giving headroom to land snapshots carefully.

**Definition of done**: see `docs/snapshot-plan.md`.

**Sub-plan**: `docs/snapshot-plan.md`.

## Cross-cutting

### Smoke test discipline

Every piece extends or adds a script in `scripts/` that exercises the
new path end-to-end against a running binary. The migration sequences
in each sub-plan list smokes per step. Don't ship a step without its
smoke passing.

### Multi-node testing

Most pieces can be developed and smoked single-node. The pieces that
need actual multi-node testing before production:

- **Webhook subsystem (d)**: leader failover with in-flight webhooks.
- **Snapshot (c)**: leader→follower snapshot transfer + apply.
- **Files-server (e)** + **logs (a)**: shared S3 backend serves
  identical bytes to all nodes (verify with multi-node smoke).

Plan to stand up a 3-node test cluster against a real S3 backend
(probably MinIO locally for inner-loop, OVH/AWS for staging) before
declaring (c) and (d) done.

### Operator-config decisions to make before production launch

- `BLOB_BACKEND=fs` (shared mount) vs `s3` (cloud) vs hybrid (fs for
  blobs, s3 for log/snapshot transport).
- Where the new subdomains terminate TLS: each subsystem listens on
  its own port, or one TLS terminator fans out, or Cloudflare in front
  with origin-only certs.
- `SSE_INTERNAL_TOKEN` (when sse-service ships at 1.0) and
  `files_token_signing_secret` (when files-server detach lands
  post-1.0) — provisioning workflow.

### Definition of "production-ready" for the phase as a whole

All five pieces shipped + each piece's smoke test passing + a 3-node
test cluster runs sustained synthetic load (1k req/s for an hour)
without disk-fill or unbounded raft.log.db growth, and survives a
leader failover with no observed customer-visible loss (webhook
delivery resumes; tape replay works for old request IDs; logs remain
queryable; deploys still apply).

That's the bar that justifies taking responsibility for a paying
customer's data.

## Status legend

- **not started** — no commits against this piece yet.
- **in progress** — at least one commit; sub-plan migration steps
  partially done.
- **done** — all migration steps shipped, smoke passes,
  documented in PLAN §9.
