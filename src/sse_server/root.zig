//! rove-sse-server — the centralized SSE notification service that
//! replaces the in-worker `_events/{sid}/...` storage + pump model.
//! See `docs/sse-plan.md` for the full design.
//!
//! Shape, briefly:
//!
//!   worker  ──POST /v1/emit──▶  sse-server  ──text/event-stream──▶  browser
//!                                  │
//!                                  ├── per-(tenant, sid) ring cache
//!                                  │   (RING_CAPACITY entries; bounded
//!                                  │   reconnect catch-up only — not a
//!                                  │   durable store)
//!                                  └── per-tenant connection list with
//!                                      live h2 streams
//!
//! Sub-modules:
//!   - `standalone` — h2 listener, ring cache, connection table, the
//!                    three routes (`GET /v1/health`, `POST /v1/emit`,
//!                    `GET /v1/{tenant}/sse`).

pub const standalone = @import("standalone.zig");

test {
    _ = standalone;
}
