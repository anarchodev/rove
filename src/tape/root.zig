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
//! - `.kv`            — every foreign `kv.get` / `kv.prefix` resolution
//!                      (§8 minimal kv read set; writes are outputs)
//! - `.module`        — module resolution tree (what deployment id / path
//!                      resolved to which bytecode hash)
//!
//! `Math.random` + `crypto.*` + `Date.now` no longer have dedicated
//! channels (`docs/primitive-gaps.md` §9 + fold-in): arenajs's per-
//! context state (`xorshift64star` PRNG + `date_now_pinned`) is
//! set once per request from `Readset.seed` + `Readset.timestamp_ns`
//! and produces the same sequence + clock values on capture and
//! replay. Two scalars in the readset header are the entire input —
//! O(1) instead of O(draws + clock-reads).
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
const log_mod = @import("rove-log");

pub const MAGIC: u32 = 0x52544150; // 'R' 'T' 'A' 'P'
/// Bumped 1 → 2 by `docs/primitive-gaps.md` §8 (minimal kv read set);
/// 2 → 3 by §9 (seed-not-draws — dropped math_random + crypto_random);
/// 3 → 4 by the §9 fold-in (dropped `.date` channel — Date.now is
/// pinned per-request via `JS_SetDateNow`, the timestamp scalar in
/// the readset header is the entire input); 4 → 5 by the read-taped
/// request surface (new `.request_reads` channel; the dead
/// `TriggerPayloadEntry.headers` reserved field removed). Pre-launch
/// — no v4 tapes need to be readable post-bump.
pub const VERSION: u16 = 5;

/// Magic + version for the whole-Readset wire format used by
/// `Readset.serialize` (`docs/readset-replication-plan.md` Phase 3).
/// Distinct from per-tape `MAGIC` so a misrouted bytes/payload trips
/// the wrong-magic check at the decoder.
pub const READSET_MAGIC: u32 = 0x52524541; // 'R' 'R' 'E' 'A'
/// Bumped 1 → 2 by `docs/readset-replication-plan.md` Phase 5a: the
/// trailing `[u32 log_header_len][log_header_bytes]` section was
/// added after the 7 channels so any node can rebuild the customer
/// LogRecord from the raft entry alone. `log_header_len == 0` is
/// the "no header" sentinel (non-handler producers, paths that
/// don't yet stamp a header). 2 → 3 by `docs/primitive-gaps.md` §9
/// (seed-not-draws): the `.math_random` and `.crypto_random`
/// channels were removed, dropping the channel count 7 → 5.
/// 3 → 4 by the §9 fold-in: the `.date` channel was removed
/// (Date.now is pinned per-request via JS_SetDateNow); count
/// drops 5 → 4. The header's `seed` + `timestamp_ns` scalars are
/// now the entire input for the random + clock sources.
/// 5 → 6 by the read-taped request surface: the `.request_reads`
/// channel was added (count 4 → 5) — the lazily-recorded inbound
/// request inputs (header names/values, body-read flag, ip reads).
/// 6 → 7 by the format-versioning freeze (`docs/plans/format-versioning-audit.md`
/// §4): a `js_engine_version: u16` scalar was added to the header
/// (after `seed`), so every replicated request records which JS engine
/// executed it. Header grows 22 → 24 bytes. This bump rides in the
/// durable raft log (type-0 envelopes carry the readset), so it forces
/// a pre-launch data-dir wipe — old v6 readsets are rejected loudly.
/// Pre-launch — hard cutover, no old raft logs to migrate. The parser
/// accepts exactly this version and rejects anything else loudly; the
/// version byte is a format guard, not a compatibility band. BodyRefs
/// resolve through the one cross-tenant pool key template
/// (`_pool/{batch_id:0>20}`). When the format changes, bump this and
/// delete the old shape in the same change — do not add a
/// min-supported fallback.
pub const READSET_VERSION: u16 = 7;
pub const READSET_CHANNEL_COUNT: usize = 5;

/// Renumbered contiguously by `docs/primitive-gaps.md` §9 +
/// fold-in: `math_random` + `crypto_random` + `date` channels are
/// removed. `Math.random` / `crypto.*` / `Date.now()` are now seeded
/// from per-request scalars (`Readset.seed` + `Readset.timestamp_ns`)
/// in the readset header. Renumbering rides the VERSION bump
/// (per-tape decoder rejects mismatched ids against the inner-blob
/// channel header).
pub const Channel = enum(u16) {
    kv = 0,
    module = 1,
    /// `docs/readset-replication-plan.md` Phase 2c-2. One entry per
    /// `http.fetch` chunk activation; each entry records the
    /// `BodyRef` naming the bytes in the cross-tenant pool blob
    /// (`_pool/{batch_id}`). Replay resolves the bytes via
    /// `BlobStore.getRange` rather than reading them inline from the
    /// log blob.
    fetch_responses = 2,
    /// `docs/readset-replication-plan.md` Phase 2d. Zero or one entry
    /// per inbound dispatch. Captures the request body's `BodyRef`
    /// (the bytes streamed into the cross-tenant pool blob) so
    /// replay can resolve `request.body` via `BlobStore.getRange`
    /// instead of the inline `request_body_bytes` capture.
    /// Zero entries when the request had no body.
    trigger_payload = 3,
    /// The lazily-recorded inbound request surface
    /// (`docs/handler-shape.md` request semantics): exactly the
    /// request inputs the handler READ, nothing else — the GDPR
    /// data-minimization channel. One `header_names` entry per
    /// activation (so `Object.keys(request.headers)` replays
    /// faithfully), one `header_value` entry per header the handler
    /// actually read (incl. the whole `cookie` header on first
    /// `request.cookies` access), a `body_read` marker when
    /// `request.body` was touched (its absence is what licenses
    /// eliding the trigger_payload body reference), and
    /// `ip_masked` / `ip_raw` for `request.ip` /
    /// `request.unmaskedIp()`. Replay reading anything NOT recorded
    /// here is a divergence error, never a silent undefined.
    request_reads = 4,
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

/// What a `request_reads` entry records. The kind byte is the wire
/// discriminator; `name`/`value` meaning depends on it (see
/// `RequestReadEntry`).
pub const RequestReadKind = enum(u8) {
    /// Once per activation, recorded eagerly at request install iff
    /// the request had wire headers. `name = ""`; `value` = JSON
    /// array of lowercase non-pseudo, non-IP-transport header names
    /// in first-occurrence order (== `Object.keys` order).
    header_names = 0,
    /// First read of one header's value (or of the whole `cookie`
    /// header via `request.cookies`). `name` = lowercase header
    /// name; `value` = what the handler saw (last-write-wins fold).
    header_value = 1,
    /// First `request.body` access. `name`/`value` empty. Presence
    /// distinguishes "body read (possibly empty)" from "body never
    /// observed → trigger_payload reference elided".
    body_read = 2,
    /// First `request.ip` access. `name = ""`; `value` = the masked
    /// client IP returned (empty value ⇒ null was returned).
    ip_masked = 3,
    /// First `request.unmaskedIp()` call — the deliberate, taped
    /// raw-IP escalation. `name = ""`; `value` = the unmasked IP
    /// returned (empty value ⇒ null was returned).
    ip_raw = 4,
};

/// Single captured event. Owned storage: the `Tape` that holds this
/// entry also owns any byte slices it references.
pub const Entry = union(Channel) {
    kv: KvEntry,
    module: ModuleEntry,
    fetch_responses: FetchResponseEntry,
    trigger_payload: TriggerPayloadEntry,
    request_reads: RequestReadEntry,

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
    /// cross-tenant pool blob OR carried inline in the entry
    /// itself (`docs/readset-replication-plan.md` Phase 4 inline
    /// small-body path). The two modes are discriminated by
    /// `body_ref.batch_id`:
    ///
    /// - `body_ref.batch_id != bodies_mod.NO_BATCH`: bytes live
    ///   at `_pool/{batch_id}` at the given
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
    /// Inbound headers are NOT here — the handler-read subset rides
    /// the `request_reads` channel (read-taping); method/path/host
    /// stay on the log record's dedicated fields. The whole entry is
    /// elided by `Readset.elideUnreadBody` when the handler never
    /// read `request.body` (storage stays — only the log-side
    /// reference is lazy).
    pub const TriggerPayloadEntry = struct {
        body_ref: bodies_mod.BodyRef,
        inline_bytes: []const u8,
    };

    /// One lazily-recorded request-surface read. See
    /// `RequestReadKind` for the per-kind `name`/`value` semantics.
    pub const RequestReadEntry = struct {
        kind: RequestReadKind,
        name: []const u8,
        value: []const u8,
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
    /// nothing when the request had no body.
    ///
    /// `inline_bytes` carries the request body inline when the
    /// caller chose the small-body inline path (`body_ref.batch_id
    /// == bodies_mod.NO_BATCH`); empty for the by-reference path
    /// (`body_ref.batch_id != NO_BATCH`, bytes live in
    /// `_pool/{batch_id}`). The slice is dup'd into tape storage.
    pub fn appendTriggerPayload(
        self: *Tape,
        body_ref: bodies_mod.BodyRef,
        inline_bytes: []const u8,
    ) !void {
        std.debug.assert(self.channel == .trigger_payload);
        const inline_copy = try self.allocator.dupe(u8, inline_bytes);
        errdefer self.allocator.free(inline_copy);
        try self.entries.append(self.allocator, .{ .trigger_payload = .{
            .body_ref = body_ref,
            .inline_bytes = inline_copy,
        } });
        self.owned_bytes += inline_copy.len;
    }

    /// Record one request-surface read, once: if an entry with the
    /// same `(kind, name)` already exists the call is a no-op (a
    /// header's value can't change mid-request, so repeat reads add
    /// no information). Linear scan — header counts are O(tens) and
    /// this only runs on the FIRST read of each distinct input
    /// anyway (the JS getters self-replace), so the scan is a
    /// belt-and-braces guard, not the hot-path dedupe.
    pub fn appendRequestReadOnce(
        self: *Tape,
        kind: RequestReadKind,
        name: []const u8,
        value: []const u8,
    ) !void {
        std.debug.assert(self.channel == .request_reads);
        for (self.entries.items) |e| {
            const r = e.request_reads;
            if (r.kind == kind and std.mem.eql(u8, r.name, name)) return;
        }
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.entries.append(self.allocator, .{ .request_reads = .{
            .kind = kind,
            .name = name_copy,
            .value = value_copy,
        } });
        self.owned_bytes += name_copy.len + value_copy.len;
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
/// 1:1 (rewind-apps repo `replay/replay-wasm-plan.md` §4) — same five
/// channels, same names. No translation layer between capture and replay.
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
    /// The `installRequest` path derives `Date.now()`'s pinned ms
    /// value from this (`@divTrunc(timestamp_ns, ns_per_ms)`).
    /// `Date.now()` and `new Date()` (no args) both return that
    /// scalar for every call inside one request (§9 fold-in).
    timestamp_ns: i64,
    /// PRNG seed for arenajs's per-context xorshift64star, set once
    /// per request via `JS_SetRandomSeed` in `installRequest`.
    /// `Math.random` + `crypto.getRandomValues` +
    /// `crypto.randomUUID` all draw from this single state, so the
    /// scalar IS the entire input for random (§9 seed-not-draws).
    /// Production callers derive it from `timestamp_ns`; tests pass
    /// a fixed value for determinism.
    seed: u64,
    /// The JS engine version (`qjs/version.zig` `JS_ENGINE_VERSION`)
    /// that executed this request — the authoritative per-request
    /// stamp the replayer reads to fetch the matching engine
    /// (`docs/plans/format-versioning-audit.md` §4). Replicated in the
    /// readset header (a peer of `seed`/`timestamp_ns`, the other
    /// per-request execution-context scalars) so a follower-rebuilt
    /// record carries the same engine the leader ran. Production
    /// callers set it from `qjs.JS_ENGINE_VERSION` at the dispatch
    /// site; 0 is the "unknown engine" default for tests / non-handler
    /// paths. One engine per binary today, so selection is a no-op
    /// until the first semantics-affecting bump (Phase 3, post-GA).
    js_engine_version: u16 = 0,
    kv: Tape,
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
    /// The lazily-recorded request-surface reads (see
    /// `Channel.request_reads`). The JS getters in
    /// `globals.installRequest` append here on first access.
    request_reads: Tape,
    /// Set by the `request.body` getter on first access. Consulted
    /// AFTER the handler ran (DispatchState is gone by then):
    /// `elideUnreadBody` + the worker's `request_body_bytes` capture
    /// gate on it. False ⇒ the body never influenced execution and
    /// the log carries no reference to it.
    body_read: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        timestamp_ns: i64,
        seed: u64,
    ) Readset {
        return .{
            .timestamp_ns = timestamp_ns,
            .seed = seed,
            .kv = Tape.init(allocator, .kv),
            .module = Tape.init(allocator, .module),
            .fetch_responses = Tape.init(allocator, .fetch_responses),
            .trigger_payload = Tape.init(allocator, .trigger_payload),
            .request_reads = Tape.init(allocator, .request_reads),
        };
    }

    pub fn deinit(self: *Readset) void {
        self.kv.deinit();
        self.module.deinit();
        self.fetch_responses.deinit();
        self.trigger_payload.deinit();
        self.request_reads.deinit();
    }

    /// Drop the body reference from the readset when the handler
    /// never read `request.body`. The body's STORAGE is untouched —
    /// large bodies were already submitted to the pool pre-dispatch
    /// (the durability gate is unconditional) — only the log-side
    /// reference is lazy: no trigger_payload entry ⇒ the LogRecord /
    /// raft entry carries nothing that points at the body bytes.
    /// Idempotent; called at the top of `captureTapes` and before
    /// every raft-entry readset serialization.
    pub fn elideUnreadBody(self: *Readset) void {
        if (self.body_read) return;
        if (self.trigger_payload.entries.items.len == 0) return;
        for (self.trigger_payload.entries.items) |*e| {
            freeEntry(self.trigger_payload.allocator, e);
        }
        self.trigger_payload.entries.clearRetainingCapacity();
        self.trigger_payload.owned_bytes = 0;
    }

    /// Serialize the whole readset to a single blob suitable for the
    /// raft entry's readset section
    /// (`docs/readset-replication-plan.md` Phase 3 + 5a). Wire format
    /// (READSET_VERSION = 7):
    ///
    /// ```
    /// [u32  magic = READSET_MAGIC ('RREA')]
    /// [u16  version = READSET_VERSION]
    /// [i64  timestamp_ns       big-endian]
    /// [u64  seed               big-endian]
    /// [u16  js_engine_version  big-endian]   // §4 format-versioning freeze
    /// for each of the 5 channels in fixed order:
    ///   [u32 blob_len BE][blob_bytes]   // blob is a full Tape.serialize()
    /// [u32 log_header_len BE][log_header_bytes]   // Phase 5a
    /// ```
    ///
    /// Channels are emitted in fixed order: kv, module,
    /// fetch_responses, trigger_payload, request_reads — the same
    /// order `parseReadset` consumes them. An empty channel still emits a
    /// 12-byte header-only blob so the fixed layout stays alignable
    /// on the wire.
    ///
    /// `log_header == null` writes a 4-byte zero length and no
    /// payload (the "no header stamped" sentinel). Pass a real
    /// `LogHeader` from the dispatch site so follower-side tape
    /// upload (Phase 5c) can reconstruct the customer LogRecord
    /// without re-executing the handler.
    pub fn serialize(
        self: *const Readset,
        allocator: std.mem.Allocator,
        log_header: ?log_mod.LogHeader,
    ) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        var header: [4 + 2 + 8 + 8 + 2]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], READSET_MAGIC, .big);
        std.mem.writeInt(u16, header[4..6], READSET_VERSION, .big);
        std.mem.writeInt(i64, header[6..14], self.timestamp_ns, .big);
        std.mem.writeInt(u64, header[14..22], self.seed, .big);
        std.mem.writeInt(u16, header[22..24], self.js_engine_version, .big);
        try buf.appendSlice(allocator, &header);

        const channels = [_]*const Tape{
            &self.kv,
            &self.module,
            &self.fetch_responses,
            &self.trigger_payload,
            &self.request_reads,
        };
        for (channels) |t| {
            const blob = try t.serialize(allocator);
            defer allocator.free(blob);
            var len_be: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_be, @intCast(blob.len), .big);
            try buf.appendSlice(allocator, &len_be);
            try buf.appendSlice(allocator, blob);
        }

        // Phase 5a — trailing LogHeader section.
        if (log_header) |lh| {
            const lh_bytes = try lh.serialize(allocator);
            defer allocator.free(lh_bytes);
            var lh_len_be: [4]u8 = undefined;
            std.mem.writeInt(u32, &lh_len_be, @intCast(lh_bytes.len), .big);
            try buf.appendSlice(allocator, &lh_len_be);
            try buf.appendSlice(allocator, lh_bytes);
        } else {
            var zero_len: [4]u8 = .{ 0, 0, 0, 0 };
            try buf.appendSlice(allocator, &zero_len);
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
    /// The JS engine version that ran the request (§4 freeze). Mirrors
    /// `Readset.js_engine_version`; 0 means unknown / pre-stamp.
    js_engine_version: u16,
    /// Borrowed slices into the input bytes, one per channel in
    /// fixed order (kv, module, fetch_responses, trigger_payload,
    /// request_reads).
    blobs: [READSET_CHANNEL_COUNT][]const u8,
    /// `docs/readset-replication-plan.md` Phase 5a — per-request
    /// LogRecord metadata. `null` when the producer didn't stamp a
    /// header (non-handler producers, paths that haven't been wired
    /// in yet). Strings inside borrow into the same input buffer the
    /// channel blobs do; lifetime is the input bytes' lifetime.
    log_header: ?log_mod.LogHeader,
};

pub fn parseReadset(bytes: []const u8) (ParseError || log_mod.LogHeaderParseError)!ParsedReadset {
    if (bytes.len < 4 + 2 + 8 + 8 + 2) return ParseError.Truncated;
    const magic = std.mem.readInt(u32, bytes[0..4], .big);
    if (magic != READSET_MAGIC) return ParseError.BadMagic;
    const version = std.mem.readInt(u16, bytes[4..6], .big);
    if (version != READSET_VERSION) return ParseError.UnsupportedVersion;
    const timestamp_ns = std.mem.readInt(i64, bytes[6..14], .big);
    const seed = std.mem.readInt(u64, bytes[14..22], .big);
    const js_engine_version = std.mem.readInt(u16, bytes[22..24], .big);

    var blobs: [READSET_CHANNEL_COUNT][]const u8 = undefined;
    var cur: usize = 24;
    var i: usize = 0;
    while (i < READSET_CHANNEL_COUNT) : (i += 1) {
        if (cur + 4 > bytes.len) return ParseError.Truncated;
        const blob_len = std.mem.readInt(u32, bytes[cur..][0..4], .big);
        cur += 4;
        if (cur + blob_len > bytes.len) return ParseError.Truncated;
        blobs[i] = bytes[cur .. cur + blob_len];
        cur += blob_len;
    }
    // Phase 5a trailing log-header section.
    if (cur + 4 > bytes.len) return ParseError.Truncated;
    const lh_len = std.mem.readInt(u32, bytes[cur..][0..4], .big);
    cur += 4;
    if (cur + lh_len > bytes.len) return ParseError.Truncated;
    const lh_slice = bytes[cur .. cur + lh_len];
    cur += lh_len;
    if (cur != bytes.len) return ParseError.Truncated;
    const lh: ?log_mod.LogHeader = if (lh_len == 0)
        null
    else
        try log_mod.parseLogHeader(lh_slice);
    return .{
        .timestamp_ns = timestamp_ns,
        .seed = seed,
        .js_engine_version = js_engine_version,
        .blobs = blobs,
        .log_header = lh,
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

/// Serialize ONE activation's readset (with `log_header` stamped in)
/// directly into a `rs_bytes` payload — i.e. `serialize` followed by
/// `encodeReadsetList(&.{blob})`, with the intermediate blob freed
/// internally. The single owner of the "wrap a lone readset as the
/// 1-item list the wire expects" step that every single-readset
/// producer (cont-resume, proposeForgetfulWrites) needs after
/// 3d-multi promoted `rs_bytes` to a list. Returns freshly-allocated
/// bytes the caller owns. On any failure the caller's convention is
/// to log + fall back to empty `rs_bytes` (best-effort replication).
pub fn encodeSingleReadset(
    allocator: std.mem.Allocator,
    readset: *const Readset,
    log_header: ?log_mod.LogHeader,
) ![]u8 {
    const blob = try readset.serialize(allocator, log_header);
    defer allocator.free(blob);
    return encodeReadsetList(allocator, &.{blob});
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
            allocator.free(t.inline_bytes);
        },
        .request_reads => |*r| {
            allocator.free(r.name);
            allocator.free(r.value);
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
            try appendLenPrefixed(allocator, buf, t.inline_bytes);
        },
        .request_reads => |r| {
            try buf.append(allocator, @intFromEnum(r.kind));
            try appendLenPrefixed(allocator, buf, r.name);
            try appendLenPrefixed(allocator, buf, r.value);
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
            const inline_bytes = try readLenPrefixed(bytes, &cur);
            if (cur != bytes.len) return ParseError.Truncated;
            return .{ .trigger_payload = .{
                .body_ref = .{
                    .batch_id = br_batch_id,
                    .offset = br_offset,
                    .len = br_len,
                },
                .inline_bytes = inline_bytes,
            } };
        },
        .request_reads => {
            if (bytes.len < 1) return ParseError.Truncated;
            const kind = std.meta.intToEnum(RequestReadKind, bytes[0]) catch
                return ParseError.UnknownChannel;
            cur = 1;
            const name = try readLenPrefixed(bytes, &cur);
            const value = try readLenPrefixed(bytes, &cur);
            if (cur != bytes.len) return ParseError.Truncated;
            return .{ .request_reads = .{
                .kind = kind,
                .name = name,
                .value = value,
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

// `docs/primitive-gaps.md` §9 + fold-in: math_random + crypto_random
// + date tape channels removed. `Math.random` + `crypto.*` draw
// from arenajs's per-context xorshift64star (seeded once per
// request from `Readset.seed`); `Date.now()` returns a pinned
// scalar (set via `JS_SetDateNow` from
// `Readset.timestamp_ns`). Determinism is verified by the
// dispatcher test "dispatch: Date.now + Math.random + crypto.*
// are seed/timestamp-only" — same seed + timestamp → bit-identical
// output.

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
    rs.js_engine_version = 7;
    try rs.kv.appendKv(.get, "k", "v", .ok);
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
    );
    try rs.request_reads.appendRequestReadOnce(.header_value, "user-agent", "smoke/1");

    const bytes = try rs.serialize(testing.allocator, null);
    defer testing.allocator.free(bytes);

    const parsed = try parseReadset(bytes);
    try testing.expectEqual(@as(i64, 1_700_000_000_000_000_000), parsed.timestamp_ns);
    try testing.expectEqual(@as(u64, 0xDEADBEEFCAFEBABE), parsed.seed);
    try testing.expectEqual(@as(u16, 7), parsed.js_engine_version);
    try testing.expect(parsed.log_header == null);

    // Each blob is a self-contained tape; re-parse to confirm the
    // channel id in the inner header matches the wire-order channel.
    const expected_channels = [_]Channel{
        .kv,
        .module,
        .fetch_responses,
        .trigger_payload,
        .request_reads,
    };
    for (parsed.blobs, 0..) |blob, idx| {
        var p = try parse(testing.allocator, blob);
        defer p.deinit();
        try testing.expectEqual(expected_channels[idx], p.channel);
    }
}

test "readset: serialize + parseReadset roundtrip with LogHeader" {
    var rs = Readset.init(testing.allocator, 42, 0xAB);
    defer rs.deinit();
    try rs.kv.appendKv(.get, "k", "v", .ok);
    const lh: log_mod.LogHeader = .{
        .request_id = 0xCAFE_BABE_DEAD_BEEF,
        .deployment_id = 1_700_000_000,
        .duration_ns = 12345,
        .status = 200,
        .outcome = .ok,
        .activation = .inbound,
        .method = "POST",
        .path = "/api/echo",
        .host = "x.rewindjsapp.localhost",
        .correlation_id = "corr-aa",
    };
    const bytes = try rs.serialize(testing.allocator, lh);
    defer testing.allocator.free(bytes);

    const parsed = try parseReadset(bytes);
    try testing.expectEqual(@as(i64, 42), parsed.timestamp_ns);
    try testing.expect(parsed.log_header != null);
    const p_lh = parsed.log_header.?;
    try testing.expectEqual(lh.request_id, p_lh.request_id);
    try testing.expectEqual(lh.deployment_id, p_lh.deployment_id);
    try testing.expectEqual(lh.duration_ns, p_lh.duration_ns);
    try testing.expectEqual(lh.status, p_lh.status);
    try testing.expectEqual(lh.outcome, p_lh.outcome);
    try testing.expectEqual(lh.activation, p_lh.activation);
    try testing.expectEqualStrings(lh.method, p_lh.method);
    try testing.expectEqualStrings(lh.path, p_lh.path);
    try testing.expectEqualStrings(lh.host, p_lh.host);
    try testing.expectEqualStrings(lh.correlation_id, p_lh.correlation_id);
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
    const bytes = try rs.serialize(testing.allocator, null);
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
    const rs_bytes = try rs.serialize(testing.allocator, null);
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
    try rs_b.module.appendModule("./b.js", "b" ** 64);
    var rs_c = Readset.init(testing.allocator, 3, 0x33);
    defer rs_c.deinit();

    const ba = try rs_a.serialize(testing.allocator, null);
    defer testing.allocator.free(ba);
    const bb = try rs_b.serialize(testing.allocator, null);
    defer testing.allocator.free(bb);
    const bc = try rs_c.serialize(testing.allocator, null);
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
    const rs_bytes = try rs.serialize(testing.allocator, null);
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
    try testing.expectEqualStrings("", t.inline_bytes);
}

test "trigger_payload tape: inline small-body roundtrip" {
    var tape = Tape.init(testing.allocator, .trigger_payload);
    defer tape.deinit();
    const body = "{\"hello\":\"world\"}";
    // Inline path: sentinel batch_id, body rides as inline_bytes.
    try tape.appendTriggerPayload(
        .{ .batch_id = 0, .offset = 0, .len = @intCast(body.len) },
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

test "request_reads tape: all kinds roundtrip" {
    var tape = Tape.init(testing.allocator, .request_reads);
    defer tape.deinit();
    try tape.appendRequestReadOnce(.header_names, "", "[\"user-agent\",\"cookie\"]");
    try tape.appendRequestReadOnce(.header_value, "user-agent", "smoke/1");
    try tape.appendRequestReadOnce(.header_value, "cookie", "sid=abc; theme=dark");
    try tape.appendRequestReadOnce(.body_read, "", "");
    try tape.appendRequestReadOnce(.ip_masked, "", "203.0.113.0");
    try tape.appendRequestReadOnce(.ip_raw, "", "203.0.113.7");

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(Channel.request_reads, parsed.channel);
    try testing.expectEqual(@as(usize, 6), parsed.entries.len);
    const names = parsed.entries[0].request_reads;
    try testing.expectEqual(RequestReadKind.header_names, names.kind);
    try testing.expectEqualStrings("[\"user-agent\",\"cookie\"]", names.value);
    const ua = parsed.entries[1].request_reads;
    try testing.expectEqual(RequestReadKind.header_value, ua.kind);
    try testing.expectEqualStrings("user-agent", ua.name);
    try testing.expectEqualStrings("smoke/1", ua.value);
    const br = parsed.entries[3].request_reads;
    try testing.expectEqual(RequestReadKind.body_read, br.kind);
    try testing.expectEqualStrings("", br.name);
    const masked = parsed.entries[4].request_reads;
    try testing.expectEqual(RequestReadKind.ip_masked, masked.kind);
    try testing.expectEqualStrings("203.0.113.0", masked.value);
    const raw = parsed.entries[5].request_reads;
    try testing.expectEqual(RequestReadKind.ip_raw, raw.kind);
    try testing.expectEqualStrings("203.0.113.7", raw.value);
}

test "request_reads tape: appendRequestReadOnce dedupes on (kind, name)" {
    var tape = Tape.init(testing.allocator, .request_reads);
    defer tape.deinit();
    try tape.appendRequestReadOnce(.header_value, "user-agent", "smoke/1");
    try tape.appendRequestReadOnce(.header_value, "user-agent", "smoke/1");
    try tape.appendRequestReadOnce(.header_value, "user-agent", "ignored-second-value");
    // Same name under a DIFFERENT kind is a distinct record.
    try tape.appendRequestReadOnce(.header_value, "accept", "*/*");
    try tape.appendRequestReadOnce(.body_read, "", "");
    try tape.appendRequestReadOnce(.body_read, "", "");

    try testing.expectEqual(@as(usize, 3), tape.entries.items.len);
    try testing.expectEqualStrings("smoke/1", tape.entries.items[0].request_reads.value);
    try testing.expectEqualStrings("accept", tape.entries.items[1].request_reads.name);
    try testing.expectEqual(RequestReadKind.body_read, tape.entries.items[2].request_reads.kind);
}

test "elideUnreadBody: drops trigger_payload entries unless body was read" {
    var rs = Readset.init(testing.allocator, 1, 1);
    defer rs.deinit();
    try rs.trigger_payload.appendTriggerPayload(
        .{ .batch_id = 0, .offset = 0, .len = 5 },
        "hello",
    );
    try testing.expectEqual(@as(usize, 1), rs.trigger_payload.entries.items.len);

    // Unread → elided; idempotent on repeat.
    rs.elideUnreadBody();
    try testing.expectEqual(@as(usize, 0), rs.trigger_payload.entries.items.len);
    try testing.expectEqual(@as(usize, 0), rs.trigger_payload.owned_bytes);
    rs.elideUnreadBody();
    try testing.expectEqual(@as(usize, 0), rs.trigger_payload.entries.items.len);

    // Read → entry survives.
    var rs2 = Readset.init(testing.allocator, 1, 1);
    defer rs2.deinit();
    try rs2.trigger_payload.appendTriggerPayload(
        .{ .batch_id = 0, .offset = 0, .len = 5 },
        "hello",
    );
    rs2.body_read = true;
    rs2.elideUnreadBody();
    try testing.expectEqual(@as(usize, 1), rs2.trigger_payload.entries.items.len);
    try testing.expectEqualStrings("hello", rs2.trigger_payload.entries.items[0].trigger_payload.inline_bytes);
}

test "readset: old-version blob is rejected loudly" {
    var rs = Readset.init(testing.allocator, 42, 7);
    defer rs.deinit();
    const blob = try rs.serialize(testing.allocator, null);
    defer testing.allocator.free(blob);
    // Patch the version field back to the previous wire version.
    std.mem.writeInt(u16, blob[4..6], READSET_VERSION - 1, .big);
    try testing.expectError(ParseError.UnsupportedVersion, parseReadset(blob));
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
