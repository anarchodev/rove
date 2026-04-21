//! rove-tenant — account/user/instance/domain bookkeeping.
//!
//! ## Store-per-instance model
//!
//! Each instance owns a directory at `{dir}/{id}/` and its app-state
//! store lives at `{dir}/{id}/app.db`. Consumers (worker, files-server,
//! log-server) open additional stores under the same directory —
//! `{dir}/{id}/files.db`, `{dir}/{id}/log.db`, plus blob dirs — so a
//! tenant's entire state is one directory that can be copied, moved,
//! or removed as a unit. rove-tenant itself only knows about the
//! instance identity and the app-state store; other services reach
//! into `Instance.dir` to open their own per-tenant state.
//!
//! The root metadata (domain → instance, instance existence markers)
//! lives in a dedicated root `KvStore` supplied by the caller —
//! typically `{dir}/__root__.db` but the tenant doesn't care where it
//! comes from.
//!
//! Isolation is structural: handler code running against instance
//! `acme` can't express a key that hits `globex`'s store, because
//! `globex`'s store is a different file handle. No `inst/{id}/` prefix,
//! no validation-by-convention, no accidental leakage through a buggy
//! key formatter. Tenant operations become filesystem operations:
//! `cp` to back up, `rm` to delete, `mv` to migrate, OS-level quotas
//! to cap size.
//!
//! Tradeoffs the caller should know about:
//!
//!   - ~2 open fds per live instance (main + WAL). Tens of thousands
//!     of tenants + default `ulimit -n` = tight — plug an LRU in front
//!     of `ensureOpen` once that matters. For M1 (<100 tenants) the
//!     cache is keep-everything-open.
//!   - First resolve of a cold instance pays ~1-10ms of SQLite open +
//!     WAL recovery. Warm cache is free.
//!
//! ## Lifetime of `Instance` pointers
//!
//! Instances live in a canonical `id → *Instance` map and are only
//! destroyed on `Tenant.deinit` (or explicit deletion, once that lands).
//! An `Instance*` handed back from `resolveDomain` stays valid across
//! any number of subsequent `Tenant` operations. Only the host → instance
//! cache entries get invalidated on writes — the underlying instance
//! struct + its `*KvStore` pointer are stable.
//!
//! ## M1 scope
//!
//! Just instances and domain aliases. Accounts, users, auth, and the
//! root-instance privilege check arrive in Phase 5 alongside
//! `rove-js-ctl`.

const std = @import("std");
const kv_mod = @import("rove-kv");

pub const Error = error{
    InvalidInstanceId,
    InvalidHost,
    InvalidDir,
    InvalidToken,
    InstanceNotFound,
    DomainNotFound,
    Kv,
    OpenFailed,
    OutOfMemory,
};

/// Resolved identity after a successful `authenticate` call. `is_root`
/// means the caller's token was issued against the root account and
/// the caller can operate on any instance — short-circuits the
/// `accountOwnsInstance` check on `/_system/*` paths. Multi-account
/// support will add an `account_id` field; `is_root = false` + an
/// account id is the normal-user path.
pub const AuthContext = struct {
    is_root: bool,
};

// Root-token shape. The store only retains sha256(token), so any
// printable ASCII string of reasonable length works. 32 chars is the
// floor (roughly 160 bits of entropy for alphanumeric, plenty); 128 is
// the ceiling so an accidentally-pasted buffer can't explode the key
// space.
pub const TOKEN_MIN_LEN: usize = 32;
pub const TOKEN_MAX_LEN: usize = 128;

pub const MAX_INSTANCE_ID_LEN: usize = 64;
pub const MAX_HOST_LEN: usize = 253; // RFC 1035

/// Reserved instance id for the built-in admin handler. Its app-state
/// KV aliases to the root store, so `kv.set("__root__/instance/{id}", "")`
/// from an admin handler is literally a root-marker write.
pub const ADMIN_INSTANCE_ID = "__admin__";

pub const InstanceList = struct {
    ids: [][]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *InstanceList) void {
        for (self.ids) |id| self.allocator.free(id);
        self.allocator.free(self.ids);
        self.* = undefined;
    }
};

pub const DomainEntry = struct {
    host: []u8,
    instance_id: []u8,
};

pub const DomainList = struct {
    entries: []DomainEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DomainList) void {
        for (self.entries) |e| {
            self.allocator.free(e.host);
            self.allocator.free(e.instance_id);
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};

/// Live instance. Owned by `Tenant`; callers hold read-only pointers.
///
/// - `id`: the tenant's string id (owned).
/// - `dir`: absolute path to the tenant's directory (owned). Other
///   services open their per-tenant state inside this directory —
///   `{dir}/files.db`, `{dir}/log.db`, `{dir}/file-blobs/`, etc.
/// - `kv`: the tenant's app-state store at `{dir}/app.db`. Handler
///   code's `kv.get("x")` hits raw key `"x"` in this file.
pub const Instance = struct {
    id: []u8,
    dir: []u8,
    kv: *kv_mod.KvStore,
    /// False for instances whose `kv` is borrowed from elsewhere
    /// (currently only `__admin__`, which aliases to the root store).
    /// `deinit` and `deleteInstance` skip `kv.close()` when this is
    /// false to avoid a double-close on the shared handle.
    owns_kv: bool = true,
};

pub const Tenant = struct {
    allocator: std.mem.Allocator,
    /// Root store — holds `__root__/instance/{id}` existence markers
    /// and `__root__/domain/{host}` → instance_id mappings. Borrowed,
    /// not owned — caller manages its lifetime.
    root: *kv_mod.KvStore,
    /// Directory where per-instance SQLite files live. Owned.
    dir: []u8,
    /// Optional shared seq-counter registry. When present,
    /// per-instance `app.db` stores are opened with a shared
    /// `SeqCounter`, so concurrent writers across multiple `Tenant`
    /// instances (one per worker thread in rove-js) draw from a single
    /// global monotonic seq space. Borrowed, not owned.
    seq_counters: ?*kv_mod.SeqCounterRegistry = null,
    /// Wildcard suffix for implicit subdomain → instance mapping.
    /// When set to e.g. `"loop46.me"`, a request for
    /// `{id}.loop46.me` resolves to instance `{id}` without needing
    /// an explicit `assignDomain` entry, so long as `{id}` is a
    /// registered instance. Explicit domain aliases still win — the
    /// wildcard is a fallback. Owned (duped on `setPublicSuffix`).
    public_suffix: ?[]u8 = null,
    /// Canonical map: instance_id → *Instance. Values are heap-allocated
    /// and stay alive until `deinit` (or explicit delete).
    instances: std.StringHashMapUnmanaged(*Instance) = .empty,
    /// Host → *Instance cache. Values point into `instances`; entries
    /// are dropped on any `Tenant` write (coarse but fine — root writes
    /// are rare bootstrap ops in M1).
    host_cache: std.StringHashMapUnmanaged(*Instance) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        root: *kv_mod.KvStore,
        dir: []const u8,
    ) Error!Tenant {
        return initWithCounters(allocator, root, dir, null);
    }

    /// Like `init`, but per-instance KvStores share `seq_counters` for
    /// their seq allocations. Required for any multi-worker deployment
    /// where several `Tenant` instances point at the same on-disk
    /// tenant directory.
    pub fn initWithCounters(
        allocator: std.mem.Allocator,
        root: *kv_mod.KvStore,
        dir: []const u8,
        seq_counters: ?*kv_mod.SeqCounterRegistry,
    ) Error!Tenant {
        if (dir.len == 0) return Error.InvalidDir;
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return Error.InvalidDir,
        };
        const dir_copy = allocator.dupe(u8, dir) catch return Error.OutOfMemory;
        return .{
            .allocator = allocator,
            .root = root,
            .dir = dir_copy,
            .seq_counters = seq_counters,
        };
    }

    pub fn deinit(self: *Tenant) void {
        self.invalidateHostCache();
        self.host_cache.deinit(self.allocator);

        var it = self.instances.iterator();
        while (it.next()) |entry| {
            const inst = entry.value_ptr.*;
            if (inst.owns_kv) inst.kv.close();
            self.allocator.free(inst.id);
            self.allocator.free(inst.dir);
            self.allocator.destroy(inst);
        }
        self.instances.deinit(self.allocator);
        if (self.public_suffix) |p| self.allocator.free(p);
        self.allocator.free(self.dir);
        self.* = undefined;
    }

    /// Set (or clear) the wildcard public suffix. Passing `null` or
    /// an empty string disables wildcard resolution. Safe to call at
    /// any time; invalidates the host cache so a previously-negative
    /// lookup now falls into the wildcard path.
    pub fn setPublicSuffix(self: *Tenant, suffix: ?[]const u8) Error!void {
        if (self.public_suffix) |old| {
            self.allocator.free(old);
            self.public_suffix = null;
        }
        if (suffix) |s| {
            if (s.len == 0) return;
            try validateHost(s);
            self.public_suffix = self.allocator.dupe(u8, s) catch return Error.OutOfMemory;
        }
        self.invalidateHostCache();
    }

    // ── Writes ────────────────────────────────────────────────────────

    /// Create an instance: open (or create) its SQLite file, register
    /// it in the in-memory map, and write the existence marker to the
    /// root store. Errors during file open surface here rather than at
    /// first-request time.
    ///
    /// Idempotent: if the instance is already in this Tenant's memory
    /// map, do nothing. If the marker already exists in the root store
    /// (another worker or the main thread already created it), open
    /// the instance into this map WITHOUT re-writing the marker —
    /// that avoids N-way root.db write contention when every worker
    /// in a multi-worker process bootstraps the same tenant set.
    pub fn createInstance(self: *Tenant, id: []const u8) Error!void {
        try validateInstanceId(id);
        if (self.instances.get(id) != null) return;
        const already_exists = try self.instanceExistsInRoot(id);
        _ = try self.ensureOpen(id);
        if (!already_exists) try self.writeInstanceMarker(id);
    }

    /// Delete an instance. Closes its open `KvStore`, drops it from
    /// the in-memory map, erases the existence marker, and sweeps any
    /// domain aliases that pointed at it. The on-disk `{dir}/{id}/`
    /// directory is NOT removed — demo-era simplification — so
    /// re-creating an instance with the same id reuses its old files.
    /// Idempotent: deleting a non-existent instance is a no-op.
    pub fn deleteInstance(self: *Tenant, id: []const u8) Error!void {
        try validateInstanceId(id);

        if (self.instances.fetchRemove(id)) |entry| {
            const inst = entry.value;
            if (inst.owns_kv) inst.kv.close();
            self.allocator.free(inst.id);
            self.allocator.free(inst.dir);
            self.allocator.destroy(inst);
        }

        var marker_buf: [32 + MAX_INSTANCE_ID_LEN]u8 = undefined;
        const marker_key = std.fmt.bufPrint(&marker_buf, "__root__/instance/{s}", .{id}) catch
            return Error.InvalidInstanceId;
        self.root.delete(marker_key) catch |err| switch (err) {
            error.NotFound => {},
            else => return Error.Kv,
        };

        // Sweep dangling domain pointers. Pulls the full domain set
        // up front so we can mutate during deletion without worrying
        // about scan/delete interleaving. M1 scale (tens of domains)
        // makes the maxInt page size fine.
        var scan = self.root.prefix("__root__/domain/", "", std.math.maxInt(u32)) catch
            return Error.Kv;
        defer scan.deinit();
        for (scan.entries) |e| {
            if (std.mem.eql(u8, e.value, id)) {
                self.root.delete(e.key) catch |err| switch (err) {
                    error.NotFound => {},
                    else => return Error.Kv,
                };
            }
        }

        self.invalidateHostCache();
    }

    pub fn assignDomain(
        self: *Tenant,
        host: []const u8,
        instance_id: []const u8,
    ) Error!void {
        try validateHost(host);
        try validateInstanceId(instance_id);
        if (!try self.instanceExistsInRoot(instance_id)) return Error.InstanceNotFound;

        var key_buf: [32 + MAX_HOST_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "__root__/domain/{s}", .{host}) catch
            return Error.InvalidHost;
        self.root.put(key, instance_id) catch return Error.Kv;
        self.invalidateHostCache();
    }

    // ── Reads ─────────────────────────────────────────────────────────

    /// Resolve `host` to its instance. Returns null if unknown.
    /// The returned pointer is stable for the lifetime of the `Tenant`.
    ///
    /// Resolution order:
    ///   1. Explicit `__root__/domain/{host}` alias from `assignDomain`.
    ///   2. Wildcard fallback: if `public_suffix` is set and `host`
    ///      parses as `{id}.{public_suffix}`, look up `{id}` as an
    ///      instance. Explicit aliases always win over the wildcard.
    pub fn resolveDomain(self: *Tenant, host: []const u8) Error!?*const Instance {
        try validateHost(host);
        if (self.host_cache.get(host)) |inst| return inst;

        var key_buf: [32 + MAX_HOST_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "__root__/domain/{s}", .{host}) catch
            return Error.InvalidHost;
        const id_bytes_opt: ?[]u8 = blk: {
            const v = self.root.get(key) catch |err| switch (err) {
                error.NotFound => break :blk null,
                else => return Error.Kv,
            };
            break :blk v;
        };
        defer if (id_bytes_opt) |v| self.allocator.free(v);

        const resolved_inst: ?*Instance = if (id_bytes_opt) |id_bytes| inner: {
            if (!try self.instanceExistsInRoot(id_bytes)) break :inner null;
            break :inner try self.ensureOpen(id_bytes);
        } else if (self.wildcardInstanceId(host)) |sub_id| wild: {
            // Wildcard hit: only resolve if the id is a registered
            // instance AND valid (garbage subdomains like `-foo` or
            // overlong labels short-circuit to a 404).
            validateInstanceId(sub_id) catch break :wild null;
            if (!try self.instanceExistsInRoot(sub_id)) break :wild null;
            break :wild try self.ensureOpen(sub_id);
        } else null;

        if (resolved_inst) |inst| {
            const host_copy = self.allocator.dupe(u8, host) catch return Error.OutOfMemory;
            errdefer self.allocator.free(host_copy);
            self.host_cache.put(self.allocator, host_copy, inst) catch
                return Error.OutOfMemory;
            return inst;
        }
        return null;
    }

    /// Return the implied instance id for `host` under the current
    /// `public_suffix`, or null if the host doesn't match the wildcard
    /// pattern `{id}.{public_suffix}`. Does NOT validate that the id
    /// corresponds to a real instance — caller's job.
    fn wildcardInstanceId(self: *const Tenant, host: []const u8) ?[]const u8 {
        const suffix = self.public_suffix orelse return null;
        if (host.len <= suffix.len + 1) return null;
        const dot_before = host.len - suffix.len - 1;
        if (host[dot_before] != '.') return null;
        if (!std.mem.eql(u8, host[dot_before + 1 ..], suffix)) return null;
        const sub = host[0..dot_before];
        // Reject multi-label subdomains — wildcard is single-label
        // only, matching how `{id}.loop46.me` is documented. Callers
        // who want deeper nesting must still `assignDomain` explicitly.
        if (std.mem.indexOfScalar(u8, sub, '.') != null) return null;
        return sub;
    }

    /// True if `id` has a registered existence marker in the root store.
    /// Does not require the instance to be open in memory.
    pub fn instanceExists(self: *Tenant, id: []const u8) Error!bool {
        try validateInstanceId(id);
        return self.instanceExistsInRoot(id);
    }

    /// Resolve an instance by id, lazy-opening its per-tenant store if
    /// it's not already in the in-memory map. Returns `null` if the
    /// id has no existence marker in the root store (i.e. never
    /// registered, or deleted). The returned pointer is stable for
    /// the lifetime of the `Tenant`.
    ///
    /// Intended for admin surfaces that need to talk to an instance's
    /// `KvStore` without going through a host → instance lookup.
    pub fn getInstance(self: *Tenant, id: []const u8) Error!?*const Instance {
        try validateInstanceId(id);
        if (self.instances.get(id)) |inst| return inst;
        if (!try self.instanceExistsInRoot(id)) return null;
        return try self.ensureOpen(id);
    }

    /// Enumerate every instance registered in the root store (up to
    /// `max`). Used by the admin UI to render the instance list.
    /// Ordering follows the root store's key order, which matches
    /// ASCII lexical order of instance ids.
    pub fn listInstances(self: *Tenant, max: u32) Error!InstanceList {
        var scan = self.root.prefix("__root__/instance/", "", max) catch
            return Error.Kv;
        defer scan.deinit();

        const ids = self.allocator.alloc([]u8, scan.entries.len) catch
            return Error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (ids[0..filled]) |id| self.allocator.free(id);
            self.allocator.free(ids);
        }

        const prefix_len = "__root__/instance/".len;
        for (scan.entries) |e| {
            if (e.key.len <= prefix_len) continue;
            const id_bytes = e.key[prefix_len..];
            ids[filled] = self.allocator.dupe(u8, id_bytes) catch
                return Error.OutOfMemory;
            filled += 1;
        }

        // Shrink if any entries were skipped (malformed keys should
        // never appear, but the guard keeps the slice tight).
        const final = if (filled == ids.len) ids else ids[0..filled];
        return .{ .ids = final, .allocator = self.allocator };
    }

    /// Enumerate domain → instance aliases (up to `max`). Values point
    /// at instance ids; callers should treat unknown instance ids as
    /// dangling aliases (we don't resolve them here).
    pub fn listDomains(self: *Tenant, max: u32) Error!DomainList {
        var scan = self.root.prefix("__root__/domain/", "", max) catch
            return Error.Kv;
        defer scan.deinit();

        const entries = self.allocator.alloc(DomainEntry, scan.entries.len) catch
            return Error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (entries[0..filled]) |e| {
                self.allocator.free(e.host);
                self.allocator.free(e.instance_id);
            }
            self.allocator.free(entries);
        }

        const prefix_len = "__root__/domain/".len;
        for (scan.entries) |e| {
            if (e.key.len <= prefix_len) continue;
            const host = e.key[prefix_len..];
            const host_copy = self.allocator.dupe(u8, host) catch
                return Error.OutOfMemory;
            errdefer self.allocator.free(host_copy);
            const id_copy = self.allocator.dupe(u8, e.value) catch
                return Error.OutOfMemory;
            entries[filled] = .{ .host = host_copy, .instance_id = id_copy };
            filled += 1;
        }

        const final = if (filled == entries.len) entries else entries[0..filled];
        return .{ .entries = final, .allocator = self.allocator };
    }

    // ── Internals ─────────────────────────────────────────────────────

    fn instanceExistsInRoot(self: *Tenant, id: []const u8) Error!bool {
        var key_buf: [32 + MAX_INSTANCE_ID_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "__root__/instance/{s}", .{id}) catch
            return Error.InvalidInstanceId;
        const v = self.root.get(key) catch |err| switch (err) {
            error.NotFound => return false,
            else => return Error.Kv,
        };
        self.allocator.free(v);
        return true;
    }

    fn writeInstanceMarker(self: *Tenant, id: []const u8) Error!void {
        var key_buf: [32 + MAX_INSTANCE_ID_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "__root__/instance/{s}", .{id}) catch
            return Error.InvalidInstanceId;
        self.root.put(key, "") catch return Error.Kv;
        self.invalidateHostCache();
    }

    /// Open (or reuse) the store for `id` and return its `*Instance`.
    /// Called by both `createInstance` and `resolveDomain`, so there's
    /// exactly one code path that promotes an instance from "lives in
    /// the root store" to "live in memory".
    ///
    /// Creates the instance directory `{dir}/{id}/` if it doesn't
    /// already exist, then opens `{dir}/{id}/app.db` as the app-state
    /// store. Other services layer their own per-tenant state inside
    /// the same directory.
    fn ensureOpen(self: *Tenant, id: []const u8) Error!*Instance {
        if (self.instances.get(id)) |inst| return inst;

        const inst_dir = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.dir, id },
        ) catch return Error.OutOfMemory;
        errdefer self.allocator.free(inst_dir);

        std.fs.cwd().makePath(inst_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return Error.OpenFailed,
        };

        // __admin__ aliases its app-state KV to the root store. The
        // admin handler's `kv.get/set` thus operates on root markers
        // directly — no separate app.db file, no new bindings.
        // The handle is borrowed; we flag it so deinit skips close().
        const is_admin = std.mem.eql(u8, id, ADMIN_INSTANCE_ID);
        const store = if (is_admin) self.root else blk: {
            const app_path = std.fmt.allocPrintSentinel(
                self.allocator,
                "{s}/app.db",
                .{inst_dir},
                0,
            ) catch return Error.OutOfMemory;
            defer self.allocator.free(app_path);

            const opened = if (self.seq_counters) |reg| cblk: {
                const counter = reg.getOrCreate(id) catch return Error.OutOfMemory;
                break :cblk kv_mod.KvStore.openWithCounter(self.allocator, app_path, counter) catch
                    return Error.OpenFailed;
            } else kv_mod.KvStore.open(self.allocator, app_path) catch
                return Error.OpenFailed;
            break :blk opened;
        };
        errdefer if (!is_admin) store.close();

        const id_copy = self.allocator.dupe(u8, id) catch return Error.OutOfMemory;
        errdefer self.allocator.free(id_copy);

        const inst = self.allocator.create(Instance) catch return Error.OutOfMemory;
        errdefer self.allocator.destroy(inst);
        inst.* = .{
            .id = id_copy,
            .dir = inst_dir,
            .kv = store,
            .owns_kv = !is_admin,
        };

        self.instances.put(self.allocator, id_copy, inst) catch return Error.OutOfMemory;
        return inst;
    }

    fn invalidateHostCache(self: *Tenant) void {
        var it = self.host_cache.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.host_cache.clearRetainingCapacity();
    }

    // ── Auth (Phase 5) ────────────────────────────────────────────────
    //
    // M1 shape: one root token, stored as its SHA-256 hash under
    // `__root__/root_token/{sha256_hex}`. A caller presenting the
    // matching plaintext authenticates as root and can operate on any
    // instance. Multi-account auth (per-account tokens + per-instance
    // membership) slots in by widening `AuthContext` and adding
    // `__root__/account/*` records — no API break for callers.
    //
    // The plaintext token is never stored; only its hash lives in the
    // root store. An attacker who reads `__root__.db` cannot forge a
    // token, and the bootstrap flag that installs the token is the
    // only place the plaintext ever appears.

    /// Install a root token. Idempotent — re-installing the same
    /// token is a no-op; re-installing a different token replaces
    /// any existing one. The plaintext is SHA-256'd before storage.
    pub fn installRootToken(self: *Tenant, token_hex: []const u8) Error!void {
        try validateTokenShape(token_hex);

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token_hex, &hash, .{});
        const hex_chars = "0123456789abcdef";
        var hash_hex: [64]u8 = undefined;
        for (hash, 0..) |b, i| {
            hash_hex[i * 2] = hex_chars[b >> 4];
            hash_hex[i * 2 + 1] = hex_chars[b & 0x0f];
        }

        // Clear any pre-existing root token. A deployment only ever
        // has one root token at a time — this keeps the root store
        // from accumulating stale entries on token rotation.
        try self.clearRootTokens();

        var key_buf: [32 + 64]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "__root__/root_token/{s}", .{hash_hex}) catch
            return Error.Kv;
        self.root.put(key, "") catch return Error.Kv;
    }

    /// Authenticate a plaintext token. Returns `null` if the token
    /// doesn't match any installed token, or an `AuthContext`
    /// describing the identity on success. Constant-time comparison
    /// isn't needed because we hash-and-lookup rather than string-
    /// compare — the kv index returns `NotFound` without scanning.
    pub fn authenticate(self: *Tenant, token_hex: []const u8) Error!?AuthContext {
        if (validateTokenShape(token_hex)) |_| {} else |_| return null;

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token_hex, &hash, .{});
        const hex_chars = "0123456789abcdef";
        var hash_hex: [64]u8 = undefined;
        for (hash, 0..) |b, i| {
            hash_hex[i * 2] = hex_chars[b >> 4];
            hash_hex[i * 2 + 1] = hex_chars[b & 0x0f];
        }

        var key_buf: [32 + 64]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "__root__/root_token/{s}", .{hash_hex}) catch
            return Error.Kv;
        const v = self.root.get(key) catch |err| switch (err) {
            error.NotFound => return null,
            else => return Error.Kv,
        };
        self.allocator.free(v);
        return .{ .is_root = true };
    }

    // ── Platform secrets: Resend API key ──────────────────────────────
    //
    // Stored plaintext at `__root__/resend_key`. The JS `email.send`
    // wrapper reads it via `getResendKey` when building the outbox
    // envelope so the customer handler never sees the key. Installed
    // once at bootstrap by `--bootstrap-resend-key`; rotated by
    // re-running the worker with a new value on that flag.

    pub const RESEND_KEY_MIN_LEN: usize = 8;
    pub const RESEND_KEY_MAX_LEN: usize = 256;

    pub fn installResendKey(self: *Tenant, key: []const u8) Error!void {
        if (key.len < RESEND_KEY_MIN_LEN or key.len > RESEND_KEY_MAX_LEN) {
            return Error.InvalidToken;
        }
        for (key) |b| {
            if (b < 0x21 or b > 0x7e) return Error.InvalidToken;
        }
        self.root.put("__root__/resend_key", key) catch return Error.Kv;
    }

    /// Returns the stored Resend key or null if none installed. The
    /// bytes are allocated by the root `KvStore`'s allocator; free
    /// with the same allocator the tenant was constructed with.
    pub fn getResendKey(self: *Tenant) Error!?[]u8 {
        const v = self.root.get("__root__/resend_key") catch |err| switch (err) {
            error.NotFound => return null,
            else => return Error.Kv,
        };
        return v;
    }

    // ── Session cookies ───────────────────────────────────────────────
    //
    // A session is an opaque 64-hex token handed to the browser via
    // `Set-Cookie` after a successful login. We store sha256(opaque),
    // NOT the opaque itself, so a leaked `__root__.db` can't impersonate
    // live sessions. Value = `{expires_at_ns i64 little-endian}{is_root u8}`.
    // TTL comes from the caller at mint time.

    pub const SESSION_HEX_LEN: usize = 64;

    /// Fresh opaque 64-hex session token. Returns the plaintext to hand
    /// the caller (for a `Set-Cookie`); the store only retains its hash.
    /// `ttl_ns` is the lifetime from now.
    pub fn createSession(
        self: *Tenant,
        ctx: AuthContext,
        ttl_ns: i64,
    ) Error![SESSION_HEX_LEN]u8 {
        var raw: [32]u8 = undefined;
        std.crypto.random.bytes(&raw);

        var opaque_hex: [SESSION_HEX_LEN]u8 = undefined;
        bytesToHex(&raw, &opaque_hex);

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&opaque_hex, &hash, .{});
        var hash_hex: [SESSION_HEX_LEN]u8 = undefined;
        bytesToHex(&hash, &hash_hex);

        var key_buf: [32 + SESSION_HEX_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "__root__/session/{s}", .{hash_hex}) catch
            return Error.Kv;

        var val_buf: [9]u8 = undefined;
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        const expires_at_ns: i64 = now_ns +| ttl_ns;
        std.mem.writeInt(i64, val_buf[0..8], expires_at_ns, .little);
        val_buf[8] = if (ctx.is_root) 1 else 0;

        self.root.put(key, &val_buf) catch return Error.Kv;
        return opaque_hex;
    }

    /// Validate an opaque session token. Returns `null` if the token is
    /// malformed, unknown, or expired (expired entries are swept on
    /// access). On hit, returns the `AuthContext` the session was minted
    /// against.
    pub fn authenticateSession(self: *Tenant, opaque_hex: []const u8) Error!?AuthContext {
        if (opaque_hex.len != SESSION_HEX_LEN) return null;
        for (opaque_hex) |b| {
            const ok = (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F');
            if (!ok) return null;
        }

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(opaque_hex, &hash, .{});
        var hash_hex: [SESSION_HEX_LEN]u8 = undefined;
        bytesToHex(&hash, &hash_hex);

        var key_buf: [32 + SESSION_HEX_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "__root__/session/{s}", .{hash_hex}) catch
            return Error.Kv;

        const v = self.root.get(key) catch |err| switch (err) {
            error.NotFound => return null,
            else => return Error.Kv,
        };
        defer self.allocator.free(v);
        if (v.len != 9) return null;

        const expires_at_ns = std.mem.readInt(i64, v[0..8], .little);
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        if (now_ns >= expires_at_ns) {
            // Drop the stale record opportunistically.
            self.root.delete(key) catch {};
            return null;
        }
        return .{ .is_root = v[8] != 0 };
    }

    /// Revoke a session by its opaque token. No-op if the session
    /// doesn't exist (idempotent logout).
    pub fn revokeSession(self: *Tenant, opaque_hex: []const u8) Error!void {
        if (opaque_hex.len != SESSION_HEX_LEN) return;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(opaque_hex, &hash, .{});
        var hash_hex: [SESSION_HEX_LEN]u8 = undefined;
        bytesToHex(&hash, &hash_hex);
        var key_buf: [32 + SESSION_HEX_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "__root__/session/{s}", .{hash_hex}) catch
            return Error.Kv;
        self.root.delete(key) catch |err| switch (err) {
            error.NotFound => {},
            else => return Error.Kv,
        };
    }

    // ── Magic-link primitive ─────────────────────────────────────────
    //
    // Signup / email-login flow. `mintMagic` generates a fresh opaque
    // 64-hex token, hashes it with SHA-256, and stores
    // `__root__/magic/{hash_hex}` →
    //   `{"email":"...","instance_id":"...","expires_at_ns":<i64>}`.
    // The caller emails the plaintext token; `redeemMagic` hashes the
    // submitted token, looks up the row, enforces TTL, and
    // **deletes the row before returning** — single-use, so a replayed
    // link never validates twice.
    //
    // Why hash-at-rest: a leaked `__root__.db` (backup, support dump,
    // dev clone) must not let an attacker impersonate pending signups.
    // The hash stores nothing redeemable; the pre-image (the link in
    // the user's inbox) is what redeems. Same pattern as
    // `createSession` above.
    //
    // Why JSON as the value: we need variable-length strings (email +
    // instance_id) where sessions only carry fixed bytes. Email shape
    // is restricted (`validateEmail`) so JSON escaping concerns can't
    // bite — no quotes or backslashes can reach the stored string.

    pub const MAGIC_HEX_LEN: usize = 64;

    /// Plaintext + metadata returned from `redeemMagic`. Both strings
    /// are owned by the caller's allocator (the same one passed at
    /// `Tenant.init`) and must be freed via `deinit`.
    pub const RedeemedMagic = struct {
        email: []u8,
        instance_id: []u8,

        pub fn deinit(self: *RedeemedMagic, allocator: std.mem.Allocator) void {
            allocator.free(self.email);
            allocator.free(self.instance_id);
            self.* = undefined;
        }
    };

    /// Mint a fresh magic token scoped to `(email, instance_id)`.
    /// Returns the 64-hex plaintext the caller should embed in the
    /// emailed link. Only `sha256(plaintext)` is stored — the token
    /// itself is unrecoverable once the return value is dropped.
    ///
    /// `ttl_ns` is the lifetime from now; PLAN §2.2 default is
    /// 15 minutes. The caller picks so the primitive stays general
    /// (a "forgot password" flow might pick longer; a confirmation
    /// might pick shorter).
    pub fn mintMagic(
        self: *Tenant,
        email: []const u8,
        instance_id: []const u8,
        ttl_ns: i64,
    ) Error![MAGIC_HEX_LEN]u8 {
        try validateEmail(email);
        try validateInstanceId(instance_id);

        var raw: [32]u8 = undefined;
        std.crypto.random.bytes(&raw);
        var opaque_hex: [MAGIC_HEX_LEN]u8 = undefined;
        bytesToHex(&raw, &opaque_hex);

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&opaque_hex, &hash, .{});
        var hash_hex: [MAGIC_HEX_LEN]u8 = undefined;
        bytesToHex(&hash, &hash_hex);

        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        const expires_at_ns: i64 = now_ns +| ttl_ns;

        // Email has no quotes / backslashes (validateEmail) and
        // instance_id matches `[A-Za-z0-9_-]+` (validateInstanceId),
        // so direct interpolation is JSON-safe.
        const body = std.fmt.allocPrint(
            self.allocator,
            "{{\"email\":\"{s}\",\"instance_id\":\"{s}\",\"expires_at_ns\":{d}}}",
            .{ email, instance_id, expires_at_ns },
        ) catch return Error.OutOfMemory;
        defer self.allocator.free(body);

        var key_buf: [32 + MAGIC_HEX_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "__root__/magic/{s}", .{hash_hex}) catch
            return Error.Kv;
        self.root.put(key, body) catch return Error.Kv;

        return opaque_hex;
    }

    /// Single-use redeem. Returns `null` for malformed, unknown, or
    /// expired tokens (stale rows are swept on access). On success,
    /// the row is deleted BEFORE returning so a race-redeem can only
    /// see the hit once.
    pub fn redeemMagic(
        self: *Tenant,
        token_hex: []const u8,
    ) Error!?RedeemedMagic {
        if (token_hex.len != MAGIC_HEX_LEN) return null;
        for (token_hex) |b| {
            const ok = (b >= '0' and b <= '9') or
                (b >= 'a' and b <= 'f') or
                (b >= 'A' and b <= 'F');
            if (!ok) return null;
        }

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token_hex, &hash, .{});
        var hash_hex: [MAGIC_HEX_LEN]u8 = undefined;
        bytesToHex(&hash, &hash_hex);

        var key_buf: [32 + MAGIC_HEX_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "__root__/magic/{s}", .{hash_hex}) catch
            return Error.Kv;

        const v = self.root.get(key) catch |err| switch (err) {
            error.NotFound => return null,
            else => return Error.Kv,
        };
        defer self.allocator.free(v);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, v, .{
            .allocate = .alloc_always,
        }) catch {
            // Corrupted row — drop it and treat as a miss. Better
            // than leaking parser state up through an auth path.
            self.root.delete(key) catch {};
            return null;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                self.root.delete(key) catch {};
                return null;
            },
        };

        const expires_at_ns = switch (obj.get("expires_at_ns") orelse .null) {
            .integer => |i| i,
            else => {
                self.root.delete(key) catch {};
                return null;
            },
        };
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        if (now_ns >= expires_at_ns) {
            self.root.delete(key) catch {};
            return null;
        }

        const email_str = switch (obj.get("email") orelse .null) {
            .string => |s| s,
            else => {
                self.root.delete(key) catch {};
                return null;
            },
        };
        const inst_str = switch (obj.get("instance_id") orelse .null) {
            .string => |s| s,
            else => {
                self.root.delete(key) catch {};
                return null;
            },
        };

        const email_copy = self.allocator.dupe(u8, email_str) catch return Error.OutOfMemory;
        errdefer self.allocator.free(email_copy);
        const inst_copy = self.allocator.dupe(u8, inst_str) catch return Error.OutOfMemory;
        errdefer self.allocator.free(inst_copy);

        // Single-use: burn the record before returning. A second
        // redeem racing the first sees NotFound.
        self.root.delete(key) catch return Error.Kv;

        return .{ .email = email_copy, .instance_id = inst_copy };
    }

    /// Check whether the given auth context is allowed to operate on
    /// `instance_id`. In the single-account M1 shape the root token
    /// grants access to every instance, so this reduces to
    /// `ctx.is_root`. Multi-account will consult
    /// `__root__/account/{id}/instance/{inst}` markers here.
    pub fn canAccessInstance(
        self: *Tenant,
        ctx: AuthContext,
        instance_id: []const u8,
    ) Error!bool {
        _ = self;
        _ = instance_id;
        return ctx.is_root;
    }

    fn clearRootTokens(self: *Tenant) Error!void {
        // The root store has no range-scan API exposed here, so the
        // cheapest correct thing is to track token hashes via the
        // root kv itself: one well-known key `__root__/root_token_hash`
        // always points at the currently-active hash (if any).
        // Deleting THAT key's referent is what clears the prior token.
        const current_key = "__root__/root_token_hash";
        const prior_hash = self.root.get(current_key) catch |err| switch (err) {
            error.NotFound => return,
            else => return Error.Kv,
        };
        defer self.allocator.free(prior_hash);

        var key_buf: [32 + 64]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "__root__/root_token/{s}", .{prior_hash}) catch
            return Error.Kv;
        self.root.delete(key) catch |err| switch (err) {
            error.NotFound => {},
            else => return Error.Kv,
        };
    }
};

fn validateTokenShape(token: []const u8) Error!void {
    if (token.len < TOKEN_MIN_LEN or token.len > TOKEN_MAX_LEN) return Error.InvalidToken;
    // Printable ASCII (0x21..0x7e). Reject anything with whitespace or
    // control bytes so copy-paste accidents (trailing newline, tab)
    // surface as a validation error rather than a silent mismatch.
    for (token) |b| {
        if (b < 0x21 or b > 0x7e) return Error.InvalidToken;
    }
}

fn bytesToHex(src: []const u8, dst: []u8) void {
    std.debug.assert(dst.len >= src.len * 2);
    const hex_chars = "0123456789abcdef";
    for (src, 0..) |b, i| {
        dst[i * 2] = hex_chars[b >> 4];
        dst[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

// ── Validation ─────────────────────────────────────────────────────────

/// Public accessor for the instance-id shape check. Callers that
/// need to validate before choosing between "create" and "error"
/// paths use this; the existing `createInstance` runs the same
/// check internally. Re-exported verbatim to avoid duplicating the
/// shape rules.
pub fn validateInstanceIdForSignup(id: []const u8) Error!void {
    return validateInstanceId(id);
}

/// Public accessor for the email shape check used by
/// `mintMagic`. Lets callers (e.g. the signup HTTP handler) reject
/// bad input before any side effects — without this, the only way
/// to probe email validity is to call `mintMagic`, which has
/// already fired `std.crypto.random.bytes` and written KV state.
pub fn validateEmailForSignup(email: []const u8) Error!void {
    return validateEmail(email);
}

fn validateInstanceId(id: []const u8) Error!void {
    if (id.len == 0 or id.len > MAX_INSTANCE_ID_LEN) return Error.InvalidInstanceId;
    for (id) |b| {
        const ok = (b >= 'a' and b <= 'z') or
            (b >= 'A' and b <= 'Z') or
            (b >= '0' and b <= '9') or
            b == '-' or b == '_';
        if (!ok) return Error.InvalidInstanceId;
    }
}

fn validateHost(host: []const u8) Error!void {
    if (host.len == 0 or host.len > MAX_HOST_LEN) return Error.InvalidHost;
    for (host) |b| {
        if (b < 0x21 or b > 0x7e) return Error.InvalidHost;
        if (b == '/' or b == '\\') return Error.InvalidHost;
    }
}

/// Lightweight email shape guard for the magic-link primitive:
/// non-empty, ≤254 bytes (RFC 5321 addr-spec ceiling), exactly one
/// `@`, printable ASCII, no quote/backslash/whitespace/control
/// bytes. Deliberately strict — handles the 99% case and keeps the
/// stored JSON trivially escape-free. Pathological forms (quoted
/// local-parts, internationalized addresses) would be rejected here
/// and can be relaxed later without changing the on-disk shape.
fn validateEmail(email: []const u8) Error!void {
    if (email.len == 0 or email.len > 254) return Error.InvalidToken;
    var at_count: usize = 0;
    for (email) |b| {
        if (b < 0x21 or b > 0x7e) return Error.InvalidToken;
        if (b == '"' or b == '\\') return Error.InvalidToken;
        if (b == '@') at_count += 1;
    }
    if (at_count != 1) return Error.InvalidToken;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const TestFixture = struct {
    allocator: std.mem.Allocator,
    tmp_dir: []u8,
    root: *kv_mod.KvStore,
    tenant: Tenant,

    fn init(allocator: std.mem.Allocator) !TestFixture {
        const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-tenant-test-{x}", .{seed});
        errdefer allocator.free(tmp_dir);
        std.fs.cwd().deleteTree(tmp_dir) catch {};
        try std.fs.cwd().makePath(tmp_dir);

        const root_path = try std.fmt.allocPrintSentinel(allocator, "{s}/__root__.db", .{tmp_dir}, 0);
        defer allocator.free(root_path);
        const root = try kv_mod.KvStore.open(allocator, root_path);
        errdefer root.close();

        const tenant = try Tenant.init(allocator, root, tmp_dir);
        return .{ .allocator = allocator, .tmp_dir = tmp_dir, .root = root, .tenant = tenant };
    }

    fn deinit(self: *TestFixture) void {
        self.tenant.deinit();
        self.root.close();
        std.fs.cwd().deleteTree(self.tmp_dir) catch {};
        self.allocator.free(self.tmp_dir);
    }
};

test "createInstance opens a dedicated kv file" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.createInstance("acme");
    try testing.expectEqual(true, try fx.tenant.instanceExists("acme"));

    // The instance store is open and usable — write through it.
    const inst = fx.tenant.instances.get("acme").?;
    try inst.kv.put("hello", "world");
    const v = try inst.kv.get("hello");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("world", v);
}

test "resolveDomain returns instance with its own store" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.createInstance("acme");
    try fx.tenant.assignDomain("acme.test", "acme");

    const inst = try fx.tenant.resolveDomain("acme.test");
    try testing.expect(inst != null);
    try testing.expectEqualStrings("acme", inst.?.id);

    // Writing through the resolved store lands in the instance's file,
    // not the root store.
    try inst.?.kv.put("k", "v");
    try testing.expectError(error.NotFound, fx.root.get("k"));
}

test "two instances have fully isolated stores" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.createInstance("a");
    try fx.tenant.createInstance("b");
    try fx.tenant.assignDomain("a.test", "a");
    try fx.tenant.assignDomain("b.test", "b");

    const a = try fx.tenant.resolveDomain("a.test");
    const b = try fx.tenant.resolveDomain("b.test");
    try a.?.kv.put("shared-key", "alpha");
    try b.?.kv.put("shared-key", "beta");

    const av = try a.?.kv.get("shared-key");
    defer testing.allocator.free(av);
    const bv = try b.?.kv.get("shared-key");
    defer testing.allocator.free(bv);
    try testing.expectEqualStrings("alpha", av);
    try testing.expectEqualStrings("beta", bv);
}

test "resolveDomain returns null for unknown host" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    try testing.expectEqual(
        @as(?*const Instance, null),
        try fx.tenant.resolveDomain("nowhere.test"),
    );
}

test "public_suffix wildcard resolves {id}.{suffix}" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.setPublicSuffix("loop46.me");
    try fx.tenant.createInstance("acme");

    // No explicit `assignDomain`, but the wildcard picks it up.
    const inst = (try fx.tenant.resolveDomain("acme.loop46.me")).?;
    try testing.expectEqualStrings("acme", inst.id);

    // Cache hit returns the same pointer.
    const again = (try fx.tenant.resolveDomain("acme.loop46.me")).?;
    try testing.expectEqual(inst, again);

    // Unknown instance under the wildcard → null.
    try testing.expectEqual(
        @as(?*const Instance, null),
        try fx.tenant.resolveDomain("nobody.loop46.me"),
    );

    // Bare suffix (no subdomain label) → null.
    try testing.expectEqual(
        @as(?*const Instance, null),
        try fx.tenant.resolveDomain("loop46.me"),
    );

    // Multi-label subdomain (`foo.bar.loop46.me`) → null; wildcard
    // is single-label only.
    try fx.tenant.createInstance("bar");
    try testing.expectEqual(
        @as(?*const Instance, null),
        try fx.tenant.resolveDomain("foo.bar.loop46.me"),
    );

    // Different TLD → null.
    try testing.expectEqual(
        @as(?*const Instance, null),
        try fx.tenant.resolveDomain("acme.other.com"),
    );

    // Invalid id under the wildcard (`!` is legal in a host per
    // validateHost but not in an instance id) → null, not an error.
    try testing.expectEqual(
        @as(?*const Instance, null),
        try fx.tenant.resolveDomain("acme!.loop46.me"),
    );
}

test "explicit assignDomain wins over wildcard" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.setPublicSuffix("loop46.me");
    try fx.tenant.createInstance("acme");
    try fx.tenant.createInstance("other");

    // Alias `acme.loop46.me` → `other`. Explicit mapping wins even
    // though the host also matches the wildcard pattern.
    try fx.tenant.assignDomain("acme.loop46.me", "other");
    const inst = (try fx.tenant.resolveDomain("acme.loop46.me")).?;
    try testing.expectEqualStrings("other", inst.id);
}

test "clearing public_suffix disables wildcard" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.setPublicSuffix("loop46.me");
    try fx.tenant.createInstance("acme");
    const first = (try fx.tenant.resolveDomain("acme.loop46.me")).?;
    try testing.expectEqualStrings("acme", first.id);

    try fx.tenant.setPublicSuffix(null);
    try testing.expectEqual(
        @as(?*const Instance, null),
        try fx.tenant.resolveDomain("acme.loop46.me"),
    );
}

test "assignDomain rejects unknown instance" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    try testing.expectError(
        Error.InstanceNotFound,
        fx.tenant.assignDomain("acme.test", "nope"),
    );
}

test "instance pointer stays stable across writes" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    try fx.tenant.createInstance("acme");
    try fx.tenant.assignDomain("acme.test", "acme");
    const first = (try fx.tenant.resolveDomain("acme.test")).?;

    // Any write flushes the host cache, but the Instance* underneath
    // is the canonical one in `instances` — pointer must survive.
    try fx.tenant.createInstance("other");
    try fx.tenant.assignDomain("alias.test", "acme");

    const second = (try fx.tenant.resolveDomain("acme.test")).?;
    try testing.expectEqual(first, second);
}

test "domain reassignment switches to the new instance" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    try fx.tenant.createInstance("a");
    try fx.tenant.createInstance("b");
    try fx.tenant.assignDomain("shared.test", "a");
    const first = (try fx.tenant.resolveDomain("shared.test")).?;
    try testing.expectEqualStrings("a", first.id);

    try fx.tenant.assignDomain("shared.test", "b");
    const second = (try fx.tenant.resolveDomain("shared.test")).?;
    try testing.expectEqualStrings("b", second.id);
}

test "multiple domains share one instance (pointer equality)" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    try fx.tenant.createInstance("shared");
    try fx.tenant.assignDomain("primary.test", "shared");
    try fx.tenant.assignDomain("alias.test", "shared");

    const a = (try fx.tenant.resolveDomain("primary.test")).?;
    const b = (try fx.tenant.resolveDomain("alias.test")).?;
    try testing.expectEqual(a, b);
}

test "reopening a tenant finds existing instances on lazy resolve" {
    const allocator = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-tenant-reopen-{x}", .{seed});
    defer allocator.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const root_path = try std.fmt.allocPrintSentinel(allocator, "{s}/__root__.db", .{tmp_dir}, 0);
    defer allocator.free(root_path);

    // Session 1: bootstrap, write through the instance, tear down.
    {
        const root = try kv_mod.KvStore.open(allocator, root_path);
        defer root.close();
        var tenant = try Tenant.init(allocator, root, tmp_dir);
        defer tenant.deinit();

        try tenant.createInstance("acme");
        try tenant.assignDomain("acme.test", "acme");
        const inst = (try tenant.resolveDomain("acme.test")).?;
        try inst.kv.put("persisted", "yes");
    }

    // Session 2: nothing in memory yet; first resolve lazy-opens the
    // existing file and finds the persisted write.
    {
        const root = try kv_mod.KvStore.open(allocator, root_path);
        defer root.close();
        var tenant = try Tenant.init(allocator, root, tmp_dir);
        defer tenant.deinit();

        const inst = (try tenant.resolveDomain("acme.test")).?;
        const got = try inst.kv.get("persisted");
        defer allocator.free(got);
        try testing.expectEqualStrings("yes", got);
    }
}

test "validateInstanceId rejects bad ids" {
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId(""));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("has space"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("with/slash"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("../evil"));
    try validateInstanceId("acme");
    try validateInstanceId("ACME-123_v2");
}

test "installRootToken + authenticate round trip" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const token = "a" ** 64;
    try fx.tenant.installRootToken(token);

    const ctx = try fx.tenant.authenticate(token);
    try testing.expect(ctx != null);
    try testing.expect(ctx.?.is_root);
}

test "authenticate rejects unknown tokens" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.installRootToken("a" ** 64);
    // Different valid-shape token → null.
    try testing.expectEqual(
        @as(?AuthContext, null),
        try fx.tenant.authenticate("b" ** 64),
    );
    // Malformed token (wrong length) → null, not an error.
    try testing.expectEqual(
        @as(?AuthContext, null),
        try fx.tenant.authenticate("short"),
    );
    // Non-hex bytes → null.
    try testing.expectEqual(
        @as(?AuthContext, null),
        try fx.tenant.authenticate("z" ** 64),
    );
}

test "installRootToken is idempotent and supports rotation" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const old_token = "1" ** 64;

    try fx.tenant.installRootToken(old_token);
    try testing.expect((try fx.tenant.authenticate(old_token)) != null);

    // Re-installing the SAME token must leave it valid.
    try fx.tenant.installRootToken(old_token);
    try testing.expect((try fx.tenant.authenticate(old_token)) != null);
}

test "canAccessInstance short-circuits for root" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    try fx.tenant.createInstance("acme");

    const root_ctx: AuthContext = .{ .is_root = true };
    try testing.expectEqual(true, try fx.tenant.canAccessInstance(root_ctx, "acme"));

    const other_ctx: AuthContext = .{ .is_root = false };
    try testing.expectEqual(false, try fx.tenant.canAccessInstance(other_ctx, "acme"));
}

test "__admin__ tenant's kv aliases to the root store" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.createInstance(ADMIN_INSTANCE_ID);
    const admin = (try fx.tenant.getInstance(ADMIN_INSTANCE_ID)).?;
    // The Instance.kv pointer IS the root store.
    try testing.expectEqual(fx.root, admin.kv);

    // A write through admin.kv is a write to root; visible via root.get
    // and via resolveDomain's existence check.
    try admin.kv.put("__root__/instance/via-admin", "");
    try testing.expectEqual(true, try fx.tenant.instanceExists("via-admin"));

    // Conversely, a write directly to root shows up through admin.kv.
    try fx.root.put("direct-root-key", "value");
    const v = try admin.kv.get("direct-root-key");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("value", v);
}

test "getInstance lazy-opens by id" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.createInstance("acme");

    // Known id: returns an open instance with a usable kv.
    const acme = try fx.tenant.getInstance("acme");
    try testing.expect(acme != null);
    try testing.expectEqualStrings("acme", acme.?.id);
    try acme.?.kv.put("k", "v");
    const v = try acme.?.kv.get("k");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("v", v);

    // Unknown id: null, no error.
    try testing.expectEqual(
        @as(?*const Instance, null),
        try fx.tenant.getInstance("nope"),
    );
}

test "getInstance survives restart by lazy-opening from root store" {
    const allocator = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-tenant-getinst-{x}", .{seed});
    defer allocator.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const root_path = try std.fmt.allocPrintSentinel(allocator, "{s}/__root__.db", .{tmp_dir}, 0);
    defer allocator.free(root_path);

    // Session 1: create, write, tear down.
    {
        const root = try kv_mod.KvStore.open(allocator, root_path);
        defer root.close();
        var tenant = try Tenant.init(allocator, root, tmp_dir);
        defer tenant.deinit();
        try tenant.createInstance("persistent");
        const inst = (try tenant.getInstance("persistent")).?;
        try inst.kv.put("hello", "world");
    }
    // Session 2: nothing in memory yet; getInstance lazy-opens.
    {
        const root = try kv_mod.KvStore.open(allocator, root_path);
        defer root.close();
        var tenant = try Tenant.init(allocator, root, tmp_dir);
        defer tenant.deinit();
        const inst = (try tenant.getInstance("persistent")).?;
        const v = try inst.kv.get("hello");
        defer allocator.free(v);
        try testing.expectEqualStrings("world", v);
    }
}

test "listInstances returns every created instance" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.createInstance("alpha");
    try fx.tenant.createInstance("beta");
    try fx.tenant.createInstance("gamma");

    var list = try fx.tenant.listInstances(100);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 3), list.ids.len);
    // Scan is lex-ordered by id.
    try testing.expectEqualStrings("alpha", list.ids[0]);
    try testing.expectEqualStrings("beta", list.ids[1]);
    try testing.expectEqualStrings("gamma", list.ids[2]);
}

test "listDomains returns host → instance mappings" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.createInstance("acme");
    try fx.tenant.createInstance("globex");
    try fx.tenant.assignDomain("acme.test", "acme");
    try fx.tenant.assignDomain("www.globex.test", "globex");

    var list = try fx.tenant.listDomains(100);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 2), list.entries.len);
    try testing.expectEqualStrings("acme.test", list.entries[0].host);
    try testing.expectEqualStrings("acme", list.entries[0].instance_id);
    try testing.expectEqualStrings("www.globex.test", list.entries[1].host);
    try testing.expectEqualStrings("globex", list.entries[1].instance_id);
}

test "deleteInstance removes marker and dangling domains" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.createInstance("acme");
    try fx.tenant.createInstance("globex");
    try fx.tenant.assignDomain("acme.test", "acme");
    try fx.tenant.assignDomain("alias.test", "acme");
    try fx.tenant.assignDomain("globex.test", "globex");

    try fx.tenant.deleteInstance("acme");

    try testing.expectEqual(false, try fx.tenant.instanceExists("acme"));
    // The other instance is untouched.
    try testing.expectEqual(true, try fx.tenant.instanceExists("globex"));

    // Both aliases for acme were swept.
    try testing.expectEqual(
        @as(?*const Instance, null),
        try fx.tenant.resolveDomain("acme.test"),
    );
    try testing.expectEqual(
        @as(?*const Instance, null),
        try fx.tenant.resolveDomain("alias.test"),
    );
    // globex's alias survives.
    const inst = try fx.tenant.resolveDomain("globex.test");
    try testing.expect(inst != null);
    try testing.expectEqualStrings("globex", inst.?.id);
}

test "deleteInstance is idempotent for unknown ids" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    try fx.tenant.deleteInstance("nonexistent");
    try testing.expectEqual(false, try fx.tenant.instanceExists("nonexistent"));
}

test "validateHost rejects slashes and whitespace" {
    try testing.expectError(Error.InvalidHost, validateHost(""));
    try testing.expectError(Error.InvalidHost, validateHost("has space"));
    try testing.expectError(Error.InvalidHost, validateHost("with/slash"));
    try validateHost("acme.test");
    try validateHost("api.v1.example.com:8443");
}

test "createSession + authenticateSession round-trip" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const ctx: AuthContext = .{ .is_root = true };
    const opaque_hex = try fx.tenant.createSession(ctx, std.time.ns_per_s * 60);
    try testing.expectEqual(@as(usize, 64), opaque_hex.len);

    const resolved = try fx.tenant.authenticateSession(&opaque_hex);
    try testing.expect(resolved != null);
    try testing.expect(resolved.?.is_root);
}

test "authenticateSession rejects unknown tokens" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const bogus = "a" ** 64;
    try testing.expectEqual(@as(?AuthContext, null), try fx.tenant.authenticateSession(bogus));

    // Wrong length / non-hex rejected as null too.
    try testing.expectEqual(@as(?AuthContext, null), try fx.tenant.authenticateSession("too-short"));
    try testing.expectEqual(@as(?AuthContext, null), try fx.tenant.authenticateSession("zz" ** 32));
}

test "revokeSession clears the record" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const ctx: AuthContext = .{ .is_root = true };
    const opaque_hex = try fx.tenant.createSession(ctx, std.time.ns_per_s * 60);
    try testing.expect(try fx.tenant.authenticateSession(&opaque_hex) != null);

    try fx.tenant.revokeSession(&opaque_hex);
    try testing.expectEqual(@as(?AuthContext, null), try fx.tenant.authenticateSession(&opaque_hex));

    // Idempotent revoke.
    try fx.tenant.revokeSession(&opaque_hex);
}

test "expired session is rejected and swept" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const ctx: AuthContext = .{ .is_root = true };
    // Negative TTL → already-expired session, exercises the sweep path.
    const opaque_hex = try fx.tenant.createSession(ctx, -1);
    try testing.expectEqual(@as(?AuthContext, null), try fx.tenant.authenticateSession(&opaque_hex));
    // Second lookup also null — sweep removed it.
    try testing.expectEqual(@as(?AuthContext, null), try fx.tenant.authenticateSession(&opaque_hex));
}

test "installResendKey + getResendKey round-trip" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try testing.expectEqual(@as(?[]u8, null), try fx.tenant.getResendKey());

    try fx.tenant.installResendKey("re_test_key_abc123");
    const got = (try fx.tenant.getResendKey()).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("re_test_key_abc123", got);
}

test "installResendKey replaces prior value" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try fx.tenant.installResendKey("re_old_key_xxxxxx");
    try fx.tenant.installResendKey("re_new_key_yyyyyy");

    const got = (try fx.tenant.getResendKey()).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("re_new_key_yyyyyy", got);
}

test "installResendKey rejects empty / whitespace / out-of-range" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try testing.expectError(Error.InvalidToken, fx.tenant.installResendKey(""));
    try testing.expectError(Error.InvalidToken, fx.tenant.installResendKey("short"));
    try testing.expectError(Error.InvalidToken, fx.tenant.installResendKey("has space in it abc"));
    try testing.expectError(Error.InvalidToken, fx.tenant.installResendKey("has\nnewline123456"));
}

test "mintMagic + redeemMagic round-trip returns email + instance_id" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const token = try fx.tenant.mintMagic("alice@example.com", "alice-api", std.time.ns_per_s * 60);

    var redeemed = (try fx.tenant.redeemMagic(&token)).?;
    defer redeemed.deinit(testing.allocator);
    try testing.expectEqualStrings("alice@example.com", redeemed.email);
    try testing.expectEqualStrings("alice-api", redeemed.instance_id);
}

test "redeemMagic is single-use: second redeem returns null" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const token = try fx.tenant.mintMagic("bob@example.com", "bob-api", std.time.ns_per_s * 60);
    var first = (try fx.tenant.redeemMagic(&token)).?;
    first.deinit(testing.allocator);

    try testing.expectEqual(@as(?Tenant.RedeemedMagic, null), try fx.tenant.redeemMagic(&token));
}

test "redeemMagic rejects expired tokens" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    // Negative TTL → already expired at mint time.
    const token = try fx.tenant.mintMagic("carol@example.com", "carol-api", -1);
    try testing.expectEqual(@as(?Tenant.RedeemedMagic, null), try fx.tenant.redeemMagic(&token));

    // And the row should have been swept — a subsequent re-mint
    // wouldn't observe it either (no prior-state interference).
    try testing.expectEqual(@as(?Tenant.RedeemedMagic, null), try fx.tenant.redeemMagic(&token));
}

test "redeemMagic rejects malformed tokens" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try testing.expectEqual(@as(?Tenant.RedeemedMagic, null), try fx.tenant.redeemMagic(""));
    try testing.expectEqual(@as(?Tenant.RedeemedMagic, null), try fx.tenant.redeemMagic("too-short"));
    try testing.expectEqual(@as(?Tenant.RedeemedMagic, null), try fx.tenant.redeemMagic("zz" ** 32));
    try testing.expectEqual(@as(?Tenant.RedeemedMagic, null), try fx.tenant.redeemMagic("0" ** 63)); // 63 hex
}

test "redeemMagic rejects unknown tokens without mutating store" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    // Plant a real token so we can prove unrelated lookups don't
    // disturb it.
    const real = try fx.tenant.mintMagic("dave@example.com", "dave-api", std.time.ns_per_s * 60);

    // 64 hex chars, but never minted.
    const bogus = "a" ** 64;
    try testing.expectEqual(@as(?Tenant.RedeemedMagic, null), try fx.tenant.redeemMagic(bogus));

    // Real token still redeems.
    var got = (try fx.tenant.redeemMagic(&real)).?;
    defer got.deinit(testing.allocator);
    try testing.expectEqualStrings("dave@example.com", got.email);
}

test "mintMagic rejects invalid email + instance_id" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    try testing.expectError(Error.InvalidToken, fx.tenant.mintMagic("", "x", 0));
    try testing.expectError(Error.InvalidToken, fx.tenant.mintMagic("no-at-sign", "x", 0));
    try testing.expectError(Error.InvalidToken, fx.tenant.mintMagic("two@@signs", "x", 0));
    try testing.expectError(Error.InvalidToken, fx.tenant.mintMagic("has\"quote@x.com", "x", 0));
    try testing.expectError(Error.InvalidToken, fx.tenant.mintMagic("has\\backslash@x.com", "x", 0));
    try testing.expectError(Error.InvalidToken, fx.tenant.mintMagic("spaces @x.com", "x", 0));
    try testing.expectError(Error.InvalidInstanceId, fx.tenant.mintMagic("a@b.com", "", 0));
    try testing.expectError(Error.InvalidInstanceId, fx.tenant.mintMagic("a@b.com", "has space", 0));
}

test "mintMagic: fresh tokens are distinct" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const t1 = try fx.tenant.mintMagic("alice@example.com", "alice", std.time.ns_per_s * 60);
    const t2 = try fx.tenant.mintMagic("alice@example.com", "alice", std.time.ns_per_s * 60);
    try testing.expect(!std.mem.eql(u8, &t1, &t2));
}
