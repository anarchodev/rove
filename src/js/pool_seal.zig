// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The worker's side of sealing a body on its way into the cross-tenant
//! body pool — resolving the tenant's key material and refusing to spill
//! without it.
//!
//! `keyring.body_seal` owns the mechanism (a data key per body, wrapped
//! under key material a destroy can reach). This file owns the part that
//! needs a worker: finding the tenant's keyring, and deciding what to do
//! when there isn't one.
//!
//! ## Why a missing keyring fails the spill
//!
//! The alternative is submitting plaintext, and that failure is silent,
//! permanent and invisible at exactly the moment it matters: the bytes go
//! to a content-addressed object shared with other tenants, get copied
//! into every backup taken afterwards, and no later destroy can reach
//! them. There is no repair — the object cannot be rewritten, and by the
//! time anyone notices, the plaintext is in backup generations nobody
//! will re-derive.
//!
//! So the same posture the rest of this epic takes: a node that cannot
//! vouch for a tenant's key material refuses to act rather than
//! downgrading quietly. It costs a large-body request on a node whose
//! keyring has not arrived; it does not cost an unrecoverable leak.

const std = @import("std");
const crypt = @import("rove-crypt");
const keyring_mod = @import("rove-keyring");

const body_seal = keyring_mod.body_seal;

pub const WRAPPED_LEN = body_seal.WRAPPED_LEN;

/// An all-zero wrap: no sealed body. Distinguishable from a real wrap
/// because a real one always leads with `crypt.ALG_AES_256_GCM`, which is
/// non-zero — so the absence is exact rather than probabilistic, the same
/// discipline `keyring/seal.zig`'s marker follows.
pub const NO_WRAP: [WRAPPED_LEN]u8 = [_]u8{0} ** WRAPPED_LEN;

pub fn isWrapped(wrap: *const [WRAPPED_LEN]u8) bool {
    return wrap[0] != 0;
}

pub const Error = error{
    /// This node holds no keyring for the tenant, so it cannot seal. The
    /// caller must fail the body rather than submit plaintext.
    NoKeyring,
} || body_seal.Error;

pub const Sealed = struct {
    /// Hand this to `Coordinator.submit` — the pool carries ciphertext.
    body: []u8,
    /// Record this beside the `BodyRef` on the tape entry.
    wrapped_key: [WRAPPED_LEN]u8,
};

/// This node's key state for `instance_id`, or null.
fn keysFor(worker: anytype, instance_id: []const u8) ?*keyring_mod.TenantKeys {
    const slot = worker.node.deploy.tenant_files_map.get(instance_id) orelse return null;
    return slot.keys;
}

/// This tenant's body-pool key, or null when this node holds no keyring.
///
/// Separate from `sealForPool` because a caller that holds bytes but not a
/// worker — the inbound-chunk job, which takes everything by injection —
/// resolves the key once at arm time and seals many payloads with it.
pub fn tenantKeyFor(worker: anytype, instance_id: []const u8) ?crypt.Key {
    const keys = keysFor(worker, instance_id) orelse return null;
    return body_seal.tenantKey(keys.tenantSecret());
}

/// Seal `plaintext` for the pool under an already-resolved tenant key.
pub fn sealWithKey(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    tenant_key: crypt.Key,
) Error!Sealed {
    const s = try body_seal.seal(
        allocator,
        plaintext,
        tenant_key,
        crypt.TENANT_REF,
        keyring_mod.seal.KEY_VERSION,
    );
    return .{ .body = s.body, .wrapped_key = s.wrapped_key };
}

/// Seal `plaintext` for the pool under the TENANT's key.
///
/// The tenant and not an identity, because no identity exists yet: a body
/// is submitted before any handler code runs. `TenantKeys.bindBodyWrap`
/// moves the wrap once the activation names one.
pub fn sealForPool(
    worker: anytype,
    allocator: std.mem.Allocator,
    instance_id: []const u8,
    plaintext: []const u8,
) Error!Sealed {
    const key = tenantKeyFor(worker, instance_id) orelse return Error.NoKeyring;
    return sealWithKey(allocator, plaintext, key);
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "the absence of a wrap is exact, not a guess" {
    // A real wrap always leads with the algorithm id, so a zeroed field
    // can never be mistaken for one. The inverse — sniffing the BODY for
    // sealedness — is what `keyring/seal.zig` rejects as probabilistic,
    // and a body is arbitrary bytes so it has no unusable leading byte
    // to spend.
    try testing.expect(!isWrapped(&NO_WRAP));
    var w = NO_WRAP;
    w[0] = crypt.ALG_AES_256_GCM;
    try testing.expect(isWrapped(&w));
}
