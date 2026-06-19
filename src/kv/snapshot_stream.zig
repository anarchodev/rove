//! snapshot_stream.zig — streaming snapshot-transfer codec (raft Phase 2.5).
//!
//! Phase 2.5 retires the single-shot `dumpTenantBundle` → buffered-POST →
//! `loadTenantBundle` path (the whole store materialized into one `ArrayList`,
//! one HTTP body, one txn — the multi-GB wall) in favour of a streamed transfer
//! whose resident memory is bounded to ONE pair + one apply batch on each end:
//!
//!   SOURCE — `StreamDumper`: a PULL-model serializer over a held kvexp
//!     `Snapshot` cursor. `pull(dst)` fills the caller's buffer (curl's
//!     `CURLOPT_READFUNCTION` buffer) with the next slice of the wire, staging
//!     exactly one pair at a time. The held snapshot is the consistency anchor —
//!     it names one `{index, conf_state}` for the whole transfer — and its LMDB
//!     read txn pins pages for the transfer's lifetime (the page-pinning bound
//!     the catch-up driver enforces a deadline against).
//!
//!   DEST — `StreamLoader`: a PUSH-model deserializer. `feed(chunk)` parses the
//!     wire as inbound body chunks arrive (frames may split across ANY chunk
//!     boundary) and applies pairs in BOUNDED txns — committing once a batch
//!     crosses `batch_max_pairs`/`batch_max_bytes` — so the dest never holds the
//!     whole store. REPLACE semantics: the store is cleared inside the first
//!     batch's txn; `finish()` commits the final batch.
//!
//! Bounded-memory tradeoff (deliberate): a mid-stream abort leaves a PARTIAL
//! store — atomic-replace and bounded-RSS cannot both hold for a multi-GB store.
//! This is safe because the caller installs the raft baseline ONLY after
//! `finish()` succeeds, so an aborted peer stays "behind", re-triggers, and
//! re-streams from the leader's (newer) snapshot — re-clearing then re-applying
//! (idempotent). A node never serves reads from a partially-applied store
//! because its raft apply-index was never advanced.
//!
//! Wire format (own magic, distinct from kvexp `BUNDLE_MAGIC` so a stream can
//! never be mis-decoded as a bundle — there is NO `n_pairs`; the stream ends at
//! body EOF, which the transport signals as a clean END_STREAM vs a reset):
//!
//!     [magic:u32 LE = STREAM_MAGIC][version:u8][store_id:u64 LE]
//!     repeat until EOF: [key_len:u16 LE][val_len:u32 LE][key bytes][val bytes]

const std = @import("std");
const kvexp = @import("kvexp");

/// "MGS2" — distinct from kvexp's BUNDLE_MAGIC ("MIGR"); a crossed wire is
/// rejected loudly rather than silently mis-framed.
pub const STREAM_MAGIC: u32 = 0x3253474D;
pub const STREAM_VERSION: u8 = 1;

/// Matches kvexp's internal BUNDLE_KEY_MAX / BUNDLE_VAL_MAX — values written
/// through rove are bundle-capped at 1 MiB, keys at 256 B.
pub const STREAM_KEY_MAX: usize = 256;
pub const STREAM_VAL_MAX: usize = 1 << 20;

const HEADER_LEN: usize = 4 + 1 + 8; // magic + version + store_id
const LEN_PREFIX: usize = 2 + 4; // key_len(u16) + val_len(u32)
/// Largest single staged frame on the source side: a length-prefixed max pair.
const MAX_FRAME: usize = LEN_PREFIX + STREAM_KEY_MAX + STREAM_VAL_MAX;

pub const Error = error{
    InvalidStreamFormat,
    UnsupportedStreamVersion,
    StreamKeyTooLarge,
    StreamValueTooLarge,
    /// `finish()` called while a frame was only partially received — the body
    /// ended mid-pair (truncated transfer / mid-stream reset).
    TruncatedStream,
    StoreNotFound,
    Kvexp,
    OutOfMemory,
};

// ─── Source: pull-model serializer ──────────────────────────────────────────

/// Serializes one store's committed key-space out of a held snapshot, one pair
/// at a time, draining into caller-supplied buffers. Owns the snapshot (and thus
/// its page-pinning read txn) for its lifetime — `deinit()` releases it.
pub const StreamDumper = struct {
    allocator: std.mem.Allocator,
    snap: kvexp.Snapshot,
    cursor: kvexp.SnapshotPrefixCursor,
    store_id: u64,

    /// Staging buffer for the current frame (header, or one pair), drained to
    /// the caller across as many `pull` calls as the wire flow control needs.
    stage: []u8,
    stage_len: usize = 0,
    stage_pos: usize = 0,
    state: enum { header, pairs, done } = .header,

    /// Opens a held snapshot of `manifest` and stages the stream header. The
    /// snapshot reflects committed writes via its captured overlay + LMDB read
    /// txn — NO `durabilize` is forced (that would fsync-contend the leader's
    /// poll loop; openSnapshot's overlay capture already sees committed pairs).
    pub fn init(allocator: std.mem.Allocator, manifest: *kvexp.Manifest, store_id: u64) Error!StreamDumper {
        var snap = manifest.openSnapshot() catch return Error.Kvexp;
        errdefer snap.close();
        const cursor = snap.scanPrefix(store_id, "") catch return Error.Kvexp;

        const stage = try allocator.alloc(u8, MAX_FRAME);
        errdefer allocator.free(stage);

        var self: StreamDumper = .{
            .allocator = allocator,
            .snap = snap,
            .cursor = cursor,
            .store_id = store_id,
            .stage = stage,
        };
        // Stage the header.
        std.mem.writeInt(u32, self.stage[0..4], STREAM_MAGIC, .little);
        self.stage[4] = STREAM_VERSION;
        std.mem.writeInt(u64, self.stage[5..13], store_id, .little);
        self.stage_len = HEADER_LEN;
        self.stage_pos = 0;
        return self;
    }

    pub fn deinit(self: *StreamDumper) void {
        self.cursor.deinit();
        self.snap.close();
        self.allocator.free(self.stage);
        self.* = undefined;
    }

    /// Fill `dst` with the next bytes of the wire; returns the count written
    /// (0 == end of stream). Spans frames within one call if `dst` has room.
    pub fn pull(self: *StreamDumper, dst: []u8) Error!usize {
        var written: usize = 0;
        while (written < dst.len) {
            if (self.stage_pos == self.stage_len) {
                if (!try self.refill()) break; // done
            }
            const avail = self.stage_len - self.stage_pos;
            const room = dst.len - written;
            const n = @min(avail, room);
            @memcpy(dst[written..][0..n], self.stage[self.stage_pos..][0..n]);
            self.stage_pos += n;
            written += n;
        }
        return written;
    }

    /// Stage the next pair into `self.stage`; false once the cursor is drained.
    fn refill(self: *StreamDumper) Error!bool {
        switch (self.state) {
            .done => return false,
            .header => self.state = .pairs, // header already drained; fall through
            .pairs => {},
        }
        const has = self.cursor.next() catch return Error.Kvexp;
        if (!has) {
            self.state = .done;
            return false;
        }
        const k = self.cursor.key();
        const v = self.cursor.value();
        if (k.len > STREAM_KEY_MAX) return Error.StreamKeyTooLarge;
        if (v.len > STREAM_VAL_MAX) return Error.StreamValueTooLarge;
        std.mem.writeInt(u16, self.stage[0..2], @intCast(k.len), .little);
        std.mem.writeInt(u32, self.stage[2..6], @intCast(v.len), .little);
        @memcpy(self.stage[6..][0..k.len], k);
        @memcpy(self.stage[6 + k.len ..][0..v.len], v);
        self.stage_len = LEN_PREFIX + k.len + v.len;
        self.stage_pos = 0;
        return true;
    }
};

// ─── Dest: push-model bounded-apply deserializer ──────────────────────────────

pub const LoaderOptions = struct {
    /// REPLACE: clear the destination store (inside the first batch's txn)
    /// before applying — the store ends exactly equal to the stream. This is
    /// the catch-up / promote-back semantics. With false, pairs overwrite but
    /// destination-only keys survive (additive).
    clear_existing: bool = true,
    /// MERGE (zero-downtime move): insert-if-absent — a key already present in
    /// the destination (a NEWER value a live forward already wrote) is KEPT and
    /// the stream's older value dropped. Mutually exclusive with `clear_existing`
    /// (a cleared store has nothing to preserve); set `clear_existing = false`
    /// alongside this.
    skip_existing: bool = false,
    /// Commit the in-flight txn once it accumulates this many pairs …
    batch_max_pairs: usize = 4096,
    /// … or this many key+value bytes, whichever first. Bounds resident memory
    /// (the overlay of the open batch) regardless of pair-size distribution.
    batch_max_bytes: usize = 8 << 20,
};

/// Parses the wire incrementally and applies it to a kvexp store in bounded
/// txns. Holds one exclusive lease for the whole load (the store is not serving
/// traffic during catch-up); `finish()` commits the tail batch and releases.
pub const StreamLoader = struct {
    allocator: std.mem.Allocator,
    manifest: *kvexp.Manifest,
    opts: LoaderOptions,

    // ── incremental parse state ──
    phase: enum { header, lens, key, val } = .header,
    /// Scratch for the fixed-size header / length-prefix fields while they
    /// accumulate across chunk boundaries.
    scratch: [HEADER_LEN]u8 = undefined,
    scratch_filled: usize = 0,
    klen: usize = 0,
    vlen: usize = 0,
    /// Heap key/val accumulators (val can be 1 MiB — off the stack).
    key_buf: []u8,
    val_buf: []u8,
    field_filled: usize = 0,
    store_id: u64 = 0,
    header_seen: bool = false,

    // ── apply state ──
    // The lease + txn are held ONLY for the duration of a single feed() call,
    // never across calls — so the worker thread that drives feed() can never
    // deadlock re-acquiring this tenant's non-reentrant lease elsewhere in the
    // same tick. `store_ready` (store created + replace-cleared) persists across
    // feeds; each feed's commit folds into the tenant overlay so the next feed
    // builds on it. `failed` latches a parse/apply error (the stream is dead).
    lease: ?kvexp.StoreLease = null,
    txn: ?*kvexp.Txn = null,
    store_ready: bool = false,
    failed: bool = false,
    batch_pairs: usize = 0,
    batch_bytes: usize = 0,
    total_pairs: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, manifest: *kvexp.Manifest, opts: LoaderOptions) Error!StreamLoader {
        const key_buf = try allocator.alloc(u8, STREAM_KEY_MAX);
        errdefer allocator.free(key_buf);
        const val_buf = try allocator.alloc(u8, STREAM_VAL_MAX);
        return .{
            .allocator = allocator,
            .manifest = manifest,
            .opts = opts,
            .key_buf = key_buf,
            .val_buf = val_buf,
        };
    }

    /// Roll back any in-flight batch and free buffers. Safe to call after
    /// `finish()` (no-op on the txn then) or on the abort path.
    pub fn deinit(self: *StreamLoader) void {
        self.abort();
        self.allocator.free(self.key_buf);
        self.allocator.free(self.val_buf);
        self.* = undefined;
    }

    /// Drop the open batch (uncommitted pairs vanish) + release the lease. The
    /// committed earlier batches stay — see the partial-store note up top.
    pub fn abort(self: *StreamLoader) void {
        if (self.txn) |t| {
            t.rollback();
            self.txn = null;
        }
        if (self.lease) |*l| {
            l.release();
            self.lease = null;
        }
    }

    /// Parse + apply as many complete pairs as `chunk` yields. The lease + txn
    /// live only for this call (committed + released in `endFeed`); partial
    /// frames are retained on `self` for the next call. On any error the feed's
    /// txn is rolled back and the loader latches `failed`.
    pub fn feed(self: *StreamLoader, chunk: []const u8) Error!void {
        if (self.failed) return Error.Kvexp;
        errdefer self.failAndRollback();
        var i: usize = 0;
        while (i < chunk.len) {
            switch (self.phase) {
                .header => {
                    i += self.fillScratch(chunk[i..], HEADER_LEN);
                    if (self.scratch_filled < HEADER_LEN) break; // need more bytes
                    const magic = std.mem.readInt(u32, self.scratch[0..4], .little);
                    if (magic != STREAM_MAGIC) return Error.InvalidStreamFormat;
                    if (self.scratch[4] != STREAM_VERSION) return Error.UnsupportedStreamVersion;
                    self.store_id = std.mem.readInt(u64, self.scratch[5..13], .little);
                    self.header_seen = true;
                    self.scratch_filled = 0;
                    self.phase = .lens;
                    // Create + (replace) clear now, so even a header-only stream
                    // (empty source) still replaces correctly.
                    try self.ensureStoreReady();
                },
                .lens => {
                    i += self.fillScratch(chunk[i..], LEN_PREFIX);
                    if (self.scratch_filled < LEN_PREFIX) break;
                    self.klen = std.mem.readInt(u16, self.scratch[0..2], .little);
                    self.vlen = std.mem.readInt(u32, self.scratch[2..6], .little);
                    if (self.klen > STREAM_KEY_MAX) return Error.StreamKeyTooLarge;
                    if (self.vlen > STREAM_VAL_MAX) return Error.StreamValueTooLarge;
                    self.scratch_filled = 0;
                    self.field_filled = 0;
                    self.phase = .key;
                },
                .key => {
                    const n = copyInto(self.key_buf[0..self.klen], self.field_filled, chunk[i..]);
                    self.field_filled += n;
                    i += n;
                    if (self.field_filled < self.klen) break;
                    self.field_filled = 0;
                    self.phase = .val;
                },
                .val => {
                    const n = copyInto(self.val_buf[0..self.vlen], self.field_filled, chunk[i..]);
                    self.field_filled += n;
                    i += n;
                    if (self.field_filled < self.vlen) break;
                    try self.applyPair(self.key_buf[0..self.klen], self.val_buf[0..self.vlen]);
                    self.field_filled = 0;
                    self.phase = .lens;
                },
            }
        }
        try self.endFeed(); // commit + release THIS feed's txn/lease
    }

    /// Validate the stream ended cleanly. Each feed already committed + released
    /// its own batch, so nothing is open here. Errors if the body ended
    /// mid-frame (truncated transfer / reset). Returns the store id.
    pub fn finish(self: *StreamLoader) Error!u64 {
        if (self.failed) return Error.Kvexp;
        if (!self.header_seen) return Error.TruncatedStream;
        // A clean end can only land at a pair boundary (`.lens` with nothing
        // buffered); anything else means the transfer was cut short.
        if (!(self.phase == .lens and self.scratch_filled == 0)) return Error.TruncatedStream;
        return self.store_id;
    }

    /// Once: create the store if absent, then (replace mode) clear it inside
    /// this feed's txn. Idempotent across feeds — only the first does the work;
    /// later calls just ensure this feed has an open txn.
    fn ensureStoreReady(self: *StreamLoader) Error!void {
        if (!self.store_ready) {
            if (!(self.manifest.hasStore(self.store_id) catch return Error.Kvexp)) {
                self.manifest.createStore(self.store_id) catch return Error.Kvexp;
            }
        }
        try self.ensureTxn();
        if (!self.store_ready) {
            if (self.opts.clear_existing) try self.clearStore();
            self.store_ready = true;
        }
    }

    /// Delete every existing key in `self.txn` (collected first — never delete
    /// while iterating the live cursor).
    fn clearStore(self: *StreamLoader) Error!void {
        const txn = self.txn.?;
        var existing: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (existing.items) |k| self.allocator.free(k);
            existing.deinit(self.allocator);
        }
        var cur = txn.scanPrefix("") catch return Error.Kvexp;
        {
            defer cur.deinit();
            while (cur.next() catch return Error.Kvexp) {
                const dup = self.allocator.dupe(u8, cur.key()) catch return Error.OutOfMemory;
                existing.append(self.allocator, dup) catch return Error.OutOfMemory;
            }
        }
        for (existing.items) |k| _ = txn.delete(k) catch return Error.Kvexp;
    }

    /// Open this feed's lease (once per feed) + a fresh txn. `acquire` requires
    /// the store to exist, so callers create it first via `ensureStoreReady`.
    fn ensureTxn(self: *StreamLoader) Error!void {
        if (self.txn != null) return;
        if (self.lease == null) self.lease = self.manifest.acquire(self.store_id) catch return Error.Kvexp;
        self.txn = self.lease.?.beginTxn() catch return Error.Kvexp;
    }

    fn applyPair(self: *StreamLoader, k: []const u8, v: []const u8) Error!void {
        try self.ensureStoreReady();
        if (self.opts.skip_existing) {
            // MERGE: keep a destination-present (newer, forwarded) value.
            _ = self.txn.?.putIfAbsent(k, v) catch return Error.Kvexp;
        } else {
            self.txn.?.put(k, v) catch return Error.Kvexp;
        }
        self.total_pairs += 1;
        self.batch_pairs += 1;
        self.batch_bytes += k.len + v.len;
        // Intra-feed batch bound (defensive — feeds are usually window-sized):
        // commit + reopen under the SAME (this feed's) lease.
        if (self.batch_pairs >= self.opts.batch_max_pairs or self.batch_bytes >= self.opts.batch_max_bytes) {
            self.txn.?.commit() catch {
                self.txn = null;
                return Error.Kvexp;
            };
            self.txn = null;
            self.batch_pairs = 0;
            self.batch_bytes = 0;
        }
    }

    /// Commit + release this feed's txn/lease (nothing held across feed calls).
    fn endFeed(self: *StreamLoader) Error!void {
        if (self.txn) |t| {
            t.commit() catch {
                self.txn = null;
                if (self.lease) |*l| {
                    l.release();
                    self.lease = null;
                }
                return Error.Kvexp;
            };
            self.txn = null;
        }
        if (self.lease) |*l| {
            l.release();
            self.lease = null;
        }
        self.batch_pairs = 0;
        self.batch_bytes = 0;
    }

    /// Latch the failure + roll back/release whatever this feed had open.
    fn failAndRollback(self: *StreamLoader) void {
        self.failed = true;
        self.abort();
    }

    /// Accumulate up to `need` bytes of a fixed field into `self.scratch`;
    /// returns bytes consumed from `src`.
    fn fillScratch(self: *StreamLoader, src: []const u8, need: usize) usize {
        const want = need - self.scratch_filled;
        const n = @min(want, src.len);
        @memcpy(self.scratch[self.scratch_filled..][0..n], src[0..n]);
        self.scratch_filled += n;
        return n;
    }
};

/// Copy into `dst[offset..]` from `src`, returning bytes copied.
fn copyInto(dst: []u8, offset: usize, src: []const u8) usize {
    const n = @min(dst.len - offset, src.len);
    @memcpy(dst[offset..][0..n], src[0..n]);
    return n;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A throwaway on-disk manifest under a tmp dir; `deinit` cleans up.
const TestManifest = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    manifest: *kvexp.Manifest,

    fn init() !TestManifest {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = try tmp.dir.realpath(".", &dir_buf);
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/ss-test.mdb", .{dir_path});
        defer testing.allocator.free(p);
        const path = try testing.allocator.dupeZ(u8, p);
        errdefer testing.allocator.free(path);
        const manifest = try testing.allocator.create(kvexp.Manifest);
        errdefer testing.allocator.destroy(manifest);
        try manifest.init(testing.allocator, path, .{ .max_map_size = 64 * 1024 * 1024 });
        return .{ .tmp = tmp, .path = path, .manifest = manifest };
    }

    fn deinit(self: *TestManifest) void {
        self.manifest.deinit();
        testing.allocator.destroy(self.manifest);
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

const Pair = struct { key: []u8, val: []u8 };

fn freePairs(a: std.mem.Allocator, pairs: []Pair) void {
    for (pairs) |p| {
        a.free(p.key);
        a.free(p.val);
    }
    a.free(pairs);
}

/// Build a varied pair set: many small, one empty value, one long key, one
/// large value — exercises every frame-split boundary.
fn buildPairs(a: std.mem.Allocator) ![]Pair {
    var list: std.ArrayListUnmanaged(Pair) = .empty;
    errdefer {
        for (list.items) |p| {
            a.free(p.key);
            a.free(p.val);
        }
        list.deinit(a);
    }
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const key = try std.fmt.allocPrint(a, "k{d:0>4}", .{i});
        const val = try std.fmt.allocPrint(a, "value-for-{d}-padded-{d}", .{ i, i * 7 });
        try list.append(a, .{ .key = key, .val = val });
    }
    // Empty value (sorts before "k" — "empty").
    try list.append(a, .{ .key = try a.dupe(u8, "empty"), .val = try a.dupe(u8, "") });
    // Long (250 B) key.
    {
        const key = try a.alloc(u8, 250);
        @memset(key, 'L');
        try list.append(a, .{ .key = key, .val = try a.dupe(u8, "longkey") });
    }
    // Large value (300 KiB), sorts last under "z".
    {
        const val = try a.alloc(u8, 300 * 1024);
        for (val, 0..) |*b, j| b.* = @truncate(j *% 31 +% 7);
        try list.append(a, .{ .key = try a.dupe(u8, "zbig"), .val = val });
    }
    return list.toOwnedSlice(a);
}

fn writePairs(manifest: *kvexp.Manifest, store_id: u64, pairs: []const Pair) !void {
    if (!try manifest.hasStore(store_id)) try manifest.createStore(store_id);
    var lease = try manifest.acquire(store_id);
    defer lease.release();
    var txn = try lease.beginTxn();
    errdefer txn.rollback();
    for (pairs) |p| try txn.put(p.key, p.val);
    try txn.commit();
}

/// Scan a store into a sorted (kvexp scan order) owned pair list.
fn scanPairs(a: std.mem.Allocator, manifest: *kvexp.Manifest, store_id: u64) ![]Pair {
    var snap = try manifest.openSnapshot();
    defer snap.close();
    var cur = try snap.scanPrefix(store_id, "");
    defer cur.deinit();
    var list: std.ArrayListUnmanaged(Pair) = .empty;
    errdefer {
        for (list.items) |p| {
            a.free(p.key);
            a.free(p.val);
        }
        list.deinit(a);
    }
    while (try cur.next()) {
        try list.append(a, .{ .key = try a.dupe(u8, cur.key()), .val = try a.dupe(u8, cur.value()) });
    }
    return list.toOwnedSlice(a);
}

fn expectStoresEqual(a: std.mem.Allocator, src: *kvexp.Manifest, dst: *kvexp.Manifest, store_id: u64) !void {
    const sa = try scanPairs(a, src, store_id);
    defer freePairs(a, sa);
    const da = try scanPairs(a, dst, store_id);
    defer freePairs(a, da);
    try testing.expectEqual(sa.len, da.len);
    for (sa, da) |s, d| {
        try testing.expectEqualStrings(s.key, d.key);
        try testing.expectEqualStrings(s.val, d.val);
    }
}

/// Dump `src`'s store into an owned wire buffer, pulling in adversarially
/// varied sizes to exercise frame splitting.
fn dumpToWire(a: std.mem.Allocator, src: *kvexp.Manifest, store_id: u64, prng: *std.Random.DefaultPrng) ![]u8 {
    var dumper = try StreamDumper.init(a, src, store_id);
    defer dumper.deinit();
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    errdefer wire.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const cap = prng.random().intRangeAtMost(usize, 1, buf.len);
        const n = try dumper.pull(buf[0..cap]);
        if (n == 0) break;
        try wire.appendSlice(a, buf[0..n]);
    }
    return wire.toOwnedSlice(a);
}

test "snapshot stream round-trips a store across manifests (varied frame splits)" {
    const a = testing.allocator;
    const store_id: u64 = 0x1234;

    var src = try TestManifest.init();
    defer src.deinit();
    var dst = try TestManifest.init();
    defer dst.deinit();

    const pairs = try buildPairs(a);
    defer freePairs(a, pairs);
    try writePairs(src.manifest, store_id, pairs);

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const wire = try dumpToWire(a, src.manifest, store_id, &prng);
    defer a.free(wire);

    // Feed the wire in adversarially varied chunk sizes.
    var loader = try StreamLoader.init(a, dst.manifest, .{ .batch_max_pairs = 17, .batch_max_bytes = 64 * 1024 });
    defer loader.deinit();
    var off: usize = 0;
    while (off < wire.len) {
        const cap = prng.random().intRangeAtMost(usize, 1, 1000);
        const end = @min(off + cap, wire.len);
        try loader.feed(wire[off..end]);
        off = end;
    }
    const got_id = try loader.finish();
    try testing.expectEqual(store_id, got_id);
    try testing.expectEqual(@as(u64, pairs.len), loader.total_pairs);

    try expectStoresEqual(a, src.manifest, dst.manifest, store_id);
}

test "snapshot stream REPLACE clears destination-only stale keys" {
    const a = testing.allocator;
    const store_id: u64 = 0x55;

    var src = try TestManifest.init();
    defer src.deinit();
    var dst = try TestManifest.init();
    defer dst.deinit();

    try writePairs(src.manifest, store_id, &.{
        .{ .key = @constCast("alpha"), .val = @constCast("1") },
        .{ .key = @constCast("beta"), .val = @constCast("2") },
    });
    // Destination pre-seeded with a stale key absent from the source.
    try writePairs(dst.manifest, store_id, &.{
        .{ .key = @constCast("alpha"), .val = @constCast("OLD") },
        .{ .key = @constCast("ghost"), .val = @constCast("stale") },
    });

    var prng = std.Random.DefaultPrng.init(7);
    const wire = try dumpToWire(a, src.manifest, store_id, &prng);
    defer a.free(wire);

    var loader = try StreamLoader.init(a, dst.manifest, .{});
    defer loader.deinit();
    try loader.feed(wire);
    _ = try loader.finish();

    // Destination now equals the source exactly — "ghost" is gone.
    try expectStoresEqual(a, src.manifest, dst.manifest, store_id);
    const da = try scanPairs(a, dst.manifest, store_id);
    defer freePairs(a, da);
    try testing.expectEqual(@as(usize, 2), da.len);
}

test "snapshot stream MERGE keeps destination-present (forwarded) values" {
    const a = testing.allocator;
    const store_id: u64 = 0x77;

    var src = try TestManifest.init();
    defer src.deinit();
    var dst = try TestManifest.init();
    defer dst.deinit();

    try writePairs(src.manifest, store_id, &.{
        .{ .key = @constCast("alpha"), .val = @constCast("snap-old") },
        .{ .key = @constCast("beta"), .val = @constCast("2") },
        .{ .key = @constCast("gamma"), .val = @constCast("3") },
    });
    // Destination already holds a NEWER "alpha" (a live forward) the snapshot
    // must not clobber, plus its own "delta".
    try writePairs(dst.manifest, store_id, &.{
        .{ .key = @constCast("alpha"), .val = @constCast("forwarded-new") },
        .{ .key = @constCast("delta"), .val = @constCast("d") },
    });

    var prng = std.Random.DefaultPrng.init(99);
    const wire = try dumpToWire(a, src.manifest, store_id, &prng);
    defer a.free(wire);

    var loader = try StreamLoader.init(a, dst.manifest, .{ .clear_existing = false, .skip_existing = true });
    defer loader.deinit();
    try loader.feed(wire);
    _ = try loader.finish();

    const got = try scanPairs(a, dst.manifest, store_id);
    defer freePairs(a, got);
    // alpha=forwarded-new (kept), beta/gamma added, delta survives → 4 keys.
    try testing.expectEqual(@as(usize, 4), got.len);
    for (got) |p| {
        if (std.mem.eql(u8, p.key, "alpha")) try testing.expectEqualStrings("forwarded-new", p.val);
        if (std.mem.eql(u8, p.key, "beta")) try testing.expectEqualStrings("2", p.val);
        if (std.mem.eql(u8, p.key, "delta")) try testing.expectEqualStrings("d", p.val);
    }
}

test "snapshot stream finish() rejects a truncated body" {
    const a = testing.allocator;
    const store_id: u64 = 0x99;

    var src = try TestManifest.init();
    defer src.deinit();
    var dst = try TestManifest.init();
    defer dst.deinit();

    try writePairs(src.manifest, store_id, &.{
        .{ .key = @constCast("alpha"), .val = @constCast("hello world") },
    });
    var prng = std.Random.DefaultPrng.init(1);
    const wire = try dumpToWire(a, src.manifest, store_id, &prng);
    defer a.free(wire);

    var loader = try StreamLoader.init(a, dst.manifest, .{});
    defer loader.deinit();
    // Feed everything but the last byte → ends mid-frame.
    try loader.feed(wire[0 .. wire.len - 1]);
    try testing.expectError(Error.TruncatedStream, loader.finish());
}

test "snapshot stream rejects a foreign magic" {
    const a = testing.allocator;
    var dst = try TestManifest.init();
    defer dst.deinit();
    var loader = try StreamLoader.init(a, dst.manifest, .{});
    defer loader.deinit();
    // kvexp BUNDLE_MAGIC bytes ("MIGR") — must NOT be accepted as a stream.
    var hdr: [HEADER_LEN]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], kvexp.BUNDLE_MAGIC, .little);
    hdr[4] = STREAM_VERSION;
    std.mem.writeInt(u64, hdr[5..13], 1, .little);
    try testing.expectError(Error.InvalidStreamFormat, loader.feed(&hdr));
}
