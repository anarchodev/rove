# V2 multi-raft — scaling learnings from the rewind2 / raft-rs-zig prototype

> **Status / provenance.** These are findings from a multi-week prototype
> built in `~/src/rewind2` (testbed) on top of `~/src/raft-rs-zig` (a Zig
> wrapper over TiKV's raft-rs). The prototype was on branch
> `aria-stage1-adapter`; the broader *aria* (OCC drain) experiment it rode
> along with is **not** merging — the OCC throughput gains didn't justify
> the complexity. But the raft-rs wrapper and the multi-node scaling work
> are the keeper, because **rewind2 turned out to be a working prototype of
> the exact V2 substrate this codebase has already committed to** (see
> `docs/v2-vendoring-spike.md` and the V2 direction locked 2026-05-16:
> per-tenant raft groups on raft-rs, CP/DP split, shared-fsync segmented
> log, no-downtime migration).
>
> This doc exists to feed measured numbers into the V2 multi-raft decision
> before V2 writes code. All numbers are AMD EPYC 7313 (16P/32T), btrfs +
> NVMe (PM9A3), 3-node simulated cluster, unless noted. Commit hashes are
> in the appendix.
>
> **Important caveat about the bench.** rewind2 simulates the network
> in-process (`netsim`), so "throughput" numbers measure the *consensus +
> apply pipeline* on one box, not real cross-node latency. They are valid
> for reasoning about per-node CPU/fsync/allocator ceilings and the *shape*
> of multi-raft scaling. They are not WAN numbers.

---

## TL;DR for V2

1. **The V2 substrate shape is sound and was prototyped end-to-end.**
   raft-rs hosting one group per tenant, a single shared per-node WAL with
   one fsync per pump cycle, per-recipient transport coalescing, and a
   detach/attach tenant-migration primitive all work and compose. The
   2026-05-16 instincts (shared fsync, raft-rs's stateless step/tick,
   per-tenant groups) were validated.

2. **Multi-raft buys migration, not throughput.** At realistic handler
   costs (100 µs–1 ms/request) the binding constraint is the *apply pool*,
   not raft consensus. Consensus is nowhere near the bottleneck. Do not
   sell V2 internally as a throughput win — sell it as no-downtime
   migration + per-tenant blast-radius. The throughput story is "no
   worse, and architecturally cleaner."

3. **The FFI surface sketched in `v2-vendoring-spike.md` is single-group
   and will not survive K=10k tenants as written.** It needs three things
   the sketch lacks: a *mailbox/ready-channel* so `poll_ready` is O(active
   groups) not O(K); *batched* tick/step entry points; and a *hibernation*
   policy (heartbeats must not keep idle tenants awake). All three are
   detailed below — they were the difference between 5.8k and 540k r/s.

4. **The single biggest surprise was the allocator.** Zig's default
   `GeneralPurposeAllocator(.{})` has a global mutex that became *the* wall
   under multi-threaded multi-raft — swapping to `c_allocator` gave 3.7×
   (540k → 1.98M r/s) on its own. **rove already uses `c_allocator`
   globally, so V1 is clear of this** — but V2 must keep it AND give the
   Rust raft-rs shim a real allocator (jemalloc/mimalloc), exactly as TiKV
   ships jemalloc. See §3.6.

5. **Migration's hard parts are the CP's job, and we left them as stubs.**
   The detach/attach *mechanism* works; *quiesce* (pause proposes during
   the move) and *raft-log carry-over* (we ship committed state only, dest
   starts a fresh group) are deferred — and they map precisely onto the
   CP-orchestrated `relinquish`/`acquire` handshake V2 already describes.
   See §4.

---

## 1. rewind2 *is* the V2 substrate (decision → artifact map)

Every locked V2 decision has a corresponding thing we actually built and
measured. This is the main reason the prototype is worth reading.

| V2 decision (locked 2026-05-16) | What rewind2 / raft-rs-zig built | Verdict |
|---|---|---|
| **raft-rs as the engine** (stateless step/tick, multi-raft-native) | `raft-rs-zig`: a `Manager` hosting N `RawNode`s behind a C ABI; `step`/`tick`/`propose`/`process_ready` per group | Works. The stateless API is genuinely the right shape for multi-group; willemt's one-instance-per-process model could not do this. |
| **Per-tenant raft groups, 1:1 not N:1** | `tenant_id == group_id` throughout; bags are always single-tenant | Works and is load-bearing for migration. No N:1 batching temptation survived contact. |
| **Segmented log, shared fsync** | `SharedWal` + `GroupedFileStorage`: all groups on a node interleave into one append-only file, **one `flush()` per pump cycle** | Works and is *the* enabling constraint (§3.2). Per-group fsync craters past K=4. |
| **No-downtime migration via membership change** | `detachGroup(tenant) → bundle` / `attachGroup(bundle)` + `clearTombstone` across nodes | Mechanism works; quiesce + log carry-over deferred to CP (§4). |
| **CP/DP split, DPs are N independent clusters** | "multi-pump" bench: N independent sub-clusters partitioned by `tenant % N` | Sharding helps sub-linearly then regresses — but the wall was the allocator, not the shape (§3.8). |
| **raft-rs vendored, prost-codec, panic=abort** | raft-rs-zig vendors `raft 0.7` but with **protobuf-codec** (protobuf 2), not prost | Codec delta to reconcile (§6). Wrapper logic transfers unchanged. |

If V2 starts from `v2-vendoring-spike.md`'s FFI sketch, treat raft-rs-zig
as the reference implementation one layer up: the sketch is per-node, the
wrapper is per-*Manager*-of-many-groups, and that gap is where all the
scaling lives.

---

## 2. The headline scaling result

Cumulative progression on the K=10,000-tenant Zipf (α=1.0) workload — the
worst case V2 cares about (10k mostly-idle tenants, hot skew on a few).
Each row is one change stacked on the previous.

| Step | Commit | r/s | Cumulative | What it was |
|---|---|---|---|---|
| Baseline | — | 5,800 | 1.0× | naive: tick all K, fsync per group, GPA, heartbeats keep everyone awake |
| Heartbeat hibernation | `73702c7` | 7,900 | 1.4× | don't bump activity on heartbeats (§3.1) |
| Transport coalescing | `64d4dad` | 13,600 | 2.35× | one envelope per recipient per cycle (§3.3) |
| Batched-step FFI | `335c1b7` | 13,600 | 2.35× | **neutral** — kept for cleanliness (§3.5) |
| Workload shape (work_ns=0) | `122bc79` | 340,000 | 59× | *removed handler work* — exposes raw consensus ceiling (§3.7) |
| Multi-pump N=2 | `18b00d9` | 540,000 | 93× | 2 independent sub-clusters (§3.8) |
| **`c_allocator`** | `8ab54db` | **1,980,000** | **340×** | swap GPA → libc malloc (§3.6) |

**How to read this honestly.** The 59× jump is *not* an optimization —
it's setting handler work to zero to measure the consensus ceiling. At
**realistic** handler costs the achievable number is far lower and
apply-pool-bound (§3.7). The genuinely transferable engineering wins are
the heartbeat fix, coalescing, the shared WAL, and the allocator. The
93×/340× cumulative figures are "what the pipeline can do when nothing
real is happening," useful only as a headroom ceiling.

---

## 3. The learnings, tagged for V2

Each tagged: **[V2 MUST DO]**, **[CONFIRMS V2 INSTINCT]**, **[V2 CAN
SKIP / DON'T OVERINVEST]**, or **[SURPRISE]**.

### 3.1 Heartbeats must not defeat hibernation — **[V2 MUST DO]**

This is the single most important K=10k finding, and it is *invisible*
until you actually run thousands of groups.

With one raft group per tenant, every group exchanges heartbeats at tick
rate to maintain liveness. The naive implementation bumped a tenant's
"active" timer on *every* inbound message — including heartbeats. Result:
a self-feeding loop where every group kept itself awake via its own
keep-alive traffic. The active set never shrank, the pump ticked all 10k
groups every cycle, and ~68% of all routed messages were heartbeats. The
pump ran at **4 cycles/sec** with 238 ms per cycle.

The fix is five lines: skip the activity bump for `MsgHeartbeat` (8) and
`MsgHeartbeatResponse` (9). This is TiKV's canonical rule — a heartbeat
means "don't elect me," not "I have work."

```zig
// detect at the protobuf wire-format level — codec-independent
inline fn isHeartbeatLike(bytes: []const u8) bool {
    if (bytes.len < 2) return false;
    if (bytes[0] != 0x08) return false;   // eraftpb.Message field 1 (msg_type), varint tag
    return bytes[1] == 8 or bytes[1] == 9; // MsgHeartbeat / MsgHeartbeatResponse
}
```

(Note: this byte test is on the eraftpb wire format, so it survives the
protobuf-codec → prost-codec switch V2 plans — same bytes either way.)

Measured: active_set 10,476 → **79**; pump 4 → **1,248 cycles/sec**;
cycle wall 238 ms → **1.0 ms**; throughput **2.15×**.

**For V2:** the planned `rove_raft_config_t` exposes `check_quorum` and
`pre_vote` but has no hibernation concept. V2's DP layer needs, above the
FFI: (a) an active-set the dispatcher maintains, (b) `bumpActive` on
proposes and on *non-heartbeat* inbound steps only, (c) tick only the
active set. Also two related pitfalls we hit:
- **Don't pre-seed the active set at init.** Seeding all K tenants with a
  hibernate deadline loaded the first second of every run with K-wide tick
  cost. Let elections drive via the mailbox; let workload populate the
  active set lazily. (3× on the K=10k ON path on its own.)
- A coarser `tickAll` is fine at K≤~1k; the active-set machinery only
  earns its keep at thousands of groups. But V2's target *is* thousands,
  so build it in.

### 3.2 One fsync per cycle / shared WAL is load-bearing — **[CONFIRMS V2 INSTINCT]**

V2 already wants "segmented raft log (shared fsync, per-fd cost goes
away)." This is correct and it is the constraint that makes multi-tenant
raft viable at all. We built `SharedWal`: all groups on a node append
(interleaved) into one file; the dispatcher calls `flush()` **once per
pump cycle**, regardless of how many groups committed. K fsyncs per cycle
would (and in an early version did) collapse throughput past K=4.

Record format extends the etcd-style single-group format with a group id:
`[tag:u8][group_id:u64 LE][payload_len:u32 LE][payload][crc32:u32 LE]`,
so the interleaved stream is a sequence of `(group_id, record)` tuples.

**For V2, two warnings from the v1 implementation:**
- **Tail-truncate is the hard part of a shared WAL.** When raft rewrites
  an uncommitted suffix for *one* group, you cannot physically rewind the
  shared file — other groups have appended past that point. Our v1 shrinks
  the per-group offset map but leaves orphan bytes in the file. That means
  **replay must dispatch by `group_id` and keep the last authoritative
  entry per group** — it is not a linear truncate. V2's segmented-log
  design needs to plan for this from the start (segment GC + per-group
  compaction watermark), not bolt it on.
- raft-rs-zig's WAL has **no replay-from-existing path yet** (it truncates
  on init). That's a prototype shortcut; V2 obviously needs real recovery.
  Listed so nobody assumes the prototype proves crash-recovery — it
  doesn't.

### 3.3 Transport coalescing (per-recipient envelopes) — **[V2 MUST DO]**

raft-rs hands you per-group outbound messages. If you ship one network
send per group-message, a node with K active groups talking to its 2 peers
emits O(K) sends per cycle. The fix is TiKV's `BatchRaftMessage`: bucket
outbound messages by *recipient node*, emit **one envelope per recipient
per cycle** carrying all groups' messages, decompose on the receiving
side. Messages/cycle drops from O(K) to O(cluster_size).

Gain: 3.3× on the high-message-count arm (13.6k r/s, up from the
heartbeat-fixed 7.9k). It also halved init time (the K=10k startup
election storm coalesces too).

**For V2:** this lives in the DP transport (rove's `raft_net.zig`
equivalent), *not* in the FFI. The FFI just needs to let you drain a
group's outbox and step a batch in (see §3.4). One subtle bug it exposed,
worth pre-empting: once you stop serializing every message through a
per-message network mutex, a pre-existing TOCTOU race in the
apply-completion bookkeeping became reachable (two nodes committing the
same entry in one cycle, both firing the apply callback, racing on the
per-tenant pending-handle FIFO). **Coalescing removes incidental
serialization that may be masking races elsewhere** — audit shared
mutable state on the apply path when you land it. We fixed it with a lock
around the (lookup + len-check + pop) sequence.

### 3.4 The FFI must be mailbox-driven, not poll-all — **[V2 MUST DO]**

The original raft-rs-zig design iterated all K groups every cycle to find
the ones with work. At K=10k that O(K) scan *is* the wall. The fix is a
mailbox + ready-channel inside the Rust shim:

- Each group slot has an atomic state: `IDLE / NOTIFIED / DROP`.
- Every work-producing op (`propose`/`step`/`campaign`/`tick`-with-output)
  CAS-flips `IDLE → NOTIFIED` and, on success, pushes the group id onto a
  `Mutex<VecDeque<u64>>`.
- `poll_ready(buf, cap)` drains the queue — **O(returned), not O(K)**.
- `release(group_id)` returns the slot to `IDLE` and re-notifies if work
  landed mid-round (closes the obvious race).

This is TiKV's batch-system shape. It is also the thing the
`v2-vendoring-spike.md` FFI sketch is missing entirely: that sketch is
`rove_raft_node_t` per node with `tick`/`step`/`process_ready` — fine for
one group, O(K) for many. **V2's Rust shim should expose a Manager of many
groups with `poll_ready`/`release`, not a node-at-a-time API.** Concretely
the wrapper's surface that the sketch should grow toward:

```
poll_ready(buf, cap) -> count      // drain ready group ids
process_ready(group_id, apply_cb)  // apply one ready group
release(group_id)                  // return to IDLE, re-notify on race
take_messages(group_id, msg_cb)    // drain outbox after ready
tick_groups([]group_id) -> count   // batched tick of active set
step_batch([]{group_id,ptr,len})   // batched inbound (see §3.5)
```

`tick_groups` matters at scale because per-call `tick(group)` FFI overhead
dominates past ~1k groups — batching the tick into one FFI call that
iterates Rust-side is a real win (unlike `step_batch`, see next).

### 3.5 `step_batch`: structural correctness ≠ throughput — **[V2 CAN SKIP / DON'T OVERINVEST]**

We predicted batching the inbound `step` FFI (one call per recipient
envelope instead of one per message) would compound for 1.5–2×. Measured:
**0×, within noise**, even on the high-message arm.

Why the prediction was wrong: the per-message cost we'd measured
pre-coalescing (~12 µs) was *netsim machinery* (per-message alloc/dup,
insertion-sort, callback dispatch), not the FFI boundary. Coalescing
already amortized those to near-zero. What's left in `step` is **Rust-side
protobuf decode + raft state update**, which happens N times regardless of
whether the N messages ride in one FFI call or N. The Zig↔C↔Rust boundary
itself is sub-µs.

We kept `step_batch` (it's the natural pair of `tick_groups` and makes the
API symmetric), but it bought nothing.

**For V2, two lessons:** (1) batch `tick` (real win — per-call overhead ×
thousands of idle groups) but don't expect batching `step` to move
throughput; the cost is in the codec, not the boundary. (2) If you ever
*do* become decode-bound (1M+ msg/s), the fix is Rust-side (faster codec /
known-format fast path), still not FFI batching. This is also a small
point in favor of V2's **prost-codec** choice over protobuf-codec — prost
decode is the thing that actually costs, so the faster codec is the lever,
not the FFI shape.

### 3.6 The allocator wall — **[SURPRISE] / [V2 MUST DO]**

The most expensive lesson of the whole exercise, and the least obvious.

After sharding (§3.8) plateaued at 540k r/s, a multi-hour investigation
ruled out ~10 hypotheses (lock contention via source instrumentation,
per-tenant FIFO under skew, sync vs async dispatch, disk via tmpfs, client
count, apply-pool size, shared Manifest, raft-rs per-entry CPU via
flamegraph...). The actual wall: **Zig's `GeneralPurposeAllocator(.{})` is
thread-safe via a single global mutex** (safety-mode default). Under N
pump threads + fanout workers + apply workers all allocating, that mutex
serialized everything.

One-line fix — `std.heap.c_allocator` — gave **540k → 1.98M r/s (3.7×)**
at work_ns=0. This is the same architectural reason TiKV ships jemalloc as
its Rust global allocator.

**For V2:**
- **rove already uses `c_allocator` globally** (`src/loop46/main.zig`,
  `src/blob/curl.zig`), so V1 is clear of this trap. V2 inherits that —
  *keep it*, don't reintroduce GPA on any hot multi-raft path.
- The rewind2 bench went one step further: `c_allocator` routes through
  libc malloc, so `LD_PRELOAD=libmimalloc.so`/`libjemalloc.so` can
  substitute a thread-local-arena allocator transparently (GPA pulls from
  mmap and bypasses libc, so LD_PRELOAD can't see it). V2 should plan to
  run under jemalloc/mimalloc in production.
- **The Rust raft-rs shim has its own global allocator.** Under multi-raft
  it allocates per-message (protobuf decode) and per-ready-cycle. Set a
  `#[global_allocator]` (jemalloc/mimalloc) in the FFI crate, or ensure
  the LD_PRELOAD covers it. The `v2-vendoring-spike.md` Cargo.toml doesn't
  mention an allocator — add it.
- **Process lesson:** swap the allocator *before* a long contention
  investigation. It's a one-line probe that would have saved the hours we
  spent. (Already captured in memory as a standing rule.)

### 3.7 Multi-raft consensus is not the throughput bottleneck — **[CONFIRMS V2 INSTINCT, with a caveat]**

The 59× jump in the headline table came purely from setting
`handler_work_ns = 0`. Read the other direction: **at realistic handler
costs the apply pipeline, not raft, is the binding constraint.**

Direct stage breakdown of one bag (work=0, the consensus-ceiling case):

| Stage | % of bag latency |
|---|---|
| dispatch → propose (inbox dwell) | 7% |
| propose → commit (raft consensus) | 25% |
| commit → apply (apply-queue dwell) | **50%** |
| apply work (the actual puts) | 18% |

And realistic-workload sweeps (work ~ U[100µs, 1ms]) show throughput
scaling with **apply-worker count**, capped at roughly `W × per-request
rate`, with `W = physical core count` the safe default (SMT oversubscribe
collapses it — W=32 on a 16P box was 3.6× *worse* than W=16). Zipf vs
uniform load made only a 9% difference — so per-tenant FIFO queueing under
skew is *not* the dominant mechanism either; the dwell is raft pipeline
depth + apply scheduling.

**For V2 this is the most important strategic input:** multi-raft does not
make the system faster at OLTP-shaped work. It makes consensus *cheaper
per tenant* and makes migration possible. The throughput ceiling is set by
how fast you can *apply* committed entries (kvexp puts + handler work),
which is the same whether you have one raft group or ten thousand. Budget
V2 effort accordingly: spend on the apply path (pool sizing, lock-free
apply queue, io_uring WAL) for throughput; spend on multi-raft for
migration and isolation.

### 3.8 Sharding (DP = N independent clusters) tops out sub-linearly — **[CONFIRMS V2 INSTINCT, bounded]**

V2's CP/DP split makes each DP an independent cluster. We validated this
shape with "multi-pump": N independent sub-clusters, tenants partitioned
`tenant % N`. Results (work=0): N=1 → 334k, N=2 → 534k (1.6×), N=4 → 521k
(plateau), N=8 → 357k (regression). The regression past N=4 was the
contention signature that led to the allocator finding (§3.6) — *after*
the `c_allocator` fix the per-shard story is healthier, but we did not
re-run the full N-sweep post-fix.

**For V2:** independent DP clusters are the right horizontal-scale axis,
but a single box won't scale linearly with sub-clusters because they
contend on shared-runtime resources (allocator, scheduler, cache lines).
The real horizontal scaling is *across machines* (one DP cluster's nodes
on different hosts), which the in-process bench can't measure. Don't
over-shard within a box; one DP's pump should own a generous slice of
tenants, and you add DPs by adding machines.

---

## 4. Migration — we built the forcing-function primitive

No-downtime tenant migration is *the* reason V2 exists. We built and
tested the mechanism end to end:

- `detachGroup(tenant) → bundle`: dump the tenant's committed KV state to
  a self-describing byte bundle (magic + version + tenant + KV pairs +
  CRC32), `destroyGroup` on all nodes, remove from the dispatcher, free
  pending handles.
- `attachGroup(bundle)`: load the bundle, `clearTombstone`, `createGroup`
  on each node with fresh storage, campaign, drive to leader.
- Tested: same-dispatcher round-trip, cross-dispatcher migration,
  duplicate-attach rejection, unknown-tenant detach rejection.

**`clearTombstone` is a real requirement, flag it for the FFI.** raft-rs
tombstones a destroyed group id by default (correctly — it prevents
zombie messages from reviving a dead group). Migration is *intentional*
reuse of an id, so you need an explicit escape hatch to lift the
tombstone. The `v2-vendoring-spike.md` FFI sketch has no
destroy/tombstone/clear at all (it's per-node lifecycle) — add
`destroy_group` / `clear_tombstone` to the Manager surface.

**What we deferred is exactly the CP's job.** Two pieces are stubbed in
the prototype, and they line up one-to-one with V2's CP-orchestrated
handshake:
- **Quiesce.** Today the caller must guarantee no in-flight proposes for a
  tenant during the move. V2's CP `relinquish`/`acquire` RPCs are where
  this lives — pause proposes on the source DP, drain, hand off, resume on
  the dest DP. Add an epoch/fence per group so stale messages to the old
  location are rejected.
- **Raft-log carry-over.** Our bundle ships *committed KV state only*; the
  destination starts a fresh raft group (term/commit-idx reset). For most
  migrations that's fine (state is what matters). If V2 wants to preserve
  in-flight uncommitted entries across a move, the bundle needs the raft
  log tail too — but the simpler "quiesce → commit everything → ship
  state → fresh group" path is probably what you want, and it's what we
  validated.

The migration design's anchor — **tenant = group, bags are always
single-tenant** — is what makes a tenant a movable unit. It held up; don't
let an N:1 batching optimization erode it.

---

## 5. Direct notes on the planned `rove_raft.h` FFI surface

Mapping the `v2-vendoring-spike.md` sketch against what the prototype
learned it needs:

| Sketch as written | Gap | Add |
|---|---|---|
| `rove_raft_node_t` per node, `tick`/`step`/`process_ready` per call | Single-group; O(K) at scale | Manager-of-groups; `poll_ready`/`release` mailbox; `tick_groups`/`step_batch` (§3.4) |
| `rove_raft_config_t` has `pre_vote`, `check_quorum` | No hibernation | Hibernation is DP-layer above FFI, but the FFI must let `tick` report whether a group produced work (so idle ticks are free) (§3.1) |
| No group lifecycle beyond `new`/`free` | Migration needs it | `create_group` / `destroy_group` (tombstone) / `clear_tombstone` (§4) |
| `send` callback per message | Fine, but caller must coalesce | Coalescing is DP transport, not FFI — but document that `send` fires per group-message so the caller buckets by recipient (§3.3) |
| Storage callbacks per node | Shared WAL is multi-group | Storage vtable must carry `group_id`; one WAL file, flush once per cycle (§3.2) |
| Cargo.toml: no allocator | Allocator is the wall | `#[global_allocator]` jemalloc/mimalloc (§3.6) |

The encouraging part: the *callback shape* in the sketch
(`append`/`save_hard_state`/`send`/`apply_normal`/`apply_conf_change`/
`apply_snapshot`) matches what raft-rs-zig actually does. The deltas are
all "make it multi-group and batched," not "rethink the boundary."

---

## 6. Codec / vendoring delta

raft-rs-zig vendors `raft = "0.7"` with **protobuf-codec** (rust-protobuf
2.x). `v2-vendoring-spike.md` picks **prost-codec** (and pre-generates the
`.rs` to avoid needing `protoc` at build time, with `panic = "abort"`,
`lto`, `codegen-units = 1`). Both are valid; the wrapper logic
(Manager, mailbox, storage vtable, step/tick/ready) is codec-agnostic and
transfers unchanged. Two concrete notes:
- The heartbeat byte-test (§3.1) is on the eraftpb wire format and is
  identical under both codecs — it ports as-is.
- prost is the better choice precisely because, per §3.5, decode cost is
  the real per-message cost, so a faster/smaller codec is the lever.

---

## 7. Methodology lessons (cheap, repeatedly paid for)

- **Look *up* the call stack from a hot fast resource.** strace showed
  97.5% futex; the conclusion "we're futex-bound" was wrong — the threads
  were in `cond.wait` because the pump was drowning in heartbeat traffic
  (§3.1). When a *fast* primitive (futex/lock) dominates syscall time,
  the cause is usually the workload feeding it, not the primitive.
- **Profile each layer separately, not the aggregate.** The "12 µs/step"
  number that motivated `step_batch` was four netsim costs + FFI + decode
  lumped together; attributing it to FFI was unfounded (§3.5).
- **Structural correctness ≠ measured win.** `step_batch` is "right" and
  did nothing. Ship structural cleanups, but measure before claiming
  throughput.
- **Swap the allocator before the contention deep-dive** (§3.6). One line,
  ten seconds, would have pre-empted a multi-hour investigation.
- **`perf record --call-graph` + `strace -c -f` are 10-second commands.**
  The wrong-bottleneck hypothesis costs sessions; the profile costs
  seconds.

---

## 8. The honest verdict on the V2 bet

- **The substrate works and the locked decisions hold up.** raft-rs +
  per-tenant groups + shared-fsync WAL + detach/attach migration was
  prototyped end-to-end and nothing in it argued for reversing a 2026-05-16
  decision.
- **The value proposition is migration and isolation, not throughput.**
  At realistic OLTP costs, throughput is apply-bound and roughly
  independent of the raft topology. V2 should be justified by no-downtime
  moves and per-tenant blast radius, with "throughput parity" as the
  honest performance claim.
- **The engineering that makes multi-raft *viable* at K=10k is specific
  and non-obvious:** heartbeat hibernation, mailbox `poll_ready`, batched
  tick, per-recipient coalescing, shared-fsync WAL, and a non-GPA
  allocator. None are exotic, all are TiKV-standard, and all must be
  designed in from the start — they were the difference between 5.8k and
  540k+ r/s. Build them into the FFI/DP layer, don't retrofit.
- **The hard remaining work is the CP**, not the engine: quiesce/fence
  during moves, segment GC + per-group compaction for the shared WAL, and
  real crash recovery (the prototype truncates on init). These are exactly
  the pieces `v2-vendoring-spike.md` scopes *out* of vendoring and into V2
  plan content — this doc is the evidence that they're the right place to
  spend.

---

## Appendix A — commit index

**rewind2** (`~/src/rewind2`, branch `aria-stage1-adapter`):

| Commit | Change |
|---|---|
| `73702c7` | heartbeats no longer bump the hibernation timer |
| `64d4dad` | per-recipient transport coalescing + applyCb race fix |
| `335c1b7` | use `stepBatch` on the envelope-delivery path |
| `122bc79` | bench harness for raft-saturation model (work_ns knob) |
| `18b00d9` | sharded sub-clusters (multi-pump validation) |
| `556466b` | async dispatch API + wait-any client + FP build mode |
| `8ab54db` | **c_allocator instead of GPA** + cluster_size env var |
| `0ec2740` | dispatchBagDrain bench path |

**raft-rs-zig** (`~/src/raft-rs-zig`, branch `main`):

| Commit | Change |
|---|---|
| `09b05e2` | initial: library-mode build + Manager wrapper |
| `cdda161` | FileStorage + multi-node message passing |
| `992a5cb` | SharedWal + GroupedFileStorage (shared per-node WAL) |
| `9b5a465` | clearTombstone escape hatch for migration |
| `1e92923` | per-group `Manager.tick` for hibernation policy |
| `5a72cab` | batched `tickGroups` for hibernation |
| `44fcb21` | mailbox + ready-channel (TiKV batch-system shape) |
| `89bb67e` | batched `step` FFI |

## Appendix B — raft-rs-zig API quick reference

`Manager` (one per simulated node, hosts N groups):

- `createGroup(group_id, node_id, vtable, storage_userdata)` /
  `destroyGroup(group_id)` (tombstones) / `clearTombstone(group_id)`
- `propose(group_id, data)` / `campaign(group_id)` / `step(group_id, bytes)`
- `stepBatch([]{group_id, msg_ptr, msg_len}) -> count`
- `tick(group_id)` / `tickAll()` / `tickGroups([]group_id) -> count`
- `pollReady(buf) -> []group_id` (drains the ready mailbox, O(active))
- `processReady(group_id, apply_cb, userdata)` (applies committed entries)
- `release(group_id)` (return slot to IDLE, re-notify on race)
- `takeMessages(group_id, msg_cb, userdata)` (drain outbox)
- `isLeader(group_id)` / `groupCount()`

Storage: `MemStorage` (in-mem), `FileStorage` (single-group WAL),
`SharedWal` + `GroupedFileStorage` (one interleaved WAL across groups, one
fsync per cycle). All expose a C-ABI `StorageVTable`.

Rust shim mailbox: per-group `AtomicU8` state `IDLE(0)/NOTIFIED(1)/DROP(2)`;
`notify_locked` CAS-flips `IDLE→NOTIFIED` and pushes id to a
`Mutex<VecDeque<u64>>`; `poll_ready` drains it; `release` resets to IDLE
and re-notifies if `has_ready() || !outbox.is_empty()`.
