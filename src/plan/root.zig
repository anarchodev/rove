// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rove-plan — per-tenant plan tiers + effective limits (docs/architecture/control-plane.md).
//!
//! A LEAF module (std + `rove-instance-id`, itself std-only) so every
//! consumer can import it without a cycle:
//! the worker (`rove-js`) resolves rate/body limits from it, and the
//! log-query surface (`rove-log-server`) resolves the retention window from it
//! (docs/architecture/control-plane.md Lever 3). It owns `RateLimitCaps` too — the limiter
//! re-exports it — so the table that maps a tier to its numbers lives in ONE
//! place reachable from both layers.
//!
//! A tenant's plan is `{tier, overrides}`: a named tier (the comptime table
//! baked here) plus optional per-field overrides for enterprise custom deals.
//! The CP stores the `{tier, overrides}` JSON blob verbatim and replicates it
//! (operational state — docs/architecture/control-plane.md); each consumer parses it into the
//! resolved limits it cares about — the worker caches `PlanLimits` on the
//! tenant's hot-path slot; the log-server reads `retention_days` per query.
//!
//! `rove` only ENFORCES tiers — setting one (Stripe → admin app → CP write)
//! is the product layer's job (docs/strategy/platform-accounts-model.md). This module
//! never knows what a dollar is; it only maps a tier name to numbers.
//!
//! ## The resolution rule
//!
//! `effective(tier, overrides)` folds `override ?? table(tier).field` per
//! field. Resolving at read-time (not set-time) means changing what "pro"
//! means is a one-line table edit, never a per-customer migration.

const std = @import("std");
const id_spec = @import("rove-instance-id");

/// Per-(instance, action) token-bucket caps. Lives here (not in the limiter)
/// so `rove-plan` stays a leaf the limiter can depend on; the limiter
/// re-exports it as `limiter.RateLimitCaps` for its existing callers.
pub const RateLimitCaps = struct {
    /// Burst cap: max requests accepted in a single instant from one instance.
    request_capacity: u32 = 1000,
    /// Sustained rate: requests per second the bucket refills at.
    request_refill_per_sec: u32 = 500,
    /// Burst cap on customer-initiated OUTBOUND calls from a handler —
    /// `on.fetch`, `http.fetch`, and the immediate fire of `webhook.send`
    /// / `email.send` (which composes over it). The platform's egress /
    /// third-party-bill guard, enforced at the frozen fetch primitive
    /// (`bindings/http.zig`) so a tenant-pinnable email/webhook package
    /// can't bypass it. Deferred fires — scheduled sends, retries, anything
    /// a baked `__system/*` module issues — count too: being
    /// platform-issued is not evidence the send was admitted.
    /// Burst cap on NEW identities named by `request.shredKey` — the
    /// footgun bound.
    ///
    /// A new identity mints a key, and slots are never reused, so this is
    /// a PERMANENT commitment no later cleanup reclaims: it inflates the
    /// keyring, the pool and the KMS together, and the KMS is the one
    /// component with no backups. Destroys are free by comparison and are
    /// not capped here.
    ///
    /// The realistic failure is a mistake rather than abuse — a handler
    /// passing a request id or a per-call UUID as the shred key. That is
    /// always wrong (a key used once can never be usefully shredded) and
    /// it turns every request into a permanent key.
    ///
    /// Sized for the real shape: identities are PEOPLE or accounts, so
    /// they arrive at signup rate, not request rate. A burst of 60 with
    /// one per minute sustained absorbs an import while making a
    /// per-request UUID hit the wall almost immediately.
    new_identity_capacity: u32 = 60,
    new_identity_refill_per_sec: u32 = 1,
    outbound_capacity: u32 = 100,
    /// 10/sec → 600/min sustained — well under any sane provider quota.
    outbound_refill_per_sec: u32 = 10,
    /// Whether this tenant may reach a third party AT ALL.
    ///
    /// The buckets below shape a rate; this decides admission. It is the
    /// abuse floor: outbound is what makes a tenant that cost an email
    /// address to create useful as a spam relay or a credential-stuffing
    /// client, and a tenant that cannot egress is worthless for both no
    /// matter how patient the operator is. A ceiling only bounds the rate
    /// of abuse; this removes the capability.
    ///
    /// Off is a REFUSAL, not a throttle — a disabled tenant gets a distinct
    /// error code and no Retry-After, because no amount of waiting changes
    /// the answer (`bindings/http.zig`'s `outboundRateOk`).
    ///
    /// Platform-internal doors (`*.internal` — storage, control plane, the
    /// log surface) are not third-party egress and are unaffected: a tenant
    /// with outbound off keeps `kv.*`, `blob.*`, statics and packages.
    /// What stops is `http.send` / `webhook.send` / `email.send` and any
    /// federated-login flow that acts as an OAuth/OIDC relying party.
    outbound_enabled: bool = true,
    /// Day-scale ceiling on outbound calls — the SPAM bound, and a
    /// different question from the burst caps above.
    ///
    /// The burst bucket is tuned for absorbing spikes, which makes its
    /// sustained rate the wrong shape for abuse: 10/s held for a day is
    /// ~864k calls from a tenant that cost an email address to create.
    /// The legitimate uses are all low-volume — an OAuth token exchange is
    /// a handful of calls per login, a webhook callback is one per event,
    /// a transactional email one per user action — so a low daily ceiling
    /// costs real use essentially nothing.
    ///
    /// This bounds a tenant that MAY egress; `outbound_enabled` decides
    /// whether it may at all. Both exist because they answer different
    /// questions: a tier that grants outbound still needs a daily bound,
    /// and a tier that withholds it is not expressible as a number. A tier
    /// wanting the middle ground — enough for federated login, worthless
    /// for bulk — sets `outbound_enabled` with a low ceiling here rather
    /// than a new mechanism.
    ///
    /// 0 falls back to the rate-derived estimate in
    /// `limiter.sustainedOutboundBudget`.
    outbound_sustained_per_day: u32 = 5_000,
    /// Log-byte ingest caps — the ingest-rate guardrail
    /// (docs/strategy/pricing-model.md): a lagging post-exec bucket in RAW
    /// bytes charged at log capture, with the NEXT admission 429ing while
    /// the balance is negative. The burst must sit above the largest
    /// single request body any tier accepts (one lawful request must never
    /// overdraw the meter); the refill is the sustained S3-growth bound
    /// (64 KiB/s ≈ 5.3 GiB/day). Plan-resolved like every other rate cap
    /// so a high-traffic tenant (or a stress smoke) raises it by
    /// override instead of the guard being a hidden wall.
    log_burst_bytes: u32 = 256 * 1024 * 1024,
    log_refill_bytes_per_sec: u32 = 64 * 1024,
};

/// The named tiers. A tenant with no CP plan blob resolves through
/// `defaultTierFor` — free for a customer, platform for a reserved id.
/// `pro` / `enterprise` numbers below are launch placeholders — the concrete
/// figures are a product call (decisions.md §10.9 — a product call), not an
/// engineering one, and live here so changing them is a one-line edit.
pub const Tier = enum(u8) {
    free,
    pro,
    enterprise,
    /// The platform's own singleton tenants — the dashboard, the identity
    /// provider, the replay arena. Not a commercial tier and never sold:
    /// what distinguishes it is that the tenants on it are US, so a
    /// customer-facing abuse limit landing on one is an outage rather than
    /// a bound. `defaultTierFor` resolves the reserved ids here.
    ///
    /// ROLLING-UPGRADE ORDER: `parse` maps an unknown tier to free, so a
    /// node running a build that predates this tier resolves a
    /// `{"tier":"platform"}` blob to FREE — the platform's own app, gated
    /// by customer limits, on one node out of three. Deploy the binary to
    /// every node BEFORE writing a blob that names a tier. The reserved-id
    /// default needs no blob and so has no such window.
    platform,

    /// Parse a tier name; unknown / absent → free (forward-compatible: a
    /// blob naming a tier this build doesn't know falls back to free rather
    /// than failing the request). Callers resolving a tenant's default
    /// should use `defaultTierFor`, which knows the reserved ids.
    pub fn parse(s: []const u8) Tier {
        if (std.mem.eql(u8, s, "pro")) return .pro;
        if (std.mem.eql(u8, s, "enterprise")) return .enterprise;
        if (std.mem.eql(u8, s, "platform")) return .platform;
        return .free;
    }
};

/// The tier a tenant gets when the CP holds no plan blob for it.
///
/// Reserved platform ids (`__admin__`, `__auth__`, `__replay__`) resolve to
/// the platform tier; everything else to free. Deriving this from the ID
/// rather than from an operator-written blob is deliberate: nothing writes a
/// plan blob at provision, so a rule that depends on an operator remembering
/// is a rule that breaks on the next genesis — and the failure is the
/// dashboard losing outbound, i.e. the login path. The set is closed against
/// customers (`instance_id.isReservedInstanceId`), so resolving a privilege
/// from a name opens nothing.
pub fn defaultTierFor(instance_id: []const u8) Tier {
    return if (id_spec.isReservedInstanceId(instance_id)) .platform else .free;
}

/// `defaultTierFor` resolved to limits — what a tenant with no plan blob is
/// enforced against.
pub fn defaultFor(instance_id: []const u8) PlanLimits {
    return table(defaultTierFor(instance_id));
}

/// The resolved limits a tenant is enforced against. Small + copyable —
/// cached by value behind an atomic pointer on the worker's slot.
pub const PlanLimits = struct {
    /// Per-(instance, action) token-bucket caps (Lever 1).
    rate: RateLimitCaps,
    /// Inbound request body ceiling — 413 above this (Lever 2).
    max_body_bytes: u32,
    /// Total raw (uncompressed) bytes of HTML documents a deployment may
    /// hold resident in worker RAM. The worker holds every HTML doc
    /// resident (gzip-compressed) so the serve path never touches blob
    /// storage; a deploy whose HTML exceeds this budget is rejected at
    /// load (Lever 2, sibling of max_body_bytes).
    max_resident_html_bytes: u32,
    /// Tape/log read-window in days — list/query clamp to the last N days
    /// (Lever 3; a read-path clamp, not GC).
    retention_days: u32,
    /// Ceiling on a tenant's durable KV bytes — the plan-derived form of the
    /// LMDB map size each tenant's `app.db` is opened at. KV is deliberate
    /// customer data, so the ceiling REFUSES the write; it never evicts, and
    /// it never bills elastically past the tier.
    max_kv_bytes: u64,
    /// Ceiling on a tenant's stored object bytes — the customer-written
    /// `app-blobs/` plus the deploy-written `file-blobs/`. Deliberate customer
    /// data, so the same rule as `max_kv_bytes`: refuse, never evict. Distinct
    /// from the `log-blobs/` pool, which is platform exhaust the customer never
    /// chose to write and where FIFO eviction at the ceiling is the fair
    /// answer.
    max_stored_bytes: u64,
    /// Ceiling on ONE `blob.receive` — the largest single object a tenant can
    /// create by streaming a request body straight into storage. A sibling of
    /// `max_body_bytes` rather than of `max_stored_bytes`: it bounds one
    /// write, not an accumulation. The inbound-body gate cannot serve here
    /// because that 413 sits below route resolution, so a module on the
    /// streaming path takes any-size bodies by design.
    ///
    /// A per-write ceiling is what makes the storage quota's overshoot
    /// bounded: without one, a single request can store past the quota by an
    /// unbounded amount instead of by one object.
    max_receive_bytes: u64,
};

/// `max_stored_bytes` for a tier whose storage figure is not yet a product
/// decision — arithmetically "no ceiling", so an ordinary `>` comparison at a
/// write path needs no sentinel special-case.
pub const UNMETERED_BYTES: u64 = std.math.maxInt(u64);

/// The engine posture behind `max_kv_bytes` — background for the per-tier
/// figures below (decided 2026-08-16, rove#314; the product framing is
/// `docs/strategy/billing-policy.md`, "The launch tiers").
///
/// What the engine constrains is a per-NODE total, not a per-tenant file:
/// every tenant's KV is a sibling store inside the one node-wide `cluster.kv`
/// env (`src/tenant/root.zig` attaches it; there is no per-instance `app.db`
/// in production). That total is deliberately OVER-SUBSCRIBED — the map is
/// sparse address space, so sizing it to `tenants × cap` would reserve for a
/// simultaneous worst case that never arrives, and would cap the tenant count
/// far below what the hardware carries. Three things make that safe, and they
/// are the reason this cap exists at all: a single tenant's growth is bounded
/// and attributable (it meets its own 507, never the node's cliff), real usage
/// is metered per tenant (`kv_store_used_bytes`), and a node approaching its
/// drive sheds tenants with the zero-downtime move
/// (`docs/architecture/control-plane.md`) instead of having pre-reserved for
/// them.
///
/// So selling more KV per tenant is a capacity + pricing decision, not blocked
/// engine work. `CLUSTER_MAP_SIZE` (`src/kv/kvstore.zig`) carries the one hard
/// bound: the map stays under free disk.
///
/// The per-tier figures are sized as RUNWAY over realistic transactional
/// state, never as a storage headline: kv is OLTP (1 MiB value cap, 256 B
/// keys, replicated 3x through raft — every sold GiB is three on disk), and
/// bulk data belongs on the blob axis (`max_stored_bytes`). Density math:
/// enterprise at 2 GiB means a node's 64 GiB map holds ~32 tenants even if
/// every one maxes out — advertising bigger numbers would invite the dense
/// usage the over-subscription design assumes away. Above enterprise the
/// answer is not a bigger cap on shared infrastructure: a genuine outlier
/// gets `Overrides` with a conversation, and the practical top end is a
/// DEDICATED CLUSTER at a custom price (clusters are the capacity step, and
/// the zero-downtime move makes onboarding one routine).
pub const KV_FREE: u64 = 64 * 1024 * 1024;
pub const KV_PRO: u64 = 512 * 1024 * 1024;
pub const KV_ENTERPRISE: u64 = 2 * 1024 * 1024 * 1024;
/// Platform tenants hold the account graph and the registry; a refusal here
/// is an outage, so the ceiling is generous — but finite, because the map it
/// opens against is (`CLUSTER_MAP_SIZE`), and a runaway platform app must
/// fail loud rather than quietly filling a node.
pub const KV_PLATFORM: u64 = 4 * 1024 * 1024 * 1024;

/// Customer object storage (`blob.*`) per tenant — the BULK axis, where large
/// data belongs. Enforced at the write path: refuse, never evict (#349).
pub const STORED_FREE: u64 = 1 * 1024 * 1024 * 1024;
pub const STORED_PRO: u64 = 50 * 1024 * 1024 * 1024;
pub const STORED_ENTERPRISE: u64 = 500 * 1024 * 1024 * 1024;

/// Every tier's `max_receive_bytes` until the tier figures are set. 1 GiB
/// matches what the `blob.write` / `seal` recipe path already permits for one
/// object, so both large-write paths agree on how big a single object can get.
/// Uniform across tiers deliberately: differentiating it is a product call —
/// the same call that fills in the rest of the tier table — and holding it
/// uniform preserves today's behaviour until that call is made. An enterprise
/// deal can raise it now through `Overrides.max_receive_bytes` without touching
/// this table.
pub const RECEIVE_BYTES_DEFAULT: u64 = 1024 * 1024 * 1024;

/// The baked tier table. The single source of what each named tier means.
pub fn table(t: Tier) PlanLimits {
    return switch (t) {
        .free => .{
            .rate = .{
                .request_capacity = 1000,
                .request_refill_per_sec = 500,
                // Third-party egress is a paid capability. A free tenant
                // costs an email address, so anything it can do at volume
                // is something an abuser can do for free — and outbound is
                // the one capability whose victim is someone else. Payment
                // is the identity signal that gates it; there is no
                // self-serve flip, because a signal a spammer can forge
                // for free buys one click.
                //
                // The cost is real and accepted: a free tenant cannot act
                // as an OAuth/OIDC relying party, send webhooks or send
                // email. Everything else — kv, blobs, statics, packages,
                // inbound — is untouched (`outbound_enabled`).
                //
                // Softening this is a one-line edit here, not a code
                // change: grant `outbound_enabled` and set the ceiling
                // below to what a login-shaped workload needs.
                .outbound_enabled = false,
                .outbound_capacity = 100,
                .outbound_refill_per_sec = 10,
                // Bounds a free tenant that has been granted outbound by
                // override (support/trial), rather than being dead numbers:
                // ~170x below the rate-derived 864k/day, and still ~50x a
                // small app's real outbound traffic.
                .outbound_sustained_per_day = 5_000,
            },
            // A few MB — generous-but-finite, coherent with the 256 KB
            // streaming QUEUE_BYTES_CAP (docs/architecture/control-plane.md Lever 2).
            .max_body_bytes = 4 * 1024 * 1024,
            .max_resident_html_bytes = 4 * 1024 * 1024,
            .retention_days = 7,
            .max_kv_bytes = KV_FREE,
            .max_stored_bytes = STORED_FREE,
            .max_receive_bytes = RECEIVE_BYTES_DEFAULT,
        },
        .pro => .{
            .rate = .{
                .request_capacity = 10_000,
                .request_refill_per_sec = 5_000,
                .outbound_capacity = 1_000,
                .outbound_refill_per_sec = 100,
                .outbound_sustained_per_day = 50_000,
            },
            .max_body_bytes = 32 * 1024 * 1024,
            .max_resident_html_bytes = 32 * 1024 * 1024,
            .retention_days = 30,
            .max_kv_bytes = KV_PRO,
            .max_stored_bytes = STORED_PRO,
            .max_receive_bytes = RECEIVE_BYTES_DEFAULT,
        },
        .enterprise => .{
            .rate = .{
                .request_capacity = 100_000,
                .request_refill_per_sec = 50_000,
                .outbound_capacity = 10_000,
                .outbound_refill_per_sec = 1_000,
                .outbound_sustained_per_day = 500_000,
            },
            .max_body_bytes = 256 * 1024 * 1024,
            .max_resident_html_bytes = 256 * 1024 * 1024,
            .retention_days = 365,
            .max_kv_bytes = KV_ENTERPRISE,
            .max_stored_bytes = STORED_ENTERPRISE,
            .max_receive_bytes = RECEIVE_BYTES_DEFAULT,
        },
        // The platform's own tenants. The ceilings mirror enterprise —
        // what makes this tier different is not its numbers but that a
        // refusal here is an outage, so the limits that PRICE a customer
        // are lifted while the ones that PROTECT THE NODE stay:
        // `max_kv_bytes` cannot exceed the map its store opens at, and the
        // log-ingest caps stay finite so a runaway platform app fails loud
        // instead of quietly filling a disk.
        .platform => .{
            .rate = .{
                .request_capacity = 100_000,
                .request_refill_per_sec = 50_000,
                .outbound_capacity = 10_000,
                .outbound_refill_per_sec = 1_000,
                .outbound_sustained_per_day = 500_000,
            },
            .max_body_bytes = 256 * 1024 * 1024,
            .max_resident_html_bytes = 256 * 1024 * 1024,
            .retention_days = 365,
            .max_kv_bytes = KV_PLATFORM,
            .max_stored_bytes = UNMETERED_BYTES,
            .max_receive_bytes = RECEIVE_BYTES_DEFAULT,
        },
    };
}

/// Sparse per-field overrides — every field optional. A null field falls
/// through to the tier table. Enterprise custom deals set the ones they need
/// without schema churn (decisions.md §10.9).
pub const Overrides = struct {
    request_capacity: ?u32 = null,
    request_refill_per_sec: ?u32 = null,
    outbound_enabled: ?bool = null,
    outbound_capacity: ?u32 = null,
    outbound_refill_per_sec: ?u32 = null,
    outbound_sustained_per_day: ?u32 = null,
    log_burst_bytes: ?u32 = null,
    log_refill_bytes_per_sec: ?u32 = null,
    max_body_bytes: ?u32 = null,
    max_resident_html_bytes: ?u32 = null,
    retention_days: ?u32 = null,
    max_kv_bytes: ?u64 = null,
    max_stored_bytes: ?u64 = null,
    max_receive_bytes: ?u64 = null,
};

/// Fold overrides over the tier table: `override ?? table(tier).field`.
pub fn effective(tier: Tier, ov: Overrides) PlanLimits {
    var p = table(tier);
    if (ov.request_capacity) |v| p.rate.request_capacity = v;
    if (ov.request_refill_per_sec) |v| p.rate.request_refill_per_sec = v;
    if (ov.outbound_enabled) |v| p.rate.outbound_enabled = v;
    if (ov.outbound_capacity) |v| p.rate.outbound_capacity = v;
    if (ov.outbound_refill_per_sec) |v| p.rate.outbound_refill_per_sec = v;
    if (ov.outbound_sustained_per_day) |v| p.rate.outbound_sustained_per_day = v;
    if (ov.log_burst_bytes) |v| p.rate.log_burst_bytes = v;
    if (ov.log_refill_bytes_per_sec) |v| p.rate.log_refill_bytes_per_sec = v;
    if (ov.max_body_bytes) |v| p.max_body_bytes = v;
    if (ov.max_resident_html_bytes) |v| p.max_resident_html_bytes = v;
    if (ov.retention_days) |v| p.retention_days = v;
    if (ov.max_kv_bytes) |v| p.max_kv_bytes = v;
    if (ov.max_stored_bytes) |v| p.max_stored_bytes = v;
    if (ov.max_receive_bytes) |v| p.max_receive_bytes = v;
    return p;
}

/// Parse a CP plan blob (`{"tier":"pro","overrides":{…}}`) into resolved
/// limits for `instance_id`. An empty blob or malformed JSON resolves to that
/// tenant's DEFAULT (`defaultFor`) — the blob is operator/admin-authored, but
/// a consumer must never fail a request on a bad plan record. For a customer
/// that means failing toward the free tier, never toward unbounded; for a
/// reserved platform id it means failing toward the platform tier, because
/// there the conservative direction is the one that keeps our own dashboard
/// serving. A customer cannot hold a reserved id, so the two rules never meet.
/// `overrides` is optional and sparse.
pub fn parseBlob(allocator: std.mem.Allocator, instance_id: []const u8, blob: []const u8) PlanLimits {
    const trimmed = std.mem.trim(u8, blob, " \t\r\n");
    if (trimmed.len == 0) return defaultFor(instance_id);
    const Doc = struct {
        tier: ?[]const u8 = null,
        overrides: Overrides = .{},
    };
    var parsed = std.json.parseFromSlice(Doc, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
        std.log.warn(
            "plan: unparseable plan blob for {s} ({d} bytes) — defaulting to {s}",
            .{ instance_id, trimmed.len, @tagName(defaultTierFor(instance_id)) },
        );
        return defaultFor(instance_id);
    };
    defer parsed.deinit();
    // A blob that names no tier states only overrides; it must not silently
    // demote a platform singleton to free.
    const tier = if (parsed.value.tier) |t| Tier.parse(t) else defaultTierFor(instance_id);
    return effective(tier, parsed.value.overrides);
}

/// Seconds of retention for a resolved plan — the read-clamp floor is
/// `now_ns - retentionNs(plan)` (docs/architecture/control-plane.md Lever 3).
pub fn retentionNs(p: PlanLimits) i64 {
    return @as(i64, p.retention_days) * std.time.ns_per_day;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "plan: free is the default tier table" {
    const f = table(.free);
    try testing.expectEqual(@as(u32, 1000), f.rate.request_capacity);
    try testing.expectEqual(@as(u32, 7), f.retention_days);
}

test "plan: tiers escalate the numbers" {
    try testing.expect(table(.pro).max_body_bytes > table(.free).max_body_bytes);
    try testing.expect(table(.enterprise).rate.request_refill_per_sec > table(.pro).rate.request_refill_per_sec);
    try testing.expect(table(.enterprise).retention_days > table(.pro).retention_days);
}

test "plan: effective folds sparse overrides over the table" {
    const p = effective(.pro, .{ .max_body_bytes = 999, .request_capacity = 7 });
    try testing.expectEqual(@as(u32, 999), p.max_body_bytes); // overridden
    try testing.expectEqual(@as(u32, 7), p.rate.request_capacity); // overridden
    // Unset fields fall through to the pro table.
    try testing.expectEqual(table(.pro).retention_days, p.retention_days);
    try testing.expectEqual(table(.pro).rate.outbound_capacity, p.rate.outbound_capacity);
}

test "plan: Tier.parse unknown → free" {
    try testing.expectEqual(Tier.pro, Tier.parse("pro"));
    try testing.expectEqual(Tier.enterprise, Tier.parse("enterprise"));
    try testing.expectEqual(Tier.platform, Tier.parse("platform"));
    try testing.expectEqual(Tier.free, Tier.parse("free"));
    try testing.expectEqual(Tier.free, Tier.parse("platinum")); // unknown
    try testing.expectEqual(Tier.free, Tier.parse(""));
}

test "plan: outbound is a paid capability — free tier is off, paid tiers are on" {
    try testing.expect(!table(.free).rate.outbound_enabled);
    try testing.expect(table(.pro).rate.outbound_enabled);
    try testing.expect(table(.enterprise).rate.outbound_enabled);
    try testing.expect(table(.platform).rate.outbound_enabled);
    // The free tier's outbound NUMBERS stay meaningful — they bound a free
    // tenant granted outbound by override (support/trial), so an operator
    // flipping one field doesn't hand out an unbounded budget.
    try testing.expect(table(.free).rate.outbound_capacity > 0);
    try testing.expect(table(.free).rate.outbound_sustained_per_day > 0);
}

test "plan: an override is what grants a free tenant outbound" {
    const granted = effective(.free, .{ .outbound_enabled = true });
    try testing.expect(granted.rate.outbound_enabled);
    // …and it grants ONLY that: the ceilings still come from the tier.
    try testing.expectEqual(table(.free).rate.outbound_sustained_per_day, granted.rate.outbound_sustained_per_day);
    // The reverse works too — a paid tenant can be cut off without a
    // downgrade (the abuse response that isn't suspension).
    try testing.expect(!effective(.pro, .{ .outbound_enabled = false }).rate.outbound_enabled);
}

test "plan: reserved platform ids default to the platform tier, customers to free" {
    // The platform's own singletons must never run under a customer-facing
    // abuse limit — `__auth__` is an OIDC relying party, so a free-tier
    // outbound gate on it is the login path going down.
    try testing.expectEqual(Tier.platform, defaultTierFor("__admin__"));
    try testing.expectEqual(Tier.platform, defaultTierFor("__auth__"));
    try testing.expectEqual(Tier.platform, defaultTierFor("__replay__"));
    try testing.expect(defaultFor("__auth__").rate.outbound_enabled);

    // Everything else is a customer, including ids that merely look
    // platform-ish. A customer cannot hold a reserved id (the `__…__` form
    // fails the DNS-label spec), so this is not a name a tenant can claim.
    try testing.expectEqual(Tier.free, defaultTierFor("acme"));
    try testing.expectEqual(Tier.free, defaultTierFor("__admin"));
    try testing.expectEqual(Tier.free, defaultTierFor("admin"));
    try testing.expectEqual(Tier.free, defaultTierFor("__notreal__"));
    try testing.expect(!defaultFor("acme").rate.outbound_enabled);
}

test "plan: a blob resolves against the tenant it belongs to" {
    const a = testing.allocator;
    // No blob / unparseable blob → that tenant's default, which for a
    // platform singleton is platform, not free. Failing toward free here
    // would take the dashboard's outbound down on a bad record.
    try testing.expect(parseBlob(a, "__admin__", "").rate.outbound_enabled);
    try testing.expect(parseBlob(a, "__admin__", "not json").rate.outbound_enabled);
    try testing.expect(!parseBlob(a, "acme", "").rate.outbound_enabled);

    // A blob naming only overrides must not silently demote a platform
    // singleton to free.
    const ov_only = parseBlob(a, "__admin__", "{\"overrides\":{\"retention_days\":30}}");
    try testing.expectEqual(@as(u32, 30), ov_only.retention_days);
    try testing.expect(ov_only.rate.outbound_enabled);
    try testing.expectEqual(table(.platform).max_body_bytes, ov_only.max_body_bytes);

    // The grant path: an overrides-only blob turns outbound on for ONE
    // customer without naming a tier. Naming one would be the trap — it
    // pins that tenant to today's meaning of "free", so a later tier-table
    // edit silently skips them; and a typo'd tier name resolves to free
    // rather than failing, which is invisible until a limit bites.
    const grant = parseBlob(a, "acme", "{\"overrides\":{\"outbound_enabled\":true}}");
    try testing.expect(grant.rate.outbound_enabled);
    // …and the grant is ONLY that. Every other limit still comes from the
    // tier, so granting egress never quietly grants enterprise numbers.
    try testing.expectEqual(table(.free).rate.outbound_sustained_per_day, grant.rate.outbound_sustained_per_day);
    try testing.expectEqual(table(.free).max_body_bytes, grant.max_body_bytes);
    try testing.expectEqual(table(.free).retention_days, grant.retention_days);

    // An explicit tier still wins over the id-derived default — that is
    // what makes the default a default rather than a hardcode.
    try testing.expectEqual(
        table(.free).max_body_bytes,
        parseBlob(a, "__admin__", "{\"tier\":\"free\"}").max_body_bytes,
    );
    try testing.expect(parseBlob(a, "acme", "{\"tier\":\"pro\"}").rate.outbound_enabled);
}

test "plan: parseBlob round-trips tier + overrides" {
    const a = testing.allocator;
    {
        const p = parseBlob(a, "acme", "{\"tier\":\"pro\"}");
        try testing.expectEqual(table(.pro).max_body_bytes, p.max_body_bytes);
    }
    {
        const p = parseBlob(a, "acme", "{\"tier\":\"pro\",\"overrides\":{\"retention_days\":90}}");
        try testing.expectEqual(@as(u32, 90), p.retention_days);
        try testing.expectEqual(table(.pro).max_body_bytes, p.max_body_bytes);
    }
}

test "plan: every tier carries both byte ceilings, under the node map" {
    for ([_]Tier{ .free, .pro, .enterprise, .platform }) |t| {
        const p = table(t);
        // No tier may promise more KV than the node-wide env could hold for a
        // handful of maxed tenants: a single tenant's cap stays well under the
        // 64 GiB `CLUSTER_MAP_SIZE`, so density never saturates a node with a
        // couple of accounts (the rove#314 sizing argument).
        try testing.expect(p.max_kv_bytes <= 4 * 1024 * 1024 * 1024);
        try testing.expect(p.max_kv_bytes > 0);
        try testing.expect(p.max_stored_bytes > 0);
    }
}

test "plan: the sellable tiers escalate kv and stored bytes" {
    try testing.expect(table(.pro).max_kv_bytes > table(.free).max_kv_bytes);
    try testing.expect(table(.enterprise).max_kv_bytes > table(.pro).max_kv_bytes);
    try testing.expect(table(.pro).max_stored_bytes > table(.free).max_stored_bytes);
    try testing.expect(table(.enterprise).max_stored_bytes > table(.pro).max_stored_bytes);
    // The platform is not a sellable tier: its kv ceiling protects the node,
    // and its own blobs are unmetered (it is us).
    try testing.expectEqual(UNMETERED_BYTES, table(.platform).max_stored_bytes);
}

test "plan: effective folds the byte-ceiling overrides" {
    const p = effective(.enterprise, .{
        .max_kv_bytes = 512 * 1024 * 1024,
        .max_stored_bytes = 100 * 1024 * 1024 * 1024,
    });
    try testing.expectEqual(@as(u64, 512 * 1024 * 1024), p.max_kv_bytes);
    try testing.expectEqual(@as(u64, 100 * 1024 * 1024 * 1024), p.max_stored_bytes);
    // Unset fields still fall through to the enterprise table.
    try testing.expectEqual(table(.enterprise).retention_days, p.retention_days);
}

test "plan: log-ingest caps default uniformly and fold overrides" {
    for ([_]Tier{ .free, .pro, .enterprise, .platform }) |t| {
        const p = table(t);
        try testing.expectEqual(@as(u32, 256 * 1024 * 1024), p.rate.log_burst_bytes);
        try testing.expectEqual(@as(u32, 64 * 1024), p.rate.log_refill_bytes_per_sec);
    }
    const p = effective(.free, .{ .log_burst_bytes = 1024, .log_refill_bytes_per_sec = 16 });
    try testing.expectEqual(@as(u32, 1024), p.rate.log_burst_bytes);
    try testing.expectEqual(@as(u32, 16), p.rate.log_refill_bytes_per_sec);
    const a = testing.allocator;
    const blob = parseBlob(a, "acme", "{\"tier\":\"free\",\"overrides\":{\"log_burst_bytes\":2048}}");
    try testing.expectEqual(@as(u32, 2048), blob.rate.log_burst_bytes);
    try testing.expectEqual(@as(u32, 64 * 1024), blob.rate.log_refill_bytes_per_sec);
}

test "plan: parseBlob carries the byte ceilings" {
    const a = testing.allocator;
    const p = parseBlob(a, "acme", "{\"tier\":\"pro\",\"overrides\":{\"max_stored_bytes\":42}}");
    try testing.expectEqual(@as(u64, 42), p.max_stored_bytes);
    // A blob that names neither ceiling resolves to the tier's own figures.
    try testing.expectEqual(table(.pro).max_kv_bytes, p.max_kv_bytes);
    const bare = parseBlob(a, "acme", "{\"tier\":\"free\"}");
    try testing.expectEqual(table(.free).max_stored_bytes, bare.max_stored_bytes);
}

test "plan: parseBlob fails toward the free tier" {
    const a = testing.allocator;
    try testing.expectEqual(table(.free).max_body_bytes, parseBlob(a, "acme", "").max_body_bytes);
    try testing.expectEqual(table(.free).max_body_bytes, parseBlob(a, "acme", "   ").max_body_bytes);
    try testing.expectEqual(table(.free).max_body_bytes, parseBlob(a, "acme", "not json").max_body_bytes);
    try testing.expectEqual(table(.free).max_body_bytes, parseBlob(a, "acme", "{\"tier\":\"galaxy\"}").max_body_bytes);
}

test "plan: retentionNs scales days to ns" {
    try testing.expectEqual(@as(i64, 7) * std.time.ns_per_day, retentionNs(table(.free)));
    try testing.expectEqual(@as(i64, 365) * std.time.ns_per_day, retentionNs(table(.enterprise)));
}
