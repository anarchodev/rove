// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
const std = @import("std");
const rove = @import("rove");
const Row = rove.Row;
const Collection = rove.Collection;
const Registry = rove.Registry;
const Entity = rove.Entity;
const linux = std.os.linux;
const posix = std.posix;

/// Get an SQE from `ring`. If the submission queue is full, flush
/// pending SQEs to the kernel and retry once. This is the hot path
/// for every SQE-prep site in rove-io — under burst load (many
/// writes/reads ready in one poll tick) a fixed-size SQ otherwise
/// returns `SubmissionQueueFull` mid-loop and crashes the worker.
fn getSqeOrSubmit(ring: *linux.IoUring) !*linux.io_uring_sqe {
    return ring.get_sqe() catch |err| switch (err) {
        error.SubmissionQueueFull => blk: {
            _ = try ring.submit();
            break :blk try ring.get_sqe();
        },
    };
}

// =============================================================================
// Component types
// =============================================================================

/// Cleanup context shared by Fd, ReadCycleEntity, and ReadResult
/// destructors. Stored on the Io struct, registered with registry via
/// setDeinitCtx. `buf_ring` / `buf_base` / `buf_size` / `buf_count`
/// let ReadResult.deinit return a kernel-held buffer to the ring when
/// its owning read entity is destroyed (e.g. via the cascade in
/// ReadCycleEntity.deinit). Without that path, every aborted-mid-recv
/// connection leaks its buffer permanently — drains the ring to zero
/// after a few thousand short-lived connections and the kernel
/// returns ENOBUFS for every subsequent recv.
pub const IoCleanupCtx = struct {
    ring: *linux.IoUring,
    max_connections: u32,
    reg: *Registry,
    buf_ring: *align(std.heap.page_size_min) linux.io_uring_buf_ring = undefined,
    buf_base: []u8 = undefined,
    buf_size: u32 = 0,
    buf_count: u16 = 0,
    /// Cumulative count of buffers returned via the deinit cascade.
    /// Mirrors `Io.recv_buffers_returned` for the regular drain path —
    /// kept separate so the source of returns is attributable in the
    /// diagnostic log.
    recv_buffers_returned_via_deinit: u64 = 0,
    /// Conns destroyed while still holding a live descriptor slot — i.e.
    /// something destroyed a conn entity without routing it through
    /// `conn_closing`. Should never move.
    fd_destroyed_live: u64 = 0,
};

/// Peer (remote) address of an accepted connection, resolved once at
/// accept time. Direct descriptors have no process fd to getpeername
/// on, and multishot accept's addr buffer is shared across
/// completions (batched accepts would mis-attribute clients) — so
/// the accept handler submits an IORING_OP_FIXED_FD_INSTALL and the
/// install CQE getpeername()s the materialized fd, fills this, and
/// closes it again. `valid` stays false until that CQE lands (a
/// request racing the window just has no peer identity) and forever
/// on client-direction connections.
pub const PeerAddr = struct {
    addr: std.net.Address = undefined,
    valid: bool = false,
};

pub const Fd = struct {
    fd: i32 = -1,

    pub const DeinitCtx = IoCleanupCtx;

    /// A connection reaches destruction through `conn_closing`, which posts
    /// the shutdown and close and clears `fd` — so on every legal path this
    /// sees -1 and does nothing.
    ///
    /// A live fd here means a conn was destroyed around the closing state.
    /// That is a programmer error, not an operating error, and the honest
    /// response is to stop: the descriptor leaks, the peer never observes a
    /// close, and — the part that actually decides it — a path that was
    /// supposed to be unreachable just ran, so nothing else it did can be
    /// trusted either. "It is only an fd" is an assumption about code we
    /// have just established we do not understand.
    ///
    /// Closing the socket instead would be worse than useless: it would hide
    /// the break, and the slot number may already have been reissued to a new
    /// accept, so the close would land on somebody else's connection.
    ///
    /// Teardown is not an exception. `shutdownAllConns` takes every remaining
    /// conn through the closing path before any collection is deinited, so
    /// the fds are already -1 when destruction reaches them. An invariant
    /// with a mode flag that switches it off is not an invariant — and that
    /// flag would have been held by the very layer whose destroys this
    /// exists to police.
    ///
    /// An explicit check and `abort`, not `std.debug.assert`, because the
    /// shipped binaries are ReleaseFast (`scripts/ops/build.sh`) where an
    /// assert compiles to nothing — the same reason the recv-buffer
    /// invariant in rove-h2 is written this way. Aborting is the one kind of
    /// work a destructor may do beyond its own memory: there is no ordering
    /// to get wrong and no re-entrancy to worry about when the process is
    /// ending.
    pub fn deinit(_: std.mem.Allocator, items: []Fd, ctx: *DeinitCtx) void {
        for (items) |item| {
            if (item.fd < 0) continue;
            ctx.fd_destroyed_live += 1;
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "\n================================================================\n" ++
                    "ROVE IO: conn destroyed while its fd ({d}) was still live.\n" ++
                    "  It bypassed `conn_closing`, so the socket was never shut down\n" ++
                    "  and the descriptor slot is leaked. A path that cannot be\n" ++
                    "  reached has been reached; the rest of its work is suspect.\n" ++
                    "================================================================\n",
                .{item.fd},
            ) catch buf[0..0];
            _ = posix.write(2, msg) catch {};
            std.process.abort();
        }
    }
};

pub const ConnEntity = struct { entity: Entity = Entity.nil };

pub const ReadResult = struct {
    result: i32 = 0,
    data: ?[*]u8 = null,
    buf_id: u16 = 0,

    pub const DeinitCtx = IoCleanupCtx;

    /// Return the kernel-held buffer (if any) to the ring when the
    /// read entity is destroyed. Without this hook, the cascade in
    /// `ReadCycleEntity.deinit` (which runs `destroyImmediate` on the
    /// linked read entity when a conn dies) leaks every buffer that
    /// was attached to a completed recv but had not yet flowed
    /// through `processReadIn`. At workloads with many short-lived
    /// connections (e.g. xargs + curl publishing many releases) the
    /// leak drains the registered buffer ring to zero and recv starts
    /// returning ENOBUFS even though the connection count is tiny.
    pub fn deinit(_: std.mem.Allocator, items: []ReadResult, ctx: *DeinitCtx) void {
        var armed: u16 = 0;
        const mask = linux.IoUring.buf_ring_mask(ctx.buf_count);
        for (items) |item| {
            if (item.data == null) continue;
            const pos = @as(usize, ctx.buf_size) * item.buf_id;
            linux.IoUring.buf_ring_add(
                ctx.buf_ring,
                ctx.buf_base[pos .. pos + ctx.buf_size],
                item.buf_id,
                mask,
                armed,
            );
            armed += 1;
        }
        if (armed > 0) {
            linux.IoUring.buf_ring_advance(ctx.buf_ring, armed);
            ctx.recv_buffers_returned_via_deinit += armed;
        }
    }
};

pub const WriteBuf = struct {
    data: [*]const u8 = undefined,
    len: u32 = 0,
    offset: u32 = 0,

    pub fn deinit(allocator: std.mem.Allocator, items: []WriteBuf) void {
        for (items) |*item| {
            if (item.len > 0) {
                allocator.free(@constCast(item.data[0..item.len]));
            }
            item.len = 0;
        }
    }
};

pub const IoResult = struct { err: i32 = 0 };

/// Target address for an outgoing `prep_connect`. The address is
/// **heap-owned** — stored via a pointer rather than inline — so
/// that `&addr.any` can be handed directly to io_uring and survive
/// any rove swap-remove that reshuffles the source collection's
/// column storage.
///
/// This is the same shape as `WriteBuf` (whose `data` field is a
/// pointer into heap memory): components that hold buffers the
/// kernel reads asynchronously MUST store pointers, not values —
/// see rove-library principle "Kernel-Visible Buffers Live Behind
/// Pointers." Taking `&column_field` and handing it to io_uring
/// would be invalidated by swap-remove the instant the owning
/// entity moves collections.
///
/// `deinit` frees the allocation. Rove calls it when the entity is
/// destroyed from a collection containing `ConnectAddr`, or when
/// the component is stripped during a `moveStrip` transition (e.g.
/// the `_connect_pending → connections` strip after a successful
/// connect).
pub const ConnectAddr = struct {
    addr: *std.net.Address,

    pub fn deinit(allocator: std.mem.Allocator, items: []ConnectAddr) void {
        for (items) |it| allocator.destroy(it.addr);
    }
};

/// Links a connection to its read-cycle entity. When the connection
/// is destroyed, the read-cycle entity is also destroyed.
pub const ReadCycleEntity = struct {
    entity: Entity = Entity.nil,

    pub const DeinitCtx = IoCleanupCtx;

    pub fn deinit(_: std.mem.Allocator, items: []ReadCycleEntity, ctx: *DeinitCtx) void {
        for (items) |item| {
            if (!item.entity.isNil() and !ctx.reg.isStale(item.entity)) {
                ctx.reg.destroyImmediate(item.entity) catch {};
            }
        }
    }
};

// =============================================================================
// Base row types
// =============================================================================

fn monotonicNs() u64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
    return @intCast(ts.sec * std.time.ns_per_s + ts.nsec);
}

/// Per-connection teardown progress, carried only while the conn sits in
/// `conn_closing`. Absent from every live conn row, so a conn acquires it
/// by moving into the closing state and it cannot be consulted before then.
pub const ClosingState = struct {
    /// `shutdown` + `close_direct` have been posted. Set once — posting a
    /// second close for the same descriptor slot would free a slot the
    /// kernel may already have handed to a new accept.
    shutdown_posted: bool = false,
    /// Monotonic deadline for the armed recv to complete. A peer that
    /// never finishes closing must not pin a slot forever, so past this
    /// the conn is retired with the recv still outstanding — the stale
    /// completion then reclaims its buffer in `handleCqe`.
    deadline_ns: u64 = 0,
};

/// io's collections, as data. An upper layer merges this with its own set
/// to build ONE collection enum over the shared registry, so an entity's
/// collection can be read from `collection_ids` rather than tested against
/// each candidate in turn.
pub const CollRef = struct {
    name: [:0]const u8,
    /// Registered only when the instance has the connect (client) half.
    connect_only: bool = false,
};

pub const COLLECTIONS = [_]CollRef{
    .{ .name = "connections" },
    .{ .name = "conn_closing" },
    .{ .name = "read_results" },
    .{ .name = "write_results" },
    .{ .name = "read_in" },
    .{ .name = "write_in" },
    .{ .name = "_read_pending" },
    .{ .name = "_write_pending" },
    .{ .name = "connect_in", .connect_only = true },
    .{ .name = "connect_errors", .connect_only = true },
    .{ .name = "_connect_socket_pending", .connect_only = true },
    .{ .name = "_connect_pending", .connect_only = true },
};

pub const ConnectionBaseRow = Row(&.{ Fd, ReadCycleEntity, PeerAddr });
/// The closing row is the connection row plus `ClosingState`, so a move in
/// from any live conn collection is an ordinary widening — no components are
/// dropped, and nothing is destroyed by the transition itself.
pub const ClosingBaseRow = ConnectionBaseRow.merge(Row(&.{ClosingState}));
pub const ReadBaseRow = Row(&.{ ConnEntity, ReadResult });
pub const WriteInBaseRow = Row(&.{ ConnEntity, WriteBuf });
pub const WriteResultBaseRow = Row(&.{ ConnEntity, WriteBuf, IoResult });
// PeerAddr rides along so the connection row stays a subset of the
// connect rows (the `_connect_pending → connections` strip requires
// it); client-direction conns just keep it invalid.
const ConnectInBaseRow = Row(&.{ ConnectAddr, Fd, IoResult, ReadCycleEntity, PeerAddr });
const ConnectErrorBaseRow = Row(&.{ ConnectAddr, Fd, IoResult, PeerAddr });

// =============================================================================
// CQE user_data encoding
// =============================================================================

const ACCEPT_SENTINEL: u64 = std.math.maxInt(u64);
const INTERNAL_SENTINEL: u64 = std.math.maxInt(u64) - 1;
const TIMEOUT_SENTINEL: u64 = std.math.maxInt(u64) - 2;

fn encodeEntity(entity: Entity) u64 {
    return @as(u64, entity.generation) << 32 | @as(u64, entity.index);
}

fn decodeEntity(user_data: u64) Entity {
    return .{
        .index = @truncate(user_data),
        .generation = @truncate(user_data >> 32),
    };
}

// =============================================================================
// Io type
// =============================================================================

pub const Options = struct {
    connection_row: type = Row(&.{}),
    read_row: type = Row(&.{}),
    write_row: type = Row(&.{}),
    connect: bool = false,
    /// First registry collection id for this instance. io's collections
    /// take `[id_base, id_base + COLLECTIONS.len)` in declaration order
    /// (skipping the connect-only ones when `connect` is false), so the
    /// layer above can build ONE enum whose values match these ids.
    id_base: u8 = 1,
};

pub const IoOptions = struct {
    ring_entries: u16 = 4096,
    buf_count: u16 = 256,
    buf_size: u32 = 4096,
    max_connections: u32 = 1024,
    ring_params: ?*linux.io_uring_params = null,
    listen_backlog: u31 = 128,
    /// Set `SO_REUSEPORT` on the listen socket. Required for the
    /// shift-js shared-nothing multi-worker model: N workers in one
    /// process each call `Io.create` with the same bind address and
    /// the kernel hashes incoming connections across their per-thread
    /// listen sockets. Without this, the second `bind(2)` fails with
    /// EADDRINUSE.
    reuseport: bool = false,
};

pub fn Io(comptime opts: Options) type {
    const conn_row = ConnectionBaseRow.merge(opts.connection_row);
    const read_row = ReadBaseRow.merge(opts.read_row);
    const write_in_row = WriteInBaseRow.merge(opts.write_row);
    const write_result_row = WriteResultBaseRow.merge(opts.write_row);
    const read_pending_row = read_row;
    const write_pending_row = write_in_row;

    const connect_in_row = ConnectInBaseRow.merge(opts.connection_row);
    const connect_error_row = ConnectErrorBaseRow.merge(opts.connection_row);
    const connect_socket_pending_row = connect_in_row;
    const connect_pending_row = connect_in_row;

    const has_connect = opts.connect;

    // Collection types
    const ConnColl = Collection(conn_row, .{});
    const ClosingColl = Collection(ClosingBaseRow.merge(opts.connection_row), .{});
    const ReadResultColl = Collection(read_row, .{});
    const WriteResultColl = Collection(write_result_row, .{});
    const ReadInColl = Collection(read_row, .{});
    const WriteInColl = Collection(write_in_row, .{});
    const ReadPendingColl = Collection(read_pending_row, .{});
    const WritePendingColl = Collection(write_pending_row, .{});

    const ConnectInColl = if (has_connect) Collection(connect_in_row, .{}) else void;
    const ConnectErrorColl = if (has_connect) Collection(connect_error_row, .{}) else void;
    const ConnectSocketPendingColl = if (has_connect) Collection(connect_socket_pending_row, .{}) else void;
    const ConnectPendingColl = if (has_connect) Collection(connect_pending_row, .{}) else void;

    return struct {
        const Self = @This();

        // Public collection types (for external access to row types)
        pub const ConnectionRow = conn_row;
        pub const ReadRow = read_row;

        // Collections
        connections: ConnColl,
        /// Connections on their way out. A conn ends by moving here —
        /// never by `reg.destroy` from an upper layer — so the layer that
        /// created it is the layer that releases its descriptor slot, and
        /// so the ending is a state the loop can see, count, and order
        /// rather than a destructor firing inside `flush`.
        ///
        /// Unprefixed on purpose: this is a seam other code moves entities
        /// into, like `read_in` / `write_in`, not internal bookkeeping.
        conn_closing: ClosingColl,
        read_results: ReadResultColl,
        write_results: WriteResultColl,
        read_in: ReadInColl,
        write_in: WriteInColl,
        _read_pending: ReadPendingColl,
        _write_pending: WritePendingColl,

        connect_in: ConnectInColl,
        connect_errors: ConnectErrorColl,
        _connect_socket_pending: ConnectSocketPendingColl,
        _connect_pending: ConnectPendingColl,

        // io_uring state
        ring: linux.IoUring,
        buf_ring: *align(std.heap.page_size_min) linux.io_uring_buf_ring,
        buf_base: []u8,
        buf_size: u32,
        buf_count: u16,
        listen_fd: posix.socket_t,
        max_connections: u32,

        cleanup_ctx: IoCleanupCtx,

        /// Optional FD resolver. If set, used to look up the Fd for a connection
        /// entity — needed when a library (like rove-h2) moves connection entities
        /// out of `self.connections` into its own collections. Defaults to looking
        /// up in `self.connections`.
        fd_resolver: ?*const fn (ctx: *anyopaque, entity: Entity) ?*Fd = null,
        fd_resolver_ctx: ?*anyopaque = null,
        peer_resolver: ?*const fn (ctx: *anyopaque, entity: Entity) ?*PeerAddr = null,
        peer_resolver_ctx: ?*anyopaque = null,

        /// Optional callback that returns the number of conn entities
        /// the upper layer (e.g. rove-h2) is currently holding outside
        /// `self.connections` — for h2 that's
        /// `_conn_tls_handshake + _conn_active`. `handleAccept` adds
        /// the result to `self.connections.len` to estimate the
        /// total in-flight conn count for admission control. When
        /// unset (or returns 0) the budget check uses only
        /// `self.connections.len`.
        extra_conns_fn: ?*const fn (ctx: *anyopaque) usize = null,
        extra_conns_ctx: ?*anyopaque = null,

        /// Admission-control telemetry. Friendly back-pressure when
        /// the conn count approaches `buf_count` — we refuse the
        /// accept rather than letting the conn consume a buffer the
        /// kernel doesn't have. See the warning surfacing in
        /// `handleAccept`.
        admission_denied_total: u64 = 0,
        admission_denied_logged: bool = false,
        admission_denied_last_logged_decade: u64 = 0,

        /// DIAG (ENOBUFS-at-low-conn-count investigation):
        /// per-process counters for the buffer-ring balance. The
        /// invariant: at any point in time, the kernel-held buffer
        /// count must be < `buf_count`. If `recv_completions_with_data`
        /// minus `recv_buffers_returned` ever approaches `buf_count`,
        /// the ring's running out for a real reason. If ENOBUFS
        /// fires while that delta is small, the kernel and the ring
        /// state disagree.
        recv_completions_with_data: u64 = 0,
        recv_buffers_returned: u64 = 0,
        /// Buffers reclaimed from a completion whose entity had already
        /// been destroyed. Counted apart from `recv_buffers_returned` so
        /// the source of a return stays attributable, the same way
        /// `IoCleanupCtx.recv_buffers_returned_via_deinit` is.
        recv_buffers_returned_via_stale: u64 = 0,

        /// Connections retired out of `conn_closing`, and how many of those
        /// gave up on the recv rather than seeing it complete. A rising
        /// second number means peers are not finishing their close — the
        /// grace window, not the teardown, is what to look at.
        conn_closing_retired: u64 = 0,
        conn_closing_deadline_expired: u64 = 0,

        reg: *Registry,
        allocator: std.mem.Allocator,

        const BUF_GROUP_ID: u16 = 0;

        /// How long a closing conn waits for its armed recv to complete
        /// before being retired anyway. Bounded because a peer that never
        /// finishes closing must not pin a descriptor slot; the stale
        /// completion that arrives afterwards still returns its buffer.
        const CLOSE_RECV_GRACE_NS: u64 = 2 * std.time.ns_per_s;

        /// Look up the Fd for a connection entity. Uses the custom resolver if
        /// set, otherwise searches `self.connections` directly.
        pub fn getFd(self: *Self, entity: Entity) ?*Fd {
            if (self.fd_resolver) |resolver| {
                return resolver(self.fd_resolver_ctx.?, entity);
            }
            return self.reg.getAny(entity, .{ &self.connections, &self.conn_closing }, Fd) catch null;
        }

        /// Register an external FD resolver. Used by rove-h2 to search its own
        /// connection collections (_conn_active, _conn_tls_handshake).
        pub fn setFdResolver(self: *Self, ctx: *anyopaque, resolver: *const fn (*anyopaque, Entity) ?*Fd) void {
            self.fd_resolver_ctx = ctx;
            self.fd_resolver = resolver;
        }

        /// PeerAddr mirror of `getFd`: the conn entity may have moved
        /// into an upper-layer collection (rove-h2's) by the time the
        /// fixed-fd-install CQE lands, so resolution goes through the
        /// same external-resolver hook.
        pub fn getPeerAddr(self: *Self, entity: Entity) ?*PeerAddr {
            if (self.peer_resolver) |resolver| {
                return resolver(self.peer_resolver_ctx.?, entity);
            }
            return self.reg.getAny(entity, .{ &self.connections, &self.conn_closing }, PeerAddr) catch null;
        }

        pub fn setPeerResolver(self: *Self, ctx: *anyopaque, resolver: *const fn (*anyopaque, Entity) ?*PeerAddr) void {
            self.peer_resolver_ctx = ctx;
            self.peer_resolver = resolver;
        }

        /// Register a callback returning the count of conn entities the
        /// upper layer holds outside `self.connections`. Used by
        /// `handleAccept`'s admission-control check to estimate total
        /// in-flight conn count vs. `buf_count`.
        pub fn setExtraConnsFn(self: *Self, ctx: *anyopaque, f: *const fn (*anyopaque) usize) void {
            self.extra_conns_ctx = ctx;
            self.extra_conns_fn = f;
        }

        pub fn create(reg: *Registry, allocator: std.mem.Allocator, addr: std.net.Address, io_opts: IoOptions) !*Self {
            var ring = if (io_opts.ring_params) |params|
                try linux.IoUring.init_params(io_opts.ring_entries, params)
            else
                try linux.IoUring.init(io_opts.ring_entries, 0);
            errdefer ring.deinit();

            {
                const empty_fds = try allocator.alloc(posix.fd_t, io_opts.max_connections);
                defer allocator.free(empty_fds);
                @memset(empty_fds, -1);
                try ring.register_files(empty_fds);
            }

            const buf_base = try allocator.alloc(u8, @as(usize, io_opts.buf_count) * io_opts.buf_size);
            errdefer allocator.free(buf_base);

            const br = try linux.IoUring.setup_buf_ring(ring.fd, io_opts.buf_count, BUF_GROUP_ID, .{ .inc = false });
            linux.IoUring.buf_ring_init(br);
            const mask = linux.IoUring.buf_ring_mask(io_opts.buf_count);
            for (0..io_opts.buf_count) |i| {
                const pos = @as(usize, io_opts.buf_size) * i;
                linux.IoUring.buf_ring_add(br, buf_base[pos .. pos + io_opts.buf_size], @intCast(i), mask, @intCast(i));
            }
            linux.IoUring.buf_ring_advance(br, io_opts.buf_count);

            const listen_fd = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
            errdefer posix.close(listen_fd);

            try posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            if (io_opts.reuseport) {
                try posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            }
            // Set TCP_NODELAY on the listen socket; Linux inherits it to
            // accepted sockets. Doing it synchronously here removes a race
            // with the async `setsockopt` SQE in `handleAccept`: with a
            // fast allocator, the first send can land before the kernel
            // has applied NODELAY, and Nagle + delayed-ACK stall every
            // request-response round trip by ~40 ms. The SQE in
            // `handleAccept` stays as belt-and-suspenders (and for the
            // rare case where the listen socket's NODELAY didn't stick).
            try posix.setsockopt(listen_fd, posix.IPPROTO.TCP, linux.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
            try posix.bind(listen_fd, &addr.any, addr.getOsSockLen());
            try posix.listen(listen_fd, io_opts.listen_backlog);

            {
                const sqe = try ring.get_sqe();
                sqe.prep_multishot_accept_direct(listen_fd, null, null, 0);
                sqe.user_data = ACCEPT_SENTINEL;
            }

            const self = try allocator.create(Self);
            self.* = .{
                .connections = try ConnColl.init(allocator),
                .conn_closing = try ClosingColl.init(allocator),
                .read_results = try ReadResultColl.init(allocator),
                .write_results = try WriteResultColl.init(allocator),
                .read_in = try ReadInColl.init(allocator),
                .write_in = try WriteInColl.init(allocator),
                ._read_pending = try ReadPendingColl.init(allocator),
                ._write_pending = try WritePendingColl.init(allocator),
                .connect_in = if (has_connect) try ConnectInColl.init(allocator) else {},
                .connect_errors = if (has_connect) try ConnectErrorColl.init(allocator) else {},
                ._connect_socket_pending = if (has_connect) try ConnectSocketPendingColl.init(allocator) else {},
                ._connect_pending = if (has_connect) try ConnectPendingColl.init(allocator) else {},
                .ring = ring,
                .buf_ring = br,
                .buf_base = buf_base,
                .buf_size = io_opts.buf_size,
                .buf_count = io_opts.buf_count,
                .listen_fd = listen_fd,
                .max_connections = io_opts.max_connections,
                .cleanup_ctx = .{
                    .ring = undefined, // set below
                    .max_connections = io_opts.max_connections,
                    .reg = reg,
                    .buf_ring = br,
                    .buf_base = buf_base,
                    .buf_size = io_opts.buf_size,
                    .buf_count = io_opts.buf_count,
                },
                .reg = reg,
                .allocator = allocator,
            };

            // Set ring pointer now that self is at its final heap location
            self.cleanup_ctx.ring = &self.ring;

            // Register collections with registry
            comptime var next_id: u8 = 0;
            inline for (COLLECTIONS) |c| {
                if (c.connect_only and !has_connect) continue;
                reg.registerCollection(&@field(self, c.name), opts.id_base + next_id);
                next_id += 1;
            }

            // Register deinit contexts. `ReadResult.deinit` returns
            // the buffer (if any) to the registered ring when its
            // owning read entity is destroyed — the fix for the
            // leak that drained the ring at xargs+curl workloads.
            reg.setDeinitCtx(Fd, &self.cleanup_ctx);
            reg.setDeinitCtx(ReadCycleEntity, &self.cleanup_ctx);
            reg.setDeinitCtx(ReadResult, &self.cleanup_ctx);

            return self;
        }

        /// End every connection still live, through the same closing path
        /// every other connection takes: move it in, post its shutdown and
        /// close, give up its slot. Afterwards no conn holds a live fd, so
        /// destruction proceeds without `Fd.deinit` needing an exception for
        /// teardown.
        ///
        /// An upper layer holding conn collections of its own must close
        /// those first — rove-h2 does, at the top of its `destroy`.
        ///
        /// The submit is the point. Without it the shutdown and close SQEs
        /// sit in the submission queue until `ring.deinit` discards them,
        /// which is what made teardown's graceful close a fiction: the peer
        /// got a reset, or nothing at all. Completions are not waited for —
        /// the kernel has the ops, and blocking teardown to watch them land
        /// buys the peer nothing it does not already have.
        pub fn shutdownAllConns(self: *Self) void {
            for (self.connections.entitySlice()) |ent| {
                if (self.reg.isStale(ent)) continue;
                if (self.reg.isMoving(ent)) continue;
                self.reg.move(ent, &self.connections, &self.conn_closing) catch continue;
            }
            self.reg.flush() catch {};
            self.processConnClosing() catch {};
            self.reg.flush() catch {};
            _ = self.ring.submit() catch {};
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            self.shutdownAllConns();
            self.connections.deinit();
            self.conn_closing.deinit();
            self.read_results.deinit();
            self.write_results.deinit();
            self.read_in.deinit();
            self.write_in.deinit();
            self._read_pending.deinit();
            self._write_pending.deinit();
            if (has_connect) {
                self.connect_in.deinit();
                self.connect_errors.deinit();
                self._connect_socket_pending.deinit();
                self._connect_pending.deinit();
            }
            linux.IoUring.free_buf_ring(self.ring.fd, self.buf_ring, self.buf_count, BUF_GROUP_ID);
            allocator.free(self.buf_base);
            posix.close(self.listen_fd);
            self.ring.deinit();
            allocator.destroy(self);
        }

        pub fn poll(self: *Self, min_complete: u32) !u32 {
            // Phase 0: Retire connections that finished closing.
            try self.processConnClosing();

            // Phase 1: Process user inputs (deferred moves)
            try self.processWriteIn();
            try self.processReadIn();
            if (has_connect) try self.processConnectIn();

            // Phase 2: Flush deferred moves
            try self.reg.flush();

            // Phase 3: Submit and wait
            _ = try self.ring.submit_and_wait(min_complete);

            // Phase 4: Drain CQEs (immediate ops)
            var cqe_buf: [256]linux.io_uring_cqe = undefined;
            var events: u32 = 0;
            while (true) {
                const count = try self.ring.copy_cqes(&cqe_buf, 0);
                if (count == 0) break;
                for (cqe_buf[0..count]) |cqe| {
                    try self.handleCqe(cqe);
                    events += 1;
                }
            }

            return events;
        }

        /// Like `poll(1)` but with a wall-clock upper bound on how long
        /// `submit_and_wait` will block. Submits a one-shot timeout SQE
        /// that produces a CQE after `timeout_ns` nanoseconds; the
        /// timeout CQE is recognized by `handleCqe` and discarded so it
        /// doesn't leak into the user's event count.
        ///
        /// Use this from outer poll loops that have **external** state
        /// needing periodic attention (parked entities waiting on a
        /// raft commit, timers, work fed in from another thread).
        /// Without a timeout you'd either block forever (`poll(1)`) or
        /// burn CPU spinning (`poll(0)` + `sleep`). With a timeout you
        /// get bounded latency on external state AND immediate wake on
        /// real I/O. Per the rove-library "Poll Blocking Is the
        /// Caller's Call" rule — the library still doesn't decide,
        /// it just gives you a richer primitive to express the choice.
        pub fn pollWithTimeout(self: *Self, timeout_ns: u64) !u32 {
            try self.processConnClosing();
            try self.processWriteIn();
            try self.processReadIn();
            if (has_connect) try self.processConnectIn();
            try self.reg.flush();

            const ts: linux.kernel_timespec = .{
                .sec = @intCast(timeout_ns / std.time.ns_per_s),
                .nsec = @intCast(timeout_ns % std.time.ns_per_s),
            };
            // count=0 means "fire only on time expiration"; flags=0 is
            // a relative timeout. The CQE arrives with res=-ETIME and
            // user_data=TIMEOUT_SENTINEL, which handleCqe drops.
            _ = try self.ring.timeout(TIMEOUT_SENTINEL, &ts, 0, 0);

            _ = try self.ring.submit_and_wait(1);

            var cqe_buf: [256]linux.io_uring_cqe = undefined;
            var events: u32 = 0;
            while (true) {
                const count = try self.ring.copy_cqes(&cqe_buf, 0);
                if (count == 0) break;
                for (cqe_buf[0..count]) |cqe| {
                    try self.handleCqe(cqe);
                    if (cqe.user_data != TIMEOUT_SENTINEL) events += 1;
                }
            }

            return events;
        }

        // =============================================================
        // Input processing (deferred ops, forward iteration)
        // =============================================================

        /// Own the teardown of every connection an upper layer handed over.
        ///
        /// The sequence is the reason this is a state and not a destructor.
        /// A destructor is synchronous: it can post the shutdown, but it
        /// cannot then WAIT for the recv that shutdown completes, so the
        /// entity dies while a completion is still in flight against it.
        /// Here the conn simply stays in `conn_closing` until its read cycle
        /// is quiet, and only then is retired.
        ///
        /// GOAWAY is deliberately not part of this. It is nghttp2's, and io
        /// knows nothing of sessions — so the upper layer sends it and drains
        /// it BEFORE handing the conn over. Arriving here means "the protocol
        /// is finished with this connection; take the socket down."
        fn processConnClosing(self: *Self) !void {
            const now = monotonicNs();
            const entities = self.conn_closing.entitySlice();
            const states = self.conn_closing.column(ClosingState);
            const fds = self.conn_closing.column(Fd);
            const cycles = self.conn_closing.column(ReadCycleEntity);

            for (entities, states, fds, cycles) |ent, *st, *fd, cycle| {
                if (self.reg.isStale(ent)) continue;
                if (self.reg.isMoving(ent)) continue;

                if (!st.shutdown_posted) {
                    st.shutdown_posted = true;
                    st.deadline_ns = now + CLOSE_RECV_GRACE_NS;
                    if (fd.fd >= 0 and @as(u32, @intCast(fd.fd)) < self.max_connections) {
                        // Shut down before freeing the slot. `close_direct`
                        // alone is not enough: a conn torn down with a recv
                        // still armed keeps the socket alive, because the
                        // slot reference the recv holds outlives the close —
                        // so the peer never observes a close (h2spec
                        // http2/5.4.1). And a bare close with unread RX bytes
                        // emits RST rather than a clean FIN (h2spec generic/5,
                        // http2/7). SHUT_RDWR sends the FIN and completes the
                        // pending recv, dropping that reference, so the
                        // hard-linked close then frees the slot. Hard-link,
                        // not soft, so the close still runs when shutdown
                        // reports the socket already gone (ENOTCONN after the
                        // peer's own FIN).
                        const sh = try getSqeOrSubmit(&self.ring);
                        sh.prep_shutdown(@intCast(fd.fd), linux.SHUT.RDWR);
                        sh.flags |= linux.IOSQE_FIXED_FILE | linux.IOSQE_IO_HARDLINK;
                        sh.user_data = INTERNAL_SENTINEL;

                        const cl = try getSqeOrSubmit(&self.ring);
                        cl.prep_close_direct(@intCast(fd.fd));
                        cl.user_data = INTERNAL_SENTINEL;

                        // The slot is spoken for. Clearing it here is what
                        // makes `Fd.deinit` an assertion rather than a second
                        // close of a descriptor the kernel may already have
                        // reissued to a new accept.
                        fd.fd = -1;
                    }
                    continue;
                }

                // Wait for the armed recv that the shutdown completes. Its
                // buffer comes back through the ordinary path, and the
                // entity outlives the completion that names it.
                const recv_armed = !cycle.entity.isNil() and
                    !self.reg.isStale(cycle.entity) and
                    self.reg.isInCollection(cycle.entity, &self._read_pending);
                if (recv_armed and now < st.deadline_ns) continue;

                self.conn_closing_retired += 1;
                if (recv_armed) self.conn_closing_deadline_expired += 1;
                try self.reg.destroy(ent);
            }
        }

        fn processWriteIn(self: *Self) !void {
            const entities = self.write_in.entitySlice();
            const conn_ents = self.write_in.column(ConnEntity);
            const wbufs = self.write_in.column(WriteBuf);

            for (entities, conn_ents, wbufs) |ent, conn_ent, wb| {
                if (self.reg.isStale(conn_ent.entity)) {
                    try self.reg.destroy(ent);
                    continue;
                }

                // A conn in `conn_closing` still resolves — it has to, so
                // an in-flight completion can find it — but it takes no new
                // work. Arming a send here would race the teardown for the
                // same descriptor slot.
                if (self.reg.isInCollection(conn_ent.entity, &self.conn_closing)) {
                    try self.reg.destroy(ent);
                    continue;
                }

                const conn_fd = self.getFd(conn_ent.entity) orelse {
                    try self.reg.destroy(ent);
                    continue;
                };

                const sqe = try getSqeOrSubmit(&self.ring);
                sqe.prep_send(conn_fd.fd, @constCast(wb.data)[wb.offset..wb.len], 0);
                sqe.flags |= linux.IOSQE_FIXED_FILE;
                sqe.user_data = encodeEntity(ent);

                try self.reg.move(ent, &self.write_in, &self._write_pending);
            }
        }

        fn processReadIn(self: *Self) !void {
            const entities = self.read_in.entitySlice();
            const conn_ents = self.read_in.column(ConnEntity);
            const results = self.read_in.column(ReadResult);
            const mask = linux.IoUring.buf_ring_mask(self.buf_count);
            var armed: u16 = 0;

            for (entities, conn_ents, results) |ent, conn_ent, *rr| {
                if (self.reg.isStale(conn_ent.entity)) {
                    if (rr.data != null) {
                        self.returnBufferToRing(rr.buf_id, mask, armed);
                        armed += 1;
                        // Clear so ReadResult.deinit (fired by the destroy below)
                        // sees data==null and does NOT return this buffer a
                        // SECOND time. A double buf_ring_add over-advances the
                        // ring's producer tail, shrinks the distinct-buffer pool,
                        // and manifests as recv ENOBUFS → the front crash-loop.
                        // Same return-then-clear the healthy path uses (below).
                        rr.* = .{};
                    }
                    try self.reg.destroy(ent);
                    continue;
                }

                // A closing conn takes no new recv. Return any buffer this
                // cycle is still holding, then drop the read entity — the
                // same return-then-clear the isStale branch above does, and
                // for the same double-return reason.
                if (self.reg.isInCollection(conn_ent.entity, &self.conn_closing)) {
                    if (rr.data != null) {
                        self.returnBufferToRing(rr.buf_id, mask, armed);
                        armed += 1;
                        rr.* = .{};
                    }
                    try self.reg.destroy(ent);
                    continue;
                }

                const conn_fd = self.getFd(conn_ent.entity) orelse {
                    if (rr.data != null) {
                        self.returnBufferToRing(rr.buf_id, mask, armed);
                        armed += 1;
                        // Clear so destroy's ReadResult.deinit doesn't return
                        // this buffer a second time (see the isStale branch).
                        rr.* = .{};
                    }
                    try self.reg.destroy(ent);
                    continue;
                };

                if (rr.data != null) {
                    self.returnBufferToRing(rr.buf_id, mask, armed);
                    armed += 1;
                }

                rr.* = .{};

                try self.armRecv(ent, conn_fd.fd);
                try self.reg.move(ent, &self.read_in, &self._read_pending);
            }

            if (armed > 0) {
                linux.IoUring.buf_ring_advance(self.buf_ring, armed);
                self.recv_buffers_returned += armed;
            }
        }

        fn processConnectIn(self: *Self) !void {
            if (!has_connect) return;

            const entities = self.connect_in.entitySlice();

            for (entities) |ent| {
                const sqe = try getSqeOrSubmit(&self.ring);
                sqe.prep_socket_direct_alloc(posix.AF.INET, posix.SOCK.STREAM, 0, 0);
                sqe.user_data = encodeEntity(ent);

                try self.reg.move(ent, &self.connect_in, &self._connect_socket_pending);
            }
        }

        // =============================================================
        // CQE handlers
        // =============================================================

        fn handleCqe(self: *Self, cqe: linux.io_uring_cqe) !void {
            if (cqe.user_data == INTERNAL_SENTINEL) return;
            if (cqe.user_data == TIMEOUT_SENTINEL) return;
            if (cqe.user_data == ACCEPT_SENTINEL) {
                try self.handleAccept(cqe);
                return;
            }

            const entity = decodeEntity(cqe.user_data);
            if (self.reg.isStale(entity)) {
                // The op outlived its entity. A recv that completed with
                // data still consumed a registered buffer, and this is the
                // last mention of it — dropping the completion here without
                // returning it removes that buffer from the pool for the
                // life of the process. The ring then runs dry under
                // connection churn and recv answers ENOBUFS at a connection
                // count nowhere near the limit.
                self.reclaimStaleBuffer(cqe);
                return;
            }

            if (self.reg.isInCollection(entity, &self._read_pending)) {
                try self.handleRecv(entity, cqe);
                return;
            }
            if (self.reg.isInCollection(entity, &self._write_pending)) {
                try self.handleSend(entity, cqe);
                return;
            }
            if (has_connect) {
                if (self.reg.isInCollection(entity, &self._connect_socket_pending)) {
                    try self.handleConnectSocket(entity, cqe);
                    return;
                }
                if (self.reg.isInCollection(entity, &self._connect_pending)) {
                    try self.handleConnect(entity, cqe);
                    return;
                }
            }
            // A conn-entity CQE is the accept-time fixed-fd install
            // (the only op posted with a conn entity as user_data).
            // The conn may already live in an upper-layer collection —
            // resolve through the peer hook, not self.connections.
            if (self.getPeerAddr(entity)) |pa| {
                handlePeerInstall(pa, cqe);
                return;
            }
            return error.UnexpectedEntityCollection;
        }

        /// Fixed-fd-install CQE: `res` is a real process fd for the
        /// accepted socket. getpeername it, record, close. Failure at
        /// any step just leaves the conn without a peer identity.
        fn handlePeerInstall(pa: *PeerAddr, cqe: linux.io_uring_cqe) void {
            if (cqe.res < 0) return;
            const real_fd: posix.fd_t = @intCast(cqe.res);
            defer posix.close(real_fd);
            var storage: posix.sockaddr.storage align(4) = undefined;
            var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            posix.getpeername(real_fd, @ptrCast(&storage), &len) catch return;
            pa.* = .{ .addr = std.net.Address.initPosix(@ptrCast(&storage)), .valid = true };
        }

        fn handleAccept(self: *Self, cqe: linux.io_uring_cqe) !void {
            if (cqe.flags & linux.IORING_CQE_F_MORE == 0) {
                const sqe = try getSqeOrSubmit(&self.ring);
                sqe.prep_multishot_accept_direct(self.listen_fd, null, null, 0);
                sqe.user_data = ACCEPT_SENTINEL;
            }

            if (cqe.res < 0) return error.AcceptFailed;

            const file_slot: u32 = @intCast(cqe.res);
            if (file_slot >= self.max_connections) return error.FileSlotOutOfRange;

            // Admission control: if the in-flight conn count is close
            // to `buf_count`, refuse the connection by closing the
            // file slot immediately. Each conn ultimately holds at
            // most one registered buffer for its armed recv; accepting
            // past the pool's headroom guarantees recv ENOBUFS, which
            // the upper layer treats as transient (so requests
            // succeed eventually) but the back-pressure is real. We
            // surface it loudly to the operator (warning on first
            // denial + every 10k thereafter) — the right answer is
            // either bumping `buf_count` or, under attack, putting
            // a CDN/edge in front. Reserved headroom: 12.5% of
            // `buf_count`.
            // A conn that is closing still owns its descriptor slot until
            // the teardown completes, so it counts against the budget just
            // like a live one. Admitting into a slot that is not free yet is
            // how the pool goes negative under churn.
            const io_conns = self.connections.entitySlice().len +
                self.conn_closing.entitySlice().len;
            const upper_conns: usize = if (self.extra_conns_fn) |f|
                f(self.extra_conns_ctx.?)
            else
                0;
            const total_conns = io_conns + upper_conns;
            const budget: usize = @as(usize, self.buf_count) - (@as(usize, self.buf_count) / 8);
            if (total_conns >= budget) {
                const close_sqe = try getSqeOrSubmit(&self.ring);
                close_sqe.prep_close_direct(file_slot);
                close_sqe.user_data = INTERNAL_SENTINEL;

                self.admission_denied_total += 1;
                const decade = self.admission_denied_total / 10_000;
                if (!self.admission_denied_logged or decade != self.admission_denied_last_logged_decade) {
                    self.admission_denied_logged = true;
                    self.admission_denied_last_logged_decade = decade;
                    std.log.warn(
                        "rove-io: admission denied — in-flight conns ({d}) ≥ {d}/{d} budget (total denials: {d}). Bump `buf_count` or place a CDN/edge in front for sustained burst load.",
                        .{ total_conns, budget, self.buf_count, self.admission_denied_total },
                    );
                }
                return;
            }

            const nodelay_sqe = try self.ring.setsockopt(
                INTERNAL_SENTINEL,
                @intCast(file_slot),
                posix.IPPROTO.TCP,
                linux.TCP.NODELAY,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            nodelay_sqe.flags |= linux.IOSQE_FIXED_FILE;

            const conn = try self.reg.create(&self.connections);
            try self.reg.set(conn, &self.connections, Fd, .{ .fd = @intCast(file_slot) });
            try self.reg.set(conn, &self.connections, PeerAddr, .{});

            // Resolve the peer address (see `PeerAddr`): install the
            // fixed file into the process fd table; the install CQE
            // handler getpeername()s the real fd, records the address,
            // and closes it again. Best-effort — a failed install just
            // leaves the conn without a peer identity.
            const install_sqe = try getSqeOrSubmit(&self.ring);
            install_sqe.prep_rw(.FIXED_FD_INSTALL, @intCast(file_slot), 0, 0, 0);
            install_sqe.flags |= linux.IOSQE_FIXED_FILE;
            install_sqe.user_data = encodeEntity(conn);

            // Create read-cycle entity and link to connection
            const read_ent = try self.reg.create(&self._read_pending);
            try self.reg.set(read_ent, &self._read_pending, ConnEntity, .{ .entity = conn });
            try self.reg.set(conn, &self.connections, ReadCycleEntity, .{ .entity = read_ent });

            try self.armRecv(read_ent, @intCast(file_slot));
        }

        fn handleRecv(self: *Self, entity: Entity, cqe: linux.io_uring_cqe) !void {
            if (cqe.res > 0) {
                const buf_id = cqe.buffer_id() catch return error.MissingBufferId;
                const pos = @as(usize, self.buf_size) * buf_id;
                const buf_ptr: [*]u8 = @ptrCast(self.buf_base[pos..].ptr);

                try self.reg.set(entity, &self._read_pending, ReadResult, .{
                    .result = cqe.res,
                    .data = buf_ptr,
                    .buf_id = buf_id,
                });
                self.recv_completions_with_data += 1;
            } else {
                try self.reg.set(entity, &self._read_pending, ReadResult, .{ .result = cqe.res });
            }

            try self.reg.moveImmediate(entity, &self._read_pending, &self.read_results);
        }

        fn handleSend(self: *Self, entity: Entity, cqe: linux.io_uring_cqe) !void {
            if (cqe.res < 0) {
                try self.reg.moveImmediate(entity, &self._write_pending, &self.write_results);
                try self.reg.set(entity, &self.write_results, IoResult, .{ .err = cqe.res });
                return;
            }

            const wb = try self.reg.get(entity, &self._write_pending, WriteBuf);
            wb.offset += @intCast(cqe.res);

            if (wb.offset >= wb.len) {
                try self.reg.moveImmediate(entity, &self._write_pending, &self.write_results);
                try self.reg.set(entity, &self.write_results, IoResult, .{ .err = 0 });
            } else {
                const conn_ent = try self.reg.get(entity, &self._write_pending, ConnEntity);
                const conn_fd = self.getFd(conn_ent.entity) orelse return error.InvalidEntity;
                const sqe = try getSqeOrSubmit(&self.ring);
                sqe.prep_send(conn_fd.fd, @constCast(wb.data)[wb.offset..wb.len], 0);
                sqe.flags |= linux.IOSQE_FIXED_FILE;
                sqe.user_data = encodeEntity(entity);
            }
        }

        fn handleConnectSocket(self: *Self, entity: Entity, cqe: linux.io_uring_cqe) !void {
            if (!has_connect) unreachable;

            if (cqe.res < 0) {
                try self.reg.set(entity, &self._connect_socket_pending, IoResult, .{ .err = cqe.res });
                try self.reg.moveStripImmediate(entity, &self._connect_socket_pending, &self.connect_errors, &.{ReadCycleEntity});
                return;
            }

            const slot: i32 = cqe.res;
            try self.reg.set(entity, &self._connect_socket_pending, Fd, .{ .fd = slot });

            const nodelay_sqe = try self.ring.setsockopt(
                INTERNAL_SENTINEL,
                slot,
                posix.IPPROTO.TCP,
                linux.TCP.NODELAY,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            nodelay_sqe.flags |= linux.IOSQE_FIXED_FILE;

            // `ca.addr` is a heap pointer (see `ConnectAddr` docs),
            // so `&ca.addr.any` points into a stable heap allocation
            // that survives the `moveImmediate` swap-remove below.
            // No `ring.submit()` dance required — the pointer stays
            // valid until the connect CQE fires and the strip move
            // frees the storage via `ConnectAddr.deinit`.
            const ca = try self.reg.get(entity, &self._connect_socket_pending, ConnectAddr);
            const sqe = try getSqeOrSubmit(&self.ring);
            sqe.prep_connect(slot, &ca.addr.any, ca.addr.getOsSockLen());
            sqe.flags |= linux.IOSQE_FIXED_FILE;
            sqe.user_data = encodeEntity(entity);

            try self.reg.moveImmediate(entity, &self._connect_socket_pending, &self._connect_pending);
        }

        fn handleConnect(self: *Self, entity: Entity, cqe: linux.io_uring_cqe) !void {
            if (!has_connect) unreachable;

            const fd_ptr = try self.reg.get(entity, &self._connect_pending, Fd);
            const slot = fd_ptr.fd;

            if (cqe.res < 0) {
                const close_sqe = try getSqeOrSubmit(&self.ring);
                close_sqe.prep_close_direct(@intCast(slot));
                close_sqe.user_data = INTERNAL_SENTINEL;
                fd_ptr.fd = -1;
                try self.reg.set(entity, &self._connect_pending, IoResult, .{ .err = cqe.res });
                try self.reg.moveStripImmediate(entity, &self._connect_pending, &self.connect_errors, &.{ReadCycleEntity});
                return;
            }

            const read_ent = try self.reg.create(&self._read_pending);
            try self.reg.set(read_ent, &self._read_pending, ConnEntity, .{ .entity = entity });
            try self.reg.set(entity, &self._connect_pending, ReadCycleEntity, .{ .entity = read_ent });

            try self.armRecv(read_ent, slot);

            try self.reg.moveStripImmediate(entity, &self._connect_pending, &self.connections, &.{ ConnectAddr, IoResult });
        }

        // =============================================================
        // Helpers
        // =============================================================

        fn armRecv(self: *Self, entity: Entity, file_slot: i32) !void {
            const sqe = try getSqeOrSubmit(&self.ring);
            sqe.prep_rw(.RECV, file_slot, 0, 0, 0);
            sqe.flags |= linux.IOSQE_BUFFER_SELECT | linux.IOSQE_FIXED_FILE;
            sqe.buf_index = BUF_GROUP_ID;
            sqe.user_data = encodeEntity(entity);
        }

        /// Return the buffer carried by a completion whose entity is gone.
        /// Silent no-op for completions without one — sends, connects, and
        /// the fixed-fd install all land here too.
        fn reclaimStaleBuffer(self: *Self, cqe: linux.io_uring_cqe) void {
            const buf_id = cqe.buffer_id() catch return;
            const mask = linux.IoUring.buf_ring_mask(self.buf_count);
            self.returnBufferToRing(buf_id, mask, 0);
            linux.IoUring.buf_ring_advance(self.buf_ring, 1);
            // Count the completion on both sides of the balance: the kernel
            // did hand us this buffer, and we did give it back. Omitting the
            // `with_data` half would drive the in-flight delta negative.
            self.recv_completions_with_data += 1;
            self.recv_buffers_returned_via_stale += 1;
        }

        fn returnBufferToRing(self: *Self, buf_id: u16, mask: u16, offset: u16) void {
            const pos: usize = @as(usize, self.buf_size) * buf_id;
            linux.IoUring.buf_ring_add(self.buf_ring, self.buf_base[pos .. pos + self.buf_size], buf_id, mask, offset);
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "component types are valid rove components" {
    const R = Row(&.{ Fd, ConnEntity, ReadResult, WriteBuf, IoResult, ReadCycleEntity, ConnectAddr });
    try testing.expectEqual(@as(usize, 7), R.len);
}

test "Io type has expected collections" {
    const IoType = Io(.{});
    try testing.expect(@hasField(IoType, "connections"));
    try testing.expect(@hasField(IoType, "read_results"));
    try testing.expect(@hasField(IoType, "write_results"));
    try testing.expect(@hasField(IoType, "read_in"));
    try testing.expect(@hasField(IoType, "write_in"));
    try testing.expect(@hasField(IoType, "_read_pending"));
    try testing.expect(@hasField(IoType, "_write_pending"));
}

test "Io with connect has connect collections" {
    const IoType = Io(.{ .connect = true });
    try testing.expect(@hasField(IoType, "connect_in"));
    try testing.expect(@hasField(IoType, "connect_errors"));
    try testing.expect(@hasField(IoType, "_connect_socket_pending"));
    try testing.expect(@hasField(IoType, "_connect_pending"));
}

test "connection row contains base components" {
    const IoType = Io(.{});
    try testing.expect(IoType.ConnectionRow.contains(ReadCycleEntity));
    try testing.expect(IoType.ConnectionRow.contains(Fd));
}

test "user components widen connection row" {
    const MySession = struct { id: u64 };
    const IoType = Io(.{ .connection_row = Row(&.{MySession}) });
    try testing.expect(IoType.ConnectionRow.contains(Fd));
    try testing.expect(IoType.ConnectionRow.contains(ReadCycleEntity));
    try testing.expect(IoType.ConnectionRow.contains(MySession));
}

test "internal rows are supersets" {
    try testing.expect(ReadBaseRow.isSubsetOf(ReadBaseRow)); // read_results ⊆ _read_pending (same row)
    try testing.expect(WriteInBaseRow.isSubsetOf(WriteResultBaseRow)); // write_in ⊆ write_results (result adds IoResult)
}

test "connect entity row is superset of connection row" {
    const conn_row = ConnectionBaseRow;
    const connect_pending_row = ConnectInBaseRow.merge(Row(&.{}));
    try testing.expect(conn_row.isSubsetOf(connect_pending_row));
}

test "works with user collections on same registry" {
    const MySession = struct { id: u64 };
    const PlayerRow = Row(&.{MySession});

    var reg = try Registry.init(testing.allocator, .{ .max_entities = 64 });
    defer reg.deinit();

    // User collection on the same registry
    var players = try Collection(PlayerRow, .{}).init(testing.allocator);
    defer players.deinit();
    reg.registerCollection(&players, 1);

    const player = try reg.create(&players);
    try testing.expect(!reg.isStale(player));
    try reg.set(player, &players, MySession, .{ .id = 99 });
    const sess = try reg.get(player, &players, MySession);
    try testing.expectEqual(@as(u64, 99), sess.id);
}

test "entity encoding round-trip" {
    const e = Entity{ .index = 42, .generation = 7 };
    const decoded = decodeEntity(encodeEntity(e));
    try testing.expect(e.eql(decoded));
}

test "stale completion carrying a buffer returns it to the ring" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 64 });
    defer reg.deinit();

    const IoType = Io(.{});
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    const io = IoType.create(&reg, testing.allocator, addr, .{
        .ring_entries = 8,
        .buf_count = 8,
        .buf_size = 256,
        .max_connections = 8,
    }) catch |err| switch (err) {
        // io_uring unavailable (restricted sandbox / old kernel) — the
        // reclaim logic is unexercised rather than wrong.
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    defer io.destroy();

    // An entity that has been destroyed: its generation is bumped, so any
    // completion still referencing it decodes as stale.
    const doomed = try reg.create(&io._read_pending);
    try reg.destroyImmediate(doomed);
    try testing.expect(reg.isStale(doomed));

    const before = io.recv_buffers_returned_via_stale;

    // The shape the kernel produces for a recv that completed with data:
    // F_BUFFER set, buffer id in the high 16 bits.
    const buf_id: u16 = 3;
    try io.handleCqe(.{
        .user_data = encodeEntity(doomed),
        .res = 128,
        .flags = linux.IORING_CQE_F_BUFFER | (@as(u32, buf_id) << linux.IORING_CQE_BUFFER_SHIFT),
    });

    try testing.expectEqual(before + 1, io.recv_buffers_returned_via_stale);
}

test "stale completion without a buffer is dropped silently" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 64 });
    defer reg.deinit();

    const IoType = Io(.{});
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    const io = IoType.create(&reg, testing.allocator, addr, .{
        .ring_entries = 8,
        .buf_count = 8,
        .buf_size = 256,
        .max_connections = 8,
    }) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    defer io.destroy();

    const doomed = try reg.create(&io._write_pending);
    try reg.destroyImmediate(doomed);

    const before = io.recv_buffers_returned_via_stale;

    // A send completion: no F_BUFFER, nothing to reclaim. Must not
    // advance the ring — a spurious advance over-reports the producer
    // tail and shrinks the distinct-buffer pool.
    try io.handleCqe(.{
        .user_data = encodeEntity(doomed),
        .res = 64,
        .flags = 0,
    });

    try testing.expectEqual(before, io.recv_buffers_returned_via_stale);
}

fn testIo(reg: *Registry) !*Io(.{}) {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    return Io(.{}).create(reg, testing.allocator, addr, .{
        .ring_entries = 8,
        .buf_count = 8,
        .buf_size = 256,
        .max_connections = 8,
    }) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => error.SkipZigTest,
        else => err,
    };
}

test "closing posts the shutdown once and gives up the slot" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 64 });
    defer reg.deinit();
    const io = try testIo(&reg);
    defer io.destroy();

    const conn = try reg.create(&io.connections);
    try reg.set(conn, &io.connections, Fd, .{ .fd = 2 });
    try reg.move(conn, &io.connections, &io.conn_closing);
    try reg.flush();

    try io.processConnClosing();

    const st = try reg.get(conn, &io.conn_closing, ClosingState);
    try testing.expect(st.shutdown_posted);
    try testing.expect(st.deadline_ns > 0);

    // The slot is spoken for. Leaving a live fd here would let `Fd.deinit`
    // close a descriptor the kernel may have already reissued.
    try testing.expectEqual(@as(i32, -1), (try reg.get(conn, &io.conn_closing, Fd)).fd);

    // Posting is not retiring — the conn survives the pass that posts.
    try testing.expect(!reg.isStale(conn));
}

test "a closing conn outlives its armed recv, then retires" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 64 });
    defer reg.deinit();
    const io = try testIo(&reg);
    defer io.destroy();

    const conn = try reg.create(&io.connections);
    try reg.set(conn, &io.connections, Fd, .{ .fd = 2 });
    const read_ent = try reg.create(&io._read_pending);
    try reg.set(read_ent, &io._read_pending, ConnEntity, .{ .entity = conn });
    try reg.set(conn, &io.connections, ReadCycleEntity, .{ .entity = read_ent });
    try reg.move(conn, &io.connections, &io.conn_closing);
    try reg.flush();

    try io.processConnClosing(); // posts the shutdown
    try reg.flush();
    try io.processConnClosing(); // recv still armed — must not retire
    try reg.flush();
    try testing.expect(!reg.isStale(conn));
    try testing.expectEqual(@as(u64, 0), io.conn_closing_retired);

    // The shutdown completes the recv: the read entity leaves _read_pending.
    try reg.moveImmediate(read_ent, &io._read_pending, &io.read_results);

    try io.processConnClosing();
    try reg.flush();
    try testing.expect(reg.isStale(conn));
    try testing.expectEqual(@as(u64, 1), io.conn_closing_retired);
    // It saw the recv finish, so the grace window never came into it.
    try testing.expectEqual(@as(u64, 0), io.conn_closing_deadline_expired);
}

test "a peer that never finishes closing does not pin the slot" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 64 });
    defer reg.deinit();
    const io = try testIo(&reg);
    defer io.destroy();

    const conn = try reg.create(&io.connections);
    try reg.set(conn, &io.connections, Fd, .{ .fd = 2 });
    const read_ent = try reg.create(&io._read_pending);
    try reg.set(read_ent, &io._read_pending, ConnEntity, .{ .entity = conn });
    try reg.set(conn, &io.connections, ReadCycleEntity, .{ .entity = read_ent });
    try reg.move(conn, &io.connections, &io.conn_closing);
    try reg.flush();

    try io.processConnClosing();
    try reg.flush();

    // Expire the grace window with the recv still armed.
    (try reg.get(conn, &io.conn_closing, ClosingState)).deadline_ns = 1;

    try io.processConnClosing();
    try reg.flush();
    try testing.expect(reg.isStale(conn));
    try testing.expectEqual(@as(u64, 1), io.conn_closing_deadline_expired);
}

// NOTE: there is deliberately no test for a conn destroyed around
// `conn_closing`. The guard in `Fd.deinit` aborts the process, so exercising
// it would take the test runner down with it — the standing cost of a check
// that stops rather than reports. What IS covered is the legal path: the
// tests above assert `fd` is -1 by the time a conn is retired, which is the
// condition that keeps the guard silent.
