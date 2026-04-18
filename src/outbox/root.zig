//! rove-outbox — webhook delivery infrastructure.
//!
//! Customers call `webhook.send({...})` inside a handler; the JS
//! global (in `rove-js/globals`) persists the envelope at
//! `_outbox/{id}` in the tenant's app.db, committed atomically with
//! the rest of the handler transaction.
//!
//! This module owns the other half: a drainer thread that scans the
//! per-tenant `_outbox/*` keys on the raft leader, makes the outbound
//! HTTP call via `http_client`, and either deletes the row on success,
//! reschedules it with exponential backoff on retryable failure, or
//! moves it to `_dlq/{id}` on terminal failure. A subsequent commit
//! (slice 3a.5) invokes the `onResult` handler as a callback.
//!
//! Split into small files so the SSRF rule set and the fetch wrapper
//! are each testable in isolation — smoke tests against a real HTTP
//! server live in `scripts/webhook_smoke.sh` once the drainer lands.

pub const ssrf = @import("ssrf.zig");
pub const http_client = @import("http_client.zig");

pub const MAX_BODY_BYTES = http_client.MAX_BODY_BYTES;

test {
    @import("std").testing.refAllDecls(@This());
}
