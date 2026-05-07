//! rove-log-server — Phase 5.5 (a) standalone log-server module.
//!
//! Worker → BatchStore (S3 or fs, via `flush_writer`) → indexer
//! (`indexer.zig`) → sqlite local index (`index_db.zig`) → query
//! API (`standalone.zig`). After Phase 5.5(a) Task #61 the loop46
//! worker no longer spawns log-server in-process; operators run
//! `examples/log_server_standalone.zig` as a separate process and
//! point the worker at it via `--log-public-base`. Both processes
//! share `LOOP46_SERVICES_JWT_SECRET` for the JWT mint/verify
//! handoff and the same `BLOB_BACKEND` config so the standalone
//! reads what the worker writes.
//!
//! Sub-modules:
//!
//! - `sidecar`    — JSON wire format for `.idx.json` files
//! - `batch_store` / `batch_store_s3` / `batch_store_fs` — vtable
//!                 + S3, fs, and (test-only) memory backends
//!                 holding `.ndjson` payloads + `.idx.json`
//!                 sidecars per tenant
//! - `index_db`   — SQLite schema + queries (`queryList`,
//!                 `queryShow`, `queryCount`)
//! - `indexer`    — background loop that polls the BatchStore for
//!                 new sidecars and inserts into IndexDb
//! - `standalone` — h2 server (`/v1/{tenant}/{list,show,count,blob}`)
//! - `flush_writer` — worker-side ndjson + sidecar encoder

pub const sidecar = @import("sidecar.zig");
pub const batch_store = @import("batch_store.zig");
pub const batch_store_s3 = @import("batch_store_s3.zig");
pub const batch_store_fs = @import("batch_store_fs.zig");
pub const index_db = @import("index_db.zig");
pub const indexer = @import("indexer.zig");
pub const standalone = @import("standalone.zig");
pub const flush_writer = @import("flush_writer.zig");

test {
    _ = sidecar;
    _ = batch_store;
    _ = batch_store_s3;
    _ = batch_store_fs;
    _ = index_db;
    _ = indexer;
    _ = standalone;
    _ = flush_writer;
}
