//! Off-pump raft snapshot staging for the V2 multi-raft node.
//!
//! A raft snapshot carries a tenant's whole store state so a follower whose log
//! was compacted past its position (or, later, a fresh learner) can catch up
//! without replaying the log. Per rove's blob philosophy the bytes go to S3
//! directly and only a tiny descriptor rides the raft `MsgSnapshot`; ALL S3 I/O
//! happens on this background thread — NEVER on the single-threaded raft pump
//! (`front_door_never_blocks_loop`).
//!
//! Generate (leader): the pump dumps the tenant store read-only at
//! `durabilized_idx` (fast, in-memory → buffer) and hands the bytes here to PUT
//! at `…/raft-snap/{idx}`. Until the PUT lands the storage `snapshot` provider
//! reports SnapshotTemporarilyUnavailable; raft-rs retries and gets the
//! descriptor once ready.
//!
//! Apply (follower): when a snapshot is pending, the pump asks here to fetch
//! `…/raft-snap/{idx}` to a local staging file; until it lands the pump defers
//! applying the snapshot. Once staged the pump loads it synchronously (local
//! file → kvexp) and advances the watermark — the slow network fetch is here,
//! the fast local load is on the pump.
//!
//! Threading: one worker thread drains a mutex-guarded job queue. The pump
//! enqueues jobs + polls per-gid state through the same mutex; it never blocks
//! on S3. A group with a pending snapshot keeps `has_ready` true (and is kept
//! active by the leader's inbound messages), so the pump re-polls it each cycle
//! until staging completes — no cross-thread wake of the pump-owned active set.

const std = @import("std");
const blob = @import("rove-blob");

pub const SUBDIR = "raft-snap";

/// Per-group generate-side state (leader): a snapshot is being / has been
/// uploaded to S3 so the `snapshot` provider can hand back its descriptor.
const GenState = struct {
    /// Index currently uploading, or 0.
    uploading_idx: u64 = 0,
    /// Highest index successfully uploaded (the provider serves this), or 0.
    ready_idx: u64 = 0,
};

/// Per-group apply-side state (follower): a snapshot is being / has been
/// fetched from S3 to a local staging file so the pump can load it.
const ApplyState = struct {
    /// Index currently fetching, or 0.
    fetching_idx: u64 = 0,
    /// Index whose bytes are staged on disk (load-ready), or 0.
    staged_idx: u64 = 0,
};

const JobKind = enum { upload, fetch };

const Job = struct {
    kind: JobKind,
    gid: u64,
    idx: u64,
    /// Owned dup of the tenant id_str (instance id for the S3 key prefix).
    id_str: []u8,
    /// upload only: owned bundle bytes to PUT (freed after the PUT).
    bytes: []u8 = &.{},
};

pub const Stager = struct {
    allocator: std.mem.Allocator,
    /// S3 connection params (borrowed; outlives the Stager). When null,
    /// snapshots are disabled — `snapshotsEnabled()` is false and the node
    /// falls back to the historical single-node-only compaction behaviour.
    blob_cfg: ?blob.BackendConfig,
    /// Local staging root: `{data_dir}/.snapshot-staging`.
    staging_dir: []u8,

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: std.ArrayListUnmanaged(Job) = .empty,
    gen: std.AutoHashMapUnmanaged(u64, GenState) = .empty,
    apply: std.AutoHashMapUnmanaged(u64, ApplyState) = .empty,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        blob_cfg: ?blob.BackendConfig,
    ) !*Stager {
        const self = try allocator.create(Stager);
        errdefer allocator.destroy(self);
        const staging = try std.fmt.allocPrint(allocator, "{s}/.snapshot-staging", .{data_dir});
        errdefer allocator.free(staging);
        self.* = .{ .allocator = allocator, .blob_cfg = blob_cfg, .staging_dir = staging };
        if (blob_cfg != null) {
            std.fs.cwd().makePath(staging) catch {};
            self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
        }
        return self;
    }

    pub fn deinit(self: *Stager) void {
        if (self.thread) |t| {
            self.stop.store(true, .release);
            self.mutex.lock();
            self.cond.signal();
            self.mutex.unlock();
            t.join();
        }
        // Free any queued jobs' owned memory.
        for (self.queue.items) |job| {
            self.allocator.free(job.id_str);
            if (job.bytes.len > 0) self.allocator.free(job.bytes);
        }
        self.queue.deinit(self.allocator);
        self.gen.deinit(self.allocator);
        self.apply.deinit(self.allocator);
        self.allocator.free(self.staging_dir);
        self.allocator.destroy(self);
    }

    pub fn snapshotsEnabled(self: *const Stager) bool {
        return self.blob_cfg != null;
    }

    // ── Generate side (leader, called from the pump) ────────────────────

    /// If a snapshot at index >= `min_idx` is uploaded and ready, return its
    /// index; else null. Cheap (no dump) — the provider checks this first so it
    /// only dumps the store when it actually has to enqueue an upload.
    pub fn genReadyIdx(self: *Stager, gid: u64, min_idx: u64) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const st = self.gen.getPtr(gid) orelse return null;
        if (st.ready_idx > 0 and st.ready_idx >= min_idx) return st.ready_idx;
        return null;
    }

    /// Whether an upload is in flight for `gid` (the provider should wait,
    /// reporting Unavailable, rather than dumping + enqueueing again).
    pub fn genBusy(self: *Stager, gid: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const st = self.gen.getPtr(gid) orelse return false;
        return st.uploading_idx != 0;
    }

    /// Enqueue an upload of the freshly-dumped `bundle` (a copy is taken and
    /// freed after the PUT) for `dump_idx`. Caller has already confirmed via
    /// `genReadyIdx`/`genBusy` that none is ready/in-flight. Pump-thread only,
    /// so there is no race with those checks.
    pub fn enqueueUpload(self: *Stager, gid: u64, id_str: []const u8, dump_idx: u64, bundle: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const gs = self.gen.getOrPut(self.allocator, gid) catch return;
        if (!gs.found_existing) gs.value_ptr.* = .{};
        if (gs.value_ptr.uploading_idx != 0) return; // already in flight
        const id_dup = self.allocator.dupe(u8, id_str) catch return;
        const bytes_owned = self.allocator.dupe(u8, bundle) catch {
            self.allocator.free(id_dup);
            return;
        };
        self.queue.append(self.allocator, .{
            .kind = .upload,
            .gid = gid,
            .idx = dump_idx,
            .id_str = id_dup,
            .bytes = bytes_owned,
        }) catch {
            self.allocator.free(id_dup);
            self.allocator.free(bytes_owned);
            return;
        };
        gs.value_ptr.uploading_idx = dump_idx;
        self.cond.signal();
    }

    // ── Apply side (follower, called from the pump) ─────────────────────

    /// Staging state for a pending snapshot at `idx`: `.staged` (the bytes are
    /// on disk — proceed to load), `.fetching` (in flight — defer), or
    /// `.kicked` (a fetch was just enqueued — defer). The pump calls this for a
    /// group with a pending snapshot before letting `processReady` apply it.
    pub const StageState = enum { staged, fetching, kicked };

    pub fn ensureFetched(self: *Stager, gid: u64, id_str: []const u8, idx: u64) StageState {
        self.mutex.lock();
        defer self.mutex.unlock();
        const as = self.apply.getOrPut(self.allocator, gid) catch return .fetching;
        if (!as.found_existing) as.value_ptr.* = .{};
        const st = as.value_ptr;
        if (st.staged_idx == idx) return .staged;
        if (st.fetching_idx == idx) return .fetching;
        // A new (or superseding) snapshot index — enqueue a fetch.
        const id_dup = self.allocator.dupe(u8, id_str) catch return .fetching;
        self.queue.append(self.allocator, .{
            .kind = .fetch,
            .gid = gid,
            .idx = idx,
            .id_str = id_dup,
        }) catch {
            self.allocator.free(id_dup);
            return .fetching;
        };
        st.fetching_idx = idx;
        st.staged_idx = 0;
        self.cond.signal();
        return .kicked;
    }

    /// Absolute path of the staged bundle file for `gid` (valid after
    /// `ensureFetched` returned `.staged`). Caller frees.
    pub fn stagedPath(self: *Stager, gid: u64, idx: u64) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{d}-{d}.bin", .{ self.staging_dir, gid, idx });
    }

    /// Clear apply state + delete the staged file once the pump has loaded it.
    pub fn clearApplied(self: *Stager, gid: u64, idx: u64) void {
        if (self.stagedPath(gid, idx)) |p| {
            defer self.allocator.free(p);
            std.fs.cwd().deleteFile(p) catch {};
        } else |_| {}
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.apply.getPtr(gid)) |st| st.* = .{};
    }

    /// Drop all per-group state for a destroyed group (best-effort file GC).
    pub fn forgetGroup(self: *Stager, gid: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.gen.remove(gid);
        _ = self.apply.remove(gid);
    }

    // ── Worker thread ───────────────────────────────────────────────────

    fn workerLoop(self: *Stager) void {
        while (true) {
            self.mutex.lock();
            while (self.queue.items.len == 0 and !self.stop.load(.acquire)) {
                self.cond.wait(&self.mutex);
            }
            if (self.stop.load(.acquire) and self.queue.items.len == 0) {
                self.mutex.unlock();
                return;
            }
            const job = self.queue.orderedRemove(0);
            self.mutex.unlock();

            switch (job.kind) {
                .upload => self.runUpload(job),
                .fetch => self.runFetch(job),
            }
            self.allocator.free(job.id_str);
            if (job.bytes.len > 0) self.allocator.free(job.bytes);
        }
    }

    fn openBackend(self: *Stager, id_str: []const u8) ?blob.BlobBackend {
        const cfg = self.blob_cfg orelse return null;
        return blob.BlobBackend.openPerTenant(self.allocator, cfg, id_str, SUBDIR) catch |e| {
            std.log.warn("snapshot: open backend {s}: {s}", .{ id_str, @errorName(e) });
            return null;
        };
    }

    fn runUpload(self: *Stager, job: Job) void {
        var be = self.openBackend(job.id_str) orelse return;
        defer be.deinit();
        var keybuf: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&keybuf, "{d}", .{job.idx}) catch return;
        be.blobStore().put(key, job.bytes) catch |e| {
            std.log.warn("snapshot: upload gid={d} idx={d}: {s}", .{ job.gid, job.idx, @errorName(e) });
            // Leave uploading_idx set so a retry isn't spammed every tick; clear
            // it so the next offer re-enqueues. Pick clear: a transient S3 error
            // should be retried on the leader's next snapshot attempt.
            self.mutex.lock();
            if (self.gen.getPtr(job.gid)) |st| st.uploading_idx = 0;
            self.mutex.unlock();
            return;
        };
        // GC the previous snapshot object (keep only the latest).
        self.mutex.lock();
        const prev = if (self.gen.getPtr(job.gid)) |st| st.ready_idx else 0;
        if (self.gen.getPtr(job.gid)) |st| {
            st.ready_idx = job.idx;
            st.uploading_idx = 0;
        }
        self.mutex.unlock();
        if (prev != 0 and prev != job.idx) {
            var pbuf: [24]u8 = undefined;
            if (std.fmt.bufPrint(&pbuf, "{d}", .{prev})) |pkey| {
                be.blobStore().delete(pkey) catch {};
            } else |_| {}
        }
    }

    fn runFetch(self: *Stager, job: Job) void {
        var be = self.openBackend(job.id_str) orelse return;
        defer be.deinit();
        var keybuf: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&keybuf, "{d}", .{job.idx}) catch return;
        const bytes = be.blobStore().get(key, self.allocator) catch |e| {
            std.log.warn("snapshot: fetch gid={d} idx={d}: {s}", .{ job.gid, job.idx, @errorName(e) });
            self.mutex.lock();
            if (self.apply.getPtr(job.gid)) |st| st.fetching_idx = 0;
            self.mutex.unlock();
            return;
        };
        defer self.allocator.free(bytes);
        const path = self.stagedPath(job.gid, job.idx) catch return;
        defer self.allocator.free(path);
        writeFile(path, bytes) catch |e| {
            std.log.warn("snapshot: stage gid={d} idx={d}: {s}", .{ job.gid, job.idx, @errorName(e) });
            self.mutex.lock();
            if (self.apply.getPtr(job.gid)) |st| st.fetching_idx = 0;
            self.mutex.unlock();
            return;
        };
        self.mutex.lock();
        if (self.apply.getPtr(job.gid)) |st| {
            if (st.fetching_idx == job.idx) {
                st.fetching_idx = 0;
                st.staged_idx = job.idx;
            }
        }
        self.mutex.unlock();
    }

    fn writeFile(path: []const u8, bytes: []const u8) !void {
        const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(bytes);
    }
};
