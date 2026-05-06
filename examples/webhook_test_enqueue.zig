//! Test helper for the webhook-server smoke (Phase 5.5 d, step 3).
//!
//! Inserts a single webhook row directly into `{data_dir}/webhooks.db`,
//! bypassing raft. The webhook-server thread on the running loop46
//! process picks up the row on its next tick, POSTs to the URL, and
//! proposes envelope 5 → apply writes `_callback/{webhook_id}` into
//! the tenant's app.db.
//!
//! Usage:
//!   webhook-test-enqueue \
//!       --data-dir /tmp/rove-data \
//!       --tenant acme \
//!       --webhook-id <64-hex> \
//!       --url https://localhost:9999/echo \
//!       [--method POST] [--on-result foo/bar] [--max-attempts 3]
//!
//! The single-row insert path matches what the dispatcher cutover
//! (step 4) will produce per `webhook.send` call, minus the raft
//! propose. For step 3 it's enough to validate the delivery loop +
//! envelope 5/6 propose path.

const std = @import("std");
const webhook_server = @import("rove-webhook-server");

const Args = struct {
    data_dir: []const u8,
    tenant: []const u8,
    webhook_id: []const u8,
    url: []const u8,
    method: []const u8 = "POST",
    on_result: []const u8 = "",
    max_attempts: u8 = 3,
    body: []const u8 = "",
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const args = parseArgs(argv) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.debug.print(
            \\
            \\usage: webhook-test-enqueue \
            \\    --data-dir DIR \
            \\    --tenant ID \
            \\    --webhook-id 64-HEX \
            \\    --url URL \
            \\    [--method POST] \
            \\    [--on-result PATH] \
            \\    [--max-attempts 3] \
            \\    [--body STRING]
            \\
        , .{});
        std.process.exit(2);
    };

    if (args.webhook_id.len != webhook_server.WEBHOOK_ID_HEX_LEN) {
        std.debug.print(
            "error: --webhook-id must be {d} hex chars (got {d})\n",
            .{ webhook_server.WEBHOOK_ID_HEX_LEN, args.webhook_id.len },
        );
        std.process.exit(2);
    }

    const db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/webhooks.db",
        .{args.data_dir},
        0,
    );
    defer allocator.free(db_path);

    var store = try webhook_server.WebhookStore.open(allocator, db_path);
    defer store.close();

    var webhook_id_buf: [webhook_server.WEBHOOK_ID_HEX_LEN]u8 = undefined;
    @memcpy(&webhook_id_buf, args.webhook_id);

    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const row: webhook_server.WebhookRow = .{
        .webhook_id_hex = webhook_id_buf,
        .tenant_id = args.tenant,
        .url = args.url,
        .method = args.method,
        .headers_json = "{\"Content-Type\":\"application/json\"}",
        .body = args.body,
        .max_attempts = args.max_attempts,
        .timeout_ms = 5_000,
        .retry_on_json = "[408,429,500,502,503,504,\"network\"]",
        .context_json = "{\"smoke\":true}",
        .on_result_path = args.on_result,
        .enqueued_at_ns = now_ns,
    };

    var rows = [_]webhook_server.WebhookRow{row};
    try store.applyEnqueueBatch(&rows);

    std.debug.print(
        "enqueued webhook id={s} tenant={s} url={s}\n",
        .{ args.webhook_id, args.tenant, args.url },
    );
}

fn parseArgs(argv: []const [:0]u8) !Args {
    var data_dir: ?[]const u8 = null;
    var tenant: ?[]const u8 = null;
    var webhook_id: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var method: []const u8 = "POST";
    var on_result: []const u8 = "";
    var max_attempts: u8 = 3;
    var body: []const u8 = "";

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            data_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--tenant")) {
            i += 1;
            tenant = argv[i];
        } else if (std.mem.eql(u8, a, "--webhook-id")) {
            i += 1;
            webhook_id = argv[i];
        } else if (std.mem.eql(u8, a, "--url")) {
            i += 1;
            url = argv[i];
        } else if (std.mem.eql(u8, a, "--method")) {
            i += 1;
            method = argv[i];
        } else if (std.mem.eql(u8, a, "--on-result")) {
            i += 1;
            on_result = argv[i];
        } else if (std.mem.eql(u8, a, "--max-attempts")) {
            i += 1;
            max_attempts = try std.fmt.parseInt(u8, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--body")) {
            i += 1;
            body = argv[i];
        } else {
            return error.UnknownArg;
        }
    }
    return .{
        .data_dir = data_dir orelse return error.MissingDataDir,
        .tenant = tenant orelse return error.MissingTenant,
        .webhook_id = webhook_id orelse return error.MissingWebhookId,
        .url = url orelse return error.MissingUrl,
        .method = method,
        .on_result = on_result,
        .max_attempts = max_attempts,
        .body = body,
    };
}
