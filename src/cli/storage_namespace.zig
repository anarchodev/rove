// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `rewind-ops storage-namespace` — read, adopt, or bump the object store's
//! generation marker.
//!
//! The grammar (key name, segment rules, what a generation means) lives in
//! rove-blob's `namespace.zig`, imported here rather than restated: two copies
//! of a wire constant is how a writer and a reader drift apart.
//!
//! This talks to S3 directly rather than through rove-blob, because the ops
//! CLI links no system libraries (no libcurl). It signs with the same
//! `sigv4.zig` the platform signs with and shells out to `curl`, the same
//! transport every other verb here uses.

const std = @import("std");
const c = @import("common.zig");
const ns = @import("blob-namespace");
const sigv4 = @import("sigv4");

const fatal = c.fatal;
const oom = c.oom;

pub const Mode = enum { show, adopt, bump, print_prefix };

const S3Env = struct {
    host: []const u8,
    bucket: []const u8,
    region: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    use_tls: bool,
    key_prefix_base: []const u8,
};

fn s3Env(env: *const c.Env) S3Env {
    var host = env.require("S3_ENDPOINT");
    // Operators paste the endpoint with a scheme (every S3 doc shows one);
    // strip it the same way `rove-blob`'s s3.init does so the two agree on
    // what gets signed.
    if (std.mem.startsWith(u8, host, "https://")) {
        host = host["https://".len..];
    } else if (std.mem.startsWith(u8, host, "http://")) {
        host = host["http://".len..];
    }
    if (host.len > 0 and host[host.len - 1] == '/') host = host[0 .. host.len - 1];

    const tls = if (env.get("S3_USE_TLS")) |v|
        !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"))
    else
        true;

    return .{
        .host = host,
        .bucket = env.require("S3_BUCKET"),
        .region = env.require("S3_REGION"),
        .access_key = env.require("AWS_ACCESS_KEY_ID"),
        .secret_key = env.require("AWS_SECRET_ACCESS_KEY"),
        .use_tls = tls,
        .key_prefix_base = env.get("S3_KEY_PREFIX_BASE") orelse "",
    };
}

/// One signed request against the marker object. `body` non-null ⇒ PUT.
fn markerRequest(a: std.mem.Allocator, s3: S3Env, method: []const u8, body: ?[]const u8) c.Resp {
    const key = std.fmt.allocPrint(a, "{s}{s}", .{ s3.key_prefix_base, ns.MARKER_KEY }) catch oom();
    const path = std.fmt.allocPrint(a, "/{s}/{s}", .{ s3.bucket, key }) catch oom();

    var stamp: [16]u8 = undefined;
    sigv4.formatAmzDate(&stamp, std.time.timestamp());

    var signed = sigv4.sign(a, .{
        .method = method,
        .path = path,
        .host = s3.host,
        .body = body orelse "",
        .access_key = s3.access_key,
        .secret_key = s3.secret_key,
        .region = s3.region,
        .timestamp = &stamp,
    }) catch |err| fatal("signing the marker request failed: {s}", .{@errorName(err)});
    defer signed.deinit(a);

    const headers = [_]c.Header{
        .{ .name = "Authorization", .value = signed.authorization },
        .{ .name = "x-amz-date", .value = signed.x_amz_date },
        .{ .name = "x-amz-content-sha256", .value = signed.x_amz_content_sha256 },
    };
    const url = std.fmt.allocPrint(a, "{s}://{s}{s}", .{
        if (s3.use_tls) "https" else "http",
        s3.host,
        path,
    }) catch oom();

    // Object storage is a public endpoint — no h2-prior-knowledge (that is for
    // the h2c private plane) and no ssh wrapper.
    const argv = c.curlArgv(a, method, url, &headers, false, body != null, 30);
    return c.run(a, argv, body);
}

/// Read the current marker. Returns null when there is none.
fn readMarker(a: std.mem.Allocator, s3: S3Env) ?[]const u8 {
    const resp = markerRequest(a, s3, "GET", null);
    if (resp.code == 404) return null;
    if (resp.code != 200) fatal("reading the namespace marker failed: HTTP {d}\n{s}", .{ resp.code, resp.body });
    const segment = std.mem.trim(u8, resp.body, " \t\r\n");
    ns.validate(segment) catch fatal(
        "the namespace marker holds '{s}', which is not a generation. Refusing to act on it.",
        .{segment},
    );
    return segment;
}

fn writeMarker(a: std.mem.Allocator, s3: S3Env, segment: []const u8) void {
    const resp = markerRequest(a, s3, "PUT", segment);
    if (resp.code != 200 and resp.code != 201 and resp.code != 204)
        fatal("writing the namespace marker failed: HTTP {d}\n{s}", .{ resp.code, resp.body });
}

fn describe(segment: []const u8) []const u8 {
    return if (segment.len == 0) "the original un-segmented layout" else "";
}

pub fn cmd(a: std.mem.Allocator, env: *const c.Env, mode: Mode) void {
    const s3 = s3Env(env);
    const current = readMarker(a, s3);

    switch (mode) {
        // Just the effective prefix, nothing else — deploy scripts assert on
        // this, and parsing prose is how a check quietly stops checking.
        .print_prefix => {
            const seg = current orelse {
                std.debug.print("{s}\n", .{ns.MISSING_MARKER_HINT});
                std.process.exit(1);
            };
            const prefix = ns.apply(a, s3.key_prefix_base, seg) catch oom();
            const out = std.fs.File.stdout();
            out.writeAll(prefix) catch {};
            out.writeAll("\n") catch {};
        },
        .show => {
            if (current) |seg| {
                std.debug.print("storage namespace: '{s}' {s}\n", .{ seg, describe(seg) });
                const prefix = ns.apply(a, s3.key_prefix_base, seg) catch oom();
                std.debug.print("  keys live under: {s}/{s}\n", .{ s3.bucket, prefix });
            } else {
                std.debug.print("storage namespace: NONE — no marker in {s}/{s}\n", .{
                    s3.bucket,
                    s3.key_prefix_base,
                });
                std.debug.print("{s}\n", .{ns.MISSING_MARKER_HINT});
                std.process.exit(1);
            }
        },
        .adopt => {
            // Adoption names what a store ALREADY holds, so it must not run
            // where a generation is recorded — that would silently re-point a
            // live cluster at a different key space and orphan its blobs.
            if (current) |seg| fatal(
                "this store is already namespaced ('{s}'). --adopt is for a store that predates namespacing.",
                .{seg},
            );
            writeMarker(a, s3, "");
            std.debug.print("adopted the existing layout ({s}/{s}) as generation 0.\n", .{
                s3.bucket,
                s3.key_prefix_base,
            });
        },
        .bump => {
            // A bump is only meaningful against a known generation: without a
            // marker we cannot tell generation 0 from a store that was never
            // namespaced, and picking wrong re-uses live keys.
            const seg = current orelse fatal(
                "no marker to bump. Run `rewind-ops storage-namespace --adopt` first (it records what this store already holds).",
                .{},
            );
            const next = ns.next(a, seg) catch |err| fatal("cannot advance '{s}': {s}", .{ seg, @errorName(err) });
            writeMarker(a, s3, next);
            const prefix = ns.apply(a, s3.key_prefix_base, next) catch oom();
            std.debug.print("storage namespace: '{s}' → '{s}'\n", .{ seg, next });
            std.debug.print("  new keys live under: {s}/{s}\n", .{ s3.bucket, prefix });
            std.debug.print("  the previous generation is untouched and still readable.\n", .{});
            std.debug.print("  every service must be (re)started to pick this up.\n", .{});
        },
    }
}
