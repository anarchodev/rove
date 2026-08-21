// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `rove-keyring` — everything a node holds for ONE tenant's per-identity
//! keys, and nothing that knows how a node talks to its peers.
//!
//! ## Why this is a module and not a handful of fields
//!
//! It grew as eight fields on `TenantSlot` — the keyring, the pool and
//! its context, a completeness flag, a destroy queue, and two mutexes —
//! which put a third of a struct about DEPLOYMENTS in service of
//! cryptography. The deployment path then had to reach into key state,
//! and key code had to reach back, and that cycle was bridged by a
//! mutable function pointer installed at startup. A global that is
//! silently a no-op if nobody installs it is not a seam; it is the shape
//! of a missing module.
//!
//! So the state lives here, with one owner and one lifetime. A tenant
//! slot holds a pointer and knows nothing else about it.
//!
//! ## What is deliberately NOT here
//!
//! Anything that reaches other nodes. Reserving a slot range goes
//! through raft, pushing a shard goes over HTTP, and publishing the
//! minted watermark is a replicated write — all of which need the
//! worker, its bridge and its transport. Those arrive as callbacks
//! (`Deps`), so this module depends on `std`, the crypto primitive and
//! the kv facade, and on nothing that knows the cluster exists.
//!
//! That is what makes it testable without a cluster, and what keeps the
//! import graph pointing one way.

const std = @import("std");

pub const keyspace = @import("keyspace.zig");
pub const seal = @import("seal.zig");
pub const tenant_keys = @import("tenant_keys.zig");

pub const TenantKeys = tenant_keys.TenantKeys;
pub const Lookup = keyspace.Lookup;
pub const Completeness = keyspace.Completeness;

test {
    _ = keyspace;
    _ = seal;
    _ = tenant_keys;
}
