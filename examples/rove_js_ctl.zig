//! `rove-js-ctl` — admin CLI for rove-js workers.
//!
//! Talks HTTP/2 (h2c) to a running js-worker over the
//! `/_system/code/*` system surface. Every request carries an
//! `Authorization: Bearer <token>` header; the token comes from
//! `--token`, `$ROVE_TOKEN`, or (last resort) a missing-token error.
//!
//! Commands:
//!
//!     rove-js-ctl [--url URL] [--token TOK] ping
//!         Sanity-check that the worker is reachable and the token
//!         authenticates. Sends a deploy against a bogus instance;
//!         on a 403/404 the round-trip is proven.
//!
//!     rove-js-ctl [--url URL] [--token TOK] deploy <instance> <dir>
//!         Walk `<dir>` recursively, upload every file under it as
//!         a source entry keyed by its path relative to `<dir>`,
//!         then call `/_system/code/<instance>/deploy` to swap
//!         `deployment/current`. Prints the new deployment id.
//!
//! Defaults:
//!
//!   --url    http://127.0.0.1:8082
//!   --token  $ROVE_TOKEN
//!
//! The URL must be h2c (plain HTTP/2 without TLS) for now; TLS to
//! the worker is a Phase 6 thing.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const H2 = h2.H2(.{ .client = true });

// ── CLI ───────────────────────────────────────────────────────────────

const Cmd = enum { ping, deploy };

const Cli = struct {
    url: []const u8 = "http://127.0.0.1:8082",
    /// Owned by the caller if `token_owned` is true (came from
    /// `$ROVE_TOKEN` via `getEnvVarOwned`); borrowed from argv
    /// otherwise.
    token: ?[]const u8 = null,
    token_owned: bool = false,
    cmd: Cmd,
    /// Owned slice of borrowed `[]const u8`s pointing into argv.
    /// Deinit only frees the slice, not the elements.
    cmd_args: [][]const u8,

    fn deinit(self: *Cli, allocator: std.mem.Allocator) void {
        if (self.token_owned) {
            if (self.token) |t| allocator.free(t);
        }
        allocator.free(self.cmd_args);
    }
};

fn parseCli(allocator: std.mem.Allocator, argv: [][:0]u8) !Cli {
    var url: []const u8 = "http://127.0.0.1:8082";
    var token: ?[]const u8 = null;
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(allocator);

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--url")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            url = argv[i];
        } else if (std.mem.eql(u8, a, "--token")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            token = argv[i];
        } else {
            try positional.append(allocator, a);
        }
    }

    if (positional.items.len == 0) return error.Usage;
    const cmd: Cmd = if (std.mem.eql(u8, positional.items[0], "ping"))
        .ping
    else if (std.mem.eql(u8, positional.items[0], "deploy"))
        .deploy
    else
        return error.Usage;

    // Env fallback for token.
    var token_owned = false;
    if (token == null) {
        if (std.process.getEnvVarOwned(allocator, "ROVE_TOKEN")) |env_tok| {
            token = env_tok;
            token_owned = true;
        } else |_| {}
    }

    const cmd_args = try allocator.dupe([]const u8, positional.items[1..]);
    return .{
        .url = url,
        .token = token,
        .token_owned = token_owned,
        .cmd = cmd,
        .cmd_args = cmd_args,
    };
}

fn printUsage() !void {
    var buf: [1024]u8 = undefined;
    var sw = std.fs.File.stderr().writer(&buf);
    try sw.interface.writeAll(
        \\usage: rove-js-ctl [opts] <cmd> [cmd-args...]
        \\
        \\  Options:
        \\    --url URL          worker h2c URL (default http://127.0.0.1:8082)
        \\    --token HEX        64-char root token (default $ROVE_TOKEN)
        \\
        \\  Commands:
        \\    ping
        \\        Sanity-check worker reachability + token.
        \\    deploy <instance> <dir>
        \\        Upload every file under <dir> and publish a new deployment.
        \\
    );
    try sw.interface.flush();
}

// ── URL parsing ───────────────────────────────────────────────────────

const Target = struct {
    host: []const u8, // owned
    port: u16,
    addr: std.net.Address,

    fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
    }
};

fn parseUrl(allocator: std.mem.Allocator, url: []const u8) !Target {
    const prefix = "http://";
    if (!std.mem.startsWith(u8, url, prefix)) return error.UnsupportedScheme;
    const rest = url[prefix.len..];
    // Strip trailing path if any (we only care about host:port).
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const hostport = rest[0..slash];
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse
        return error.MissingPort;
    const host = hostport[0..colon];
    const port_str = hostport[colon + 1 ..];
    const port = try std.fmt.parseInt(u16, port_str, 10);

    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);
    const addr = try std.net.Address.parseIp(host_z, port);

    const host_owned = try allocator.dupe(u8, host);
    return .{ .host = host_owned, .port = port, .addr = addr };
}

// ── HTTP/2 client wrapper ─────────────────────────────────────────────

const Response = struct {
    status: u16,
    body: []u8, // owned by allocator — caller frees

    fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

const Client = struct {
    allocator: std.mem.Allocator,
    reg: *rove.Registry,
    h2c: *H2,
    target: Target,
    session: rove.Entity,

    fn open(allocator: std.mem.Allocator, reg: *rove.Registry, target: Target) !Client {
        // Bind the client's own listen address to 127.0.0.1:0 — the
        // rove-h2 client still needs a listen fd even in pure-client
        // mode (rove-io doesn't support create-without-listen yet).
        const bind_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        const h2c = try H2.create(reg, allocator, bind_addr, .{
            .max_connections = 4,
            .buf_count = 16,
            .buf_size = 64 * 1024,
        }, .{});
        errdefer h2c.destroy();

        // Issue the connect and drain until it lands.
        const conn = try reg.create(&h2c.client_connect_in);
        try reg.set(conn, &h2c.client_connect_in, h2.ConnectTarget, .{ .addr = target.addr });

        var ticks: u32 = 0;
        var session: rove.Entity = rove.Entity.nil;
        while (ticks < 200) : (ticks += 1) {
            try h2c.poll(0);

            const outs = h2c.client_connect_out.entitySlice();
            if (outs.len > 0) {
                const sess_comp = try reg.get(outs[0], &h2c.client_connect_out, h2.Session);
                session = sess_comp.entity;
                try reg.destroy(outs[0]);
                try reg.flush();
                break;
            }
            const errs = h2c.client_connect_errors.entitySlice();
            if (errs.len > 0) {
                const io = try reg.get(errs[0], &h2c.client_connect_errors, h2.H2IoResult);
                std.log.err("connect failed: {d}", .{io.err});
                try reg.destroy(errs[0]);
                try reg.flush();
                h2c.destroy();
                return error.ConnectFailed;
            }
        }
        if (session.index == 0 and session.generation == 0) {
            h2c.destroy();
            return error.ConnectTimeout;
        }

        return .{
            .allocator = allocator,
            .reg = reg,
            .h2c = h2c,
            .target = target,
            .session = session,
        };
    }

    fn close(self: *Client) void {
        self.h2c.destroy();
    }

    /// Send an HTTP request and block until the response comes back.
    /// `headers` is a list of name/value pairs; pseudo-headers
    /// (`:method`, `:path`, `:scheme`, `:authority`) are synthesized
    /// automatically from `method`, `path`, and the connection target.
    /// `body` is sent verbatim; pass `&.{}` for an empty body.
    ///
    /// Returns a `Response` that borrows nothing — the body is dup'd
    /// out of rove-h2's buffer pool and the caller frees it.
    fn request(
        self: *Client,
        method: []const u8,
        path: []const u8,
        extra_headers: []const h2.HeaderField,
        body: []const u8,
    ) !Response {
        const allocator = self.allocator;
        const reg = self.reg;

        // Synthesize authority from the target.
        var authority_buf: [256]u8 = undefined;
        const authority = try std.fmt.bufPrint(
            &authority_buf,
            "{s}:{d}",
            .{ self.target.host, self.target.port },
        );

        // Build the full header list: pseudo-headers first, then
        // caller's extras. All pointer fields reference stack-local
        // storage; we keep the stack frame alive until after
        // `reg.set` copies the slice into rove-h2's owned state.
        var all_headers: std.ArrayList(h2.HeaderField) = .empty;
        defer all_headers.deinit(allocator);

        try all_headers.append(allocator, .{
            .name = ":method",
            .name_len = 7,
            .value = method.ptr,
            .value_len = @intCast(method.len),
        });
        try all_headers.append(allocator, .{
            .name = ":path",
            .name_len = 5,
            .value = path.ptr,
            .value_len = @intCast(path.len),
        });
        try all_headers.append(allocator, .{
            .name = ":scheme",
            .name_len = 7,
            .value = "http",
            .value_len = 4,
        });
        try all_headers.append(allocator, .{
            .name = ":authority",
            .name_len = 10,
            .value = authority.ptr,
            .value_len = @intCast(authority.len),
        });
        for (extra_headers) |h| try all_headers.append(allocator, h);

        // Body copy — rove-h2 takes ownership on set. Must be heap
        // so the input slice can go away mid-flight.
        var body_copy: ?[*]u8 = null;
        var body_len: u32 = 0;
        if (body.len > 0) {
            const buf = try allocator.alloc(u8, body.len);
            @memcpy(buf, body);
            body_copy = buf.ptr;
            body_len = @intCast(body.len);
        }

        const req = try reg.create(&self.h2c.client_request_in);
        try reg.set(req, &self.h2c.client_request_in, h2.Session, .{ .entity = self.session });
        try reg.set(req, &self.h2c.client_request_in, h2.ReqHeaders, .{
            .fields = all_headers.items.ptr,
            .count = @intCast(all_headers.items.len),
        });
        try reg.set(req, &self.h2c.client_request_in, h2.ReqBody, .{
            .data = body_copy,
            .len = body_len,
        });
        try reg.flush();

        // Drain until the response entity appears in client_response_out.
        var ticks: u32 = 0;
        while (ticks < 2000) : (ticks += 1) {
            try self.h2c.poll(1);
            const outs = self.h2c.client_response_out.entitySlice();
            if (outs.len == 0) continue;

            const resp_ent = outs[0];
            const status = try reg.get(resp_ent, &self.h2c.client_response_out, h2.Status);
            const resp_body = try reg.get(resp_ent, &self.h2c.client_response_out, h2.RespBody);
            const io_res = try reg.get(resp_ent, &self.h2c.client_response_out, h2.H2IoResult);

            const owned_body = if (resp_body.data != null and resp_body.len > 0) blk: {
                const buf = try allocator.alloc(u8, resp_body.len);
                @memcpy(buf, resp_body.data.?[0..resp_body.len]);
                break :blk buf;
            } else try allocator.alloc(u8, 0);
            errdefer allocator.free(owned_body);

            if (io_res.err != 0) {
                std.log.warn("rove-js-ctl: upstream io error {d}", .{io_res.err});
            }

            try reg.destroy(resp_ent);
            try reg.flush();

            return .{
                .status = @intCast(status.code),
                .body = owned_body,
            };
        }
        return error.ResponseTimeout;
    }
};

// ── Commands ──────────────────────────────────────────────────────────

fn runPing(client: *Client, token: []const u8) !void {
    const auth_header = try std.fmt.allocPrint(client.allocator, "Bearer {s}", .{token});
    defer client.allocator.free(auth_header);

    const hdrs = [_]h2.HeaderField{
        .{
            .name = "authorization",
            .name_len = 13,
            .value = auth_header.ptr,
            .value_len = @intCast(auth_header.len),
        },
    };

    var resp = try client.request("POST", "/_system/code/__ping__/deploy", &hdrs, "");
    defer resp.deinit(client.allocator);

    std.debug.print("ping: worker reachable, status={d}\n", .{resp.status});
}

fn runDeploy(
    allocator: std.mem.Allocator,
    client: *Client,
    token: []const u8,
    instance: []const u8,
    dir_path: []const u8,
) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var upload_count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const rel_path = try allocator.dupe(u8, entry.path);
        defer allocator.free(rel_path);

        // Read the file contents.
        const file = try dir.openFile(entry.path, .{});
        defer file.close();
        const source = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
        defer allocator.free(source);

        // Build /_system/code/{instance}/upload path + headers.
        const upload_path = try std.fmt.allocPrint(
            allocator,
            "/_system/code/{s}/upload",
            .{instance},
        );
        defer allocator.free(upload_path);

        const hdrs = [_]h2.HeaderField{
            .{
                .name = "authorization",
                .name_len = 13,
                .value = auth_header.ptr,
                .value_len = @intCast(auth_header.len),
            },
            .{
                .name = "x-rove-path",
                .name_len = 11,
                .value = rel_path.ptr,
                .value_len = @intCast(rel_path.len),
            },
        };

        var resp = try client.request("POST", upload_path, &hdrs, source);
        defer resp.deinit(allocator);

        if (resp.status != 204) {
            std.log.err(
                "upload {s} failed: status={d} body={s}",
                .{ rel_path, resp.status, resp.body },
            );
            return error.UploadFailed;
        }
        std.debug.print("uploaded {s} ({d} bytes)\n", .{ rel_path, source.len });
        upload_count += 1;
    }

    if (upload_count == 0) {
        std.log.err("deploy: no files found under {s}", .{dir_path});
        return error.EmptyDirectory;
    }

    // Call deploy.
    const deploy_path = try std.fmt.allocPrint(
        allocator,
        "/_system/code/{s}/deploy",
        .{instance},
    );
    defer allocator.free(deploy_path);

    const deploy_hdrs = [_]h2.HeaderField{
        .{
            .name = "authorization",
            .name_len = 13,
            .value = auth_header.ptr,
            .value_len = @intCast(auth_header.len),
        },
    };

    var resp = try client.request("POST", deploy_path, &deploy_hdrs, "");
    defer resp.deinit(allocator);

    if (resp.status != 200) {
        std.log.err(
            "deploy failed: status={d} body={s}",
            .{ resp.status, resp.body },
        );
        return error.DeployFailed;
    }

    std.debug.print(
        "deployed {d} file(s) to instance {s}; id={s}",
        .{ upload_count, instance, resp.body },
    );
}

// ── main ──────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var cli = parseCli(allocator, argv) catch {
        try printUsage();
        std.process.exit(2);
    };
    defer cli.deinit(allocator);

    const token = cli.token orelse {
        std.log.err("missing token — pass --token or set $ROVE_TOKEN", .{});
        std.process.exit(2);
    };

    var target = try parseUrl(allocator, cli.url);
    defer target.deinit(allocator);

    var reg = try rove.Registry.init(allocator, .{
        .max_entities = 256,
        .deferred_queue_capacity = 64,
    });
    defer reg.deinit();

    var client = try Client.open(allocator, &reg, target);
    defer client.close();

    switch (cli.cmd) {
        .ping => try runPing(&client, token),
        .deploy => {
            if (cli.cmd_args.len != 2) {
                try printUsage();
                std.process.exit(2);
            }
            try runDeploy(allocator, &client, token, cli.cmd_args[0], cli.cmd_args[1]);
        },
    }
}
