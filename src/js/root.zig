//! rove-js — the worker-side JS dispatch layer.
//!
//! Phase 2 session 1 (this file's current scope):
//!
//! - `Request` / `Response` — plain Zig types the HTTP layer will feed
//!   in and read back out. Session 2 bridges these to `rove-h2`.
//! - `Dispatcher` — creates a fresh quickjs `Runtime`+`Context` per
//!   request, installs the minimal global surface (`kv`, `console`,
//!   `request`, `response`), evaluates a handler source, and extracts
//!   the response. A fresh runtime per request is correct but slow; the
//!   snapshot/restore fast path (memcpy into a reused arena) lands in a
//!   later session once the request/response shape is stable.
//! - Minimal JS globals: `kv.get`/`kv.set`/`kv.delete`, `console.log`,
//!   a read-only `request` object, a writable `response` object.
//!
//! **Deferred to the next sessions:**
//!
//! - HTTP/2 wiring (`rove-h2` accept loop + router). Session 2.
//! - HTTP/2 client to `rove-files-server` for on-demand bytecode fetch.
//!   Session 2 builds both ends of this wire.
//! - Tenant resolution + per-instance KV prefixing. Session 2 adds
//!   `rove-tenant` and plumbs it through the router.
//! - Raft wiring (3-node worker cluster). Session 3.
//!
//! ## Handler convention (M1 shape)
//!
//! A handler is a plain script that reads `request` and writes
//! `response`:
//!
//! ```js
//! const name = kv.get("name") ?? "world";
//! kv.set("last_name", name);
//! console.log("greeting " + name);
//! response.status = 200;
//! response.body = "hello " + name;
//! ```
//!
//! No `export default`, no function export — the script body runs once
//! per request against a fresh context. This is deliberately simple so
//! session 1 doesn't commit us to an async model before we know what
//! the globals look like. The "modern" handler shape (`export default
//! async function(req)`) will land alongside snapshot/restore in
//! session 3 where we can afford the added complexity.

const std = @import("std");

pub const dispatcher = @import("dispatcher.zig");
pub const globals = @import("globals.zig");
pub const worker = @import("worker.zig");
pub const apply = @import("apply.zig");
pub const penalty = @import("penalty.zig");
pub const limiter = @import("limiter.zig");
pub const router = @import("router.zig");
pub const callback_dispatch = @import("callback_dispatch.zig");
pub const config_mirror = @import("config_mirror.zig");
pub const reserved = @import("reserved.zig");
pub const send_outbox = @import("send_outbox.zig");
pub const send_inflight = @import("send_inflight.zig");
pub const send_dispatch = @import("send_dispatch.zig");
pub const session = @import("session.zig");
pub const events = @import("events.zig");
pub const sse_dispatch = @import("sse_dispatch.zig");
pub const sse_token = @import("sse_token.zig");
pub const deployment_loader = @import("deployment_loader.zig");
pub const DeploymentLoader = deployment_loader.DeploymentLoader;

pub const Budget = dispatcher.Budget;
pub const PenaltyBox = penalty.PenaltyBox;
pub const RateLimiter = limiter.RateLimiter;
pub const RateLimitCaps = limiter.RateLimitCaps;
pub const Action = limiter.Action;

pub const Dispatcher = dispatcher.Dispatcher;
pub const Request = dispatcher.Request;
pub const Response = dispatcher.Response;
pub const DispatchError = dispatcher.DispatchError;

pub const Worker = worker.Worker;
pub const WorkerConfig = worker.WorkerConfig;
pub const ManifestHttpConfig = worker.ManifestHttpConfig;
pub const PrefetchedManifest = worker.PrefetchedManifest;
pub const ManifestPrefetchMap = worker.ManifestPrefetchMap;
pub const NodeState = worker.NodeState;
pub const WorkerOptions = worker.Options;
pub const RaftWait = worker.RaftWait;
pub const TenantFiles = worker.TenantFiles;
pub const TenantLog = worker.TenantLog;
pub const DEFAULT_HANDLER_PATH = worker.DEFAULT_HANDLER_PATH;
pub const BlockedTenants = worker.BlockedTenants;
pub const dispatchOnce = worker.dispatchOnce;
pub const dispatchSendCompletions = callback_dispatch.dispatchSendCompletions;
pub const CALLBACK_DEFAULT_MAX_PER_TENANT = callback_dispatch.DEFAULT_MAX_PER_TENANT;
pub const drainRaftPending = worker.drainRaftPending;
pub const sweepParkedContinuations = worker.sweepParkedContinuations;
pub const drainOnLeadershipLoss = worker.drainOnLeadershipLoss;
pub const cleanupResponses = worker.cleanupResponses;
pub const flushLogs = worker.flushLogs;

test {
    _ = dispatcher;
    _ = globals;
    _ = worker;
    _ = apply;
    _ = penalty;
    _ = limiter;
    _ = router;
    _ = callback_dispatch;
    _ = config_mirror;
    _ = reserved;
    _ = send_outbox;
    _ = send_inflight;
    _ = send_dispatch;
    _ = session;
    _ = events;
    _ = sse_dispatch;
    _ = sse_token;
    _ = deployment_loader;
}
