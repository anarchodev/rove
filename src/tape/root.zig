//! rove-tape — deterministic replay capture for rove-js handlers.
//!
//! ## Why
//!
//! The whole point of rove-js's "magic" feature is that every
//! non-deterministic operation a handler performs — kv reads, kv
//! writes, `Date.now`, `Math.random`, `crypto.getRandomValues`,
//! `crypto.randomUUID`, module resolution — gets recorded during the
//! original request. Later, `rove-js-ctl replay <request_id>` can
//! re-run the exact same handler bytecode with the exact same inputs
//! and end up at the exact same response. That's what lets us build a
//! time-traveling debugger: stepping through a captured request with
//! full breakpoints, mutation history, and divergence detection.
//!
//! ## Channels
//!
//! shift-js split non-determinism into several independent tapes so
//! replay could diff each channel separately and surface which source
//! of non-determinism drifted. We keep that split:
//!
//! - `.kv`            — every `kv.get` / `kv.set` / `kv.delete`
//! - `.date`          — every `Date.now` call + `new Date()` with no args
//! - `.math_random`   — every `Math.random` call
//! - `.crypto_random` — `crypto.getRandomValues` + `crypto.randomUUID`
//! - `.module`        — module resolution tree (what deployment id / path
//!                      resolved to which bytecode hash)
//!
//! Each channel is its own `Tape` value — a linear sequence of
//! `Entry`s — and each tape serializes to its own blob. On flush, the
//! worker computes a SHA-256 over the serialized bytes and stores the
//! `(hash → blob)` pair in the tenant's log-blobs; the hash then goes
//! onto the `LogRecord` (see `rove-log`'s `TapeRefs`).
//!
//! On replay, the log-cli fetches each referenced blob, parses it,
//! installs it via `ReplaySource`, and runs the handler — the
//! instrumented globals read from the tape instead of calling live
//! sources.
//!
//! ## Determinism contract
//!
//! The ORDER of calls inside a given channel must be deterministic
//! under replay. Handlers run single-threaded on a single JS context
//! with no `await`/microtask interference (MVP is synchronous handlers
//! only), so a correctly-instrumented global call sequence is
//! deterministic by construction. If we ever grow async handlers we'll
//! need an explicit ordering token in each entry — leaving a `seq`
//! field on each entry now so that's forward-compatible.
//!
//! ## Wire format
//!
//! Per-tape:
//!
//! ```
//! [u32 magic = 0x52544150 'RTAP']
//! [u16 version = 1]
//! [u16 channel (EntryTag)]
//! [u32 entry_count]
//! [for each entry: [u32 len][entry bytes]]
//! ```
//!
//! Per-entry bytes depend on `channel`. See `Entry` for the union.

const std = @import("std");
const bodies_mod = @import("rove-bodies");

pub const MAGIC: u32 = 0x52544150; // 'R' 'T' 'A' 'P'
pub const VERSION: u16 = 1;

/// Magic + version for the whole-Readset wire format used by
/// `Readset.serialize` (`docs/readset-replication-plan.md` Phase 3).
/// Distinct from per-tape `MAGIC` so a misrouted bytes/payload trips
/// the wrong-magic check at the decoder.
pub const READSET_MAGIC: u32 = 0x52524541; // 'R' 'R' 'E' 'A'
pub const READSET_VERSION: u16 = 1;
pub const READSET_CHANNEL_COUNT: usize = 7;

pub const Channel = enum(u16) {
    kv = 0,
    date = 1,
    math_random = 2,
    crypto_random = 3,
    module = 4,
    /// `docs/readset-replication-plan.md` Phase 2c-2. One entry per
    /// `http.fetch` chunk activation; each entry records the
    /// `BodyRef` naming the bytes in the per-tenant readset-blob
    /// (`{tenant}/readset-blobs/{batch_id}`). Replay resolves the
    /// bytes via `BlobStore.getRange` rather than reading them
    /// inline from the log blob.
    fetch_responses = 5,
    /// `docs/readset-replication-plan.md` Phase 2d. Zero or one entry
    /// per inbound dispatch. Captures the request body's `BodyRef`
    /// (the bytes streamed into the per-tenant readset-blob) so
    /// replay can resolve `request.body` via `BlobStore.getRange`
    /// instead of the inline `request_body_bytes` capture.
    /// Zero entries when the request had no body.
    trigger_payload = 6,
};

/// Outcome of a kv operation as captured on the tape. `NotFound` is
/// common enough to be a first-class variant rather than an error
/// payload so replay can produce it directly without reconstructing a
/// Zig error value.
pub const KvOutcome = enum(u8) {
    ok = 0,
    not_found = 1,
    /// The live call raised an error that wasn't NotFound (e.g. SQLite
    /// I/O error). We record it so replay sees the same failure — the
    /// handler's error-handling path is itself under test.
    err = 2,
};

pub const KvOp = enum(u8) {
    get = 0,
    set = 1,
    delete = 2,
    /// `kv.prefix(prefix, cursor, limit) → [...]`. The captured entry
    /// holds the inputs (prefix, cursor, limit) AND the full result
    /// list — replay needs all of them: the inputs to validate the
    /// handler called with the same arguments, the results to feed
    /// back to the handler. Replay-determinism failures here usually
    /// indicate handler-source drift since capture, not platform bugs.
    prefix = 3,
};

/// One row returned by a `kv.prefix(...)` scan, captured inside a
/// `KvEntry` with `op = .prefix`.
pub const KvPair = struct {
    key: []const u8,
    value: []const u8,
};

/// Single captured event. Owned storage: the `Tape` that holds this
/// entry also owns any byte slices it references.
pub const Entry = union(Channel) {
    kv: KvEntry,
    date: DateEntry,
    math_random: MathRandomEntry,
    crypto_random: CryptoRandomEntry,
    module: ModuleEntry,
    fetch_responses: FetchResponseEntry,
    trigger_payload: TriggerPayloadEntry,

    pub const KvEntry = struct {
        op: KvOp,
        outcome: KvOutcome,
        /// For `.get`/`.set`/`.delete`: the key passed to the handler.
        /// For `.prefix`: the prefix string scanned.
        key: []const u8,
        /// For `.get .ok` this is the value read; for `.set` it is the
        /// value written; for `.delete` + `.not_found` + `.err` it is
        /// empty. For `.prefix`: empty (the input cursor is in `cursor`,
        /// the rows are in `results`).
        value: []const u8,
        /// `.prefix` only: the input cursor (empty for the first page).
        cursor: []const u8 = "",
        /// `.prefix` only: the requested page-size cap.
        limit: u32 = 0,
        /// `.prefix` only: the rows the scan returned. Up to `limit`
        /// entries; empty when the scan found nothing AND the outcome
        /// was `.ok`. Owning storage matches the rest of the entry —
        /// each pair's `key`/`value` lives in the tape allocator (write
        /// side) or the parsed-tape backing buffer (read side).
        results: []const KvPair = &.{},
    };

    pub const DateEntry = struct {
        /// Milliseconds since epoch — what `Date.now()` returned.
        ms_epoch: i64,
    };

    pub const MathRandomEntry = struct {
        /// The 64-bit float `Math.random` produced. Stored as raw bits
        /// to avoid any float-formatting ambiguity on the wire.
        bits: u64,
    };

    pub const CryptoRandomEntry = struct {
        /// Raw random bytes that were handed to the handler.
        bytes: []const u8,
    };

    pub const ModuleEntry = struct {
        /// Requested path as the handler wrote it.
        specifier: []const u8,
        /// SHA-256 of the bytecode that resolved for this specifier,
        /// hex-encoded. 64 chars.
        source_hash_hex: []const u8,
    };

    /// One `http.fetch` chunk activation. Captures enough of the
    /// upstream event for replay to re-trigger the handler with
    /// the same payload. Two modes, discriminated by
    /// `body_ref.batch_id`:
    ///
    /// - `body_ref.batch_id != bodies_mod.NO_BATCH`: chunk bytes
    ///   live in the per-tenant readset-blob; `inline_bytes` is
    ///   empty. Used for chunks over the inline threshold.
    /// - `body_ref.batch_id == bodies_mod.NO_BATCH` AND
    ///   `inline_bytes.len > 0`: bytes ride inline in the entry
    ///   (Phase 4-fetch-inline). Used for chunks under the
    ///   inline threshold — handler runs immediately, raft
    ///   entry fsync IS the durability substrate, same shape as
    ///   the inbound `trigger_payload` inline path.
    /// - `body_ref.batch_id == bodies_mod.NO_BATCH` AND
    ///   `inline_bytes.len == 0`: a terminal-only event with no
    ///   body bytes (transport errors, stream-mode FINs, etc.).
    ///
    /// Headers ride inline only on the seq=0 entry (libcurl
    /// delivers them alongside the first chunk); subsequent
    /// entries have `headers == ""`. `final` flags the terminal
    /// entry; status / terminal_ok / body_truncated are
    /// meaningful only when `final == true`.
    pub const FetchResponseEntry = struct {
        /// Correlates every chunk activation of one fetch call.
        /// Surfaces as `request.activation.fetch_id` on the
        /// re-fired activation during replay.
        fetch_id: []const u8,
        /// 0-based chunk sequence within this fetch.
        seq: u32,
        /// Cumulative byte count before this chunk
        /// (surfaces as `request.activation.byte_offset`).
        byte_offset: u64,
        /// Pointer to the chunk payload. See the doc comment
        /// above for the discriminator semantics.
        body_ref: bodies_mod.BodyRef,
        /// True iff this is the last activation for the fetch.
        final: bool,
        /// Upstream HTTP status. Meaningful only when `final`;
        /// 0 otherwise. Stored on every entry so the wire format
        /// stays fixed-width per non-string field.
        terminal_status: u16,
        /// Transport-success flag (final only). Meaningful only
        /// when `final`. `ok=true, status=503` means "transport
        /// worked, server said no"; `ok=false` means libcurl-level
        /// failure (DNS / TLS / timeout / cancel).
        terminal_ok: bool,
        /// True iff upstream sent more bytes than the configured
        /// cap and the runtime truncated the rest. Meaningful only
        /// when `final`.
        body_truncated: bool,
        /// Parsed upstream response headers as a JSON object
        /// (`{"name":"value",...}`). Non-empty on seq=0 only;
        /// later chunks reference the seq=0 entry for headers.
        headers: []const u8,
        /// Chunk payload when the inline fast path is selected
        /// (`body_ref.batch_id == bodies_mod.NO_BATCH`,
        /// `body_ref.len == inline_bytes.len`). Empty for the
        /// BodyRef-to-S3 path and for terminal-only events.
        inline_bytes: []const u8,
    };

    /// One inbound request's body — either by-reference into the
    /// per-tenant readset-blob OR carried inline in the entry
    /// itself (`docs/readset-replication-plan.md` Phase 4 inline
    /// small-body path). The two modes are discriminated by
    /// `body_ref.batch_id`:
    ///
    /// - `body_ref.batch_id != bodies_mod.NO_BATCH`: bytes live
    ///   at `(tenant)/readset-blobs/{batch_id}` at the given
    ///   offset+len; `inline_bytes` is empty. Used for bodies
    ///   over the inline threshold (16 KB today); the dispatch
    ///   loop parks the request until the buffer's batch is
    ///   durable, then re-dispatches.
    /// - `body_ref.batch_id == bodies_mod.NO_BATCH`: bytes ride
    ///   inline as `inline_bytes`. `body_ref.offset == 0`,
    ///   `body_ref.len == inline_bytes.len`. The handler runs
    ///   immediately — no buffer append, no park, no S3 RTT —
    ///   because the raft entry itself IS the durability
    ///   substrate (every replica sees the bytes when the
    ///   entry replicates).
    ///
    /// `headers` is reserved for future inbound-header capture
    /// (replay currently re-reads method/path/host/wire headers
    /// from the log record's dedicated fields); kept on the
    /// entry so the wire layout matches the §4.1 readset shape
    /// and a later slice can populate it without a version bump.
    pub const TriggerPayloadEntry = struct {
        body_ref: bodies_mod.BodyRef,
        headers: []const u8,
        inline_bytes: []const u8,
    };
};

/// Append-only in-memory tape for a single channel. The worker
/// allocates one per channel per in-flight request; on dispatch exit
/// the tapes are serialized and either discarded (Phase 3 baseline,
/// tape_refs all null) or uploaded to the tenant's log-blob store and
/// referenced by hash on the LogRecord.
pub const Tape = struct {
    allocator: std.mem.Allocator,
    channel: Channel,
    entries: std.ArrayList(Entry),
    /// Running total of heap bytes the tape has allocated for owned
    /// slices inside entries. Lets the worker enforce a per-request
    /// tape budget so a pathological handler can't OOM the process by
    /// doing `kv.get(hugekey)` in a loop.
    owned_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, channel: Channel) Tape {
        return .{
            .allocator = allocator,
            .channel = channel,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Tape) void {
        for (self.entries.items) |*e| freeEntry(self.allocator, e);
        self.entries.deinit(self.allocator);
    }

    /// Append a kv event. Dups `key` + `value` into tape-owned storage
    /// so the caller's buffers can go away. NOT for `.prefix` —
    /// callers use `appendKvPrefix` for that, since prefix carries a
    /// list of result rows the flat (key, value) shape can't express.
    pub fn appendKv(
        self: *Tape,
        op: KvOp,
        key: []const u8,
        value: []const u8,
        outcome: KvOutcome,
    ) !void {
        std.debug.assert(self.channel == .kv);
        std.debug.assert(op != .prefix);
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const val_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val_copy);
        try self.entries.append(self.allocator, .{ .kv = .{
            .op = op,
            .key = key_copy,
            .value = val_copy,
            .outcome = outcome,
        } });
        self.owned_bytes += key_copy.len + val_copy.len;
    }

    /// Append a `kv.prefix(prefix, cursor, limit)` scan capture. Dups
    /// every input string and every result pair's bytes into tape
    /// storage. `results` may be empty (no rows matched).
    pub fn appendKvPrefix(
        self: *Tape,
        prefix: []const u8,
        cursor: []const u8,
        limit: u32,
        results: []const KvPair,
        outcome: KvOutcome,
    ) !void {
        std.debug.assert(self.channel == .kv);

        const prefix_copy = try self.allocator.dupe(u8, prefix);
        errdefer self.allocator.free(prefix_copy);
        const cursor_copy = try self.allocator.dupe(u8, cursor);
        errdefer self.allocator.free(cursor_copy);

        const results_slab = try self.allocator.alloc(KvPair, results.len);
        // Tracks how many slab entries already have allocated bytes,
        // so we can roll back cleanly on a mid-loop dup failure.
        var initialized: usize = 0;
        errdefer {
            for (results_slab[0..initialized]) |p| {
                self.allocator.free(p.key);
                self.allocator.free(p.value);
            }
            self.allocator.free(results_slab);
        }
        var owned_added: usize = prefix_copy.len + cursor_copy.len;
        for (results, 0..) |p, i| {
            const k = try self.allocator.dupe(u8, p.key);
            const v = self.allocator.dupe(u8, p.value) catch |err| {
                self.allocator.free(k);
                return err;
            };
            results_slab[i] = .{ .key = k, .value = v };
            initialized = i + 1;
            owned_added += k.len + v.len;
        }

        try self.entries.append(self.allocator, .{ .kv = .{
            .op = .prefix,
            .outcome = outcome,
            .key = prefix_copy,
            .value = "",
            .cursor = cursor_copy,
            .limit = limit,
            .results = results_slab,
        } });
        self.owned_bytes += owned_added;
    }

    pub fn appendDate(self: *Tape, ms_epoch: i64) !void {
        std.debug.assert(self.channel == .date);
        try self.entries.append(self.allocator, .{ .date = .{ .ms_epoch = ms_epoch } });
    }

    pub fn appendMathRandom(self: *Tape, value: f64) !void {
        std.debug.assert(self.channel == .math_random);
        try self.entries.append(self.allocator, .{
            .math_random = .{ .bits = @bitCast(value) },
        });
    }

    pub fn appendCryptoRandom(self: *Tape, bytes: []const u8) !void {
        std.debug.assert(self.channel == .crypto_random);
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.entries.append(self.allocator, .{
            .crypto_random = .{ .bytes = copy },
        });
        self.owned_bytes += copy.len;
    }

    pub fn appendModule(
        self: *Tape,
        specifier: []const u8,
        source_hash_hex: []const u8,
    ) !void {
        std.debug.assert(self.channel == .module);
        std.debug.assert(source_hash_hex.len == 64);
        const spec_copy = try self.allocator.dupe(u8, specifier);
        errdefer self.allocator.free(spec_copy);
        const hash_copy = try self.allocator.dupe(u8, source_hash_hex);
        errdefer self.allocator.free(hash_copy);
        try self.entries.append(self.allocator, .{ .module = .{
            .specifier = spec_copy,
            .source_hash_hex = hash_copy,
        } });
        self.owned_bytes += spec_copy.len + hash_copy.len;
    }

    /// Append one `http.fetch` chunk activation. Dups every
    /// caller-owned byte slice into tape storage so the caller's
    /// buffers can go away. `headers` should be the parsed JSON
    /// (non-empty on seq=0 only); pass `""` for non-header
    /// chunks. `inline_bytes` is the chunk payload when the inline
    /// fast path is selected (`body_ref.batch_id == NO_BATCH`,
    /// `body_ref.len == inline_bytes.len`); pass `""` for the
    /// BodyRef-to-S3 path and terminal-only events.
    pub fn appendFetchResponse(
        self: *Tape,
        fetch_id: []const u8,
        seq: u32,
        byte_offset: u64,
        body_ref: bodies_mod.BodyRef,
        final: bool,
        terminal_status: u16,
        terminal_ok: bool,
        body_truncated: bool,
        headers: []const u8,
        inline_bytes: []const u8,
    ) !void {
        std.debug.assert(self.channel == .fetch_responses);
        const fid_copy = try self.allocator.dupe(u8, fetch_id);
        errdefer self.allocator.free(fid_copy);
        const headers_copy = try self.allocator.dupe(u8, headers);
        errdefer self.allocator.free(headers_copy);
        const inline_copy = try self.allocator.dupe(u8, inline_bytes);
        errdefer self.allocator.free(inline_copy);
        try self.entries.append(self.allocator, .{ .fetch_responses = .{
            .fetch_id = fid_copy,
            .seq = seq,
            .byte_offset = byte_offset,
            .body_ref = body_ref,
            .final = final,
            .terminal_status = terminal_status,
            .terminal_ok = terminal_ok,
            .body_truncated = body_truncated,
            .headers = headers_copy,
            .inline_bytes = inline_copy,
        } });
        self.owned_bytes += fid_copy.len + headers_copy.len + inline_copy.len;
    }

    /// Append one inbound trigger payload entry. The channel
    /// carries at most one entry per request; callers append
    /// nothing when the request had no body. `headers` is
    /// reserved for future capture — pass `""` for now.
    ///
    /// `inline_bytes` carries the request body inline when the
    /// caller chose the small-body inline path (`body_ref.batch_id
    /// == bodies_mod.NO_BATCH`); empty for the by-reference path
    /// (`body_ref.batch_id != NO_BATCH`, bytes live in
    /// `(tenant)/readset-blobs/{batch_id}`). Both slices are
    /// dup'd into tape storage.
    pub fn appendTriggerPayload(
        self: *Tape,
        body_ref: bodies_mod.BodyRef,
        headers: []const u8,
        inline_bytes: []const u8,
    ) !void {
        std.debug.assert(self.channel == .trigger_payload);
        const headers_copy = try self.allocator.dupe(u8, headers);
        errdefer self.allocator.free(headers_copy);
        const inline_copy = try self.allocator.dupe(u8, inline_bytes);
        errdefer self.allocator.free(inline_copy);
        try self.entries.append(self.allocator, .{ .trigger_payload = .{
            .body_ref = body_ref,
            .headers = headers_copy,
            .inline_bytes = inline_copy,
        } });
        self.owned_bytes += headers_copy.len + inline_copy.len;
    }

    /// Serialize to a fresh heap buffer the caller owns. Empty tapes
    /// still produce a valid (header-only) serialization — replay
    /// must be able to distinguish "channel was empty" from "no tape
    /// at all" and a header-only blob does that cheaply.
    pub fn serialize(self: *const Tape, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        var header: [12]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], MAGIC, .big);
        std.mem.writeInt(u16, header[4..6], VERSION, .big);
        std.mem.writeInt(u16, header[6..8], @intFromEnum(self.channel), .big);
        std.mem.writeInt(u32, header[8..12], @intCast(self.entries.items.len), .big);
        try buf.appendSlice(allocator, &header);

        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(allocator);

        for (self.entries.items) |*e| {
            scratch.clearRetainingCapacity();
            try encodeEntry(allocator, &scratch, e);
            var len_be: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_be, @intCast(scratch.items.len), .big);
            try buf.appendSlice(allocator, &len_be);
            try buf.appendSlice(allocator, scratch.items);
        }

        return buf.toOwnedSlice(allocator);
    }

    /// SHA-256 of the serialized form, hex-encoded (64 chars, lowercase).
    /// Called by the worker when it stores the tape blob — the hex
    /// goes onto the LogRecord's TapeRefs.
    pub fn hashHex(self: *const Tape, allocator: std.mem.Allocator) ![64]u8 {
        const bytes = try self.serialize(allocator);
        defer allocator.free(bytes);
        return hashHexBytes(bytes);
    }
};

/// Per-request captured readset — the set of non-deterministic
/// inputs the handler observed, channeled by source. Structural
/// holder of the per-channel `Tape`s plus the scalar inputs
/// captured once at dispatch entry (`timestamp_ns`, `seed`); the
/// dispatcher hands the worker one `Readset` per dispatch and the
/// bindings append to the relevant channel.
///
/// Channel shape mirrors the WASM replay engine's `Module.tapes`
/// 1:1 (`docs/replay-wasm-plan.md` §4) — same five channels, same
/// names. No translation layer between capture and replay.
///
/// `docs/readset-replication-plan.md` Phase 1 lifted this from
/// `src/js/worker_log.zig:RequestTapes`; this revision adds the
/// `timestamp_ns` / `seed` scalars from §4.1 so the readset is the
/// single home for every per-request non-deterministic input the
/// raft entry will eventually carry. Later phases will extend with
/// `fetch_responses` + `trigger_payload`.
pub const Readset = struct {
    /// Wall-clock nanosecond timestamp captured once at dispatch
    /// entry — the canonical "when this request was received."
    /// Used to seed `Math.random`/`crypto.*` PRNG (via `.seed`,
    /// see below) and recorded so replay sees the same start
    /// instant. Stored alongside the per-call `.date` tape, which
    /// captures each `Date.now()` separately.
    timestamp_ns: i64,
    /// PRNG seed used to initialize the dispatcher's
    /// `std.Random.DefaultPrng` for `Math.random` and
    /// `crypto.getRandomValues` / `crypto.randomUUID`. Production
    /// callers derive it from `timestamp_ns`; tests pass a fixed
    /// value for determinism. Belt-and-suspenders for "the tape
    /// was dropped but the seed survived" — replay primarily reads
    /// the per-call `.math_random` / `.crypto_random` tapes.
    seed: u64,
    kv: Tape,
    date: Tape,
    math_random: Tape,
    crypto_random: Tape,
    module: Tape,
    /// `docs/readset-replication-plan.md` Phase 2c-2: one entry per
    /// `http.fetch` chunk activation. Captures the `BodyRef` naming
    /// the bytes in the per-tenant readset-blob; replay resolves
    /// the bytes via `BlobStore.getRange`.
    fetch_responses: Tape,
    /// `docs/readset-replication-plan.md` Phase 2d: zero-or-one
    /// entry for the inbound request body's `BodyRef`. Replay
    /// resolves `request.body` via `BlobStore.getRange` instead of
    /// the inline `request_body_bytes` capture.
    trigger_payload: Tape,

    pub fn init(
        allocator: std.mem.Allocator,
        timestamp_ns: i64,
        seed: u64,
    ) Readset {
        return .{
            .timestamp_ns = timestamp_ns,
            .seed = seed,
            .kv = Tape.init(allocator, .kv),
            .date = Tape.init(allocator, .date),
            .math_random = Tape.init(allocator, .math_random),
            .crypto_random = Tape.init(allocator, .crypto_random),
            .module = Tape.init(allocator, .module),
            .fetch_responses = Tape.init(allocator, .fetch_responses),
            .trigger_payload = Tape.init(allocator, .trigger_payload),
        };
    }

    pub fn deinit(self: *Readset) void {
        self.kv.deinit();
        self.date.deinit();
        self.math_random.deinit();
        self.crypto_random.deinit();
        self.module.deinit();
        self.fetch_responses.deinit();
        self.trigger_payload.deinit();
    }

    /// Serialize the whole readset to a single blob suitable for the
    /// raft entry's readset section
    /// (`docs/readset-replication-plan.md` Phase 3). Wire format:
    ///
    /// ```
    /// [u32  magic = READSET_MAGIC ('RREA')]
    /// [u16  version = READSET_VERSION]
    /// [i64  timestamp_ns  big-endian]
    /// [u64  seed          big-endian]
    /// for each of the 7 channels in fixed order:
    ///   [u32 blob_len BE][blob_bytes]   // blob is a full Tape.serialize()
    /// ```
    ///
    /// Channels are emitted in the order matching the `Channel` enum
    /// (kv=0, date=1, math_random=2, crypto_random=3, module=4,
    /// fetch_responses=5, trigger_payload=6) — same order
    /// `parseReadset` consumes them. An empty channel still emits a
    /// 12-byte header-only blob so the fixed layout stays alignable
    /// on the wire.
    pub fn serialize(self: *const Readset, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        var header: [4 + 2 + 8 + 8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], READSET_MAGIC, .big);
        std.mem.writeInt(u16, header[4..6], READSET_VERSION, .big);
        std.mem.writeInt(i64, header[6..14], self.timestamp_ns, .big);
        std.mem.writeInt(u64, header[14..22], self.seed, .big);
        try buf.appendSlice(allocator, &header);

        const channels = [_]*const Tape{
            &self.kv,
            &self.date,
            &self.math_random,
            &self.crypto_random,
            &self.module,
            &self.fetch_responses,
            &self.trigger_payload,
        };
        for (channels) |t| {
            const blob = try t.serialize(allocator);
            defer allocator.free(blob);
            var len_be: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_be, @intCast(blob.len), .big);
            try buf.appendSlice(allocator, &len_be);
            try buf.appendSlice(allocator, blob);
        }

        return buf.toOwnedSlice(allocator);
    }
};

/// Decoded readset bytes — header scalars plus per-channel blob
/// slices that alias the input buffer. Lifetime: valid as long as
/// the input buffer to `parseReadset` is live. The blob slices can
/// be fed to `parse(allocator, blob)` to materialize ParsedTape
/// values (which copy the bytes into their own backing buffer).
///
/// `readset-replication-plan.md` Phase 3: Phase 3 only needs to
/// VALIDATE the readset shape (Phase 5 is where followers actually
/// use the channels), so the apply path consumes this for shape
/// validation today and a future slice will materialize tapes for
/// follower-side tape upload.
pub const ParsedReadset = struct {
    timestamp_ns: i64,
    seed: u64,
    /// Borrowed slices into the input bytes, one per channel in
    /// fixed order (kv, date, math_random, crypto_random, module,
    /// fetch_responses, trigger_payload).
    blobs: [READSET_CHANNEL_COUNT][]const u8,
};

pub fn parseReadset(bytes: []const u8) ParseError!ParsedReadset {
    if (bytes.len < 4 + 2 + 8 + 8) return ParseError.Truncated;
    const magic = std.mem.readInt(u32, bytes[0..4], .big);
    if (magic != READSET_MAGIC) return ParseError.BadMagic;
    const version = std.mem.readInt(u16, bytes[4..6], .big);
    if (version != READSET_VERSION) return ParseError.UnsupportedVersion;
    const timestamp_ns = std.mem.readInt(i64, bytes[6..14], .big);
    const seed = std.mem.readInt(u64, bytes[14..22], .big);

    var blobs: [READSET_CHANNEL_COUNT][]const u8 = undefined;
    var cur: usize = 22;
    var i: usize = 0;
    while (i < READSET_CHANNEL_COUNT) : (i += 1) {
        if (cur + 4 > bytes.len) return ParseError.Truncated;
        const blob_len = std.mem.readInt(u32, bytes[cur..][0..4], .big);
        cur += 4;
        if (cur + blob_len > bytes.len) return ParseError.Truncated;
        blobs[i] = bytes[cur .. cur + blob_len];
        cur += blob_len;
    }
    if (cur != bytes.len) return ParseError.Truncated;
    return .{
        .timestamp_ns = timestamp_ns,
        .seed = seed,
        .blobs = blobs,
    };
}

/// List of `Readset.serialize()` blobs, wire-encoded for the type-0
/// envelope's `rs_bytes` section
/// (`docs/readset-replication-plan.md` Phase 3d follow-up — multi-
/// request batch aggregation). A batched H2 dispatch can run several
/// successful handlers under one raft entry; each handler owns a
/// distinct readset, and tape upload on follower-promotion needs to
/// hydrate one tape per request, not just the first.
///
/// Wire format:
/// ```
/// (empty bytes)                                — count = 0 sentinel
/// or
/// [u32 count BE]
///   for each i in 0..count:
///     [u32 blob_len BE]
///     [blob_bytes]                             — `Readset.serialize` output
/// ```
///
/// Why an empty-bytes sentinel for count=0: non-handler producers
/// (ACME, secondary inner envelopes of a batched propose,
/// root_writeset) pass `rs_bytes = ""` already, and the apply path
/// gates "has readset?" on `len > 0`. Keeping that contract means
/// no churn in those callers.
pub const ParsedReadsetList = struct {
    /// Borrowed slices into the input bytes; each is a
    /// `Readset.serialize` blob ready to feed back to `parseReadset`.
    blobs: []const []const u8,

    pub fn deinit(self: *ParsedReadsetList, allocator: std.mem.Allocator) void {
        if (self.blobs.len > 0) allocator.free(self.blobs);
        self.* = undefined;
    }
};

/// Wrap a sequence of pre-serialized `Readset.serialize()` blobs as a
/// type-0 envelope's `rs_bytes` payload. Caller owns each input blob;
/// they are not freed. Empty input returns an empty slice (the
/// "no readsets" sentinel) without allocating.
pub fn encodeReadsetList(
    allocator: std.mem.Allocator,
    blobs: []const []const u8,
) ![]u8 {
    if (blobs.len == 0) return &.{};
    var total: usize = 4; // count header
    for (blobs) |b| total += 4 + b.len;
    const out = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, out[0..4], @intCast(blobs.len), .big);
    var cur: usize = 4;
    for (blobs) |b| {
        std.mem.writeInt(u32, out[cur..][0..4], @intCast(b.len), .big);
        cur += 4;
        @memcpy(out[cur..][0..b.len], b);
        cur += b.len;
    }
    return out;
}

/// Parse a `rs_bytes` payload as a list of readset blobs. Empty
/// input returns an empty list (caller still calls `deinit`, which
/// is a no-op for the empty case). Allocates a `[]const []const u8`
/// slice; each entry borrows into `bytes`, which must outlive the
/// returned value.
pub fn parseReadsetList(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) (ParseError || std.mem.Allocator.Error)!ParsedReadsetList {
    if (bytes.len == 0) return .{ .blobs = &.{} };
    if (bytes.len < 4) return ParseError.Truncated;
    const count = std.mem.readInt(u32, bytes[0..4], .big);
    if (count == 0) {
        // Non-empty bytes with count=0 is malformed — the "no readsets"
        // sentinel is bytes.len == 0, not a 4-byte zero count.
        return ParseError.Truncated;
    }
    var cur: usize = 4;
    const blobs = try allocator.alloc([]const u8, count);
    errdefer allocator.free(blobs);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (cur + 4 > bytes.len) return ParseError.Truncated;
        const blob_len = std.mem.readInt(u32, bytes[cur..][0..4], .big);
        cur += 4;
        if (cur + blob_len > bytes.len) return ParseError.Truncated;
        blobs[i] = bytes[cur .. cur + blob_len];
        cur += blob_len;
    }
    if (cur != bytes.len) return ParseError.Truncated;
    return .{ .blobs = blobs };
}

pub fn hashHexBytes(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var out: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

/// Parsed tape — opaque wrapper around an owned buffer + entries slice.
/// Produced by `parse`. Used by replay drivers; not appended to.
pub const ParsedTape = struct {
    allocator: std.mem.Allocator,
    channel: Channel,
    entries: []Entry,
    /// The original bytes. Every `[]const u8` inside `entries` points
    /// into this buffer, so it must outlive the parsed tape.
    backing: []u8,
    /// One slab per `kv.prefix` entry in the tape — the per-result
    /// `KvPair` array (each pair's bytes still point into `backing`,
    /// just the slab itself needs heap storage). Empty for tapes
    /// without prefix entries, which is the common case.
    aux: std.ArrayList([]KvPair),

    pub fn deinit(self: *ParsedTape) void {
        for (self.aux.items) |slab| self.allocator.free(slab);
        self.aux.deinit(self.allocator);
        self.allocator.free(self.entries);
        self.allocator.free(self.backing);
        self.* = undefined;
    }
};

pub const ParseError = error{
    BadMagic,
    UnsupportedVersion,
    UnknownChannel,
    Truncated,
    ChannelMismatch,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!ParsedTape {
    if (bytes.len < 12) return ParseError.Truncated;

    // Own the backing buffer so slices into it are stable.
    const backing = allocator.dupe(u8, bytes) catch return ParseError.OutOfMemory;
    errdefer allocator.free(backing);

    const magic = std.mem.readInt(u32, backing[0..4], .big);
    if (magic != MAGIC) return ParseError.BadMagic;
    const version = std.mem.readInt(u16, backing[4..6], .big);
    if (version != VERSION) return ParseError.UnsupportedVersion;
    const chan_raw = std.mem.readInt(u16, backing[6..8], .big);
    const channel = std.meta.intToEnum(Channel, chan_raw) catch
        return ParseError.UnknownChannel;
    const count = std.mem.readInt(u32, backing[8..12], .big);

    const entries = allocator.alloc(Entry, count) catch return ParseError.OutOfMemory;
    errdefer allocator.free(entries);

    var aux: std.ArrayList([]KvPair) = .empty;
    errdefer {
        for (aux.items) |slab| allocator.free(slab);
        aux.deinit(allocator);
    }

    var cur: usize = 12;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (cur + 4 > backing.len) return ParseError.Truncated;
        const elen = std.mem.readInt(u32, backing[cur..][0..4], .big);
        cur += 4;
        if (cur + elen > backing.len) return ParseError.Truncated;
        const slice = backing[cur .. cur + elen];
        cur += elen;
        entries[i] = try decodeEntry(allocator, &aux, channel, slice);
    }

    return .{
        .allocator = allocator,
        .channel = channel,
        .entries = entries,
        .backing = backing,
        .aux = aux,
    };
}

// ── Internal encode/decode ────────────────────────────────────────────

fn freeEntry(allocator: std.mem.Allocator, e: *Entry) void {
    switch (e.*) {
        .kv => |*k| {
            allocator.free(k.key);
            allocator.free(k.value);
            if (k.op == .prefix) {
                allocator.free(k.cursor);
                for (k.results) |p| {
                    allocator.free(p.key);
                    allocator.free(p.value);
                }
                allocator.free(k.results);
            }
        },
        .date, .math_random => {},
        .crypto_random => |*c| allocator.free(c.bytes),
        .module => |*m| {
            allocator.free(m.specifier);
            allocator.free(m.source_hash_hex);
        },
        .fetch_responses => |*f| {
            allocator.free(f.fetch_id);
            allocator.free(f.headers);
            allocator.free(f.inline_bytes);
        },
        .trigger_payload => |*t| {
            allocator.free(t.headers);
            allocator.free(t.inline_bytes);
        },
    }
}

fn appendLenPrefixed(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    slice: []const u8,
) !void {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(slice.len), .big);
    try buf.appendSlice(allocator, &len_be);
    try buf.appendSlice(allocator, slice);
}

fn readLenPrefixed(bytes: []const u8, cur: *usize) ParseError![]const u8 {
    if (cur.* + 4 > bytes.len) return ParseError.Truncated;
    const n = std.mem.readInt(u32, bytes[cur.*..][0..4], .big);
    cur.* += 4;
    if (cur.* + n > bytes.len) return ParseError.Truncated;
    const out = bytes[cur.* .. cur.* + n];
    cur.* += n;
    return out;
}

fn encodeEntry(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    e: *const Entry,
) !void {
    switch (e.*) {
        .kv => |k| {
            try buf.append(allocator, @intFromEnum(k.op));
            try buf.append(allocator, @intFromEnum(k.outcome));
            try appendLenPrefixed(allocator, buf, k.key);
            if (k.op == .prefix) {
                try appendLenPrefixed(allocator, buf, k.cursor);
                var limit_be: [4]u8 = undefined;
                std.mem.writeInt(u32, &limit_be, k.limit, .big);
                try buf.appendSlice(allocator, &limit_be);
                var count_be: [4]u8 = undefined;
                std.mem.writeInt(u32, &count_be, @intCast(k.results.len), .big);
                try buf.appendSlice(allocator, &count_be);
                for (k.results) |p| {
                    try appendLenPrefixed(allocator, buf, p.key);
                    try appendLenPrefixed(allocator, buf, p.value);
                }
            } else {
                try appendLenPrefixed(allocator, buf, k.value);
            }
        },
        .date => |d| {
            var be: [8]u8 = undefined;
            std.mem.writeInt(i64, &be, d.ms_epoch, .big);
            try buf.appendSlice(allocator, &be);
        },
        .math_random => |m| {
            var be: [8]u8 = undefined;
            std.mem.writeInt(u64, &be, m.bits, .big);
            try buf.appendSlice(allocator, &be);
        },
        .crypto_random => |c| {
            try appendLenPrefixed(allocator, buf, c.bytes);
        },
        .module => |m| {
            try appendLenPrefixed(allocator, buf, m.specifier);
            try appendLenPrefixed(allocator, buf, m.source_hash_hex);
        },
        .fetch_responses => |f| {
            try appendLenPrefixed(allocator, buf, f.fetch_id);
            var seq_be: [4]u8 = undefined;
            std.mem.writeInt(u32, &seq_be, f.seq, .big);
            try buf.appendSlice(allocator, &seq_be);
            var bo_be: [8]u8 = undefined;
            std.mem.writeInt(u64, &bo_be, f.byte_offset, .big);
            try buf.appendSlice(allocator, &bo_be);
            // BodyRef: batch_id (u64), offset (u64), len (u32).
            var br_bi: [8]u8 = undefined;
            std.mem.writeInt(u64, &br_bi, f.body_ref.batch_id, .big);
            try buf.appendSlice(allocator, &br_bi);
            var br_off: [8]u8 = undefined;
            std.mem.writeInt(u64, &br_off, f.body_ref.offset, .big);
            try buf.appendSlice(allocator, &br_off);
            var br_len: [4]u8 = undefined;
            std.mem.writeInt(u32, &br_len, f.body_ref.len, .big);
            try buf.appendSlice(allocator, &br_len);
            // Flags + terminal fields. Packed as 1-byte bools so the
            // wire layout stays bit-stable and the decoder can skip
            // ahead to `headers` deterministically.
            try buf.append(allocator, @intFromBool(f.final));
            var st_be: [2]u8 = undefined;
            std.mem.writeInt(u16, &st_be, f.terminal_status, .big);
            try buf.appendSlice(allocator, &st_be);
            try buf.append(allocator, @intFromBool(f.terminal_ok));
            try buf.append(allocator, @intFromBool(f.body_truncated));
            try appendLenPrefixed(allocator, buf, f.headers);
            try appendLenPrefixed(allocator, buf, f.inline_bytes);
        },
        .trigger_payload => |t| {
            // BodyRef: batch_id (u64), offset (u64), len (u32).
            var br_bi: [8]u8 = undefined;
            std.mem.writeInt(u64, &br_bi, t.body_ref.batch_id, .big);
            try buf.appendSlice(allocator, &br_bi);
            var br_off: [8]u8 = undefined;
            std.mem.writeInt(u64, &br_off, t.body_ref.offset, .big);
            try buf.appendSlice(allocator, &br_off);
            var br_len: [4]u8 = undefined;
            std.mem.writeInt(u32, &br_len, t.body_ref.len, .big);
            try buf.appendSlice(allocator, &br_len);
            try appendLenPrefixed(allocator, buf, t.headers);
            try appendLenPrefixed(allocator, buf, t.inline_bytes);
        },
    }
}

fn decodeEntry(
    allocator: std.mem.Allocator,
    aux: *std.ArrayList([]KvPair),
    channel: Channel,
    bytes: []const u8,
) ParseError!Entry {
    var cur: usize = 0;
    switch (channel) {
        .kv => {
            if (bytes.len < 2) return ParseError.Truncated;
            const op = std.meta.intToEnum(KvOp, bytes[0]) catch
                return ParseError.UnknownChannel;
            const outcome = std.meta.intToEnum(KvOutcome, bytes[1]) catch
                return ParseError.UnknownChannel;
            cur = 2;
            const key = try readLenPrefixed(bytes, &cur);
            if (op == .prefix) {
                const cursor = try readLenPrefixed(bytes, &cur);
                if (cur + 8 > bytes.len) return ParseError.Truncated;
                const limit = std.mem.readInt(u32, bytes[cur..][0..4], .big);
                cur += 4;
                const count = std.mem.readInt(u32, bytes[cur..][0..4], .big);
                cur += 4;
                const slab = allocator.alloc(KvPair, count) catch return ParseError.OutOfMemory;
                aux.append(allocator, slab) catch {
                    allocator.free(slab);
                    return ParseError.OutOfMemory;
                };
                for (slab) |*p| {
                    p.key = try readLenPrefixed(bytes, &cur);
                    p.value = try readLenPrefixed(bytes, &cur);
                }
                return .{ .kv = .{
                    .op = .prefix,
                    .outcome = outcome,
                    .key = key,
                    .value = "",
                    .cursor = cursor,
                    .limit = limit,
                    .results = slab,
                } };
            }
            const value = try readLenPrefixed(bytes, &cur);
            return .{ .kv = .{ .op = op, .outcome = outcome, .key = key, .value = value } };
        },
        .date => {
            if (bytes.len != 8) return ParseError.Truncated;
            const ms = std.mem.readInt(i64, bytes[0..8], .big);
            return .{ .date = .{ .ms_epoch = ms } };
        },
        .math_random => {
            if (bytes.len != 8) return ParseError.Truncated;
            const bits = std.mem.readInt(u64, bytes[0..8], .big);
            return .{ .math_random = .{ .bits = bits } };
        },
        .crypto_random => {
            const b = try readLenPrefixed(bytes, &cur);
            if (cur != bytes.len) return ParseError.Truncated;
            return .{ .crypto_random = .{ .bytes = b } };
        },
        .module => {
            const spec = try readLenPrefixed(bytes, &cur);
            const hash = try readLenPrefixed(bytes, &cur);
            if (cur != bytes.len) return ParseError.Truncated;
            return .{ .module = .{ .specifier = spec, .source_hash_hex = hash } };
        },
        .fetch_responses => {
            const fid = try readLenPrefixed(bytes, &cur);
            if (cur + 4 + 8 + 8 + 8 + 4 + 1 + 2 + 1 + 1 > bytes.len) {
                return ParseError.Truncated;
            }
            const seq = std.mem.readInt(u32, bytes[cur..][0..4], .big);
            cur += 4;
            const byte_offset = std.mem.readInt(u64, bytes[cur..][0..8], .big);
            cur += 8;
            const br_batch_id = std.mem.readInt(u64, bytes[cur..][0..8], .big);
            cur += 8;
            const br_offset = std.mem.readInt(u64, bytes[cur..][0..8], .big);
            cur += 8;
            const br_len = std.mem.readInt(u32, bytes[cur..][0..4], .big);
            cur += 4;
            const final = bytes[cur] != 0;
            cur += 1;
            const status = std.mem.readInt(u16, bytes[cur..][0..2], .big);
            cur += 2;
            const ok = bytes[cur] != 0;
            cur += 1;
            const trunc = bytes[cur] != 0;
            cur += 1;
            const headers = try readLenPrefixed(bytes, &cur);
            const inline_bytes = try readLenPrefixed(bytes, &cur);
            if (cur != bytes.len) return ParseError.Truncated;
            return .{ .fetch_responses = .{
                .fetch_id = fid,
                .seq = seq,
                .byte_offset = byte_offset,
                .body_ref = .{
                    .batch_id = br_batch_id,
                    .offset = br_offset,
                    .len = br_len,
                },
                .final = final,
                .terminal_status = status,
                .terminal_ok = ok,
                .body_truncated = trunc,
                .headers = headers,
                .inline_bytes = inline_bytes,
            } };
        },
        .trigger_payload => {
            if (cur + 8 + 8 + 4 > bytes.len) return ParseError.Truncated;
            const br_batch_id = std.mem.readInt(u64, bytes[cur..][0..8], .big);
            cur += 8;
            const br_offset = std.mem.readInt(u64, bytes[cur..][0..8], .big);
            cur += 8;
            const br_len = std.mem.readInt(u32, bytes[cur..][0..4], .big);
            cur += 4;
            const headers = try readLenPrefixed(bytes, &cur);
            const inline_bytes = try readLenPrefixed(bytes, &cur);
            if (cur != bytes.len) return ParseError.Truncated;
            return .{ .trigger_payload = .{
                .body_ref = .{
                    .batch_id = br_batch_id,
                    .offset = br_offset,
                    .len = br_len,
                },
                .headers = headers,
                .inline_bytes = inline_bytes,
            } };
        },
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "kv tape: roundtrip with mixed ops and outcomes" {
    var tape = Tape.init(testing.allocator, .kv);
    defer tape.deinit();

    try tape.appendKv(.get, "hits", "42", .ok);
    try tape.appendKv(.get, "missing", "", .not_found);
    try tape.appendKv(.set, "name", "rove", .ok);
    try tape.appendKv(.delete, "name", "", .ok);
    try tape.appendKv(.get, "broken", "", .err);

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(Channel.kv, parsed.channel);
    try testing.expectEqual(@as(usize, 5), parsed.entries.len);

    try testing.expectEqual(KvOp.get, parsed.entries[0].kv.op);
    try testing.expectEqualStrings("hits", parsed.entries[0].kv.key);
    try testing.expectEqualStrings("42", parsed.entries[0].kv.value);
    try testing.expectEqual(KvOutcome.ok, parsed.entries[0].kv.outcome);

    try testing.expectEqual(KvOutcome.not_found, parsed.entries[1].kv.outcome);
    try testing.expectEqual(KvOp.set, parsed.entries[2].kv.op);
    try testing.expectEqualStrings("rove", parsed.entries[2].kv.value);
    try testing.expectEqual(KvOp.delete, parsed.entries[3].kv.op);
    try testing.expectEqual(KvOutcome.err, parsed.entries[4].kv.outcome);
}

test "kv tape: prefix capture round-trips inputs and results" {
    var tape = Tape.init(testing.allocator, .kv);
    defer tape.deinit();

    // Mix prefix with simple ops so the parser proves it can read
    // both shapes from one tape and that the aux slab tracking
    // doesn't disturb other entry types.
    try tape.appendKv(.get, "score/alice", "10", .ok);
    const results = [_]KvPair{
        .{ .key = "score/alice", .value = "10" },
        .{ .key = "score/bob", .value = "7" },
        .{ .key = "score/carol", .value = "13" },
    };
    try tape.appendKvPrefix("score/", "", 100, &results, .ok);
    try tape.appendKvPrefix("missing/", "", 100, &.{}, .ok);
    try tape.appendKv(.set, "score/dan", "1", .ok);

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 4), parsed.entries.len);

    // Simple op survived.
    try testing.expectEqual(KvOp.get, parsed.entries[0].kv.op);
    try testing.expectEqualStrings("score/alice", parsed.entries[0].kv.key);
    try testing.expectEqualStrings("10", parsed.entries[0].kv.value);

    // First prefix entry.
    const p1 = parsed.entries[1].kv;
    try testing.expectEqual(KvOp.prefix, p1.op);
    try testing.expectEqualStrings("score/", p1.key);
    try testing.expectEqualStrings("", p1.cursor);
    try testing.expectEqual(@as(u32, 100), p1.limit);
    try testing.expectEqual(@as(usize, 3), p1.results.len);
    try testing.expectEqualStrings("score/alice", p1.results[0].key);
    try testing.expectEqualStrings("10", p1.results[0].value);
    try testing.expectEqualStrings("score/carol", p1.results[2].key);
    try testing.expectEqualStrings("13", p1.results[2].value);

    // Empty-result prefix.
    const p2 = parsed.entries[2].kv;
    try testing.expectEqual(KvOp.prefix, p2.op);
    try testing.expectEqualStrings("missing/", p2.key);
    try testing.expectEqual(@as(usize, 0), p2.results.len);

    // Trailing simple op survived.
    try testing.expectEqual(KvOp.set, parsed.entries[3].kv.op);
    try testing.expectEqualStrings("score/dan", parsed.entries[3].kv.key);
    try testing.expectEqualStrings("1", parsed.entries[3].kv.value);
}

test "date tape: roundtrip preserves exact ms" {
    var tape = Tape.init(testing.allocator, .date);
    defer tape.deinit();
    try tape.appendDate(1_712_345_678_901);
    try tape.appendDate(0);
    try tape.appendDate(-1);

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 1_712_345_678_901), parsed.entries[0].date.ms_epoch);
    try testing.expectEqual(@as(i64, 0), parsed.entries[1].date.ms_epoch);
    try testing.expectEqual(@as(i64, -1), parsed.entries[2].date.ms_epoch);
}

test "math_random tape: bit-exact f64 roundtrip" {
    var tape = Tape.init(testing.allocator, .math_random);
    defer tape.deinit();
    // Include a subnormal + NaN-adjacent value to prove we don't go
    // through any float formatting that might normalize them.
    try tape.appendMathRandom(0.0);
    try tape.appendMathRandom(0.123456789012345);
    try tape.appendMathRandom(std.math.floatMin(f64));

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 0.0))), parsed.entries[0].math_random.bits);
    try testing.expectEqual(
        @as(u64, @bitCast(@as(f64, 0.123456789012345))),
        parsed.entries[1].math_random.bits,
    );
    try testing.expectEqual(
        @as(u64, @bitCast(std.math.floatMin(f64))),
        parsed.entries[2].math_random.bits,
    );
}

test "crypto tape: preserves exact bytes" {
    var tape = Tape.init(testing.allocator, .crypto_random);
    defer tape.deinit();
    try tape.appendCryptoRandom(&.{ 0x00, 0xff, 0xde, 0xad, 0xbe, 0xef });
    try tape.appendCryptoRandom(&.{});

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0xff, 0xde, 0xad, 0xbe, 0xef },
        parsed.entries[0].crypto_random.bytes,
    );
    try testing.expectEqual(@as(usize, 0), parsed.entries[1].crypto_random.bytes.len);
}

test "module tape: specifier + hash roundtrip" {
    var tape = Tape.init(testing.allocator, .module);
    defer tape.deinit();
    const hash = "a" ** 64;
    try tape.appendModule("./handler.js", hash);

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqualStrings("./handler.js", parsed.entries[0].module.specifier);
    try testing.expectEqualStrings(hash, parsed.entries[0].module.source_hash_hex);
}

test "readset: serialize + parseReadset roundtrip" {
    var rs = Readset.init(testing.allocator, 1_700_000_000_000_000_000, 0xDEADBEEFCAFEBABE);
    defer rs.deinit();
    try rs.kv.appendKv(.get, "k", "v", .ok);
    try rs.date.appendDate(1_712_345_678_901);
    try rs.math_random.appendMathRandom(0.5);
    try rs.crypto_random.appendCryptoRandom(&.{ 0x01, 0x02, 0x03 });
    try rs.module.appendModule("./h.js", "a" ** 64);
    try rs.fetch_responses.appendFetchResponse(
        "fetch-1",
        0,
        0,
        .{ .batch_id = 5, .offset = 200, .len = 64 },
        true,
        200,
        true,
        false,
        "{}",
        "",
    );
    try rs.trigger_payload.appendTriggerPayload(
        .{ .batch_id = 3, .offset = 0, .len = 128 },
        "",
        "",
    );

    const bytes = try rs.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    const parsed = try parseReadset(bytes);
    try testing.expectEqual(@as(i64, 1_700_000_000_000_000_000), parsed.timestamp_ns);
    try testing.expectEqual(@as(u64, 0xDEADBEEFCAFEBABE), parsed.seed);

    // Each blob is a self-contained tape; re-parse to confirm.
    for (parsed.blobs, 0..) |blob, idx| {
        var p = try parse(testing.allocator, blob);
        defer p.deinit();
        try testing.expectEqual(@as(u16, @intCast(idx)), @intFromEnum(p.channel));
    }
}

test "readset: parseReadset rejects bad magic + bad version" {
    var bad = [_]u8{0} ** 32;
    try testing.expectError(ParseError.BadMagic, parseReadset(&bad));

    std.mem.writeInt(u32, bad[0..4], READSET_MAGIC, .big);
    std.mem.writeInt(u16, bad[4..6], 99, .big);
    try testing.expectError(ParseError.UnsupportedVersion, parseReadset(&bad));
}

test "readset: parseReadset rejects truncated input" {
    var rs = Readset.init(testing.allocator, 0, 0);
    defer rs.deinit();
    const bytes = try rs.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectError(
        ParseError.Truncated,
        parseReadset(bytes[0 .. bytes.len - 3]),
    );
}

test "readset list: empty roundtrip (sentinel)" {
    const bytes = try encodeReadsetList(testing.allocator, &.{});
    // Empty bytes are the "no readsets" sentinel — no allocation happens.
    try testing.expectEqual(@as(usize, 0), bytes.len);
    var parsed = try parseReadsetList(testing.allocator, bytes);
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), parsed.blobs.len);
}

test "readset list: single-entry roundtrip" {
    var rs = Readset.init(testing.allocator, 1234, 0xAA);
    defer rs.deinit();
    try rs.kv.appendKv(.get, "k", "v", .ok);
    const rs_bytes = try rs.serialize(testing.allocator);
    defer testing.allocator.free(rs_bytes);

    const list = try encodeReadsetList(testing.allocator, &.{rs_bytes});
    defer testing.allocator.free(list);
    // 4-byte count + 4-byte length + payload
    try testing.expectEqual(@as(usize, 8 + rs_bytes.len), list.len);

    var parsed = try parseReadsetList(testing.allocator, list);
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), parsed.blobs.len);
    try testing.expectEqualSlices(u8, rs_bytes, parsed.blobs[0]);

    // Each blob in the list is a valid Readset blob.
    const inner = try parseReadset(parsed.blobs[0]);
    try testing.expectEqual(@as(i64, 1234), inner.timestamp_ns);
    try testing.expectEqual(@as(u64, 0xAA), inner.seed);
}

test "readset list: multi-entry roundtrip" {
    var rs_a = Readset.init(testing.allocator, 1, 0x11);
    defer rs_a.deinit();
    try rs_a.kv.appendKv(.get, "a", "1", .ok);
    var rs_b = Readset.init(testing.allocator, 2, 0x22);
    defer rs_b.deinit();
    try rs_b.kv.appendKv(.get, "b", "2", .ok);
    try rs_b.date.appendDate(99);
    var rs_c = Readset.init(testing.allocator, 3, 0x33);
    defer rs_c.deinit();

    const ba = try rs_a.serialize(testing.allocator);
    defer testing.allocator.free(ba);
    const bb = try rs_b.serialize(testing.allocator);
    defer testing.allocator.free(bb);
    const bc = try rs_c.serialize(testing.allocator);
    defer testing.allocator.free(bc);

    const list = try encodeReadsetList(testing.allocator, &.{ ba, bb, bc });
    defer testing.allocator.free(list);

    var parsed = try parseReadsetList(testing.allocator, list);
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), parsed.blobs.len);
    try testing.expectEqualSlices(u8, ba, parsed.blobs[0]);
    try testing.expectEqualSlices(u8, bb, parsed.blobs[1]);
    try testing.expectEqualSlices(u8, bc, parsed.blobs[2]);

    // Independent reparse of each surfaces the right scalars + content.
    const ia = try parseReadset(parsed.blobs[0]);
    try testing.expectEqual(@as(i64, 1), ia.timestamp_ns);
    const ib = try parseReadset(parsed.blobs[1]);
    try testing.expectEqual(@as(u64, 0x22), ib.seed);
    const ic = try parseReadset(parsed.blobs[2]);
    try testing.expectEqual(@as(i64, 3), ic.timestamp_ns);
}

test "readset list: rejects 4-byte zero-count (malformed sentinel)" {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, 0, .big);
    try testing.expectError(
        ParseError.Truncated,
        parseReadsetList(testing.allocator, &bytes),
    );
}

test "readset list: rejects truncated count header" {
    const short: [3]u8 = .{ 0, 0, 1 };
    try testing.expectError(
        ParseError.Truncated,
        parseReadsetList(testing.allocator, &short),
    );
}

test "readset list: rejects truncated entry length" {
    // count = 1, but only 2 bytes of the per-entry length header follow.
    var bytes: [6]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], 1, .big);
    bytes[4] = 0;
    bytes[5] = 0;
    try testing.expectError(
        ParseError.Truncated,
        parseReadsetList(testing.allocator, &bytes),
    );
}

test "readset list: rejects truncated entry payload" {
    // count = 1, declared blob_len = 10, but only 4 bytes of payload follow.
    var bytes: [12]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], 1, .big);
    std.mem.writeInt(u32, bytes[4..8], 10, .big);
    @memset(bytes[8..], 0);
    try testing.expectError(
        ParseError.Truncated,
        parseReadsetList(testing.allocator, &bytes),
    );
}

test "readset list: rejects trailing bytes after final entry" {
    var rs = Readset.init(testing.allocator, 0, 0);
    defer rs.deinit();
    const rs_bytes = try rs.serialize(testing.allocator);
    defer testing.allocator.free(rs_bytes);
    const list = try encodeReadsetList(testing.allocator, &.{rs_bytes});
    defer testing.allocator.free(list);

    const padded = try testing.allocator.alloc(u8, list.len + 4);
    defer testing.allocator.free(padded);
    @memcpy(padded[0..list.len], list);
    @memset(padded[list.len..], 0);
    try testing.expectError(
        ParseError.Truncated,
        parseReadsetList(testing.allocator, padded),
    );
}

test "trigger_payload tape: BodyRef-only roundtrip (large body)" {
    var tape = Tape.init(testing.allocator, .trigger_payload);
    defer tape.deinit();
    try tape.appendTriggerPayload(
        .{ .batch_id = 3, .offset = 4096, .len = 1024 },
        "",
        "",
    );
    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqual(Channel.trigger_payload, parsed.channel);
    try testing.expectEqual(@as(usize, 1), parsed.entries.len);
    const t = parsed.entries[0].trigger_payload;
    try testing.expectEqual(@as(u64, 3), t.body_ref.batch_id);
    try testing.expectEqual(@as(u64, 4096), t.body_ref.offset);
    try testing.expectEqual(@as(u32, 1024), t.body_ref.len);
    try testing.expectEqualStrings("", t.headers);
    try testing.expectEqualStrings("", t.inline_bytes);
}

test "trigger_payload tape: inline small-body roundtrip" {
    var tape = Tape.init(testing.allocator, .trigger_payload);
    defer tape.deinit();
    const body = "{\"hello\":\"world\"}";
    // Inline path: sentinel batch_id, body rides as inline_bytes.
    try tape.appendTriggerPayload(
        .{ .batch_id = 0, .offset = 0, .len = @intCast(body.len) },
        "",
        body,
    );
    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();
    const t = parsed.entries[0].trigger_payload;
    try testing.expectEqual(@as(u64, 0), t.body_ref.batch_id);
    try testing.expectEqualStrings(body, t.inline_bytes);
    try testing.expectEqual(@as(u32, body.len), t.body_ref.len);
}

test "fetch_responses tape: chunk + terminal roundtrip" {
    var tape = Tape.init(testing.allocator, .fetch_responses);
    defer tape.deinit();

    // Seq-0 entry: headers populated, non-final, BodyRef path.
    try tape.appendFetchResponse(
        "fetch-abc",
        0,
        0,
        .{ .batch_id = 7, .offset = 100, .len = 256 },
        false,
        0,
        false,
        false,
        "{\"content-type\":\"application/json\"}",
        "",
    );
    // Mid-stream chunk: no headers, BodyRef path.
    try tape.appendFetchResponse(
        "fetch-abc",
        1,
        256,
        .{ .batch_id = 7, .offset = 356, .len = 128 },
        false,
        0,
        false,
        false,
        "",
        "",
    );
    // Terminal: empty body, status + ok set.
    try tape.appendFetchResponse(
        "fetch-abc",
        2,
        384,
        .{ .batch_id = 0, .offset = 0, .len = 0 },
        true,
        200,
        true,
        false,
        "",
        "",
    );

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(Channel.fetch_responses, parsed.channel);
    try testing.expectEqual(@as(usize, 3), parsed.entries.len);

    const e0 = parsed.entries[0].fetch_responses;
    try testing.expectEqualStrings("fetch-abc", e0.fetch_id);
    try testing.expectEqual(@as(u32, 0), e0.seq);
    try testing.expectEqual(@as(u64, 0), e0.byte_offset);
    try testing.expectEqual(@as(u64, 7), e0.body_ref.batch_id);
    try testing.expectEqual(@as(u64, 100), e0.body_ref.offset);
    try testing.expectEqual(@as(u32, 256), e0.body_ref.len);
    try testing.expectEqual(false, e0.final);
    try testing.expectEqualStrings("{\"content-type\":\"application/json\"}", e0.headers);

    const e1 = parsed.entries[1].fetch_responses;
    try testing.expectEqual(@as(u32, 1), e1.seq);
    try testing.expectEqual(@as(u64, 256), e1.byte_offset);
    try testing.expectEqual(@as(u32, 128), e1.body_ref.len);
    try testing.expectEqualStrings("", e1.headers);

    const e2 = parsed.entries[2].fetch_responses;
    try testing.expectEqual(true, e2.final);
    try testing.expectEqual(@as(u16, 200), e2.terminal_status);
    try testing.expectEqual(true, e2.terminal_ok);
    try testing.expectEqual(false, e2.body_truncated);
    try testing.expectEqual(@as(u32, 0), e2.body_ref.len);
}

test "fetch_responses tape: inline small-chunk roundtrip" {
    var tape = Tape.init(testing.allocator, .fetch_responses);
    defer tape.deinit();
    const chunk = "{\"ok\":true,\"data\":[1,2,3]}";
    try tape.appendFetchResponse(
        "fetch-xyz",
        0,
        0,
        .{ .batch_id = 0, .offset = 0, .len = @intCast(chunk.len) },
        true,
        200,
        true,
        false,
        "{\"content-type\":\"application/json\"}",
        chunk,
    );
    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();
    const e = parsed.entries[0].fetch_responses;
    try testing.expectEqual(@as(u64, 0), e.body_ref.batch_id); // sentinel
    try testing.expectEqual(@as(u32, chunk.len), e.body_ref.len);
    try testing.expectEqualStrings(chunk, e.inline_bytes);
    try testing.expectEqual(true, e.final);
    try testing.expectEqual(@as(u16, 200), e.terminal_status);
}

test "empty tape is a valid header-only blob" {
    var tape = Tape.init(testing.allocator, .kv);
    defer tape.deinit();
    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 12), bytes.len);

    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqual(Channel.kv, parsed.channel);
    try testing.expectEqual(@as(usize, 0), parsed.entries.len);
}

test "hash is stable for identical content" {
    var a = Tape.init(testing.allocator, .kv);
    defer a.deinit();
    var b = Tape.init(testing.allocator, .kv);
    defer b.deinit();

    try a.appendKv(.get, "k", "v", .ok);
    try b.appendKv(.get, "k", "v", .ok);

    const ha = try a.hashHex(testing.allocator);
    const hb = try b.hashHex(testing.allocator);
    try testing.expectEqualSlices(u8, &ha, &hb);

    try b.appendKv(.get, "k2", "", .not_found);
    const hc = try b.hashHex(testing.allocator);
    try testing.expect(!std.mem.eql(u8, &ha, &hc));
}

test "parse rejects bad magic" {
    var bytes: [12]u8 = undefined;
    @memset(&bytes, 0);
    try testing.expectError(ParseError.BadMagic, parse(testing.allocator, &bytes));
}

test "parse rejects wrong version" {
    var bytes: [12]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], MAGIC, .big);
    std.mem.writeInt(u16, bytes[4..6], 99, .big);
    std.mem.writeInt(u16, bytes[6..8], 0, .big);
    std.mem.writeInt(u32, bytes[8..12], 0, .big);
    try testing.expectError(ParseError.UnsupportedVersion, parse(testing.allocator, &bytes));
}

test "parse rejects truncated entries" {
    var tape = Tape.init(testing.allocator, .kv);
    defer tape.deinit();
    try tape.appendKv(.get, "k", "v", .ok);
    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectError(
        ParseError.Truncated,
        parse(testing.allocator, bytes[0 .. bytes.len - 3]),
    );
}

test "owned_bytes tracks dup'd storage" {
    var tape = Tape.init(testing.allocator, .kv);
    defer tape.deinit();
    try tape.appendKv(.set, "key1", "val1", .ok);
    try testing.expectEqual(@as(usize, 8), tape.owned_bytes);
    try tape.appendKv(.get, "x", "", .not_found);
    try testing.expectEqual(@as(usize, 9), tape.owned_bytes);
}
