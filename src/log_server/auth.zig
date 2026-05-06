//! HS256 JWT helpers for the log-server's `Authorization: Bearer`
//! gate.
//!
//! Wire format is the standard JWT three-part token:
//!   `<base64url(header)>.<base64url(payload)>.<base64url(sig)>`
//!
//! Header is fixed: `{"alg":"HS256","typ":"JWT"}`.
//! Payload is `{"exp":<unix_ms>}`. No subject / issuer / audience —
//! the token's only job is to prove "an authenticated dashboard
//! session minted this token within the last few minutes." Tenant
//! authorization happens on the worker (when minting) and on the
//! standalone (when applying the token to a per-tenant route).
//!
//! The HMAC secret is shared between the worker process (which mints
//! tokens at `/_system/log-token`) and the standalone log-server
//! (which verifies them on every `/v1/*` request). Both run inside
//! the same loop46 process for now; multi-node will need an
//! operator-supplied env var.

const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const B64 = std.base64.url_safe_no_pad;

pub const Error = error{
    Malformed,
    BadSignature,
    Expired,
    UnsupportedAlg,
    OutOfMemory,
};

/// Fixed JWT header bytes. Pre-encoded so mint doesn't need to
/// re-base64 it on every call.
const HEADER_B64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

/// HS256 signature is 32 bytes → 43 base64url chars (no padding).
const SIG_B64_LEN: usize = 43;

pub const Payload = struct {
    /// Unix milliseconds. Tokens minted by the worker use a 5-minute
    /// expiry; the dashboard refreshes on demand by hitting
    /// `/_system/log-token` again.
    exp_ms: i64,
};

/// Mint a token. Caller frees with `allocator.free`. The output is
/// pure ASCII (base64url chars + two `.` separators).
pub fn mint(allocator: std.mem.Allocator, secret: []const u8, payload: Payload) Error![]u8 {
    var payload_json_buf: [64]u8 = undefined;
    const payload_json = std.fmt.bufPrint(&payload_json_buf, "{{\"exp\":{d}}}", .{payload.exp_ms}) catch
        unreachable;

    var payload_b64_buf: [128]u8 = undefined;
    const payload_b64 = B64.Encoder.encode(&payload_b64_buf, payload_json);

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
/// expiry check is timing-trivial.
pub fn verify(secret: []const u8, token: []const u8, now_ms: i64) Error!Payload {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return Error.Malformed;
    const header_b64 = token[0..first_dot];
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return Error.Malformed;
    const payload_b64 = rest[0..second_dot];
    const sig_b64 = rest[second_dot + 1 ..];

    if (!std.mem.eql(u8, header_b64, HEADER_B64)) return Error.UnsupportedAlg;
    if (sig_b64.len != SIG_B64_LEN) return Error.Malformed;

    // Recompute the signature.
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

    // std.crypto.utils.timingSafeEql for constant-time compare.
    if (!std.crypto.timing_safe.eql([SIG_B64_LEN]u8, expected_b64[0..SIG_B64_LEN].*, sig_b64[0..SIG_B64_LEN].*))
        return Error.BadSignature;

    // Decode + parse payload.
    var payload_json_buf: [128]u8 = undefined;
    const payload_json_len = B64.Decoder.calcSizeForSlice(payload_b64) catch return Error.Malformed;
    if (payload_json_len > payload_json_buf.len) return Error.Malformed;
    B64.Decoder.decode(payload_json_buf[0..payload_json_len], payload_b64) catch
        return Error.Malformed;

    const exp_ms = parseExp(payload_json_buf[0..payload_json_len]) orelse return Error.Malformed;
    if (now_ms >= exp_ms) return Error.Expired;
    return .{ .exp_ms = exp_ms };
}

/// Parse `{"exp":<i64>}`. Returns null on any deviation. Tight
/// hand-coded reader so the standalone doesn't pay std.json's setup
/// cost on every request.
fn parseExp(json: []const u8) ?i64 {
    const needle = "\"exp\":";
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = idx + needle.len;
    // Skip optional whitespace.
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (i >= json.len) return null;
    const start = i;
    if (json[i] == '-') i += 1;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(i64, json[start..i], 10) catch null;
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
    // Flip a payload byte. Locate the second dot and tamper one char before.
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
    // header for {"alg":"none"} — base64url(`{"alg":"none"}`)
    const fake = "eyJhbGciOiJub25lIn0..sig";
    try testing.expectError(Error.UnsupportedAlg, verify("k", fake, 0));
}
