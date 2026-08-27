// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The data-plane `Node`'s hot loop and the effects it drives: `pump` (tick →
//! ack completed fsyncs → ready → apply → send → hand the fsync to the
//! flusher thread; or, inline without one: tick → ready → apply → fsync →
//! ack → send), `durabilizeTick`,
//! `autoDemoteTick`, the hibernation active-set helpers, `propose*`, the
//! committed-entry apply path (`applyEntry` / `applyCb` / `notifyApply`), and the
//! raft-rs C-ABI callbacks. Method bodies for `node_core.zig`'s `Node`; `node.zig`
//! re-exports the public ones via `Node`. Imports `node_core.zig` for the types —
//! never `node.zig` (the root-import trap; see node.zig's header).

const std = @import("std");
const raft = @import("raft_rs_zig");
const writeset = @import("kvlimbs").writeset;
const envelope = @import("envelope.zig");

const core = @import("node_core.zig");
const Node = core.Node;
const TenantSlot = core.TenantSlot;
const Error = core.Error;
const KvStore = core.KvStore;
const WriteSet = core.WriteSet;

pub fn growReadyBuf(self: *Node) Error!void {
    const need = self.groups.count();
    if (self.ready_buf.len >= need) return;
    const grown = self.allocator.realloc(self.ready_buf, need) catch return Error.OutOfMemory;
    self.ready_buf = grown;
    const grown2 = self.allocator.realloc(self.ready_buf2, need) catch return Error.OutOfMemory;
    self.ready_buf2 = grown2;
}

/// Queue `gid` for the post-fsync `onPersist` ack (at most once per
/// round — see `persist_ack`). In async-fsync mode the note-time stamp is
/// the LAST-REQUESTED seq: a group that appends this cycle is re-stamped
/// with the new request right after the round, and one that appended
/// nothing is covered by whatever was already requested (its raft stash
/// is empty, so the eventual ack is a no-op). Pump-thread only.
pub fn notePersistAck(self: *Node, gid: u64) void {
    const slot = self.groups.get(gid) orelse return;
    slot.hib.persist_seq = self.wal_flusher.lastRequested();
    self.active_set.addPersistAck(slot, gid, self.allocator) catch {
        // Dropping the ack would stall the group's commits forever
        // (raft never counts its entries); surface loudly instead.
        self.apply_err = self.apply_err orelse Error.OutOfMemory;
    };
}

// ── Hibernation active set ─────────────────────────────

fn nowNs() i64 {
    return @intCast(std.time.nanoTimestamp());
}

/// Mark a group active: refresh its hibernate deadline and add it to the
/// tick set if absent. Called on every propose, on formation, and on a
/// non-heartbeat inbound step — the events that mean "this group has
/// work," so the pump keeps ticking it. A no-op for an unknown gid.
/// Pump-thread only (mutates `active` + the slot).
pub fn bumpActive(self: *Node, gid: u64) Error!void {
    const slot = self.groups.get(gid) orelse return;
    slot.hib.active_until_ns = nowNs() + self.hibernate_ns;
    self.active_set.addActive(slot, gid, self.allocator) catch return Error.OutOfMemory;
}

/// Pin a group as ALWAYS-active: never hibernated, so it keeps ticking
/// (heartbeating as leader / running its election timer as follower)
/// regardless of request activity. The control-plane directory group uses
/// this — it is ONE group (so always-ticking is O(1)) and MUST stay
/// available: a directory read never proposes, so a hibernated directory
/// group whose leader died would never wake to re-elect. Pump-thread only
/// (or pre-pump). A no-op for an unknown gid.
pub fn pinActive(self: *Node, gid: u64) Error!void {
    const slot = self.groups.get(gid) orelse return;
    slot.hib.pinned = true;
    slot.hib.active_until_ns = nowNs() + self.hibernate_ns;
    self.active_set.addActive(slot, gid, self.allocator) catch return Error.OutOfMemory;
}

/// Remove a group from the active set (destroy / errdefer). Clears its
/// `in_active` flag. O(active); the active set is small by design.
pub fn dropActive(self: *Node, gid: u64) void {
    for (self.active_set.active.items, 0..) |g, i| {
        if (g == gid) {
            _ = self.active_set.active.swapRemove(i);
            break;
        }
    }
    if (self.groups.get(gid)) |slot| slot.hib.in_active = false;
}

/// Drop every group whose hibernate deadline has passed from the active
/// set — the pump stops ticking it, so it stops heartbeating (leader) /
/// running its election timer (follower) until a propose or non-heartbeat
/// step wakes it. Run once per pump cycle. Pump-thread only.
pub fn sweepHibernated(self: *Node, now: i64) void {
    var i: usize = 0;
    while (i < self.active_set.active.items.len) {
        const gid = self.active_set.active.items[i];
        const slot = self.groups.get(gid) orelse {
            _ = self.active_set.active.swapRemove(i);
            continue;
        };
        // Keep ticking a LEADERLESS group even past its idle deadline: a
        // group with no known leader (this node not leading AND `leaderId`
        // == 0 — e.g. a woken survivor mid-recovery) must keep running its
        // election timer / escalation, else it would re-hibernate frozen
        // before electing. A group with a live leader (leaderId != 0,
        // including this node as leader) hibernates normally.
        const leaderless = !self.mgr.isLeader(gid) and self.mgr.leaderId(gid) == 0;
        if (!slot.hib.pinned and !leaderless and now > slot.hib.active_until_ns) {
            slot.hib.in_active = false;
            _ = self.active_set.active.swapRemove(i);
        } else i += 1;
    }
}

/// TiKV-style wake-to-elect (the hard-failover recovery): force-campaign any
/// ACTIVE group that has stayed leaderless past `leaderless_escalate_ns`.
///
/// After a SIGKILL leader loss the surviving voters re-elect on their own
/// ONLY if their `check_quorum` leases happen to expire in time — a frozen,
/// just-woken survivor whose `election_elapsed` stalled below the timeout
/// keeps `leader_id` pointing at the dead leader and IGNORES the normal
/// (pre-)vote (raft's disruptive-server lease). A force-campaign
/// (`mgr.campaignForce` → `campaign(CAMPAIGN_TRANSFER)`) sends votes that
/// carry the transfer context, which receivers honour past their lease — so
/// recovery is deterministic instead of timing-dependent.
///
/// Trigger: this node is not the leader AND `leaderId == 0` (genuinely
/// leaderless — a node mid-pre-vote is a `PreCandidate`, which raft sets to
/// `leader_id == INVALID_ID`, so this also catches the wedged re-pre-voting
/// case). A live leader (`leaderId != 0`) disarms it, so a healthy group is
/// never disrupted. Gated on the escalation window so a normal election
/// completes first; `campaignForce` itself is a safe no-op on a leader,
/// learner, or pending-conf-change group. Pump-thread only; O(active).
pub fn escalateLeaderless(self: *Node, now: i64) void {
    for (self.active_set.active.items) |gid| {
        const slot = self.groups.get(gid) orelse continue;
        const leaderless = !self.mgr.isLeader(gid) and self.mgr.leaderId(gid) == 0;
        if (!leaderless) {
            slot.hib.leaderless_since_ns = 0;
            slot.hib.last_seen_leader = self.mgr.leaderId(gid);
            continue;
        }
        if (slot.hib.leaderless_since_ns == 0) {
            slot.hib.leaderless_since_ns = now;
            logLeaderlessEdge(self, gid, slot, now);
        } else if (now - slot.hib.leaderless_since_ns >= self.leaderless_escalate_ns) {
            // WARN, not debug: a force-campaign bypasses pre-vote AND peers'
            // check_quorum leases, so it is the one action that can depose a
            // healthy leader. It should be rare (a genuinely wedged group);
            // seeing it during an ordinary failover means the escalation
            // window closed on an election that was still progressing.
            std.log.warn("raft: FORCE-CAMPAIGN gid={d} after {d}ms leaderless (window {d}ms) at={d}", .{
                gid,
                @divTrunc(now - slot.hib.leaderless_since_ns, std.time.ns_per_ms),
                @divTrunc(self.leaderless_escalate_ns, std.time.ns_per_ms),
                std.time.milliTimestamp(),
            });
            self.mgr.campaignForce(gid);
            // Re-arm the window (cooldown) so the next escalation, if the
            // forced campaign also loses (split vote), waits another window
            // rather than force-campaigning every cycle.
            slot.hib.leaderless_since_ns = now;
        }
    }
}

/// Election forensics, fired once per leaderless edge — the first cycle a
/// group that HAD a live leader is observed with none (a follower's election
/// timeout fired, or this node — `prev_leader` = its own id — stepped down /
/// was deposed). Logs the age of the group's last leader traffic from the
/// transport's per-group stamps, which separates the three candidate causes
/// of a spurious election: the leader never sent (its own edge shows a large
/// `hb_sent_age`), the wire/receive path delayed it (leader sent fresh, this
/// node's `hb_recv_age` large), or the traffic arrived but too late to beat
/// the election window (`hb_recv_age` small, `hb_recv_gap` spans the window).
/// A group born/woken leaderless (`last_seen_leader == 0`) is skipped —
/// formation and cold recovery are not elections worth forensics. Ages are
/// -1 when the stamp (or the transport) is absent. Pump-thread only.
fn logLeaderlessEdge(self: *Node, gid: u64, slot: *TenantSlot, now: i64) void {
    const prev = slot.hib.last_seen_leader;
    if (prev == 0) return;
    slot.hib.last_seen_leader = 0;
    var hb_recv_age_us: i64 = -1;
    var hb_recv_gap_us: i64 = -1;
    var append_recv_age_us: i64 = -1;
    var hb_sent_age_us: i64 = -1;
    var append_sent_age_us: i64 = -1;
    if (self.transport) |t| {
        if (t.recvStampFor(gid)) |r| {
            if (r.hb_ns != 0) hb_recv_age_us = @divTrunc(now - r.hb_ns, std.time.ns_per_us);
            if (r.hb_gap_ns != 0) hb_recv_gap_us = @divTrunc(r.hb_gap_ns, std.time.ns_per_us);
            if (r.append_ns != 0) append_recv_age_us = @divTrunc(now - r.append_ns, std.time.ns_per_us);
        }
        if (t.sendStampFor(gid)) |s| {
            if (s.hb_ns != 0) hb_sent_age_us = @divTrunc(now - s.hb_ns, std.time.ns_per_us);
            if (s.append_ns != 0) append_sent_age_us = @divTrunc(now - s.append_ns, std.time.ns_per_us);
        }
    }
    std.log.warn(
        "raft: leaderless-edge gid={d} prev_leader={d} self={d} hb_recv_age_us={d} hb_recv_gap_us={d} append_recv_age_us={d} hb_sent_age_us={d} append_sent_age_us={d} at={d}",
        .{ gid, prev, self.node_id, hb_recv_age_us, hb_recv_gap_us, append_recv_age_us, hb_sent_age_us, append_sent_age_us, std.time.milliTimestamp() },
    );
}

/// Propose an encoded envelope to `tenant_id`'s group with no origin
/// identity (hookless: tests, bare nodes — `origin = seq = 0` matches
/// no bridge, so the entry is never skipped and advances no
/// watermark). See `proposeFramed`.
pub fn propose(self: *Node, tenant_id: u64, env_bytes: []const u8) Error!void {
    return self.proposeFramed(tenant_id, 0, 0, env_bytes);
}

/// Propose an encoded envelope stamped with the proposer's identity
/// (`envelope.EntryFrame`: the bridge's per-boot `origin` + the
/// per-tenant `seq`). Returns once the entry is staged in raft-rs's
/// pending list — NOT once applied. Drive `pump` to commit + apply
/// it. A propose is activity, so it wakes the group (`bumpActive`) —
/// a hibernated tenant ticks again and replicates the entry. Bump
/// first so even a propose that raft-rs rejects (non-leader) still
/// re-ticks the group toward an election.
pub fn proposeFramed(self: *Node, tenant_id: u64, origin: u64, seq: u64, env_bytes: []const u8) Error!void {
    try self.bumpActive(tenant_id);
    const framed = try envelope.encodeEntryFrame(self.allocator, origin, seq, env_bytes);
    defer self.allocator.free(framed);
    try self.mgr.propose(tenant_id, framed);
}

/// Build a type-0 writeset envelope from `ws` and propose it, then
/// pump until it commits + applies to the tenant's store (or the
/// budget is exhausted → `NotCommitted`). Returns the applied index.
pub fn proposeWriteSet(self: *Node, tenant_id: u64, id_str: []const u8, ws: *const WriteSet) Error!u64 {
    const slot = try self.ensureGroup(tenant_id, id_str);
    const before = slot.applied_idx;

    const ws_bytes = ws.encode(self.allocator) catch return Error.OutOfMemory;
    defer self.allocator.free(ws_bytes);
    const env = try envelope.encodeWriteSet(self.allocator, id_str, ws_bytes);
    defer self.allocator.free(env);

    try self.propose(tenant_id, env);

    var spins: u32 = 0;
    while (slot.applied_idx == before and spins < 200) : (spins += 1) {
        _ = try self.pump();
    }
    if (slot.applied_idx == before) return Error.NotCommitted;
    return slot.applied_idx;
}

/// Drive one ready cycle across the active set. Returns true if any
/// group had committed entries to apply this cycle.
///
/// The async-append pump (persist-before-quorum ordering): tick the
/// active set, then
///
///   pass 1: processReady every ready group — appends are BUFFERED
///           into the shared WAL; committed entries handed out here
///           were already durable (raft gates them on its persist
///           watermark) and apply now
///   fsync:  ONE `wal.flush()` for the whole cycle (the load-bearing
///           single-fsync constraint)
///   ack:    `mgr.onPersist` per buffered group — only now do this
///           node's entries count toward the commit quorum, and only
///           now do the stashed persistence-asserting messages
///           (append acks / vote responses) reach the outboxes
///   pass 2: the acks unlock commit advances — poll + apply the
///           newly-committed entries in the same cycle
///   hooks:  fire the staged commit notifications (everything applied
///           this cycle is fsync-covered)
///   drain:  takeMessages + release for both passes' groups.
///
/// Single-node has no peers, so `takeMessages` drains to a no-op
/// sink — but the drain+release is still required to honour the
/// pollReady/release pairing invariant.
pub fn pump(self: *Node) Error!bool {
    // Raft logical tick — interval-gated so the wall-clock election timeout
    // is `election_tick × tick_interval_ns`, a fixed number, rather than
    // floating with the pump loop / fsync cadence (see `DEFAULT_TICK_NS`).
    // pollReady / processReady / transport I/O below still run EVERY cycle;
    // only the tick is gated. Single-tick-when-due (not catch-up bursts):
    // after a stall the timer just resumes, which is conservative — slower
    // elections, never a spurious burst.
    {
        const now = nowNs();
        if (now - self.last_tick_ns >= self.tick_interval_ns) {
            self.last_tick_ns = now;
            _ = self.mgr.tickGroups(self.active_set.active.items);
        }
    }
    self.apply_err = null;

    // Async-fsync completions (flusher running): fire the deferred
    // `onPersist` for every group whose latest append the flusher's
    // completed fsync covers — BEFORE pollReady, so a commit advance the
    // ack unlocks surfaces in this same cycle's ready set (a single-node
    // propose commits in fsync + one cycle). A flusher fsync failure is a
    // durability loss with no completion published — die loudly like an
    // inline flush failure would; a restart replays the WAL.
    var acked_any = false;
    if (self.wal_flusher.started()) {
        if (self.wal_flusher.failed.load(.acquire)) return Error.Io;
        acked_any = ackCovered(self, self.wal_flusher.completed.load(.acquire));
    }

    const ready = self.mgr.pollReady(self.ready_buf);

    var ready2: []u64 = self.ready_buf2[0..0];
    if (self.wal_flusher.started()) {
        if (ready.len > 0) {
            self.commit_notify.clearRetainingCapacity();
            // Append this round's writes (direct writevAll — in the kernel,
            // not yet durable) and apply committed entries. Committed
            // entries raft hands out here are already quorum-durable: its
            // commit math counts this node only up to the persist watermark,
            // which advances only via the post-fsync `onPersist` above — so
            // the commit hook below needs no flush gate.
            const seg_before = self.wal.next_seg_no;
            const off_before = self.wal.wal_offset;
            for (ready) |g| {
                self.mgr.processReady(g, applyCb, self) catch |e| {
                    self.apply_err = self.apply_err orelse mapRaftErr(e);
                };
                self.notePersistAck(g);
            }

            // Hand the fsync to the flusher and KEEP GOING — the send loop
            // below runs before any fsync completes, which is the point:
            // heartbeats (and a follower's heartbeat responses) are in the
            // outbox now (the persistence-asserting messages are stashed in
            // raft until `onPersist`), so a slow fsync no longer makes this
            // node heartbeat-silent past the election timeout. Awaiting
            // groups are stamped with the request's seq; a group that
            // appended nothing keeps its note-time stamp (already covered).
            if (self.wal.next_seg_no != seg_before or self.wal.wal_offset != off_before) {
                const dupfd = std.posix.dup(self.wal.file.handle) catch {
                    self.apply_err = self.apply_err orelse Error.Io;
                    return self.apply_err.?;
                };
                const seq = self.wal_flusher.request(dupfd);
                for (self.active_set.persist_ack.items) |g| {
                    if (self.groups.get(g)) |slot| slot.hib.persist_seq = seq;
                }
            }

            if (self.apply.commit_hook) |h| {
                for (self.commit_notify.items) |n| h.func(h.ctx, n.gid, n.origin, n.seq, n.idx);
            }
            self.commit_notify.clearRetainingCapacity();

            for (ready) |g| {
                var sctx: SendCtx = .{ .node = self, .group_id = g, .epoch = self.mgr.groupEpoch(g) };
                self.mgr.takeMessages(g, sendMsgCb, &sctx) catch {};
                self.mgr.release(g);
            }
        }
    } else if (ready.len > 0 or self.active_set.persist_ack.items.len > 0) {
        // ── Inline flush path (no flusher thread): the synchronous
        // append → fsync → ack → pass-2 round, kept for tests that drive
        // `pumpOnce` directly and expect propose→commit within one call.
        // Production runs the async path above (`Bridge.startPump` starts
        // the flusher). ──
        self.commit_notify.clearRetainingCapacity();
        // Pass 1: append this round's writes (BUFFERED — the fsync is
        // below) and apply committed entries that were already durable
        // from earlier cycles (raft gates handed-out committed entries
        // on its persist watermark). Every processed ready is queued
        // for the post-fsync ack.
        for (ready) |g| {
            self.mgr.processReady(g, applyCb, self) catch |e| {
                self.apply_err = self.apply_err orelse mapRaftErr(e);
            };
            self.notePersistAck(g);
        }

        // ONE fsync per cycle regardless of how many groups committed.
        // Inline-path only: here the sends below do wait on the fsync, so
        // the stall probe stays (the async path's probe lives in the
        // flusher thread).
        const flush_t0 = nowNs();
        const flushed = blk: {
            self.wal.flush() catch {
                self.apply_err = self.apply_err orelse Error.Io;
                break :blk false;
            };
            break :blk true;
        };
        const flush_us = @divTrunc(nowNs() - flush_t0, std.time.ns_per_us);
        if (flush_us > 5000)
            std.log.warn("wal fsync took {d}us at={d}", .{ flush_us, std.time.milliTimestamp() });

        if (flushed) {
            // Persist ack (the async-append handshake): the fsync now
            // covers every buffered append, so tell raft — this is the
            // point this node's entries start counting toward the
            // commit quorum, and it releases the stashed persistence-
            // asserting messages (append acks / vote responses) into
            // the outboxes. On a failed flush the list is RETAINED:
            // no ack, no acks on the wire, commits stay locked until
            // a later successful fsync — never durability claimed for
            // volatile bytes.
            for (self.active_set.persist_ack.items) |g| {
                self.mgr.onPersist(g);
                if (self.groups.get(g)) |slot| slot.hib.in_persist_ack = false;
            }
            self.active_set.persist_ack.clearRetainingCapacity();

            // Pass 2: the acks commonly unlock a commit advance — the
            // newly-committed entries surface as fresh readies. Apply
            // them NOW so a single-node propose still commits within
            // one pump cycle. Anything pass 2 buffers (typically the
            // advanced commit index riding the next hard state) is
            // covered by the NEXT cycle's fsync+ack — pass-2 groups
            // re-enter `persist_ack`, and the `persist_ack.items.len`
            // arm of the enclosing `if` guarantees that next round
            // runs even if nothing else is ready.
            ready2 = self.mgr.pollReady(self.ready_buf2);
            for (ready2) |g| {
                self.mgr.processReady(g, applyCb, self) catch |e| {
                    self.apply_err = self.apply_err orelse mapRaftErr(e);
                };
                self.notePersistAck(g);
            }

            // Fire the commit hook ONLY now: the hook advances the
            // per-tenant watermark the worker acks clients on. Pass-1
            // applies were durable before this cycle; pass-2 applies
            // are covered by this cycle's fsync. On flush failure the
            // notifications are DROPPED: parked workers time out →
            // 503, the correct "unknown outcome" signal (never a
            // false durable ack).
            if (self.apply.commit_hook) |h| {
                for (self.commit_notify.items) |n| h.func(h.ctx, n.gid, n.origin, n.seq, n.idx);
            }
        }
        self.commit_notify.clearRetainingCapacity();

        // Drain each ready group's outbox (both passes; `release` is
        // dup-tolerant and re-notifies if work landed mid-round).
        // Single-node: queued to a transport-less sink (a no-op).
        // Multi-node: buffered per destination node, stamped with the
        // group's migration epoch, for the coalesced flush below. (No
        // cross-node compaction floor is sent — mechanism-A compaction is
        // per-node; there is no floor wire field.)
        for (ready) |g| {
            var sctx: SendCtx = .{ .node = self, .group_id = g, .epoch = self.mgr.groupEpoch(g) };
            self.mgr.takeMessages(g, sendMsgCb, &sctx) catch {};
            self.mgr.release(g);
        }
        for (ready2) |g| {
            var sctx: SendCtx = .{ .node = self, .group_id = g, .epoch = self.mgr.groupEpoch(g) };
            self.mgr.takeMessages(g, sendMsgCb, &sctx) catch {};
            self.mgr.release(g);
        }
    }

    const now = nowNs();

    // Always drive the transport (multi-node): flush this cycle's
    // coalesced sends, then a non-blocking tick that submits them and
    // delivers any inbound envelopes (→ stepBatch). Done every cycle —
    // not just when a group committed — so heartbeats/elections flow
    // and inbound messages are stepped even on an otherwise idle node.
    if (self.transport) |t| {
        t.flush();
        t.tick(now, 0) catch |e| {
            // A transport tick failure is a silent partition in the
            // making (nothing sent or received this cycle) — log it
            // rate-limited so a persistently broken transport is
            // operator-visible instead of an unexplained quorum loss.
            self.transport_err_count +%= 1;
            if (self.transport_err_count == 1 or self.transport_err_count % 1000 == 0) {
                std.log.warn(
                    "v2 node {d}: transport tick failed ({s}) — {d} failures so far",
                    .{ self.node_id, @errorName(e), self.transport_err_count },
                );
            }
        };
        // Wake any group that received a NON-heartbeat message this cycle
        // (real raft traffic = work). Heartbeats are skipped on purpose
        // (§3.1) so a quiet group can't keep itself awake.
        self.active_set.woke_scratch.clearRetainingCapacity();
        t.drainWoke(&self.active_set.woke_scratch, self.allocator) catch {};
        for (self.active_set.woke_scratch.items) |gid| self.bumpActive(gid) catch {};
    }

    // Hibernate: stop ticking any group idle past its deadline (but keep a
    // leaderless group ticking so it can recover — see `sweepHibernated`).
    self.sweepHibernated(now);

    // Wake-to-elect: force-campaign any group wedged leaderless past the
    // escalation window, bypassing peers' check_quorum leases (TiKV-style
    // hard-failover recovery — see `escalateLeaderless`).
    self.escalateLeaderless(now);

    // Leader-side auto-demote: drop a far-behind, presumed-dead voter to a
    // learner so it stops pinning the WAL-compaction floor. Before the
    // durabilize so a demote's higher floor takes effect this same tick.
    self.autoDemoteTick(now);

    // Checkpoint: fold each dirty store's overlay into LMDB + stamp its
    // watermark + (single-node) compact the WAL. Interval-gated, O(dirty).
    self.durabilizeTick(now);

    if (self.apply_err) |e| {
        self.apply_err = null;
        return e;
    }
    return ready.len > 0 or ready2.len > 0 or acked_any;
}

/// Async-fsync mode: `onPersist` every awaiting group whose latest append
/// is covered by the flusher's completed fsync (`persist_seq ≤ completed`)
/// and drop it from the awaiting list; later appends (a higher stamp) wait
/// for their covering completion. A destroyed group's stale entry is
/// dropped without an ack. Returns whether anything was acked (work — the
/// released acks / unlocked commits surface via the ready channel).
/// Pump-thread only.
fn ackCovered(self: *Node, completed: u64) bool {
    var acked = false;
    var i: usize = 0;
    while (i < self.active_set.persist_ack.items.len) {
        const gid = self.active_set.persist_ack.items[i];
        const slot = self.groups.get(gid) orelse {
            _ = self.active_set.persist_ack.swapRemove(i);
            continue;
        };
        if (slot.hib.persist_seq <= completed) {
            self.mgr.onPersist(gid);
            slot.hib.in_persist_ack = false;
            _ = self.active_set.persist_ack.swapRemove(i);
            acked = true;
            continue;
        }
        i += 1;
    }
    return acked;
}

/// Checkpoint dirty stores. Interval-gated. For each group with
/// committed-but-not-durable writes,
/// fold its overlay into LMDB + stamp `lastAppliedRaftIdx` (one atomic
/// durabilize), then compact the shared WAL so the log stays bounded.
/// Compaction is mechanism A (raft-native-alignment §I4): truncate to a FIXED
/// catch-up buffer (`snapshot_grace`) below the durable apply watermark, PER
/// NODE INDEPENDENTLY — no cross-node min-match floor, no lockstep, no
/// leader/follower asymmetry. A peer within the buffer catches up from the
/// log; a peer further back trips raft's `StateSnapshot` and is recovered by
/// the out-of-band snapshot catch-up driver. Pump-thread only. All dirty
/// groups are flushed in one tick so the shared WAL's interleaved commits
/// clear together.
pub fn durabilizeTick(self: *Node, now: i64) void {
    if (self.active_set.dirty.items.len == 0) return;
    if (now - self.last_durabilize_ns < self.durabilize_interval_ns) return;
    self.last_durabilize_ns = now;
    // Under the async-append flow the durable HardState.commit lags
    // the live commit by one fsync (it rides the NEXT ready's hard
    // state). Compaction must never truncate past a commit index that
    // is not yet durable — a crash right after the truncate would
    // recover hs.commit < first_index-1 and panic `RawNode::new`. One
    // flush before the first compact of the tick closes the lag; lazy
    // so a tick that compacts nothing pays nothing.
    var compaction_flushed = false;
    // Iterate with a retain cursor: a slot whose fold could not reach
    // `applied_idx` this tick (durabilize floor below it, or a fold
    // error) STAYS dirty so a later tick finishes the job — without
    // this, a one-shot stamp left the un-foldable tail volatile
    // forever (an idle tenant's last write never re-folded).
    var keep: usize = 0;
    for (self.active_set.dirty.items) |gid| {
        const slot = self.groups.get(gid) orelse continue;
        // The fold target: how far the store's overlay actually covers.
        // In worker_overlay mode a skipped entry's writes sit in the
        // worker's OPEN txn until the worker acks (`noteWorkerCommitted`)
        // — folding/stamping/compacting past it would claim durability
        // for data the fold cannot see (crash ⇒ acked write lost, WAL
        // already truncated). The bridge's floor is `maxInt` when
        // nothing is awaited.
        var target = slot.applied_idx;
        if (self.apply.durabilize_floor) |f| target = @min(target, f.func(f.ctx, gid));
        // Mechanism-A WAL compaction (raft-native-alignment §I4): truncate to
        // a FIXED catch-up buffer below the durable apply watermark, PER NODE
        // INDEPENDENTLY — no cross-node min-match floor, no propagated floor,
        // no leader/follower asymmetry. A peer within `snapshot_grace` of the
        // cap catches up from the log; a peer further back trips raft's
        // `StateSnapshot` and is recovered out-of-band by the snapshot
        // catch-up driver (the `snapshotTriggerTick` → `SnapshotCatchupThread`
        // path). The fixed buffer is the bound: a dead/stuck peer falls out of
        // it and snapshots rather than pinning the WAL. Constrains only
        // truncation; the LMDB fold of the full applied tail above is
        // unaffected.
        const compact_target = target -| self.snapshot_grace;
        if (target <= slot.durabilized_idx) {
            // Nothing foldable yet — keep the slot dirty and retry
            // next tick (the worker ack raises the floor).
            self.active_set.dirty.items[keep] = gid;
            keep += 1;
            continue;
        }
        const store = self.storeFor(slot, slot.id_str) orelse {
            // Resolver failure — retry next tick rather than
            // stranding an in_dirty=true slot outside the list.
            self.active_set.dirty.items[keep] = gid;
            keep += 1;
            continue;
        };
        store.setLastAppliedRaftIdx(target) catch |e| {
            std.log.warn("v2 durabilize gid={d}: {s}", .{ gid, @errorName(e) });
            self.active_set.dirty.items[keep] = gid;
            keep += 1;
            continue;
        };
        // Compact when enabled (single-, leader-, and follower-side alike;
        // each node truncates to its own `target − snapshot_grace`). Skip
        // when `compact_target` is 0 (a group still below the catch-up
        // buffer) so it doesn't trigger the pre-compact flush.
        if (self.compact_wal and compact_target > 0) {
            if (!compaction_flushed) {
                self.wal.flush() catch |e| {
                    // Can't make the commit index durable — skip ALL
                    // compaction this tick (the stamp above already
                    // happened, which is fine: durabilize ≠ truncate).
                    std.log.warn("v2 wal pre-compact flush: {s}", .{@errorName(e)});
                    slot.durabilized_idx = target;
                    if (slot.applied_idx > target) {
                        self.active_set.dirty.items[keep] = gid;
                        keep += 1;
                    } else slot.hib.in_dirty = false;
                    continue;
                };
                compaction_flushed = true;
            }
            // Truncate to `compact_target` (≤ `target`): the leader's
            // min-match floor keeps the log entries lagging followers still
            // need. No-op when `compact_target` is at/below the current
            // sentinel.
            slot.gfs.compact(compact_target) catch |e| {
                std.log.warn("v2 wal compact gid={d}: {s}", .{ gid, @errorName(e) });
            };
        }
        slot.durabilized_idx = target;
        if (slot.applied_idx > target) {
            // Partially folded (floor held back the tail): stay dirty.
            self.active_set.dirty.items[keep] = gid;
            keep += 1;
        } else {
            slot.hib.in_dirty = false;
        }
    }
    self.active_set.dirty.shrinkRetainingCapacity(keep);
}

/// Leader-side auto-demote policy. For each group this
/// node leads with un-durabilized writes (so the log is actively advancing
/// and a dead voter is pinning the WAL floor), demote the first voter that
/// is BOTH far behind (`lag > auto_demote_lag`) AND `!recent_active` to a
/// learner — it can no longer form quorum anyway, so this loses no real
/// availability while unpinning `minMatchIndex` so the WAL truncates. At most
/// one demote per group per pass (a raft conf-change must commit before the
/// next is proposed). Interval-gated + warmup-skipped so a freshly-started or
/// freshly-elected leader gives peers a window to check in first. Gated on
/// `compact_wal` (the only benefit is unpinning compaction) and a non-zero
/// `auto_demote_lag`. Pump-thread only.
pub fn autoDemoteTick(self: *Node, now: i64) void {
    if (self.auto_demote_lag == 0 or !self.compact_wal) return;
    if (self.active_set.dirty.items.len == 0) return;
    // Warmup: the first pass after start/elect just stamps the clock and
    // returns, so peers get a full interval to report in before we judge
    // them dead (`last_auto_demote_ns` starts at 0 ⇒ would fire immediately).
    if (self.last_auto_demote_ns == 0) {
        self.last_auto_demote_ns = now;
        return;
    }
    if (now - self.last_auto_demote_ns < self.auto_demote_interval_ns) return;
    self.last_auto_demote_ns = now;

    var ids_buf: [16]u64 = undefined;
    var matched_buf: [16]u64 = undefined;
    var active_buf: [16]u8 = undefined;
    var prog_buf: [16]raft.Manager.VoterProgress = undefined;
    for (self.active_set.dirty.items) |gid| {
        if (!self.mgr.isLeader(gid)) continue;
        const view = self.mgr.voterProgress(gid, &ids_buf, &matched_buf, &active_buf, &prog_buf) orelse continue;
        for (view.peers) |p| {
            if (p.recent_active) continue; // still in contact — keep it
            const lag = view.leader_last -| p.matched;
            if (lag <= self.auto_demote_lag) continue;
            // Demote this dead, far-behind voter to a learner. One per group
            // per pass; the FFI quorum-guard refuses a demote that would drop
            // below 2 voters (swallowed — expected, not an error here).
            self.mgr.proposeConfChange(gid, p.id, .add_learner, "") catch |e| switch (e) {
                raft.Error.ConfChangeQuorumGuard => {
                    std.log.debug("v2 auto-demote gid={d} node={d}: refused (would drop below 2 voters)", .{ gid, p.id });
                    break;
                },
                else => {
                    std.log.warn("v2 auto-demote gid={d} node={d}: propose failed: {s}", .{ gid, p.id, @errorName(e) });
                    break;
                },
            };
            std.log.info(
                "v2 auto-demote gid={d}: voter {d} demoted to learner (lag={d} > {d}, !recent_active) — unpinning WAL floor",
                .{ gid, p.id, lag, self.auto_demote_lag },
            );
            break; // one conf-change per group per pass
        }
    }
}

/// Enqueue `slot` for the next `durabilizeTick` if not already (its
/// `applied_idx` just advanced past `durabilized_idx`). Pump-thread only.
pub fn markDirty(self: *Node, slot: *TenantSlot) void {
    // Best-effort; on OOM the guard bit stays clear and recovery still
    // covers it (the fold retries once the group next commits).
    self.active_set.addDirty(slot, slot.tenant_id, self.allocator) catch {};
}


/// C-ABI apply callback: fires once per committed entry during
/// `processReady`. Decodes the envelope and routes it to the
/// tenant's store. Errors are stashed in `self.apply_err` (the
/// callback can't return one) and checked by `pump`.
fn applyCb(
    ud: ?*anyopaque,
    group_id: u64,
    index: u64,
    term: u64,
    data: [*c]const u8,
    len: usize,
) callconv(.c) void {
    _ = term;
    const self: *Node = @ptrCast(@alignCast(ud.?));
    if (self.apply_err != null) return; // already failed this round
    // raft-rs emits empty entries (e.g. the leader's no-op on
    // election). Nothing to apply.
    if (len == 0) return;
    const bytes = data[0..len];
    const frame = envelope.decodeEntryFrame(bytes) catch |e| {
        self.apply_err = e;
        return;
    };
    self.applyEntry(group_id, index, frame) catch |e| {
        self.apply_err = e;
        return;
    };
    // The entry committed + applied cleanly: STAGE the bridge
    // notification (advancing the tenant's committed_seq watermark).
    // `pump` fires it after the cycle's `wal.flush()` succeeds — the
    // watermark is the durable-ack signal, so it must not run ahead
    // of the fsync. Staged only on the success path, so the leader's
    // empty election no-op (len==0, returned above) and any
    // undecodable entry (apply_err, returned above) never advance a
    // tenant's watermark. A staging failure (OOM) is surfaced as an
    // apply error rather than silently losing the waiter's wakeup.
    if (self.apply.commit_hook != null) {
        self.commit_notify.append(self.allocator, .{
            .gid = group_id,
            .origin = frame.origin,
            .seq = frame.seq,
            .idx = index,
        }) catch {
            self.apply_err = Error.OutOfMemory;
        };
    }
}

pub fn applyEntry(self: *Node, group_id: u64, index: u64, frame: envelope.EntryFrame) Error!void {
    const env = try envelope.decode(frame.env_bytes);
    // Decide whether the pump writes the store, or only advances the
    // watermark (the worker's TrackedTxn.commit is the durable write).
    // `worker_overlay` keys this on PROVENANCE via the bridge's
    // `skip_query`: skip iff the entry is this node's own live propose
    // (origin matches and the seq's worker txn is still pending —
    // that txn IS the store write). Everything else is written by the
    // pump: a follower's replicated entries, a freshly-elected
    // leader's catch-up entries proposed elsewhere, a replayed entry
    // at recovery (no live txns at boot), and an entry whose local
    // waiter already gave up (fault/timeout rolled the txn back and
    // abandoned the seq).
    const skip_store = if (self.recovering)
        // Replaying the WAL at restart: there is no worker to have written
        // the store, so the pump MUST write it (and durabilize the tail).
        false
    else switch (self.apply.apply_mode) {
        .apply_on_commit => false,
        .leader_skip => true,
        .worker_overlay => blk: {
            if (self.apply.skip_query) |q|
                break :blk q.func(q.ctx, group_id, frame.origin, frame.seq);
            // No bridge (bare-node tests): the role-keyed skip.
            break :blk self.mgr.isLeader(group_id);
        },
    };
    if (skip_store) {
        // We still decode (above) so a stale/unknown envelope type
        // surfaces loudly, and bump applied_idx — but we do NOT touch
        // the store. Root writesets (no per-tenant group) are a no-op
        // here too; their durable write also rode the worker's txn. The
        // worker DID write its own overlay (inst.kv), so the group is still
        // dirty: `durabilizeTick` folds that overlay + stamps the watermark.
        //
        // The observer STILL fires, with `origin = true`: an engine-visible
        // key written by an activation (the `_deploy/current` release flip,
        // rove#719) has no door left to run its side effect on the
        // proposing node, and the pump is the one seam that sees every
        // committed entry. Origin lets each observer branch keep its
        // exactly-once story — see `ApplyObserver`. Only walked when an
        // observer is registered, so the no-observer cost stays zero.
        if (self.apply.apply_observer != null) {
            switch (env.type) {
                .writeset => {
                    if (envelope.decodeWriteSetPayload(env.payload)) |wp|
                        self.notifyApply(group_id, env.id, wp.ws_bytes, true)
                    else |_| {}
                },
                .multi => blk: {
                    const inner = envelope.decodeMultiInner(self.allocator, env.payload) catch break :blk;
                    defer self.allocator.free(inner);
                    for (inner) |inner_bytes| {
                        const ie = envelope.decode(inner_bytes) catch continue;
                        switch (ie.type) {
                            .writeset => {
                                if (envelope.decodeWriteSetPayload(ie.payload)) |wp|
                                    self.notifyApply(group_id, ie.id, wp.ws_bytes, true)
                                else |_| {}
                            },
                            // Nesting is rejected at encode; notify-only, so
                            // skip rather than fault (the entry already
                            // applied through the worker's own txn).
                            .multi => {},
                            .root_writeset => self.notifyApply(group_id, "", ie.payload, true),
                        }
                    }
                },
                .root_writeset => self.notifyApply(group_id, "", env.payload, true),
            }
        }
        if (self.groups.get(group_id)) |slot| {
            slot.applied_idx = index;
            self.markDirty(slot);
        }
        return;
    }
    const slot = self.groups.get(group_id) orelse return Error.UnknownGroup;
    switch (env.type) {
        .writeset => {
            const store = self.storeFor(slot, env.id) orelse return Error.UnroutedApply;
            // Strip the readset frame; apply the writeset bytes (the
            // readset rides for the tape, not the store).
            const wp = try envelope.decodeWriteSetPayload(env.payload);
            try writeset.applyEncodedDirect(store, index, wp.ws_bytes);
            self.notifyApply(group_id, env.id, wp.ws_bytes, false);
        },
        .multi => {
            const inner = try envelope.decodeMultiInner(self.allocator, env.payload);
            defer self.allocator.free(inner);
            for (inner) |inner_bytes| {
                const ie = try envelope.decode(inner_bytes);
                switch (ie.type) {
                    .writeset => {
                        // Inner writesets route by THEIR OWN id — an
                        // admin batch's cross-tenant trampoline inner
                        // (`proposeBatch` targets) names a tenant
                        // other than the anchor group's, and writing
                        // it into the anchor's store would corrupt
                        // both tenants on a follower / at recovery
                        // replay.
                        const store = self.storeFor(slot, ie.id) orelse return Error.UnroutedApply;
                        const wp = try envelope.decodeWriteSetPayload(ie.payload);
                        try writeset.applyEncodedDirect(store, index, wp.ws_bytes);
                        self.notifyApply(group_id, ie.id, wp.ws_bytes, false);
                    },
                    .multi => return envelope.Error.NestedMulti,
                    // A root inner (`platform.root.*` riding the admin
                    // batch). Raw writeset payload — root envelopes
                    // are not readset-framed.
                    .root_writeset => {
                        const store = self.storeFor(slot, "") orelse return Error.UnroutedApply;
                        try writeset.applyEncodedDirect(store, index, ie.payload);
                        self.notifyApply(group_id, "", ie.payload, false);
                    },
                }
            }
        },
        // A bare root writeset (rides the reserved root group, whose
        // slot id is `""` — so the no-resolver fallback in `storeFor`
        // routes it to that group's own slot store). Raw payload (no
        // readset frame).
        .root_writeset => {
            const store = self.storeFor(slot, "") orelse return Error.UnroutedApply;
            try writeset.applyEncodedDirect(store, index, env.payload);
            self.notifyApply(group_id, "", env.payload, false);
        },
    }
    // One entry applied (all inners included): advance the group's
    // applied index and queue it for the durabilize checkpoint.
    slot.applied_idx = index;
    self.markDirty(slot);
}

/// The store a committed writeset (or `multi` inner) targeting `id_str`
/// applies to. With a `store_resolver` set (the bridge fronting a
/// worker), the resolver routes by id — the worker's own per-tenant
/// serving store for a tenant id, the node-wide root store for `""` —
/// so a follower's replicated writes (including an admin batch's
/// cross-tenant inners) land in the SAME stores the worker serves from.
/// Without a resolver (the bare-node multi-node tests, the CP) only the
/// group's OWN id routes — to the slot
/// store; a cross-tenant or root target has nowhere to land and
/// surfaces as null (→ `UnroutedApply`, an invariant violation: those
/// producers only exist on worker-fronted nodes, which set a resolver).
pub fn storeFor(self: *Node, slot: *TenantSlot, id_str: []const u8) ?*KvStore {
    if (self.apply.store_resolver) |r| return r.func(r.ctx, slot.tenant_id, id_str);
    if (std.mem.eql(u8, id_str, slot.id_str)) return slot.store;
    return null;
}

/// Fire the `apply_observer` (if set) once per op in a just-applied
/// writeset. `id_str` is the tenant id the writeset targeted (the
/// inner's id for a multi inner, `""` for a root writeset). Re-decodes
/// the writeset bytes — cheap for the single-op writes the observers
/// care about. Best-effort: the bytes already applied cleanly via
/// `applyEncoded`, so a decode error here is not propagated (it would
/// only mean a stale projection, recovered on the next apply / restart
/// scan).
pub fn notifyApply(self: *Node, group_id: u64, id_str: []const u8, ws_bytes: []const u8, origin: bool) void {
    const obs = self.apply.apply_observer orelse return;
    var ops: std.ArrayListUnmanaged(writeset.Op) = .empty;
    defer ops.deinit(self.allocator);
    writeset.decodeOps(ws_bytes, self.allocator, &ops) catch return;
    for (ops.items) |op| switch (op) {
        .put => |p| obs.func(obs.ctx, group_id, id_str, .put, p.key, p.value, origin),
        // A delete carries no value; the observer decides what removal means
        // for its projection (the CP directory drops the row, so a follower
        // converges with the leader on a deprovision).
        .delete => |d| obs.func(obs.ctx, group_id, id_str, .delete, d.key, "", origin),
    };
}

/// Context for `sendMsgCb`: which group's outbox is being drained (so
/// each message carries its group id + migration epoch into the
/// coalesced envelope). Lives on the pump's stack for the takeMessages
/// call.
const SendCtx = struct {
    node: *Node,
    group_id: u64,
    epoch: u64,
};

/// `takeMessages` callback: buffer one outbound raft message into the
/// transport for its destination node. No-op when there is no transport
/// (single-node), so the single-node pump's drain stays a sink.
fn sendMsgCb(
    ud: ?*anyopaque,
    to: u64,
    msg_bytes: [*c]const u8,
    msg_len: usize,
) callconv(.c) void {
    const ctx: *SendCtx = @ptrCast(@alignCast(ud.?));
    const t = ctx.node.transport orelse return;
    const bytes = if (msg_len == 0) &[_]u8{} else msg_bytes[0..msg_len];
    t.queueOut(to, ctx.group_id, ctx.epoch, bytes);
}


/// Narrow a raft-rs error to the node's `Error` set (they overlap, but
/// `node_core.zig`'s `Error` union already includes `raft.Error`, so this is identity —
/// kept as a seam for when the two sets diverge).
fn mapRaftErr(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.ProcessReadyFailed,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

