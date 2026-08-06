// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! A tenant's storage identity, and the ONLY constructor for everything
//! derived from it: S3 key prefixes, signed object paths, per-tenant blob
//! backends, the KV sibling-store id, and the on-disk instance directory.
//!
//! Storage identity is `(id, incarnation)`, never the id alone. Deprovision
//! frees a name for reuse, so any derivation keyed on the name hands the next
//! holder of that name the previous holder's bytes (#357) — and a derivation
//! written by hand at a call site silently keeps the old rule when this one
//! changes (docs/defect-patterns.md class 2: seven instances, one root).
//! Code that needs a path takes a `TenantStorage`, not a bare id.

const std = @import("std");
const kv_mod = @import("raft-kv");
const blob_mod = @import("rove-blob");
const id_spec = @import("rove-instance-id");

/// Max bytes of an incarnation token (lowercase hex, minted by the CP per
/// tenant lifetime). Random rather than a counter: a counter would have to
/// survive the very deletion that destroys the tenant's state, and losing it
/// would silently re-issue a live path. A token needs no history to be safe.
pub const MAX_INCARNATION_LEN: usize = 32;

/// A tenant's storage incarnation. Deliberately NOT a string: an empty
/// string once meant both "legacy instance" and "nobody passed one", and
/// that ambiguity turned every missed hand-off into a quiet wrong answer
/// rather than a loud failure (#357). As a union with no default, "unset"
/// is unrepresentable — a struct that carries one must be given one.
pub const Incarnation = union(enum) {
    /// Instance provisioned before incarnations existed: storage keyed by
    /// name alone, DELIBERATELY — its objects already live at the name-keyed
    /// paths and stay there (no migration; the name could not be freed and
    /// reused before deprovision shipped). Legacy is an identity a live
    /// tenant legitimately has, never a fallback. "We don't know the
    /// incarnation" must surface as an error at the source
    /// (`Tenant.storageOf`), not map here.
    legacy,
    /// The tenant-lifetime token: non-empty, at most `MAX_INCARNATION_LEN`
    /// bytes, validated at the creation edge
    /// (`Tenant.createInstanceWithIncarnation`).
    token: []const u8,

    /// From a marker VALUE that was actually read (`instance/{id}` in the
    /// root store) or an attach-envelope field that was actually present:
    /// empty means legacy. An ABSENT marker means "no such instance" and an
    /// absent envelope field means "sender predates the field" — resolve
    /// those at the call site; never spell them "".
    pub fn fromMarker(v: []const u8) Incarnation {
        return if (v.len == 0) .legacy else .{ .token = v };
    }

    /// The marker/wire spelling: the token, or "" for legacy.
    pub fn marker(self: Incarnation) []const u8 {
        return switch (self) {
            .legacy => "",
            .token => |t| t,
        };
    }

    pub fn dupe(self: Incarnation, a: std.mem.Allocator) std.mem.Allocator.Error!Incarnation {
        return switch (self) {
            .legacy => .legacy,
            .token => |t| .{ .token = try a.dupe(u8, t) },
        };
    }

    /// Free a token owned by the caller (from `dupe`); no-op for legacy.
    pub fn free(self: Incarnation, a: std.mem.Allocator) void {
        switch (self) {
            .legacy => {},
            .token => |t| a.free(t),
        }
    }
};

/// Every per-tenant S3 subdir, in one place. This is the set a teardown
/// sweeps, so it is also the definition of "the tenant's stored objects": a
/// new subdir that is not listed here outlives its tenant, costing storage
/// forever and leaving bytes behind that an account deletion promised to
/// remove. Add to this list in the same change that introduces the subdir.
pub const SUBDIRS = [_][]const u8{
    "app-blobs",
    "file-blobs",
    "log-blobs",
    "deployments",
    // Data-export parts (rove#429). Unmetered — so the ONLY thing that bounds
    // it is this sweep: an export pool missing from this list would outlive
    // its tenant *and* have never been charged for, via the feature that
    // exists to honour erasure.
    "exports",
};

/// The handle every per-tenant derivation goes through. Both fields are
/// borrowed slices — `Tenant.Instance` owns one for its lifetime; transient
/// callers get an owned-token one from `Tenant.storageOf`.
pub const TenantStorage = struct {
    id: []const u8,
    incarnation: Incarnation,

    /// S3 key prefix for one per-tenant subdir (`"file-blobs"`,
    /// `"deployments"`, `"log-blobs"`): `{key_prefix_base}{id}/{subdir}/`,
    /// with the incarnation segment between id and subdir for a non-legacy
    /// instance. The single home of that branch. Caller frees.
    pub fn keyPrefix(
        self: TenantStorage,
        a: std.mem.Allocator,
        key_prefix_base: []const u8,
        subdir: []const u8,
    ) std.mem.Allocator.Error![]u8 {
        return switch (self.incarnation) {
            .legacy => std.fmt.allocPrint(
                a,
                "{s}{s}/{s}/",
                .{ key_prefix_base, self.id, subdir },
            ),
            .token => |t| std.fmt.allocPrint(
                a,
                "{s}{s}/{s}/{s}/",
                .{ key_prefix_base, self.id, t, subdir },
            ),
        };
    }

    /// Path-style S3 object path `/{bucket}/{prefix}{key}`, used both for
    /// SigV4 signing and the wire URL (the fetch-engine doors,
    /// `blob.presign`). Caller frees.
    pub fn s3ObjectPath(
        self: TenantStorage,
        a: std.mem.Allocator,
        cfg: blob_mod.BackendConfig,
        subdir: []const u8,
        key: []const u8,
    ) std.mem.Allocator.Error![]u8 {
        const prefix = try self.keyPrefix(a, cfg.key_prefix_base, subdir);
        defer a.free(prefix);
        return std.fmt.allocPrint(a, "/{s}/{s}{s}", .{ cfg.bucket, prefix, key });
    }

    /// Open the per-tenant S3 backend for one subdir. THE per-tenant backend
    /// constructor — same factory for file-blobs, deployments and log-blobs,
    /// so the S3 layout mirrors the on-disk layout exactly.
    pub fn openBackend(
        self: TenantStorage,
        a: std.mem.Allocator,
        cfg: blob_mod.BackendConfig,
        subdir: []const u8,
    ) !blob_mod.BlobBackend {
        const prefix = try self.keyPrefix(a, cfg.key_prefix_base, subdir);
        defer a.free(prefix);
        return blob_mod.BlobBackend.openS3(a, .{
            .endpoint = cfg.endpoint,
            .region = cfg.region,
            .bucket = cfg.bucket,
            .key_prefix = prefix,
            .access_key = cfg.access_key,
            .secret_key = cfg.secret_key,
            .use_tls = cfg.use_tls,
        });
    }

    /// The sibling-store id this tenant's KV lives under in the shared
    /// manifest. Hashing the name alone is exactly what let a reborn tenant
    /// read its predecessor's rows.
    pub fn storeId(self: TenantStorage) u64 {
        return switch (self.incarnation) {
            .legacy => kv_mod.hashStoreId(self.id),
            .token => |t| blk: {
                var buf: [id_spec.MAX_INSTANCE_ID_LEN + 1 + MAX_INCARNATION_LEN]u8 = undefined;
                // id/token lengths are validated at every construction edge;
                // overflow here is a broken invariant, not an input error.
                const keyed = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.id, t }) catch
                    @panic("tenant id/incarnation exceed validated bounds");
                break :blk kv_mod.hashStoreId(keyed);
            },
        };
    }

    /// On-disk instance directory `{base_dir}/{id}[/{token}]`. Caller frees.
    pub fn dirPath(
        self: TenantStorage,
        a: std.mem.Allocator,
        base_dir: []const u8,
    ) std.mem.Allocator.Error![]u8 {
        return switch (self.incarnation) {
            .legacy => std.fmt.allocPrint(a, "{s}/{s}", .{ base_dir, self.id }),
            .token => |t| std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ base_dir, self.id, t }),
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "Incarnation.fromMarker: empty is legacy, non-empty is a token" {
    try testing.expect(Incarnation.fromMarker("") == .legacy);
    const inc = Incarnation.fromMarker("aaaa1111");
    try testing.expectEqualStrings("aaaa1111", inc.token);
    try testing.expectEqualStrings("aaaa1111", inc.marker());
    const legacy: Incarnation = .legacy;
    try testing.expectEqualStrings("", legacy.marker());
}

test "keyPrefix: legacy and incarnation layouts" {
    const legacy = TenantStorage{ .id = "acme", .incarnation = .legacy };
    const lp = try legacy.keyPrefix(testing.allocator, "prod/", "file-blobs");
    defer testing.allocator.free(lp);
    try testing.expectEqualStrings("prod/acme/file-blobs/", lp);

    const inc = TenantStorage{ .id = "acme", .incarnation = .{ .token = "bbbb2222" } };
    const ip = try inc.keyPrefix(testing.allocator, "prod/", "file-blobs");
    defer testing.allocator.free(ip);
    try testing.expectEqualStrings("prod/acme/bbbb2222/file-blobs/", ip);

    const bare = try legacy.keyPrefix(testing.allocator, "", "log-blobs");
    defer testing.allocator.free(bare);
    try testing.expectEqualStrings("acme/log-blobs/", bare);
}

test "s3ObjectPath: path-style bucket + prefix + key" {
    const cfg = blob_mod.BackendConfig{ .bucket = "loop46-shared", .key_prefix_base = "prod/" };
    const ts = TenantStorage{ .id = "acme", .incarnation = .{ .token = "bbbb2222" } };
    const p = try ts.s3ObjectPath(testing.allocator, cfg, "app-blobs", "deadbeef");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/loop46-shared/prod/acme/bbbb2222/app-blobs/deadbeef", p);
}

test "openBackend: builds the per-tenant prefix" {
    const cfg = blob_mod.BackendConfig{
        .endpoint = "s3.gra.io.cloud.ovh.net",
        .region = "gra",
        .bucket = "loop46-shared",
        .key_prefix_base = "prod/",
        .access_key = "ak",
        .secret_key = "sk",
    };
    const ts = TenantStorage{ .id = "inst-0001", .incarnation = .legacy };
    var be = try ts.openBackend(testing.allocator, cfg, "file-blobs");
    defer be.deinit();
    try testing.expectEqualStrings("prod/inst-0001/file-blobs/", be.inner.s3.config.key_prefix);
    try testing.expectEqualStrings("loop46-shared", be.inner.s3.config.bucket);
}

test "storeId: legacy hashes the name, a token re-keys the store" {
    const legacy = TenantStorage{ .id = "acme", .incarnation = .legacy };
    try testing.expectEqual(kv_mod.hashStoreId("acme"), legacy.storeId());
    const reborn = TenantStorage{ .id = "acme", .incarnation = .{ .token = "bbbb2222" } };
    try testing.expectEqual(kv_mod.hashStoreId("acme/bbbb2222"), reborn.storeId());
    try testing.expect(legacy.storeId() != reborn.storeId());
}

test "dirPath: incarnation nests under the name" {
    const ts = TenantStorage{ .id = "acme", .incarnation = .{ .token = "bbbb2222" } };
    const d = try ts.dirPath(testing.allocator, "/data/tenants");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("/data/tenants/acme/bbbb2222", d);
}
