# libcurl multi interface — plan

> **Status**: planned, not started — 2026-05-24.
> **Prerequisite reading**: `docs/primitive-gaps.md` §2.5 (held outbound
> subscription — the forcing function), `docs/connection-actor-plan.md`
> §6.5 (atproto firehose — the first customer), `docs/http-send-plan.md`
> §3 (existing libcurl outbound path).
> **Hard prerequisite**: none. This work is upstream of gap 2.5 and
> Phase 4 of `effect-reification-plan.md`. It can start independently
> of the effect-reification trajectory.

## 1. Goal

Replace the libcurl easy-handle + worker-thread-pool transport
(`src/blob/curl.zig:Easy` + `src/js/fetch_pool.zig:FetchPool`) with an
event-driven curl multi engine. After this work, one thread can hold
many concurrent transfers — including transfers that never terminate
by themselves. That unlocks `docs/primitive-gaps.md` §2.5 (held
outbound subscription) and is the natural transport for the eventual
WebSocket / atproto firehose / federation work that
`connection-actor-plan.md` §6.5 names as v2.

## 2. Why now — what it fixes

The current fetch-pool model assumes every transfer finishes quickly:
N=8 worker threads, each acquires an `Easy` handle, calls blocking
`curl_easy_perform`, returns the handle. The chunk callback delivers
bytes synchronously while the thread waits for the whole transfer.

This model has three structural limits, ordered by urgency:

1. **Gap 2.5 unbuildable.** A held outbound subscription
   (atproto firehose CONSUMER per `connection-actor-plan.md` §6.5,
   Pub/Sub long-poll, AMQP/Kafka bridges, OAuth-provider webhooks where
   the provider holds the connection) does not terminate. One
   subscription occupies one thread indefinitely. With
   `FETCH_POOL_SIZE = 8`, the node saturates at 8 simultaneous
   subscriptions across all tenants. The model violates its own
   assumption.

2. **WebSocket transport unbuildable.** System libcurl 8.15.0 ships
   the WebSocket wrappers (`curl_ws_send` / `curl_ws_recv`, stable
   since 7.86), but they require the multi interface for
   non-blocking operation. Federation
   (`project_fediverse_libs`) names inbound-WS-origin as the forcing
   function; the upstream-WS consumer is the symmetric problem with
   the same transport prerequisite.

3. **http.fetch concurrency capped at 8 per node.** Today a slow
   upstream (e.g. an LLM streaming endpoint that takes 30s) holds a
   fetch-pool thread for that entire time. Eight concurrent slow
   upstreams = no headroom for fast fetches. The multi interface
   removes this cap structurally.

Limit #1 is the forcing function. Limits #2 and #3 fall out of the
same transport upgrade. None of these are reachable by tuning
`FETCH_POOL_SIZE` — raising it just moves the saturation point
linearly, doesn't change the model.

## 3. Target shape

### 3.1 Engine — one curl_multi per node

```
NodeState
  └── FetchEngine (new — replaces FetchPool)
        ├── thread:  std.Thread (one)
        ├── multi:   *CURLM           // curl_multi handle
        ├── transfers: AutoHashMap(*CURL, *Transfer)
        ├── pending_in: Mpmc<TransferRequest>   // worker → engine
        └── events_out: per-tenant route (existing NodeState plumbing)
```

One thread per node owns the multi handle. Workers submit transfer
requests via a lockless queue (the existing
`enqueuePendingFetches` plumbing rewires onto this). The thread
drives `curl_multi_socket_action()` against an epoll/io_uring loop;
per-transfer callbacks fire on the engine thread and route results
via the existing `NodeState.enqueueFetchEventForTenant` (which
already hash-routes to the destination worker's `msg_inbox`).

The thread's loop:

```
while not stop:
    poll fds (curl-supplied) with deadline = curl_multi_timeout()
    for each ready fd:
        curl_multi_socket_action(multi, fd, ev_bits, &running)
    for each new request in pending_in:
        build CURL*, set opts, curl_multi_add_handle(multi, ch)
    drain curl_multi_info_read for completed transfers
```

### 3.2 Transfer kinds — one type, three lifecycles

```zig
const TransferKind = enum {
    short,        // http.fetch, finishes by itself
    held,         // gap 2.5 subscription, customer closes
    websocket,    // duplex frames (deferred to Phase 4 of this plan)
};

const Transfer = struct {
    kind: TransferKind,
    easy: *CURL,
    pf: PendingFetch,              // request descriptor
    on_chunk: *const fn (...) void, // bytes-arrived callback
    dest_tenant_id: []const u8,    // for routing events
    cancelled: std.atomic.Value(bool) = .init(false),
    ...
};
```

Same engine drives all three. The difference is in the per-transfer
completion model:

| Kind | When does it complete? | Customer-visible lifecycle |
|---|---|---|
| `short` | `CURLMSG_DONE` from curl_multi_info_read | Fires one `fetch_chunk` Msg with `final=true` |
| `held` | Cancel via `http.cancelSubscription({id})` or upstream hangup | Fires `subscription_chunk` Msgs until cancel/hangup; last carries `final=true` |
| `websocket` | Cancel or close frame | Fires `inbound_frame` Msgs per `curl_ws_recv`; `conn_write` Cmd drives outbound via `curl_ws_send` |

### 3.3 Cancellation — the new surface

`Easy` today has no async cancel (it's per-thread blocking). The
multi engine needs one. The cancel path is:

```
worker thread:    engine.cancel(transfer_id)
                  → push CancelRequest onto pending_in
                  → wake engine via eventfd / pipe / io_uring
engine thread:    curl_multi_remove_handle(multi, ch)
                  → curl_easy_cleanup(ch)
                  → free Transfer, emit one final Msg with cancelled=true
```

This is the API hook `http.cancelFetch` (today a no-op per
`bindings/http.zig:170`) finally wires to.

### 3.4 Coexistence with Easy

`src/blob/curl.zig:Easy` stays. S3 PUTs (`blob/s3.zig`, log-batch
push via `worker_log.zig`) keep their thread-per-PUT model. The
workload fit is different: S3 PUTs are bulk-blocking on synchronous
network I/O; pushing them through a single curl_multi thread would
serialize them. Leave Easy in place; let it own bulk blocking work
where the workload is "many cores, each pushing one big body."

The new engine in `blob/curl_multi.zig` is a peer file, not a
replacement.

## 4. Current state — what bespoke transport bits collapse

| Bespoke today | After |
|---|---|
| `FetchPool` (`fetch_pool.zig:64`) — N threads, each blocks on one transfer | `FetchEngine` — 1 thread, N concurrent transfers |
| `EasyPool` (`blob/curl.zig:466`) shared with S3 + log push | unchanged; only `fetch_pool.zig` migrates off it |
| `http.cancelFetch` (`bindings/http.zig:143`) — no-op log line | wired to engine.cancel |
| Gap 2.5 `__rove_subscribe` — not implementable | implementable on `held` transfer kind |
| WebSocket transport — not implementable | implementable on `websocket` transfer kind |

## 5. Invariants — hold at every step

1. **Easy stays for S3 + log push.** Don't migrate consumers whose
   workload doesn't benefit. The trade-off is per-call setup: Easy
   pre-warms a handle pool, Multi adds a handle per call. S3 PUTs
   are not the workload that justifies that.
2. **http.fetch semantics stay byte-identical.** The
   `CURLOPT_WRITEFUNCTION` chunked callback shape, the
   `max_response_chunk_bytes` / `max_total_response_bytes` caps, the
   single-callback `on_chunk` activation with `final=true` —
   `fetch_chunk_smoke.py` + `fetch_streaming_smoke.py` pin every
   observable. The engine reproduces them.
3. **Cancellation is cooperative, not preemptive.** A transfer
   in-flight may emit one more chunk after `cancel()` returns; the
   engine ignores it post-cancel rather than racing to abort
   per-byte. Documented; customer's `on_chunk` handles the late
   chunk as a no-op (the marker for "we already moved on" is in the
   chain ctx, not the transport).
4. **One engine thread.** Don't shard the multi handle across
   threads; libcurl multi handles are not thread-safe. If
   throughput needs to scale beyond one thread's
   `curl_multi_socket_action` rate, the answer is multiple engines
   (multi-process, post-1.0), not multi-threaded one engine.
5. **No perf regression on the http.fetch hot path.** Phase 0
   measures: `fetch_chunk_smoke.py` round-trip time + a soak with
   100 concurrent fetches against an in-process echo. Each phase
   stays at-or-better.
6. **Every phase is independently shippable.** Phase 1 lands the
   engine alongside `FetchPool`; the cutover is one config flag.
   Phase 2 retires `FetchPool`. Phase 3 adds `held`. Phase 4 adds
   `websocket`. Rollback at any phase is "leave the previous
   phase's code, don't proceed."

## 6. Phases

Each phase: **Goal / Steps / Gate / Done / Rollback.**

### Phase 0 — Baseline + decisions (this doc)

- **Goal**: lock the four open decisions surfaced in the
  investigation; record current `fetch_chunk_smoke` timing as
  baseline.
- **Steps**:
  - Lock decisions §6.A–D below.
  - Run `fetch_chunk_smoke.py` + a synthetic 100-concurrent-fetch
    soak; record p50/p95/p99 latency + max concurrent in the
    "Phase 0 results" section.
  - Confirm libcurl WebSocket symbols (`curl_ws_send` /
    `curl_ws_recv`) link cleanly against the system 8.15.0.
- **Done**: decisions table filled; baseline numbers recorded.
- **Rollback**: n/a (no code change).

### Phase 1 — `curl_multi.zig` wrapper + engine skeleton (no consumers)

- **Goal**: a working multi engine in tree, exercised by tests, with
  zero production consumers. `FetchPool` keeps running.
- **Steps**:
  - Write `src/blob/curl_multi.zig`:
    - `Multi` — wraps `CURLM*`; init/deinit, add/remove handle,
      socket_action driver, info_read poll, cancellation.
    - `Transfer` — owns one `CURL*` + per-request state +
      ownership-of-PendingFetch.
    - Driver loop: `runDriver(multi, stop_flag)` — pollable from a
      dedicated thread.
  - Inline Zig tests: round-trip against a local h2 echo (reuse the
    in-process echo from `fetch_chunk_smoke` Python harness — port
    to Zig).
  - No production wiring. The engine is dead code at end of
    Phase 1.
- **Gate**: `zig build test` green; new tests pass; no perf
  regression (no consumers means no perf change).
- **Done**: `Multi`/`Transfer`/driver compile + pass tests; no
  dispatch path touched.
- **Rollback**: delete the new file.

### Phase 2 — migrate `http.fetch` consumer onto the engine

- **Goal**: `FetchPool` retired; `http.fetch` runs on
  `FetchEngine`. No new feature; behavior byte-identical.
- **Steps**:
  - Add `FetchEngine` to `NodeState` (1 thread, owns `Multi`).
  - Rewire `worker.node.enqueuePendingFetches` from
    `NodeState.fetch_pending` (the FetchPool queue) onto
    `FetchEngine.submit`.
  - Implement the streaming-write callback the same way
    `FetchPool.runOne` does today (re-chunk to
    `max_response_chunk_bytes`, route via
    `NodeState.enqueueFetchEventForTenant`).
  - Wire `http.cancelFetch({id})` to `engine.cancel(id)`. The id is
    the `derived_fetch_id` (hex of sha256 input) from
    `bindings/http.zig:287` — kept stable across the cutover.
  - Delete `src/js/fetch_pool.zig`. Delete `FETCH_POOL_SIZE` (or
    repurpose as the engine's `max_concurrent_transfers` cap).
- **Gate**: `fetch_chunk_smoke.py` + `fetch_streaming_smoke.py` +
  `pipe_smoke.py` + `http_send_smoke.py` (the JS-shim path exercises
  http.fetch) all green; soak test from Phase 0 baseline stays
  within ±5% on p50, ≥2× concurrency.
- **Done**: `FetchPool` gone; the new engine carries the
  production load.
- **Rollback**: revert the cutover commits; `FetchPool` is the prev
  state. The new engine stays in tree (Phase 1's contribution) but
  is dead code again.

### Phase 3 — `held` transfer kind + `__rove_subscribe` Cmd (gap 2.5) — **DONE 2026-05-24**

Shipped: `held: bool` flag on `PendingFetch` + per-tenant cap
(`HELD_MAX_PER_TENANT=16`) + JS bindings `http.subscribe` /
`http.cancelSubscription`. Customer-visible activations stay on
the `fetch_chunk` Msg variant; terminal events always carry
`ok=false` for held transfers ("subscription ended"). Cap
rejection fires a single defined `final: true, ok: false` event.
Smokes: `scripts/subscription_smoke.py` +
`scripts/subscription_cap_smoke.py` (both green, 6/6 runs).
`docs/primitive-gaps.md` §2.5 updated.

Deferred from the original plan: the §6.E decomposition into
`__rove_stream` with a direction parameter. The JS binding is
distinct (`http.subscribe`); the underlying Cmd shape stays as a
`PendingFetch + held` flag for now. The unified-Cmd refactor
moves with the eventual effect-reification Phase 4.X work when
the full Cmd union gets its exhaustive `interpretCmd` switch.
Tape policy (large-frame content-addressed path from
`connection-actor-plan.md` §8) also deferred — held chunks tape
inline via the existing `fetch_chunk` path; the §6 cap from
`primitive-gaps.md` applies.

- **Goal**: customers can hold an outbound subscription. Closes
  gap 2.5.
- **Steps**:
  - Add `Cmd.held_subscribe` to `effect/cmd.zig` (per gap 2.5's
    decomposed-into-`__rove_stream` recommendation, this may be a
    direction parameter on the existing stream Cmd — see §6.E
    below).
  - JS binding: `http.subscribe({ url, headers?, on_chunk, ctx? })`
    → returns subscription id; pairs with
    `http.cancelSubscription({ id })`.
  - Engine: `held` transfers don't fire `CURLMSG_DONE`-driven
    final events; they stream until cancelled or upstream closes.
    On upstream close, fire `final: true, ok: false, reason:
    "upstream_closed"` so the customer's handler can decide
    reconnect.
  - Per-tenant cap on simultaneous held subscriptions (mirror
    `connection-actor-plan.md` §9.2).
  - Tape policy: subscription chunks are taped inline up to a per-
    chunk cap; over-cap goes to the content-addressed path
    (`connection-actor-plan.md` §8 large-frame treatment).
- **New tests**:
  - `subscription_smoke.py` — handler subscribes to an in-process
    echo, asserts N chunks fire on the customer's handler, then
    cancels.
  - `subscription_cap_smoke.py` — exceed per-tenant cap, assert
    defined rejection.
- **Gate**: new smokes pass; `fetch_chunk_smoke` regression-stable.
- **Done**: gap 2.5 closed; `docs/primitive-gaps.md` §2.5 status
  updated.
- **Rollback**: revert the held-transfer + binding commits;
  Phases 1+2 stand.

### Phase 4 — WebSocket transfer kind (DEFERRED, conditional on
                                       federation demand)

WebSocket lands in a future revision of this plan, not as a phase
inside the current scope. Two reasons:

1. **libcurl is client-only.** `curl_ws_send` / `curl_ws_recv`
   handle the outbound (consumer) side. They do not, and will
   never, accept inbound connections — libcurl has no server
   primitives. Federation as a consumer of upstream feeds (atproto
   firehose, OAuth-provider push) needs only the client side;
   federation as a producer (inbound clients connecting via WS)
   needs a server-side stack rove doesn't have today (rove-h2 is
   HTTP/2 only via nghttp2).
2. **Coupling shipping.** The framing / lifecycle / auth / cap
   surface for WS deserves its own design pass against a
   real customer demand. Adding it inside this plan couples a
   well-scoped transport upgrade to an open design question.

When WS does land, the surfaces split:

- **Outbound (client) WS** — a `Cmd.websocket_out` variant + a new
  `websocket` transfer kind on the engine built here. Re-uses the
  cancellation + tape policies from Phase 3's `held`.
- **Inbound (server) WS** — entirely outside this plan. Either RFC
  8441 "WebSockets over HTTP/2" via nghttp2's `:protocol`
  pseudo-header (stays h2-only; weaker browser support), or a
  minimal HTTP/1.1 Upgrade accept path (the
  `project_fediverse_libs` "only inbound-WS-origin forces an h1
  stack" call). Both are separate plans.

The `conn_write` Cmd variant in `effect/cmd.zig` stays
producer-less until inbound-WS lands; this plan does not change
that. Effect-reification Phase 4.1 ships independently — its
exhaustive `interpretCmd` switch handles `conn_write` with a
panic/unreachable branch that fills in when inbound-WS lands. See
§10 for the cross-plan relationship.

## 7. Open decisions — to lock in Phase 0

### A. Drive model: io_uring integration vs dedicated thread?

- **A1**: One curl_multi per worker, driven by the worker's
  io_uring loop via `curl_multi_socket_action`. The same loop
  fields HTTP/2 + outbound transfers.
- **A2**: Dedicated curl_multi thread per node, with its own
  io_uring / epoll. Connected to workers via NodeState plumbing.
- **Recommendation**: **A2.** rove-io abstracts io_uring for the
  h2 server in a way that hasn't been extended to track curl-
  supplied fds; teaching it that is its own project. A2 is the
  smaller blast radius — workers stay untouched, the thread cost
  (one context switch per event) is invisible against the network
  RTTs that dominate http.fetch latency (cluster ceiling is
  fsync/RTT-bound per memory
  `project_inbound_log_perf_2026_05_24`). A1 stays available as a
  later perf-driven decision.

### B. Migration scope — fetch only, or also blob?

- **B1**: Just `fetch_pool.zig` migrates. Blob backend
  (`blob/s3.zig` + `worker_log.zig` push) keeps using `Easy`.
- **B2**: Blob backend also migrates.
- **Recommendation**: **B1.** S3 PUTs are bulk-blocking on
  synchronous network I/O; a single multi thread would serialize
  them. The S3 workload fits "many cores, each pushing one big
  body" — exactly what the Easy pool optimizes for. Don't migrate
  consumers whose workload doesn't benefit.

### C. WebSocket in scope?

- **C1**: No. Multi is for fetch + held subscriptions only. WS
  lands in a future revision of this plan, separately from server-
  side WS (which is its own design — RFC 8441 over h2 vs. h1
  Upgrade ingress vs. a vendored WS server library).
- **C2**: Yes, ship outbound WS framing as part of this work.
- **Recommendation: C1.** libcurl is client-only — it solves the
  outbound (consumer) side but does nothing for the inbound
  (server) side that federation as a producer would need. The
  full WS story is two separate plans; doing the outbound half
  here couples shipping for no architectural win. See Phase 4
  notes above.

### D. Migration vs. rebuild

- **D1**: Extend `blob/curl.zig` with multi types alongside Easy.
- **D2**: New `blob/curl_multi.zig` as a peer file.
- **Recommendation**: **D2.** Matches the
  `worker_log.zig` / `worker_streaming.zig` / `worker_drain.zig`
  precedent of "extract focused peer files." Smaller diff per PR;
  `blob/curl.zig` stays as-is for the Easy consumers.

### E. Held subscription Cmd shape

`primitive-gaps.md` §2.5 recommends unifying `__rove_subscribe`
into `__rove_stream` with a direction parameter (held-inbound
vs. held-outbound). The Cmd surface stays at three (Response /
next / stream).

- **E1**: Implement as a separate `Cmd.held_subscribe`.
- **E2**: Extend `Cmd.respond` / `stream` with a direction
  parameter; customer sees one `__rove_stream` Cmd.
- **Recommendation**: **E2**, per the gaps doc's stated principle.
  But the binding shape (`http.subscribe(...)` as the JS-side
  call) can be a JS-shim over the unified Cmd — symmetric to how
  `webhook.send` is a JS shim over `kv.set` + `http.fetch`.

## 8. Test & perf strategy

Per memory `user_freeze_workflow`: this is **test-first** work on
shipped code. Each phase: confirm gating smokes pin current
behavior, refactor, prove green.

**Gating smoke set** (all must stay green every phase, plus the
new ones each phase adds):

- `fetch_chunk_smoke.py` — single-shot http.fetch.
- `fetch_streaming_smoke.py` — chunked http.fetch.
- `pipe_smoke.py` — pipe disposition.
- `http_send_smoke.py` — JS-shim webhook path (exercises
  http.fetch on the inside).
- `leader_failover_smoke.py` — H2 reference path (the multi
  engine is on outbound; H2 inbound is untouched, but the cluster
  shape matters).

**Perf gate**: a new soak test
`scripts/fetch_concurrency_bench.py` — N=100 in-process echos
served concurrently, measure p50 / p95 / p99 + max in-flight.
Phase 0 records the FetchPool baseline; Phase 2 must improve
max-in-flight (FETCH_POOL_SIZE=8 ceiling lifts) without
regressing p50 by >5%.

## 9. Out of scope (locked rejections — do not re-propose)

- **Multi-threaded curl_multi.** Multi handles are not
  thread-safe; multiple engines = multiple processes, not multiple
  threads on one engine. Post-1.0 (multi-process horizon) only.
- **Replacing Easy entirely.** S3 + log push stay on Easy
  forever; the workloads are different. Don't fold for symmetry.
- **HTTP/3.** libcurl HTTP/3 needs nghttp3 + quiche/ngtcp2;
  vendored deps + build complexity. Not on the critical path.
- **DNS caching tier.** libcurl has AsynchDNS + its own cache; if
  customer DNS becomes a perf issue, address inside libcurl
  config, not in our wrapper.
- **Per-tenant curl handle reuse.** Each transfer gets a fresh
  `CURL*`. Reuse is a libcurl 8.x optimization (connection
  pooling, share-handle); cleaner to lean on libcurl's built-in
  share interface if measured, not to hand-roll.

## 10. Interaction with effect-reification-plan.md

This plan is **upstream of** Phase 4 of the effect-reification
plan and adjacent to gap 2.5.

- Phase 2 of THIS plan (FetchEngine carries http.fetch) lands
  before Phase 4.1 of the reification plan (interpretCmd switch
  over the full Cmd union). 4.1's `Cmd.http_out` interpreter
  invokes `engine.submit` instead of today's
  `enqueuePendingFetches`.
- Phase 3 of THIS plan (gap 2.5) is the prerequisite for the
  reification plan's full Cmd union being meaningful — without a
  held-subscription Cmd to interpret, `conn_write` stays an
  unbuildable variant.
- The `conn_write` Cmd variant has no producer until inbound-WS
  lands (a separate plan: RFC 8441 via nghttp2 or a minimal h1
  Upgrade ingress). Effect-reification Phase 4.1 is **not blocked**
  on that: `interpretCmd`'s exhaustive switch covers `conn_write`
  with a panic/unreachable case (`@panic("conn_write has no
  interpreter; inbound-WS not built")`). The switch is exhaustive
  by construction; the case is dead code until the producer
  lands. When inbound-WS does land, that branch swaps from panic
  to a real interpreter and the producer wiring lights up. No
  Phase 4.1 rework needed at WS-land time beyond filling the one
  branch.

The sequencing per user 2026-05-24:

1. THIS plan (Phases 1-3): curl-multi engine → http.fetch on the
   engine → gap 2.5 held subscriptions.
2. Effect-reification Phase 4 full vision: interpretCmd over the
   buildable Cmd union (`kv_write` + `http_fetch` + `respond` +
   `held_subscribe`). `conn_write` stays an unbuilt variant.
3. WS / federation if/when customer demand surfaces. Two separate
   plans by then: outbound (revision of THIS plan, adds the
   `websocket` transfer kind) and inbound (new plan covering h2
   RFC 8441 vs h1 Upgrade ingress).

## 11. Appendix — A1 (rove-io integration) vs A2 (dedicated thread), detailed

§7.A locks A2; this appendix retains the analysis for the next time
someone asks "why not A1?"

### What libcurl multi requires from the event loop

`curl_multi_socket_action()` works via two callbacks set during init:

- **`CURLMOPT_SOCKETFUNCTION`** — fires when libcurl wants you to
  start / stop watching an fd. Signature `(easy, fd, what, userp,
  sockp)` with `what ∈ { CURL_POLL_IN, OUT, INOUT, REMOVE }`.
- **`CURLMOPT_TIMERFUNCTION`** — fires when libcurl wants you to
  (re)arm a single timeout. Signature `(multi, timeout_ms,
  userp)`. `timeout_ms == -1` means cancel.

Your loop watches the libcurl-requested fds, calls
`curl_multi_socket_action(multi, fd, ev_bits, &still_running)` on
readiness, calls `curl_multi_socket_action(multi, CURL_SOCKET_TIMEOUT,
0, ...)` on timer fire, and drains `curl_multi_info_read()` after
each call for completed transfers.

### Why io_uring integration is "fancier epoll," not "I/O replacement"

io_uring's `IORING_OP_POLL_ADD` / `IORING_OP_POLL_REMOVE` give
fd-readiness notifications equivalent to epoll. So A1 boils down to
"submit poll SQEs for the fds libcurl asks us to watch, call
socket_action on completion CQEs."

The deeper integration (submit `IORING_OP_READ` / `IORING_OP_WRITE`
SQEs for the actual bytes libcurl would `recv`/`send`) is not
possible without forking libcurl — there's no `CURLOPT_USE_MY_IO`
hook. libcurl's send/recv path is fixed; the most an application
can override is the socket *creation*
(`CURLOPT_OPENSOCKETFUNCTION`), not the I/O on it.

### Sketch — A1 wired into a per-worker rove-io ring

```zig
// Setup (per worker)
_ = c.curl_multi_setopt(multi, c.CURLMOPT_SOCKETFUNCTION, socketCb);
_ = c.curl_multi_setopt(multi, c.CURLMOPT_SOCKETDATA, @ptrCast(worker));
_ = c.curl_multi_setopt(multi, c.CURLMOPT_TIMERFUNCTION, timerCb);
_ = c.curl_multi_setopt(multi, c.CURLMOPT_TIMERDATA, @ptrCast(worker));

fn socketCb(_: ?*c.CURL, fd: c.curl_socket_t, what: c_int,
            userp: ?*anyopaque, sockp: ?*anyopaque) callconv(.c) c_int {
    const worker: *Worker = @ptrCast(@alignCast(userp.?));
    if (what == c.CURL_POLL_REMOVE) {
        const handle: *PollHandle = @ptrCast(@alignCast(sockp.?));
        worker.io.cancelPoll(handle);
        worker.allocator.destroy(handle);
        return 0;
    }
    var handle: *PollHandle = if (sockp) |s| @ptrCast(@alignCast(s)) else blk: {
        const h = worker.allocator.create(PollHandle) catch return -1;
        _ = c.curl_multi_assign(worker.curl_multi, fd, @ptrCast(h));
        break :blk h;
    };
    const mask: u32 =
        (if (what & c.CURL_POLL_IN  != 0) std.posix.POLL.IN  else 0) |
        (if (what & c.CURL_POLL_OUT != 0) std.posix.POLL.OUT else 0);
    worker.io.pollAddOrMod(fd, mask, handle, &onCurlPollReady);
    return 0;
}

fn onCurlPollReady(worker: *Worker, fd: c.curl_socket_t, revents: i16) void {
    var ev: c_int = 0;
    if (revents & std.posix.POLL.IN  != 0) ev |= c.CURL_CSELECT_IN;
    if (revents & std.posix.POLL.OUT != 0) ev |= c.CURL_CSELECT_OUT;
    var still_running: c_int = 0;
    _ = c.curl_multi_socket_action(worker.curl_multi, fd, ev, &still_running);
    drainCompletedTransfers(worker);
}
```

New primitives rove-io would need that don't exist today:

- `pollAddOrMod(fd, mask, *Handle, *fn)` — `IORING_OP_POLL_ADD`
  (or `POLL_REMOVE`+`POLL_ADD` on mask change). Track the SQE's
  user_data so cancel works.
- `cancelPoll(*Handle)` — `IORING_OP_ASYNC_CANCEL` against the
  tracked SQE.
- `armCurlTimer(ms, *fn)` / `cancelCurlTimer()` —
  `IORING_OP_TIMEOUT` with cancellable handle.

rove-io's h2 server path doesn't use this shape today (it's all
submit-read/submit-write directly on streams); these are new
surface.

### The architectural consequence: per-worker multi handles

A1 inherently means **one curl_multi per worker thread** — the
multi handle isn't thread-safe and each worker owns its own ring:

```
worker 0 ──> ring 0 ──> curl_multi 0 ──> N transfers
worker 1 ──> ring 1 ──> curl_multi 1 ──> N transfers
...
worker 7 ──> ring 7 ──> curl_multi 7 ──> N transfers
```

vs A2:

```
worker 0..7 ──> Mpmc queue ──> engine thread ──> curl_multi ──> N transfers
                                     └──> own ring / epoll
```

### Trade-off matrix

| Dimension | A1 per-worker | A2 dedicated thread |
|---|---|---|
| **Connection pooling** | N pools (one per worker). Same upstream → N TCP conns | 1 pool. Upstream conn reused across tenants |
| **Cross-thread routing on completion** | None — chain stays on worker | One hop via `enqueueFetchEventForTenant` |
| **rove-io surface change** | New poll/timer primitives | None |
| **DNS resolver** | c-ares per worker, cache per worker | Single resolver, shared cache |
| **CPU per transfer** | Mixes with h2 hot path | Isolated engine thread |
| **Failure isolation** | Integration bug can wedge worker's h2 loop | Engine can hang/restart independently |
| **Pattern familiarity** | Novel; libcurl-on-io_uring isn't well-trodden | Standard libcurl-on-epoll; lots of reference code |
| **Shutdown** | N handles to tear down | 1 handle |

### Why A2 wins today

The decisive factor is **connection pooling**. When handler X on
worker 0 calls `http.fetch(github.com)` and handler Y on worker 3
also calls `http.fetch(github.com)`, A1 opens two TCP connections
(one per worker). A2 reuses one. For a tenant that hammers a
single upstream (LLM proxy, internal service, atproto firehose),
this is meaningful at scale. libcurl's `CURLSHOPT_SHARE` can share
the connection cache across multi handles, but it requires explicit
locking via callbacks — *your* locking, not libcurl's — which gives
back the cleanliness A1 promised.

A1's latency win ("no cross-thread hop on completion") saves
microseconds per fetch. The cluster ceiling is fsync/RTT-bound per
memory `project_inbound_log_perf_2026_05_24`; this isn't moving
the dial.

### When to reconsider A1

Flip A1 → A2 if **all** are true:

1. Measured workload where per-worker affinity matters (long-lived
   chains where tape locality is hot).
2. Cross-thread Msg routing measured as a hot spot.
3. Connection-pool fragmentation not a concern (small N of
   upstreams, or willing to accept per-worker pools).

None are true today. The gap 2.5 workload (federation firehose)
explicitly wants one connection per upstream across the node —
arguing for A2.

A2 → A1 migration is bounded (touches rove-io's surface, not
fundamentals) if a future measurement justifies it.

## Phase 0 results — decisions locked (2026-05-24)

Baseline measurements pending; decisions locked per recommendations
in §7:

- **A: A2** — dedicated curl_multi thread per node, with its own
  epoll/io_uring loop. Connected to workers via existing NodeState
  cross-thread plumbing. (See §11 appendix for the A1 analysis.)
- **B: B1** — migrate `fetch_pool.zig` only. S3 + log-batch push
  stay on `Easy` (workload fit).
- **C: C1** — WebSocket out of scope; future revision of this
  plan adds outbound WS. Inbound WS is a separate plan entirely.
- **D: D2** — new `src/blob/curl_multi.zig` peer file, not
  extending `blob/curl.zig`.
- **E: E2** — held subscription as a direction parameter on
  `__rove_stream` per `primitive-gaps.md` §2.5; JS binding
  surface (`http.subscribe(...)`) is a shim over the unified Cmd.

Phase 0 measurements (2026-05-24, local ReleaseFast, single-node
in `Cluster.spawn(workers_per_node=1)`, upstream = same-node wb/bulk
echo serving a 170-byte deterministic body):

**libcurl WebSocket symbols:** LINK OK against system libcurl
8.15.0. `nm -D /lib64/libcurl.so.4` confirms `curl_ws_send` +
`curl_ws_recv` are exported.

**`scripts/fetch_concurrency_bench.py` baseline** (3 runs at N=100,
median values; N=1 and N=10 single runs):

| N | wall (ms) | per-fetch p50 (ms) | p95 (ms) | p99 (ms) | effective concurrency | implied throughput (fps) |
|---:|---:|---:|---:|---:|---:|---:|
| 1   | 22   | 20   | 20   | 20   | 0.92 | 46 |
| 10  | 51   | 46   | 47   | 47   | 9.10 | 198 |
| 100 | 2130 | 1150 | 2000 | 2100 | 52.5 | 47 |

**Interpretation:**

- **N=1** captures the dispatch-path floor: ~20 ms covers entry
  handler → http.fetch enqueue → FetchPool thread acquire +
  libcurl GET (loopback) → on_chunk activation → kv.set raft
  commit of `bench/done/<id>`. That's the per-fetch overhead the
  curl-multi engine must not regress.
- **N=10** at-FetchPool-capacity: effective concurrency ~9 confirms
  the pool saturates (`FETCH_POOL_SIZE=8` + one in-flight return
  trip). Per-fetch latency grows 2× from N=1 because each fetch
  contends for the same on_chunk dispatch + raft propose.
- **N=100** beyond capacity: per-fetch p50 balloons to 1.15 s —
  most of that is queue-wait. Throughput collapses from 198 fps
  (N=10) to 47 fps (N=100) because at high queue depth the on_chunk
  raft writes start contending. **Phase 2's `FetchEngine` target:
  lift the `FETCH_POOL_SIZE=8` ceiling structurally so N=100 stays
  near the N=10 per-fetch latency (≤100 ms p50) while wall time
  scales with `N / effective_concurrency` against a much higher
  ceiling.**

Note on measurement staleness: the bench's `bench/done/<id>` polling
runs at 50 ms intervals, adding up to 50 ms per-fetch latency over
the true value. Acceptable for relative comparison; tighten if a
phase needs absolute numbers.
