const std = @import("std");
const rove = @import("rove");
const Row = rove.Row;
const Entity = rove.Entity;
const linux = std.os.linux;
const posix = std.posix;

// =============================================================================
// Component types
// =============================================================================

/// Cleanup context shared by Fd and ReadCycleEntity destructors.
/// Stored on the Io struct, registered with collections via setDeinitCtx.
pub const IoCleanupCtx = struct {
    ring: *linux.IoUring,
    max_connections: u32,
    rove_ctx: *anyopaque,
    destroy_fn: *const fn (*anyopaque, Entity) void,
};

pub const Fd = struct {
    fd: i32 = -1,

    pub const DeinitCtx = IoCleanupCtx;

    pub fn deinit(_: std.mem.Allocator, items: []Fd, ctx: *DeinitCtx) void {
        for (items) |item| {
            if (item.fd >= 0 and @as(u32, @intCast(item.fd)) < ctx.max_connections) {
                const sqe = ctx.ring.get_sqe() catch
                    @panic("SQ full during Fd.deinit — cannot close fixed-file slot");
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
pub const ConnectAddr = struct { addr: std.net.Address };

/// Links a connection to its read-cycle entity. When the connection
/// is destroyed, the read-cycle entity is also destroyed.
pub const ReadCycleEntity = struct {
    entity: Entity = Entity.nil,

    pub const DeinitCtx = IoCleanupCtx;

    pub fn deinit(_: std.mem.Allocator, items: []ReadCycleEntity, ctx: *DeinitCtx) void {
        for (items) |item| {
            if (!item.entity.isNil()) {
                ctx.destroy_fn(ctx.rove_ctx, item.entity);
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
// Spec
// =============================================================================

pub const Options = struct {
    connection_row: type = Row(&.{}),
    read_row: type = Row(&.{}),
    write_row: type = Row(&.{}),
    connect: bool = false,
};

pub fn Collections(comptime opts: Options) type {
    const conn_row = ConnectionBaseRow.merge(opts.connection_row);
    const read_row = ReadBaseRow.merge(opts.read_row);
    const write_in_row = WriteInBaseRow.merge(opts.write_row);
    const write_result_row = WriteResultBaseRow.merge(opts.write_row);
    const read_pending_row = read_row;
    const write_pending_row = write_in_row;

    // Connect pipeline rows (supersets of connection row so the entity
    // can move from connect_in → ... → connections without data loss)
    const connect_in_row = ConnectInBaseRow.merge(opts.connection_row);
    const connect_error_row = ConnectErrorBaseRow.merge(opts.connection_row);
    const connect_socket_pending_row = connect_in_row;
    const connect_pending_row = connect_in_row;

    const C = rove.Collection;
    const base_fields = .{
        rove.col("connections", C(conn_row, .{})),
        rove.col("read_results", C(read_row, .{})),
        rove.col("write_results", C(write_result_row, .{})),
        rove.col("read_in", C(read_row, .{})),
        rove.col("write_in", C(write_in_row, .{})),
        rove.col("_read_pending", C(read_pending_row, .{})),
        rove.col("_write_pending", C(write_pending_row, .{})),
    };

    const connect_fields = if (opts.connect) .{
        rove.col("connect_in", C(connect_in_row, .{})),
        rove.col("connect_errors", C(connect_error_row, .{})),
        rove.col("_connect_socket_pending", C(connect_socket_pending_row, .{})),
        rove.col("_connect_pending", C(connect_pending_row, .{})),
    } else .{};

    return rove.MakeCollections(&(base_fields ++ connect_fields));
}

// =============================================================================
// CQE user_data encoding
// =============================================================================

const ACCEPT_SENTINEL: u64 = std.math.maxInt(u64);
const INTERNAL_SENTINEL: u64 = std.math.maxInt(u64) - 1;

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

pub const IoOptions = struct {
    /// io_uring submission queue depth (must be power of two).
    ring_entries: u16 = 256,
    /// Number of provided receive buffers (must be power of two).
    buf_count: u16 = 256,
    /// Size of each receive buffer in bytes.
    buf_size: u32 = 4096,
    /// Maximum concurrent connections (fixed-file table size).
    max_connections: u32 = 1024,
    /// Optional io_uring params for advanced configuration (SQPOLL,
    /// sq_thread_cpu, cq_entries, etc.). When non-null, used instead
    /// of default ring initialization.
    ring_params: ?*linux.io_uring_params = null,
    /// TCP listen backlog.
    listen_backlog: u31 = 128,
};

pub fn Io(comptime Ctx: type) type {
    const has_connect = @hasField(Ctx.CollectionId, "connect_in");

    return struct {
        const Self = @This();

        ring: linux.IoUring,
        buf_ring: *align(std.heap.page_size_min) linux.io_uring_buf_ring,
        buf_base: []u8,
        buf_size: u32,
        buf_count: u16,
        listen_fd: posix.socket_t,
        conn_slots: []ConnSlot,
        max_connections: u32,

        // Cleanup context for component destructors — interior pointer
        // is stable because Self is heap-allocated.
        cleanup_ctx: IoCleanupCtx,

        allocator: std.mem.Allocator,

        const ConnSlot = struct {
            entity: Entity = Entity.nil,
        };

        const BUF_GROUP_ID: u16 = 0;

        pub fn create(ctx: *Ctx, allocator: std.mem.Allocator, addr: std.net.Address, opts: IoOptions) !*Self {
            var ring = if (opts.ring_params) |params|
                try linux.IoUring.init_params(opts.ring_entries, params)
            else
                try linux.IoUring.init(opts.ring_entries, 0);
            errdefer ring.deinit();

            {
                const empty_fds = try allocator.alloc(posix.fd_t, opts.max_connections);
                defer allocator.free(empty_fds);
                @memset(empty_fds, -1);
                try ring.register_files(empty_fds);
            }

            const buf_base = try allocator.alloc(u8, @as(usize, opts.buf_count) * opts.buf_size);
            errdefer allocator.free(buf_base);

            const br = try linux.IoUring.setup_buf_ring(ring.fd, opts.buf_count, BUF_GROUP_ID, .{ .inc = false });
            linux.IoUring.buf_ring_init(br);
            const mask = linux.IoUring.buf_ring_mask(opts.buf_count);
            for (0..opts.buf_count) |i| {
                const pos = @as(usize, opts.buf_size) * i;
                linux.IoUring.buf_ring_add(br, buf_base[pos .. pos + opts.buf_size], @intCast(i), mask, @intCast(i));
            }
            linux.IoUring.buf_ring_advance(br, opts.buf_count);

            const listen_fd = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
            errdefer posix.close(listen_fd);

            try posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            try posix.bind(listen_fd, &addr.any, addr.getOsSockLen());
            try posix.listen(listen_fd, opts.listen_backlog);

            {
                const sqe = try ring.get_sqe();
                sqe.prep_multishot_accept_direct(listen_fd, null, null, 0);
                sqe.user_data = ACCEPT_SENTINEL;
            }

            const conn_slots = try allocator.alloc(ConnSlot, opts.max_connections);
            @memset(conn_slots, ConnSlot{});

            const self = try allocator.create(Self);
            self.* = .{
                .ring = ring,
                .buf_ring = br,
                .buf_base = buf_base,
                .buf_size = opts.buf_size,
                .buf_count = opts.buf_count,
                .listen_fd = listen_fd,
                .conn_slots = conn_slots,
                .max_connections = opts.max_connections,
                .cleanup_ctx = .{
                    .ring = undefined, // set below after self is allocated
                    .max_connections = opts.max_connections,
                    .rove_ctx = @ptrCast(ctx),
                    .destroy_fn = &destroyEntityThunk,
                },
                .allocator = allocator,
            };

            // Set ring pointer now that self is at its final heap location
            self.cleanup_ctx.ring = &self.ring;

            // Register deinit context — &self.cleanup_ctx is stable (self is heap-allocated)
            self.registerDeinitCtxs(ctx);

            return self;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            linux.IoUring.free_buf_ring(self.ring.fd, self.buf_ring, self.buf_count, BUF_GROUP_ID);
            allocator.free(self.buf_base);
            posix.close(self.listen_fd);
            allocator.free(self.conn_slots);
            self.ring.deinit();
            allocator.destroy(self);
        }

        pub fn poll(self: *Self, ctx: *Ctx, min_complete: u32) !u32 {
            // Phase 1: Process user inputs (deferred moves)
            try self.processWriteIn(ctx);
            try self.processReadIn(ctx);
            if (has_connect) try self.processConnectIn(ctx);

            // Phase 2: Flush deferred moves
            try ctx.flush();

            // Phase 3: Submit and wait
            _ = try self.ring.submit_and_wait(min_complete);

            // Phase 4: Drain CQEs (immediate ops)
            var cqe_buf: [256]linux.io_uring_cqe = undefined;
            var events: u32 = 0;
            while (true) {
                const count = try self.ring.copy_cqes(&cqe_buf, 0);
                if (count == 0) break;
                for (cqe_buf[0..count]) |cqe| {
                    try self.handleCqe(ctx, cqe);
                    events += 1;
                }
            }

            return events;
        }

        // =============================================================
        // Slot release
        // =============================================================

        // =============================================================
        // Input processing (deferred ops, forward iteration)
        // =============================================================

        fn processWriteIn(self: *Self, ctx: *Ctx) !void {
            const entities = ctx.entities(.write_in);
            const conn_ents = ctx.column(.write_in, ConnEntity);
            const wbufs = ctx.column(.write_in, WriteBuf);

            for (entities, conn_ents, wbufs) |ent, conn_ent, wb| {
                if (ctx.isStale(conn_ent.entity)) {
                    try ctx.destroyOne(ent);
                    continue;
                }

                const conn_fd = try ctx.get(conn_ent.entity, Fd);

                const sqe = try self.ring.get_sqe();
                sqe.prep_send(conn_fd.fd, @constCast(wb.data)[wb.offset..wb.len], 0);
                sqe.flags |= linux.IOSQE_FIXED_FILE;
                sqe.user_data = encodeEntity(ent);

                try ctx.moveOneFrom(ent, .write_in, ._write_pending);
            }
        }

        fn processReadIn(self: *Self, ctx: *Ctx) !void {
            const entities = ctx.entities(.read_in);
            const conn_ents = ctx.column(.read_in, ConnEntity);
            const results = ctx.column(.read_in, ReadResult);
            const mask = linux.IoUring.buf_ring_mask(self.buf_count);
            var armed: u16 = 0;

            for (entities, conn_ents, results) |ent, conn_ent, rr| {
                if (ctx.isStale(conn_ent.entity)) {
                    if (rr.data != null) {
                        self.returnBufferToRing(rr.buf_id, mask, armed);
                        armed += 1;
                    }
                    try ctx.destroyOne(ent);
                    continue;
                }

                const conn_fd = try ctx.get(conn_ent.entity, Fd);

                if (rr.data != null) {
                    self.returnBufferToRing(rr.buf_id, mask, armed);
                    armed += 1;
                }

                const rr_ptr = try ctx.get(ent, ReadResult);
                rr_ptr.* = .{};

                try self.armRecv(ent, conn_fd.fd);
                try ctx.moveOneFrom(ent, .read_in, ._read_pending);
            }

            if (armed > 0) {
                linux.IoUring.buf_ring_advance(self.buf_ring, armed);
            }
        }

        fn processConnectIn(self: *Self, ctx: *Ctx) !void {
            if (!has_connect) return;

            const entities = ctx.entities(.connect_in);
            const addrs = ctx.column(.connect_in, ConnectAddr);

            for (entities, addrs) |ent, addr| {
                _ = addr;
                // Submit socket_direct_alloc SQE
                const sqe = try self.ring.get_sqe();
                sqe.prep_socket_direct_alloc(posix.AF.INET, posix.SOCK.STREAM, 0, 0);
                sqe.user_data = encodeEntity(ent);

                try ctx.moveOneFrom(ent, .connect_in, ._connect_socket_pending);
            }
        }

        // =============================================================
        // CQE handlers
        // =============================================================

        fn handleCqe(self: *Self, ctx: *Ctx, cqe: linux.io_uring_cqe) !void {
            if (cqe.user_data == INTERNAL_SENTINEL) return;
            if (cqe.user_data == ACCEPT_SENTINEL) {
                try self.handleAccept(ctx, cqe);
                return;
            }

            const entity = decodeEntity(cqe.user_data);
            if (ctx.isStale(entity)) return;

            const col_id = ctx.collection_ids[entity.index];
            const read_pending_id = comptime Ctx.internalIndex(._read_pending);
            const write_pending_id = comptime Ctx.internalIndex(._write_pending);

            if (col_id == read_pending_id) {
                try self.handleRecv(ctx, entity, cqe);
            } else if (col_id == write_pending_id) {
                try self.handleSend(ctx, entity, cqe);
            } else if (has_connect) {
                const connect_socket_id = comptime Ctx.internalIndex(._connect_socket_pending);
                const connect_pending_id = comptime Ctx.internalIndex(._connect_pending);
                if (col_id == connect_socket_id) {
                    try self.handleConnectSocket(ctx, entity, cqe);
                } else if (col_id == connect_pending_id) {
                    try self.handleConnect(ctx, entity, cqe);
                } else {
                    return error.UnexpectedEntityCollection;
                }
            } else {
                return error.UnexpectedEntityCollection;
            }
        }

        fn handleAccept(self: *Self, ctx: *Ctx, cqe: linux.io_uring_cqe) !void {
            if (cqe.flags & linux.IORING_CQE_F_MORE == 0) {
                const sqe = try self.ring.get_sqe();
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

            const conn = try ctx.createOneImmediate(.connections);
            try ctx.set(conn, Fd, .{ .fd = @intCast(file_slot) });
            self.conn_slots[file_slot] = .{ .entity = conn };

            // Create read-cycle entity and link to connection
            const read_ent = try ctx.createOneImmediate(._read_pending);
            try ctx.set(read_ent, ConnEntity, .{ .entity = conn });
            try ctx.set(conn, ReadCycleEntity, .{ .entity = read_ent });

            try self.armRecv(read_ent, @intCast(file_slot));
        }

        fn handleRecv(self: *Self, ctx: *Ctx, entity: Entity, cqe: linux.io_uring_cqe) !void {
            if (cqe.res > 0) {
                const buf_id = cqe.buffer_id() catch return error.MissingBufferId;
                const pos = @as(usize, self.buf_size) * buf_id;
                const buf_ptr: [*]u8 = @ptrCast(self.buf_base[pos..].ptr);

                try ctx.set(entity, ReadResult, .{
                    .result = cqe.res,
                    .data = buf_ptr,
                    .buf_id = buf_id,
                });
            } else {
                try ctx.set(entity, ReadResult, .{ .result = cqe.res });
            }

            try ctx.moveImmediateFrom(entity, ._read_pending, .read_results);
        }

        fn handleSend(self: *Self, ctx: *Ctx, entity: Entity, cqe: linux.io_uring_cqe) !void {
            if (cqe.res < 0) {
                try ctx.moveImmediateFrom(entity, ._write_pending, .write_results);
                try ctx.set(entity, IoResult, .{ .err = cqe.res });
                return;
            }

            const wb = try ctx.get(entity, WriteBuf);
            wb.offset += @intCast(cqe.res);

            if (wb.offset >= wb.len) {
                try ctx.moveImmediateFrom(entity, ._write_pending, .write_results);
                try ctx.set(entity, IoResult, .{ .err = 0 });
            } else {
                const conn_ent = try ctx.get(entity, ConnEntity);
                const conn_fd = try ctx.get(conn_ent.entity, Fd);
                const sqe = try self.ring.get_sqe();
                sqe.prep_send(conn_fd.fd, @constCast(wb.data)[wb.offset..wb.len], 0);
                sqe.flags |= linux.IOSQE_FIXED_FILE;
                sqe.user_data = encodeEntity(entity);
            }
        }

        fn handleConnectSocket(self: *Self, ctx: *Ctx, entity: Entity, cqe: linux.io_uring_cqe) !void {
            if (!has_connect) unreachable;

            if (cqe.res < 0) {
                // Socket creation failed
                try ctx.set(entity, IoResult, .{ .err = cqe.res });
                try ctx.moveStripImmediateFrom(entity, ._connect_socket_pending, .connect_errors, &.{ReadCycleEntity});
                return;
            }

            const slot: i32 = cqe.res;
            try ctx.set(entity, Fd, .{ .fd = slot });

            // TCP_NODELAY
            const nodelay_sqe = try self.ring.setsockopt(
                INTERNAL_SENTINEL,
                slot,
                posix.IPPROTO.TCP,
                linux.TCP.NODELAY,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            nodelay_sqe.flags |= linux.IOSQE_FIXED_FILE;

            // Submit connect SQE
            const ca = try ctx.get(entity, ConnectAddr);
            const sqe = try self.ring.get_sqe();
            sqe.prep_connect(slot, &ca.addr.any, ca.addr.getOsSockLen());
            sqe.flags |= linux.IOSQE_FIXED_FILE;
            sqe.user_data = encodeEntity(entity);

            try ctx.moveImmediateFrom(entity, ._connect_socket_pending, ._connect_pending);
        }

        fn handleConnect(self: *Self, ctx: *Ctx, entity: Entity, cqe: linux.io_uring_cqe) !void {
            if (!has_connect) unreachable;

            const fd_ptr = try ctx.get(entity, Fd);
            const slot = fd_ptr.fd;

            if (cqe.res < 0) {
                // Connect failed — close slot directly, set fd=-1 so destructor skips
                const close_sqe = try self.ring.get_sqe();
                close_sqe.prep_close_direct(@intCast(slot));
                close_sqe.user_data = INTERNAL_SENTINEL;
                fd_ptr.fd = -1;
                try ctx.set(entity, IoResult, .{ .err = cqe.res });
                try ctx.moveStripImmediateFrom(entity, ._connect_pending, .connect_errors, &.{ReadCycleEntity});
                return;
            }

            // Success: create read-cycle entity, arm recv, move to connections
            self.conn_slots[@intCast(slot)] = .{ .entity = entity };

            const read_ent = try ctx.createOneImmediate(._read_pending);
            try ctx.set(read_ent, ConnEntity, .{ .entity = entity });
            try ctx.set(entity, ReadCycleEntity, .{ .entity = read_ent });

            try self.armRecv(read_ent, slot);

            // The connect entity becomes the connection
            try ctx.moveStripImmediateFrom(entity, ._connect_pending, .connections, &.{ ConnectAddr, IoResult });
        }

        // =============================================================
        // Helpers
        // =============================================================

        fn destroyEntityThunk(ctx_ptr: *anyopaque, entity: Entity) void {
            const rove_ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
            if (!rove_ctx.isStale(entity)) {
                rove_ctx.destroyImmediate(entity) catch {};
            }
        }

        fn registerDeinitCtxs(self: *Self, ctx: *Ctx) void {
            ctx.setDeinitCtx(Fd, &self.cleanup_ctx);
            ctx.setDeinitCtx(ReadCycleEntity, &self.cleanup_ctx);
        }

        fn armRecv(self: *Self, entity: Entity, file_slot: i32) !void {
            const sqe = try self.ring.get_sqe();
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

test "spec produces all expected collections" {
    const S = Collections(.{});
    try testing.expect(@hasField(S, "connections"));
    try testing.expect(@hasField(S, "read_results"));
    try testing.expect(@hasField(S, "write_results"));
    try testing.expect(@hasField(S, "read_in"));
    try testing.expect(@hasField(S, "write_in"));
    try testing.expect(@hasField(S, "_read_pending"));
    try testing.expect(@hasField(S, "_write_pending"));
}

test "spec with connect" {
    const S = Collections(.{ .connect = true });
    try testing.expect(@hasField(S, "connect_in"));
    try testing.expect(@hasField(S, "connect_errors"));
    try testing.expect(@hasField(S, "_connect_socket_pending"));
    try testing.expect(@hasField(S, "_connect_pending"));
}

test "spec without connect has no connect collections" {
    const S = Collections(.{});
    try testing.expect(!@hasField(S, "connect_in"));
}

test "connection row contains ReadCycleEntity" {
    const S = Collections(.{});
    try testing.expect(rove.CollectionRow(S, "connections").contains(ReadCycleEntity));
    try testing.expect(rove.CollectionRow(S, "connections").contains(Fd));
}

test "spec — user components on connections" {
    const MySession = struct { id: u64 };
    const S = Collections(.{ .connection_row = Row(&.{MySession}) });
    try testing.expect(rove.CollectionRow(S, "connections").contains(Fd));
    try testing.expect(rove.CollectionRow(S, "connections").contains(ReadCycleEntity));
    try testing.expect(rove.CollectionRow(S, "connections").contains(MySession));
}

test "spec — internal rows are supersets" {
    const S = Collections(.{});
    try testing.expect(rove.CollectionRow(S, "read_results").isSubsetOf(rove.CollectionRow(S, "_read_pending")));
    try testing.expect(rove.CollectionRow(S, "write_in").isSubsetOf(rove.CollectionRow(S, "_write_pending")));
    try testing.expect(rove.CollectionRow(S, "_write_pending").isSubsetOf(rove.CollectionRow(S, "write_results")));
}

test "spec — connect entity can move to connections" {
    const S = Collections(.{ .connect = true });
    try testing.expect(rove.CollectionRow(S, "connections").isSubsetOf(rove.CollectionRow(S, "_connect_pending")));
}

test "spec — merges with user collections and creates Context" {
    const MySession = struct { id: u64 };
    const PlayerRow = Row(&.{MySession});
    const AppSpec = rove.MakeCollections(&.{rove.col("players", rove.Collection(PlayerRow, .{}))});
    const Spec = rove.MergeCollections(.{ Collections(.{ .connection_row = Row(&.{MySession}) }), AppSpec });

    const Ctx = rove.Context(Spec);
    var ctx = try Ctx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const conn = try ctx.createOne(.connections);
    const player = try ctx.createOne(.players);
    try ctx.flush();

    try testing.expect(!ctx.isStale(conn));
    try testing.expect(!ctx.isStale(player));

    try ctx.set(conn, Fd, .{ .fd = 42 });
    try ctx.set(conn, MySession, .{ .id = 99 });
    const fd = try ctx.get(conn, Fd);
    const sess = try ctx.get(conn, MySession);
    try testing.expectEqual(@as(i32, 42), fd.fd);
    try testing.expectEqual(@as(u64, 99), sess.id);
}

test "entity encoding round-trip" {
    const e = Entity{ .index = 42, .generation = 7 };
    const decoded = decodeEntity(encodeEntity(e));
    try testing.expect(e.eql(decoded));
}
