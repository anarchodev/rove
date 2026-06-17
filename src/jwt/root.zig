//! HS256 JWT helpers for the standalone services' `Authorization:
//! Bearer` gates (log-server, files-server) plus the worker's
//! `/_system/release` and `/_system/admin-kv` endpoints. Not a
//! general-purpose JWT library — fixed alg, narrow payload shape.
//!
//! Wire format is the standard JWT three-part token:
//!   `<base64url(header)>.<base64url(payload)>.<base64url(sig)>`
//!
//! Header is fixed: `{"alg":"HS256","typ":"JWT"}`.
//! Payload is `{"exp":<unix_ms>}` for the basic services-token
//! shape, or `{"exp":<unix_ms>,"tenant":"<id>"?,"caps":["<cap>",...]}`
//! when the token grants cluster-internal capabilities (e.g. `release`,
//! `admin-kv`, `logs-read`). The optional `tenant` scope confines the
//! token to one tenant: `verifyWithCapAndTenant` rejects it for any
//! other tenant, and (crucially) rejects an unscoped token outright —
//! so an "any authenticated caller" token can't read across tenants.
//!
//! The HMAC secret is shared between the worker process (which mints
//! tokens at `/_system/services-token`) and every standalone service
//! that verifies them. Operators set `LOOP46_SERVICES_JWT_SECRET`
//! (hex) on every binary.

const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const B64 = std.base64.url_safe_no_pad;

pub const Error = error{
    Malformed,
    BadSignature,
    Expired,
    MissingCap,
    UnsupportedAlg,
    InvalidCap,
    /// Mint: `tenant` contained a character outside `[a-zA-Z0-9_-]`.
    InvalidTenant,
    /// Verify: token's `tenant` claim is absent or doesn't match the
    /// tenant the verifier required. A token minted without a tenant
    /// scope NEVER satisfies a tenant-scoped verify — closes the
    /// "any authenticated caller sees any tenant" gap.
    WrongTenant,
    OutOfMemory,
};

/// Fixed JWT header bytes. Pre-encoded so mint doesn't need to
/// re-base64 it on every call.
const HEADER_B64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

/// HS256 signature is 32 bytes → 43 base64url chars (no padding).
const SIG_B64_LEN: usize = 43;

/// Capability names. Conventionally short kebab-case ASCII; mint
/// rejects anything outside `[a-zA-Z0-9_-]`. Add new caps here when a
/// new internal endpoint joins.
pub const Cap = struct {
    /// Token bearer may POST `/_system/release` to set
    /// `_deploy/current` for any tenant. Issued so the standing deploy
    /// app can ship release flips without the root bearer.
    pub const RELEASE = "release";
    /// Token bearer may POST `/_system/admin-kv` to write key/value
    /// pairs into `__admin__/app.db`. Issued to files-server for
    /// platform-config bootstrap (resend_key, platform_email_from,
    /// etc.).
    pub const ADMIN_KV = "admin-kv";
    /// Token bearer may GET `/_system/raft-snapshot/{snap_id}` to
    /// stream a follower-catchup snapshot's bytes from the leader.
    /// Minted by raft peers themselves (using the shared services
    /// JWT secret) when they receive a SNAP_OFFER frame and need to
    /// fetch the offered snapshot. Out-of-band from the consensus
    /// control plane so the bulk transfer can't starve heartbeats.
    pub const RAFT_SNAPSHOT = "raft-snapshot";
    /// Token bearer may read one tenant's request logs from the
    /// log-server. ALWAYS minted tenant-scoped (`{caps:[logs-read],
    /// tenant}`): the log-server verifies with `verifyWithCapAndTenant`,
    /// so an unscoped token can't read across tenants. Minted by the
    /// worker's fetch engine when it rewrites the privileged
    /// `rewind-logs.internal` host the `__admin__` chokepoint issues
    /// (rewind-cli-plan.md §7; step3-auth-plan.md A2/A3).
    pub const LOGS_READ = "logs-read";
};

pub const Payload = struct {
    /// Unix milliseconds. Tokens minted by the worker use a 5-minute
    /// expiry by default.
    exp_ms: i64,
};

pub const MintOptions = struct {
    exp_ms: i64,
    /// Optional capability list. Empty (default) for tokens served
    /// to the dashboard via `/_system/services-token` — those only
    /// need to prove "an authenticated session minted me," with
    /// per-tenant authorization happening on the standalone service.
    /// Internal cluster operations (release, admin-kv) carry the
    /// matching cap so the receiving worker can authorize without
    /// a separate root bearer.
    caps: []const []const u8 = &.{},
    /// Optional tenant scope. When set, the token is only valid for
    /// operations on this tenant — a verifier calling
    /// `verifyWithCapAndTenant` rejects it for any other tenant.
    /// Mint enforces `[a-zA-Z0-9_-]` (so the substring-based verify
    /// needs no JSON unescaping, same as caps). Null = unscoped (the
    /// legacy "any tenant" shape; a tenant-scoped verify rejects it).
    tenant: ?[]const u8 = null,
};

/// Mint a token. Caller frees with `allocator.free`. Output is pure
/// ASCII (base64url chars + two `.` separators). Returns
/// `Error.InvalidCap` if any element of `caps` contains a character
/// outside `[a-zA-Z0-9_-]` — the verify path's substring search
/// assumes caps don't need JSON escaping, so we enforce that at mint
/// time rather than carrying an escape pass.
pub fn mint(allocator: std.mem.Allocator, secret: []const u8, opts: MintOptions) Error![]u8 {
    for (opts.caps) |cap| {
        if (cap.len == 0) return Error.InvalidCap;
        for (cap) |b| {
            const ok = (b >= 'a' and b <= 'z') or
                (b >= 'A' and b <= 'Z') or
                (b >= '0' and b <= '9') or
                b == '-' or b == '_';
            if (!ok) return Error.InvalidCap;
        }
    }
    if (opts.tenant) |t| {
        if (t.len == 0 or t.len > 64) return Error.InvalidTenant;
        for (t) |b| {
            const ok = (b >= 'a' and b <= 'z') or
                (b >= 'A' and b <= 'Z') or
                (b >= '0' and b <= '9') or
                b == '-' or b == '_';
            if (!ok) return Error.InvalidTenant;
        }
    }

    var payload_json = std.ArrayList(u8).empty;
    defer payload_json.deinit(allocator);
    payload_json.appendSlice(allocator, "{\"exp\":") catch return Error.OutOfMemory;
    var exp_buf: [24]u8 = undefined;
    const exp_str = std.fmt.bufPrint(&exp_buf, "{d}", .{opts.exp_ms}) catch unreachable;
    payload_json.appendSlice(allocator, exp_str) catch return Error.OutOfMemory;
    if (opts.tenant) |t| {
        payload_json.appendSlice(allocator, ",\"tenant\":\"") catch return Error.OutOfMemory;
        payload_json.appendSlice(allocator, t) catch return Error.OutOfMemory;
        payload_json.append(allocator, '"') catch return Error.OutOfMemory;
    }
    if (opts.caps.len > 0) {
        payload_json.appendSlice(allocator, ",\"caps\":[") catch return Error.OutOfMemory;
        for (opts.caps, 0..) |c, i| {
            if (i > 0) payload_json.append(allocator, ',') catch return Error.OutOfMemory;
            payload_json.append(allocator, '"') catch return Error.OutOfMemory;
            payload_json.appendSlice(allocator, c) catch return Error.OutOfMemory;
            payload_json.append(allocator, '"') catch return Error.OutOfMemory;
        }
        payload_json.append(allocator, ']') catch return Error.OutOfMemory;
    }
    payload_json.append(allocator, '}') catch return Error.OutOfMemory;

    var payload_b64_buf: [256]u8 = undefined;
    const enc_len = B64.Encoder.calcSize(payload_json.items.len);
    if (enc_len > payload_b64_buf.len) return Error.OutOfMemory;
    const payload_b64 = B64.Encoder.encode(payload_b64_buf[0..enc_len], payload_json.items);

    // Signing input: `header_b64 . payload_b64`
    var signing_input = std.ArrayList(u8).empty;
    defer signing_input.deinit(allocator);
    signing_input.appendSlice(allocator, HEADER_B64) catch return Error.OutOfMemory;
    signing_input.append(allocator, '.') catch return Error.OutOfMemory;
    signing_input.appendSlice(allocator, payload_b64) catch return Error.OutOfMemory;

    var sig: [32]u8 = undefined;
    HmacSha256.create(&sig, signing_input.items, secret);
    var sig_b64_buf: [SIG_B64_LEN]u8 = undefined;
    const sig_b64 = B64.Encoder.encode(&sig_b64_buf, &sig);

    const total = signing_input.items.len + 1 + sig_b64.len;
    const out = allocator.alloc(u8, total) catch return Error.OutOfMemory;
    @memcpy(out[0..signing_input.items.len], signing_input.items);
    out[signing_input.items.len] = '.';
    @memcpy(out[signing_input.items.len + 1 ..], sig_b64);
    return out;
}

/// Verify a token's signature + expiry against `now_ms`. On success
/// returns the parsed payload. Constant-time on signature compare;
/// expiry check is timing-trivial. Does NOT check capabilities — use
/// `verifyWithCap` when a specific cap is required.
pub fn verify(secret: []const u8, token: []const u8, now_ms: i64) Error!Payload {
    _ = try verifyAndDecodePayload(secret, token, now_ms, null, null);
    // verifyAndDecodePayload does the work; reuse its result.
    return verifyOnly(secret, token, now_ms);
}

/// Verify + require a capability. Returns the payload on success.
/// `Error.MissingCap` if the token's caps list doesn't contain
/// `required`. Use this on the worker side for `/_system/release`
/// and `/_system/admin-kv`.
pub fn verifyWithCap(secret: []const u8, token: []const u8, now_ms: i64, required: []const u8) Error!Payload {
    return verifyAndDecodePayload(secret, token, now_ms, required, null);
}

/// Verify + require both a capability AND a tenant scope. Returns the
/// payload on success. `Error.MissingCap` if the cap is absent;
/// `Error.WrongTenant` if the token's `tenant` claim is absent or
/// doesn't equal `tenant`. This is the tenant-scoped gate: a token
/// minted for tenant A (or with no tenant at all) cannot act on tenant
/// B. Use it where a service must confine a caller to one tenant
/// (e.g. log query scoped to the tenant in the request path).
pub fn verifyWithCapAndTenant(
    secret: []const u8,
    token: []const u8,
    now_ms: i64,
    required: []const u8,
    tenant: []const u8,
) Error!Payload {
    return verifyAndDecodePayload(secret, token, now_ms, required, tenant);
}

/// Sign an arbitrary payload JSON. Used by callers that need a richer
/// payload shape than `{exp, caps?}` — e.g. the SSE token mint
/// (sse-plan §5.1) embeds `{v, tenant_id, sid, caps, exp}`. The caller
/// builds the JSON bytes; this routine just runs the standard
/// HEADER + payload base64 + HMAC-SHA256 dance and returns the
/// three-part token. Caller frees the result with `allocator.free`.
///
/// `payload_json` should already include an `"exp"` field — verifiers
/// (`verify`, `verifyAndCopyPayload`) reject tokens missing it.
pub fn mintWithPayload(
    allocator: std.mem.Allocator,
    secret: []const u8,
    payload_json: []const u8,
) Error![]u8 {
    var payload_b64_buf: [512]u8 = undefined;
    const enc_len = B64.Encoder.calcSize(payload_json.len);
    if (enc_len > payload_b64_buf.len) return Error.OutOfMemory;
    const payload_b64 = B64.Encoder.encode(payload_b64_buf[0..enc_len], payload_json);

    const signing_input_len = HEADER_B64.len + 1 + payload_b64.len;
    var signing_input_buf: [768]u8 = undefined;
    if (signing_input_len > signing_input_buf.len) return Error.OutOfMemory;
    @memcpy(signing_input_buf[0..HEADER_B64.len], HEADER_B64);
    signing_input_buf[HEADER_B64.len] = '.';
    @memcpy(signing_input_buf[HEADER_B64.len + 1 ..][0..payload_b64.len], payload_b64);

    var sig: [32]u8 = undefined;
    HmacSha256.create(&sig, signing_input_buf[0..signing_input_len], secret);
    var sig_b64_buf: [SIG_B64_LEN]u8 = undefined;
    const sig_b64 = B64.Encoder.encode(&sig_b64_buf, &sig);

    const total = signing_input_len + 1 + sig_b64.len;
    const out = allocator.alloc(u8, total) catch return Error.OutOfMemory;
    @memcpy(out[0..signing_input_len], signing_input_buf[0..signing_input_len]);
    out[signing_input_len] = '.';
    @memcpy(out[signing_input_len + 1 ..], sig_b64);
    return out;
}

/// Verify signature + expiry, then copy the decoded payload JSON into
/// `out_buf` and return the slice. Lets a caller read additional fields
/// (e.g. `tenant_id`, `sid` for the SSE token shape — see sse-plan §5.1)
/// without re-implementing the HMAC dance. `out_buf` must be at least
/// `MAX_PAYLOAD_BYTES` (256) so any well-formed token fits.
pub fn verifyAndCopyPayload(
    secret: []const u8,
    token: []const u8,
    now_ms: i64,
    out_buf: []u8,
) Error![]u8 {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return Error.Malformed;
    const header_b64 = token[0..first_dot];
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return Error.Malformed;
    const payload_b64 = rest[0..second_dot];
    const sig_b64 = rest[second_dot + 1 ..];

    if (!std.mem.eql(u8, header_b64, HEADER_B64)) return Error.UnsupportedAlg;
    if (sig_b64.len != SIG_B64_LEN) return Error.Malformed;

    const signing_input_len = header_b64.len + 1 + payload_b64.len;
    var signing_input_buf: [512]u8 = undefined;
    if (signing_input_len > signing_input_buf.len) return Error.Malformed;
    @memcpy(signing_input_buf[0..header_b64.len], header_b64);
    signing_input_buf[header_b64.len] = '.';
    @memcpy(signing_input_buf[header_b64.len + 1 ..][0..payload_b64.len], payload_b64);

    var expected_sig: [32]u8 = undefined;
    HmacSha256.create(&expected_sig, signing_input_buf[0..signing_input_len], secret);
    var expected_b64_buf: [SIG_B64_LEN]u8 = undefined;
    const expected_b64 = B64.Encoder.encode(&expected_b64_buf, &expected_sig);

    if (!std.crypto.timing_safe.eql([SIG_B64_LEN]u8, expected_b64[0..SIG_B64_LEN].*, sig_b64[0..SIG_B64_LEN].*))
        return Error.BadSignature;

    const payload_json_len = B64.Decoder.calcSizeForSlice(payload_b64) catch return Error.Malformed;
    if (payload_json_len > out_buf.len) return Error.Malformed;
    B64.Decoder.decode(out_buf[0..payload_json_len], payload_b64) catch
        return Error.Malformed;

    const exp_ms = parseExp(out_buf[0..payload_json_len]) orelse return Error.Malformed;
    if (now_ms >= exp_ms) return Error.Expired;
    return out_buf[0..payload_json_len];
}

/// Internal: signature + expiry check, returning the parsed payload.
/// Separate from `verify` to keep the public function's signature
/// stable (no capability check).
fn verifyOnly(secret: []const u8, token: []const u8, now_ms: i64) Error!Payload {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return Error.Malformed;
    const header_b64 = token[0..first_dot];
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return Error.Malformed;
    const payload_b64 = rest[0..second_dot];
    const sig_b64 = rest[second_dot + 1 ..];

    if (!std.mem.eql(u8, header_b64, HEADER_B64)) return Error.UnsupportedAlg;
    if (sig_b64.len != SIG_B64_LEN) return Error.Malformed;

    const signing_input_len = header_b64.len + 1 + payload_b64.len;
    var signing_input_buf: [256]u8 = undefined;
    if (signing_input_len > signing_input_buf.len) return Error.Malformed;
    @memcpy(signing_input_buf[0..header_b64.len], header_b64);
    signing_input_buf[header_b64.len] = '.';
    @memcpy(signing_input_buf[header_b64.len + 1 ..][0..payload_b64.len], payload_b64);

    var expected_sig: [32]u8 = undefined;
    HmacSha256.create(&expected_sig, signing_input_buf[0..signing_input_len], secret);
    var expected_b64_buf: [SIG_B64_LEN]u8 = undefined;
    const expected_b64 = B64.Encoder.encode(&expected_b64_buf, &expected_sig);

    if (!std.crypto.timing_safe.eql([SIG_B64_LEN]u8, expected_b64[0..SIG_B64_LEN].*, sig_b64[0..SIG_B64_LEN].*))
        return Error.BadSignature;

    var payload_json_buf: [256]u8 = undefined;
    const payload_json_len = B64.Decoder.calcSizeForSlice(payload_b64) catch return Error.Malformed;
    if (payload_json_len > payload_json_buf.len) return Error.Malformed;
    B64.Decoder.decode(payload_json_buf[0..payload_json_len], payload_b64) catch
        return Error.Malformed;

    const exp_ms = parseExp(payload_json_buf[0..payload_json_len]) orelse return Error.Malformed;
    if (now_ms >= exp_ms) return Error.Expired;
    return .{ .exp_ms = exp_ms };
}

/// Internal: signature + expiry check + optional capability check
/// in one pass (avoids re-decoding the payload). Returns the parsed
/// payload on success.
fn verifyAndDecodePayload(
    secret: []const u8,
    token: []const u8,
    now_ms: i64,
    required_cap: ?[]const u8,
    required_tenant: ?[]const u8,
) Error!Payload {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return Error.Malformed;
    const header_b64 = token[0..first_dot];
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return Error.Malformed;
    const payload_b64 = rest[0..second_dot];
    const sig_b64 = rest[second_dot + 1 ..];

    if (!std.mem.eql(u8, header_b64, HEADER_B64)) return Error.UnsupportedAlg;
    if (sig_b64.len != SIG_B64_LEN) return Error.Malformed;

    const signing_input_len = header_b64.len + 1 + payload_b64.len;
    var signing_input_buf: [256]u8 = undefined;
    if (signing_input_len > signing_input_buf.len) return Error.Malformed;
    @memcpy(signing_input_buf[0..header_b64.len], header_b64);
    signing_input_buf[header_b64.len] = '.';
    @memcpy(signing_input_buf[header_b64.len + 1 ..][0..payload_b64.len], payload_b64);

    var expected_sig: [32]u8 = undefined;
    HmacSha256.create(&expected_sig, signing_input_buf[0..signing_input_len], secret);
    var expected_b64_buf: [SIG_B64_LEN]u8 = undefined;
    const expected_b64 = B64.Encoder.encode(&expected_b64_buf, &expected_sig);

    if (!std.crypto.timing_safe.eql([SIG_B64_LEN]u8, expected_b64[0..SIG_B64_LEN].*, sig_b64[0..SIG_B64_LEN].*))
        return Error.BadSignature;

    var payload_json_buf: [256]u8 = undefined;
    const payload_json_len = B64.Decoder.calcSizeForSlice(payload_b64) catch return Error.Malformed;
    if (payload_json_len > payload_json_buf.len) return Error.Malformed;
    B64.Decoder.decode(payload_json_buf[0..payload_json_len], payload_b64) catch
        return Error.Malformed;
    const json = payload_json_buf[0..payload_json_len];

    const exp_ms = parseExp(json) orelse return Error.Malformed;
    if (now_ms >= exp_ms) return Error.Expired;

    if (required_cap) |cap| {
        if (!hasCap(json, cap)) return Error.MissingCap;
    }
    if (required_tenant) |t| {
        if (!hasTenant(json, t)) return Error.WrongTenant;
    }
    return .{ .exp_ms = exp_ms };
}

/// Parse `{"exp":<i64>}`. Returns null on any deviation. Tight
/// hand-coded reader so the standalone doesn't pay std.json's setup
/// cost on every request.
fn parseExp(json: []const u8) ?i64 {
    const needle = "\"exp\":";
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = idx + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (i >= json.len) return null;
    const start = i;
    if (json[i] == '-') i += 1;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(i64, json[start..i], 10) catch null;
}

/// Substring-search the payload JSON for `cap` as a quoted element
/// inside the `caps` array. Caps are validated at mint time to
/// contain only `[a-zA-Z0-9_-]`, so the JSON-encoded form is just
/// `"<cap>"` — no escaping to undo, no neighbouring tokens to
/// confuse. The needle includes both quotes so a cap named `read`
/// doesn't match a cap named `read-only` (or vice versa).
fn hasCap(json: []const u8, cap: []const u8) bool {
    if (cap.len == 0 or cap.len > 64) return false;
    const caps_marker = "\"caps\":[";
    const start = std.mem.indexOf(u8, json, caps_marker) orelse return false;
    const after = json[start + caps_marker.len ..];
    const end = std.mem.indexOfScalar(u8, after, ']') orelse return false;
    const list = after[0..end];

    var needle_buf: [66]u8 = undefined;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + cap.len], cap);
    needle_buf[1 + cap.len] = '"';
    return std.mem.indexOf(u8, list, needle_buf[0 .. 2 + cap.len]) != null;
}

/// Substring-search the payload JSON for `"tenant":"<expected>"`. The
/// trailing quote delimits, so tenant `acme` does not match a token
/// scoped to `acme-prod`. Tenant is validated to `[a-zA-Z0-9_-]` at
/// mint, so the JSON-encoded form is just `"tenant":"<id>"` — no
/// escaping to undo. A token with no `tenant` field never matches.
fn hasTenant(json: []const u8, expected: []const u8) bool {
    if (expected.len == 0 or expected.len > 64) return false;
    const prefix = "\"tenant\":\"";
    var needle_buf: [prefix.len + 64 + 1]u8 = undefined;
    @memcpy(needle_buf[0..prefix.len], prefix);
    @memcpy(needle_buf[prefix.len..][0..expected.len], expected);
    needle_buf[prefix.len + expected.len] = '"';
    return std.mem.indexOf(u8, json, needle_buf[0 .. prefix.len + expected.len + 1]) != null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "mint + verify round-trip" {
    const a = testing.allocator;
    const secret = "hunter2-and-then-some";
    const tok = try mint(a, secret, .{ .exp_ms = 1_000_000_000 });
    defer a.free(tok);
    const got = try verify(secret, tok, 999_999_999);
    try testing.expectEqual(@as(i64, 1_000_000_000), got.exp_ms);
}

test "expired token rejected" {
    const a = testing.allocator;
    const secret = "k";
    const tok = try mint(a, secret, .{ .exp_ms = 1_000 });
    defer a.free(tok);
    try testing.expectError(Error.Expired, verify(secret, tok, 1_000));
    try testing.expectError(Error.Expired, verify(secret, tok, 9_999));
}

test "wrong secret rejected" {
    const a = testing.allocator;
    const tok = try mint(a, "good", .{ .exp_ms = 9_999 });
    defer a.free(tok);
    try testing.expectError(Error.BadSignature, verify("evil", tok, 0));
}

test "tampered payload rejected" {
    const a = testing.allocator;
    const tok = try mint(a, "k", .{ .exp_ms = 1_000_000 });
    defer a.free(tok);
    const first_dot = std.mem.indexOfScalar(u8, tok, '.').?;
    const second_dot = std.mem.indexOfScalarPos(u8, tok, first_dot + 1, '.').?;
    const tampered = try a.dupe(u8, tok);
    defer a.free(tampered);
    tampered[second_dot - 1] = if (tampered[second_dot - 1] == 'A') 'B' else 'A';
    try testing.expectError(Error.BadSignature, verify("k", tampered, 0));
}

test "malformed tokens rejected" {
    try testing.expectError(Error.Malformed, verify("k", "not-a-jwt", 0));
    try testing.expectError(Error.Malformed, verify("k", "only.one-dot", 0));
}

test "header with different alg rejected" {
    const fake = "eyJhbGciOiJub25lIn0..sig";
    try testing.expectError(Error.UnsupportedAlg, verify("k", fake, 0));
}

test "mint with caps + verifyWithCap accepts" {
    const a = testing.allocator;
    const tok = try mint(a, "k", .{ .exp_ms = 1_000_000, .caps = &.{ Cap.RELEASE, Cap.ADMIN_KV } });
    defer a.free(tok);
    const p = try verifyWithCap("k", tok, 0, Cap.RELEASE);
    try testing.expectEqual(@as(i64, 1_000_000), p.exp_ms);
    _ = try verifyWithCap("k", tok, 0, Cap.ADMIN_KV);
}

test "verifyWithCap rejects token without that cap" {
    const a = testing.allocator;
    const tok = try mint(a, "k", .{ .exp_ms = 1_000_000, .caps = &.{Cap.RELEASE} });
    defer a.free(tok);
    try testing.expectError(Error.MissingCap, verifyWithCap("k", tok, 0, Cap.ADMIN_KV));
}

test "verifyWithCap rejects token with no caps at all" {
    const a = testing.allocator;
    const tok = try mint(a, "k", .{ .exp_ms = 1_000_000 });
    defer a.free(tok);
    try testing.expectError(Error.MissingCap, verifyWithCap("k", tok, 0, Cap.RELEASE));
}

test "verify (no cap check) ignores caps list" {
    const a = testing.allocator;
    const tok = try mint(a, "k", .{ .exp_ms = 1_000_000, .caps = &.{Cap.RELEASE} });
    defer a.free(tok);
    const p = try verify("k", tok, 0);
    try testing.expectEqual(@as(i64, 1_000_000), p.exp_ms);
}

test "hasCap delimits on quotes (substring guard)" {
    // Token granting "release-foo" should NOT match cap "release".
    const a = testing.allocator;
    const tok = try mint(a, "k", .{ .exp_ms = 1_000_000, .caps = &.{"release-foo"} });
    defer a.free(tok);
    try testing.expectError(Error.MissingCap, verifyWithCap("k", tok, 0, Cap.RELEASE));
    _ = try verifyWithCap("k", tok, 0, "release-foo");
}

test "mintWithPayload + verifyAndCopyPayload round-trip carries arbitrary fields" {
    const a = testing.allocator;
    const payload = "{\"v\":1,\"tenant_id\":\"acme\",\"sid\":\"abc\",\"exp\":1000000}";
    const tok = try mintWithPayload(a, "k", payload);
    defer a.free(tok);

    var buf: [256]u8 = undefined;
    const decoded = try verifyAndCopyPayload("k", tok, 0, &buf);
    try testing.expectEqualStrings(payload, decoded);
}

test "mintWithPayload rejects tokens with bad sig under a different secret" {
    const a = testing.allocator;
    const tok = try mintWithPayload(a, "k", "{\"exp\":9999999}");
    defer a.free(tok);
    var buf: [256]u8 = undefined;
    try testing.expectError(Error.BadSignature, verifyAndCopyPayload("evil", tok, 0, &buf));
}

test "mint rejects caps with invalid chars" {
    const a = testing.allocator;
    try testing.expectError(Error.InvalidCap, mint(a, "k", .{
        .exp_ms = 1_000,
        .caps = &.{"has space"},
    }));
    try testing.expectError(Error.InvalidCap, mint(a, "k", .{
        .exp_ms = 1_000,
        .caps = &.{"with\"quote"},
    }));
    try testing.expectError(Error.InvalidCap, mint(a, "k", .{
        .exp_ms = 1_000,
        .caps = &.{""},
    }));
}

test "tenant-scoped token: verifyWithCapAndTenant accepts matching cap + tenant" {
    const a = testing.allocator;
    const tok = try mint(a, "k", .{
        .exp_ms = 1_000_000,
        .caps = &.{Cap.LOGS_READ},
        .tenant = "acme-prod",
    });
    defer a.free(tok);
    const p = try verifyWithCapAndTenant("k", tok, 0, Cap.LOGS_READ, "acme-prod");
    try testing.expectEqual(@as(i64, 1_000_000), p.exp_ms);
}

test "tenant-scoped token: rejects a different tenant" {
    const a = testing.allocator;
    const tok = try mint(a, "k", .{
        .exp_ms = 1_000_000,
        .caps = &.{"logs-read"},
        .tenant = "acme-prod",
    });
    defer a.free(tok);
    try testing.expectError(Error.WrongTenant, verifyWithCapAndTenant("k", tok, 0, "logs-read", "globex-prod"));
}

test "tenant-scoped verify rejects a token with NO tenant claim (the gap)" {
    // The core fix: an unscoped (legacy "any tenant") token must never
    // satisfy a tenant-scoped verify, or the cross-tenant read gap stays.
    const a = testing.allocator;
    const tok = try mint(a, "k", .{ .exp_ms = 1_000_000, .caps = &.{"logs-read"} });
    defer a.free(tok);
    try testing.expectError(Error.WrongTenant, verifyWithCapAndTenant("k", tok, 0, "logs-read", "acme-prod"));
}

test "tenant-scoped verify still enforces the cap" {
    const a = testing.allocator;
    const tok = try mint(a, "k", .{ .exp_ms = 1_000_000, .caps = &.{"admin-kv"}, .tenant = "acme" });
    defer a.free(tok);
    // right tenant, wrong cap → MissingCap (cap checked before tenant)
    try testing.expectError(Error.MissingCap, verifyWithCapAndTenant("k", tok, 0, "logs-read", "acme"));
}

test "hasTenant delimits on quotes (acme != acme-prod)" {
    const a = testing.allocator;
    const tok = try mint(a, "k", .{ .exp_ms = 1_000_000, .caps = &.{"logs-read"}, .tenant = "acme-prod" });
    defer a.free(tok);
    // a verify scoped to "acme" must NOT match a token scoped to "acme-prod"
    try testing.expectError(Error.WrongTenant, verifyWithCapAndTenant("k", tok, 0, "logs-read", "acme"));
    _ = try verifyWithCapAndTenant("k", tok, 0, "logs-read", "acme-prod");
}

test "system tenant ids (underscores) are valid tenant scopes" {
    const a = testing.allocator;
    const tok = try mint(a, "k", .{ .exp_ms = 1_000_000, .caps = &.{"admin-kv"}, .tenant = "__admin__" });
    defer a.free(tok);
    _ = try verifyWithCapAndTenant("k", tok, 0, "admin-kv", "__admin__");
}

test "mint rejects tenant with invalid chars" {
    const a = testing.allocator;
    try testing.expectError(Error.InvalidTenant, mint(a, "k", .{ .exp_ms = 1_000, .tenant = "has space" }));
    try testing.expectError(Error.InvalidTenant, mint(a, "k", .{ .exp_ms = 1_000, .tenant = "with\"quote" }));
    try testing.expectError(Error.InvalidTenant, mint(a, "k", .{ .exp_ms = 1_000, .tenant = "" }));
}

test "tenant scope is back-compatible: plain verify + verifyWithCap ignore it" {
    const a = testing.allocator;
    const tok = try mint(a, "k", .{ .exp_ms = 1_000_000, .caps = &.{"logs-read"}, .tenant = "acme" });
    defer a.free(tok);
    // a tenant-unaware verifier still works on a tenant-scoped token
    const p = try verify("k", tok, 0);
    try testing.expectEqual(@as(i64, 1_000_000), p.exp_ms);
    _ = try verifyWithCap("k", tok, 0, "logs-read");
}
