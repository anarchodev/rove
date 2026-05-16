# Phase 5.5 rollout — multi-node production readiness

This document is the **orchestration plan** across the five Phase 5.5
sub-plans. Each sub-plan (`logs-plan.md`, `http-send-plan.md`
(supersedes `webhook-server-plan.md`), `snapshot-plan.md`,
`files-server-plan.md`, plus the in-PLAN tape body capture work)
describes the implementable detail for one subsystem.
This doc tracks ordering, dependencies, status, and the cross-cutting
"definition of production-ready" so future sessions can pick up the
work without re-deriving the sequence.

The motivating context: PLAN.md commits to a "first customer can take
real production traffic" boundary at the end of Phase 5.5. Specifically
that means a node operator (rewind.js-the-project, in the v1 case) is
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

2. **Webhook/http.send subsystem (d)** next — biggest engineering risk
   because it touches the raft entry layout (multi-envelope-per-raft-
   entry), the apply path (shipped as envelopes 4/5/6; then superseded
   2026-05-09 by envelopes 8/9/10/11 + `schedules.db`), the dispatcher
   (envelope-8 rides with envelope-0 atomically), AND adds a new
   leader-pinned thread. Should land second so its testing pressure
   validates the raft-entry-layout change before more subsystems depend
   on it.

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

## Where we are (2026-05-06)

- **(b) tape-body capture — done.** Bodies stored
  content-addressed via the per-tenant `BlobBackend`
  (`{inst.dir}/log-blobs/` for fs, `{S3_KEY_PREFIX_BASE}{tenant}/log-blobs/{hash}`
  for s3); the standalone log-server reads from the same backend.
- **(d) webhooks — done.** Cluster-wide `webhooks.db`, envelope
  types 4/5/6, multi-envelope-per-raft-entry, leader-pinned
  webhook-server thread.
- **(a) logs — done + process split done.** Worker → S3 / fs
  batch store (ndjson + sidecar). Standalone log-server runs at
  `logs.{public_suffix}` with its own TLS listener, JWT-gated
  `/v1/{tenant}/{list,show,count,blob}` (HS256; worker mints at
  `/_system/services-token` after admin auth, dashboard refreshes
  on 401). Per-tenant `log.db` and `Worker.log_proxy` are gone;
  tape body capture flows via the per-tenant `BlobBackend` shared
  between worker + standalone. Task #61 dropped the in-process
  log-server thread from `loop46`; operators run
  `log-server-standalone` separately and point the worker at it
  via `--log-public-base`. New `FsBatchStore` (alongside the
  existing `S3BatchStore` and the test-only `MemoryBatchStore`)
  provides the cross-process worker → standalone batch path under
  `{data_dir}/log-batches/` for fs-backend deploys.
- **(e) files-server — F1 + F2-push + F2-storage + process split done.**
  Files-server runs at `https://files.{public_suffix}` with TLS +
  JWT-gated routes, reusing the same shared HMAC secret as
  log-server. Worker proxy / `code_proxy` / `ProxyTag` / `ProxyPeer`
  / `proxy.zig` / `/_system/files/*` route all deleted (F1).
  Dashboard / CLI now POST `/_system/release {tenant_id, dep_id}`
  on the worker after every successful deploy; the worker's
  process-wide `ReleaseTable` carries the signal across worker
  threads and `applyPendingReleases` triggers the bytecode reload
  on every worker's next dispatch tick (F2-push). Manifest JSON
  lives in a per-tenant `deployments/` BlobBackend
  (`{dep_id:020d}.json`), shared via the same fs/s3 backend as
  file-blobs; the runtime release pointer (`_deploy/current`) lands
  in the tenant's app.db and rides envelope 0 through raft so cold
  starts and follower nodes recover the active deployment without
  files.db (F2-storage). Envelope type 3 / `applyFilesWriteSet` /
  `ApplyCtx.files_stores` / `proposeFilesWriteSet` /
  `FileStore.replicate` all deleted; the worker no longer opens
  files.db at all (files-server keeps a local files.db for its own
  working tree, but the worker reads manifests from
  manifest_backend instead). After Task #62 the in-process
  `files_server.thread.spawn` from `loop46/main.zig` is gone:
  operators run `files-server-standalone` as a separate process and
  point the worker at it via `--files-public-base`.
  `LOOP46_SERVICES_JWT_SECRET` (operator-supplied env, hex
  HMAC-SHA256) shares the JWT key across the two processes;
  `--files-listen` retired from `loop46`. Dev (`scripts/dev_serve.sh`)
  + production (`scripts/rove-loop46-serve.sh`) helpers fork-exec
  the standalone alongside the worker for one-command startup.
- **(c) snapshot — steps 1-4 + periodic loop done; by-reference
  reuse + willemt log-compaction deferred.**
  `_apply_state` per-store table + per-entry idempotency filter
  (step 1), in-memory `ApplyCtx.tenant_apply_idx` mirror
  (step 2), end-to-end capture orchestrator + manifest JSON
  shape (`src/loop46/snapshot.zig`, step 3a), follower-side
  `restore()` + atomic-rename + `_apply_state` stamp (step 4),
  and operator CLIs `loop46 snapshot --data-dir ...` /
  `loop46 restore-from-snapshot --snap-id ...` driven by the
  same `BLOB_BACKEND` env contract as files / logs (S3 with
  `SNAPSHOT_S3_KEY_PREFIX` namespacing or fs at
  `{data_dir}/.snapshots/`). `scripts/snapshot_smoke.py`
  exercises seed → capture → restore round-trip against
  either backend; verified end-to-end against real OVH S3.
  An in-process periodic capture loop has shipped
  (`--snapshot-interval-ms` flag in `src/loop46/main.zig`).
  By-reference reuse for unchanged tenants and the willemt
  `raft_begin_snapshot` / `raft_end_snapshot` log compaction
  wiring stay deferred.

**Next pickup:**
1. **(c) snapshot — see `docs/snapshot-plan.md`.** With (a) and
   (e) F2-storage done, the largest remaining source of raft log
   growth is webhook replay; snapshot work is the natural next
   storage-scalability piece.

Detail per piece below.

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

### 2. Webhook subsystem — **done 2026-05-06**

> **Corrigendum:** piece (d) shipped 2026-05-06 then was
> **SUPERSEDED 2026-05-09** by the more general `http.send`
> primitive — see `docs/http-send-plan.md`. envelopes 4/5/6,
> `webhooks.db`, `src/webhook_server/`, and `src/outbox/` were
> deleted; the live design is envelopes 8/9/10/11 +
> `schedules.db` + `src/schedule_server/`. The sub-plan
> `webhook-server-plan.md` no longer exists; its replacement is
> `http-send-plan.md`.

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
- **Step 2 — done.** `EnvelopeType` extended with
  `webhook_enqueue_batch=4`, `webhook_complete=5`,
  `webhook_retry_schedule=6`, and `multi=7` (length-prefixed
  inner-envelope wrapper). `applyOne` dispatches each envelope type;
  `ApplyCtx.webhooks_store` opens `{data_dir}/webhooks.db` lazily on
  first webhook envelope. Webhook envelopes do NOT leader-skip — both
  leader and follower apply. Envelope 5's cross-db apply
  (`_callback/{id}` → tenant app.db, then DELETE → webhooks.db) uses
  sequential idempotent ordering per webhook-server-plan §8.1's
  fallback path. Tests cover envelope round-trips, multi-wrapper
  wrap/unwrap across mixed inner types, truncated-payload rejection,
  and `buildCallbackJson` (delivered + failed) parses with std.json
  matching the schema `callback_dispatch.zig` consumes.
- **Step 3 — done.** `src/webhook_server/thread.zig` ships a leader-
  pinned poll loop that scans `webhooks.db` via the new
  `WebhookStore.readyRows`, POSTs ready rows through `outbox/http_client`
  (SSRF-checked), classifies the response, and proposes envelope 5
  (`webhook_complete`) or envelope 6 (`webhook_retry_schedule`)
  through the local raft node. Wired into `loop46/main.zig` alongside
  the legacy drainer (both gate on leader; never run concurrently on
  a follower). Smoke (`scripts/webhook_server_smoke.sh`) injects a
  row via the new `webhook-test-enqueue` helper, watches the python
  echo target receive the POST with stamped metadata headers, and
  verifies envelope 5 applied + the existing `dispatchCallbacks`
  invoked the customer's `onResult` handler. Lease columns reserved
  for cross-leader handover; v1 uses an in-memory in-flight set
  during a single leader's tenure.
- **Step 4 — done.** CLI flag `--webhook-path drainer|direct`
  (default `drainer`) plumbs through `WorkerConfig.webhook_path` →
  `Worker.webhook_path` → worker_dispatch's per-batch `pending_webhooks`
  accumulator (allocated only in direct mode). `webhook.send` branches
  on `state.pending_webhooks`: direct → extract a `WebhookRow` from
  the JSON envelope and append (no `_outbox/{id}` write); drainer →
  legacy path. `finalizeBatch` proposes via the new
  `raft_propose.proposeBatchAndWebhooks` helper which picks: both →
  type-7 multi (env 0 + env 4); writes only → bare env 0; webhooks
  only → bare env 4. Customer response still gated on raft commit so
  both halves are durable cluster-wide before the user sees 200.
  Smoke (`scripts/webhook_direct_smoke.sh`): exercises the cbfire
  handler that does `kv.set` + `webhook.send`, verifies env 0 +
  env 4 + envelope 5 + callback all fire, and that `_outbox/*` is
  empty under direct mode. Per-handler savepoint discipline for the
  accumulator mirrors the existing flat writeset shape — neither has
  per-savepoint rollback; the plan's "structurally identical" framing
  documents this.
- **Step 5 — done.** `--webhook-path` default flipped from `drainer`
  to `direct` (`WorkerConfig.webhook_path` matches). All three
  webhook smokes pass with the new default; `webhook_direct_smoke`
  verifies `_outbox/*` is empty during steady state. The legacy
  `--webhook-path drainer` flag still works for rollback safety
  during the one-release window before step 6 deletes it.
- **Step 6 — done.** Drainer + flag deletion. `src/outbox/` removed
  entirely; `ssrf.zig` + `http_client.zig` moved into
  `src/webhook_server/` (their only consumer). `WebhookPath` enum,
  `--webhook-path` CLI flag, `WorkerConfig.webhook_path`, and
  `Worker.webhook_path` all stripped — direct is the only path.
  `webhook.send` simplified: extracts a `WebhookRow` from `opts`
  directly, throws if `pending_webhooks` is null (production
  worker_dispatch always allocates it). `loop46/main.zig` no longer
  imports rove-outbox or spawns `drainer_handle`; the
  `FsInstanceProvider` walker (drainer's tenant snapshot) is gone.
  `_outbox/`, `_outbox_inflight/`, `_dlq/` stay in `reserved.zig`'s
  PLATFORM_KV_PREFIXES list (forward-compat hygiene; nothing writes
  them now). `webhook_direct_smoke.sh` deleted (redundant with
  `webhook_smoke.py`, which now exercises the direct path by
  default). All smokes pass; dispatcher webhook tests rewritten
  against the `pending_webhooks` accumulator.

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
each step. (Note: webhook-server-plan.md is superseded by
`docs/http-send-plan.md` — see corrigendum above.)

**Sub-plan**: `docs/http-send-plan.md` (supersedes
`docs/webhook-server-plan.md`).

### 3. Logs — **done 2026-05-06 (Steps A + B both shipped)**

**What it delivers**: log-server runs on its own subdomain
(`logs.{public_suffix}`) with its own TLS and JWT-handoff auth.
Worker batches log records in memory and PUTs `.ndjson.gz` payloads
+ `.idx.json` sidecars directly to S3. log-server polls sidecars,
maintains a local SQLite `log_index.db`, serves dashboard queries.
Drops envelope type 1, per-tenant `log.db`, and the worker's
`/_system/log/*` proxy.

- **Step 2 — done.** Standalone log-server binary
  (`log-server-standalone`) ships indexer thread + h2c query API on
  loopback. New `src/log_server/` modules: `sidecar.zig` (JSON
  encoder/parser), `batch_store.zig` (vtable + filesystem backend),
  `index_db.zig` (SQLite schema + insert + queryList +
  queryShow), `indexer.zig` (full-scan polling loop with `INSERT
  OR IGNORE` dedup), `standalone.zig` (h2 routes
  `/v1/{tenant}/list` + `/v1/{tenant}/show/{request_id}`). Smoke
  populates a local batch-store dir and exercises 9 assertions
  end-to-end (newest-first, pagination, cross-tenant isolation,
  range-read /show, 404/405, incremental indexing). Cursor-based
  LIST optimization sketched in plan §4.3 deferred to v2 — full
  scan + DB-side dedup avoids the cross-tenant interleave bug.
- **Step 3 — done.** Worker gains `--log-backend raft|s3` (default
  `raft`). When `s3`, `flushLogs` builds `.ndjson` + `.idx.json` via
  the new `flush_writer` and PUTs to a `BatchStore`. `LogStore`
  gains `drainRecords` (sibling to `drainBatch`) so the s3 path
  gets per-record offsets for the sidecar. `loop46/main.zig`
  constructs a process-global `FilesystemBatchStore` rooted at
  `LOG_BATCH_STORE_DIR` env (or `{data_dir}/log-batches`). The
  S3-backed `BatchStore` lands in a follow-up before the default
  flips in step 5; fs is enough to validate the worker integration.
  Smoke (`scripts/log_backend_s3_smoke.py`) drives the worker's s3
  path end-to-end: 3 acme requests → flush_writer sidecars on disk
  → standalone log-server indexes them → /list returns the records
  → /show round-trips via range-read.
- **Step 3a — done.** `S3BatchStore` ships in
  `src/log_server/batch_store_s3.zig`. Mirrors `S3BlobStore`'s sigv4
  plumbing but adds the two ops the BlobStore doesn't have: `Range`-
  header `getRange` for /show range-reads, and ListObjectsV2 with
  `prefix=` + `start-after=` (XML response parsed with a tight
  `<Key>...</Key>` substring scan). `FilesystemBatchStore` deleted
  entirely — the design is S3-only after step 3a; an in-process
  `MemoryBatchStore` keeps unit tests hermetic. `loop46/main.zig`
  reads the same env vars as `BLOB_BACKEND=s3` plus an optional
  `LOG_S3_KEY_PREFIX`; standalone log-server CLI dropped
  `--batch-store-dir` for the same env-driven config. Smoke
  (`scripts/log_backend_s3_smoke.py`) hits the real OVH `replaykv`
  bucket end-to-end. Two sigv4/std.http gotchas caught + fixed:
  added `query_canonical` opt-out to sigv4 to avoid double-encoding
  pre-canonicalized query strings; the wire URL must include the
  query string (otherwise std.http forwards a query-less URL while
  sigv4 signs a populated one, mismatching AWS's canonicalization).
- **Step 4 — done.** `WorkerConfig.log_backend` + the CLI default
  flipped from `raft` to `s3`. All worker-spawning smokes that don't
  exercise the new log path get explicit `--log-backend raft` so
  they don't need S3 env. The existing `/_system/log/*` proxy
  returns empty results under the default now (worker writes to S3,
  not per-tenant `log.db`); the proxy stays around for one-release
  rollback safety + because `replay` still uses per-tenant
  `log-blobs/` for tape blobs. Skipping the optional step 9
  migration helper per direction.
- **Steps 5+7+8 (compressed) — done 2026-05-06.** Raft log WRITE
  path deleted. Removed: `flushOneRaft`, `WorkerConfig.log_backend`,
  the `LogBackend` enum, the `--log-backend` CLI flag, envelope
  type 1, `applyLogBatch`, `RaftLogHandle`, `ApplyCtx.log_stores`,
  `ApplyCtx.blob_backend_cfg` (was log-only). The dispatcher's
  envelope dispatch table no longer carries `.log_batch`; the
  decoder still rejects type=1 as `UnknownEnvelopeType` so a stale
  raft entry surfaces loudly rather than silently mis-applying.
  `loop46/main.zig` made the S3 batch-store wiring lenient — when
  the `S3_*`/`AWS_*` env vars aren't set, `log_batch_store` stays
  null and `flushLogs` drops records with a one-line warn (dev /
  smoke path; production wires real S3). 14 smokes lost
  `--log-backend raft` (flag is gone); admin_smoke + proxy_smoke
  lost their `/_system/log/*` round-trip assertions (kept the auth
  401 gate); replay_smoke skips entirely until the read-side
  migration to S3 lands. KEPT for one more release: TenantLog +
  per-tenant `log.db` (still needed for `nextRequestSeq`),
  `log-blobs/` directory (tape body blobs), in-process log-server
  thread (returns empty results), `Worker.log_proxy` +
  `/_system/log/*` route (proxies to the now-empty in-process
  server). Step 9 (operator migrate-to-s3 helper) skipped per
  direction.
- **Step A — read-side migration to S3 (done 2026-05-06).** The
  legacy in-process log-server thread + `Worker.log_proxy` →
  per-tenant `log.db` path retired. Replay clients now go through
  the worker's `/_system/log/*` proxy (URL-rewritten to `/v1/*`)
  to a loopback `log-server-standalone` spawned in the loop46
  process, which reads `LogRecord`s from the shared S3
  `BatchStore` (or in-memory dev store) via `IndexDb` queries and
  tape blobs from the same per-tenant `BlobBackend` the worker
  writes to.
  - **A1 — done.** Standalone log-server gained
    `/v1/{tenant}/blob/{hash}` backed by a per-tenant
    `BlobBackend` cache.
  - **A2 — done.** Standalone gained `/v1/{tenant}/count` for
    parity. The originally-scoped client-migration work folded
    into A3 (web admin) and A4 (rove-log-cli).
  - **A4 — done.** `nextRequestSeq` lives at
    `_log/next_request_seq` in the per-tenant `app.db`. `LogStore.init`
    gained an `Options{ seq_kv, seq_key }` arg; `_log/` joined
    `PLATFORM_KV_PREFIXES` so customer code can't read or stomp
    the counter.
  - **A3 — done.** Coordinated cutover:
    - `proxy.zig`'s `forwardHeaders` rewrites
      `/_system/log/{rest}` → `/v1/{rest}` (and keeps the existing
      `/_system/files` strip).
    - `loop46/main.zig` spawns the `log-server-standalone` on
      loopback (instead of the legacy thread); the worker proxy
      points at it. The shared `BatchStore` is S3 when the env is
      wired, in-memory `MemoryBatchStore` otherwise — both let
      worker writes flow through to standalone reads in the same
      process.
    - `web/admin/api.js` rewritten for the v1 wire shape (decimal
      request_ids, `{record:...}` unwrap, `{received_ns,
      request_id}` cursor).
    - `LogStore` collapsed to write-side only — `kv`, `blob`,
      `serializeRecord`, `parseRecord`, `serializeBatch`,
      `parseBatch`, `applyBatch`, `writeOne`, `list`, `get`,
      `RECORD_VERSION`, all `FLAG_*` bits, the v1-record fallback,
      and every related test all dropped.
    - `src/log_server/thread.zig` deleted; `src/log_server/root.zig`
      collapsed to just the standalone-side module re-exports.
    - `src/tape/bundle.zig` and `examples/log_cli.zig` deleted —
      the dashboard composes replay bundles via HTTP + the
      standalone server already serves the same data. Web replay
      shell lost its single-file-shape fallback. `examples/dual_worker.zig`
      (the shift-js spike) deleted — superseded by loop46's
      `--workers N`.
    - Worker.openTenantLog no longer opens `log.db`; old `log.db`
      files on disk are inert orphans. `replay_smoke.py` restored
      from its SKIP state and rewritten against the v1 wire shape.
    - **No legacy / migration scaffolding kept.** Pre-launch — no
      need to carry old-format readers or one-shot migrations as
      tech debt.
- **Step B — log-server subdomain + JWT handoff (done 2026-05-06).**
  Standalone log-server gained a TLS listener at `--log-listen`
  (default `127.0.0.1:8083`), reusing the worker's wildcard
  `*TlsConfig`. Auth: `/v1/*` requests must carry
  `Authorization: Bearer <jwt>`; the worker mints HS256 tokens at
  `/_system/log-token` after running its existing admin-auth check
  (cookie or bearer). Tokens expire in 5 minutes; the dashboard
  caches and refreshes ~1 minute before expiry. The JWT secret is
  per-process random (multi-node ops will need a shared env var
  later). Standalone responses carry CORS allow-origin =
  `--admin-origin` so the dashboard at `app.{public_suffix}` can
  call `logs.{public_suffix}` cross-origin. New helpers:
  `src/log_server/auth.zig` (HS256 mint + verify, hand-coded —
  no JWT library) and a `--log-public-base` CLI flag (auto-derived
  from `--public-suffix` + the bound port). With Step B in place,
  `Worker.log_proxy` + the `/_system/log/*` route + `ProxyTag.log`
  + `proxy.zig`'s log-prefix URL rewrite all came out — the
  worker is no longer in the log read path. Sets the template
  files-server (piece 4) reuses verbatim.

**Definition of done**: see `docs/logs-plan.md` §7 (migration
sequence). Each step is independently shippable + smoke-testable.

**Sub-plan**: `docs/logs-plan.md`.

### 4. Files-server architectural move — **F1 + F2-push + F2-storage + process split done 2026-05-06**

**What it delivers**: files-server moves to its own subdomain
(`files.{public_suffix}`), the runtime release signal becomes a
push from the dashboard / CLI rather than a polled kv read, and
the manifest eventually moves from per-tenant `files.db` to S3
(`tenants/{id}/deployments/{dep_id}.json`). Worker drops the
`/_system/files/*` proxy (F1), `refreshDeployments` polling loop
(F2-push), and eventually `files.db` per tenant + envelope type 3
(F2-storage).

**F1 — done 2026-05-06.** Subdomain move + JWT handoff. Files-server
runs at `https://files.{public_suffix}` with its own TLS listener
(reusing the worker's `*TlsConfig`), gates every request on a JWT
verified against the shared services secret. Worker no longer
proxies — `/_system/files/*` route, `code_proxy`, `ProxyTag.code`,
`proxy.zig`, `ProxyPeer`, the `connect/ingest/flush/drain` proxy
loop in main.zig — all deleted. The `/_system/log-token` endpoint
became `/_system/services-token` and now returns both `log_url`
and `files_url`. The HS256 helper extracted from `log_server/auth.zig`
to a new top-level `rove-jwt` module so both standalone services
share. Dashboard's `filesFetch()` mirrors `logFetch()`. CLI
deletion: `rove-js-ctl` removed (legacy h2-client over the proxy);
`scripts/ctl_smoke.py` rewritten as curl + Python JWT mint.
`scripts/proxy_smoke.sh` deleted (its sole purpose — testing the
proxy — gone). Pre-launch sweep: no parallel-write code, no
back-compat fallback, no dual auth shape.

**F2-push — done 2026-05-06.** Push-from-dashboard release signal.
The earlier design (kv `_deploy/active` marker observed via
`markDirtyFromWriteset`) was discarded after the user pointed out
that the dashboard / CLI is the natural orchestrator: it already
knows when a deploy completed, so just have it tell the worker
directly. Implementation: new `/_system/release` system route on
the worker (root-bearer or cookie auth) accepts
`{"tenant_id":"...","dep_id":N}` and writes into a process-wide
`ReleaseTable` (mutex-guarded `StringHashMapUnmanaged(u64)`).
Each worker's dispatch tick calls `applyPendingReleases`, which
walks `tenant_files_map`, looks up the table, and reloads
bytecodes for any tenant whose released id advanced past the
cached `current_deployment_id`. Multi-worker propagation comes
free — every worker reads the same table on every tick. Cold-load
on first request to a fresh tenant still works (lazy-open hits
files.db's `deployment/current`), and a worker restart eagerly
loads the latest deployment in `Worker.create`. Retires:
`refreshDeployments`, `--refresh-interval-ms` CLI flag,
`WorkerConfig.refresh_interval_ns`, `TenantFiles.next_refresh_ns`.
Smokes (`ctl_smoke.py`, `triggers_smoke.py`, `replay_smoke.py`,
`static_smoke.py`, `rate_limit_smoke.py`, `sse_smoke.sh`,
`signup_smoke.py`) updated to POST `/_system/release` (via
`release_deployment` helper in `_smoke_helpers.sh`) after each
files-server deploy. Multi-node propagation deferred; today's
single-node deployments work as designed.

**F2-storage — done 2026-05-06.** Manifests landed in a per-tenant
`deployments/` BlobBackend (`tenants/{id}/deployments/{N:020d}.json`
in s3 mode, `{inst.dir}/deployments/{N:020d}.json` on fs). Files-
server's `deploy` paths now `assembleManifest` from the working
tree, encode JSON via `files.manifest_json.encode`, write to the
manifest backend, and bump a local `deployment/current` next-id
counter in files.db (files-server-private; not replicated). The
runtime release pointer lives in the tenant's app.db at
`_deploy/current`; the `/_system/release` POST commits it locally
and proposes envelope 0 so followers' apply path picks it up.
Worker `openTenantFiles` opens a per-tenant `manifest_backend`
alongside `blob_backend`, drops `files_kv` + `store` + the files.db
open entirely, reads `_deploy/current` from `inst.kv` on cold-load
and parses `{dep_id:020d}.json` into the active maps. Envelope
type 3 (`files_writeset`) gone; `applyFilesWriteSet`,
`ApplyCtx.files_stores`, `getFilesKv`, `proposeFilesWriteSet`,
`encodeFilesWriteSetEnvelope`, `FileStore.replicate`,
`FileStore.setReplicate`, `FileStore.deploy`,
`FileStore.loadCurrentDeployment`, `FileStore.loadDeployment` all
deleted. `deployStarterContent` writes the starter manifest to
manifest_backend and stages `_deploy/current=1` into a writeset
the trampoline commits + proposes via envelope 0.

**Definition of done**: see `docs/files-server-plan.md` §9
"Migration order."

**Sub-plan**: `docs/files-server-plan.md`.

### 5. Snapshot — **partial — operator-CLI + periodic loop done; by-reference reuse + willemt log-compaction deferred**

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
