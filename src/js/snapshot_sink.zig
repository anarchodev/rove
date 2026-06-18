//! Dest side of the raft Phase 2.5 streaming snapshot transfer
//! (`docs/raft-native-alignment.md`; codec in `raft-kv`'s `snapshot_stream`).
//!
//! `POST /_system/v2-snapshot-stream` arrives as a streamed inbound body. Rather
//! than the customer `onChunk` `Job` (which round-trips every >cap chunk through
//! the S3 chunk-tape durability gate — wrong for an internal peer→peer snapshot),
//! this is a dedicated `h2.BodySink` that feeds bytes straight into a
//! `kv.StreamLoader`. No tape, no S3: the kvexp apply + the raft baseline install
//! ARE the durability.
//!
//! rove-native shape (see the global `rove-library` principles):
//!   - **#2 data lifetime through components**: the streaming state is a heap
//!     `Box` OWNED by a `SnapshotStream` component on the request entity — NOT a
//!     side map. The `Box` is refcounted (h2 sink ref + component ref), so a
//!     dropped connection frees it structurally via the component deinit.
//!   - **#1 state is collection membership**: the request entity moves
//!     `request_out → snapshot_streams` (parked, out of the dispatch walk) →
//!     `response_in` on completion. `worker.drainSnapshotStreams` iterates
//!     `snapshot_streams` and finalizes.
//!   - **#14/#15 stable pointer**: the `Box` is heap-allocated; its address is
//!     the `BodySink` ctx (a column-stored value would dangle on a flush move).

const std = @import("std");
const kv = @import("raft-kv");

/// Heap, refcounted streaming-transfer state. Its address is the `h2.BodySink`
/// ctx, so it must NOT live in a rove column (those relocate on flush).
pub const Box = struct {
    allocator: std.mem.Allocator,
    /// Two owners: the h2 sink (released via `Sink.release`) and the
    /// `SnapshotStream` component (released in its deinit).
    refs: u32 = 2,

    loader: kv.StreamLoader,
    /// Raft group + data-free baseline to install once the body completes
    /// (carried in request headers — collapses the old two-call v2-load-replace
    /// + v2-apply-snapshot into one streamed call).
    gid: u64,
    index: u64,
    term: u64,

    /// END_STREAM seen — ready to finalize (finish + durabilize + baseline).
    eof: bool = false,
    /// A `feed()` rejected the stream (bad frame / apply error) — finalize 500.
    failed: bool = false,
    /// The client reset the upload mid-stream — no response is possible.
    aborted: bool = false,
    /// h2 receive-window bytes to repay (apply outpaces the wire, so we repay
    /// each push immediately — the wire, not the apply, is the bottleneck).
    drained_pending: u32 = 0,

    pub fn create(
        allocator: std.mem.Allocator,
        loader: kv.StreamLoader,
        gid: u64,
        index: u64,
        term: u64,
    ) error{OutOfMemory}!*Box {
        const self = try allocator.create(Box);
        self.* = .{ .allocator = allocator, .loader = loader, .gid = gid, .index = index, .term = term };
        return self;
    }

    pub fn unref(self: *Box) void {
        self.refs -= 1;
        if (self.refs > 0) return;
        self.loader.deinit();
        self.allocator.destroy(self);
    }

    /// Finalize the apply: validate the stream ended cleanly + flush the loaded
    /// pairs to disk BEFORE the caller advances the raft index. Returns the
    /// store id the stream named.
    pub fn commit(self: *Box) kv.snapshot_stream.Error!u64 {
        const store_id = try self.loader.finish();
        // Data must be durable before the raft baseline advances the applied
        // index — a crash in the window then recovers a store ≤ index on disk.
        // durabilize(0): fold overlay → LMDB without disturbing the watermark
        // (the snapshot's compaction marker carries the applied index, exactly
        // as the buffered v2-load-replace + v2-apply-snapshot path relies on).
        self.loader.manifest.durabilize(0) catch return kv.snapshot_stream.Error.Kvexp;
        return store_id;
    }

    // ── h2.BodySink callbacks (run on the worker thread == h2 poll thread) ──

    fn sinkPush(self: *Box, bytes: []const u8) bool {
        if (self.aborted) return false;
        // After a failure, keep draining so the closing stream can't wedge on a
        // shut window; the bytes are dropped (the loader is dead).
        if (!self.failed) {
            self.loader.feed(bytes) catch {
                self.failed = true;
            };
        }
        self.drained_pending +%= @intCast(bytes.len);
        return true;
    }

    fn sinkFinish(self: *Box) void {
        self.eof = true;
    }

    fn sinkAbort(self: *Box) void {
        self.aborted = true;
    }

    fn sinkDrained(self: *Box) u32 {
        const d = self.drained_pending;
        self.drained_pending = 0;
        return d;
    }
};

/// `h2.BodySink`-shaped vtable adapter (field shapes match `h2.BodySink`;
/// `worker.zig` constructs the real `BodySink` with these fn pointers).
pub const Sink = struct {
    pub fn push(ctx: *anyopaque, bytes: []const u8) bool {
        return boxOf(ctx).sinkPush(bytes);
    }
    pub fn finish(ctx: *anyopaque) void {
        boxOf(ctx).sinkFinish();
    }
    pub fn abort(ctx: *anyopaque) void {
        boxOf(ctx).sinkAbort();
    }
    pub fn drained(ctx: *anyopaque) u32 {
        return boxOf(ctx).sinkDrained();
    }
    pub fn release(ctx: *anyopaque) void {
        boxOf(ctx).unref();
    }
    inline fn boxOf(ctx: *anyopaque) *Box {
        return @ptrCast(@alignCast(ctx));
    }
};

/// Per-entity component: owns the streaming `Box` (one of its two refs). Carried
/// on the request entity through `request_out → snapshot_streams → response_in`;
/// its deinit (entity destroy or an explicit detach) drops the component's ref.
/// Default `{ box = null }` is the inert state every non-snapshot stream entity
/// carries (the field rides in the shared `StreamRow`).
pub const SnapshotStream = struct {
    box: ?*Box = null,

    pub fn deinit(allocator: std.mem.Allocator, items: []SnapshotStream) void {
        _ = allocator;
        for (items) |*s| {
            if (s.box) |b| {
                b.unref();
                s.box = null;
            }
        }
    }
};
