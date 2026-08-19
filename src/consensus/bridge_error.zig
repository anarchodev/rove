// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
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
    /// The envelope is larger than one raft message can carry
    /// (`transport.MAX_ENTRY_BYTES`). Refused BEFORE the propose, because the
    /// alternative is not a slow write but a torn peer connection: nothing
    /// fragments a raft message, so an entry over the wire limit is dropped
    /// unsent and re-emitted forever. The caller owes the customer a defined
    /// error — this write cannot be made durable at any size of patience.
    EntryTooLarge,
    OutOfMemory,
} || node_mod.Error;
