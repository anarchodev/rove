//! `loop46 restore-from-snapshot` subcommand — pulls a snapshot
//! out of a `BatchStore` (S3 or fs, picked off `BLOB_BACKEND`
//! env) and installs it into a fresh `--data-dir`. Phase 5.5(c)
//! step 4. Used by:
//!
//!   - Disaster recovery: every node lost its disk; bring up a
//!     fresh node, run this against the snapshot bucket, start
//!     `loop46 worker`. New leader picks up at the snapshot's
//!     compaction floor.
//!   - Point-in-time rollback: pick an older `--snap-id` than the
//!     latest. Operator confirms the discard of post-floor state.
//!
//! Usage:
//!     loop46 restore-from-snapshot --snap-id <id> --data-dir <path>
//!                                  [--snapshot-dir <path>]
//!
//! With `BLOB_BACKEND=fs` (default) the snapshot store reads from
//! `--snapshot-dir` (defaults to `{data_dir}/.snapshots`). With
//! `BLOB_BACKEND=s3` the standard S3 env vars apply, and an
//! optional `SNAPSHOT_S3_KEY_PREFIX` namespaces the bucket.

const std = @import("std");
const blob_mod = @import("rove-blob");
const ls = @import("rove-log-server");

const main_mod = @import("main.zig");
const snapshot = @import("snapshot.zig");

const ENV_SNAPSHOT_S3_KEY_PREFIX = "SNAPSHOT_S3_KEY_PREFIX";

const Args = struct {
    snap_id: []const u8,
    data_dir: []const u8,
    snapshot_dir: ?[]const u8 = null,
};

fn parseArgs(args: []const [:0]u8) !Args {
    var snap_id: ?[]const u8 = null;
    var data_dir: ?[]const u8 = null;
    var snapshot_dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--snap-id")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            snap_id = args[i];
        } else if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            data_dir = args[i];
        } else if (std.mem.eql(u8, a, "--snapshot-dir")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            snapshot_dir = args[i];
        } else {
            return error.Usage;
        }
    }
    return .{
        .snap_id = snap_id orelse return error.Usage,
        .data_dir = data_dir orelse return error.Usage,
        .snapshot_dir = snapshot_dir,
    };
}

/// Drive the subcommand. Mirrors `seed.runSeed`'s shape: validates
/// args, opens the right store backend off env, calls
/// `snapshot.restore`, prints a summary. Exits non-zero on usage
/// errors so a wrapping shell can distinguish operator typos from
/// legitimate failures.
pub fn runRestore(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    const parsed = try parseArgs(args);

    try std.fs.cwd().makePath(parsed.data_dir);

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
        "{s}/.restore-stage",
        .{parsed.data_dir},
    );
    defer allocator.free(stage_dir);

    var restored = snapshot.restore(
        allocator,
        store,
        parsed.snap_id,
        parsed.data_dir,
        stage_dir,
    ) catch |err| {
        std.debug.print("error: restore: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer restored.manifest.deinit();

    std.debug.print(
        "restored snapshot {s}\n  data_dir       : {s}\n  tenants        : {d}\n  root_db        : {s}\n  willemt_floor  : {d}\n  willemt_term   : {d}\n  captured_at_ms : {d}\n",
        .{
            restored.manifest.snap_id,
            parsed.data_dir,
            restored.tenants_restored,
            if (restored.root_restored) "yes" else "no",
            restored.manifest.willemt_compaction_floor,
            restored.manifest.willemt_term,
            restored.manifest.captured_at_ms,
        },
    );
}
