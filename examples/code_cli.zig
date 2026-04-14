//! `rove-code-cli` — local driver for rove-code.
//!
//! Phase 1b ships rove-code as a library + a local CLI; the HTTP/2
//! server wrapper is deferred to early Phase 2 where it gets designed
//! alongside the worker's code-client (both ends of the wire at once).
//! Until then, this binary is the integration harness: it exercises
//! the full stack — rove-kv + rove-blob + rove-qjs compile hook +
//! rove-code — against a local database and blob directory, so we can
//! upload a source tree, deploy it, and read entries back.
//!
//! Usage:
//!   rove-code-cli upload <dir> --db <path> --blob <dir>
//!   rove-code-cli deploy --db <path> --blob <dir>
//!   rove-code-cli show --db <path> --blob <dir>
//!   rove-code-cli get <path> --db <path> --blob <dir>
//!
//! `upload` walks a directory, registers every regular file whose name
//! ends in `.js` or `.mjs` as a source entry in the CodeStore. A
//! subsequent `deploy` freezes the working tree and assigns a deployment
//! id. `show` prints the current deployment manifest. `get` fetches the
//! current source bytes for a path.

const std = @import("std");
const qjs = @import("rove-qjs");
const code = @import("rove-code");
const kv = @import("rove-kv");
const blob_mod = @import("rove-blob");

const MAX_SOURCE_BYTES: usize = 8 * 1024 * 1024; // 8 MiB/file, plenty for M1

// ── qjs compile hook ──────────────────────────────────────────────────
//
// The compile function closes over a single Runtime + Context pair. It
// runs `Context.compileToBytecode` on each source and returns the bytes.
// One shared context is fine: compile has no request state, and bytecode
// is portable across contexts anyway.

const QjsCompiler = struct {
    runtime: qjs.Runtime,
    context: qjs.Context,

    fn init() !QjsCompiler {
        var rt = try qjs.Runtime.init();
        errdefer rt.deinit();
        const ctx = try rt.newContext();
        return .{ .runtime = rt, .context = ctx };
    }

    fn deinit(self: *QjsCompiler) void {
        self.context.deinit();
        self.runtime.deinit();
    }

    fn compile(
        ctx_opaque: ?*anyopaque,
        source: []const u8,
        filename: [:0]const u8,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *QjsCompiler = @ptrCast(@alignCast(ctx_opaque.?));
        return self.context.compileToBytecode(source, filename, allocator, .{ .kind = .module });
    }
};

// ── Arg parsing ───────────────────────────────────────────────────────

const Args = struct {
    cmd: Command,
    data_dir: []const u8,
    instance: []const u8,
    positional: ?[]const u8 = null,

    const Command = enum { upload, deploy, show, get };
};

fn parseArgs(argv: [][:0]u8) !Args {
    if (argv.len < 2) return error.Usage;
    const cmd: Args.Command = if (std.mem.eql(u8, argv[1], "upload"))
        .upload
    else if (std.mem.eql(u8, argv[1], "deploy"))
        .deploy
    else if (std.mem.eql(u8, argv[1], "show"))
        .show
    else if (std.mem.eql(u8, argv[1], "get"))
        .get
    else
        return error.Usage;

    var data_dir: ?[]const u8 = null;
    var instance: ?[]const u8 = null;
    var positional: ?[]const u8 = null;

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            data_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--instance")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            instance = argv[i];
        } else if (positional == null) {
            positional = a;
        } else {
            return error.Usage;
        }
    }

    if (data_dir == null or instance == null) return error.Usage;
    if ((cmd == .upload or cmd == .get) and positional == null) return error.Usage;

    return .{
        .cmd = cmd,
        .data_dir = data_dir.?,
        .instance = instance.?,
        .positional = positional,
    };
}

fn usage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\usage: rove-code-cli <cmd> [args] --data-dir <path> --instance <id>
        \\  upload <dir>  walk <dir>, register every .js/.mjs file
        \\  deploy        freeze the working tree, assign a deployment id
        \\  show          print the current deployment manifest
        \\  get <path>    print the current source bytes for <path>
        \\
        \\Code storage is per-tenant. Given --data-dir <root> --instance <id>,
        \\the tenant's code index lives at <root>/<id>/code.db and source/
        \\bytecode blobs at <root>/<id>/code-blobs/. The directory is created
        \\if missing.
        \\
    );
    try w.flush();
}

// ── Commands ──────────────────────────────────────────────────────────

fn runUpload(allocator: std.mem.Allocator, store: *code.CodeStore, dir_path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var uploaded: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!(std.mem.endsWith(u8, entry.path, ".js") or std.mem.endsWith(u8, entry.path, ".mjs")))
            continue;

        const bytes = try entry.dir.readFileAlloc(allocator, entry.basename, MAX_SOURCE_BYTES);
        defer allocator.free(bytes);

        // Normalize path separators to forward slashes for key stability
        // across platforms. Linux-only right now, but cheap insurance.
        const norm = try allocator.dupe(u8, entry.path);
        defer allocator.free(norm);
        for (norm) |*b| if (b.* == '\\') {
            b.* = '/';
        };

        try store.putSource(norm, bytes);
        uploaded += 1;
    }

    var stderr_buf: [256]u8 = undefined;
    var sw = std.fs.File.stderr().writer(&stderr_buf);
    try sw.interface.print("uploaded {d} source file(s)\n", .{uploaded});
    try sw.interface.flush();
}

fn runDeploy(store: *code.CodeStore) !void {
    const id = try store.deploy();
    var stdout_buf: [64]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    try sw.interface.print("{d}\n", .{id});
    try sw.interface.flush();
}

fn runShow(store: *code.CodeStore) !void {
    var m = try store.loadCurrentDeployment();
    defer m.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    const w = &sw.interface;
    try w.print("deployment {d} ({d} entries)\n", .{ m.id, m.entries.len });
    for (m.entries) |e| {
        try w.print("  {s}\n    src={s}\n    bc ={s}\n", .{
            e.path,
            e.source_hex,
            e.bytecode_hex,
        });
    }
    try w.flush();
}

fn runGet(
    allocator: std.mem.Allocator,
    store: *code.CodeStore,
    path: []const u8,
) !void {
    const bytes = try store.getSource(path, allocator);
    defer allocator.free(bytes);

    var stdout_buf: [4096]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    try sw.interface.writeAll(bytes);
    try sw.interface.flush();
}

// ── Entry point ───────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stderr_buf: [1024]u8 = undefined;
    var sw = std.fs.File.stderr().writer(&stderr_buf);

    const args = parseArgs(argv) catch {
        try usage(&sw.interface);
        std.process.exit(2);
    };

    // Build {data_dir}/{instance}/ and ensure it exists.
    const inst_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ args.data_dir, args.instance },
    );
    defer allocator.free(inst_dir);
    std.fs.cwd().makePath(inst_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const code_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/code.db",
        .{inst_dir},
        0,
    );
    defer allocator.free(code_db_path);

    const code_blob_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/code-blobs",
        .{inst_dir},
    );
    defer allocator.free(code_blob_dir);

    var compiler = try QjsCompiler.init();
    defer compiler.deinit();

    const kvs = try kv.KvStore.open(allocator, code_db_path);
    defer kvs.close();

    var fs_store = try blob_mod.FilesystemBlobStore.open(allocator, code_blob_dir);
    defer fs_store.deinit();

    var store = code.CodeStore.init(
        allocator,
        kvs,
        fs_store.blobStore(),
        QjsCompiler.compile,
        &compiler,
    );

    switch (args.cmd) {
        .upload => try runUpload(allocator, &store, args.positional.?),
        .deploy => try runDeploy(&store),
        .show => try runShow(&store),
        .get => try runGet(allocator, &store, args.positional.?),
    }
}

// ── Integration tests ─────────────────────────────────────────────────
//
// These live here (not in src/code/) because they wire rove-qjs into
// the compile hook, and I want the rove-code library itself to stay
// qjs-agnostic. Running `zig build test` picks them up via the
// `code-cli-tests` step wired in build.zig.

const testing = std.testing;

const IntegrationFixture = struct {
    allocator: std.mem.Allocator,
    tmp_path: []u8,
    compiler: QjsCompiler,
    kv_store: *kv.KvStore,
    blob_store: blob_mod.FilesystemBlobStore,

    fn init(allocator: std.mem.Allocator) !IntegrationFixture {
        const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/rove-code-int-{x}", .{seed});
        errdefer allocator.free(tmp_path);
        std.fs.cwd().deleteTree(tmp_path) catch {};
        try std.fs.cwd().makePath(tmp_path);

        const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/idx.db", .{tmp_path}, 0);
        defer allocator.free(db_path);

        const compiler = try QjsCompiler.init();
        errdefer {
            var c = compiler;
            c.deinit();
        }

        const kvs = try kv.KvStore.open(allocator, db_path);
        errdefer kvs.close();

        const blob_path = try std.fmt.allocPrint(allocator, "{s}/blobs", .{tmp_path});
        defer allocator.free(blob_path);
        const bs = try blob_mod.FilesystemBlobStore.open(allocator, blob_path);

        return .{
            .allocator = allocator,
            .tmp_path = tmp_path,
            .compiler = compiler,
            .kv_store = kvs,
            .blob_store = bs,
        };
    }

    fn deinit(self: *IntegrationFixture) void {
        self.blob_store.deinit();
        self.kv_store.close();
        self.compiler.deinit();
        std.fs.cwd().deleteTree(self.tmp_path) catch {};
        self.allocator.free(self.tmp_path);
    }

    fn codeStore(self: *IntegrationFixture) code.CodeStore {
        return code.CodeStore.init(
            self.allocator,
            self.kv_store,
            self.blob_store.blobStore(),
            QjsCompiler.compile,
            &self.compiler,
        );
    }
};

test "integration: real qjs compile round trip" {
    var fx = try IntegrationFixture.init(testing.allocator);
    defer fx.deinit();
    var store = fx.codeStore();

    try store.putSource("handlers/math.js", "export const sum = (a, b) => a + b;");

    // Source blob survives untouched.
    const src = try store.getSource("handlers/math.js", testing.allocator);
    defer testing.allocator.free(src);
    try testing.expectEqualStrings("export const sum = (a, b) => a + b;", src);

    // Bytecode is real quickjs output — non-empty, and evaluating it
    // against a fresh context executes the module.
    const bc = try store.getBytecode("handlers/math.js", testing.allocator);
    defer testing.allocator.free(bc);
    try testing.expect(bc.len > 0);
}

test "integration: compiled bytecode executes in a fresh runtime" {
    var fx = try IntegrationFixture.init(testing.allocator);
    defer fx.deinit();
    var store = fx.codeStore();

    try store.putSource(
        "h.js",
        "globalThis.result = 6 * 7;",
    );
    const bc = try store.getBytecode("h.js", testing.allocator);
    defer testing.allocator.free(bc);

    // Fresh runtime so we know the bytecode isn't piggy-backing on the
    // compiler's context state.
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    var r = try ctx.evalBytecode(bc);
    defer r.deinit();

    var check = try ctx.eval("globalThis.result", "check.js", .{});
    defer check.deinit();
    try testing.expectEqual(@as(i32, 42), try check.toI32());
}

test "integration: deploy + loadCurrentDeployment + resolve blob via manifest" {
    var fx = try IntegrationFixture.init(testing.allocator);
    defer fx.deinit();
    var store = fx.codeStore();

    try store.putSource("a.js", "export const a = 1;");
    try store.putSource("b/c.js", "export const c = 3;");
    const id = try store.deploy();
    try testing.expectEqual(@as(u64, 1), id);

    var m = try store.loadCurrentDeployment();
    defer m.deinit();
    try testing.expectEqual(@as(usize, 2), m.entries.len);

    // Every bytecode hash in the manifest should round-trip through the
    // blob store — this is the flow the Phase 2 worker will use.
    for (m.entries) |e| {
        const bs = fx.blob_store.blobStore();
        try testing.expectEqual(true, try bs.exists(&e.bytecode_hex));
        const b = try bs.get(&e.bytecode_hex, testing.allocator);
        defer testing.allocator.free(b);
        try testing.expect(b.len > 0);
    }
}

test "integration: syntax error propagates as CompileFailed" {
    var fx = try IntegrationFixture.init(testing.allocator);
    defer fx.deinit();
    var store = fx.codeStore();

    try testing.expectError(
        code.Error.CompileFailed,
        store.putSource("bad.js", "@@@ not js @@@"),
    );
}

test "integration: upload walks a tree and registers .js files" {
    var fx = try IntegrationFixture.init(testing.allocator);
    defer fx.deinit();
    var store = fx.codeStore();

    // Lay down a tiny source tree under fx.tmp_path/src.
    const src_dir = try std.fmt.allocPrint(testing.allocator, "{s}/src", .{fx.tmp_path});
    defer testing.allocator.free(src_dir);
    try std.fs.cwd().makePath(src_dir);

    var d = try std.fs.cwd().openDir(src_dir, .{});
    defer d.close();
    try d.writeFile(.{ .sub_path = "a.js", .data = "export const a = 1;" });
    try d.makePath("sub");
    try d.writeFile(.{ .sub_path = "sub/b.mjs", .data = "export const b = 2;" });
    try d.writeFile(.{ .sub_path = "README.md", .data = "# not js" });

    try runUpload(testing.allocator, &store, src_dir);
    _ = try store.deploy();

    var m = try store.loadCurrentDeployment();
    defer m.deinit();
    try testing.expectEqual(@as(usize, 2), m.entries.len);
    // Sorted by key — "a.js" before "sub/b.mjs".
    try testing.expectEqualStrings("a.js", m.entries[0].path);
    try testing.expectEqualStrings("sub/b.mjs", m.entries[1].path);
}
