//! Built-in handler modules — the `__system/` namespace.
//!
//! Phase 5 PR-2 introduces module paths that the runtime resolves
//! without those modules being in any tenant's deployment files.
//! `webhook.send.js` (the shim) fires `http.fetch` with
//! `on_chunk: "__system/webhook_onresult"`; the runtime's module
//! resolver (`worker.resolveDeployment`) recognizes the `__system/`
//! prefix and falls through to this module's `BYTECODES` map
//! instead of looking up in `tc.snap.bytecodes`.
//!
//! ## Why a separate namespace
//!
//! The shim's bookkeeping handler needs to run as a normal
//! dispatcher activation (so it has access to kv, http, __rove_next,
//! etc. — every tenant-context global). Putting it in every tenant's
//! deployment files is the wrong shape (auto-injection at deploy
//! time was Q2 option #1, rejected — auto-inject every tenant
//! pollutes their filesystem AND requires re-deploying every tenant
//! to update the shim). The chosen path (Q2 option #3, native Zig
//! resolution): compile once at NodeState init, share the bytecode
//! across every tenant.
//!
//! ## Lifecycle
//!
//! - **Build-time:** each `.mjs` file is `@embedFile`'d via build.zig's
//!   `js_runtime_files` table (entries with `builtin_*` prefix).
//! - **Startup:** `init(allocator)` spins up a throwaway QJS
//!   Runtime + Context, compiles each source to portable bytecode
//!   via `compileToBytecode`, stores the owned `[]u8` in the map.
//!   The Runtime + Context are freed before init returns; the
//!   bytecode buffers outlive them.
//! - **Runtime:** `worker.resolveDeployment` looks up `module_path`
//!   in `NodeState.builtin_modules` (which holds the map this
//!   module returned) when the path starts with `__system/`.
//! - **Shutdown:** `deinit(map, allocator)` frees each bytecode
//!   slice and the map's backing storage.
//!
//! Adding a new built-in: drop a `.mjs` under `src/js/builtin_modules/`,
//! add an entry to `js_runtime_files` in `build.zig` AND an entry to
//! `MODULES` here.

const std = @import("std");
const qjs = @import("rove-qjs");

/// (registered path, embedded JS source). The registered path is
/// what the dispatcher matches `module_path` against — customers
/// (and the shim) reference `__system/<name>` (no extension);
/// the resolver appends `.mjs` like it does for tenant modules.
const MODULES = [_]struct {
    /// Path-without-suffix; the resolver appends `.mjs` to match
    /// tenant-side ergonomics (customer writes `on_chunk:
    /// "__system/webhook_onresult"`).
    path: []const u8,
    /// Source string (`@embedFile`'d).
    src: []const u8,
}{
    .{
        .path = "__system/webhook_onresult.mjs",
        .src = @embedFile("builtin_webhook_onresult_mjs"),
    },
    .{
        // §2.6 durable scheduled wake (docs/durable-wake-plan.md P1).
        .path = "__system/scheduler_tick.mjs",
        .src = @embedFile("builtin_scheduler_tick_mjs"),
    },
    .{
        // Handler-surface Phase 5: the `cron(...)` recurrence engine.
        .path = "__system/cron_tick.mjs",
        .src = @embedFile("builtin_cron_tick_mjs"),
    },
    .{
        // `docs/blob-storage-plan.md` P1: blob.put's marker-settling
        // result handler.
        .path = "__system/blob_onresult.mjs",
        .src = @embedFile("builtin_blob_onresult_mjs"),
    },
};

/// Compile every built-in module to QJS bytecode and return an
/// owned `path → bytecode` map. The QJS Runtime + Context used for
/// compilation are local; bytecode is portable across runtimes
/// built from the same QJS so the returned bytecodes can be eval'd
/// in any per-tenant context.
///
/// Errors propagate — a baked-in module that won't compile is a
/// build-time bug that should fail loud at startup, not silently
/// disable the shim. Owned slices on the returned map are freed
/// via `deinit`.
pub fn init(allocator: std.mem.Allocator) !std.StringHashMapUnmanaged([]u8) {
    var map: std.StringHashMapUnmanaged([]u8) = .empty;
    errdefer {
        var it = map.iterator();
        while (it.next()) |e| allocator.free(e.value_ptr.*);
        map.deinit(allocator);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    for (MODULES) |m| {
        // The `filename` argument is for stack traces / module
        // identity inside QJS. Use the registered path so a
        // throw inside a built-in module surfaces as
        // `__system/<name>` in the stack — matches how customers
        // see their own module names.
        const filename_z = try allocator.dupeZ(u8, m.path);
        defer allocator.free(filename_z);
        const bc = try ctx.compileToBytecode(
            m.src,
            filename_z,
            allocator,
            .{ .kind = .module },
        );
        errdefer allocator.free(bc);
        try map.put(allocator, m.path, bc);
    }
    return map;
}

/// Free every bytecode buffer + the map's backing storage.
pub fn deinit(map: *std.StringHashMapUnmanaged([]u8), allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |e| allocator.free(e.value_ptr.*);
    map.deinit(allocator);
}

/// True iff `module_path` belongs to the `__system/` namespace —
/// the runtime falls through to `init`'s map when this is true.
pub fn isBuiltinPath(module_path: []const u8) bool {
    return std.mem.startsWith(u8, module_path, "__system/");
}

test "init compiles every built-in to non-empty bytecode" {
    const testing = std.testing;
    var map = try init(testing.allocator);
    defer deinit(&map, testing.allocator);
    try testing.expectEqual(MODULES.len, map.count());
    var it = map.iterator();
    while (it.next()) |e| try testing.expect(e.value_ptr.*.len > 0);
}

test "isBuiltinPath matches the __system/ prefix only" {
    const testing = std.testing;
    try testing.expect(isBuiltinPath("__system/webhook_onresult"));
    try testing.expect(isBuiltinPath("__system/webhook_onresult.mjs"));
    try testing.expect(!isBuiltinPath("hooks/onDelivered"));
    try testing.expect(!isBuiltinPath("_subscriptions/foo/index.mjs"));
    try testing.expect(!isBuiltinPath(""));
}
