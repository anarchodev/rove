//! rove-log — request-id minting + node-wide log buffer.
//!
//! Two responsibilities, two structs:
//!
//!   - `RequestIdMinter` is per-tenant. Mints `request_id`s by combining
//!     the worker_id (upper 16 bits) with a chunked-reservation seq
//!     (lower 48 bits) persisted into the tenant's app.db at
//!     `_log/next_request_seq`. Per-tenant because each tenant's
//!     request_id space must be monotonic across cluster restarts —
//!     replay would mismatch otherwise.
//!
//!   - `NodeLogBuffer` is per-node. A single in-memory `LogRecord`
//!     buffer that the dispatch path appends to from every tenant on
//!     the node. `flushLogs` periodically drains it into one combined
//!     batch and PUTs it to S3. Per-node because the on-the-wire
//!     layout interleaves tenants — the worker writes one object per
//!     flush window regardless of tenant fan-in.
//!
//! Pre-Phase-5.5(a-2): a single `LogStore` per tenant held both
//! responsibilities, plus a per-tenant in-memory buffer. The buffer
//! was leftover from the raft-era per-tenant `log.db` model — every
//! flush combined all tenants' buffers into one batch anyway, so the
//! per-tenant slicing was complexity with no purpose. Splitting the
//! struct removes a `HashMap(instance_id, *Buffer)` from the hot
//! append path and folds the two-pass `flushLogs` into a single
//! threshold check + drain.
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

/// What caused this handler activation (streaming-handlers-plan §2,
/// shared by `dispatcher.Request.activation_source` and
/// `LogRecord.activation`). v1 has the two implemented variants; the
/// enum grows (`kv_wake`, `timer`, `disconnect`) when `__rove_stream`
/// lands.
pub const ActivationSource = enum(u8) {
    inbound = 0,
    send_callback = 1,
    /// Timer wake on a held stream (streaming-handlers-plan §4.5).
    /// Phase 2b-ii: the streaming-handler primitive's `waitFor.timer`
    /// fires this when its `intervalMs` (or absMs) reaches the
    /// sweep's check.
    timer = 2,
    /// Client disconnect on a held stream (streaming-handlers-plan
    /// §4.4). Implicit on every parked chain — h2 detects FIN/RST,
    /// routes the entity to `response_out`, and `cleanupResponses`
    /// fires one final handler run with this activation so the
    /// customer can do cleanup (release resources, log a "session
    /// ended" event, etc.). The handler's return is recorded on the
    /// tape but no bytes reach the wire — the socket is already
    /// gone.
    disconnect = 3,
    /// kv-write match wake on a held stream (streaming-handlers-plan
    /// §4.6). The cell registered one or more tenant-scoped prefixes
    /// via `waitFor: { kv: { prefix } }`; `apply.zig`'s writeset
    /// hook fired on a matching `put`/`delete` and `resumeStream`
    /// runs the handler with `request.activation = { kind: "kv",
    /// key, op }`. Prefix-only — predicate filters out of scope
    /// (§4.6 + §11.1).
    ///
    /// Legacy single-slot activation source. Superseded by
    /// `wake_batch` (Gap 2.2). Retained in the enum so replay can
    /// still decode pre-§9.4 tapes.
    kv_wake = 4,
    /// Wake-batch activation (streaming-handlers-plan §9.4 +
    /// `docs/primitive-gaps.md` §2.2). The held stream's
    /// `PendingWakes` ring drained into a temporal-order batch of
    /// kv-write + timer entries; the handler sees
    /// `request.activation = { kind: "wake_batch", wakes: [...],
    /// overflow: { lost_oldest } }`. Supersedes the per-wake
    /// `kv_wake` / `timer` activation sources for held streams.
    wake_batch = 5,
    /// Subscription chain origin (`docs/primitive-gaps.md` §2.1 +
    /// `docs/subscriptions-plan.md`). A `_subscriptions/<name>/`
    /// handler is firing without an inbound HTTP request — driven
    /// by a cron schedule, an apply-time kv-write match, or a
    /// once-per-deployment-activation boot. The handler sees
    /// `request.activation = { kind: "subscription_fire", name,
    /// source: { kind:"cron"|"kv"|"boot", ... } }`. There's no
    /// held socket; `Response` is recorded but not transmitted.
    subscription_fire = 6,
    /// Upstream send chunk (`docs/primitive-gaps.md` §2.3 +
    /// `docs/upstream-streaming-plan.md` §3). A handler opted into
    /// per-chunk visibility via `http.send({stream_response: true})`
    /// receives one of these per upstream chunk: `request.activation
    /// = { kind: "send_chunk", send_id, seq, byte_offset, bytes,
    /// send_headers? }`. The chain continues until `send_end`.
    send_chunk = 7,
    /// Terminal of a `stream_response: true` send. `request.activation
    /// = { kind: "send_end", send_id, ok, status, trailers }`.
    /// Counterpart to `send_callback` but for chunked sends: the
    /// body arrived as chunks, this carries the metadata + status.
    send_end = 8,
    /// Terminal of a `pipe_to: "held_response"` send. Handler is
    /// NOT invoked per chunk; the runtime pipes upstream bytes
    /// directly into the held client's `StreamChunks`. The
    /// terminal fires once upstream closes: `request.activation =
    /// { kind: "send_pipe_done", send_id, ok, status, bytes_piped,
    /// dropped_chunks }`.
    send_pipe_done = 9,
};

/// Inline tape + body byte payloads for one request. Each `_bytes`
/// field is allocator-owned; empty (`&.{}`) for channels the handler
/// didn't touch. Tape capture stores these directly in the LogRecord
/// — the `tapes: TapePayloads` field — and the flush writer emits
/// them base64-encoded in the ndjson line.
///
/// Pre-Phase-5.5(a-2) these were content-addressed blobs in a
/// per-tenant `log-blobs/` S3 prefix, with the LogRecord carrying
/// only `*_hex` hash refs. The fanout (one PUT per channel per
/// request) capped tape capture at single-digit-thousand req/s
/// because std.http.Client serializes a single OVH connection that
/// drops mid-write under concurrent load. Inlining collapses the
/// per-request PUT count to zero — bytes ride the existing per-flush
/// ndjson PUT — and removes the read-side hash→blob fetch hop.
pub const TapePayloads = struct {
    kv_tape_bytes: []const u8 = &.{},
    crypto_random_tape_bytes: []const u8 = &.{},
    date_tape_bytes: []const u8 = &.{},
    math_random_tape_bytes: []const u8 = &.{},
    module_tree_bytes: []const u8 = &.{},
    /// Captured request body (or its 256 KB prefix if the body was
    /// larger). Empty when the request had no body or the worker
    /// chose not to capture (no tenant log open).
    request_body_bytes: []const u8 = &.{},
    /// True iff `request_body_bytes` is a truncated prefix. Replay
    /// still feeds the captured bytes — the handler's view is what
    /// was captured, even if that's less than the original.
    request_body_truncated: bool = false,
    // Response body is NOT captured — deterministic replay
    // re-produces it from (request body, tapes, source). Storing
    // it on every batch PUT would be pure duplication on the S3
    // bill.

    pub fn deinit(self: *TapePayloads, allocator: std.mem.Allocator) void {
        if (self.kv_tape_bytes.len != 0) allocator.free(self.kv_tape_bytes);
        if (self.crypto_random_tape_bytes.len != 0) allocator.free(self.crypto_random_tape_bytes);
        if (self.date_tape_bytes.len != 0) allocator.free(self.date_tape_bytes);
        if (self.math_random_tape_bytes.len != 0) allocator.free(self.math_random_tape_bytes);
        if (self.module_tree_bytes.len != 0) allocator.free(self.module_tree_bytes);
        if (self.request_body_bytes.len != 0) allocator.free(self.request_body_bytes);
        self.* = .{};
    }
};

/// One request's log entry. All `[]const u8` fields are owned by the
/// record (allocated via the buffer's allocator). `deinit` frees them.
pub const LogRecord = struct {
    /// Tenant the request was scoped to. Lives on the record so a
    /// single per-node ndjson can interleave records from many
    /// tenants — the indexer demuxes on this field. Owned slice.
    tenant_id: []const u8,
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
    tapes: TapePayloads = .{},
    /// Per-chain identifier (streaming-handlers-plan §6). Empty
    /// string when the record has no chain context (pre-Phase-1
    /// records, or paths where the runtime couldn't synthesize one
    /// — early-error captures before request handling started).
    /// Allocator-owned alongside the other `[]const u8` fields.
    correlation_id: []const u8 = "",
    /// What caused this activation (streaming-handlers-plan §2).
    /// Defaults to `.inbound` for back-compat with code paths that
    /// haven't been updated to set it explicitly; the inbound case
    /// is by far the dominant one historically.
    activation: ActivationSource = .inbound,

    pub fn deinit(self: *LogRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.method);
        allocator.free(self.path);
        allocator.free(self.host);
        allocator.free(self.console);
        allocator.free(self.exception);
        if (self.correlation_id.len > 0) allocator.free(self.correlation_id);
        self.tapes.deinit(allocator);
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

/// Per-tenant request_id minter. Holds the chunked-reservation state
/// for one tenant; `nextRequestId` mints the next id and persists
/// every `REQUEST_ID_CHUNK`-th one to the kv store.
pub const RequestIdMinter = struct {
    allocator: std.mem.Allocator,
    /// Upper 16 bits of every `request_id` minted by this minter.
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

    /// Open a minter. Reads its chunked-reservation counter from
    /// `opts.seq_kv` at `opts.seq_key`; if absent, starts at 0. Any
    /// gap between the loaded value and what was actually handed out
    /// before the previous crash is intentional — see `REQUEST_ID_CHUNK`.
    pub fn init(
        allocator: std.mem.Allocator,
        worker_id: u16,
        opts: Options,
    ) Error!RequestIdMinter {
        const seq_key = allocator.dupe(u8, opts.seq_key) catch return Error.OutOfMemory;
        var self: RequestIdMinter = .{
            .allocator = allocator,
            .worker_id = worker_id,
            .seq_kv = opts.seq_kv,
            .seq_key = seq_key,
            .next_request_seq = 0,
            .reserved_until = 0,
        };
        const loaded = self.loadNextSeq() catch 0;
        self.next_request_seq = loaded;
        self.reserved_until = loaded;
        return self;
    }

    pub fn deinit(self: *RequestIdMinter) void {
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
    pub fn nextRequestId(self: *RequestIdMinter) Error!u64 {
        if (self.next_request_seq >= self.reserved_until) {
            self.reserved_until = self.next_request_seq + REQUEST_ID_CHUNK;
            self.persistReservedUntil() catch return Error.Kv;
        }
        const seq = self.next_request_seq;
        self.next_request_seq +%= 1;
        return (@as(u64, self.worker_id) << 48) | @as(u64, seq);
    }

    fn loadNextSeq(self: *RequestIdMinter) Error!u48 {
        const bytes = self.seq_kv.get(self.seq_key) catch |err| switch (err) {
            error.NotFound => return 0,
            else => return Error.Kv,
        };
        defer self.allocator.free(bytes);
        return std.fmt.parseInt(u48, bytes, 16) catch 0;
    }

    fn persistReservedUntil(self: *RequestIdMinter) !void {
        var buf: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{x:0>12}", .{self.reserved_until}) catch unreachable;
        self.seq_kv.put(self.seq_key, s) catch return Error.Kv;
    }
};

/// Single per-node in-memory `LogRecord` buffer. The dispatch path
/// appends from every tenant on the node; `flushLogs` drains the
/// whole buffer into one batch per flush window. Thresholds are
/// applied to the combined buffer, not per tenant.
pub const NodeLogBuffer = struct {
    allocator: std.mem.Allocator,
    /// In-memory batch waiting for the next flush. Each record is
    /// fully owned (its slices were allocated by `allocator` when the
    /// caller built the record).
    buffer: std.ArrayList(LogRecord),
    /// Wall-clock at the last `drainRecords` call. Used by `shouldFlush`
    /// for the time-based threshold.
    last_flush_ns: i64,
    /// Guards `buffer` and `last_flush_ns`. Multiple dispatch threads
    /// (one per tenant in the worker pool, in principle) can call
    /// `append` concurrently with the flusher's `drainRecords`. The
    /// critical section is just an ArrayList.append — sub-microsecond.
    mutex: std.Thread.Mutex = .{},

    flush_threshold_records: u32 = 1024,
    flush_threshold_bytes: u32 = 1 * 1024 * 1024,
    flush_interval_ns: i64 = 1 * std.time.ns_per_s,

    pub fn init(allocator: std.mem.Allocator) NodeLogBuffer {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .last_flush_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
        };
    }

    pub fn deinit(self: *NodeLogBuffer) void {
        for (self.buffer.items) |*r| r.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append a fully-owned LogRecord to the buffer. Caller transfers
    /// ownership of all slices; the buffer frees them on flush or
    /// deinit.
    pub fn append(self: *NodeLogBuffer, record: LogRecord) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.buffer.append(self.allocator, record) catch return Error.OutOfMemory;
    }

    /// Returns true if any flush threshold has been crossed:
    ///   - record count >= flush_threshold_records
    ///   - estimated buffer bytes >= flush_threshold_bytes
    ///   - elapsed since last flush >= flush_interval_ns (when buffer non-empty)
    /// Cheap to call every tick. Takes the mutex briefly.
    pub fn shouldFlush(self: *NodeLogBuffer, now_ns: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.buffer.items.len == 0) return false;
        if (self.buffer.items.len >= self.flush_threshold_records) return true;
        if (now_ns - self.last_flush_ns >= self.flush_interval_ns) return true;
        var estimated: usize = 0;
        for (self.buffer.items) |*r| estimated += estimateRecordBytes(r);
        if (estimated >= self.flush_threshold_bytes) return true;
        return false;
    }

    /// Hand the buffered records to the caller. Caller takes ownership
    /// of every record's `[]const u8` fields and the outer slice;
    /// deinit each then `free` the slice with `allocator`. Updates
    /// `last_flush_ns` so the time-based threshold doesn't fire
    /// repeatedly. Returns null when the buffer is empty.
    pub fn drainRecords(self: *NodeLogBuffer, allocator: std.mem.Allocator) Error!?[]LogRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
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
};

/// Approximate per-record byte cost used by `shouldFlush`'s byte
/// threshold. The flush path serializes to ndjson, which is roughly
/// 2-3× the raw struct size; the threshold is a soft cap, not exact.
fn estimateRecordBytes(r: *const LogRecord) usize {
    var n: usize = 64; // fixed-width header (request_id, timestamps, status, ...)
    n += r.method.len + r.path.len + r.host.len;
    n += r.console.len + r.exception.len;
    // Inline tape + body payloads ride in the ndjson record as
    // base64. The threshold is a soft cap so we skip the *4/3
    // expansion and just account raw bytes — slightly under-counts
    // but matches the original "approximate" intent.
    n += r.tapes.kv_tape_bytes.len;
    n += r.tapes.crypto_random_tape_bytes.len;
    n += r.tapes.date_tape_bytes.len;
    n += r.tapes.math_random_tape_bytes.len;
    n += r.tapes.module_tree_bytes.len;
    n += r.tapes.request_body_bytes.len;
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
        .tenant_id = try allocator.dupe(u8, "acme"),
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

const TestMinter = struct {
    allocator: std.mem.Allocator,
    tmp_dir: []u8,
    seq_kv: *kv_mod.KvStore,
    minter: RequestIdMinter,

    fn init(allocator: std.mem.Allocator) !TestMinter {
        const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-log-test-{x}", .{seed});
        errdefer allocator.free(tmp_dir);
        std.fs.cwd().deleteTree(tmp_dir) catch {};
        try std.fs.cwd().makePath(tmp_dir);
        const seq_path = try std.fmt.allocPrintSentinel(allocator, "{s}/seq.db", .{tmp_dir}, 0);
        defer allocator.free(seq_path);
        const seq_kv = try kv_mod.KvStore.open(allocator, seq_path);
        errdefer seq_kv.close();
        const minter = try RequestIdMinter.init(allocator, 7, .{
            .seq_kv = seq_kv,
            .seq_key = "_log/next_request_seq",
        });
        return .{ .allocator = allocator, .tmp_dir = tmp_dir, .seq_kv = seq_kv, .minter = minter };
    }

    fn deinit(self: *TestMinter) void {
        self.minter.deinit();
        self.seq_kv.close();
        std.fs.cwd().deleteTree(self.tmp_dir) catch {};
        self.allocator.free(self.tmp_dir);
    }
};

test "NodeLogBuffer shouldFlush honors record-count threshold" {
    const a = testing.allocator;
    var buf = NodeLogBuffer.init(a);
    defer buf.deinit();
    buf.flush_threshold_records = 3;
    buf.flush_interval_ns = std.math.maxInt(i64); // disable time path

    const now: i64 = 0;
    try testing.expect(!buf.shouldFlush(now));
    try buf.append(try buildRecord(a, 1, "GET", "/", 200, .ok, ""));
    try testing.expect(!buf.shouldFlush(now));
    try buf.append(try buildRecord(a, 2, "GET", "/", 200, .ok, ""));
    try testing.expect(!buf.shouldFlush(now));
    try buf.append(try buildRecord(a, 3, "GET", "/", 200, .ok, ""));
    try testing.expect(buf.shouldFlush(now));
}

test "NodeLogBuffer shouldFlush honors time threshold" {
    const a = testing.allocator;
    var buf = NodeLogBuffer.init(a);
    defer buf.deinit();
    buf.flush_threshold_records = 1000;
    buf.flush_threshold_bytes = std.math.maxInt(u32);
    buf.flush_interval_ns = 1_000_000; // 1 ms
    buf.last_flush_ns = 0;

    try buf.append(try buildRecord(a, 1, "GET", "/", 200, .ok, ""));
    try testing.expect(!buf.shouldFlush(500_000));
    try testing.expect(buf.shouldFlush(1_500_000));
}

test "NodeLogBuffer drainRecords transfers ownership and clears the buffer" {
    const a = testing.allocator;
    var buf = NodeLogBuffer.init(a);
    defer buf.deinit();

    try buf.append(try buildRecord(a, 1, "GET", "/a", 200, .ok, ""));
    try buf.append(try buildRecord(a, 2, "POST", "/b", 503, .fault, "boom\n"));

    const drained = (try buf.drainRecords(a)).?;
    defer {
        for (drained) |*r| r.deinit(a);
        a.free(drained);
    }
    try testing.expectEqual(@as(usize, 2), drained.len);
    try testing.expectEqualStrings("/a", drained[0].path);
    try testing.expectEqualStrings("/b", drained[1].path);
    try testing.expectEqual(@as(usize, 0), buf.buffer.items.len);
    try testing.expectEqual(@as(?[]LogRecord, null), try buf.drainRecords(a));
}

test "RequestIdMinter persists next_request_seq across reopen (chunked)" {
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
        var minter = try RequestIdMinter.init(a, 0, .{
            .seq_kv = seq_kv,
            .seq_key = "_log/next_request_seq",
        });
        defer minter.deinit();
        first_ids[0] = try minter.nextRequestId();
        first_ids[1] = try minter.nextRequestId();
        first_ids[2] = try minter.nextRequestId();
    }
    {
        const seq_kv = try kv_mod.KvStore.open(a, seq_path);
        defer seq_kv.close();
        var minter = try RequestIdMinter.init(a, 0, .{
            .seq_kv = seq_kv,
            .seq_key = "_log/next_request_seq",
        });
        defer minter.deinit();
        const next = try minter.nextRequestId();
        // Under chunked reservation: the first nextRequestId call in
        // the previous process persisted `reserved_until = REQUEST_ID_CHUNK`.
        // The reopened minter loads that value and hands out its first
        // id at exactly `REQUEST_ID_CHUNK` — the intervening seqs
        // 3..REQUEST_ID_CHUNK-1 become an intentional sparse gap.
        try testing.expectEqual(@as(u64, REQUEST_ID_CHUNK), next);
        for (first_ids) |prior| try testing.expect(next > prior);
    }
}

test "RequestIdMinter worker_id occupies the upper 16 bits of request_id" {
    const a = testing.allocator;
    var fx = try TestMinter.init(a);
    defer fx.deinit();
    // Override the worker_id by re-initing — fixture defaults to 7.
    fx.minter.deinit();
    fx.minter = try RequestIdMinter.init(a, 0xCAFE, .{
        .seq_kv = fx.seq_kv,
        .seq_key = "_log/next_request_seq",
    });
    const id = try fx.minter.nextRequestId();
    try testing.expectEqual(@as(u64, 0xCAFE), id >> 48);
    try testing.expectEqual(@as(u64, 0), id & 0xFFFFFFFFFFFF);
}
