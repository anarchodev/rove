//! rove-schedule-server — the platform's outbound HTTP fire path.
//!
//! Post-5b-2-d this module is just the libcurl fire mechanics + the
//! SSRF policy that Option (b)'s per-node `SendDispatch`
//! (`src/js/send_dispatch.zig`) drives. The cluster-wide
//! raft-replicated schedule/callback storage (`ScheduleStore`,
//! `ScheduleRow`, `CallbackRow`, the env-8/9/10/11 wire format, the
//! leader-pinned scheduler thread, the §3.2 in-process
//! internal-routing fast path) was deleted in the http.send N-way
//! re-platform: a send's only firing record is now the per-tenant
//! `_send/owed/{id}` marker riding envelope-0, fired by a
//! leader-local in-memory dispatcher. See `docs/http-send-plan.md`
//! (§15 Option (b)) for the design.
//!
//! ## What lives here
//!
//! - `thread.fireOnce` — the blocking single-shot libcurl call
//!   (`FireParams` → `FireResult`), called from `SendDispatch`'s
//!   dedicated fire-thread pool.
//! - `ssrf` — the SSRF blocklist (RFC1918 / loopback /
//!   cloud-metadata) `fireOnce` enforces before connecting.
//! - `Outcome` / `Error` / `RESPONSE_BODY_CAP` / `ID_MAX_LEN` —
//!   small wire/contract constants the fire path + callers share.

const std = @import("std");

/// The blocking single-shot libcurl fire path. `SendDispatch`'s
/// dedicated fire-thread pool calls `thread.fireOnce`.
pub const thread = @import("thread.zig");

/// SSRF blocklist for outbound HTTP. Used by `thread.zig` to refuse
/// connections to RFC1918 / loopback / cloud-metadata addresses
/// (test hook: `ssrf.test_allow_loopback`).
pub const ssrf = @import("ssrf.zig");

pub const Error = error{
    Truncated,
    InvalidVersion,
    InvalidOutcome,
    InvalidHandle,
    InvalidMethod,
    OutOfMemory,
    Kv,
};

/// Body cap on what the fire path captures and hands back to the
/// customer's on_result handler. See `docs/http-send-plan.md` §1.
pub const RESPONSE_BODY_CAP: usize = 256 * 1024;

/// Customer-supplied handle width: 1-256 bytes UTF-8, no NUL. The
/// platform-derived id (sha256 hex) is 64 chars, well inside.
pub const ID_MAX_LEN: usize = 256;

/// Outcome on the wire — the fire path reports delivered vs failed;
/// callers (`SendDispatch` / the resolution phase) map it onto the
/// on_result event's success/failure shape.
pub const Outcome = enum(u8) {
    delivered = 0,
    failed = 1,
};

// ── Tests ──────────────────────────────────────────────────────────────

// Pull thread.zig + ssrf.zig tests into the schedule_server test
// binary. `pub const X = @import(...)` alone doesn't make Zig
// collect a file's tests — they must be comptime-referenced here.
test {
    _ = thread;
    _ = ssrf;
}
