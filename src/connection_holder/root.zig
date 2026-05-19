//! rove-connection-holder — the subsystem that owns long-lived held
//! sockets so handlers never do. See `docs/connection-actor-plan.md`
//! for the full design; this is the primitive under SSE, WebSockets,
//! held-synchronous third-party calls, and the atproto firehose.
//!
//! The shipped sse-service (`src/sse_server/`) is unchanged by this —
//! the connection-holder is a *sibling* subsystem (plan §9), mirroring
//! its isolation discipline: own h2 listener, own connection table,
//! zero handler-side connection state. The worker pends writes / reads
//! handles; it never owns a socket.
//!
//! Build phasing (tracked outside the tree):
//!   - Phase 1 (this commit): subsystem skeleton — listener, the
//!     connection table keyed by a serializable connection-id, the
//!     readiness collection, and the ability to accept + park a held
//!     connection with a holder-level deadline. No wakes into the JS
//!     handler yet.
//!   - Phase 2: wake dispatch + the `open` wake (degenerate §6.1).
//!   - Phase 3: the held-synchronous third-party call (§6.4).
//!
//! Shape, briefly (Phase 1):
//!
//!   client ──socket──▶ connection-holder
//!                          │  parks the h2 request entity (stream
//!                          │  stays open, client waits)
//!                          ├── connection table: id → {stream, frontier
//!                          │   cursor, pending-write buffer, armed
//!                          │   deadline, version counter}
//!                          └── readiness queue (collection membership;
//!                              plan §3 — drained, never O(N) scanned)
//!
//! Sub-modules:
//!   - `standalone` — h2 listener, connection table, readiness queue,
//!                    routes (`GET /v1/health`, the Phase-1 `hold`
//!                    park route).

pub const standalone = @import("standalone.zig");

test {
    _ = standalone;
}
