//! rove-sse-server — the SSE notification service.
//!
//! Post-task-#10 Phase 3 this runs as an **in-process thread** of
//! `loop46` (sibling to the raft thread), spawned by
//! `standalone.spawn(Config)` and gated on `--sse-listen`. The
//! `sse-server-standalone` separate process is retired; the
//! "standalone" name on the submodule is now a misnomer (rename
//! deferred to Phase 4) — the file still owns the h2 listener, the
//! per-(tenant,sid) ring cache, the connection table, and the
//! `applyEmitBatch` core.
//!
//! Shape, briefly:
//!
//!   worker thread  ──Handle.enqueueEmit──▶  SSE thread  ──text/event-stream──▶  browser
//!                       (in-process queue)         │
//!                                                  ├── per-(tenant, sid) ring cache
//!                                                  │   (RING_CAPACITY entries; bounded
//!                                                  │   reconnect catch-up only — not a
//!                                                  │   durable store)
//!                                                  └── per-tenant connection list with
//!                                                      live h2 streams
//!
//! See `docs/sse-plan.md` + `docs/connection-actor-plan.md` §6.2 for
//! the design.
//!
//! Sub-modules:
//!   - `thread` — h2 listener, ring cache, connection table, two
//!                routes (`GET /v1/health`, `GET /v1/{tenant}/sse`),
//!                the in-process emit queue (`Handle.enqueueEmit`
//!                → `drainEmitQueue` → `applyEmitBatch`). Renamed
//!                from `standalone` in task #10 Phase 4 (it's a
//!                loop46 thread now, not a standalone process).

pub const thread = @import("thread.zig");

test {
    _ = thread;
}
