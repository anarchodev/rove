// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Data-plane node — thin module root. The real content lives in
//! `node_core.zig` (the `Node` + `TenantSlot` structs, the apply/commit helper
//! types, `Error`, and the config knobs), with the method bodies split by
//! concern across `node_groups.zig` (group lifecycle), `node_membership.zig`
//! (the raft membership + log-inspection surface — the pump-side twins of the
//! bridge's ControlCmd relay), and `node_pump.zig` (the hot loop: pump /
//! durabilize / auto-demote / apply). See the node-module split note in
//! `docs/architecture/consensus-and-storage.md`.
//!
//! This file stays the BUILD-MODULE ROOT (`build.zig` roots `v2_node_mod` here;
//! `bridge.zig` + the hibernation bench import it), so the split siblings must
//! NOT `@import("node.zig")` — a file that is both a module root and a relative
//! import compiles as two distinct instances with incompatible types (the Zig
//! root-import trap). They import `node_core.zig` (never a root) for every type,
//! and `node_core`'s `Node` re-exports their functions as methods — a resolved
//! file-level import cycle. This root only re-exports the public surface.

const std = @import("std");

pub const core = @import("node_core.zig");

// ── Public type surface (bridge.zig / bridge_error.zig / hibernation bench) ──
pub const Node = core.Node;
pub const TenantSlot = core.TenantSlot;
pub const Error = core.Error;

pub const Transport = core.Transport;
pub const PeerAddr = core.PeerAddr;
pub const PeerResolver = core.PeerResolver;
pub const PeerRegistry = core.PeerRegistry;
pub const ActiveSet = core.ActiveSet;
pub const SlotHib = core.SlotHib;
pub const KvStore = core.KvStore;
pub const WriteSet = core.WriteSet;
pub const Envelope = core.Envelope;
pub const RangeResult = core.RangeResult;

pub const StoreResolver = core.StoreResolver;
pub const CommitHook = core.CommitHook;
pub const SkipQuery = core.SkipQuery;
pub const DurabilizeFloor = core.DurabilizeFloor;
pub const ApplyObserver = core.ApplyObserver;
pub const ApplyMode = core.ApplyMode;
pub const ApplyPolicy = core.ApplyPolicy;

// ── Config knobs ────────────────────────────────────────────────────────────
pub const DEFAULT_HIBERNATE_NS = core.DEFAULT_HIBERNATE_NS;
pub const DEFAULT_LEADERLESS_ESCALATE_NS = core.DEFAULT_LEADERLESS_ESCALATE_NS;
pub const DEFAULT_DURABILIZE_NS = core.DEFAULT_DURABILIZE_NS;
pub const DEFAULT_SNAPSHOT_GRACE = core.DEFAULT_SNAPSHOT_GRACE;
pub const DEFAULT_AUTO_DEMOTE_LAG = core.DEFAULT_AUTO_DEMOTE_LAG;
pub const DEFAULT_AUTO_DEMOTE_NS = core.DEFAULT_AUTO_DEMOTE_NS;
pub const DEFAULT_TICK_NS = core.DEFAULT_TICK_NS;

// Pull the split files' inline tests into this module's test artifact (the gate
// roots `v2_node_test` here).
test {
    _ = core;
    _ = @import("envelope.zig");
}
