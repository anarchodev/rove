//! `connection-holder-standalone` — runs the held-socket subsystem as
//! a separate process. See `docs/connection-actor-plan.md` §9.
//!
//! Phase 1: no auth env yet (the `open` wake into the JS handler and
//! the held-synchronous projection land in Phases 2–3, which is where
//! auth wiring belongs). This binary just stands up the listener so
//! the skeleton is exercisable end-to-end on its own.
//!
//! Usage:
//!   connection-holder-standalone --listen <host:port>
//!                                [--tls-cert <path> --tls-key <path>]
//!                                [--max-held-total <N>]
//!                                [--max-held-per-tenant <N>]
//!                                [--hold-deadline-ms <MS>]

const std = @import("std");
const conn_holder = @import("rove-connection-holder");
const h2 = @import("rove-h2");

/// Layer-3 shared bearer for the worker → holder privileged channel.
/// Optional in Phase 2a (null → privileged routes 401, lets a smoke
/// spin up without it); the worker process supplies it in 2b.
const ENV_INTERNAL_TOKEN = "CONN_HOLDER_INTERNAL_TOKEN";

/// Worker origin the `open` wake (plan §6.1) is forwarded to. CLI
/// `--worker-base` overrides this.
const ENV_WORKER_BASE = "CONN_HOLDER_WORKER_BASE";

var stop_flag: std.atomic.Value(bool) = .init(false);

fn handleSignal(_: c_int) callconv(.c) void {
    stop_flag.store(true, .release);
}

fn installSignalHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

const Cli = struct {
    listen: []const u8 = "127.0.0.1:0",
    tls_cert: ?[]const u8 = null,
    tls_key: ?[]const u8 = null,
    max_held_total: u32 = 4096,
    max_held_per_tenant: u32 = 1024,
    hold_deadline_ms: i64 = 25_000,
    worker_base: ?[]const u8 = null,
    worker_insecure_tls: bool = false,
};

fn usage(stderr: *std.fs.File.Writer) !void {
    try stderr.interface.writeAll(
        \\usage: connection-holder-standalone --listen <host:port>
        \\                                    [--tls-cert <path> --tls-key <path>]
        \\                                    [--max-held-total <N>]
        \\                                    [--max-held-per-tenant <N>]
        \\                                    [--hold-deadline-ms <MS>]
        \\                                    [--worker-base <url>]
        \\                                    [--worker-insecure-tls]
        \\
        \\env (optional):
        \\  CONN_HOLDER_INTERNAL_TOKEN   layer-3 worker→holder bearer
        \\  CONN_HOLDER_WORKER_BASE      worker origin for the open wake
        \\
    );
    try stderr.interface.flush();
}

fn parseCli(argv: [][:0]u8) !Cli {
    var out: Cli = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--listen")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.listen = argv[i];
        } else if (std.mem.eql(u8, a, "--tls-cert")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.tls_cert = argv[i];
        } else if (std.mem.eql(u8, a, "--tls-key")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.tls_key = argv[i];
        } else if (std.mem.eql(u8, a, "--max-held-total")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.max_held_total = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--max-held-per-tenant")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.max_held_per_tenant = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--hold-deadline-ms")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.hold_deadline_ms = try std.fmt.parseInt(i64, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--worker-base")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.worker_base = argv[i];
        } else if (std.mem.eql(u8, a, "--worker-insecure-tls")) {
            out.worker_insecure_tls = true;
        } else {
            return error.Usage;
        }
    }
    if ((out.tls_cert == null) != (out.tls_key == null)) return error.Usage;
    return out;
}

fn parseHostPort(allocator: std.mem.Allocator, hp: []const u8) !std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return error.MalformedHostPort;
    const host = hp[0..colon];
    const port = try std.fmt.parseInt(u16, hp[colon + 1 ..], 10);
    if (std.mem.eql(u8, host, "localhost")) {
        return std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    }
    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);
    return try std.net.Address.parseIp(host_z, port);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stderr_buf: [512]u8 = undefined;
    var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
    const cli = parseCli(argv) catch {
        usage(&stderr_w) catch {};
        std.process.exit(2);
    };

    var tls_config: ?*h2.TlsConfig = null;
    defer if (tls_config) |c| c.destroy();
    if (cli.tls_cert) |cert| {
        tls_config = h2.TlsConfig.createFromFiles(allocator, cert, cli.tls_key.?, null) catch |err| {
            std.debug.print("error: tls: {s} (cert={s}, key={s})\n", .{ @errorName(err), cert, cli.tls_key.? });
            std.process.exit(2);
        };
        std.log.info("tls: loaded {s} + {s}", .{ cert, cli.tls_key.? });
    }

    const listen_addr = parseHostPort(allocator, cli.listen) catch |err| {
        std.debug.print("error: --listen {s}: {s}\n", .{ cli.listen, @errorName(err) });
        std.process.exit(2);
    };

    const internal_token: ?[]u8 = std.process.getEnvVarOwned(allocator, ENV_INTERNAL_TOKEN) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (internal_token) |t| allocator.free(t);

    // --worker-base wins; else env CONN_HOLDER_WORKER_BASE; else null
    // (wakes fall to the deadline — the 2a behaviour).
    const worker_base_env: ?[]u8 = if (cli.worker_base == null)
        std.process.getEnvVarOwned(allocator, ENV_WORKER_BASE) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        }
    else
        null;
    defer if (worker_base_env) |b| allocator.free(b);
    const worker_base: ?[]const u8 = cli.worker_base orelse worker_base_env;

    const handle = try conn_holder.standalone.spawn(.{
        .allocator = allocator,
        .bind_addr = listen_addr,
        .max_held_total = cli.max_held_total,
        .max_held_per_tenant = cli.max_held_per_tenant,
        .default_hold_deadline_ms = cli.hold_deadline_ms,
        .tls_config = tls_config,
        .internal_token = internal_token,
        .worker_base = worker_base,
        .worker_insecure_tls = cli.worker_insecure_tls,
    });
    defer handle.shutdown();

    const scheme: []const u8 = if (tls_config != null) "https" else "http";
    var stdout_buf: [128]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    try sw.interface.print("connection-holder-standalone listening on {s}://{s} (port {d})\n", .{
        scheme, cli.listen, handle.port,
    });
    try sw.interface.flush();

    installSignalHandlers();
    h2.TlsConfig.runReloadPoll(tls_config, &stop_flag);
}
