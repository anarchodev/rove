//! Per-request / per-batch `events.emit` accumulator shape.
//!
//! `events.emit` populates an `EmitEntry` list on the dispatch
//! state; `worker_dispatch` / `tenant_batch` collect it per batch and,
//! after the writeset commits, hand it to the in-process SSE thread
//! via `sse_server.thread.Handle.enqueueEmit` (task #10 Phase 2 —
//! replaced the retired worker→sse-server HTTP emit POST).
//!
//! The customer's `app.db` remains the source of truth — SSE is a
//! notification channel, not a durable store. Losing an emit is
//! acceptable: the next reconnect's sentinel + state refetch covers
//! it (best-effort by contract; `enqueueEmit` drops on OOM).

const std = @import("std");

/// Same shape as the wire id `events.emit` produces:
/// `{request_id:020d}-{call_index:06d}` = 27 chars.
pub const EVENT_ID_LEN: usize = 27;

/// One captured `events.emit` call. Owned by the dispatch state's
/// allocator; freed via `deinit` when the per-batch list drains
/// (after `enqueueEmit` has deep-copied it into SSE-owned memory).
pub const EmitEntry = struct {
    /// `{request_id:020d}-{call_index:06d}` — deterministic across
    /// tape replays so resume-by-Last-Event-ID works after replay.
    event_id: [EVENT_ID_LEN]u8,
    /// Customer-supplied `type` (defaults to `"message"`).
    event_type: []u8,
    /// Customer-supplied payload, JSON-serialized. Embedded
    /// verbatim into the wire body's `data` field.
    data_json: []u8,
    /// Target sids. Defaults to `[request.session.id]`; explicit
    /// `to: [...]` produces multi-target fan-out.
    target_sids: [][]u8,
    /// Wall-clock at emit. Forwarded to the ring cache so the
    /// catch-up replay carries the original timestamp.
    created_at_ms: i64,

    pub fn deinit(self: *EmitEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.data_json);
        for (self.target_sids) |s| allocator.free(s);
        allocator.free(self.target_sids);
        self.* = undefined;
    }
};
