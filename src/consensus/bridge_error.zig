//! The bridge-wide error set, split into its own file so both `bridge.zig`
//! (the module root) and `bridge_control.zig` can share it without the
//! module-root import that referencing `bridge.zig` from a sibling would
//! trigger.

const node_mod = @import("node.zig");

/// Errors surfaced across the worker↔pump bridge seam — proposes, control
/// commands, and everything the node's apply path can raise.
pub const Error = error{
    /// `propose` / `committedSeq` named a gid with no registered tenant.
    UnknownTenant,
    /// The bridge is shutting down; no further proposes accepted.
    ShuttingDown,
    /// A control command (`createGroupEpoch` / `destroyGroup`) could not
    /// be serviced because the pump thread is not running.
    PumpNotRunning,
    /// This node has the tenant's group but is not its raft leader — the
    /// propose was refused BEFORE anything entered the log, so the caller
    /// can safely re-aim at the leader (worker maps this to a 421; the
    /// front door / serve-or-forward retry on it).
    NotLeader,
    OutOfMemory,
} || node_mod.Error;
