// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Deleting a deprovisioned tenant's stored objects — the S3 half of teardown.
//!
//! Evicting the raft group destroys the tenant's KV, but its bytes live in
//! object storage (`app-blobs/`, `file-blobs/`, `log-blobs/`, `deployments/`)
//! and nothing else ever removes them: the retention clamp hides log records
//! rather than deleting them, and the blob store has no GC. Without this sweep
//! a deleted tenant bills forever, and an account-closure promise to erase
//! customer data has no code behind it.
//!
//! ## Why the incarnation must outlive the sweep
//!
//! Storage identity is `(id, incarnation)`, so the incarnation row IS the
//! handle to the prefix. `handleDelete` therefore withdraws it LAST — only
//! once the bytes are gone. A sweep that failed with the row already dropped
//! would strand objects under a prefix nothing can name again, and no retry
//! could converge. Re-provisioning is safe meanwhile: it mints a fresh random
//! incarnation and overwrites the row, so a lingering one is never inherited.
//!
//! ## Why per-subdir, not one prefix
//!
//! The sweep deletes `{base}{id}/{incarnation}/{subdir}/` for each subdir
//! rather than the whole `{base}{id}/` tree. For a LEGACY (pre-incarnation)
//! tenant the tree form would also cover `{base}{id}/{token}/…` — a later
//! tenant reborn under the same name — so a retried delete could erase the
//! live successor's data. Naming the subdirs keeps the two layouts disjoint.

const std = @import("std");
const blob = @import("rove-blob");
const tenant_mod = @import("rove-tenant");

const TenantStorage = tenant_mod.TenantStorage;

/// Delete every stored object belonging to `(tenant, incarnation)`.
///
/// Returns the number of objects removed. Errors surface only AFTER every
/// subdir has been attempted, so one unreachable prefix never abandons the
/// rest — the caller retries the whole delete, which converges.
pub fn deleteTenantObjects(
    a: std.mem.Allocator,
    cfg: blob.BackendConfig,
    storage: TenantStorage,
) !u64 {
    // Opened at the bucket root so the sweep can pass fully-qualified
    // prefixes built by `TenantStorage.keyPrefix` — the one source of truth
    // for the per-tenant layout, shared with every reader and writer.
    var backend = try blob.BlobBackend.openS3(a, .{
        .endpoint = cfg.endpoint,
        .region = cfg.region,
        .bucket = cfg.bucket,
        .key_prefix = "",
        .access_key = cfg.access_key,
        .secret_key = cfg.secret_key,
        .use_tls = cfg.use_tls,
    });
    defer backend.deinit();

    var total: u64 = 0;
    var first_err: ?anyerror = null;
    for (tenant_mod.SUBDIRS) |subdir| {
        const prefix = try storage.keyPrefix(a, cfg.key_prefix_base, subdir);
        defer a.free(prefix);
        const n = backend.deletePrefix(prefix) catch |err| {
            std.log.warn(
                "rewind-cp: sweep {s}: deleting {s} failed: {s} — retry the delete",
                .{ storage.id, prefix, @errorName(err) },
            );
            first_err = first_err orelse err;
            continue;
        };
        // Logged even at zero: "swept nothing" and "swept the wrong prefix"
        // are indistinguishable from the total alone, and this is the only
        // record of what teardown actually removed.
        std.log.info("rewind-cp: sweep {s}: deleted {d} object(s) under {s}", .{ storage.id, n, prefix });
        total += n;
    }
    if (first_err) |e| return e;
    return total;
}
