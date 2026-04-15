//! rove-log — per-tenant request log store.
//!
//! Every request the worker dispatches gets a `LogRecord`. Records
//! accumulate in an in-memory buffer per tenant. Periodically
//! (`shouldFlush`), the buffer is drained into a serialized **batch**
//! that the worker proposes through raft as a single entry. The apply
//! callback decodes the batch on every node and writes individual
//! records to that node's local `log.db`.
//!
//! Batching amortizes raft cost across N records. Reads AND writes
//! are logged because some tenants want a full audit trail; the cost
//! is hidden by the batch size, not the per-request synchronous write
//! that shift-js used.
//!
//! ## What's NOT in Phase 3
//!
//! - **Request / response bodies.** Deferred to Phase 4 alongside
//!   rove-tape. The `tape_refs` slot on `LogRecord` is reserved.
//! - **Body offload to rove-blob.** Phase 4 will populate tape blobs
//!   in `{inst.dir}/log-blobs/`. The `blob: BlobStore` field is here
//!   today so callers can construct a complete LogStore now without
//!   needing to add a parameter later.
//! - **S3 batch payload split.** Today the raft entry payload IS the
//!   batch bytes. Phase 6 changes this so the leader uploads the
//!   batch blob to S3 and the raft entry carries only the index. The
//!   library API doesn't change.
//! - **Retention / GC.** No automatic sweep. A future
//!   `purgeOlderThan(ns)` API is planned but not present yet.
//!
//! ## Best-effort, not durable
//!
//! Records sit in volatile memory between flushes. A worker crash
//! between `append` and the next flush loses those records. This is
//! intentional — logs are observability, not source-of-truth state.
//! The user explicitly chose this trade-off.
//!
//! ## Followers without raft proposal rights
//!
//! In a multi-node cluster, only the leader can propose raft entries.
//! Follower-handled requests (currently: reads on followers in the
//! existing rove-js model) get logged via a direct `applyBatch` call
//! to the local store, bypassing raft. They're visible in local
//! queries but not replicated to other nodes. Documented gap.

const std = @import("std");
const kv_mod = @import("rove-kv");
const blob_mod = @import("rove-blob");

pub const Error = error{
    Truncated,
    InvalidVersion,
    InvalidOutcome,
    Kv,
    Blob,
    OutOfMemory,
};

pub const HASH_HEX_LEN: usize = 64;

/// Per-request lifecycle outcome. Stored in a single byte on the wire.
pub const Outcome = enum(u8) {
    ok = 0,
    fault = 1,
    timeout = 2,
    handler_error = 3,
    kv_error = 4,
    no_deployment = 5,
    unknown_domain = 6,
};

/// Phase 4 will populate these. Phase 3 keeps them all null.
pub const TapeRefs = struct {
    kv_tape_hex: ?[HASH_HEX_LEN]u8 = null,
    crypto_random_tape_hex: ?[HASH_HEX_LEN]u8 = null,
    date_tape_hex: ?[HASH_HEX_LEN]u8 = null,
    math_random_tape_hex: ?[HASH_HEX_LEN]u8 = null,
    module_tree_hex: ?[HASH_HEX_LEN]u8 = null,
};

/// One request's log entry. All `[]const u8` fields are owned by the
/// record (allocated via the LogStore's allocator). `deinit` frees them.
pub const LogRecord = struct {
    /// Combined identifier: upper 16 bits = worker_id, lower 48 = seq.
    request_id: u64,
    /// The deployment that was active when this request ran.
    /// Pulled from `TenantCode.current_deployment_id`. Replay needs
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
    /// Phase 4 tape references. All null in Phase 3.
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

pub const ListResult = struct {
    records: []LogRecord,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ListResult) void {
        for (self.records) |*r| r.deinit(self.allocator);
        self.allocator.free(self.records);
        self.records = &.{};
    }
};

pub const ListOpts = struct {
    /// Max records to return. Newest first.
    limit: u32 = 100,
};

const RECORD_VERSION: u32 = 1;

/// Bit positions in the `flags` byte used by `serializeRecord`.
/// Each bit signals presence of one optional field. 5 of the 8 bits
/// are reserved for tape refs (Phase 4).
const FLAG_KV_TAPE: u8 = 1 << 0;
const FLAG_CRYPTO_RANDOM_TAPE: u8 = 1 << 1;
const FLAG_DATE_TAPE: u8 = 1 << 2;
const FLAG_MATH_RANDOM_TAPE: u8 = 1 << 3;
const FLAG_MODULE_TREE: u8 = 1 << 4;

pub const LogStore = struct {
    allocator: std.mem.Allocator,
    /// Per-tenant log index. Stores `req/{id}` → serialized record
    /// and `meta/next_request_seq` for restart continuity.
    kv: *kv_mod.KvStore,
    /// Reserved for Phase 4 tape blob storage. Phase 3 doesn't write
    /// here, but it's wired so callers can construct a complete
    /// LogStore without adding a parameter when Phase 4 lands.
    blob: blob_mod.BlobStore,
    /// Upper 16 bits of every `request_id` minted by this LogStore.
    /// Sourced from raft node id at the worker layer; unique per node.
    worker_id: u16,
    /// Lower 48 bits of `request_id`. Persisted to `meta/next_request_seq`
    /// across restarts so log queries don't see id collisions after a
    /// process restart.
    next_request_seq: u48,
    /// In-memory batch waiting for the next flush. Each record is
    /// fully owned (its slices were allocated by `allocator` when the
    /// caller built the record).
    buffer: std.ArrayList(LogRecord),
    /// Wall-clock at the last `drainBatch` call. Used by `shouldFlush`
    /// for the time-based threshold.
    last_flush_ns: i64,

    flush_threshold_records: u32 = 256,
    flush_threshold_bytes: u32 = 64 * 1024,
    flush_interval_ns: i64 = 1 * std.time.ns_per_s,

    /// Open or initialize a LogStore on top of an already-open KvStore
    /// + BlobStore. The store reads `meta/next_request_seq` if present
    /// so request_ids don't collide after a restart.
    pub fn init(
        allocator: std.mem.Allocator,
        kv: *kv_mod.KvStore,
        blob: blob_mod.BlobStore,
        worker_id: u16,
    ) Error!LogStore {
        var self: LogStore = .{
            .allocator = allocator,
            .kv = kv,
            .blob = blob,
            .worker_id = worker_id,
            .next_request_seq = 0,
            .buffer = .empty,
            .last_flush_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
        };
        self.next_request_seq = self.loadNextSeq() catch 0;
        return self;
    }

    pub fn deinit(self: *LogStore) void {
        for (self.buffer.items) |*r| r.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    /// Mint a new request_id for the next request. Combines worker_id
    /// (upper 16) with the monotonic local seq (lower 48). Persists
    /// the seq to `meta/next_request_seq` on every call so a restart
    /// doesn't reuse ids.
    pub fn nextRequestId(self: *LogStore) Error!u64 {
        const seq = self.next_request_seq;
        self.next_request_seq +%= 1;
        self.persistNextSeq() catch return Error.Kv;
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
    ///   - serialized buffer bytes >= flush_threshold_bytes (estimated)
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

    /// Serialize the buffer into a single batch payload, clear the
    /// buffer, and return owned bytes. Caller frees with
    /// `allocator.free`. Returns null if the buffer is empty.
    /// `last_flush_ns` is updated unconditionally so the time-based
    /// threshold doesn't fire repeatedly on a quiet tenant.
    pub fn drainBatch(self: *LogStore, allocator: std.mem.Allocator) Error!?[]u8 {
        self.last_flush_ns = @as(i64, @intCast(std.time.nanoTimestamp()));
        if (self.buffer.items.len == 0) return null;

        const out = serializeBatch(allocator, self.buffer.items) catch return Error.OutOfMemory;
        // Free the records' owned slices now that they're encoded.
        for (self.buffer.items) |*r| r.deinit(self.allocator);
        self.buffer.clearRetainingCapacity();
        return out;
    }

    /// Decode a batch payload (produced by `drainBatch` somewhere in
    /// the cluster — possibly this node, possibly another) and write
    /// each record to the local KV index. Idempotent on the
    /// `req/{id}` keys: re-applying a batch overwrites with identical
    /// bytes.
    pub fn applyBatch(self: *LogStore, batch_bytes: []const u8) Error!void {
        const records = try parseBatch(self.allocator, batch_bytes);
        defer {
            for (records) |*r| r.deinit(self.allocator);
            self.allocator.free(records);
        }

        // Wrap the whole batch in ONE SQLite transaction. Without this,
        // every record paid an individual `BEGIN`/`COMMIT` pair — at
        // ~20k req/s that was ~80 flushes/sec × 256 commits each =
        // ~20k WAL appends/sec, dominating CPU in walIndexAppend /
        // walChecksumBytes. One batch → one commit → one WAL append.
        self.kv.begin() catch return Error.Kv;
        errdefer self.kv.rollback() catch {};
        for (records) |*r| try self.writeOneInTxn(r);
        self.kv.commit() catch return Error.Kv;
    }

    /// Build the storage key for a request id. The id is bitwise-
    /// inverted so that ascending `kv.range` iteration over `req/`
    /// walks newest-first naturally — giving us `list()` without a
    /// secondary index. `get()` inverts once more before looking up.
    fn reqKey(buf: *[4 + 16]u8, request_id: u64) []u8 {
        return std.fmt.bufPrint(buf, "req/{x:0>16}", .{~request_id}) catch unreachable;
    }

    /// Single-record lookup by request_id. Returns null if not found.
    /// Caller must `deinit` the returned record.
    pub fn get(self: *LogStore, request_id: u64) Error!?LogRecord {
        var key_buf: [4 + 16]u8 = undefined;
        const key = reqKey(&key_buf, request_id);
        const bytes = self.kv.get(key) catch |err| switch (err) {
            error.NotFound => return null,
            else => return Error.Kv,
        };
        defer self.allocator.free(bytes);
        return try parseRecord(self.allocator, bytes);
    }

    /// List recent records (newest first). Because the primary key is
    /// inverted (`req/{~id}`), ascending iteration returns newest
    /// first — no secondary index needed. Caller must deinit.
    pub fn list(self: *LogStore, opts: ListOpts) Error!ListResult {
        var range = self.kv.range("req/", "req0", opts.limit) catch
            return Error.Kv;
        defer range.deinit();

        var out = std.ArrayList(LogRecord).empty;
        errdefer {
            for (out.items) |*r| r.deinit(self.allocator);
            out.deinit(self.allocator);
        }

        for (range.entries) |entry| {
            const rec = parseRecord(self.allocator, entry.value) catch continue;
            out.append(self.allocator, rec) catch return Error.OutOfMemory;
        }

        const slice = out.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
        return .{ .records = slice, .allocator = self.allocator };
    }

    // ── Internals ─────────────────────────────────────────────────────

    /// Write one `req/{~id}` row. Single INSERT — no secondary index.
    /// Caller holds the SQLite txn (`applyBatch` opens one per batch).
    fn writeOne(self: *LogStore, record: *const LogRecord) Error!void {
        self.kv.begin() catch return Error.Kv;
        errdefer self.kv.rollback() catch {};
        try self.writeOneInTxn(record);
        self.kv.commit() catch return Error.Kv;
    }

    fn writeOneInTxn(self: *LogStore, record: *const LogRecord) Error!void {
        const bytes = serializeRecord(self.allocator, record) catch return Error.OutOfMemory;
        defer self.allocator.free(bytes);

        var key_buf: [4 + 16]u8 = undefined;
        const key = reqKey(&key_buf, record.request_id);
        self.kv.put(key, bytes) catch return Error.Kv;
    }

    fn loadNextSeq(self: *LogStore) Error!u48 {
        const bytes = self.kv.get("meta/next_request_seq") catch |err| switch (err) {
            error.NotFound => return 0,
            else => return Error.Kv,
        };
        defer self.allocator.free(bytes);
        return std.fmt.parseInt(u48, bytes, 16) catch 0;
    }

    fn persistNextSeq(self: *LogStore) !void {
        var buf: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{x:0>12}", .{self.next_request_seq}) catch unreachable;
        self.kv.put("meta/next_request_seq", s) catch return Error.Kv;
    }
};

// ── Encoding ───────────────────────────────────────────────────────────
//
// Record layout (binary, little-endian):
//   [u32 version=1][u64 request_id][u64 deployment_id]
//   [i64 received_ns][i64 duration_ns][u16 status][u8 outcome]
//   [u16 method_len][method][u16 path_len][path][u16 host_len][host]
//   [u32 console_len][console][u32 exception_len][exception]
//   [u8 flags][optional 64-byte tape hex blocks per set flag]
//
// Batch layout:
//   [u32 record_count][u32 total_payload_len]
//   [per record: [u32 record_len][record bytes]]

fn estimateRecordBytes(r: *const LogRecord) usize {
    var n: usize = 4 + 8 + 8 + 8 + 8 + 2 + 1; // header fixed
    n += 2 + r.method.len;
    n += 2 + r.path.len;
    n += 2 + r.host.len;
    n += 4 + r.console.len;
    n += 4 + r.exception.len;
    n += 1; // flags
    if (r.tape_refs.kv_tape_hex != null) n += HASH_HEX_LEN;
    if (r.tape_refs.crypto_random_tape_hex != null) n += HASH_HEX_LEN;
    if (r.tape_refs.date_tape_hex != null) n += HASH_HEX_LEN;
    if (r.tape_refs.math_random_tape_hex != null) n += HASH_HEX_LEN;
    if (r.tape_refs.module_tree_hex != null) n += HASH_HEX_LEN;
    return n;
}

fn serializeRecord(allocator: std.mem.Allocator, r: *const LogRecord) ![]u8 {
    const total = estimateRecordBytes(r);
    const out = try allocator.alloc(u8, total);
    var i: usize = 0;

    std.mem.writeInt(u32, out[i..][0..4], RECORD_VERSION, .little);
    i += 4;
    std.mem.writeInt(u64, out[i..][0..8], r.request_id, .little);
    i += 8;
    std.mem.writeInt(u64, out[i..][0..8], r.deployment_id, .little);
    i += 8;
    std.mem.writeInt(i64, out[i..][0..8], r.received_ns, .little);
    i += 8;
    std.mem.writeInt(i64, out[i..][0..8], r.duration_ns, .little);
    i += 8;
    std.mem.writeInt(u16, out[i..][0..2], r.status, .little);
    i += 2;
    out[i] = @intFromEnum(r.outcome);
    i += 1;

    i += writeLenPrefixed(out[i..], r.method, 2);
    i += writeLenPrefixed(out[i..], r.path, 2);
    i += writeLenPrefixed(out[i..], r.host, 2);
    i += writeLenPrefixed(out[i..], r.console, 4);
    i += writeLenPrefixed(out[i..], r.exception, 4);

    var flags: u8 = 0;
    if (r.tape_refs.kv_tape_hex != null) flags |= FLAG_KV_TAPE;
    if (r.tape_refs.crypto_random_tape_hex != null) flags |= FLAG_CRYPTO_RANDOM_TAPE;
    if (r.tape_refs.date_tape_hex != null) flags |= FLAG_DATE_TAPE;
    if (r.tape_refs.math_random_tape_hex != null) flags |= FLAG_MATH_RANDOM_TAPE;
    if (r.tape_refs.module_tree_hex != null) flags |= FLAG_MODULE_TREE;
    out[i] = flags;
    i += 1;

    inline for (.{
        .{ FLAG_KV_TAPE, r.tape_refs.kv_tape_hex },
        .{ FLAG_CRYPTO_RANDOM_TAPE, r.tape_refs.crypto_random_tape_hex },
        .{ FLAG_DATE_TAPE, r.tape_refs.date_tape_hex },
        .{ FLAG_MATH_RANDOM_TAPE, r.tape_refs.math_random_tape_hex },
        .{ FLAG_MODULE_TREE, r.tape_refs.module_tree_hex },
    }) |pair| {
        if (pair[1]) |hex| {
            @memcpy(out[i..][0..HASH_HEX_LEN], &hex);
            i += HASH_HEX_LEN;
        }
    }

    return out;
}

fn writeLenPrefixed(dst: []u8, src: []const u8, comptime prefix_len: comptime_int) usize {
    if (prefix_len == 2) {
        std.mem.writeInt(u16, dst[0..2], @intCast(src.len), .little);
        @memcpy(dst[2..][0..src.len], src);
        return 2 + src.len;
    } else if (prefix_len == 4) {
        std.mem.writeInt(u32, dst[0..4], @intCast(src.len), .little);
        @memcpy(dst[4..][0..src.len], src);
        return 4 + src.len;
    } else @compileError("unsupported prefix_len");
}

fn parseRecord(allocator: std.mem.Allocator, bytes: []const u8) Error!LogRecord {
    var r = ParseReader{ .data = bytes, .pos = 0 };
    const version = try r.u32le();
    if (version != RECORD_VERSION) return Error.InvalidVersion;
    const request_id = try r.u64le();
    const deployment_id = try r.u64le();
    const received_ns = try r.i64le();
    const duration_ns = try r.i64le();
    const status = try r.u16le();
    const outcome_byte = try r.byte();
    const outcome = std.meta.intToEnum(Outcome, outcome_byte) catch return Error.InvalidOutcome;

    const method = try r.bytes16(allocator);
    errdefer allocator.free(method);
    const path = try r.bytes16(allocator);
    errdefer allocator.free(path);
    const host = try r.bytes16(allocator);
    errdefer allocator.free(host);
    const console = try r.bytes32(allocator);
    errdefer allocator.free(console);
    const exception = try r.bytes32(allocator);
    errdefer allocator.free(exception);

    const flags = try r.byte();
    var tape_refs: TapeRefs = .{};
    if (flags & FLAG_KV_TAPE != 0) tape_refs.kv_tape_hex = try r.hexBlock();
    if (flags & FLAG_CRYPTO_RANDOM_TAPE != 0) tape_refs.crypto_random_tape_hex = try r.hexBlock();
    if (flags & FLAG_DATE_TAPE != 0) tape_refs.date_tape_hex = try r.hexBlock();
    if (flags & FLAG_MATH_RANDOM_TAPE != 0) tape_refs.math_random_tape_hex = try r.hexBlock();
    if (flags & FLAG_MODULE_TREE != 0) tape_refs.module_tree_hex = try r.hexBlock();

    return .{
        .request_id = request_id,
        .deployment_id = deployment_id,
        .received_ns = received_ns,
        .duration_ns = duration_ns,
        .method = method,
        .path = path,
        .host = host,
        .status = status,
        .outcome = outcome,
        .console = console,
        .exception = exception,
        .tape_refs = tape_refs,
    };
}

const ParseReader = struct {
    data: []const u8,
    pos: usize,

    fn remaining(self: *const ParseReader) usize {
        return self.data.len - self.pos;
    }

    fn byte(self: *ParseReader) Error!u8 {
        if (self.remaining() < 1) return Error.Truncated;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    fn u16le(self: *ParseReader) Error!u16 {
        if (self.remaining() < 2) return Error.Truncated;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    fn u32le(self: *ParseReader) Error!u32 {
        if (self.remaining() < 4) return Error.Truncated;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    fn u64le(self: *ParseReader) Error!u64 {
        if (self.remaining() < 8) return Error.Truncated;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    fn i64le(self: *ParseReader) Error!i64 {
        return @bitCast(try self.u64le());
    }

    fn bytes16(self: *ParseReader, allocator: std.mem.Allocator) Error![]u8 {
        const n = try self.u16le();
        if (self.remaining() < n) return Error.Truncated;
        const out = allocator.alloc(u8, n) catch return Error.OutOfMemory;
        @memcpy(out, self.data[self.pos..][0..n]);
        self.pos += n;
        return out;
    }

    fn bytes32(self: *ParseReader, allocator: std.mem.Allocator) Error![]u8 {
        const n = try self.u32le();
        if (self.remaining() < n) return Error.Truncated;
        const out = allocator.alloc(u8, n) catch return Error.OutOfMemory;
        @memcpy(out, self.data[self.pos..][0..n]);
        self.pos += n;
        return out;
    }

    fn hexBlock(self: *ParseReader) Error![HASH_HEX_LEN]u8 {
        if (self.remaining() < HASH_HEX_LEN) return Error.Truncated;
        var out: [HASH_HEX_LEN]u8 = undefined;
        @memcpy(&out, self.data[self.pos..][0..HASH_HEX_LEN]);
        self.pos += HASH_HEX_LEN;
        return out;
    }
};

fn serializeBatch(allocator: std.mem.Allocator, records: []const LogRecord) ![]u8 {
    // Pre-encode each record so we know the sizes.
    var encoded = std.ArrayList([]u8).empty;
    defer {
        for (encoded.items) |b| allocator.free(b);
        encoded.deinit(allocator);
    }
    for (records) |*r| {
        const b = try serializeRecord(allocator, r);
        try encoded.append(allocator, b);
    }

    var total: usize = 4 + 4; // count + total_len header
    for (encoded.items) |b| total += 4 + b.len;

    const out = try allocator.alloc(u8, total);
    var i: usize = 0;
    std.mem.writeInt(u32, out[i..][0..4], @intCast(records.len), .little);
    i += 4;
    std.mem.writeInt(u32, out[i..][0..4], @intCast(total), .little);
    i += 4;
    for (encoded.items) |b| {
        std.mem.writeInt(u32, out[i..][0..4], @intCast(b.len), .little);
        i += 4;
        @memcpy(out[i..][0..b.len], b);
        i += b.len;
    }
    return out;
}

fn parseBatch(allocator: std.mem.Allocator, bytes: []const u8) Error![]LogRecord {
    var r = ParseReader{ .data = bytes, .pos = 0 };
    const count = try r.u32le();
    _ = try r.u32le(); // total_len, currently unused; kept for forward compat

    const out = allocator.alloc(LogRecord, count) catch return Error.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |*rec| rec.deinit(allocator);
        allocator.free(out);
    }

    while (filled < count) : (filled += 1) {
        const rec_len = try r.u32le();
        if (r.remaining() < rec_len) return Error.Truncated;
        const slice = r.data[r.pos..][0..rec_len];
        r.pos += rec_len;
        out[filled] = try parseRecord(allocator, slice);
    }
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const fs_backend = blob_mod.fs;

const TestFixture = struct {
    allocator: std.mem.Allocator,
    tmp_dir: []u8,
    kv: *kv_mod.KvStore,
    blob_store: fs_backend.FilesystemBlobStore,
    log: LogStore,

    fn init(allocator: std.mem.Allocator) !TestFixture {
        const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-log-test-{x}", .{seed});
        errdefer allocator.free(tmp_dir);
        std.fs.cwd().deleteTree(tmp_dir) catch {};
        try std.fs.cwd().makePath(tmp_dir);

        const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/log.db", .{tmp_dir}, 0);
        defer allocator.free(db_path);
        const kv = try kv_mod.KvStore.open(allocator, db_path);
        errdefer kv.close();

        const blob_dir = try std.fmt.allocPrint(allocator, "{s}/log-blobs", .{tmp_dir});
        defer allocator.free(blob_dir);
        var bs = try fs_backend.FilesystemBlobStore.open(allocator, blob_dir);
        errdefer bs.deinit();

        const log = try LogStore.init(allocator, kv, bs.blobStore(), 7);
        return .{
            .allocator = allocator,
            .tmp_dir = tmp_dir,
            .kv = kv,
            .blob_store = bs,
            .log = log,
        };
    }

    fn deinit(self: *TestFixture) void {
        self.log.deinit();
        self.blob_store.deinit();
        self.kv.close();
        std.fs.cwd().deleteTree(self.tmp_dir) catch {};
        self.allocator.free(self.tmp_dir);
    }
};

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

test "serialize + parse single record round-trip" {
    const a = testing.allocator;
    var rec = try buildRecord(a, 0x1234567890abcdef, "GET", "/foo", 200, .ok, "hello\n");
    defer rec.deinit(a);

    const bytes = try serializeRecord(a, &rec);
    defer a.free(bytes);

    var parsed = try parseRecord(a, bytes);
    defer parsed.deinit(a);

    try testing.expectEqual(rec.request_id, parsed.request_id);
    try testing.expectEqual(rec.deployment_id, parsed.deployment_id);
    try testing.expectEqual(rec.received_ns, parsed.received_ns);
    try testing.expectEqual(rec.duration_ns, parsed.duration_ns);
    try testing.expectEqual(rec.status, parsed.status);
    try testing.expectEqual(rec.outcome, parsed.outcome);
    try testing.expectEqualStrings(rec.method, parsed.method);
    try testing.expectEqualStrings(rec.path, parsed.path);
    try testing.expectEqualStrings(rec.host, parsed.host);
    try testing.expectEqualStrings(rec.console, parsed.console);
}

test "tape_refs default null round-trip" {
    const a = testing.allocator;
    var rec = try buildRecord(a, 1, "POST", "/x", 200, .ok, "");
    defer rec.deinit(a);

    const bytes = try serializeRecord(a, &rec);
    defer a.free(bytes);
    var parsed = try parseRecord(a, bytes);
    defer parsed.deinit(a);

    try testing.expect(parsed.tape_refs.kv_tape_hex == null);
    try testing.expect(parsed.tape_refs.crypto_random_tape_hex == null);
    try testing.expect(parsed.tape_refs.date_tape_hex == null);
    try testing.expect(parsed.tape_refs.math_random_tape_hex == null);
    try testing.expect(parsed.tape_refs.module_tree_hex == null);
}

test "tape_refs partial set round-trip" {
    const a = testing.allocator;
    var rec = try buildRecord(a, 2, "GET", "/", 200, .ok, "");
    defer rec.deinit(a);
    rec.tape_refs.kv_tape_hex = [_]u8{'a'} ** HASH_HEX_LEN;
    rec.tape_refs.module_tree_hex = [_]u8{'b'} ** HASH_HEX_LEN;

    const bytes = try serializeRecord(a, &rec);
    defer a.free(bytes);
    var parsed = try parseRecord(a, bytes);
    defer parsed.deinit(a);

    try testing.expect(parsed.tape_refs.kv_tape_hex != null);
    try testing.expectEqualSlices(u8, &([_]u8{'a'} ** HASH_HEX_LEN), &parsed.tape_refs.kv_tape_hex.?);
    try testing.expect(parsed.tape_refs.crypto_random_tape_hex == null);
    try testing.expect(parsed.tape_refs.module_tree_hex != null);
}

test "batch serialize + parse round-trip" {
    const a = testing.allocator;
    var records = [_]LogRecord{
        try buildRecord(a, 1, "GET", "/a", 200, .ok, ""),
        try buildRecord(a, 2, "POST", "/b", 503, .fault, "boom\n"),
        try buildRecord(a, 3, "DELETE", "/c", 404, .no_deployment, ""),
    };
    defer for (&records) |*r| r.deinit(a);

    const bytes = try serializeBatch(a, &records);
    defer a.free(bytes);

    const parsed = try parseBatch(a, bytes);
    defer {
        for (parsed) |*r| r.deinit(a);
        a.free(parsed);
    }

    try testing.expectEqual(@as(usize, 3), parsed.len);
    try testing.expectEqual(records[0].request_id, parsed[0].request_id);
    try testing.expectEqual(records[1].outcome, parsed[1].outcome);
    try testing.expectEqualStrings(records[2].path, parsed[2].path);
}

test "parseBatch rejects truncated input" {
    const a = testing.allocator;
    try testing.expectError(Error.Truncated, parseBatch(a, &[_]u8{}));
    // claim 3 records but stop after the header
    try testing.expectError(
        Error.Truncated,
        parseBatch(a, &[_]u8{ 3, 0, 0, 0, 0, 0, 0, 0 }),
    );
}

test "LogStore append + drainBatch + applyBatch round-trip via local kv" {
    const a = testing.allocator;
    var fx = try TestFixture.init(a);
    defer fx.deinit();

    const id1 = try fx.log.nextRequestId();
    try fx.log.append(try buildRecord(a, id1, "GET", "/one", 200, .ok, "a\n"));
    const id2 = try fx.log.nextRequestId();
    try fx.log.append(try buildRecord(a, id2, "POST", "/two", 201, .ok, "b\n"));

    const batch = (try fx.log.drainBatch(a)).?;
    defer a.free(batch);
    try testing.expectEqual(@as(usize, 0), fx.log.buffer.items.len);

    try fx.log.applyBatch(batch);

    var got1 = (try fx.log.get(id1)).?;
    defer got1.deinit(a);
    try testing.expectEqualStrings("/one", got1.path);

    var got2 = (try fx.log.get(id2)).?;
    defer got2.deinit(a);
    try testing.expectEqualStrings("/two", got2.path);
}

test "LogStore.list returns records newest first" {
    const a = testing.allocator;
    var fx = try TestFixture.init(a);
    defer fx.deinit();

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const id = try fx.log.nextRequestId();
        var path_buf: [16]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/p{d}", .{i});
        try fx.log.append(try buildRecord(a, id, "GET", path, 200, .ok, ""));
    }
    const batch = (try fx.log.drainBatch(a)).?;
    defer a.free(batch);
    try fx.log.applyBatch(batch);

    var result = try fx.log.list(.{ .limit = 10 });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 5), result.records.len);
    // Newest first: /p4 then /p3 ... /p0
    try testing.expectEqualStrings("/p4", result.records[0].path);
    try testing.expectEqualStrings("/p0", result.records[4].path);
}

test "shouldFlush honors record-count threshold" {
    const a = testing.allocator;
    var fx = try TestFixture.init(a);
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
    var fx = try TestFixture.init(a);
    defer fx.deinit();
    fx.log.flush_threshold_records = 1000; // disable count path
    fx.log.flush_threshold_bytes = std.math.maxInt(u32);
    fx.log.flush_interval_ns = 1_000_000; // 1 ms
    fx.log.last_flush_ns = 0;

    try fx.log.append(try buildRecord(a, 1, "GET", "/", 200, .ok, ""));
    try testing.expect(!fx.log.shouldFlush(500_000)); // 0.5 ms
    try testing.expect(fx.log.shouldFlush(1_500_000)); // 1.5 ms
}

test "next_request_seq persists across LogStore reopen" {
    const a = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(a, "/tmp/rove-log-persist-{x}", .{seed});
    defer a.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/log.db", .{tmp_dir}, 0);
    defer a.free(db_path);
    const blob_dir = try std.fmt.allocPrint(a, "{s}/log-blobs", .{tmp_dir});
    defer a.free(blob_dir);

    {
        const kv = try kv_mod.KvStore.open(a, db_path);
        defer kv.close();
        var bs = try fs_backend.FilesystemBlobStore.open(a, blob_dir);
        defer bs.deinit();
        var log = try LogStore.init(a, kv, bs.blobStore(), 0);
        defer log.deinit();
        _ = try log.nextRequestId(); // 0
        _ = try log.nextRequestId(); // 1
        _ = try log.nextRequestId(); // 2
    }
    {
        const kv = try kv_mod.KvStore.open(a, db_path);
        defer kv.close();
        var bs = try fs_backend.FilesystemBlobStore.open(a, blob_dir);
        defer bs.deinit();
        var log = try LogStore.init(a, kv, bs.blobStore(), 0);
        defer log.deinit();
        const next = try log.nextRequestId();
        // The persisted seq was 3 (minted 3 ids: 0, 1, 2) so the next
        // should be id 3 = (worker_id 0 << 48) | 3.
        try testing.expectEqual(@as(u64, 3), next);
    }
}

test "worker_id occupies the upper 16 bits of request_id" {
    const a = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(a, "/tmp/rove-log-wid-{x}", .{seed});
    defer a.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/log.db", .{tmp_dir}, 0);
    defer a.free(db_path);
    const blob_dir = try std.fmt.allocPrint(a, "{s}/log-blobs", .{tmp_dir});
    defer a.free(blob_dir);

    const kv = try kv_mod.KvStore.open(a, db_path);
    defer kv.close();
    var bs = try fs_backend.FilesystemBlobStore.open(a, blob_dir);
    defer bs.deinit();
    var log = try LogStore.init(a, kv, bs.blobStore(), 0xCAFE);
    defer log.deinit();

    const id = try log.nextRequestId();
    try testing.expectEqual(@as(u64, 0xCAFE), id >> 48);
    try testing.expectEqual(@as(u64, 0), id & 0xFFFFFFFFFFFF);
}
