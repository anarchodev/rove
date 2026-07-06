//! Executable-examples lint — the docs' teeth.
//!
//! Every code example a customer can copy — the ```js fences in
//! `docs/handler-shape.md` and the `@example` blocks in the
//! `globals/*.js` shim JSDoc — is checked in `zig build test`:
//!
//!   Gate A (all examples): compiles as a module. Syntax drift fails
//!           the build.
//!   Gate B (all examples): contains no RETIRED spelling (the
//!           handler-shape §10 what's-gone list, kept in sync below).
//!           This is the gate that would have caught every drift
//!           instance the 2026-07 ergonomics audit found — `kv.range`
//!           fiction, `request.result`, the pre-rename `on.*` verbs —
//!           years before a reader did.
//!   Gate C (drivable examples): EXECUTES against the real baked
//!           globals through the dispatcher, with a chameleon stub
//!           standing in for the example's deliberate free variables
//!           (`process(...)`, `API_A`, …). A handler exception fails
//!           the build — so an example calling `kv.range(...)` (a
//!           method that doesn't exist) dies here even if a future
//!           retired-spellings gap misses it. Drivable = a snippet
//!           (wrapped in `export function go(){…}`) or a module with a
//!           `default` export; named-export-only module examples (a
//!           chunk/wake handler needing a specific activation shape)
//!           get Gates A+B only.
//!
//! When this lint fails, FIX THE EXAMPLE (usually by making it
//! self-contained — better docs) rather than weakening a gate. If an
//! example genuinely cannot execute (it illustrates a shape that needs
//! live infrastructure), mark its opening fence ```js (doc-only) or
//! put `// doc-only` as the @example's first line — Gates A+B still
//! apply.

const std = @import("std");
const qjs = @import("rove-qjs");
const kv_mod = @import("raft-kv");

const dispatcher_mod = @import("dispatcher.zig");
const globals = @import("globals.zig");
const request_mod = @import("request.zig");

const testing = std.testing;

const HANDLER_SHAPE_MD = @embedFile("handler_shape_md");

// ── Gate B: retired spellings ───────────────────────────────────────
//
// Mirror of handler-shape.md §10 ("What's gone"). Adding a retirement
// there means adding its copyable spelling here — that is the whole
// maintenance burden, and it is what keeps examples from quietly
// resurrecting a retired surface.
const RetiredSpelling = struct { pattern: []const u8, hint: []const u8 };
const RETIRED_SPELLINGS = [_]RetiredSpelling{
    .{ .pattern = "on.fetch(", .hint = "the connection-wake namespace is `after.*` (after.fetch)" },
    .{ .pattern = "on.kv(", .hint = "the connection-wake namespace is `after.*` (after.kv)" },
    .{ .pattern = "on.timer(", .hint = "the connection-wake namespace is `after.*` (after.ms)" },
    .{ .pattern = "scheduler.after(", .hint = "the durable delay verb is `scheduler.in`" },
    .{ .pattern = "webhook.send({", .hint = "webhook.send takes a positional url: webhook.send(url, opts)" },
    .{ .pattern = "on_result", .hint = "the universal callback-target key is `{on}`" },
    .{ .pattern = "{ to:", .hint = "the universal callback-target key is `{on}`" },
    .{ .pattern = "{to:", .hint = "the universal callback-target key is `{on}`" },
    .{ .pattern = "request.body", .hint = "the payload surface is request.bytes / .text / .json" },
    .{ .pattern = "request.result", .hint = "results are flattened: request.bytes/.text/.json + .status/.ok/.done" },
    .{ .pattern = "activation.msg", .hint = "a schedule/cron target's payload is request.ctx (one-ctx)" },
    .{ .pattern = "kv.range(", .hint = "kv.range does not exist; page by key with kv.prefix(prefix, cursor, limit)" },
    .{ .pattern = "body_truncated", .hint = "handler-visible fields are camelCase: bodyTruncated" },
    .{ .pattern = "scheduled_at_ns", .hint = "handler-visible fields are camelCase: scheduledAtNs" },
    .{ .pattern = "onBoot", .hint = "kind=boot subscriptions are retired; seed registrations from any handler activation" },
    .{ .pattern = "http.send(", .hint = "durable outbound is webhook.send(url, opts)" },
};

// ── Example extraction ──────────────────────────────────────────────

const Example = struct {
    /// Where it came from, for failure messages ("handler-shape.md fence 3",
    /// "webhook.js @example 1").
    origin: []const u8,
    /// The example source, dedented.
    src: []const u8,
    /// First line was `// doc-only` / fence tagged `(doc-only)`.
    doc_only: bool,
};

/// Collect ```js fenced blocks from markdown. Fences tagged
/// ```js (doc-only) are collected with `doc_only = true`.
fn collectMdFences(a: std.mem.Allocator, md: []const u8, out: *std.ArrayListUnmanaged(Example)) !void {
    var idx: usize = 0;
    var n: usize = 0;
    while (std.mem.indexOfPos(u8, md, idx, "```js")) |open| {
        const line_end = std.mem.indexOfScalarPos(u8, md, open, '\n') orelse break;
        const tag = md[open + 5 .. line_end];
        // Exactly ```js — not ```json (or any other prefix-sharing tag).
        if (tag.len > 0 and tag[0] != ' ') {
            idx = line_end + 1;
            continue;
        }
        const doc_only = std.mem.indexOf(u8, tag, "doc-only") != null;
        const close = std.mem.indexOfPos(u8, md, line_end + 1, "\n```") orelse break;
        n += 1;
        try out.append(a, .{
            .origin = try std.fmt.allocPrint(a, "handler-shape.md fence {d}", .{n}),
            .src = md[line_end + 1 .. close + 1],
            .doc_only = doc_only,
        });
        idx = close + 4;
    }
}

/// Collect `@example` blocks from a JSDoc'd shim source. An example
/// runs from the line after `@example` to the next `@tag` or the end
/// of its comment block; the leading ` * ` scaffolding is stripped.
fn collectJsdocExamples(
    a: std.mem.Allocator,
    name: []const u8,
    src: []const u8,
    out: *std.ArrayListUnmanaged(Example),
) !void {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var in_example = false;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    while (lines.next()) |raw| {
        const line = std.mem.trimLeft(u8, raw, " \t");
        const star = std.mem.startsWith(u8, line, "*");
        const content = if (star) std.mem.trimLeft(u8, line[1..], " ") else line;
        const ends_comment = std.mem.indexOf(u8, line, "*/") != null;
        const is_tag = star and std.mem.startsWith(u8, content, "@");
        if (in_example and (is_tag or ends_comment or !star)) {
            n += 1;
            try out.append(a, .{
                .origin = try std.fmt.allocPrint(a, "{s} @example {d}", .{ name, n }),
                .src = try buf.toOwnedSlice(a),
                .doc_only = false,
            });
            in_example = false;
        }
        if (is_tag and std.mem.startsWith(u8, content, "@example")) {
            in_example = true;
            buf.clearRetainingCapacity();
            continue;
        }
        if (in_example) {
            try buf.appendSlice(a, content);
            try buf.append(a, '\n');
        }
    }
}

fn collectAll(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(Example)) !void {
    try collectMdFences(a, HANDLER_SHAPE_MD, out);
    for (globals.GLOBALS_FILES) |g| {
        try collectJsdocExamples(a, g.name, g.src, out);
    }
}

fn isDocOnly(ex: Example) bool {
    if (ex.doc_only) return true;
    const first = std.mem.trimLeft(u8, ex.src, " \t\n");
    return std.mem.startsWith(u8, first, "// doc-only");
}

/// Config-first / key-first library shims: every example presumes a
/// deployed `_config/*` file, real key material, or the admin plane —
/// their `fromConfig(...)` fail-loud errors ARE the documented
/// behavior. Gates A+B still apply to every one of their examples;
/// only Gate C (execution) is skipped. Handler-SURFACE examples must
/// never land here — fix or `// doc-only` those individually.
const EXEC_EXEMPT_SHIMS = [_][]const u8{
    "oauth", "oidc", "sessions", "activitypub", "platform", "crypto", "jwt",
};

fn isExecExempt(ex: Example) bool {
    for (EXEC_EXEMPT_SHIMS) |name| {
        if (std.mem.startsWith(u8, ex.origin, name) and
            ex.origin.len > name.len and ex.origin[name.len] == ' ')
        {
            return true;
        }
    }
    return false;
}

// ── Gate C: the chameleon stub + free-variable prelude ─────────────

/// A value that survives most example uses of an undefined helper:
/// callable (returns itself), member-access (returns itself),
/// stringifies + JSON-serializes to "stub".
const STUB_DECL =
    \\const __stub = (() => {
    \\  const f = function () { return f; };
    \\  f.toString = () => "stub";
    \\  f.toJSON = () => "stub";
    \\  f[Symbol.toPrimitive] = () => "stub";
    \\  f[Symbol.iterator] = function* () {};
    \\  return f;
    \\})();
    \\
;

const JsTokenIter = struct {
    src: []const u8,
    i: usize = 0,
    /// Inside a template literal's text (between backticks, outside ${…}).
    in_template: bool = false,
    /// Brace depth inside a template interpolation (0 = not in one).
    interp_depth: usize = 0,

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
    }
    fn isIdent(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }

    /// Next bare identifier that is not a property access (`.name`) and
    /// not inside a string/comment. Approximate — good enough because
    /// every emitted name is existence-guarded at runtime.
    fn next(self: *JsTokenIter) ?[]const u8 {
        const s = self.src;
        while (self.i < s.len) {
            const c = s[self.i];
            // Template-literal text: consume until the closing backtick
            // or a `${` interpolation (whose expression scans normally,
            // brace-tracked, then drops back to template text).
            if (self.in_template and self.interp_depth == 0) {
                if (c == '\\') {
                    self.i += 2;
                    continue;
                }
                if (c == '`') {
                    self.in_template = false;
                    self.i += 1;
                    continue;
                }
                if (c == '$' and self.i + 1 < s.len and s[self.i + 1] == '{') {
                    self.interp_depth = 1;
                    self.i += 2;
                    continue;
                }
                self.i += 1;
                continue;
            }
            if (self.interp_depth > 0) {
                if (c == '{') self.interp_depth += 1;
                if (c == '}') {
                    self.interp_depth -= 1;
                    if (self.interp_depth == 0) {
                        self.i += 1;
                        continue; // back to template text
                    }
                }
            }
            // Skip plain strings; template interpolations (`${user}`)
            // scan as code via the state machine above.
            if (c == '"' or c == '\'') {
                const q = c;
                self.i += 1;
                while (self.i < s.len and s[self.i] != q) {
                    if (s[self.i] == '\\') self.i += 1;
                    self.i += 1;
                }
                self.i += 1;
                continue;
            }
            if (c == '`') {
                self.in_template = true;
                self.i += 1;
                continue;
            }
            // Skip comments.
            if (c == '/' and self.i + 1 < s.len and s[self.i + 1] == '/') {
                while (self.i < s.len and s[self.i] != '\n') self.i += 1;
                continue;
            }
            if (c == '/' and self.i + 1 < s.len and s[self.i + 1] == '*') {
                self.i += 2;
                while (self.i + 1 < s.len and !(s[self.i] == '*' and s[self.i + 1] == '/')) self.i += 1;
                self.i += 2;
                continue;
            }
            if (isIdentStart(c)) {
                // Property access? Look back for the nearest non-space char.
                var j = self.i;
                var prop = false;
                while (j > 0) {
                    j -= 1;
                    if (s[j] == ' ' or s[j] == '\t') continue;
                    prop = s[j] == '.';
                    break;
                }
                const start = self.i;
                while (self.i < s.len and isIdent(s[self.i])) self.i += 1;
                if (!prop) return s[start..self.i];
                continue;
            }
            self.i += 1;
        }
        return null;
    }
};

/// Emit `if (!("N" in globalThis)) globalThis["N"] = __stub;` for every
/// bare identifier in the example. The runtime existence guard makes an
/// over-approximate token scan safe: real globals are never shadowed,
/// and stubbing an unused name is a no-op.
fn buildPrelude(a: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, STUB_DECL);
    // Continuation-shaped snippets read request.ctx; the harness drives
    // a plain inbound where it's absent — stand a stub in.
    try out.appendSlice(a, "if (typeof request !== \"undefined\" && !(\"ctx\" in request)) request.ctx = __stub;\n");
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(a);
    var it = JsTokenIter{ .src = src };
    while (it.next()) |tok| {
        const gop = try seen.getOrPut(a, tok);
        if (gop.found_existing) continue;
        // Convention in the examples: SCREAMING_CASE = a constant
        // placeholder (LLM_URL, API_A) — stub as a string so strict
        // natives (after.fetch url, webhook.send url) accept it.
        // Anything else = a helper — the callable chameleon.
        var caps = tok.len > 1;
        for (tok) |ch| {
            if (!((ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_')) {
                caps = false;
                break;
            }
        }
        if (caps) {
            try out.writer(a).print(
                "if (!(\"{s}\" in globalThis)) globalThis[\"{s}\"] = \"https://stub.invalid/{s}\";\n",
                .{ tok, tok, tok },
            );
        } else {
            try out.writer(a).print(
                "if (!(\"{s}\" in globalThis)) globalThis[\"{s}\"] = __stub;\n",
                .{ tok, tok },
            );
        }
    }
    return out.toOwnedSlice(a);
}

// ── The gates ───────────────────────────────────────────────────────

/// True when the example is a module (a line starts with `export `) —
/// an `export` inside a comment doesn't count.
fn isModuleShaped(src: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimLeft(u8, raw, " \t");
        if (std.mem.startsWith(u8, line, "export ")) return true;
    }
    return false;
}

fn hasDefaultExport(src: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimLeft(u8, raw, " \t");
        if (std.mem.startsWith(u8, line, "export default")) return true;
    }
    return false;
}

fn moduleSource(a: std.mem.Allocator, ex: Example) ![]u8 {
    const prelude = try buildPrelude(a, ex.src);
    defer a.free(prelude);
    if (isModuleShaped(ex.src)) {
        return std.fmt.allocPrint(a, "{s}{s}", .{ prelude, ex.src });
    }
    return std.fmt.allocPrint(a, "{s}export function go() {{\n{s}\n}}\n", .{ prelude, ex.src });
}

fn openTempKv(allocator: std.mem.Allocator, buf: *[64]u8) !*kv_mod.KvStore {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.bufPrintZ(buf, "/tmp/rove-doc-ex-{x}.db", .{seed});
    return try kv_mod.KvStore.open(allocator, path);
}

test "doc examples: retired spellings (Gate B) + compile (Gate A) + execute (Gate C)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var examples: std.ArrayListUnmanaged(Example) = .empty;
    try collectAll(a, &examples);
    // A silent extraction regression would make every gate pass on an
    // empty set — pin a floor well below the real count.
    if (examples.items.len < 20) {
        std.debug.print("\ndoc-examples: extraction found only {d} examples — extractor regression?\n", .{examples.items.len});
        return error.DocExampleExtractionRegression;
    }

    var failures: usize = 0;

    // Gate B — retired spellings, every example (doc-only included).
    for (examples.items) |ex| {
        for (RETIRED_SPELLINGS) |r| {
            if (std.mem.indexOf(u8, ex.src, r.pattern)) |_| {
                std.debug.print(
                    "\ndoc-examples GATE B [{s}]: uses retired spelling \"{s}\" — {s}\n--- example ---\n{s}\n",
                    .{ ex.origin, r.pattern, r.hint, ex.src },
                );
                failures += 1;
            }
        }
    }

    // Gate A + C.
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var cctx = try rt.newContext();
    defer cctx.deinit();

    var kv_buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &kv_buf);
    defer {
        kv.close();
        const path = std.mem.sliceTo(&kv_buf, 0);
        std.fs.cwd().deleteFile(path) catch {};
    }
    var d = try dispatcher_mod.Dispatcher.init(testing.allocator);
    defer d.deinit();

    for (examples.items) |ex| {
        const mod_src = try moduleSource(a, ex);

        // Gate A — compile.
        const bytecode = cctx.compileToBytecode(mod_src, "doc-example.mjs", a, .{ .kind = .module }) catch {
            const msg = cctx.takeExceptionMessage(a) catch null;
            std.debug.print(
                "\ndoc-examples GATE A [{s}]: does not compile: {s}\n--- example ---\n{s}\n",
                .{ ex.origin, msg orelse "(no message)", ex.src },
            );
            failures += 1;
            continue;
        };

        // Gate C — execute the drivable ones.
        if (isDocOnly(ex) or isExecExempt(ex)) continue;
        const is_module = isModuleShaped(ex.src);
        const has_default = hasDefaultExport(ex.src);
        if (is_module and !has_default) continue; // named-only: needs a specific activation shape

        var txn = try kv.beginTrackedImmediate();
        var txn_done = false;
        defer if (!txn_done) txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
        const request: request_mod.Request = .{
            .method = "POST",
            .path = "/",
            .body = "{\"a\":1}",
            .fn_override = if (has_default) null else "go",
            .trace = .{ .request_id = 1 },
        };
        var outcome = d.runOutcome(kv, &txn, &ws, bytecode, null, null, null, request, &budget) catch |err| {
            std.debug.print(
                "\ndoc-examples GATE C [{s}]: dispatch failed: {s}\n--- example ---\n{s}\n",
                .{ ex.origin, @errorName(err), ex.src },
            );
            failures += 1;
            continue;
        };
        txn.commit() catch {};
        txn_done = true;
        switch (outcome) {
            .terminal => |*r| {
                defer r.deinit(testing.allocator);
                if (r.exception.len > 0) {
                    std.debug.print(
                        "\ndoc-examples GATE C [{s}]: example threw: {s}\n--- example ---\n{s}\n",
                        .{ ex.origin, r.exception, ex.src },
                    );
                    failures += 1;
                }
            },
            .continuation => |*cont| cont.deinit(testing.allocator),
            .stream => |*s| s.deinit(testing.allocator),
            .no_onheaders, .no_onchunk => {},
        }
    }

    if (failures > 0) {
        std.debug.print("\ndoc-examples: {d} failing example(s) — fix the example (preferred) or mark it doc-only\n", .{failures});
        return error.DocExamplesFailed;
    }
}
