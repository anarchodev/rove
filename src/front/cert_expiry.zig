//! When each certificate the front is serving stops being valid.
//!
//! A certificate expiring is a total outage for every name on it, it is known
//! months ahead, and it is the one failure that no amount of health-checking
//! catches: everything reports healthy right up to the moment nothing can
//! connect. The platform's wildcard is renewed by hand — Let's Encrypt issues
//! wildcards over DNS-01 only, so the in-tree HTTP-01 issuer cannot produce one
//! — which makes a human the renewal mechanism, and a human needs telling.
//!
//! So the expiry is exported as a gauge and alerted on, rather than left for
//! someone to remember. The same gauge covers the certificates the in-tree
//! issuer manages: one question asked once.
//!
//! Written by the cert-sync thread (per-host installs) and read by the :443
//! loop (metrics), hence the mutex. Cheap either way — a handful of entries,
//! touched on a sync tick and a metrics tick.

const std = @import("std");
const expiry = @import("rove-acme").expiry;

/// The label used for the default/fallback context — the wildcard that serves
/// every connection whose SNI is absent or has no per-host entry. It is not
/// keyed by hostname because it deliberately answers for many.
pub const DEFAULT_LABEL = "<default>";

pub const CertExpiry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    /// host (or `DEFAULT_LABEL`) → notAfter, unix seconds. Keys owned.
    by_host: std.StringHashMapUnmanaged(i64) = .empty,

    pub fn init(allocator: std.mem.Allocator) CertExpiry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CertExpiry) void {
        var it = self.by_host.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.by_host.deinit(self.allocator);
    }

    /// Record `cert_pem`'s expiry under `host`. Unparseable certificates are
    /// recorded as **already expired** rather than skipped: a missing series
    /// looks identical to "no certificate configured", and a certificate we
    /// cannot read is one we cannot vouch for. Better a firing alert than a
    /// silent gap.
    pub fn observe(self: *CertExpiry, host: []const u8, cert_pem: []const u8) void {
        const not_after = expiry.notAfter(self.allocator, cert_pem) catch |err| blk: {
            std.log.warn("front: cannot read the expiry of the cert for {s}: {s}", .{ host, @errorName(err) });
            break :blk 0;
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = self.by_host.getOrPut(self.allocator, host) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, host) catch {
                _ = self.by_host.remove(host);
                return;
            };
        }
        gop.value_ptr.* = not_after;
    }

    /// Read the PEM at `path` and record it under `host`. The default context
    /// is built from files by OpenSSL, so this is how its expiry is learned.
    pub fn observeFile(self: *CertExpiry, host: []const u8, path: []const u8) void {
        const pem = std.fs.cwd().readFileAlloc(self.allocator, path, 1 << 20) catch |err| {
            std.log.warn("front: cannot read {s} to learn its expiry: {s}", .{ path, @errorName(err) });
            return;
        };
        defer self.allocator.free(pem);
        self.observe(host, pem);
    }

    /// Render the gauge. `now_s` is passed in so the remaining-seconds series
    /// is consistent with the rest of the snapshot and testable.
    pub fn writeMetrics(self: *CertExpiry, w: *std.Io.Writer, now_s: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.by_host.count() == 0) return;

        try w.writeAll(
            \\# HELP front_tls_cert_expiry_seconds unix time at which a served certificate stops being valid.
            \\# TYPE front_tls_cert_expiry_seconds gauge
            \\
        );
        var it = self.by_host.iterator();
        while (it.next()) |e| {
            try w.print("front_tls_cert_expiry_seconds{{host=\"{s}\"}} {d}\n", .{ e.key_ptr.*, e.value_ptr.* });
        }
        // The derived series exists so an alert can be written against a
        // duration without every consumer re-deriving `expiry - now`, and so a
        // dashboard reads in the unit an operator thinks in. Clamped at 0: an
        // expired certificate is not "negative time left", and a rule like
        // `< 21d` should treat every expired cert identically.
        try w.writeAll(
            \\# HELP front_tls_cert_remaining_seconds seconds until a served certificate expires (0 once expired).
            \\# TYPE front_tls_cert_remaining_seconds gauge
            \\
        );
        var it2 = self.by_host.iterator();
        while (it2.next()) |e| {
            const remaining = if (e.value_ptr.* > now_s) e.value_ptr.* - now_s else 0;
            try w.print("front_tls_cert_remaining_seconds{{host=\"{s}\"}} {d}\n", .{ e.key_ptr.*, remaining });
        }
    }
};

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const fixture = expiry.testdata.cert_pem;
const FIXTURE_NOT_AFTER = expiry.testdata.not_after;

fn render(ce: *CertExpiry, now_s: i64, buf: *std.ArrayList(u8)) ![]const u8 {
    var aw = std.Io.Writer.Allocating.fromArrayList(testing.allocator, buf);
    try ce.writeMetrics(&aw.writer, now_s);
    buf.* = aw.toArrayList();
    return buf.items;
}

test "the gauge reports a certificate's real expiry and the time left" {
    var ce = CertExpiry.init(testing.allocator);
    defer ce.deinit();
    ce.observe("wildcard.test", fixture);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const day = std.time.s_per_day;
    const out = try render(&ce, FIXTURE_NOT_AFTER - 30 * day, &buf);

    try testing.expect(std.mem.indexOf(u8, out, "front_tls_cert_expiry_seconds{host=\"wildcard.test\"} 1793204895") != null);
    try testing.expect(std.mem.indexOf(u8, out, "front_tls_cert_remaining_seconds{host=\"wildcard.test\"} 2592000") != null);
}

test "an expired certificate reads as zero remaining, not negative" {
    // The alert is `remaining < threshold`; a negative value would still fire,
    // but it would also make an expired cert sort below a healthy one on any
    // dashboard and invites a `> 0` filter that hides the worst case.
    var ce = CertExpiry.init(testing.allocator);
    defer ce.deinit();
    ce.observe("expired.test", fixture);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const out = try render(&ce, FIXTURE_NOT_AFTER + 10 * std.time.s_per_day, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "front_tls_cert_remaining_seconds{host=\"expired.test\"} 0") != null);
}

test "an unreadable certificate alerts instead of vanishing" {
    // A skipped series is indistinguishable from "no cert configured", so a
    // cert we cannot parse must still produce a firing value.
    var ce = CertExpiry.init(testing.allocator);
    defer ce.deinit();
    ce.observe("broken.test", "not a certificate");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const out = try render(&ce, 1_700_000_000, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "front_tls_cert_expiry_seconds{host=\"broken.test\"} 0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "front_tls_cert_remaining_seconds{host=\"broken.test\"} 0") != null);
}

test "a renewal replaces the entry rather than adding a second series" {
    // Cert-sync re-observes the same host on every tick; a duplicate series
    // would break the scrape (same labels twice) and double-count.
    var ce = CertExpiry.init(testing.allocator);
    defer ce.deinit();
    ce.observe("host.test", fixture);
    ce.observe("host.test", fixture);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const out = try render(&ce, FIXTURE_NOT_AFTER - std.time.s_per_day, &buf);
    var count: usize = 0;
    var idx: usize = 0;
    const needle = "front_tls_cert_expiry_seconds{host=\"host.test\"}";
    while (std.mem.indexOfPos(u8, out, idx, needle)) |at| {
        count += 1;
        idx = at + needle.len;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "no certificates observed emits nothing at all" {
    // An empty HELP/TYPE block with no samples is noise in every scrape from
    // an h2c front that terminates no TLS.
    var ce = CertExpiry.init(testing.allocator);
    defer ce.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectEqualStrings("", try render(&ce, 0, &buf));
}
