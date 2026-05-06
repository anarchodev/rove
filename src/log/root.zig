//! rove-log — per-request log buffer + chunked request-id minting.
//!
//! `LogStore` holds:
//!   - a per-tenant in-memory `LogRecord` buffer (the worker's
//!     dispatch loop appends here on every request)
//!   - a chunked-reservation counter for `request_id`, persisted to
//!     a caller-provided KvStore + key (the worker passes app.db at
//!     `_log/next_request_seq`)
//!
//! `flushLogs` periodically calls `drainRecords` and ships the
//! `LogRecord`s straight to S3 via `rove-log-server.flush_writer`
//! (ndjson + sidecar). The standalone log-server reads them back
//! out via `IndexDb` + range-reads.
//!
//! There is no longer a record-side KV / records-on-disk path. Pre-
//! Phase-5.5(a), records lived in a per-tenant `log.db` so the
//! in-process log-server thread could `list`/`get` them; that thread
//! is gone, log.db is gone, and this module's API is correspondingly
//! buffer-only. Tape body bytes still live in the per-tenant
//! `BlobBackend` (fs or s3 prefix `{base}{tenant}/log-blobs/`); the
//! BlobBackend is owned by the worker, not by `LogStore`, so it
//! doesn't appear here either.
//!
//! ## Best-effort, not durable
//!
//! Records sit in volatile memory between flushes. A worker crash
//! between `append` and the next flush loses those records. This is
//! intentional — logs are observability, not source-of-truth state.

const std = @import("std");
const kv_mod = @import("rove-kv");

pub const Error = error{
    Kv,
    OutOfMemory,
};

pub const HASH_HEX_LEN: usize = 64;

/// Per-request lifecycle outcome.
pub const Outcome = enum(u8) {
    ok = 0,
    fault = 1,
    timeout = 2,
    handler_error = 3,
    kv_error = 4,
    no_deployment = 5,
    unknown_domain = 6,
};

/// Per-request blob references attached to a `LogRecord`. Each
/// non-null field is a 64-char hex hash of bytes living in the
/// tenant's `log-blobs/` BlobBackend. Replay fetches each by hash
/// and either re-drives the handler from the captured non-determinism
/// (the `*_tape_*` channels) or stamps the runtime globals (the
/// `*_body_*` captures).
pub const TapeRefs = struct {
    kv_tape_hex: ?[HASH_HEX_LEN]u8 = null,
    crypto_random_tape_hex: ?[HASH_HEX_LEN]u8 = null,
    date_tape_hex: ?[HASH_HEX_LEN]u8 = null,
    math_random_tape_hex: ?[HASH_HEX_LEN]u8 = null,
    module_tree_hex: ?[HASH_HEX_LEN]u8 = null,
    /// Hash of the captured request body (or its 256 KB prefix if
    /// the body was larger). Null when the request had no body or
    /// the worker chose not to capture (no tenant log open).
    request_body_hex: ?[HASH_HEX_LEN]u8 = null,
    /// True iff `request_body_hex` references a truncated prefix.
    /// Replay still feeds the captured bytes — the handler's view
    /// is what was captured, even if that's less than the full
    /// original body.
    request_body_truncated: bool = false,
    /// Hash of the captured response body (handler return value
    /// after content-type sniffing / JSON serialization, truncated
    /// to 256 KB). Null when the handler returned no body or the
    /// worker chose not to capture.
    response_body_hex: ?[HASH_HEX_LEN]u8 = null,
    /// True iff `response_body_hex` references a truncated prefix.
    response_body_truncated: bool = false,
};

/// One request's log entry. All `[]const u8` fields are owned by the
/// record (allocated via the LogStore's allocator). `deinit` frees them.
pub const LogRecord = struct {
    /// Combined identifier: upper 16 bits = worker_id, lower 48 = seq.
    request_id: u64,
    /// The deployment that was active when this request ran.
    /// Pulled from `TenantFiles.current_deployment_id`. Replay needs
    /// this to load the exact bytecode the handler used.
    deployment_id: u64,
    received_ns: i64,
    duration_ns: i64,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    status: u16,
    outcome: Outcome,
    /// Captured `console.log`/`console.warn`/`console.error` output.
    /// Empty if the handler didn't write to console.
    console: []const u8,
    /// JS exception message if the handler threw. Empty otherwise.
    exception: []const u8,
    tape_refs: TapeRefs = .{},

    pub fn deinit(self: *LogRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path);
        allocator.free(self.host);
        allocator.free(self.console);
        allocator.free(self.exception);
        self.* = undefined;
    }
};

/// Request-id reservation window size. `nextRequestId` hands out this
/// many ids in memory before persisting a new high-water mark to the
/// kv store. Larger = fewer SQLite autocommits per request (which
/// dominated ~29% of dispatch CPU profiling before this was batched);
/// smaller = fewer ids wasted to sparse gaps after a crash.
///
/// Invariant: after a crash, the next process resumes from the last
/// persisted `reserved_until`. Any ids already minted from the prior
/// window but not yet committed become a gap (unused, sparse), which
/// is benign — ids never collide across restarts.
pub const REQUEST_ID_CHUNK: u48 = 1024;

/// Where the chunked-reservation counter lives. The worker passes
/// `inst.kv` (app.db) and `"_log/next_request_seq"`. Tests pass a
/// dedicated SQLite file. Both fields are required — there is no
/// implicit fallback.
pub const Options = struct {
    seq_kv: *kv_mod.KvStore,
    seq_key: []const u8,
};

pub const LogStore = struct {
    allocator: std.mem.Allocator,
    /// Upper 16 bits of every `request_id` minted by this LogStore.
    /// Sourced from raft node id at the worker layer; unique per node.
    worker_id: u16,
    /// Where chunked-reservation persists. See `Options.seq_kv`.
    seq_kv: *kv_mod.KvStore,
    /// Owned key used by the chunked-reservation counter (heap-
    /// allocated copy of `Options.seq_key` so the caller can pass
    /// a stack-local literal without lifetime worries).
    seq_key: []u8,
    /// Lower 48 bits of the next `request_id` to hand out. In-memory
    /// counter that advances on every `nextRequestId` call. Only
    /// values < `reserved_until` are safe to hand out — when they
    /// catch up, `nextRequestId` reserves a new chunk on disk.
    next_request_seq: u48,
    /// Highest (exclusive) seq that has been reserved on disk via
    /// `seq_key`. On restart this value is loaded and
    /// `next_request_seq` resumes from it, which may leave a sparse
    /// gap up to `REQUEST_ID_CHUNK` wide — acceptable since the
    /// invariant we need is "ids never collide," not "ids are dense."
    reserved_until: u48,
    /// In-memory batch waiting for the next flush. Each record is
    /// fully owned (its slices were allocated by `allocator` when the
    /// caller built the record).
    buffer: std.ArrayList(LogRecord),
    /// Wall-clock at the last `drainRecords` call. Used by `shouldFlush`
    /// for the time-based threshold.
    last_flush_ns: i64,

    flush_threshold_records: u32 = 256,
    flush_threshold_bytes: u32 = 64 * 1024,
    flush_interval_ns: i64 = 1 * std.time.ns_per_s,

    /// Open a LogStore. Reads its chunked-reservation counter from
    /// `opts.seq_kv` at `opts.seq_key`; if absent, starts at 0. Any
    /// gap between the loaded value and what was actually handed out
    /// before the previous crash is intentional — see `REQUEST_ID_CHUNK`.
    pub fn init(
        allocator: std.mem.Allocator,
        worker_id: u16,
        opts: Options,
    ) Error!LogStore {
        const seq_key = allocator.dupe(u8, opts.seq_key) catch return Error.OutOfMemory;
        var self: LogStore = .{
            .allocator = allocator,
            .worker_id = worker_id,
            .seq_kv = opts.seq_kv,
            .seq_key = seq_key,
            .next_request_seq = 0,
            .reserved_until = 0,
            .buffer = .empty,
            .last_flush_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
        };
        const loaded = self.loadNextSeq() catch 0;
        self.next_request_seq = loaded;
        self.reserved_until = loaded;
        return self;
    }

    pub fn deinit(self: *LogStore) void {
        for (self.buffer.items) |*r| r.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
        self.allocator.free(self.seq_key);
        self.* = undefined;
    }

    /// Mint a new request_id for the next request. Combines worker_id
    /// (upper 16) with the monotonic local seq (lower 48).
    ///
    /// Hands out ids from a pre-reserved window — the kv store only
    /// sees a write once per `REQUEST_ID_CHUNK` ids, not once per
    /// request. This is load-bearing for dispatch throughput: the
    /// per-request autocommit was ~29% of CPU in a 2026-04-14 profile.
    /// On restart, any unused tail of the last reservation is
    /// abandoned — ids become sparse across restarts, but never
    /// collide.
    pub fn nextRequestId(self: *LogStore) Error!u64 {
        if (self.next_request_seq >= self.reserved_until) {
            self.reserved_until = self.next_request_seq + REQUEST_ID_CHUNK;
            self.persistReservedUntil() catch return Error.Kv;
        }
        const seq = self.next_request_seq;
        self.next_request_seq +%= 1;
        return (@as(u64, self.worker_id) << 48) | @as(u64, seq);
    }

    /// Append a fully-owned LogRecord to the buffer. Caller transfers
    /// ownership of all slices; the LogStore frees them on flush or
    /// deinit. Use `nextRequestId` first to get a stable id.
    pub fn append(self: *LogStore, record: LogRecord) Error!void {
        self.buffer.append(self.allocator, record) catch return Error.OutOfMemory;
    }

    /// Returns true if any flush threshold has been crossed:
    ///   - record count >= flush_threshold_records
    ///   - estimated buffer bytes >= flush_threshold_bytes
    ///   - elapsed since last flush >= flush_interval_ns
    /// Cheap to call every tick.
    pub fn shouldFlush(self: *LogStore, now_ns: i64) bool {
        if (self.buffer.items.len == 0) return false;
        if (self.buffer.items.len >= self.flush_threshold_records) return true;
        if (now_ns - self.last_flush_ns >= self.flush_interval_ns) return true;
        var estimated: usize = 0;
        for (self.buffer.items) |*r| estimated += estimateRecordBytes(r);
        if (estimated >= self.flush_threshold_bytes) return true;
        return false;
    }

    /// Hand the buffered records to the caller. The worker's flush
    /// path needs the structured `LogRecord`s (not a serialized blob)
    /// to build per-record offsets for the S3 sidecar. Caller takes
    /// ownership of every record's `[]const u8` fields and the outer
    /// slice; deinit each then `free` the slice with `allocator`.
    /// Updates `last_flush_ns` so the time-based threshold doesn't
    /// fire repeatedly. Returns null when the buffer is empty.
    pub fn drainRecords(self: *LogStore, allocator: std.mem.Allocator) Error!?[]LogRecord {
        self.last_flush_ns = @as(i64, @intCast(std.time.nanoTimestamp()));
        if (self.buffer.items.len == 0) return null;

        const out = allocator.alloc(LogRecord, self.buffer.items.len) catch
            return Error.OutOfMemory;
        @memcpy(out, self.buffer.items);
        // Records' []const u8 fields move into `out`. Clear the
        // buffer without re-freeing them — caller owns now.
        self.buffer.clearRetainingCapacity();
        return out;
    }

    fn loadNextSeq(self: *LogStore) Error!u48 {
        const bytes = self.seq_kv.get(self.seq_key) catch |err| switch (err) {
            error.NotFound => return 0,
            else => return Error.Kv,
        };
        defer self.allocator.free(bytes);
        return std.fmt.parseInt(u48, bytes, 16) catch 0;
    }

    fn persistReservedUntil(self: *LogStore) !void {
        var buf: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{x:0>12}", .{self.reserved_until}) catch unreachable;
        self.seq_kv.put(self.seq_key, s) catch return Error.Kv;
    }
};

/// Approximate per-record byte cost used by `shouldFlush`'s byte
/// threshold. The flush path serializes to ndjson, which is roughly
/// 2-3× the raw struct size; the threshold is a soft cap, not exact.
fn estimateRecordBytes(r: *const LogRecord) usize {
    var n: usize = 64; // fixed-width header (request_id, timestamps, status, ...)
    n += r.method.len + r.path.len + r.host.len;
    n += r.console.len + r.exception.len;
    if (r.tape_refs.kv_tape_hex != null) n += HASH_HEX_LEN;
    if (r.tape_refs.crypto_random_tape_hex != null) n += HASH_HEX_LEN;
    if (r.tape_refs.date_tape_hex != null) n += HASH_HEX_LEN;
    if (r.tape_refs.math_random_tape_hex != null) n += HASH_HEX_LEN;
    if (r.tape_refs.module_tree_hex != null) n += HASH_HEX_LEN;
    if (r.tape_refs.request_body_hex != null) n += HASH_HEX_LEN;
    if (r.tape_refs.response_body_hex != null) n += HASH_HEX_LEN;
    return n;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn buildRecord(
    allocator: std.mem.Allocator,
    request_id: u64,
    method: []const u8,
    path: []const u8,
    status: u16,
    outcome: Outcome,
    console: []const u8,
) !LogRecord {
    return .{
        .request_id = request_id,
        .deployment_id = 42,
        .received_ns = 1_000_000_000,
        .duration_ns = 500_000,
        .method = try allocator.dupe(u8, method),
        .path = try allocator.dupe(u8, path),
        .host = try allocator.dupe(u8, "acme.test"),
        .status = status,
        .outcome = outcome,
        .console = try allocator.dupe(u8, console),
        .exception = try allocator.dupe(u8, ""),
    };
}

const TestStore = struct {
    allocator: std.mem.Allocator,
    tmp_dir: []u8,
    seq_kv: *kv_mod.KvStore,
    log: LogStore,

    fn init(allocator: std.mem.Allocator) !TestStore {
        const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-log-test-{x}", .{seed});
        errdefer allocator.free(tmp_dir);
        std.fs.cwd().deleteTree(tmp_dir) catch {};
        try std.fs.cwd().makePath(tmp_dir);
        const seq_path = try std.fmt.allocPrintSentinel(allocator, "{s}/seq.db", .{tmp_dir}, 0);
        defer allocator.free(seq_path);
        const seq_kv = try kv_mod.KvStore.open(allocator, seq_path);
        errdefer seq_kv.close();
        const log = try LogStore.init(allocator, 7, .{
            .seq_kv = seq_kv,
            .seq_key = "_log/next_request_seq",
        });
        return .{ .allocator = allocator, .tmp_dir = tmp_dir, .seq_kv = seq_kv, .log = log };
    }

    fn deinit(self: *TestStore) void {
        self.log.deinit();
        self.seq_kv.close();
        std.fs.cwd().deleteTree(self.tmp_dir) catch {};
        self.allocator.free(self.tmp_dir);
    }
};

test "shouldFlush honors record-count threshold" {
    const a = testing.allocator;
    var fx = try TestStore.init(a);
    defer fx.deinit();
    fx.log.flush_threshold_records = 3;
    fx.log.flush_interval_ns = std.math.maxInt(i64); // disable time path

    const now: i64 = 0;
    try testing.expect(!fx.log.shouldFlush(now));
    try fx.log.append(try buildRecord(a, 1, "GET", "/", 200, .ok, ""));
    try testing.expect(!fx.log.shouldFlush(now));
    try fx.log.append(try buildRecord(a, 2, "GET", "/", 200, .ok, ""));
    try testing.expect(!fx.log.shouldFlush(now));
    try fx.log.append(try buildRecord(a, 3, "GET", "/", 200, .ok, ""));
    try testing.expect(fx.log.shouldFlush(now));
}

test "shouldFlush honors time threshold" {
    const a = testing.allocator;
    var fx = try TestStore.init(a);
    defer fx.deinit();
    fx.log.flush_threshold_records = 1000;
    fx.log.flush_threshold_bytes = std.math.maxInt(u32);
    fx.log.flush_interval_ns = 1_000_000; // 1 ms
    fx.log.last_flush_ns = 0;

    try fx.log.append(try buildRecord(a, 1, "GET", "/", 200, .ok, ""));
    try testing.expect(!fx.log.shouldFlush(500_000));
    try testing.expect(fx.log.shouldFlush(1_500_000));
}

test "drainRecords transfers ownership and clears the buffer" {
    const a = testing.allocator;
    var fx = try TestStore.init(a);
    defer fx.deinit();

    try fx.log.append(try buildRecord(a, 1, "GET", "/a", 200, .ok, ""));
    try fx.log.append(try buildRecord(a, 2, "POST", "/b", 503, .fault, "boom\n"));

    const drained = (try fx.log.drainRecords(a)).?;
    defer {
        for (drained) |*r| r.deinit(a);
        a.free(drained);
    }
    try testing.expectEqual(@as(usize, 2), drained.len);
    try testing.expectEqualStrings("/a", drained[0].path);
    try testing.expectEqualStrings("/b", drained[1].path);
    try testing.expectEqual(@as(usize, 0), fx.log.buffer.items.len);
    try testing.expectEqual(@as(?[]LogRecord, null), try fx.log.drainRecords(a));
}

test "next_request_seq persists across LogStore reopen (chunked)" {
    const a = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(a, "/tmp/rove-log-persist-{x}", .{seed});
    defer a.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const seq_path = try std.fmt.allocPrintSentinel(a, "{s}/seq.db", .{tmp_dir}, 0);
    defer a.free(seq_path);

    var first_ids: [3]u64 = undefined;
    {
        const seq_kv = try kv_mod.KvStore.open(a, seq_path);
        defer seq_kv.close();
        var log = try LogStore.init(a, 0, .{
            .seq_kv = seq_kv,
            .seq_key = "_log/next_request_seq",
        });
        defer log.deinit();
        first_ids[0] = try log.nextRequestId();
        first_ids[1] = try log.nextRequestId();
        first_ids[2] = try log.nextRequestId();
    }
    {
        const seq_kv = try kv_mod.KvStore.open(a, seq_path);
        defer seq_kv.close();
        var log = try LogStore.init(a, 0, .{
            .seq_kv = seq_kv,
            .seq_key = "_log/next_request_seq",
        });
        defer log.deinit();
        const next = try log.nextRequestId();
        // Under chunked reservation: the first nextRequestId call in
        // the previous process persisted `reserved_until = REQUEST_ID_CHUNK`.
        // The reopened store loads that value and hands out its first
        // id at exactly `REQUEST_ID_CHUNK` — the intervening seqs
        // 3..REQUEST_ID_CHUNK-1 become an intentional sparse gap.
        try testing.expectEqual(@as(u64, REQUEST_ID_CHUNK), next);
        for (first_ids) |prior| try testing.expect(next > prior);
    }
}

test "worker_id occupies the upper 16 bits of request_id" {
    const a = testing.allocator;
    var fx = try TestStore.init(a);
    defer fx.deinit();
    // Override the worker_id by re-initing — fixture defaults to 7.
    fx.log.deinit();
    fx.log = try LogStore.init(a, 0xCAFE, .{
        .seq_kv = fx.seq_kv,
        .seq_key = "_log/next_request_seq",
    });
    const id = try fx.log.nextRequestId();
    try testing.expectEqual(@as(u64, 0xCAFE), id >> 48);
    try testing.expectEqual(@as(u64, 0), id & 0xFFFFFFFFFFFF);
}
