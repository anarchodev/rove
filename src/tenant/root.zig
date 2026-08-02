// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rove-tenant — account/user/instance/domain bookkeeping.
//!
//! ## Store-per-instance model
//!
//! Each instance owns a directory at `{dir}/{id}/` and its app-state
//! store lives at `{dir}/{id}/app.db`. Consumers (worker, log-server)
//! open additional stores under the same directory —
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
//! ## Scope
//!
//! Instances, domain aliases, root-token auth, and admin sessions.
//! A full multi-account user model is not modeled here.

const std = @import("std");
const kv_mod = @import("raft-kv");
/// The id spec itself lives in a leaf module because the control plane
/// enforces the same rule when it provisions a tenant, and resolves the same
/// `{id}.{suffix}` wildcard when the front door asks who owns a host.
const id_spec = @import("rove-instance-id");
const storage_mod = @import("storage.zig");

/// The tenant-storage handle: `(id, incarnation)` plus every derivation —
/// key prefixes, signed paths, blob backends, store ids, directories. See
/// `storage.zig` for why the bare id must never be the input to any of them.
pub const TenantStorage = storage_mod.TenantStorage;
pub const Incarnation = storage_mod.Incarnation;

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

pub const MAX_INSTANCE_ID_LEN = id_spec.MAX_INSTANCE_ID_LEN;

/// An instance's storage INCARNATION: an opaque lowercase-hex token minted per
/// tenant LIFETIME, so storage identity is (name, incarnation) rather than name
/// alone. Deprovision frees a name for reuse, and without this the next holder
/// of that name would address the previous holder's KV rows and S3 objects.
pub const MAX_INCARNATION_LEN = storage_mod.MAX_INCARNATION_LEN;
pub const MAX_HOST_LEN: usize = 253; // RFC 1035

/// Reserved instance id for the built-in admin handler. The admin
/// tenant is an instance like any other — its own `{dir}/app.db`,
/// its own outbox, its own per-request logs — plus one singleton
/// capability: `Instance.platform` points back at the `Tenant`, so
/// the admin JS handler can issue platform operations (instance
/// CRUD, domain CRUD, root kv reads) via the `platform.*` globals.
/// Every other instance has `platform = null`.
pub const ADMIN_INSTANCE_ID = id_spec.ADMIN_INSTANCE_ID;

/// Reserved tenant id for the tape-replay browser page (PLAN §10.12).
/// Bootstrapped as a regular instance — no `platform` capability, no
/// special dispatch path. The only platform-special bit is the
/// `replay.{public_suffix}` host alias added in `bootstrapTenants`,
/// which routes the well-known host straight at this tenant via the
/// existing `assignDomain` machinery.
pub const REPLAY_INSTANCE_ID = id_spec.REPLAY_INSTANCE_ID;

/// Reserved tenant id for the OIDC identity provider
/// (auth-domain-plan.md §4). Same shape as `__replay__`: a regular
/// instance, no `platform` capability, reached via the
/// `auth.{system_suffix}` host alias added in bootstrap. Runs the
/// `oidc.provider()` library + a magic-link login.
pub const AUTH_INSTANCE_ID = id_spec.AUTH_INSTANCE_ID;

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
/// - `platform`: non-null only on the singleton admin instance
///   (`id == ADMIN_INSTANCE_ID`). When set, points back at the
///   owning `Tenant` — the JS dispatcher uses its presence to gate
///   installation of the `platform.*` globals (instance CRUD, root
///   kv, etc.). Regular instances see `platform === undefined` in
///   their handlers.
pub const Instance = struct {
    id: []u8,
    dir: []u8,
    kv: *kv_mod.KvStore,
    platform: ?*Tenant = null,
    /// This instance's storage identity — THE handle every consumer that
    /// opens per-tenant storage (blob backends, sibling KV handles, signed
    /// paths) derives from, so all of them address the same tenant lifetime
    /// without re-reading the root store. `storage.id` aliases `id`; a
    /// `.token` incarnation aliases a buffer owned by this instance.
    storage: TenantStorage,
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
    /// Serializes every read or write of `instances` and `host_cache`.
    /// Worker threads call `resolveDomain` concurrently with distinct
    /// hosts and contend on `host_cache.put` (std.HashMap rehashes
    /// invalidate concurrent reads), so coarse-grained locking is the
    /// minimum-correct choice. Reads are short — single map.get or
    /// fixed-size iteration — so contention stays bounded at the
    /// per-tenant scale we run today.
    maps_mutex: std.Thread.Mutex = .{},
    /// Operator-supplied root bearer token (the `LOOP46_ROOT_TOKEN`
    /// env var). When non-null, presenting an `Authorization: Bearer
    /// <this>` proves "platform operator." When null, every request
    /// authenticates as non-root — useful in tests + tenants that
    /// don't expose a root surface. Borrowed; lifetime managed by
    /// the caller (typically the worker's main() frame which holds
    /// the env-var slice for the process lifetime).
    root_token_secret: ?[]const u8 = null,

    /// Heap-allocate a `Tenant`. The admin instance's `platform`
    /// capability field stores a pointer BACK at this Tenant (see
    /// `ensureOpen` + rove-library principle 14 "Heap-Allocate
    /// Structs with Interior Pointers"), so the Tenant must live at
    /// a stable address for its entire lifetime — copying or moving
    /// it after `createInstance(ADMIN_INSTANCE_ID)` would leave the
    /// pointer dangling. Pair with `destroy`.
    pub fn create(
        allocator: std.mem.Allocator,
        root: *kv_mod.KvStore,
        dir: []const u8,
    ) Error!*Tenant {
        return createWithCounters(allocator, root, dir, null);
    }

    /// Like `create`, but per-instance KvStores share `seq_counters`
    /// for their seq allocations. Required for any multi-worker
    /// deployment where several `Tenant` instances point at the same
    /// on-disk tenant directory.
    pub fn createWithCounters(
        allocator: std.mem.Allocator,
        root: *kv_mod.KvStore,
        dir: []const u8,
        seq_counters: ?*kv_mod.SeqCounterRegistry,
    ) Error!*Tenant {
        if (dir.len == 0) return Error.InvalidDir;
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return Error.InvalidDir,
        };
        const dir_copy = allocator.dupe(u8, dir) catch return Error.OutOfMemory;
        errdefer allocator.free(dir_copy);
        const self = allocator.create(Tenant) catch return Error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .root = root,
            .dir = dir_copy,
            .seq_counters = seq_counters,
        };
        return self;
    }

    pub fn destroy(self: *Tenant) void {
        const allocator = self.allocator;
        self.invalidateHostCache();
        self.host_cache.deinit(self.allocator);

        var it = self.instances.iterator();
        while (it.next()) |entry| {
            const inst = entry.value_ptr.*;
            inst.kv.close();
            allocator.free(inst.id);
            allocator.free(inst.dir);
            inst.storage.incarnation.free(allocator);
            allocator.destroy(inst);
        }
        self.instances.deinit(allocator);
        if (self.public_suffix) |p| allocator.free(p);
        allocator.free(self.dir);
        allocator.destroy(self);
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

    /// Read the configured public suffix (for diagnostic / banner use).
    /// Returns null when wildcard customer-subdomain resolution is
    /// disabled.
    pub fn publicSuffix(self: *const Tenant) ?[]const u8 {
        return self.public_suffix;
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
        return self.createInstanceWithIncarnation(id, .legacy);
    }

    /// `createInstance`, binding the instance to a storage INCARNATION.
    ///
    /// The incarnation is what keeps one tenant's storage unreachable from the
    /// next tenant to hold the same name (docs/architecture/consensus-and-storage.md,
    /// "Storage incarnation"). It is NOT generated here: `createInstance` runs
    /// independently on every node, so a locally-minted value would differ per
    /// node and each would derive a different store id for the same tenant. It
    /// is minted once by the control plane at provision and delivered with the
    /// attach, exactly as the plan blob is.
    ///
    /// An EXISTING marker always wins, even over a supplied incarnation: the
    /// marker is what the tenant's live data is already keyed by, so honouring
    /// a different value would silently orphan it. That also makes re-attach
    /// and lazy re-open idempotent.
    ///
    /// `.legacy` = keyed by name alone. Instances created before incarnations
    /// exist keep their storage exactly where it is, so this needs no
    /// migration; they are also never at risk, because a name could not be
    /// freed and reused before deprovision.
    pub fn createInstanceWithIncarnation(self: *Tenant, id: []const u8, incarnation: Incarnation) Error!void {
        try validateInstanceId(id);
        switch (incarnation) {
            .legacy => {},
            .token => |t| {
                if (t.len == 0 or t.len > MAX_INCARNATION_LEN) return Error.InvalidInstanceId;
                for (t) |b| {
                    const ok = (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9');
                    if (!ok) return Error.InvalidInstanceId;
                }
            },
        }
        const already_exists = try self.instanceExistsInRoot(id);
        {
            self.maps_mutex.lock();
            defer self.maps_mutex.unlock();
            if (self.instances.get(id) != null) return;
            // On FIRST creation the marker does not exist yet, so the open
            // cannot learn the incarnation by reading it back — pass it in.
            // (Opening before writing the marker is deliberate: a failed open
            // must not leave a marker claiming the instance exists.) An
            // existing instance ignores the argument and reads its marker,
            // because that is what its live data is already keyed by.
            _ = try self.ensureOpenLockedWith(id, if (already_exists) null else incarnation);
        }
        if (!already_exists) try self.writeInstanceMarker(id, incarnation.marker());
    }

    /// Delete an instance. Closes its open `KvStore`, drops it from
    /// the in-memory map, erases the existence marker, and sweeps any
    /// domain aliases that pointed at it. The on-disk `{dir}/{id}/`
    /// directory is NOT removed (a deliberate simplification), so
    /// re-creating an instance with the same id reuses its old files.
    /// Idempotent: deleting a non-existent instance is a no-op.
    pub fn deleteInstance(self: *Tenant, id: []const u8) Error!void {
        try validateInstanceId(id);

        {
            self.maps_mutex.lock();
            defer self.maps_mutex.unlock();
            if (self.instances.fetchRemove(id)) |entry| {
                const inst = entry.value;
                inst.kv.close();
                self.allocator.free(inst.id);
                self.allocator.free(inst.dir);
                inst.storage.incarnation.free(self.allocator);
                self.allocator.destroy(inst);
            }
        }

        var marker_buf: [16 + MAX_INSTANCE_ID_LEN]u8 = undefined;
        const marker_key = std.fmt.bufPrint(&marker_buf, "instance/{s}", .{id}) catch
            return Error.InvalidInstanceId;
        self.root.delete(marker_key) catch |err| switch (err) {
            error.NotFound => {},
            else => return Error.Kv,
        };

        // Sweep dangling domain pointers. Pulls the full domain set
        // up front so we can mutate during deletion without worrying
        // about scan/delete interleaving. M1 scale (tens of domains)
        // makes the maxInt page size fine.
        var scan = self.root.prefix("domain/", "", std.math.maxInt(u32)) catch
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

        var key_buf: [16 + MAX_HOST_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "domain/{s}", .{host}) catch
            return Error.InvalidHost;
        self.root.put(key, instance_id) catch return Error.Kv;
        self.invalidateHostCache();
    }

    // ── Reads ─────────────────────────────────────────────────────────

    /// Resolve `host` to its instance. Returns null if unknown.
    /// The returned pointer is stable for the lifetime of the `Tenant`.
    ///
    /// Resolution order:
    ///   1. Explicit `domain/{host}` alias from `assignDomain`.
    ///   2. Wildcard fallback: if `public_suffix` is set and `host`
    ///      parses as `{id}.{public_suffix}`, look up `{id}` as an
    ///      instance. Explicit aliases always win over the wildcard.
    pub fn resolveDomain(self: *Tenant, host: []const u8) Error!?*const Instance {
        try validateHost(host);
        // Fast path: cache hit under a brief lock.
        {
            self.maps_mutex.lock();
            defer self.maps_mutex.unlock();
            if (self.host_cache.get(host)) |inst| return inst;
        }

        var key_buf: [16 + MAX_HOST_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "domain/{s}", .{host}) catch
            return Error.InvalidHost;
        const id_bytes_opt: ?[]u8 = blk: {
            const v = self.root.get(key) catch |err| switch (err) {
                error.NotFound => break :blk null,
                else => return Error.Kv,
            };
            break :blk v;
        };
        defer if (id_bytes_opt) |v| self.allocator.free(v);

        // Slow path: serialize the resolve + insert under one lock.
        // Re-check the cache first — another thread may have inserted
        // while we were waiting on root.get.
        self.maps_mutex.lock();
        defer self.maps_mutex.unlock();
        if (self.host_cache.get(host)) |inst| return inst;

        const resolved_inst: ?*Instance = if (id_bytes_opt) |id_bytes| inner: {
            if (!try self.instanceExistsInRoot(id_bytes)) break :inner null;
            break :inner try self.ensureOpenLocked(id_bytes);
        } else if (self.wildcardInstanceId(host)) |sub_id| wild: {
            // Wildcard hit: only resolve if the id is a registered
            // instance AND valid (garbage subdomains like `-foo` or
            // overlong labels short-circuit to a 404).
            validateInstanceId(sub_id) catch break :wild null;
            if (!try self.instanceExistsInRoot(sub_id)) break :wild null;
            break :wild try self.ensureOpenLocked(sub_id);
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
        return id_spec.wildcardLabel(host, suffix);
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
        {
            self.maps_mutex.lock();
            defer self.maps_mutex.unlock();
            if (self.instances.get(id)) |inst| return inst;
        }
        if (!try self.instanceExistsInRoot(id)) return null;
        self.maps_mutex.lock();
        defer self.maps_mutex.unlock();
        if (self.instances.get(id)) |inst| return inst;
        return try self.ensureOpenLocked(id);
    }

    /// Enumerate every instance registered in the root store (up to
    /// `max`). Used by the admin UI to render the instance list.
    /// Ordering follows the root store's key order, which matches
    /// ASCII lexical order of instance ids.
    pub fn listInstances(self: *Tenant, max: u32) Error!InstanceList {
        var scan = self.root.prefix("instance/", "", max) catch
            return Error.Kv;
        defer scan.deinit();

        const ids = self.allocator.alloc([]u8, scan.entries.len) catch
            return Error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (ids[0..filled]) |id| self.allocator.free(id);
            self.allocator.free(ids);
        }

        const prefix_len = "instance/".len;
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
        var scan = self.root.prefix("domain/", "", max) catch
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

        const prefix_len = "domain/".len;
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
        var key_buf: [16 + MAX_INSTANCE_ID_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "instance/{s}", .{id}) catch
            return Error.InvalidInstanceId;
        const v = self.root.get(key) catch |err| switch (err) {
            error.NotFound => return false,
            else => return Error.Kv,
        };
        self.allocator.free(v);
        return true;
    }

    fn writeInstanceMarker(self: *Tenant, id: []const u8, incarnation: []const u8) Error!void {
        var key_buf: [16 + MAX_INSTANCE_ID_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "instance/{s}", .{id}) catch
            return Error.InvalidInstanceId;
        self.root.put(key, incarnation) catch return Error.Kv;
        self.invalidateHostCache();
    }

    /// The instance's storage handle, resolved by NAME — for callers that
    /// don't hold a live `*Instance` (the fetch-engine doors, the deploy
    /// staging paths). `storage.id` borrows `id`; a `.token` incarnation is
    /// owned by the caller: free it with `storage.incarnation.free(a)`.
    ///
    /// Read from the ROOT store rather than the instance map, because a
    /// follower learns the marker by applying it replicated, which may land
    /// before anything opens the instance locally.
    ///
    /// An ABSENT marker is `Error.InstanceNotFound`, never legacy: "this
    /// instance has name-keyed storage" is a fact recorded in the marker,
    /// while "there is no marker" means the instance doesn't exist — and
    /// conflating the two is what turned every missed incarnation hand-off
    /// into a quiet read of the wrong tenant lifetime (#357).
    pub fn storageOf(self: *Tenant, a: std.mem.Allocator, id: []const u8) Error!TenantStorage {
        var key_buf: [16 + MAX_INSTANCE_ID_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "instance/{s}", .{id}) catch
            return Error.InvalidInstanceId;
        const v = self.root.get(key) catch |err| switch (err) {
            error.NotFound => return Error.InstanceNotFound,
            else => return Error.Kv,
        };
        defer self.allocator.free(v);
        const owned = a.dupe(u8, v) catch return Error.OutOfMemory;
        if (owned.len == 0) {
            a.free(owned);
            return .{ .id = id, .incarnation = .legacy };
        }
        return .{ .id = id, .incarnation = .{ .token = owned } };
    }

    /// Open (or reuse) the store for `id` and return its `*Instance`.
    /// Called by both `createInstance` and `resolveDomain`, so there's
    /// exactly one code path that promotes an instance from "lives in
    /// the root store" to "live in memory".
    ///
    /// Creates the instance directory `{dir}/{id}/` if it doesn't
    /// already exist, then opens `{dir}/{id}/app.db` as the app-state
    /// store. Other services layer their own per-tenant state inside
    /// the same directory. The singleton `__admin__` is treated
    /// identically on disk — its own app.db, file-blobs/, log.db —
    /// and picks up the `platform` capability pointer so the admin
    /// JS handler can call platform operations via the `platform.*`
    /// globals.
    /// Caller-locks variant: requires `maps_mutex` to be held. Returns
    /// the existing `*Instance` for `id` if any, otherwise opens its
    /// per-tenant store and installs it into `instances`. The check-
    /// then-insert is atomic under the lock so racing callers don't
    /// open the same instance twice.
    fn ensureOpenLocked(self: *Tenant, id: []const u8) Error!*Instance {
        return self.ensureOpenLockedWith(id, null);
    }

    /// `ensureOpenLocked`, with the incarnation supplied rather than read back
    /// from the marker. `null` = read the marker (every path except the first
    /// creation, where the marker is written only after a successful open).
    fn ensureOpenLockedWith(self: *Tenant, id: []const u8, supplied: ?Incarnation) Error!*Instance {
        if (self.instances.get(id)) |inst| return inst;

        // The instance's storage key is (id, incarnation), not id alone — so
        // the next tenant to hold this name addresses a different store and a
        // different directory, and cannot reach the previous one's data even
        // if its objects were never cleaned up. Unlike `storageOf` (a query),
        // an absent marker here means this open IS the instance's creation:
        // an id nothing has provisioned an incarnation for opens legacy,
        // which is `createInstance`'s (and the pump's first-sight) contract.
        const incarnation: Incarnation = if (supplied) |inc|
            inc.dupe(self.allocator) catch return Error.OutOfMemory
        else blk: {
            const st = self.storageOf(self.allocator, id) catch |err| switch (err) {
                Error.InstanceNotFound => break :blk .legacy,
                else => return err,
            };
            break :blk st.incarnation;
        };
        errdefer incarnation.free(self.allocator);

        const storage = TenantStorage{ .id = id, .incarnation = incarnation };
        const inst_dir = storage.dirPath(self.allocator, self.dir) catch
            return Error.OutOfMemory;
        errdefer self.allocator.free(inst_dir);

        std.fs.cwd().makePath(inst_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return Error.OpenFailed,
        };

        // Per-instance state lives as a store inside the same manifest
        // as `self.root` — the
        // cluster's `cluster.kv` in production, the test's
        // standalone manifest in unit-test fixtures. `inst_dir`
        // remains on disk for sibling artifacts (file-blobs etc.)
        // but no per-instance `app.db` file is created.
        const counter_opt: ?*kv_mod.SeqCounter = blk: {
            const reg = self.seq_counters orelse break :blk null;
            break :blk reg.getOrCreate(id) catch return Error.OutOfMemory;
        };
        // Same rule for the sibling store id: the per-instance KV lives inside
        // the shared manifest keyed by this hash, so hashing the name alone is
        // exactly what let a reborn tenant read its predecessor's rows.
        const u64_id = storage.storeId();
        const store = kv_mod.KvStore.attachSibling(
            self.allocator,
            self.root,
            u64_id,
            counter_opt,
        ) catch return Error.OpenFailed;
        errdefer store.close();

        const id_copy = self.allocator.dupe(u8, id) catch return Error.OutOfMemory;
        errdefer self.allocator.free(id_copy);

        const inst = self.allocator.create(Instance) catch return Error.OutOfMemory;
        errdefer self.allocator.destroy(inst);

        inst.* = .{
            .id = id_copy,
            .dir = inst_dir,
            .kv = store,
            // `incarnation`'s token bytes were duped above and are owned by
            // this instance from here (freed in destroy/deleteInstance).
            .storage = .{ .id = id_copy, .incarnation = incarnation },
            // The singleton admin tenant gets a back-pointer to the
            // Tenant so its JS handler can issue platform ops. Every
            // other instance leaves `platform = null`.
            .platform = if (std.mem.eql(u8, id, ADMIN_INSTANCE_ID)) self else null,
        };

        self.instances.put(self.allocator, id_copy, inst) catch return Error.OutOfMemory;
        // Which store a node opened for a tenant is the first thing you need
        // when a write "replicates" but reads come back empty: two nodes on
        // different incarnations of the same name each look internally
        // consistent, and only this line shows they disagree (#357).
        std.log.info("tenant: opened {s} incarnation='{s}' store_id={x} dir={s}", .{ id, incarnation.marker(), u64_id, inst_dir });
        return inst;
    }

    fn invalidateHostCache(self: *Tenant) void {
        self.maps_mutex.lock();
        defer self.maps_mutex.unlock();
        var it = self.host_cache.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.host_cache.clearRetainingCapacity();
    }

    // ── Auth ──────────────────────────────────────────────────────────
    //
    // The root bearer token is operator-supplied via the
    // `LOOP46_ROOT_TOKEN` env var, read at worker startup, and stored
    // on the Tenant as `root_token_secret`. Presenting the matching
    // plaintext authenticates as platform operator. Admin sessions +
    // magic links live in `__admin__`'s app.db (see the session +
    // magic sections below).
    //
    // No SQLite write at startup, no per-node `__root__.db` row to
    // get out of sync across the cluster — every node reads the same
    // env value. Rotating the token = restart the workers with a new
    // env value. Comparison is constant-time so a leaked timing
    // signal doesn't help an attacker brute-force the token byte-by-
    // byte.

    /// Authenticate a plaintext token against `root_token_secret`.
    /// Returns `null` if the token is malformed, doesn't match, or
    /// no root token is configured. Returns `AuthContext{is_root:
    /// true}` on a constant-time match.
    pub fn authenticate(self: *Tenant, token_hex: []const u8) Error!?AuthContext {
        const secret = self.root_token_secret orelse return null;
        if (token_hex.len != secret.len) return null;
        if (validateTokenShape(token_hex)) |_| {} else |_| return null;
        // std.crypto.timing_safe.eql wants compile-time-known size.
        // Tokens are at most a few hundred bytes; do a manual
        // constant-time XOR-accumulate to avoid the size constraint.
        var diff: u8 = 0;
        for (token_hex, secret) |a, b| diff |= a ^ b;
        return if (diff == 0) .{ .is_root = true } else null;
    }

    // ── adminKv: storage handle for admin-surface state ──────────────
    //
    // Sessions and magic-link rows live in the singleton admin tenant's
    // own app.db, not the root store. Callers reach them via this
    // helper rather than hard-coding `instances.get(ADMIN_INSTANCE_ID)`.
    // Requires `__admin__` to be registered first — callers are
    // expected to `createInstance(ADMIN_INSTANCE_ID)` during bootstrap
    // before any session / magic operation fires.
    fn adminKv(self: *Tenant) Error!*kv_mod.KvStore {
        self.maps_mutex.lock();
        defer self.maps_mutex.unlock();
        const inst = self.instances.get(ADMIN_INSTANCE_ID) orelse
            return Error.InstanceNotFound;
        return inst.kv;
    }

    // ── Session cookies ───────────────────────────────────────────────
    //
    // A session is an opaque 64-hex token handed to the browser via
    // `Set-Cookie` after a successful login. Stored in the admin
    // tenant's app.db under `session/{sha256(opaque)}` — the store
    // only retains the hash, so a leaked app.db can't impersonate
    // live sessions. Value =
    // `{"expires_at_ns":<i64>,"is_root":<bool>}` (JSON, so admin's
    // JS handler can parse via `kv.get` + `JSON.parse`).
    //
    // Mint + revoke live in admin's deployed JS bundle; only
    // `authenticateSession` is in Zig
    // because `extractAdminAuth` (used by /_system/* + the admin
    // host's RPC auth gate) validates cookies before
    // dispatching to JS.

    pub const SESSION_HEX_LEN: usize = 64;

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
        const kv = try self.adminKv();

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(opaque_hex, &hash, .{});
        var hash_hex: [SESSION_HEX_LEN]u8 = undefined;
        bytesToHex(&hash, &hash_hex);

        var key_buf: [8 + SESSION_HEX_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "session/{s}", .{hash_hex}) catch
            return Error.Kv;

        const v = kv.get(key) catch |err| switch (err) {
            error.NotFound => return null,
            else => return Error.Kv,
        };
        defer self.allocator.free(v);

        const SessionRow = struct {
            expires_at_ns: i64,
            is_root: bool,
        };
        const parsed = std.json.parseFromSlice(SessionRow, self.allocator, v, .{
            .allocate = .alloc_always,
        }) catch {
            // Corrupted row — drop it and treat as a miss. Better
            // than leaking parser state up through an auth path.
            kv.delete(key) catch {};
            return null;
        };
        defer parsed.deinit();

        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        if (now_ns >= parsed.value.expires_at_ns) {
            // Drop the stale record opportunistically.
            kv.delete(key) catch {};
            return null;
        }
        return .{ .is_root = parsed.value.is_root };
    }

    /// Check whether the given auth context is allowed to operate on
    /// `instance_id`. In the single-account shape the root token
    /// grants access to every instance, so this reduces to
    /// `ctx.is_root`. A multi-account model would consult
    /// `account_member/{account_id}/{user_id}` markers here.
    pub fn canAccessInstance(
        self: *Tenant,
        ctx: AuthContext,
        instance_id: []const u8,
    ) Error!bool {
        _ = self;
        _ = instance_id;
        return ctx.is_root;
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

/// Validate a tenant/instance id against the shared spec
/// (`rove-instance-id`). The rule is one definition because the control plane
/// enforces it at provisioning time and the reject reason has to reach the
/// customer; here we only need the yes/no.
fn validateInstanceId(id: []const u8) Error!void {
    if (id_spec.check(id) != null) return Error.InvalidInstanceId;
}

fn validateHost(host: []const u8) Error!void {
    if (host.len == 0 or host.len > MAX_HOST_LEN) return Error.InvalidHost;
    for (host) |b| {
        if (b < 0x21 or b > 0x7e) return Error.InvalidHost;
        if (b == '/' or b == '\\') return Error.InvalidHost;
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const TestFixture = struct {
    allocator: std.mem.Allocator,
    tmp_dir: []u8,
    root: *kv_mod.KvStore,
    tenant: *Tenant,

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

        const tenant = try Tenant.create(allocator, root, tmp_dir);
        errdefer tenant.destroy();
        // Register the singleton admin tenant — sessions and magic
        // links live in its app.db, so most tests implicitly depend
        // on it existing. Tests that need the "admin not registered"
        // path can delete it before asserting.
        try tenant.createInstance(ADMIN_INSTANCE_ID);
        return .{ .allocator = allocator, .tmp_dir = tmp_dir, .root = root, .tenant = tenant };
    }

    fn deinit(self: *TestFixture) void {
        self.tenant.destroy();
        self.root.close();
        std.fs.cwd().deleteTree(self.tmp_dir) catch {};
        self.allocator.free(self.tmp_dir);
    }
};

test {
    // Pull storage.zig's tests into this module's test build — an import
    // for declarations alone does not (test_reachability_lint.py).
    _ = storage_mod;
}

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
        const tenant = try Tenant.create(allocator, root, tmp_dir);
        defer tenant.destroy();

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
        const tenant = try Tenant.create(allocator, root, tmp_dir);
        defer tenant.destroy();

        const inst = (try tenant.resolveDomain("acme.test")).?;
        const got = try inst.kv.get("persisted");
        defer allocator.free(got);
        try testing.expectEqualStrings("yes", got);
    }
}

test "instance storage is keyed by (id, incarnation), not id alone" {
    const a = testing.allocator;
    var fx = try TestFixture.init(a);
    defer fx.deinit();

    // Two lifetimes of ONE name. The second must not be able to reach the
    // first's rows — the deprovision leak (#357).
    try fx.tenant.createInstanceWithIncarnation("acme", .{ .token = "aaaa1111" });
    const first = (try fx.tenant.getInstance("acme")).?;
    const first_store = first.storage.storeId();
    try first.kv.put("secret", "first-tenant-data");

    try fx.tenant.deleteInstance("acme");
    try fx.tenant.createInstanceWithIncarnation("acme", .{ .token = "bbbb2222" });
    const second = (try fx.tenant.getInstance("acme")).?;

    try testing.expect(first_store != second.storage.storeId());
    try testing.expectEqualStrings("bbbb2222", second.storage.incarnation.marker());
    try testing.expectError(error.NotFound, second.kv.get("secret"));
}

test "an existing instance keeps the incarnation its data is keyed by" {
    const a = testing.allocator;
    var fx = try TestFixture.init(a);
    defer fx.deinit();

    try fx.tenant.createInstanceWithIncarnation("acme", .{ .token = "aaaa1111" });
    const inst = (try fx.tenant.getInstance("acme")).?;
    try inst.kv.put("k", "v");

    // A re-attach carrying a DIFFERENT incarnation must not re-key a live
    // tenant — that would orphan its data rather than protect it.
    try fx.tenant.createInstanceWithIncarnation("acme", .{ .token = "cccc3333" });
    const again = (try fx.tenant.getInstance("acme")).?;
    try testing.expectEqualStrings("aaaa1111", again.storage.incarnation.marker());
    const v = try again.kv.get("k");
    defer a.free(v);
    try testing.expectEqualStrings("v", v);
}

test "a legacy instance (no incarnation) keeps its name-keyed storage" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    // Instances created before incarnations existed must stay exactly where
    // their data is — this is what makes the change need no migration.
    try fx.tenant.createInstance("legacy");
    const inst = (try fx.tenant.getInstance("legacy")).?;
    try testing.expect(inst.storage.incarnation == .legacy);
    try testing.expectEqual(kv_mod.hashStoreId("legacy"), inst.storage.storeId());
}

test "storageOf: absent marker is InstanceNotFound, never legacy" {
    const a = testing.allocator;
    var fx = try TestFixture.init(a);
    defer fx.deinit();

    // "No such instance" and "legacy instance" must be distinguishable —
    // collapsing them is what made a missed incarnation hand-off a quiet
    // read of the wrong tenant lifetime instead of a loud failure (#357).
    try testing.expectError(Error.InstanceNotFound, fx.tenant.storageOf(a, "ghost"));

    try fx.tenant.createInstance("oldster");
    const legacy_st = try fx.tenant.storageOf(a, "oldster");
    defer legacy_st.incarnation.free(a);
    try testing.expect(legacy_st.incarnation == .legacy);

    try fx.tenant.createInstanceWithIncarnation("fresh", .{ .token = "dddd4444" });
    const st = try fx.tenant.storageOf(a, "fresh");
    defer st.incarnation.free(a);
    try testing.expectEqualStrings("dddd4444", st.incarnation.marker());
}

test "validateInstanceId enforces DNS-label-safe spec" {
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId(""));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("has space"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("with/slash"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("../evil"));
    // Pre-customer tightening (§7.4): no uppercase, no underscore, no
    // leading/trailing hyphen, ≤63 octets.
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("ACME"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("acme_v2"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("-acme"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("acme-"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("-"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("a" ** 64));
    // Customers cannot squat the reserved `__…__` form.
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("__evil__"));
    // Reserved subdomain labels (§7.7): a customer can't become `auth.<zone>`.
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("auth"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("api"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("app"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("admin"));
    try testing.expectError(Error.InvalidInstanceId, validateInstanceId("www"));

    // Valid customer ids (incl. ones that merely contain a reserved label).
    try validateInstanceId("a");
    try validateInstanceId("acme");
    try validateInstanceId("acme-123");
    try validateInstanceId("my-api");
    try validateInstanceId("admintest");
    try validateInstanceId("apixzy");
    try validateInstanceId("a" ** 63);
    // Platform-reserved tenants are exempt from the DNS spec.
    try validateInstanceId("__admin__");
    try validateInstanceId("__auth__");
    try validateInstanceId("__replay__");
}

test "authenticate matches root_token_secret" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const token = "a" ** 64;
    fx.tenant.root_token_secret = token;

    const ctx = try fx.tenant.authenticate(token);
    try testing.expect(ctx != null);
    try testing.expect(ctx.?.is_root);
}

test "authenticate rejects unknown tokens" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    fx.tenant.root_token_secret = "a" ** 64;
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

test "authenticate returns null when no root_token_secret is set" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    // Default — root_token_secret is null.
    try testing.expectEqual(
        @as(?AuthContext, null),
        try fx.tenant.authenticate("a" ** 64),
    );
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

test "__admin__ tenant is an instance like any other, with platform capability" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    // TestFixture already calls createInstance(ADMIN_INSTANCE_ID).
    const admin = (try fx.tenant.getInstance(ADMIN_INSTANCE_ID)).?;

    // Admin has its OWN app.db — not aliased to root.
    try testing.expect(admin.kv != fx.root);

    // The singleton gets a back-pointer to the Tenant; regular
    // instances do not.
    try testing.expect(admin.platform != null);
    try testing.expectEqual(fx.tenant, admin.platform.?);

    try fx.tenant.createInstance("acme");
    const acme = (try fx.tenant.getInstance("acme")).?;
    try testing.expect(acme.platform == null);

    // A write through admin.kv goes to admin's app.db, NOT root.
    try admin.kv.put("mykey", "myvalue");
    try testing.expectError(error.NotFound, fx.root.get("mykey"));
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
        const tenant = try Tenant.create(allocator, root, tmp_dir);
        defer tenant.destroy();
        try tenant.createInstance("persistent");
        const inst = (try tenant.getInstance("persistent")).?;
        try inst.kv.put("hello", "world");
    }
    // Session 2: nothing in memory yet; getInstance lazy-opens.
    {
        const root = try kv_mod.KvStore.open(allocator, root_path);
        defer root.close();
        const tenant = try Tenant.create(allocator, root, tmp_dir);
        defer tenant.destroy();
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
    // The fixture auto-registers `__admin__`; it sorts FIRST under
    // ASCII lex order (double-underscore is 0x5f, before 'a' = 0x61).
    try testing.expectEqual(@as(usize, 4), list.ids.len);
    try testing.expectEqualStrings(ADMIN_INSTANCE_ID, list.ids[0]);
    try testing.expectEqualStrings("alpha", list.ids[1]);
    try testing.expectEqualStrings("beta", list.ids[2]);
    try testing.expectEqualStrings("gamma", list.ids[3]);
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

// Helper: write a session row in the JSON-on-disk shape that admin's
// JS handler produces. Mirrors the format documented above
// `authenticateSession` so the Zig-side reader is exercised against
// the same bytes a JS handler would emit.
fn putSessionRow(
    tenant: *Tenant,
    opaque_hex: []const u8,
    expires_at_ns: i64,
    is_root: bool,
) !void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(opaque_hex, &hash, .{});
    var hash_hex: [Tenant.SESSION_HEX_LEN]u8 = undefined;
    bytesToHex(&hash, &hash_hex);
    var key_buf: [8 + Tenant.SESSION_HEX_LEN]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "session/{s}", .{hash_hex});
    var val_buf: [96]u8 = undefined;
    const json = try std.fmt.bufPrint(&val_buf, "{{\"expires_at_ns\":{d},\"is_root\":{s}}}", .{
        expires_at_ns,
        if (is_root) "true" else "false",
    });
    const kv = try tenant.adminKv();
    try kv.put(key, json);
}

test "authenticateSession reads JSON-shape session row produced by admin's JS" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const opaque_hex = "a" ** 64;
    const future_ns: i64 = @intCast(std.time.nanoTimestamp() + std.time.ns_per_s * 60);
    try putSessionRow(fx.tenant, opaque_hex, future_ns, true);

    const resolved = try fx.tenant.authenticateSession(opaque_hex);
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

test "expired session is rejected and swept on access" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const opaque_hex = "b" ** 64;
    try putSessionRow(fx.tenant, opaque_hex, -1, true); // negative-ns timestamp = already expired

    try testing.expectEqual(@as(?AuthContext, null), try fx.tenant.authenticateSession(opaque_hex));
    // Second lookup also null — the first call swept the row.
    try testing.expectEqual(@as(?AuthContext, null), try fx.tenant.authenticateSession(opaque_hex));
}

test "authenticateSession returns is_root=false for non-root sessions" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const opaque_hex = "c" ** 64;
    const future_ns: i64 = @intCast(std.time.nanoTimestamp() + std.time.ns_per_s * 60);
    try putSessionRow(fx.tenant, opaque_hex, future_ns, false);

    const resolved = try fx.tenant.authenticateSession(opaque_hex);
    try testing.expect(resolved != null);
    try testing.expect(!resolved.?.is_root);
}

// Note: resend_key + platform_email_from are plain kv pairs that
// admin's JS reads via `kv.get`; bootstrap writes them via the generic
// `--bootstrap-kv key=value` flag. There is no Zig-side shim and no
// Zig-side knowledge of which keys exist.

// Note: mintMagic + redeemMagic + their tests live in admin's
// deployed JS bundle, not here. Coverage lives in
// scripts/signup_smoke.sh, which exercises the full mint → email
// outbox → click → redeem path against a live worker.
