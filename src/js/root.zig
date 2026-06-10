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
//! `docs/effect-reification-plan.md` §3.3 for the Continuation primitive
//! backing the parked Msg queue.
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
//! durability gates, subscription/cron/boot fires, owed-retry sweeps, and
//! response/log cleanup. They run between `poll()` and `reg.flush()`.

const std = @import("std");

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
pub const reserved = @import("reserved.zig");
pub const session = @import("session.zig");
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
pub const drainRaftPending = worker.drainRaftPending;
pub const drainForwardPending = worker.drainForwardPending;
pub const drainBodyPending = worker.drainBodyPending;
pub const drainFetchPendingDurability = worker.drainFetchPendingDurability;
pub const drainPendingBoundResumes = worker.drainPendingBoundResumes;
pub const sweepParkedContinuations = worker.sweepParkedContinuations;
pub const serviceParkedStreams = worker.serviceParkedStreams;
pub const serviceWsMessages = worker.serviceWsMessages;
pub const drainOnLeadershipLoss = worker.drainOnLeadershipLoss;
pub const cleanupResponses = worker.cleanupResponses;
pub const flushLogs = worker.flushLogs;
pub const serviceSubscriptionFires = worker.serviceSubscriptionFires;
pub const sweepBootSubscriptions = worker.sweepBootSubscriptions;
pub const sweepCronSubscriptions = worker.sweepCronSubscriptions;
pub const sweepBlobSessions = worker.sweepBlobSessions;
pub const sweepOwedRetries = worker.sweepOwedRetries;
pub const sweepOwedRetriesOnPromotion = worker.sweepOwedRetriesOnPromotion;
pub const sweepDurableWakes = worker.sweepDurableWakes;
pub const sweepDurableWakesOnPromotion = worker.sweepDurableWakesOnPromotion;
pub const serviceFetchEvents = worker.serviceFetchEvents;
pub const drainSpools = worker.drainSpools;

test {
    _ = dispatcher;
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
}
