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

/// Cleanup context shared by Fd and ReadCycleEntity destructors.
/// Stored on the Io struct, registered with registry via setDeinitCtx.
pub const IoCleanupCtx = struct {
    ring: *linux.IoUring,
    max_connections: u32,
    reg: *Registry,
};

pub const Fd = struct {
    fd: i32 = -1,

    pub const DeinitCtx = IoCleanupCtx;

    pub fn deinit(_: std.mem.Allocator, items: []Fd, ctx: *DeinitCtx) void {
        for (items) |item| {
            if (item.fd >= 0 and @as(u32, @intCast(item.fd)) < ctx.max_connections) {
                const sqe = getSqeOrSubmit(ctx.ring) catch
                    @panic("SQ full during Fd.deinit even after submit — ring too small");
                sqe.prep_close_direct(@intCast(item.fd));
                sqe.user_data = INTERNAL_SENTINEL;
            }
        }
    }
};

pub const ConnEntity = struct { entity: Entity = Entity.nil };

pub const ReadResult = struct {
    result: i32 = 0,
    data: ?[*]u8 = null,
    buf_id: u16 = 0,
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

pub const ConnectionBaseRow = Row(&.{ Fd, ReadCycleEntity });
pub const ReadBaseRow = Row(&.{ ConnEntity, ReadResult });
pub const WriteInBaseRow = Row(&.{ ConnEntity, WriteBuf });
pub const WriteResultBaseRow = Row(&.{ ConnEntity, WriteBuf, IoResult });
const ConnectInBaseRow = Row(&.{ ConnectAddr, Fd, IoResult, ReadCycleEntity });
const ConnectErrorBaseRow = Row(&.{ ConnectAddr, Fd, IoResult });

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

        reg: *Registry,
        allocator: std.mem.Allocator,

        const BUF_GROUP_ID: u16 = 0;

        /// Look up the Fd for a connection entity. Uses the custom resolver if
        /// set, otherwise searches `self.connections` directly.
        pub fn getFd(self: *Self, entity: Entity) ?*Fd {
            if (self.fd_resolver) |resolver| {
                return resolver(self.fd_resolver_ctx.?, entity);
            }
            return self.reg.get(entity, &self.connections, Fd) catch null;
        }

        /// Register an external FD resolver. Used by rove-h2 to search its own
        /// connection collections (_conn_active, _conn_tls_handshake).
        pub fn setFdResolver(self: *Self, ctx: *anyopaque, resolver: *const fn (*anyopaque, Entity) ?*Fd) void {
            self.fd_resolver_ctx = ctx;
            self.fd_resolver = resolver;
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
                },
                .reg = reg,
                .allocator = allocator,
            };

            // Set ring pointer now that self is at its final heap location
            self.cleanup_ctx.ring = &self.ring;

            // Register collections with registry
            reg.registerCollection(&self.connections);
            reg.registerCollection(&self.read_results);
            reg.registerCollection(&self.write_results);
            reg.registerCollection(&self.read_in);
            reg.registerCollection(&self.write_in);
            reg.registerCollection(&self._read_pending);
            reg.registerCollection(&self._write_pending);
            if (has_connect) {
                reg.registerCollection(&self.connect_in);
                reg.registerCollection(&self.connect_errors);
                reg.registerCollection(&self._connect_socket_pending);
                reg.registerCollection(&self._connect_pending);
            }

            // Register deinit contexts
            reg.setDeinitCtx(Fd, &self.cleanup_ctx);
            reg.setDeinitCtx(ReadCycleEntity, &self.cleanup_ctx);

            return self;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            self.connections.deinit();
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

        fn processWriteIn(self: *Self) !void {
            const entities = self.write_in.entitySlice();
            const conn_ents = self.write_in.column(ConnEntity);
            const wbufs = self.write_in.column(WriteBuf);

            for (entities, conn_ents, wbufs) |ent, conn_ent, wb| {
                if (self.reg.isStale(conn_ent.entity)) {
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
                    }
                    try self.reg.destroy(ent);
                    continue;
                }

                const conn_fd = self.getFd(conn_ent.entity) orelse {
                    if (rr.data != null) {
                        self.returnBufferToRing(rr.buf_id, mask, armed);
                        armed += 1;
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
            if (self.reg.isStale(entity)) return;

            if (self.reg.isInCollection(entity, &self._read_pending)) {
                try self.handleRecv(entity, cqe);
            } else if (self.reg.isInCollection(entity, &self._write_pending)) {
                try self.handleSend(entity, cqe);
            } else if (has_connect) {
                if (self.reg.isInCollection(entity, &self._connect_socket_pending)) {
                    try self.handleConnectSocket(entity, cqe);
                } else if (self.reg.isInCollection(entity, &self._connect_pending)) {
                    try self.handleConnect(entity, cqe);
                } else {
                    return error.UnexpectedEntityCollection;
                }
            } else {
                return error.UnexpectedEntityCollection;
            }
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
    reg.registerCollection(&players);

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
