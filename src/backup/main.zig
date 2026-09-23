// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `rewind-backup` — take an off-provider backup of a cluster's tenant state,
//! and put it back (rove#341).
//!
//! Three raft nodes in one datacenter is replication, not backup: raft
//! protects against a node dying and faithfully replicates a bad apply, an
//! operator mistake, and a delete a customer regrets. So this writes tenant
//! state to a SEPARATE object store, under separate credentials
//! (`BACKUP_S3_*`), and can read it back into a cluster that shares nothing
//! with the one it came from.
//!
//! ## What it does NOT invent
//!
//! The bytes are the ones a tenant MOVE already ships — the worker's
//! `StreamDumper` over a held snapshot — and a restore is a POST to
//! `/_system/v2-snapshot-stream`, the endpoint a move's destination already
//! serves. So neither direction has a serialization or an apply path of its
//! own: both ride code that runs in production on every move and every raft
//! catch-up, rather than code exercised for the first time on the worst day
//! of the year.
//!
//! This tool holds the BACKUP credentials and the move secret; it never needs
//! the cluster root token. Splitting it from `rewind-ops` that way is
//! deliberate — the thing that can read every tenant's state out of the
//! cluster should not also be the thing that can deploy code into it.
//!
//! ## What a run contains
//!
//! ```
//! {prefix}{run_id}/manifest.json               what this run covers
//! {prefix}{run_id}/tenants/{id}.snap           the held-snapshot dump
//! {prefix}{run_id}/tenants/{id}.kr             the tenant's sealed keyring secret
//! {prefix}{run_id}/tenants/{id}.shard-{8 hex}  one sealed shard per shard
//! ```
//!
//! The keyring parts are what make a restored tenant able to READ what it
//! restored: every value it sealed under `shredKey` is ciphertext in the
//! dump, and the keys live outside raft. They move verbatim — nothing is
//! decrypted to make the copy — so the whole backup stays inert without the
//! cluster KEK, which lives in SOPS and never here. A restore lands the store
//! FIRST and the keyring second, because the store carries the `_keys/dead/`
//! tombstones that stop a restore from resurrecting a destroyed key.
//!
//! The manifest is written LAST: a run without one is an incomplete run, and
//! `verify` says so rather than reporting a partial set as restorable.
//!
//! ## What it does not yet cover (rove#341's remaining leaf)
//!
//! - **A schedule, a retention policy, and a scheduled restore test**, which
//!   is also where a stated RPO/RTO comes from (rove#966).

const std = @import("std");
const blob = @import("rove-blob");
const wire = @import("wire-headers");
const curl = blob.curl;

const USAGE =
    \\rewind-backup — off-provider backup + restore of tenant state (rove#341)
    \\
    \\  rewind-backup run --nodes <url,...> --tenants <id,...> --cp <url>
    \\                    [--run-id <id>] [--no-directory]
    \\      Back up each tenant from whichever node leads it, capture the CP
    \\      directory rows that say where each one lives and what identity its
    \\      data is keyed by, then write the run manifest. Prints the run id.
    \\      `--no-directory` omits the directory — say it out loud, because a
    \\      run without it restores tenants nobody can place.
    \\
    \\  rewind-backup mirror --run <id>
    \\      Copy the run's tenants' OBJECTS — bundles, static assets, exports,
    \\      deployment manifests — plus the shared log and body-pool families,
    \\      from the live store into the backup store. Copy-if-absent, so a
    \\      re-run resumes. Needs the live store's env (S3_*) as well as the
    \\      backup target's.
    \\
    \\  rewind-backup verify --run <id>
    \\      Re-read every object the manifest names and check it is a whole,
    \\      well-formed snapshot stream of the recorded size. An unverified
    \\      backup is a belief, not a control.
    \\
    \\  rewind-backup restore --run <id> --tenant <id> --nodes <url,...>
    \\      Stream a backed-up tenant into a cluster that has already attached
    \\      it (an empty group). Tries each node until one is the leader.
    \\
    \\  rewind-backup restore-directory --run <id> --cp <url>
    \\      Put the directory rows back into a REBUILT control plane — one
    \\      that places no tenants of its own. Do this BEFORE restoring
    \\      tenants: it is what says which cluster each belongs to and under
    \\      which incarnation to attach it.
    \\
    \\  rewind-backup show --run <id>
    \\      Print the run manifest — per tenant, the object, its size and
    \\      hash, and the INCARNATION a restore must attach under.
    \\
    \\  rewind-backup tenants --cp <url>
    \\      Every tenant the directory places, comma-separated — what a
    \\      scheduled run feeds back into `--tenants`, so a tenant
    \\      provisioned today is in tonight's backup with nobody remembering.
    \\
    \\  rewind-backup prune [--keep-daily N] [--keep-weekly M] --yes
    \\      Enforce the retention window: the N most recent runs, then one
    \\      per day for M more. Prints what it would remove without --yes.
    \\
    \\  rewind-backup list
    \\      Runs present in the backup store, newest first.
    \\
    \\Env: BACKUP_S3_ENDPOINT / _REGION / _BUCKET / _KEY_PREFIX_BASE /
    \\     _USE_TLS, BACKUP_AWS_ACCESS_KEY_ID, BACKUP_AWS_SECRET_ACCESS_KEY,
    \\     REWIND_MOVE_SECRET (to reach the worker doors).
    \\
;

/// The snapshot-stream framing, so `verify` can tell a whole dump from a
/// truncated upload without standing up a store to load it into. Mirrors
/// `raft-kv`'s `snapshot_stream` header — checked, not re-implemented: this
/// reads the first bytes, it never writes them.
const STREAM_MAGIC: u32 = 0x3253474D;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("rewind-backup: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// A run's object names. One place, because `run` writes them and `verify` /
/// `restore` read them, and a second spelling would only be discovered by a
/// restore that found nothing.
///
/// The PREFIX is what the door is given; the worker names the parts under it
/// (`.snap`, `.kr`, `.shard-{8 hex}`), because only the worker can see which
/// parts a tenant has.
fn tenantPrefix(a: std.mem.Allocator, run_id: []const u8, tenant: []const u8) []u8 {
    return std.fmt.allocPrint(a, "{s}/tenants/{s}", .{ run_id, tenant }) catch @panic("OOM");
}

/// The object a named keyring part lands in. `secret` → `{prefix}.kr`;
/// `shard-000000ab` → `{prefix}.shard-000000ab`.
fn partKey(a: std.mem.Allocator, prefix: []const u8, part: []const u8) []u8 {
    if (std.mem.eql(u8, part, "secret"))
        return std.fmt.allocPrint(a, "{s}.kr", .{prefix}) catch @panic("OOM");
    return std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, part }) catch @panic("OOM");
}

fn manifestKey(a: std.mem.Allocator, run_id: []const u8) []u8 {
    return std.fmt.allocPrint(a, "{s}/manifest.json", .{run_id}) catch @panic("OOM");
}

/// The CP directory rows for a run: where each tenant lives, its plan, and
/// the incarnation its own data is keyed by. One object, because it is one
/// consistent read of one raft group.
fn directoryKey(a: std.mem.Allocator, run_id: []const u8) []u8 {
    return std.fmt.allocPrint(a, "{s}/directory.json", .{run_id}) catch @panic("OOM");
}

/// `YYYYMMDDTHHMMSSZ` — sorts lexically, which is what makes `list` and a
/// retention sweep simple later.
fn defaultRunId(a: std.mem.Allocator) []u8 {
    const now: u64 = @intCast(std.time.timestamp());
    const es = std.time.epoch.EpochSeconds{ .secs = now };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch @panic("OOM");
}

const Args = struct {
    cmd: []const u8 = "",
    nodes: []const []const u8 = &.{},
    tenants: []const []const u8 = &.{},
    run_id: ?[]const u8 = null,
    tenant: ?[]const u8 = null,
    cp: ?[]const u8 = null,
    no_directory: bool = false,
    keep_daily: u32 = 14,
    keep_weekly: u32 = 8,
    yes: bool = false,
};

fn splitList(a: std.mem.Allocator, csv: []const u8) []const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, csv, ", ");
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t/");
        if (trimmed.len == 0) continue;
        out.append(a, a.dupe(u8, trimmed) catch @panic("OOM")) catch @panic("OOM");
    }
    return out.toOwnedSlice(a) catch @panic("OOM");
}

fn parseArgs(a: std.mem.Allocator, argv: []const []const u8) Args {
    var args: Args = .{};
    if (argv.len < 2) {
        std.debug.print("{s}", .{USAGE});
        std.process.exit(2);
    }
    args.cmd = argv[1];
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const next = if (i + 1 < argv.len) argv[i + 1] else null;
        if (std.mem.eql(u8, arg, "--nodes")) {
            args.nodes = splitList(a, next orelse fatal("--nodes needs a value", .{}));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--tenants")) {
            args.tenants = splitList(a, next orelse fatal("--tenants needs a value", .{}));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--run") or std.mem.eql(u8, arg, "--run-id")) {
            args.run_id = next orelse fatal("{s} needs a value", .{arg});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--tenant")) {
            args.tenant = next orelse fatal("--tenant needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--cp")) {
            args.cp = next orelse fatal("--cp needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--no-directory")) {
            args.no_directory = true;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            args.yes = true;
        } else if (std.mem.eql(u8, arg, "--keep-daily")) {
            args.keep_daily = std.fmt.parseInt(u32, next orelse fatal("--keep-daily needs a value", .{}), 10) catch
                fatal("--keep-daily must be a number", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--keep-weekly")) {
            args.keep_weekly = std.fmt.parseInt(u32, next orelse fatal("--keep-weekly needs a value", .{}), 10) catch
                fatal("--keep-weekly must be a number", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{USAGE});
            std.process.exit(0);
        } else {
            fatal("unknown argument '{s}'", .{arg});
        }
    }
    return args;
}

/// Open the backup target. Missing config is fatal HERE rather than at the
/// first upload: a backup run that discovers halfway through that it has
/// nowhere to write has already told the operator it was running.
fn openBackupStore(a: std.mem.Allocator) struct { owned: blob.env.BlobBackendOwned, store: blob.S3BlobStore } {
    const owned = blob.env.loadFromEnvPrefixed(a, blob.env.BACKUP_ENV_PREFIX) catch |err| {
        const name = blob.env.errorEnvName(err) orelse "BACKUP_S3_*";
        fatal("backup target not configured: set {s}{s}", .{ blob.env.BACKUP_ENV_PREFIX, name });
    };
    const store = blob.S3BlobStore.init(a, .{
        .endpoint = owned.cfg.endpoint,
        .region = owned.cfg.region,
        .bucket = owned.cfg.bucket,
        .key_prefix = owned.cfg.key_prefix_base,
        .access_key = owned.cfg.access_key,
        .secret_key = owned.cfg.secret_key,
        .use_tls = owned.cfg.use_tls,
    }) catch |e| fatal("backup target unusable: {s}", .{@errorName(e)});
    return .{ .owned = owned, .store = store };
}

fn moveSecret(a: std.mem.Allocator) []u8 {
    return (blob.env.envOpt(a, "REWIND_MOVE_SECRET") catch null) orelse
        fatal("REWIND_MOVE_SECRET is unset — the worker doors are gated on it", .{});
}

// ── run ───────────────────────────────────────────────────────────────

const ObjectFacts = struct { bytes: u64, sha_hex: []u8 };

/// Read an object back and describe what is actually there. A manifest that
/// recorded what we *sent* would certify an upload that silently truncated.
fn describeObject(a: std.mem.Allocator, store: *blob.S3BlobStore, key: []const u8) !ObjectFacts {
    const got = try store.blobStore().get(key, a);
    defer a.free(got);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(got, &digest, .{});
    return .{
        .bytes = got.len,
        .sha_hex = std.fmt.allocPrint(a, "{x}", .{&digest}) catch @panic("OOM"),
    };
}

/// Ask each node in turn to back `tenant` up to `key`. A node that does not
/// lead the tenant answers 421, which is a redirect, not a failure — the
/// leader is the only node whose snapshot has a knowable recency.
fn backupOne(
    a: std.mem.Allocator,
    nodes: []const []const u8,
    secret: []const u8,
    tenant: []const u8,
    key: []const u8,
) ![]u8 {
    var last_status: u16 = 0;
    var last_body: []const u8 = "";
    for (nodes) |base| {
        const url = try std.fmt.allocPrint(a, "{s}/_system/v2-backup", .{base});
        defer a.free(url);
        var resp = curl.cpRequest(a, .POST, url, "", .{
            .headers = &.{
                .{ .name = wire.MOVE_SECRET, .value = secret },
                .{ .name = wire.TENANT, .value = tenant },
                .{ .name = wire.BACKUP_KEY, .value = key },
            },
            // A backup streams a whole tenant store to an object store; the
            // worker bounds it with REWIND_SNAPSHOT_XFER_MAX_MS (10 min by
            // default) and this must outlast that, or a run reports failures
            // for uploads that went on to succeed.
            .timeout_ms = 20 * 60 * 1000,
        }) catch |e| {
            std.debug.print("  {s}: {s} — trying the next node\n", .{ base, @errorName(e) });
            continue;
        };
        defer resp.deinit(a);
        last_status = resp.status;
        last_body = resp.body orelse "";
        // The door answers with the tenant's STORAGE IDENTITY, which the
        // manifest has to carry: a restore must re-attach the tenant under
        // the same incarnation, or the dump loads into a store nothing reads.
        if (resp.status == 200) return a.dupe(u8, resp.body orelse "{}");
        if (resp.status == 421) continue; // not the leader — ask the next node
        return error.BackupRefused;
    }
    if (last_status == 0) return error.NoNodeReachable;
    std.debug.print("  last status {d}: {s}\n", .{ last_status, std.mem.trim(u8, last_body, "\n") });
    return error.NoLeaderForTenant;
}

fn cmdRun(a: std.mem.Allocator, args: Args) !u8 {
    if (args.nodes.len == 0) fatal("run needs --nodes", .{});
    if (args.tenants.len == 0) fatal("run needs --tenants", .{});
    var target = openBackupStore(a);
    defer target.store.deinit();
    const secret = moveSecret(a);
    const run_id = args.run_id orelse defaultRunId(a);

    std.debug.print("run {s}: {d} tenant(s)\n", .{ run_id, args.tenants.len });

    // The directory FIRST. It is the smallest object in the run and the one
    // that makes the rest meaningful: without it a restored tenant has no
    // placement, no plan, and no incarnation to attach under. Captured before
    // the dumps so a run that cannot reach the CP fails before spending
    // twenty minutes streaming stores.
    var directory_bytes: u64 = 0;
    var directory_sha: ?[]u8 = null;
    defer if (directory_sha) |d| a.free(d);
    if (args.cp) |cp| {
        const rows = fetchDirectory(a, cp, secret) catch |e|
            fatal("directory dump from {s} failed: {s}", .{ cp, @errorName(e) });
        defer a.free(rows);
        const dkey = directoryKey(a, run_id);
        defer a.free(dkey);
        target.store.blobStore().put(dkey, rows) catch |e|
            fatal("directory dump write failed: {s}", .{@errorName(e)});
        const facts = describeObject(a, &target.store, dkey) catch |e|
            fatal("directory dump stored but unreadable: {s}", .{@errorName(e)});
        directory_bytes = facts.bytes;
        directory_sha = facts.sha_hex;
        std.debug.print("  ok directory: {d} bytes\n", .{facts.bytes});
    } else if (!args.no_directory) {
        fatal(
            "run needs --cp (the control plane to capture the directory from), " ++
                "or an explicit --no-directory. A run without it restores tenants nobody can place.",
            .{},
        );
    } else {
        std.debug.print("  NO DIRECTORY — this run restores tenant data only\n", .{});
    }

    var manifest: std.ArrayListUnmanaged(u8) = .empty;
    defer manifest.deinit(a);
    const w = manifest.writer(a);
    try w.print("{{\"run_id\":\"{s}\",\"tenants\":[", .{run_id});

    var failures: usize = 0;
    for (args.tenants, 0..) |tenant, i| {
        const prefix = tenantPrefix(a, run_id, tenant);
        defer a.free(prefix);
        const identity = backupOne(a, args.nodes, secret, tenant, prefix) catch |e| {
            std.debug.print("  FAILED {s}: {s}\n", .{ tenant, @errorName(e) });
            failures += 1;
            continue;
        };
        defer a.free(identity);
        const parsed_id = std.json.parseFromSlice(std.json.Value, a, identity, .{}) catch |e| {
            std.debug.print("  FAILED {s}: the node did not report a storage identity: {s}\n", .{ tenant, @errorName(e) });
            failures += 1;
            continue;
        };
        defer parsed_id.deinit();
        const store_id: []const u8 = if (parsed_id.value.object.get("store_id")) |v| v.string else "0";
        const incarnation: []const u8 = if (parsed_id.value.object.get("incarnation")) |v| v.string else "";
        if (incarnation.len == 0) {
            std.debug.print("  FAILED {s}: no incarnation reported — a dump nobody can re-attach\n", .{tenant});
            failures += 1;
            continue;
        }
        // Sizes and hashes come from the STORE, not from what we asked for:
        // the only honest record of an upload is the object that is now
        // there. Same for the keyring parts, which is also how `verify`
        // later notices one that never landed.
        const snap_key = std.fmt.allocPrint(a, "{s}.snap", .{prefix}) catch @panic("OOM");
        defer a.free(snap_key);
        const dump = describeObject(a, &target.store, snap_key) catch |e| {
            std.debug.print("  FAILED {s}: stored but unreadable: {s}\n", .{ tenant, @errorName(e) });
            failures += 1;
            continue;
        };
        defer a.free(dump.sha_hex);

        // The keyring parts the node says it wrote. A tenant that has never
        // sealed anything reports none, and that empty list is the record of
        // what was there — not a gap to paper over at restore time.
        var parts_json: std.ArrayListUnmanaged(u8) = .empty;
        defer parts_json.deinit(a);
        var parts_failed = false;
        if (parsed_id.value.object.get("keyring_parts")) |kp| {
            for (kp.array.items, 0..) |entry, pi| {
                const part = entry.string;
                const pkey = partKey(a, prefix, part);
                defer a.free(pkey);
                const obj = describeObject(a, &target.store, pkey) catch |e| {
                    std.debug.print("  FAILED {s}: keyring part {s} unreadable: {s}\n", .{ tenant, part, @errorName(e) });
                    parts_failed = true;
                    break;
                };
                defer a.free(obj.sha_hex);
                if (pi > 0) parts_json.appendSlice(a, ",") catch @panic("OOM");
                parts_json.writer(a).print(
                    "{{\"part\":\"{s}\",\"bytes\":{d},\"sha256\":\"{s}\"}}",
                    .{ part, obj.bytes, obj.sha_hex },
                ) catch @panic("OOM");
            }
        }
        if (parts_failed) {
            failures += 1;
            continue;
        }

        if (i > 0) try w.writeAll(",");
        // The object prefixes come straight from the node, verbatim: the
        // prefix depends on the storage incarnation, and deriving it a second
        // time here is how a writer and a reader end up at different depths.
        var obj_prefixes: std.ArrayListUnmanaged(u8) = .empty;
        defer obj_prefixes.deinit(a);
        if (parsed_id.value.object.get("object_prefixes")) |ops| {
            for (ops.array.items, 0..) |op, oi| {
                if (oi > 0) obj_prefixes.appendSlice(a, ",") catch @panic("OOM");
                obj_prefixes.writer(a).print("\"{s}\"", .{op.string}) catch @panic("OOM");
            }
        }
        var shared_json: std.ArrayListUnmanaged(u8) = .empty;
        defer shared_json.deinit(a);
        if (parsed_id.value.object.get("shared_prefixes")) |sps| {
            for (sps.array.items, 0..) |sp, si| {
                if (si > 0) shared_json.appendSlice(a, ",") catch @panic("OOM");
                shared_json.writer(a).print("\"{s}\"", .{sp.string}) catch @panic("OOM");
            }
        }
        try w.print(
            "{{\"tenant\":\"{s}\",\"prefix\":\"{s}\",\"bytes\":{d},\"sha256\":\"{s}\"," ++
                "\"store_id\":\"{s}\",\"incarnation\":\"{s}\",\"keyring_parts\":[{s}]," ++
                "\"object_prefixes\":[{s}],\"shared_prefixes\":[{s}]}}",
            .{ tenant, prefix, dump.bytes, dump.sha_hex, store_id, incarnation, parts_json.items, obj_prefixes.items, shared_json.items },
        );
        std.debug.print("  ok {s}: {d} bytes, {d} keyring part(s) (incarnation {s})\n", .{
            tenant,
            dump.bytes,
            if (parsed_id.value.object.get("keyring_parts")) |kp| kp.array.items.len else 0,
            incarnation,
        });
    }
    try w.writeAll("],");
    if (directory_sha) |sha| {
        try w.print("\"directory\":{{\"key\":\"{s}/directory.json\",\"bytes\":{d},\"sha256\":\"{s}\"}},", .{
            run_id, directory_bytes, sha,
        });
    } else {
        // Recorded as absent rather than omitted: `verify` says so out loud,
        // and a reader of the manifest should never have to infer coverage
        // from a missing key.
        try w.writeAll("\"directory\":null,");
    }
    try w.print("\"failures\":{d}}}", .{failures});

    if (failures > 0) {
        // No manifest on a partial run. A manifest is the claim that this set
        // is restorable; writing one for a run that lost a tenant would make
        // the next `verify` pass on a backup that is missing data.
        std.debug.print("run {s}: {d} tenant(s) FAILED — no manifest written\n", .{ run_id, failures });
        return 1;
    }
    const mkey = manifestKey(a, run_id);
    defer a.free(mkey);
    target.store.blobStore().put(mkey, manifest.items) catch |e|
        fatal("manifest write failed: {s}", .{@errorName(e)});
    std.debug.print("run {s}: complete\n{s}\n", .{ run_id, run_id });
    return 0;
}

// ── verify ────────────────────────────────────────────────────────────

fn cmdVerify(a: std.mem.Allocator, args: Args) !u8 {
    const run_id = args.run_id orelse fatal("verify needs --run", .{});
    var target = openBackupStore(a);
    defer target.store.deinit();

    const mkey = manifestKey(a, run_id);
    defer a.free(mkey);
    const manifest = target.store.blobStore().get(mkey, a) catch |e|
        fatal("run {s} has no manifest ({s}) — an incomplete run is not a backup", .{ run_id, @errorName(e) });
    defer a.free(manifest);

    const parsed = std.json.parseFromSlice(std.json.Value, a, manifest, .{}) catch |e|
        fatal("run {s}: manifest is not JSON: {s}", .{ run_id, @errorName(e) });
    defer parsed.deinit();
    const tenants = parsed.value.object.get("tenants") orelse
        fatal("run {s}: manifest has no tenants", .{run_id});

    var bad: usize = 0;

    // The directory first, because a run that lost it restores tenant data
    // nobody can place — a fact worth reading before a list of green tenants.
    if (parsed.value.object.get("directory")) |d| {
        if (d == .null) {
            std.debug.print("  NOTE {s}: no directory in this run (--no-directory) — tenant data only\n", .{run_id});
        } else {
            const dkey = d.object.get("key").?.string;
            const want_b: u64 = @intCast(d.object.get("bytes").?.integer);
            const want_s = d.object.get("sha256").?.string;
            if (describeObject(a, &target.store, dkey)) |obj| {
                defer a.free(obj.sha_hex);
                if (obj.bytes != want_b or !std.mem.eql(u8, obj.sha_hex, want_s)) {
                    std.debug.print("  FAIL directory: {d}b/{s} vs manifest {d}b/{s}\n", .{
                        obj.bytes, obj.sha_hex, want_b, want_s,
                    });
                    bad += 1;
                } else {
                    std.debug.print("  ok directory: {d} bytes\n", .{obj.bytes});
                }
            } else |e| {
                std.debug.print("  FAIL directory: unreadable: {s}\n", .{@errorName(e)});
                bad += 1;
            }
        }
    }

    // The mirror record, if this run has one. Absent is not a failure — the
    // objects are a separate pass — but `verify` says which it is, because
    // "the backup is complete" means different things with and without it.
    const rkey = std.fmt.allocPrint(a, "{s}/mirror.json", .{run_id}) catch @panic("OOM");
    defer a.free(rkey);
    if (target.store.blobStore().get(rkey, a)) |rec| {
        defer a.free(rec);
        std.debug.print("  ok objects mirrored: {s}\n", .{std.mem.trim(u8, rec, "\n")});
    } else |_| {
        std.debug.print("  NOTE no object mirror in this run — KV, keyring and directory only\n", .{});
    }

    for (tenants.array.items) |entry| {
        const tenant = entry.object.get("tenant").?.string;
        const prefix = entry.object.get("prefix").?.string;
        const key = std.fmt.allocPrint(a, "{s}.snap", .{prefix}) catch @panic("OOM");
        defer a.free(key);
        const want_bytes: u64 = @intCast(entry.object.get("bytes").?.integer);
        const want_sha = entry.object.get("sha256").?.string;

        const got = target.store.blobStore().get(key, a) catch |e| {
            std.debug.print("  FAIL {s}: unreadable: {s}\n", .{ tenant, @errorName(e) });
            bad += 1;
            continue;
        };
        defer a.free(got);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(got, &digest, .{});
        const sha_hex = std.fmt.allocPrint(a, "{x}", .{&digest}) catch @panic("OOM");
        defer a.free(sha_hex);

        if (got.len != want_bytes) {
            std.debug.print("  FAIL {s}: {d} bytes, manifest says {d}\n", .{ tenant, got.len, want_bytes });
            bad += 1;
        } else if (!std.mem.eql(u8, sha_hex, want_sha)) {
            std.debug.print("  FAIL {s}: sha256 {s}, manifest says {s}\n", .{ tenant, sha_hex, want_sha });
            bad += 1;
        } else if (got.len < 5 or std.mem.readInt(u32, got[0..4], .little) != STREAM_MAGIC) {
            // Size and hash agree with what we uploaded; this asks the other
            // question — whether what we uploaded is a snapshot stream at all.
            std.debug.print("  FAIL {s}: not a snapshot stream (bad magic)\n", .{tenant});
            bad += 1;
        } else {
            std.debug.print("  ok {s}: {d} bytes\n", .{ tenant, got.len });
        }

        // The keyring is the half that decides whether a restored tenant can
        // READ what it restored. An unverified part is the failure that only
        // shows up as "every sealed value is gone", long after the restore
        // reported success.
        const parts = entry.object.get("keyring_parts") orelse continue;
        for (parts.array.items) |pe| {
            const part = pe.object.get("part").?.string;
            const p_bytes: u64 = @intCast(pe.object.get("bytes").?.integer);
            const p_sha = pe.object.get("sha256").?.string;
            const pkey = partKey(a, prefix, part);
            defer a.free(pkey);
            const obj = describeObject(a, &target.store, pkey) catch |e| {
                std.debug.print("  FAIL {s} keyring {s}: unreadable: {s}\n", .{ tenant, part, @errorName(e) });
                bad += 1;
                continue;
            };
            defer a.free(obj.sha_hex);
            if (obj.bytes != p_bytes or !std.mem.eql(u8, obj.sha_hex, p_sha)) {
                std.debug.print("  FAIL {s} keyring {s}: {d}b/{s} vs manifest {d}b/{s}\n", .{
                    tenant, part, obj.bytes, obj.sha_hex, p_bytes, p_sha,
                });
                bad += 1;
            } else {
                std.debug.print("  ok {s} keyring {s}: {d} bytes\n", .{ tenant, part, obj.bytes });
            }
        }
    }
    if (bad > 0) {
        std.debug.print("run {s}: {d} object(s) FAILED verification\n", .{ run_id, bad });
        return 1;
    }
    std.debug.print("run {s}: verified\n", .{run_id});
    return 0;
}

/// Ask the CP for its backed-up directory rows.
fn fetchDirectory(a: std.mem.Allocator, cp: []const u8, secret: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(a, "{s}/_control/directory-dump", .{cp});
    defer a.free(url);
    var resp = try curl.cpRequest(a, .POST, url, "", .{
        .headers = &.{.{ .name = wire.MOVE_SECRET, .value = secret }},
    });
    defer resp.deinit(a);
    if (resp.status != 200) {
        std.debug.print("  directory dump → {d}\n", .{resp.status});
        return error.DirectoryDumpRefused;
    }
    return a.dupe(u8, resp.body orelse "");
}

// ── tenants ───────────────────────────────────────────────────────────

/// Every tenant the directory PLACES, comma-separated, for a scheduled run to
/// feed straight back into `run --tenants`.
///
/// Asked of the control plane rather than kept in a list somewhere: a tenant
/// provisioned today is in tonight's backup without anyone remembering to add
/// it. A hand-maintained list is a list that silently stops covering the
/// newest customers, which is the set most likely to notice.
fn cmdTenants(a: std.mem.Allocator, args: Args) !u8 {
    const cp = args.cp orelse fatal("tenants needs --cp", .{});
    const secret = moveSecret(a);
    const rows = fetchDirectory(a, cp, secret) catch |e|
        fatal("directory dump from {s} failed: {s}", .{ cp, @errorName(e) });
    defer a.free(rows);

    const parsed = std.json.parseFromSlice(std.json.Value, a, rows, .{}) catch |e|
        fatal("the CP's directory dump is not JSON: {s}", .{@errorName(e)});
    defer parsed.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    var n: usize = 0;
    for ((parsed.value.object.get("rows") orelse fatal("no rows", .{})).array.items) |row| {
        const k = row.object.get("k").?.string;
        const PLACEMENT = "placement/";
        if (!std.mem.startsWith(u8, k, PLACEMENT)) continue;
        if (n > 0) out.appendSlice(a, ",") catch @panic("OOM");
        out.appendSlice(a, k[PLACEMENT.len..]) catch @panic("OOM");
        n += 1;
    }
    var w = std.fs.File.stdout().writer(&.{});
    w.interface.writeAll(out.items) catch {};
    w.interface.writeAll("\n") catch {};
    return 0;
}

// ── prune ─────────────────────────────────────────────────────────────

/// A run id is `YYYYMMDDTHHMMSSZ`, so its day is the first eight characters
/// and ids sort lexically. Retention is therefore an ordering problem rather
/// than a date-parsing one — which is why the ids look like that.
fn dayOf(run_id: []const u8) ?[]const u8 {
    if (run_id.len < 8) return null;
    for (run_id[0..8]) |c| if (c < '0' or c > '9') return null;
    return run_id[0..8];
}

fn cmdPrune(a: std.mem.Allocator, args: Args) !u8 {
    var target = openBackupStore(a);
    defer target.store.deinit();

    const runs = try listRuns(a, &target.store, target.owned.cfg.key_prefix_base);
    defer {
        for (runs) |r| a.free(r);
        a.free(runs);
    }
    if (runs.len == 0) {
        std.debug.print("no complete runs to prune\n", .{});
        return 0;
    }

    // Newest first. Keep the N most recent runs outright, then one run per
    // ISO week going back M weeks; everything else goes.
    var keep: std.StringHashMapUnmanaged(void) = .empty;
    defer keep.deinit(a);
    var i: usize = runs.len;
    var daily_kept: u32 = 0;
    var weekly_days: std.StringHashMapUnmanaged(void) = .empty;
    defer weekly_days.deinit(a);

    while (i > 0) {
        i -= 1;
        const run = runs[i];
        if (daily_kept < args.keep_daily) {
            keep.put(a, run, {}) catch @panic("OOM");
            daily_kept += 1;
            continue;
        }
        // One per distinct day beyond the daily window, capped at keep_weekly.
        const day = dayOf(run) orelse {
            // An id this tool did not mint — keep it. Deleting something we
            // cannot date is the one irreversible way to be wrong here.
            keep.put(a, run, {}) catch @panic("OOM");
            continue;
        };
        if (weekly_days.count() < args.keep_weekly and !weekly_days.contains(day)) {
            weekly_days.put(a, day, {}) catch @panic("OOM");
            keep.put(a, run, {}) catch @panic("OOM");
        }
    }

    var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
    defer doomed.deinit(a);
    for (runs) |r| if (!keep.contains(r)) doomed.append(a, r) catch @panic("OOM");

    std.debug.print("{d} run(s): keeping {d}, removing {d}\n", .{ runs.len, keep.count(), doomed.items.len });
    for (doomed.items) |r| std.debug.print("  - {s}\n", .{r});

    if (doomed.items.len == 0) return 0;
    if (!args.yes) {
        std.debug.print("re-run with --yes to delete. A backup removed is not recoverable,\n" ++
            "and the window it leaves is also how long an erasure stays only mostly true.\n", .{});
        return 2;
    }

    // Floor: never leave the store with nothing. A misconfigured retention
    // (`--keep-daily 0`) should read as a configuration error, not as a
    // successful deletion of every backup we have.
    if (keep.count() == 0) {
        std.debug.print("REFUSED: that retention would delete every run. Check --keep-daily/--keep-weekly.\n", .{});
        return 1;
    }

    var removed: usize = 0;
    for (doomed.items) |run| {
        const n = target.store.deletePrefix(run) catch |e| {
            std.debug.print("  FAILED {s}: {s}\n", .{ run, @errorName(e) });
            return 1;
        };
        std.debug.print("  removed {s} ({d} object(s))\n", .{ run, n });
        removed += 1;
    }
    std.debug.print("pruned {d} run(s)\n", .{removed});
    return 0;
}

/// Complete runs in the backup store, oldest first. A run is complete iff it
/// has a manifest — the same rule `verify` applies, so a prune can never
/// mistake an interrupted run for a keepable one or vice versa.
///
/// `key_prefix` is the store's own prefix, and stripping it is not cosmetic:
/// `listPrefix` returns FULLY-QUALIFIED keys (its sibling `deleteObjects`
/// says so), while every other verb here takes a bare run id and lets the
/// store prepend. Without the strip, a run id read from a listing is one
/// depth deeper than a run id typed by an operator — so `prune` could not
/// date it, kept everything, and would have deleted nothing under a
/// double-prefixed key while reporting success.
fn listRuns(a: std.mem.Allocator, store: *blob.S3BlobStore, key_prefix: []const u8) ![][]const u8 {
    var token: ?[]u8 = null;
    defer if (token) |t| a.free(t);
    var runs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (runs.items) |r| a.free(r);
        runs.deinit(a);
    }
    while (true) {
        var page = try store.listPrefix(a, "", token);
        defer page.deinit(a);
        for (page.keys) |k| {
            if (!std.mem.endsWith(u8, k, "/manifest.json")) continue;
            const qualified = k[0 .. k.len - "/manifest.json".len];
            const run = if (std.mem.startsWith(u8, qualified, key_prefix))
                qualified[key_prefix.len..]
            else
                qualified;
            runs.append(a, a.dupe(u8, run) catch @panic("OOM")) catch @panic("OOM");
        }
        const next = page.next_token orelse break;
        if (token) |t| a.free(t);
        token = a.dupe(u8, next) catch @panic("OOM");
    }
    std.mem.sort([]const u8, runs.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return runs.toOwnedSlice(a);
}

// ── mirror ────────────────────────────────────────────────────────────

/// Open the LIVE object store — the one the cluster writes to — at the
/// storage generation it is actually using. The generation is resolved from
/// the store's own marker rather than assumed: a cluster that was wiped and
/// bumped writes under a different prefix, and mirroring the prefix an
/// operator remembers would copy a previous lifetime's objects while missing
/// every current one.
fn openLiveStore(a: std.mem.Allocator) struct { owned: blob.env.BlobBackendOwned, store: blob.S3BlobStore } {
    var owned = blob.env.loadFromEnv(a) catch |err| {
        const name = blob.env.errorEnvName(err) orelse "S3_*";
        fatal("the live object store is not configured: set {s}", .{name});
    };
    const segment = blob.namespace_store.resolve(a, owned.cfg) catch |e|
        fatal("cannot read the live store's storage-namespace marker: {s}", .{@errorName(e)});
    defer a.free(segment);
    _ = owned.applyNamespace(a, segment) catch |e| fatal("namespace: {s}", .{@errorName(e)});

    const store = blob.S3BlobStore.init(a, .{
        .endpoint = owned.cfg.endpoint,
        .region = owned.cfg.region,
        .bucket = owned.cfg.bucket,
        .key_prefix = "", // keys from the manifest are already fully qualified
        .access_key = owned.cfg.access_key,
        .secret_key = owned.cfg.secret_key,
        .use_tls = owned.cfg.use_tls,
    }) catch |e| fatal("the live object store is unusable: {s}", .{@errorName(e)});
    return .{ .owned = owned, .store = store };
}

const MirrorStats = struct { copied: u64 = 0, skipped: u64 = 0, bytes: u64 = 0 };

/// Copy every object under `prefix` from the live store into the backup
/// store, skipping what is already there.
///
/// Copy-if-absent is exactly right for this store and not a shortcut: every
/// family here is immutable once written — content-addressed blobs by
/// construction, and the id-keyed families (deployments, log batches, pooled
/// bodies) because their ids are never reused within a storage generation. So
/// a key that exists in the backup already holds the same bytes, and a
/// re-run is a resume rather than a re-copy.
fn mirrorPrefix(
    a: std.mem.Allocator,
    live: *blob.S3BlobStore,
    backup: *blob.S3BlobStore,
    prefix: []const u8,
    stats: *MirrorStats,
) !void {
    var token: ?[]u8 = null;
    defer if (token) |t| a.free(t);
    while (true) {
        var page = try live.listPrefix(a, prefix, token);
        defer page.deinit(a);
        for (page.keys) |key| {
            if (backup.blobStore().exists(key) catch false) {
                stats.skipped += 1;
                continue;
            }
            const bytes = live.blobStore().get(key, a) catch |e| {
                std.debug.print("  FAILED {s}: unreadable in the live store: {s}\n", .{ key, @errorName(e) });
                return error.MirrorIncomplete;
            };
            defer a.free(bytes);
            backup.blobStore().put(key, bytes) catch |e| {
                std.debug.print("  FAILED {s}: {s}\n", .{ key, @errorName(e) });
                return error.MirrorIncomplete;
            };
            stats.copied += 1;
            stats.bytes += bytes.len;
        }
        const next = page.next_token orelse break;
        if (token) |t| a.free(t);
        token = a.dupe(u8, next) catch @panic("OOM");
    }
}

fn cmdMirror(a: std.mem.Allocator, args: Args) !u8 {
    const run_id = args.run_id orelse fatal("mirror needs --run", .{});
    var target = openBackupStore(a);
    defer target.store.deinit();
    var live = openLiveStore(a);
    defer live.store.deinit();
    defer live.owned.deinit(a);

    const mkey = manifestKey(a, run_id);
    defer a.free(mkey);
    const manifest = target.store.blobStore().get(mkey, a) catch |e|
        fatal("run {s} has no manifest: {s}", .{ run_id, @errorName(e) });
    defer a.free(manifest);
    const parsed = std.json.parseFromSlice(std.json.Value, a, manifest, .{}) catch |e|
        fatal("run {s}: manifest is not JSON: {s}", .{ run_id, @errorName(e) });
    defer parsed.deinit();

    var stats: MirrorStats = .{};
    var covered: std.ArrayListUnmanaged(u8) = .empty;
    defer covered.deinit(a);
    var first = true;

    for ((parsed.value.object.get("tenants") orelse fatal("no tenants", .{})).array.items) |entry| {
        const tenant = entry.object.get("tenant").?.string;
        const prefixes = entry.object.get("object_prefixes") orelse continue;
        for (prefixes.array.items) |p| {
            const prefix = p.string;
            mirrorPrefix(a, &live.store, &target.store, prefix, &stats) catch {
                std.debug.print("mirror {s}: INCOMPLETE at {s}\n", .{ run_id, prefix });
                return 1;
            };
            if (!first) covered.appendSlice(a, ",") catch @panic("OOM");
            first = false;
            covered.writer(a).print("\"{s}\"", .{prefix}) catch @panic("OOM");
        }
        std.debug.print("  ok {s}: {d} copied, {d} already there\n", .{ tenant, stats.copied, stats.skipped });
    }

    // The shared families, which belong to the cluster rather than to any one
    // tenant: request-log batches (`_logs/{node}/`) and spilled request bodies
    // (`_pool/`). A backup that skipped them would restore tenants whose
    // request history and large bodies had vanished — and neither is
    // reconstructible from anything else.
    //
    // Their prefixes come from the NODE, like the per-tenant ones, because
    // they hang off the resolved key-prefix base — which carries the storage
    // generation. Composing `{base}_logs/` here from this process's own env
    // walked a prefix the cluster does not write to and reported a cheerful
    // zero; the node is the only thing that knows where its objects went.
    var seen_shared: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_shared.deinit(a);
    for ((parsed.value.object.get("tenants").?).array.items) |entry| {
        const sps = entry.object.get("shared_prefixes") orelse continue;
        for (sps.array.items) |sp| {
            const prefix = sp.string;
            if (seen_shared.contains(prefix)) continue;
            seen_shared.put(a, prefix, {}) catch @panic("OOM");
            mirrorPrefix(a, &live.store, &target.store, prefix, &stats) catch {
                std.debug.print("mirror {s}: INCOMPLETE at {s}\n", .{ run_id, prefix });
                return 1;
            };
            if (!first) covered.appendSlice(a, ",") catch @panic("OOM");
            first = false;
            covered.writer(a).print("\"{s}\"", .{prefix}) catch @panic("OOM");
            std.debug.print("  ok {s}\n", .{prefix});
        }
    }
    if (seen_shared.count() == 0) {
        std.debug.print(
            "mirror {s}: the run's manifest names NO shared prefixes — it was taken by a node\n" ++
                "that does not report them, so request logs and pooled bodies are NOT covered.\n",
            .{run_id},
        );
        return 1;
    }

    // Written LAST, and only on a complete pass — the same rule the run
    // manifest follows. A mirror record present is the claim that every
    // prefix it names was walked to the end.
    const rec = std.fmt.allocPrint(
        a,
        "{{\"run_id\":\"{s}\",\"copied\":{d},\"skipped\":{d},\"bytes\":{d},\"prefixes\":[{s}]}}",
        .{ run_id, stats.copied, stats.skipped, stats.bytes, covered.items },
    ) catch @panic("OOM");
    defer a.free(rec);
    const rkey = std.fmt.allocPrint(a, "{s}/mirror.json", .{run_id}) catch @panic("OOM");
    defer a.free(rkey);
    target.store.blobStore().put(rkey, rec) catch |e|
        fatal("mirror record write failed: {s}", .{@errorName(e)});

    std.debug.print("mirror {s}: {d} object(s) copied, {d} already present, {d} bytes\n", .{
        run_id, stats.copied, stats.skipped, stats.bytes,
    });
    return 0;
}

// ── restore-directory ─────────────────────────────────────────────────

fn cmdRestoreDirectory(a: std.mem.Allocator, args: Args) !u8 {
    const run_id = args.run_id orelse fatal("restore-directory needs --run", .{});
    const cp = args.cp orelse fatal("restore-directory needs --cp", .{});
    var target = openBackupStore(a);
    defer target.store.deinit();
    const secret = moveSecret(a);

    const dkey = directoryKey(a, run_id);
    defer a.free(dkey);
    const rows = target.store.blobStore().get(dkey, a) catch |e|
        fatal("run {s} carries no directory ({s}) — it was taken with --no-directory", .{ run_id, @errorName(e) });
    defer a.free(rows);

    const url = try std.fmt.allocPrint(a, "{s}/_control/directory-restore", .{cp});
    defer a.free(url);
    var resp = curl.cpRequest(a, .POST, url, rows, .{
        .headers = &.{
            .{ .name = wire.MOVE_SECRET, .value = secret },
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .timeout_ms = 5 * 60 * 1000,
    }) catch |e| {
        std.debug.print("directory restore to {s}: {s}\n", .{ cp, @errorName(e) });
        return 1;
    };
    defer resp.deinit(a);
    switch (resp.status) {
        204 => {
            std.debug.print("directory restored into {s} ({d} bytes of rows)\n", .{ cp, rows.len });
            return 0;
        },
        409 => {
            std.debug.print(
                "REFUSED: {s} already places tenants of its own. A directory restore is for a\n" ++
                    "REBUILT control plane; against a live one it would overwrite the placements,\n" ++
                    "plans and incarnations of tenants that are serving.\n",
                .{cp},
            );
            return 1;
        },
        else => {
            std.debug.print("directory restore → {d} {s}\n", .{ resp.status, std.mem.trim(u8, resp.body orelse "", "\n") });
            return 1;
        },
    }
}

// ── show ──────────────────────────────────────────────────────────────

/// Print a run's manifest. It is what says, per tenant, which incarnation a
/// restore has to attach under — the one thing a restore cannot work out for
/// itself, and the difference between putting the data back and writing it
/// where nothing reads.
fn cmdShow(a: std.mem.Allocator, args: Args) !u8 {
    const run_id = args.run_id orelse fatal("show needs --run", .{});
    var target = openBackupStore(a);
    defer target.store.deinit();
    const mkey = manifestKey(a, run_id);
    defer a.free(mkey);
    const manifest = target.store.blobStore().get(mkey, a) catch |e|
        fatal("run {s} has no manifest: {s}", .{ run_id, @errorName(e) });
    defer a.free(manifest);
    var out = std.fs.File.stdout().writer(&.{});
    out.interface.writeAll(manifest) catch {};
    out.interface.writeAll("\n") catch {};
    return 0;
}

// ── restore ───────────────────────────────────────────────────────────

fn cmdRestore(a: std.mem.Allocator, args: Args) !u8 {
    const run_id = args.run_id orelse fatal("restore needs --run", .{});
    const tenant = args.tenant orelse fatal("restore needs --tenant", .{});
    if (args.nodes.len == 0) fatal("restore needs --nodes", .{});
    var target = openBackupStore(a);
    defer target.store.deinit();
    const secret = moveSecret(a);

    // The manifest names the parts; it is also what says which incarnation
    // the destination must be attached under.
    const mkey = manifestKey(a, run_id);
    defer a.free(mkey);
    const manifest = target.store.blobStore().get(mkey, a) catch |e|
        fatal("run {s} has no manifest: {s}", .{ run_id, @errorName(e) });
    defer a.free(manifest);
    const parsed = std.json.parseFromSlice(std.json.Value, a, manifest, .{}) catch |e|
        fatal("run {s}: manifest is not JSON: {s}", .{ run_id, @errorName(e) });
    defer parsed.deinit();
    var entry: ?std.json.Value = null;
    for ((parsed.value.object.get("tenants") orelse fatal("run {s}: no tenants", .{run_id})).array.items) |e| {
        if (std.mem.eql(u8, e.object.get("tenant").?.string, tenant)) entry = e;
    }
    const ent = entry orelse fatal("run {s} does not cover {s}", .{ run_id, tenant });
    const prefix = ent.object.get("prefix").?.string;

    const key = std.fmt.allocPrint(a, "{s}.snap", .{prefix}) catch @panic("OOM");
    defer a.free(key);
    const bytes = target.store.blobStore().get(key, a) catch |e|
        fatal("no backup for {s} in run {s}: {s}", .{ tenant, run_id, @errorName(e) });
    defer a.free(bytes);
    std.debug.print("restoring {s} from {s} ({d} bytes, incarnation {s})\n", .{
        tenant, key, bytes.len, ent.object.get("incarnation").?.string,
    });

    // `merge` — insert-if-absent, no baseline. The group this lands in was
    // attached empty, so merge and replace mean the same thing here, and
    // merge is the mode a push already carries: no baseline of ours can
    // disagree with the raft state of a cluster we know nothing about.
    var last: u16 = 0;
    for (args.nodes) |base| {
        const url = try std.fmt.allocPrint(a, "{s}/_system/v2-snapshot-stream", .{base});
        defer a.free(url);
        var resp = curl.cpRequest(a, .POST, url, bytes, .{
            .headers = &.{
                .{ .name = wire.MOVE_SECRET, .value = secret },
                .{ .name = wire.TENANT, .value = tenant },
                .{ .name = wire.SNAPSHOT_MODE, .value = "merge" },
                .{ .name = "Content-Type", .value = "application/octet-stream" },
            },
            .timeout_ms = 20 * 60 * 1000,
        }) catch |e| {
            std.debug.print("  {s}: {s} — trying the next node\n", .{ base, @errorName(e) });
            continue;
        };
        defer resp.deinit(a);
        last = resp.status;
        if (resp.status == 200 or resp.status == 204) {
            std.debug.print("  store restored into {s}\n", .{base});
            // The keyring goes in AFTER the store, and the order is the
            // point: the store carries this tenant's `_keys/dead/`
            // tombstones, and `TenantKeys.open` reconciles against them. Land
            // the keys first and a destroyed key could come back — an erasure
            // undone by a restore, which is the one thing a backup must not
            // do (rove#592).
            return restoreKeyring(a, &target.store, base, secret, tenant, prefix, ent);
        }
        std.debug.print("  {s}: {d} {s}\n", .{ base, resp.status, std.mem.trim(u8, resp.body orelse "", "\n") });
    }
    std.debug.print("restore of {s} FAILED (last status {d})\n", .{ tenant, last });
    return 1;
}

/// Land every keyring part the manifest names, on the node that just took the
/// store. Any part failing fails the restore: a tenant missing one shard reads
/// its own live data as erased, and the absence is authoritative — there is no
/// later repair that notices.
fn restoreKeyring(
    a: std.mem.Allocator,
    store: *blob.S3BlobStore,
    base: []const u8,
    secret: []const u8,
    tenant: []const u8,
    prefix: []const u8,
    entry: std.json.Value,
) !u8 {
    const parts = entry.object.get("keyring_parts") orelse {
        std.debug.print("restored {s} into {s} (no keyring in this backup)\n", .{ tenant, base });
        return 0;
    };
    const url = try std.fmt.allocPrint(a, "{s}/_system/v2-keyring-restore", .{base});
    defer a.free(url);

    for (parts.array.items) |pe| {
        const part = pe.object.get("part").?.string;
        const pkey = partKey(a, prefix, part);
        defer a.free(pkey);
        const sealed = store.blobStore().get(pkey, a) catch |e| {
            std.debug.print("  keyring {s}: unreadable in the backup store: {s}\n", .{ part, @errorName(e) });
            return 1;
        };
        defer a.free(sealed);
        var resp = curl.cpRequest(a, .POST, url, sealed, .{
            .headers = &.{
                .{ .name = wire.MOVE_SECRET, .value = secret },
                .{ .name = wire.TENANT, .value = tenant },
                .{ .name = wire.KEYRING_PART, .value = part },
                .{ .name = "Content-Type", .value = "application/octet-stream" },
            },
        }) catch |e| {
            std.debug.print("  keyring {s}: {s}\n", .{ part, @errorName(e) });
            return 1;
        };
        defer resp.deinit(a);
        if (resp.status != 204) {
            std.debug.print("  keyring {s}: {d} {s}\n", .{ part, resp.status, std.mem.trim(u8, resp.body orelse "", "\n") });
            if (resp.status == 409)
                std.debug.print("  (409 = sealed under a different cluster KEK than this cluster opens with)\n", .{});
            return 1;
        }
        std.debug.print("  keyring {s}: installed ({d} bytes)\n", .{ part, sealed.len });
    }
    std.debug.print("restored {s} into {s} — store + {d} keyring part(s)\n", .{ tenant, base, parts.array.items.len });
    return 0;
}

// ── list ──────────────────────────────────────────────────────────────

fn cmdList(a: std.mem.Allocator) !u8 {
    var target = openBackupStore(a);
    defer target.store.deinit();
    const runs = try listRuns(a, &target.store, target.owned.cfg.key_prefix_base);
    defer {
        for (runs) |r| a.free(r);
        a.free(runs);
    }
    if (runs.len == 0) {
        std.debug.print("no complete runs in the backup store\n", .{});
        return 0;
    }
    // Newest first: the one an operator wants is almost always the last one.
    var i = runs.len;
    while (i > 0) {
        i -= 1;
        std.debug.print("{s}\n", .{runs[i]});
    }
    return 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const argv = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, argv);
    const args = parseArgs(a, argv);

    const rc: u8 = if (std.mem.eql(u8, args.cmd, "run"))
        try cmdRun(a, args)
    else if (std.mem.eql(u8, args.cmd, "verify"))
        try cmdVerify(a, args)
    else if (std.mem.eql(u8, args.cmd, "restore"))
        try cmdRestore(a, args)
    else if (std.mem.eql(u8, args.cmd, "tenants"))
        try cmdTenants(a, args)
    else if (std.mem.eql(u8, args.cmd, "prune"))
        try cmdPrune(a, args)
    else if (std.mem.eql(u8, args.cmd, "mirror"))
        try cmdMirror(a, args)
    else if (std.mem.eql(u8, args.cmd, "restore-directory"))
        try cmdRestoreDirectory(a, args)
    else if (std.mem.eql(u8, args.cmd, "show"))
        try cmdShow(a, args)
    else if (std.mem.eql(u8, args.cmd, "list"))
        try cmdList(a)
    else
        fatal("unknown command '{s}' — try --help", .{args.cmd});

    std.process.exit(rc);
}
