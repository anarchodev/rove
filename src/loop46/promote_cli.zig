//! `loop46 promote-learner` subcommand — lost-quorum recovery for a
//! learner replica (production.md #1.2 step 3). When >half the voting
//! cluster has died simultaneously, raft loses quorum permanently and
//! no in-band promotion is possible. The learner has been applying
//! every committed entry as a non-voter so its app.dbs are current
//! (or close to it, modulo whatever the snapshot-catchup machinery
//! has streamed in). Recovery: reconfigure the learner as a 1-node
//! voting cluster while keeping all of its app state.
//!
//! Mechanism — drop the raft.log.db. willemt's persistent log holds
//! both the entry history AND the persisted membership state.
//! Wiping it forces a clean boot: the operator restarts the worker
//! with `--peers <self>:<port>:voter` (no other peers), willemt sees
//! a fresh log + a single-voter config, elects itself in one round,
//! and starts serving writes. App.db state is untouched — every
//! committed kv row that ever reached this node stays.
//!
//! Loss model:
//!   - Entries committed elsewhere but not yet applied here: LOST.
//!     For a healthy learner that was keeping up, the gap is bounded
//!     by one heartbeat interval (~100ms) — entries the leader had
//!     committed but hadn't yet replicated past one heartbeat.
//!   - Entries committed AND applied here: preserved (in app.dbs).
//!
//! Usage:
//!   loop46 promote-learner --data-dir <path>
//!
//! After this runs, restart the worker with a peers list naming only
//! itself as a voter:
//!   loop46 worker --node-id N --peers <host>:<raft_port>:voter \
//!     --listen <host>:<raft_port> --http <host>:<http_port> \
//!     --data-dir <path>

const std = @import("std");

const Args = struct {
    data_dir: []const u8,
};

fn parseArgs(args: []const [:0]u8) !Args {
    var data_dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            data_dir = args[i];
        } else {
            return error.Usage;
        }
    }
    return .{
        .data_dir = data_dir orelse return error.Usage,
    };
}

pub fn runPromote(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    const parsed = try parseArgs(args);

    // Confirm the data_dir looks like a worker home — at minimum it
    // should have a `cluster.kv` (the consolidated kvexp manifest
    // holding __root__ + every tenant's store; replaced the
    // per-tenant `__root__.db` SQLite file post-cutover). We
    // deliberately don't require a `raft.log.db` to exist (a fresh
    // learner that's never persisted would still benefit from this
    // command running without error).
    const root_path = try std.fmt.allocPrint(allocator, "{s}/cluster.kv", .{parsed.data_dir});
    defer allocator.free(root_path);
    std.fs.cwd().access(root_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err(
                "promote-learner: {s} not found — is `{s}` actually a worker data dir?",
                .{ root_path, parsed.data_dir },
            );
            return error.NotADataDir;
        },
        else => return err,
    };

    // Drop the raft log + any sidecar files (-wal, -shm). The next
    // boot will open a fresh empty log; willemt will rebuild its
    // node table from the new --peers flag.
    var deleted: usize = 0;
    inline for (.{ "raft.log.db", "raft.log.db-wal", "raft.log.db-shm" }) |name| {
        const path = try std.fs.path.join(allocator, &.{ parsed.data_dir, name });
        defer allocator.free(path);
        if (std.fs.cwd().deleteFile(path)) {
            deleted += 1;
            std.log.info("promote-learner: removed {s}", .{path});
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                std.log.err("promote-learner: failed to remove {s}: {s}", .{ path, @errorName(err) });
                return err;
            },
        }
    }

    if (deleted == 0) {
        std.log.warn(
            "promote-learner: no raft.log.db (or sidecars) found under {s}; nothing to wipe. " ++
                "If this is intentional (never-started node), proceed with the restart anyway.",
            .{parsed.data_dir},
        );
    }

    std.debug.print(
        \\
        \\promote-learner: data_dir {s} is now ready for 1-node-cluster boot.
        \\
        \\Restart the worker with a peers list naming ONLY this node, plus
        \\the --allow-single-peer opt-in (the default validation rejects
        \\single-peer deploys to catch misconfigs):
        \\
        \\  loop46 worker --node-id 0 \
        \\                --peers <host>:<raft_port>:voter \
        \\                --allow-single-peer \
        \\                --listen <host>:<raft_port> \
        \\                --http <host>:<http_port> \
        \\                --data-dir {s}
        \\
        \\willemt will elect itself in one round and start serving writes.
        \\App.db state is preserved; any entries the surviving node hadn't
        \\yet applied at the time of the original cluster loss are gone.
        \\
        \\Add new voters via the normal --peers list once they're ready.
        \\
    , .{ parsed.data_dir, parsed.data_dir });
}
