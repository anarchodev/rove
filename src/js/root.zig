// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rove-js — the worker-side JS dispatch layer.
//!
//! This module owns everything between an inbound activation and the
//! customer JS handler that services it: the per-request JS context, the
//! global surface the handler sees, the effect/Cmd machinery that makes
//! external effects durable, and the worker-level dispatch loop that
//! drives it all.
//!
//! ## Dispatch model
//!
//! The handler is `update : (Msg, Ctx) -> (Effects, Cmd Msg)` — the Elm
//! Architecture (TEA) shape. Every activation (inbound request,
//! send/fetch callback, kv wake, disconnect, subscription fire) is a
//! `Msg` routed through `Dispatcher.runOutcome` (`dispatcher.zig`), the
//! single re-entry point. The handler returns a list of `Cmd`s; external
//! effects are reified rather than performed inline, so they can be made
//! durable (parked until raft-committed) and replayed. See
//! `docs/effect-algebra.md` for the four-primitive effect frame and
//! `docs/architecture/effects-and-handlers.md` (the Continuation
//! primitive) for the parked Msg queue.
//!
//! ## Per-request context
//!
//! Each request runs against a fresh JS context via arenajs's dual-arena
//! reset — one cursor write per request, not a fresh runtime (see
//! `vendor/arenajs/README.md`). The base arena is built once at worker
//! startup and shared across all requests on the thread.
//!
//! ## Request lifecycle
//!
//! ```
//! h2.request_out → dispatchOnce → [drainRaftPending if writes]
//!                → h2.response_in → h2.response_out
//! ```
//!
//! The `drain*` / `sweep*` / `service*` helpers re-exported below are the
//! worker tick's phase-based dispatch stages — parked continuations,
//! durability gates, subscription/cron fires, owed-retry sweeps, and
//! response/log cleanup. They run between `poll()` and `reg.flush()`.

const std = @import("std");



/// Re-exported so the format-version registry (`src/version.zig`) can
/// reach the readset wire version + the customer-id prefixes through the
/// worker's existing `rove-js` import (no extra build-graph edges).
pub const tape = @import("rove-tape");
pub const log = @import("rove-log");

pub const dispatcher = @import("dispatcher.zig");
pub const effect = @import("effect/root.zig");
pub const globals = @import("globals.zig");
pub const worker = @import("worker.zig");
pub const components = @import("components.zig");
pub const chunk_spool = @import("chunk_spool.zig");
pub const apply = @import("apply.zig");
pub const penalty = @import("penalty.zig");
pub const limiter = @import("limiter.zig");
pub const router = @import("router.zig");
pub const config_mirror = @import("config_mirror.zig");
pub const reserved = @import("rove-reserved");
pub const ssrf = @import("rove-ssrf");
pub const session = @import("session.zig");
pub const deployment_loader = @import("deployment_loader.zig");
pub const durable_wake = @import("durable_wake.zig");
pub const DeploymentLoader = deployment_loader.DeploymentLoader;
pub const snapshot_catchup = @import("snapshot_catchup.zig");
pub const SnapshotCatchupThread = snapshot_catchup.SnapshotCatchupThread;

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
pub const NodeState = worker.NodeState;
pub const WorkerOptions = worker.Options;
pub const RaftWait = worker.RaftWait;
pub const TenantFiles = worker.TenantFiles;
pub const TenantLog = worker.TenantLog;
pub const DEFAULT_HANDLER_PATH = worker.DEFAULT_HANDLER_PATH;
pub const BlockedTenants = worker.BlockedTenants;
pub const dispatchOnce = worker.dispatchOnce;
pub const drainRequestReceiving = worker.drainRequestReceiving;
pub const drainRaftPending = worker.drainRaftPending;
pub const drainForwardPending = worker.drainForwardPending;
pub const drainSnapshotStreams = @import("v2_move.zig").drainSnapshotStreams;
pub const drainSnapshotPushes = @import("v2_move.zig").drainSnapshotPushes;
pub const drainBodyPending = worker.drainBodyPending;
pub const drainFetchPendingDurability = worker.drainFetchPendingDurability;
pub const drainPendingBoundResumes = worker.drainPendingBoundResumes;
pub const sweepParkedContinuations = worker.sweepParkedContinuations;
pub const pumpInboundChunks = worker.pumpInboundChunks;
pub const serviceParkedStreams = worker.serviceParkedStreams;
pub const serviceWsMessages = worker.serviceWsMessages;
pub const drainOnLeadershipLoss = worker.drainOnLeadershipLoss;
pub const cleanupResponses = worker.cleanupResponses;
pub const flushLogs = worker.flushLogs;
pub const serviceSubscriptionFires = worker.serviceSubscriptionFires;
pub const sweepBlobSessions = worker.sweepBlobSessions;
pub const sweepDurableWakes = worker.sweepDurableWakes;
pub const sweepDurableWakesOnPromotion = worker.sweepDurableWakesOnPromotion;
pub const sweepDirtySubscriptionsOnPromotion = @import("worker_streaming.zig").sweepDirtySubscriptionsOnPromotion;
pub const serviceFetchEvents = worker.serviceFetchEvents;
pub const drainSpools = worker.drainSpools;
pub const drainRelay = worker.drainRelay;

/// Operator metrics: `buildMetricsText` renders the Prometheus snapshot (worker
/// thread), `MetricsServer` serves it over a dedicated loopback HTTP/1.1 port.
pub const buildMetricsText = @import("worker_system.zig").buildMetricsText;
pub const MetricsServer = @import("metrics-server").MetricsServer;

test {
    // Expected-failure tests in this module drive paths that warn by design —
    // arena exhaustion into the GC retry, an oversize config blob, simulated
    // fetch failures. The runner captures warnings and reports them as test
    // failures, so those tests would fail for doing exactly what they exist to
    // do. Raised here, once, because the root's tests run first; errors still
    // fail the suite.
    std.testing.log_level = .err;
    _ = dispatcher;
    _ = @import("dispatcher_test.zig");
    _ = @import("kv_binding_test.zig");
    _ = effect;
    _ = globals;
    _ = worker;
    _ = components;
    _ = chunk_spool;
    _ = apply;
    _ = penalty;
    _ = limiter;
    _ = router;
    _ = config_mirror;
    _ = reserved;
    _ = session;
    _ = deployment_loader;
    // `worker.zig` reaches worker_ws only through generic (`anytype`)
    // call sites, which a test build never instantiates — so its tests
    // are collected only if the file is named here.
    _ = @import("worker_ws.zig");
    _ = @import("worker_dispatch.zig");
    _ = @import("worker_inbound_chunk.zig");
    _ = @import("worker_upload_walker.zig");
    _ = @import("log_walker.zig");
    _ = @import("static_cache.zig");
    _ = @import("blob_usage.zig");
    _ = @import("keyring_slots.zig");
    _ = @import("keyring_bind.zig");
    _ = @import("deploy_thread.zig");
    _ = @import("doc_examples.zig");
    _ = @import("surface_tests.zig");
    _ = @import("bindings/continuation.zig");
    _ = @import("bindings/crypto.zig");
    _ = @import("bindings/crypto_ecdsa.zig");
    _ = @import("bindings/crypto_jose.zig");
    _ = @import("bindings/http.zig");
    _ = @import("bindings/stream.zig");
    _ = @import("bindings/textcodec.zig");
    _ = @import("blob_sessions.zig");
    _ = @import("kv_export.zig");
    _ = @import("builtin_modules.zig");
    _ = @import("bytecode_cache.zig");
    _ = @import("deployment_cache.zig");
    _ = @import("durable_wake.zig");
    _ = @import("fetch_engine.zig");
    _ = @import("gzip.zig");
    _ = @import("ip_mask.zig");
    _ = @import("module_execution.zig");
    _ = @import("owed_retry.zig");
    _ = @import("package_resolver.zig");
    _ = @import("reserved_headers.zig");
    _ = @import("response_builder.zig");
    _ = @import("response_building.zig");
    _ = @import("rpc_dispatch.zig");
    _ = @import("worker_fire.zig");
    _ = @import("worker_log.zig");
    _ = @import("worker_system.zig");
}
