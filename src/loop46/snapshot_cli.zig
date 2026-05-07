//! `loop46 snapshot` subcommand — triggers a one-off snapshot
//! capture against the data dir's tenants. Phase 5.5(c) S3
//! wiring. Reads `BLOB_BACKEND` env (with optional
//! `SNAPSHOT_S3_KEY_PREFIX`) to pick the snapshot store backend
//! the same way the restore CLI does, walks `{data_dir}/*` for
//! tenant subdirs, opens fresh per-tenant SQLite connections,
//! VACUUM-INTOs each into `{data_dir}/.snapshot-stage/{snap_id}`,
//! sha256s + uploads, writes a manifest, and prints the snap_id
//! the operator can later pass to `restore-from-snapshot`.
//!
//! Usage:
//!   loop46 snapshot --data-dir <path>
//!                   [--snapshot-dir <path>]   # fs only
//!                   [--apply-position <N>]    # default 0
//!                   [--willemt-term <N>]      # default 0
//!
//! `--apply-position` + `--willemt-term` are escape hatches for
//! out-of-band captures that don't have access to a running raft
//! node. The default zero values produce a manifest that follower
//! load + replay handles correctly (every post-floor entry is
//! "after the snapshot" — same as a fresh cluster). When run
//! against a node with an active raft, the periodic loop in
//! `loop46 worker` (future work) threads the real values; this
//! CLI is the simpler operator handle.

const std = @import("std");
const blob_mod = @import("rove-blob");
const ls = @import("rove-log-server");

const main_mod = @import("main.zig");
const snapshot = @import("snapshot.zig");

const ENV_SNAPSHOT_S3_KEY_PREFIX = "SNAPSHOT_S3_KEY_PREFIX";

const Args = struct {
    data_dir: []const u8,
    snapshot_dir: ?[]const u8 = null,
    apply_position: u64 = 0,
    willemt_term: u64 = 0,
};

fn parseArgs(args: []const [:0]u8) !Args {
    var data_dir: ?[]const u8 = null;
    var snapshot_dir: ?[]const u8 = null;
    var apply_position: u64 = 0;
    var willemt_term: u64 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            data_dir = args[i];
        } else if (std.mem.eql(u8, a, "--snapshot-dir")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            snapshot_dir = args[i];
        } else if (std.mem.eql(u8, a, "--apply-position")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            apply_position = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--willemt-term")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            willemt_term = try std.fmt.parseInt(u64, args[i], 10);
        } else {
            return error.Usage;
        }
    }
    return .{
        .data_dir = data_dir orelse return error.Usage,
        .snapshot_dir = snapshot_dir,
        .apply_position = apply_position,
        .willemt_term = willemt_term,
    };
}

pub fn runSnapshot(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    const parsed = try parseArgs(args);

    var blob_owned = try main_mod.loadBlobBackend(allocator);
    defer blob_owned.deinit(allocator);

    var fs_handle: ?*ls.batch_store_fs.FsBatchStore = null;
    defer if (fs_handle) |h| h.deinit();
    var s3_handle: ?*ls.batch_store_s3.S3BatchStore = null;
    defer if (s3_handle) |h| h.deinit();
    var store: ls.batch_store.BatchStore = undefined;

    switch (blob_owned.cfg) {
        .fs => {
            const dir = if (parsed.snapshot_dir) |d|
                try allocator.dupe(u8, d)
            else
                try std.fmt.allocPrint(allocator, "{s}/.snapshots", .{parsed.data_dir});
            defer allocator.free(dir);
            fs_handle = try ls.batch_store_fs.FsBatchStore.init(allocator, dir);
            store = fs_handle.?.batchStore();
            std.log.info("snapshot store: fs at {s}", .{dir});
        },
        .s3 => |s3cfg| {
            const key_prefix = (try blob_mod.env.envOpt(allocator, ENV_SNAPSHOT_S3_KEY_PREFIX)) orelse
                try allocator.dupe(u8, "");
            defer allocator.free(key_prefix);
            s3_handle = try ls.batch_store_s3.S3BatchStore.init(allocator, .{
                .endpoint = s3cfg.endpoint,
                .region = s3cfg.region,
                .bucket = s3cfg.bucket,
                .key_prefix = key_prefix,
                .access_key = s3cfg.access_key,
                .secret_key = s3cfg.secret_key,
                .use_tls = s3cfg.use_tls,
            });
            store = s3_handle.?.batchStore();
            std.log.info(
                "snapshot store: s3 endpoint={s} bucket={s} key_prefix='{s}'",
                .{ s3cfg.endpoint, s3cfg.bucket, key_prefix },
            );
        },
    }

    const stage_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/.snapshot-stage",
        .{parsed.data_dir},
    );
    defer allocator.free(stage_dir);

    var captured = snapshot.captureFromDataDir(
        allocator,
        parsed.data_dir,
        store,
        stage_dir,
        parsed.apply_position,
        parsed.willemt_term,
    ) catch |err| {
        std.debug.print("error: snapshot: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer captured.deinit();

    std.debug.print(
        "captured snapshot {s}\n  manifest_key  : {s}\n  manifest_size : {d}\n",
        .{ captured.snap_id, captured.manifest_key, captured.manifest_bytes.len },
    );
}
