//! The sim's module resolution — the offline half of `@scope/pkg` package
//! support (rove issue #50). Installed through the reactor's base-setup hook
//! (`arena_reactor_new_open_with`): the sim pairs its own `normalize` with
//! arenajs's proven tape loader via
//! `arena_install_replay_module_loader_normalize`, so bare package specifiers
//! resolve to `/pkg/<hash>/…` keys before the loader serves source from the
//! world — reusing the SAME `package_resolver` the worker uses, so the two
//! can't drift. When no packages are declared the resolver is null and
//! `normalize` is a pure `./`/`../` + bare-passthrough resolver, identical to
//! the loader's previous default.

const std = @import("std");
const c = @import("qjs_c.zig").c;
const package_resolver = @import("package_resolver");

/// Per-run module context, pointed at by the loader's opaque. Its address is
/// stable (heap-owned by the `Engine`); `simulate` sets `resolver` before each
/// run and clears it after. The tape loader serves source via the process-
/// global replay host, so only the resolver lives here.
pub const SimModCtx = struct {
    /// The world's package resolver, or null when the world declares no
    /// packages. Borrowed for the duration of one run.
    resolver: ?*const package_resolver.PackageResolver = null,
};

// arenajs replay bindings (declared here rather than via the reactor header's
// cImport so root.zig keeps its hand-written reactor externs).
extern fn arena_install_replay_bindings(ctx: ?*c.JSContext) c_int;
extern fn arena_install_replay_module_loader_normalize(
    rt: ?*c.JSRuntime,
    normalize: ?*const NormalizeFn,
    opaque_ptr: ?*anyopaque,
) c_int;

const NormalizeFn = fn (?*c.JSContext, [*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) [*c]u8;

/// Scratch for a normalized path. 512 mirrors the worker's `static_buf`.
threadlocal var scratch: [512]u8 = undefined;

/// The reactor base-setup hook (`arena_base_setup_fn`): install the replay
/// kv/crypto bindings, then the tape loader paired with our normalizer. `user`
/// is the `*SimModCtx` and flows to `normalize` as its opaque. Params are
/// `?*anyopaque` (cast to the qjs types here) so root.zig — which owns no
/// `@cImport` — can name this hook's type when declaring the reactor extern.
pub fn simSetup(ctx: ?*anyopaque, rt: ?*anyopaque, user: ?*anyopaque) callconv(.c) c_int {
    if (arena_install_replay_bindings(@ptrCast(ctx)) < 0) return -1;
    _ = arena_install_replay_module_loader_normalize(@ptrCast(rt), &normalize, user);
    return 0;
}

/// qjs module normalizer. Bare `@scope/pkg` resolves per-importer via the
/// world's `PackageResolver` (app surface vs. a package's own encapsulated
/// deps); everything else (relative, `__system/*`, undeclared) falls to the
/// path resolver — the same shape as the worker's `module_loader.normalize`.
/// Returns a `js_malloc`'d, NUL-terminated buffer quickjs owns.
fn normalize(
    ctx: ?*c.JSContext,
    base: [*c]const u8,
    name: [*c]const u8,
    opaque_ptr: ?*anyopaque,
) callconv(.c) [*c]u8 {
    const base_s = if (base != null) std.mem.span(base) else "";
    const name_s = if (name != null) std.mem.span(name) else "";

    if (opaque_ptr) |op| {
        const mc: *const SimModCtx = @ptrCast(@alignCast(op));
        if (mc.resolver) |r| {
            if (!std.mem.startsWith(u8, name_s, "./") and !std.mem.startsWith(u8, name_s, "../")) {
                if (r.resolve(base_s, name_s)) |key| return dupToJs(ctx, key);
            }
        }
    }

    const resolved = package_resolver.resolveSpecifier(base_s, name_s, scratch[0..]);
    return dupToJs(ctx, resolved);
}

/// Copy `s` into a qjs-allocated NUL-terminated buffer quickjs owns.
fn dupToJs(ctx: ?*c.JSContext, s: []const u8) [*c]u8 {
    const out = c.js_malloc(ctx, s.len + 1) orelse return null;
    const p: [*]u8 = @ptrCast(out);
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    return p;
}
