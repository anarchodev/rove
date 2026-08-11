// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Built-in handler modules — the `__system/` namespace.
//!
//! Module paths in this namespace resolve without those modules being
//! in any tenant's deployment files.
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
//! deployment files is the wrong shape — auto-injecting into every
//! tenant pollutes their filesystem AND requires re-deploying every
//! tenant to update the shim. Instead, native Zig resolution compiles
//! once at NodeState init and shares the bytecode across every tenant.
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
    /// May a durable wake fire this module? (rove#495)
    ///
    /// A `_sched/` record names its own dispatch target, and `_sched/` is
    /// customer-writable by design (`reserved.zig`'s
    /// `SHIM_WRITABLE_PREFIXES`) so the `schedule` shim can arm wakes from
    /// handler context. So the target of a wake is customer input, and a
    /// baked module reached that way runs with `is_system_module` — the
    /// engine grants it from the module PATH, not from who armed the entry.
    ///
    /// Default false: a module is unreachable by wake unless it says
    /// otherwise. That inverts the old default, where every baked module was
    /// reachable and safety rested on each one independently choosing to be
    /// defensive about its ctx and its marker. Modules fired by a fetch
    /// result (`on_chunk` targets) or directly by the engine are not wake
    /// targets and stay false.
    wake_targetable: bool = false,
}{
    .{
        .path = "__system/webhook_onresult.mjs",
        .src = @embedFile("builtin_webhook_onresult_mjs"),
    },
    .{
        // durable-wake-plan P5(a): the wake-fired half of webhook.send
        // (scheduled fires, retry re-arms, crash-recovery watchdog).
        .path = "__system/webhook_fire.mjs",
        .src = @embedFile("builtin_webhook_fire_mjs"),
        .wake_targetable = true,
    },
    .{
        // §2.6 durable scheduled wake (durable-wake P1; docs/architecture/effects-and-handlers.md).
        .path = "__system/scheduler_tick.mjs",
        .src = @embedFile("builtin_scheduler_tick_mjs"),
    },
    .{
        // The `cron(...)` recurrence engine.
        .path = "__system/cron_tick.mjs",
        .src = @embedFile("builtin_cron_tick_mjs"),
        .wake_targetable = true,
    },
    .{
        // rove#340: the durable data-export job — walks the tenant's KV into
        // content-addressed parts, one part per activation.
        .path = "__system/export_run.mjs",
        .src = @embedFile("builtin_export_run_mjs"),
        .wake_targetable = true,
    },
    .{
        // blob-storage-plan P1; `docs/architecture/routing-and-ingress.md`: blob.put's marker-settling
        // result handler.
        .path = "__system/blob_onresult.mjs",
        .src = @embedFile("builtin_blob_onresult_mjs"),
    },
    .{
        // blob-write-recipes.md §4: the seal-time prompt compose —
        // assembles the recipe rows and hands the payload to blob.put.
        .path = "__system/blob_compose.mjs",
        .src = @embedFile("builtin_blob_compose_mjs"),
    },
    .{
        // blob-write-recipes.md §4–5: the flip (delete recipe +
        // pending row) and the customer {on} handoff.
        .path = "__system/blob_compose_onresult.mjs",
        .src = @embedFile("builtin_blob_compose_onresult_mjs"),
    },
    .{
        // blob-storage-plan §6; `docs/architecture/routing-and-ingress.md`: segments.seal's swap half
        // (index write + hot-row delete after the segment PUT
        // confirmed).
        .path = "__system/segments_onsealed.mjs",
        .src = @embedFile("builtin_segments_onsealed_mjs"),
    },
    .{
        // Engine-fired deploy-static streamer ("onStatic"): on an LRU miss for
        // a stable static path, the engine dispatches here with the content
        // hash injected (request.ctx) and this streams the blob from the
        // tenant's own file-blobs to the held connection.
        .path = "__system/static.mjs",
        .src = @embedFile("builtin_static_mjs"),
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

/// True iff a durable wake may fire `target` (rove#495).
///
/// Only meaningful for `__system/` targets; a customer module is always a
/// legitimate wake target (it is the tenant's own code, running with no
/// platform privilege), so callers check this only when `isBuiltinPath`.
///
/// EXACT match against a `wake_targetable` entry, in either the extensionless
/// spelling the shims write (`__system/webhook_fire`) or the registry's own
/// (`…​.mjs`). Exactness is the point: it also refuses the `module.method`
/// form, so a customer cannot reach an arbitrary named export of a baked
/// module by arming `__system/webhook_fire.mjs.someExport`. Baked modules are
/// entered through their default export or not at all.
pub fn isWakeTargetable(target: []const u8) bool {
    for (MODULES) |m| {
        if (!m.wake_targetable) continue;
        if (std.mem.eql(u8, target, m.path)) return true;
        const bare = m.path[0 .. m.path.len - ".mjs".len];
        if (std.mem.eql(u8, target, bare)) return true;
    }
    return false;
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

test "isWakeTargetable: only the three wake-driven jobs, and only by exact name" {
    const testing = std.testing;

    // The legitimate wake targets: a scheduled/retried send, the export
    // job's watchdog, and the cron recurrence engine. Both spellings — the
    // shims arm the extensionless form, the registry holds the `.mjs` one.
    for ([_][]const u8{ "webhook_fire", "export_run", "cron_tick" }) |name| {
        var bare_buf: [64]u8 = undefined;
        const bare = try std.fmt.bufPrint(&bare_buf, "__system/{s}", .{name});
        try testing.expect(isWakeTargetable(bare));
        var mjs_buf: [64]u8 = undefined;
        const mjs = try std.fmt.bufPrint(&mjs_buf, "__system/{s}.mjs", .{name});
        try testing.expect(isWakeTargetable(mjs));
    }

    // Everything else baked in is reachable only by the engine or by a fetch
    // result. A tenant can write the `_sched/` row naming one of these — the
    // prefix is customer-writable — so this list is what stops the row from
    // becoming a dispatch.
    for ([_][]const u8{
        "__system/scheduler_tick",
        "__system/webhook_onresult",
        "__system/blob_compose",
        "__system/blob_onresult",
        "__system/blob_compose_onresult",
        "__system/segments_onsealed",
        "__system/static",
    }) |path| {
        try testing.expect(!isWakeTargetable(path));
    }

    // Exactness matters as much as membership: the `module.method` form must
    // not smuggle an arbitrary named export of a wake-targetable module.
    try testing.expect(!isWakeTargetable("__system/webhook_fire.mjs.someExport"));
    try testing.expect(!isWakeTargetable("__system/export_run.mjs.default"));
    // Neither may a look-alike.
    try testing.expect(!isWakeTargetable("__system/webhook_fire_evil"));
    try testing.expect(!isWakeTargetable("__system/"));
    try testing.expect(!isWakeTargetable(""));
    // A customer module is not this predicate's business — callers ask only
    // when `isBuiltinPath`, and it is false for these.
    try testing.expect(!isBuiltinPath("jobs/reminder"));
    try testing.expect(!isBuiltinPath("reports.mjs.weekly"));
}

test "every wake-targetable module is one the platform actually arms" {
    // The list is a grant, so it should be justified rather than inherited:
    // each entry below is armed by name somewhere in the tree (webhook.js and
    // webhook_onresult arm `webhook_fire`; the export package and export_run
    // arm `export_run`; the cron package and cron_tick arm `cron_tick`). If a
    // module stops being armed, it should lose the flag rather than keep a
    // standing invitation.
    var count: usize = 0;
    for (MODULES) |m| {
        if (m.wake_targetable) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}
