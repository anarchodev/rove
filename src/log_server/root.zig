//! rove-log-server — Phase 5.5 (a) standalone log-server module.
//!
//! Worker → S3 (via `flush_writer`) → indexer (`indexer.zig`) →
//! sqlite local index (`index_db.zig`) → query API
//! (`standalone.zig`). The standalone binary lives at
//! `examples/log_server_standalone.zig`; loop46 also spawns one
//! in-process so the worker's `/_system/log/*` proxy has a target.
//!
//! Sub-modules:
//!
//! - `sidecar`    — JSON wire format for `.idx.json` files
//! - `batch_store`/`batch_store_s3` — vtable + S3 backend (the
//!                 `BatchStore` that holds `.ndjson` payloads +
//!                 `.idx.json` sidecars per tenant)
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
