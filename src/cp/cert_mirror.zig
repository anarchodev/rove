// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! A durable copy of each host's certificate, outside everything a cold
//! bring-up destroys.
//!
//! Certificates live in the directory raft group (`cert/{host}`), whose state
//! is under `~/.rove/data/cp` — which `--genesis` wipes. Re-issuing after a
//! wipe is not free: Let's Encrypt rate-limits duplicate certificates to five
//! per week for an identical name set, so a deployment brought up a few times
//! in a week can exhaust issuance and be left unable to serve TLS. Worse, the
//! wall is hit later, on whichever renewal crosses the limit, not during the
//! genesis that spent the quota.
//!
//! So a certificate is mirrored to object storage as it is written, and the
//! issuer consults the mirror before asking a CA for anything. A certificate is
//! not lifetime-scoped — one for `rewindjs.com` is valid no matter which
//! cluster lifetime requested it — so the mirror deliberately sits at
//! `{key_prefix_base}_certs/{host}`, OUTSIDE the storage-namespace generation
//! (the storage-namespace section of `docs/architecture/deployment-and-logs.md`),
//! next to the namespace marker and for the same reason: some state has to
//! outlive the lifetime that wrote it.
//!
//! Mirroring is best-effort and never fails a cert write — the certificate is
//! already durable in raft by then — but a failure is logged, because a
//! silently un-mirrored certificate is one the next genesis destroys.

const std = @import("std");
const blob = @import("rove-blob");
const directory_mod = @import("cp-directory");
const expiry = @import("rove-acme").expiry;

/// Key prefix for the mirror, relative to `key_prefix_base`.
pub const SUBDIR = "_certs/";

pub const CertMirror = struct {
    allocator: std.mem.Allocator,
    backend: blob.BlobBackend,
    /// Serializes access to the one libcurl handle inside `backend`: cert
    /// writes come from the ACME issuer thread and from the CP's control
    /// surface, and the store is not thread-safe.
    mutex: std.Thread.Mutex = .{},

    /// Open the mirror against the SAME S3 connection params everything else
    /// uses, but at the un-namespaced base prefix.
    pub fn init(allocator: std.mem.Allocator, cfg: blob.BackendConfig) !CertMirror {
        const prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ cfg.key_prefix_base, SUBDIR });
        defer allocator.free(prefix);
        return .{
            .allocator = allocator,
            .backend = try blob.BlobBackend.openS3(allocator, .{
                .endpoint = cfg.endpoint,
                .region = cfg.region,
                .bucket = cfg.bucket,
                .key_prefix = prefix,
                .access_key = cfg.access_key,
                .secret_key = cfg.secret_key,
                .use_tls = cfg.use_tls,
            }),
        };
    }

    pub fn deinit(self: *CertMirror) void {
        self.backend.deinit();
    }

    /// Store `frame` (a packed cert frame — the same bytes the raft group
    /// holds, so the mirror and the live copy cannot disagree about format).
    pub fn put(self: *CertMirror, host: []const u8, frame: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.backend.blobStore().put(host, frame);
    }

    /// The mirrored frame for `host`, or null when there is none. Caller owns.
    pub fn getOwned(self: *CertMirror, a: std.mem.Allocator, host: []const u8) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const store = self.backend.blobStore();
        if (!(store.exists(host) catch return null)) return null;
        return store.get(host, a) catch |err| switch (err) {
            blob.Error.NotFound => null,
            else => err,
        };
    }

    /// The `Directory.CertMirror` hook, so every writer that reaches `setCert`
    /// mirrors — rather than each call site remembering to.
    pub fn hook(self: *CertMirror) directory_mod.CertMirrorHook {
        return .{ .ctx = self, .put = putTrampoline };
    }

    fn putTrampoline(ctx: *anyopaque, host: []const u8, frame: []const u8) void {
        const self: *CertMirror = @ptrCast(@alignCast(ctx));
        self.put(host, frame) catch |err| std.log.warn(
            "cp: mirroring the certificate for {s} failed: {s} — it is durable in raft " ++
                "but a cold bring-up would destroy it (rove#269)",
            .{ host, @errorName(err) },
        );
    }

    /// Put a still-usable mirrored certificate back into the directory. True
    /// when `host` ends up served without a CA call.
    ///
    /// An expired mirrored certificate is deliberately NOT restored: it would
    /// satisfy "this host has a cert" and suppress the issuance it needs,
    /// leaving the host serving TLS that no client accepts.
    pub fn restoreHost(
        self: *CertMirror,
        a: std.mem.Allocator,
        dir: *directory_mod.Directory,
        host: []const u8,
        now_s: i64,
        renew_window_s: i64,
    ) bool {
        const frame = (self.getOwned(a, host) catch |err| {
            std.log.warn("cp: reading the mirrored cert for {s} failed: {s}", .{ host, @errorName(err) });
            return false;
        }) orelse return false;
        defer a.free(frame);

        const unpacked = directory_mod.Directory.unpackCert(frame) orelse {
            std.log.warn("cp: the mirrored cert for {s} is unreadable; leaving it to issuance", .{host});
            return false;
        };
        if (expiry.needsRenewal(a, unpacked.cert_pem, now_s, renew_window_s)) return false;

        dir.setCert(host, unpacked.cert_pem, unpacked.key_pem) catch |err| {
            std.log.warn("cp: restoring the cert for {s} failed: {s}", .{ host, @errorName(err) });
            return false;
        };
        std.log.info("cp: restored the certificate for {s} from the mirror (no CA call)", .{host});
        return true;
    }

    /// Restore every host that is missing a usable certificate but has one in
    /// the mirror. Leader-gated by the caller (only the leader can write).
    ///
    /// Runs on the CP's own loop rather than inside the ACME issuer, because
    /// re-installing a certificate this cluster already owns is not an ACME
    /// operation — a deployment with ACME disabled, serving operator-uploaded
    /// certificates, still has to get them back after a cold bring-up.
    pub fn restorePass(
        self: *CertMirror,
        a: std.mem.Allocator,
        dir: *directory_mod.Directory,
        now_s: i64,
        renew_window_s: i64,
    ) usize {
        const hosts = dir.collectHostsNeedingCert(a, now_s, renew_window_s) catch return 0;
        defer {
            for (hosts) |h| a.free(h);
            a.free(hosts);
        }
        var restored: usize = 0;
        for (hosts) |host| {
            if (self.restoreHost(a, dir, host, now_s, renew_window_s)) restored += 1;
        }
        return restored;
    }
};
