# WebSocket plan — transport, handler shape, and the use cases it unlocks

> **Status**: in progress (single-tenant / single-node). **Inbound model
> decided 2026-06-07 — see §4.5** (DO-shaped; gap #6 dropped the cost to ~1–2
> weeks; §4's 6–10-week estimate is superseded). **Handler-API revised 2026-06-08
> to the shipped post-Phase-2 surface** — the held-connection handler is
> `stream.*` effects + `on.*` waits + `return next()` / terminal + named-export
> dispatch (`docs/handler-shape.md`), NOT the retired `__rove_stream({write,
> waitFor})` return verb. Every handler-facing snippet below is in the current
> vocabulary. **Transport shipped 2026-06-08**: the codec (piece B,
> `src/h2/ws.zig`) plus the rove-h2 transport (pieces A/C + the h2 side of E) —
> the `101` handshake, ws-mode connection, inbound parse/reassemble/auto-pong/
> close, and outbound framing over the `ws_message_out` / `ws_send_in` collection
> seam. Proven by `examples/ws_echo_test.zig` (`zig build ws-echo`) +
> `scripts/ws_echo_smoke.py`. **Piece D (worker seam) shipped + smoke-proven
> 2026-06-09**: deployed-handler `onMessage` / `onDisconnect` over a real WS
> connection — `scripts/ws_worker_smoke_v2.py` (piece F) asserts text/binary
> echo, commit-gated durable frames, kv round-trip, terminal close, and both
> disconnect paths (client Close + abrupt-drop stale sweep). The inbound
> single-node baseline is **done**.
> Originally consolidated 2026-05-27 from the
> WebSocket-blocked items scattered across other docs (`architecture/effects-and-handlers.md`
> §6.3 + §6.5, `architecture/effects-and-handlers.md` Phase 4.1.4 `conn_write`,
> the held-outbound-subscription note (now in `architecture/effects-and-handlers.md`),
> the deleted `curl-multi-plan.md` Phase 4) into one
> place. The execution model is already specified (`architecture/routing-and-ingress.md`
> §1–§5 + connection-actor §6); this doc is about transport choices,
> what shipping WS unlocks, and the cost/sequencing.

## 1. The asymmetry — outbound is close, inbound is far

**Outbound WebSocket** (client of an upstream WS server, e.g. atproto
firehose CONSUMER, Pub/Sub, custom WS APIs):

- Transport is **mostly here.** `fetch_engine.zig` is a curl_multi
  engine driving N concurrent transfers on one thread; libcurl
  supports WebSocket in recent versions (`CURLOPT_CONNECT_ONLY` +
  `curl_ws_recv` / `curl_ws_send`). Adding a `held: bool` ws-mode
  variant of the existing `held` PendingFetch is the closest
  unstarted work.
- Execution model is **fully shipped.** Each upstream WS frame
  resumes the held chain as a bound-`on.fetch` chunk activation —
  the same `onFetchChunk` export `http.subscribe`'s streamed reads
  already dispatch to.
- Tape determinism is **already covered.** Per-chain tape budget
  (`architecture/routing-and-ingress.md` §3) handles WS frame replay the same way it
  handles SSE chunks.

**Inbound WebSocket** (server endpoint for chat, presence, collab
editing, federation inbound):

- Transport is **far.** RFC 6455 is `HTTP/1.1 Upgrade:` — forbidden
  in HTTP/2. RFC 8441 extended CONNECT bridges through h2 but
  Cloudflare downgrades WS traffic to HTTP/1.1 to the origin. So
  serving WS requires a parallel HTTP/1.1 listener stack alongside
  the nghttp2-based h2 stack: separate parser, separate framing
  (RFC 6455 masking + fragmentation + ping/pong), separate
  connection lifecycle, ALPN negotiation. **Several thousand LOC
  and a two-stack maintenance burden.** This is the deferred-to-v2
  cost PLAN documents.
- Execution model is **shipped** (the streaming-handlers primitive
  covers inbound-chunk dispatch + held-stream lifecycle); when
  transport lands, WS-shaped handlers ride it.
- One typed Cmd slot is reserved-but-deferred:
  `architecture/effects-and-handlers.md` Phase 4.1.4 `conn_write` — added
  when the inbound-WS producer exists.

The two halves are independently shippable. **Outbound WS is the
faster win** (~weeks); inbound WS is the structural commitment
(~quarters).

## 2. Why each piece is blocked on this

### 2.1 atproto firehose CONSUMER

`com.atproto.sync.subscribeRepos` — server→client, binary, sequenced,
cursor-resumable. The forcing function for the fediverse vertical
([[project_fediverse_libs]]).

Status:
- ✅ Long-lived held connection — `http.subscribe` shipped 2026-05-24
- ✅ Per-frame activation model — the `onFetchChunk` activation shape works
- ✅ Per-tenant cap, cooperative cancellation
- ❌ **WS framing** — currently just HTTP body chunks via curl_multi;
  needs WebSocket frame parsing (binary opcodes, ping/pong)
- ❌ **CBOR / DAG-CBOR decoding** of frame payloads — atproto-specific;
  out of any transport plan (customer JS library)
- ❌ **Cursor/sequence persistence** — customer-composed via kv per the
  framework's "customer owns reconnect state" principle

So the gate IS the WS frame parsing. Add a `ws: true` mode to the
existing `held` PendingFetch; libcurl handles the frame parsing; the
chunk callback delivers frames instead of bytes. Reuses the existing
chain activation machinery.

### 2.2 Inbound WS endpoints — chat / presence / collab editing

Customer use case: a chat room handler receives WS messages from N
connected clients, broadcasts to all of them. Today the customer can
build the receive-half via long-poll over the `stream.*` surface (works
but chatty), but they can't expose a real WebSocket endpoint that
browsers expect.

Blocked on the h1 stack work above. The execution model is fully
covered by the held-handler surface (`stream.*` output + `on.*` waits +
`next()`) + per-frame `onMessage` activations — no design work, just
transport.

### 2.3 Federation inbound (ActivityPub C2S, atproto PDS server)

ActivityPub C2S Streams API uses WS. Same as inbound WS endpoints —
gated on the h1 stack. ActivityPub S2S (server-to-server) is
HTTP-only and already works without WS per
[[project_fediverse_libs]] ("AP needs ZERO transport work").

### 2.4 Outbound-frame effect — `stream.write`, not a separate `conn_write`

`architecture/effects-and-handlers.md` Phase 4.1.4 originally reserved a `conn_write`
Cmd variant for inbound-WS frame writes. **The post-Phase-2 handler surface
superseded that reservation:** connection output is the **one** `stream.write`
effect surface (`docs/handler-shape.md` §2.2 — "ONE streaming surface"), which
already lowers to `Cmd.stream_chunk`. So an outbound WS frame is just
`stream.write(chunk)`; the WS opcode (text for a string value, binary for
bytes) is carried on the chunk and applied as RFC 6455 framing at the h2
serialize fork (where `http1StreamChunk` lives) for a WS-mode connection. No
distinct `conn_write` Cmd — adding one would re-fork the unified output surface
the Phase-2 reshape deliberately collapsed. Ping/pong are runtime-internal
(auto-pong); close is the handler's terminal return.

## 3. Transport choices — outbound

**Recommended path:** add a `ws: true` mode to `PendingFetch`,
extend `FetchEngine` to set `CURLOPT_CONNECT_ONLY=2` (libcurl's
WebSocket handshake mode), use `curl_ws_recv` / `curl_ws_send` in
the engine loop. The held-transfer infrastructure (no timeout,
per-tenant cap, cooperative cancellation) is unchanged.

Estimated cost: **1–2 weeks** for a working `http.subscribe`-style
WS subscription, plus tests against atproto firehose.

Open detail: the JS binding shape — likely `http.subscribeWs(opts) →
subscription_id` as a sibling of `http.subscribe`, or just a `ws:
true` flag on the existing binding. Decide at binding time;
mechanical.

## 4. Transport choices — inbound

**Three structural options:**

### 4.1 Parallel HTTP/1.1 server stack

Vendor or build an h1 server with RFC 6455 Upgrade. Coexists with
the nghttp2-based h2 stack. ~3-5k LOC depending on framing depth +
edge cases (extensions, compression, fragmentation).

Pros: most compatible (every browser supports it; every WS client
expects it).
Cons: maintenance burden of two HTTP stacks; parser bugs become
attack surface; the h2 stack's careful integration with rove-io
doesn't carry over.

### 4.2 RFC 8441 extended-CONNECT on the existing h2 stack

Add the `:protocol = websocket` pseudo-header support to the
nghttp2 server config. Reuses existing h2 connection machinery.

Pros: one stack; nghttp2 supports it; per-stream multiplexing means
many WS connections per TCP connection.
Cons: **Cloudflare downgrades WS to HTTP/1.1 to origin** per
operator reports. If the platform sits behind Cloudflare (the
documented edge proxy requirement, `architecture/deployment-and-logs.md`), this option
silently fails — the client opens WS to Cloudflare, Cloudflare
opens h1+Upgrade to origin, and the origin's extended-CONNECT
handler never fires.

### 4.3 Cloudflare-aware mixed mode

Edge proxy terminates h2 to clients; on a WS upgrade, the proxy
opens a separate h1 connection to origin. Origin runs both an h2
listener (regular traffic) and an h1 listener (only WS upgrades).
The h1 listener is small (~few hundred LOC) because it only handles
Upgrade — once upgraded, the connection becomes a raw byte stream
the platform owns.

Pros: works behind Cloudflare; smaller h1 surface than 4.1; the
limited-purpose h1 listener doesn't grow into a full HTTP server.
Cons: still two listening ports; operators have to configure proxy
routing rules.

**Recommendation: 4.3.** Smallest h1 surface that survives the
edge-proxy reality. Defer 4.1 until a customer asks for native h1
hosting; defer 4.2 until Cloudflare or whoever stops downgrading.

Estimated cost for 4.3: ~~**6-10 weeks**~~ → **superseded by §4.5.** The
gap-#6 HTTP/1.1 edge work (2026-06-07) already built the h1 listener this
estimate assumed from scratch, dropping the inbound cost to ~1–2 weeks. The
DO-shaped model + revised plan is **§4.5**.

## 4.5 The DO-shaped inbound model + post-gap-#6 plan (decided 2026-06-07)

**Decision: build inbound WebSockets as the Cloudflare-Durable-Object shape.**
A tenant is the object; its connections are held in the tenant's worker(s);
durable state is the tenant's raft-backed KV; idle held connections ride
Phase-6 hibernation. Fan-out splits cleanly into **point-to-point** (platform)
and **broadcast** (a customer recipe on kv wakes) — and that split is *forced by
the model*, not chosen (below).

> **Scope: single-node only, for now.** The baseline targets a tenant served on
> one node — the DO-parity shape. Multi-node held connections (a tenant whose
> connections span machines) are deliberately **not addressed here**; held
> state is single-node by construction today (`architecture/effects-and-handlers.md`)
> and that is the assumption throughout this section.

### Gap #6 already paid the transport cost

§4 priced inbound at **6–10 weeks** because option 4.3 assumed building the
origin h1 listener from scratch. **That listener now exists.** The gap-#6
HTTP/1.1 edge work (2026-06-07, `docs/architecture/routing-and-ingress.md`) shipped, in
`rove-h2` + `rewind-front`:

- the h1 codec (`src/h2/http1.zig`: request parse + response serialize, chunked
  decode/encode, unit-tested) — the `101` Upgrade rides an h1 request, and
  `parseHead` already yields its headers + `Sec-WebSocket-Key`;
- plaintext **and** TLS-via-ALPN h1 ingress (`Conn.h1`, the sniff/handshake
  forks, `:scheme`);
- chunked streaming responses with **backpressure** (`_stream_data_sending`
  one-write-in-flight gate) — the exact outbound-frame write discipline a WS
  connection needs;
- the connection lifecycle (`Http1Conn`, keep-alive, idle GC, the
  decrypt/encrypt seam, `http1Send`).

So §4.3 ("origin runs an h2 listener + a small h1 listener that only handles
Upgrade") is effectively done — *better* than 4.3, since h1 is inline in
rove-h2, not a second listener. **Revised inbound estimate: medium (~1–2
weeks)** — see §4.6.

### Tenant = the Durable Object

Cloudflare DO is single-object-affinity: one addressable instance, all its WS
connections terminate there, that's where state lives. rove's "one tenant →
one raft group → one serving worker" is the same shape, so a **tenant is the DO
analog** — held connections in the tenant's worker(s), durable state in the
tenant's KV, and idle held connections riding the Phase-6 hibernation
active-set (the DO "WebSocket Hibernation" analog; rove already has the
primitive). A held WS connection is a held continuation chain (§5): each
inbound frame dispatches to the `onMessage` export (one new connection
activation kind, the WS analog of `onChunk`); client close → the existing
`onDisconnect` export; outbound frames are `stream.write` (the existing
connection-output effect). One new activation kind (`onMessage`); everything
else reuses the shipped held-handler vocabulary.

### Two fan-out operations, forced apart by the model

| Operation | What | Mechanism | Owner |
|---|---|---|---|
| **point-to-point** | a chunk/disconnect/`send_callback` for *one* known continuation | holder locator (`worker_idx, slot, gen`) + cross-worker inbox | platform |
| **broadcast** | push to *everyone* in a room | `on.kv` trigger + a durable write | customer recipe |

The runtime knows the target of a point-to-point wake (it owns the
continuation), so it routes to the worker that holds it — the existing
held-state routing, shared by every held primitive (fetch, subscribe, WS), not
WS tax (`architecture/effects-and-handlers.md`). Broadcast is the opposite: the
connection-actor model **never exposes a connection handle**
(`connection-actor-unified-trigger.md`), so broadcast *cannot* be "enumerate
the connections and push" — it must be pub-sub on a trigger. So broadcast is
`on.kv`: subscribers park on a room key; a durable write fires the wake; each
parked continuation reads the new message and pushes it down its socket. The
hidden-handle rule guarantees there is no other way to broadcast anyway, which
is why fan-out is a customer recipe, not a platform API.

### Durability: per-frame raft cost is opt-in, and batches via group-commit

A frame costs a raft round-trip **iff its handler activation commits a
non-empty writeset** — that is the whole rule. So:

- **Ephemeral frame** = empty writeset = zero raft + moot-on-loss: cursor /
  presence / typing / live-pointer broadcasts, pure read-and-reply, fan-out to
  other live sockets (a connection-actor write, not a KV write). If the holding
  worker dies the frame is lost — but the socket died with it, so it is
  consistent precisely *because* it promised nothing durable.
- **Durable frame** = non-empty writeset: a persisted chat message, a committed
  CRDT op, or a durable effect (whose owed-marker is itself a KV write).

The atomicity unit is **one activation**: an `onMessage` run's `kv.*` writes +
`stream.write`s commit together as one writeset → one raft entry, exactly like
any other connection activation. The **first single-node cut ships batch-of-1**
(each writing frame is its own activation → its own propose; ephemeral frames
skip raft entirely).

~~To avoid one raft round-trip per durable frame *later*, coalesce via the
connection actor's coalesced trigger into one `onMessage` activation whose
`request.activation.frames` carries the batch.~~ **REJECTED 2026-06-09 (§7) —
there is no `frames:[...]` future goal; one message per `onMessage` is the
permanent shape.** The amortization that design chased is already inherent in
batch-of-1: per-frame activations are fire-and-forget (`proposeForgetfulWrites`
enqueues and returns; replies park commit-gated), every activation's writeset
funnels into the one per-tenant propose inbox, and the bridge's `pumpOnce`
submits the *entire* drained inbox to the group before driving one ready
cycle — so a K-frame burst is K raft entries in **one** Ready: one log append,
one fsync, one MsgAppend RTT, ~one commit round wall-clock. Handler runs are
cheap (the per-request arena reset is one cursor write), so fewer activations
buys nothing. Durability acks stay **per-activation** (a writing frame's
replies gate on its own commit) — strictly better than the batch-granular acks
the coalesced design would have forced. Known, accepted wrinkle: a read-only
frame's inline reply can overtake an in-flight writing frame's commit-gated
reply (writing frames stay FIFO among themselves via the per-tenant commit
order); if strict cross-frame reply ordering is ever demanded, gate inline
emits behind the connection's in-flight commit — a runtime tweak, not an
activation-shape change. Same-Ready grouping is opportunistic (no linger; the
pump races the worker tick) — a guarantee, if ever needed, is a pump-level
lever. Transparent multi-envelope merging of separate activations stays
rejected too (per-inner apply isn't transactional; fault attribution is
batch-granular).

### Non-goals — DO-model-specific (extend §7)

- **A platform broadcast/enumeration API.** Forced out by the hidden-handle
  rule. Room/large fan-out is the customer's kv-wake recipe. A `channel.js` /
  `room.js` shim (pure sugar over `on.kv` + a durable write, à la
  `webhook.send`) may follow **once a common shape emerges from real use** —
  defer per `compose_from_primitives`.
- **Multi-node held connections.** Out of scope (see the scope note above);
  the baseline is a tenant on one node.

## 4.6 Build decomposition + sizing (revised — on the gap-#6 substrate)

| # | Piece | Size | Notes |
|---|---|---|---|
| A | `101` Upgrade handshake | ✅ **DONE** | `wsIsUpgrade` (GET + `Upgrade: websocket` + `Connection: upgrade` token + `Sec-WebSocket-Key`) detected in `http1Drive`; `wsHandshake` replies `101` with `ws.acceptKey` derivation and flips `Http1Conn.ws_mode`. The `101` is queued through the WS outbound path so it precedes any frame in wire order. |
| B | RFC 6455 frame codec (`src/h2/ws.zig`) | ✅ **DONE** (~430 LOC + 16 tests, `zig build ws-test`) | pure parse/serialize: opcode, FIN, mask bit, 7/16/64-bit length, unmask, fragmentation surfaced (opcode+fin), ping/pong/close, `Sec-WebSocket-Accept` derivation. A self-contained table-tested file like `http1.zig`. |
| C | connection mode switch on `Conn` | ✅ **DONE** | `Http1Conn.ws_mode` + reassembly state (`ws_msg`/`ws_msg_opcode`); `http1Feed` routes a ws-mode conn to `wsDrive` (parse loop, auto-pong, close echo, fragment reassembly → emit on `ws_message_out`). TLS decrypt + the read pump are reused from gap #6. |
| E | outbound-frame framing | ✅ **DONE** (h2 side) | NOT a new Cmd. The WS seam is two collections: `ws_message_out` (inbound complete messages) + `ws_send_in` (outbound frames, opcode in `WsMeta`, bytes in `ReqBody`). `consumeWsSends` RFC-6455-frames each by opcode onto the per-conn `ws_out` byte queue; `wsFlush` keeps exactly one socket write in flight (`ws_write_inflight`, released in `writesAccount`) so control frames (pong/close) interleave with data in wire order. **Worker side (lower `stream.write` on a WS conn → `ws_send_in`) lands with piece D.** |
| D | frame → activation | ✅ **DONE** (2026-06-09) | `serviceWsMessages` (`src/js/worker_streaming.zig`) drains `ws_message_out` per tick: find-or-`establishWsChain` (a `parked_continuations` entry, indexed by conn via `ws_chains_by_conn`, deadline `maxInt` so the §6.4 sweep skips it), `fireWsMessage` runs `onMessage`, opcode 8 → `fireWsDisconnect` (`onDisconnect`); `sweepStaleWsChains` catches abrupt conn death. Outbound: read-only frames emit `ws_send_in` inline; a WRITING frame's frames stage as commit-gated `Cmd.ws_send` via `proposeForgetfulWrites` (batch-of-1). The dispatcher's `ws_frame_output` flag (set for `.ws_message` activations) bypasses the Phase-2 stream bridge so `stream.write`+`next()` stays a plain continuation with the chunks left for `shipWsFrames` — without it the activation classifies as an SSE `Stream` descriptor (501). |
| F | functional smoke | ✅ **DONE** (2026-06-09) | `scripts/ws_worker_smoke_v2.py` on the `V2Cluster` harness: deploy an `onMessage`/`onDisconnect` handler, raw RFC 6455 client direct to the node (tenant Host) — text echo, binary echo with embedded NULs (Uint8Array fidelity), `kv.set` frame's reply gated behind the raft commit then visible via `/_system/v2-kv`, `kv.get` round-trip, terminal return → frames-then-Close, client Close → `onDisconnect`, abrupt TCP drop → stale-sweep `onDisconnect`. |
| (shared) | cross-worker held-state locator | **medium, not WS-specific** | `architecture/effects-and-handlers.md`; needed by every held primitive. Amortized, not WS tax. |

**Transport (A/B/C/E-h2) is shipped + proven** by `examples/ws_echo_test.zig`
(`zig build ws-echo`) and `scripts/ws_echo_smoke.py` (raw-socket RFC 6455 client:
101 handshake, text/binary echo, fragment reassembly, auto-pong, close
handshake). **Pieces D + F shipped 2026-06-09** — the single-node inbound
baseline is done. Remaining: broadcast docs (the kv-wake recipe). The
`frames:[...]` coalescing is **rejected outright** (§7) — fsync/RTT
amortization already holds in batch-of-1; one message per `onMessage` is the
permanent shape.

## 5. Handler execution model — the current (post-Phase-2) surface

Per `docs/handler-shape.md` (the shipped held-handler model) +
`architecture/routing-and-ingress.md`:

- A WS connection IS a held continuation chain. `correlation_id` per
  connection; the chain rides Phase-6 hibernation while idle.
- Each inbound frame dispatches to the **`onMessage`** export — one new
  connection activation kind (the WS analog of `onChunk`).
  `request.activation` carries `{ opcode, data }` — **one message per
  activation, permanently** (the batched `frames:[...]` shape is rejected,
  §7). `opcode` is **numeric**
  (1 = text → `data` is a string; 2 = binary → `data` is a Uint8Array the
  handler owns). Binary frames > 16 KB
  go content-addressed via the blob coordinator (architecture/routing-and-ingress.md §7).
- Outbound frames are the **`stream.write(chunk)`** effect (commit-gated,
  like every connection write): a string value → a text frame, bytes → a
  binary frame; the WS-mode connection applies RFC 6455 framing at the h2
  serialize fork. Ping/pong are runtime-internal (auto-pong); the handler
  never sees them.
- **Park for the next frame** = `return next({ctx?})`; **close** = a
  terminal return (the server sends a Close frame). A client-initiated
  close routes to the **`onDisconnect`** export (cleanup is optional —
  a missing `onDisconnect` is a no-op).

```js
// echo: per inbound frame, send it back and stay open.
// `request` is a GLOBAL (exports are invoked with no arguments — a
// `request` parameter would shadow it with undefined).
export function onMessage() {
  const { opcode, data } = request.activation;   // inbound frame
  stream.write(opcode === 2 ? data : `echo:${data}`);  // 2 = binary
  return next();                                  // park for the next frame
}
export function onDisconnect() { /* optional cleanup */ }
```

The **one** new runtime activation kind is `onMessage`; close reuses the
shipped `onDisconnect`, and output reuses the one `stream.write` surface
(`Cmd.stream_chunk`) — no separate `conn_write` Cmd (§2.4).

## 6. Use cases unlocked

| Use case | Direction | Transport needed | Other prereqs |
|---|---|---|---|
| atproto firehose CONSUMER | outbound | §3 libcurl WS | CBOR decoding (customer JS) |
| Pub/Sub / Kafka WS consumer | outbound | §3 libcurl WS | per-vendor framing |
| Real-time chat / presence | inbound | §4 h1 Upgrade stack | none |
| Collab editing (CRDT sync) | inbound | §4 h1 Upgrade stack | CRDT library |
| ActivityPub C2S Streams | inbound | §4 h1 Upgrade stack | C2S protocol shims |
| atproto PDS server | inbound | §4 h1 Upgrade stack | atproto protocol shims |

**Sequencing recommendation:** ship §3 (outbound) first — unlocks
fediverse consumer + atproto firehose with ~1-2 weeks of work + low
architectural risk. Inbound §4 is the multi-week structural
commitment; do it when a concrete consumer materializes (customer
shipping a chat app, or rewindjs's own dashboard wanting real-time
collab).

## 7. Out of scope (locked rejections — do not re-propose)

- **A batched `frames:[...]` `onMessage` activation** (the former §4.5
  coalesced-trigger perf phase). Rejected 2026-06-09: fsync/RTT amortization
  is inherent in the batch-of-1 propose pipeline (§4.5 as-built — K frames =
  K entries in one Ready/fsync), handler runs are cheap, and the batch shape
  would re-introduce batch-granular durability acks plus a second activation
  contract for no win. If strict cross-frame reply ordering or extreme-rate
  per-entry overhead ever materializes, the levers are runtime-level (gate
  inline emits behind the in-flight commit; pump-side linger) — not a handler-
  surface change.
- **WebSocket compression extensions (permessage-deflate).** RFC 7692.
  Adds memory + CPU overhead; the small-frame use case doesn't need
  it. Revisit if WS becomes a large-frame transport workhorse.
- **Multi-frame transactions.** WS frame ordering is per-connection;
  cross-connection ordering is the customer's problem.
- **Server-pushed WS via h2 PUSH_PROMISE.** Deprecated by browsers;
  doesn't apply.
- **Replacing SSE with WS for the live-UI-update use case.** SSE via the
  `stream.*` surface covers that case today (`architecture/routing-and-ingress.md` §3-§4);
  WS is for the cases SSE can't (bidirectional, binary, custom
  framing).

## 8. Open questions

- **Binding shape for outbound WS.** `http.subscribeWs(opts)` as a
  sibling of `http.subscribe`, or `ws: true` flag on the existing
  binding. Decide when implementing.
- **Per-tenant WS connection caps.** Inbound: same cap shape as
  inbound h2 streams. Outbound: same cap as `http.subscribe`
  (`HELD_MAX_PER_TENANT=16`).
- **Large binary frame threshold.** Streaming-model §3 says ≤16 KB
  inline / >16 KB through coord; WS frames probably inherit the
  same threshold but should be verified against typical frame sizes
  (atproto repo commits, chat messages).
- **Reconnect / cursor policy.** Customer composes via kv per the
  framework principle. No platform-managed cursor store.
- ~~**Cross-worker fan-out.**~~ **RESOLVED in §4.5:** point-to-point wakes route
  to the holding worker (platform held-state routing); broadcast is the
  customer's `on.kv` recipe — the hidden-handle rule forces it onto pub-sub.
  Multi-node held connections are out of scope (single-node baseline).
- ~~**Inbound durability per frame.**~~ **RESOLVED in §4.5:** a frame costs
  raft iff its activation writes; ephemeral frames are free + moot-on-loss;
  a burst of writing frames stays one-entry-per-frame but the entries share
  one Ready/fsync/RTT through the per-tenant propose pipeline (the batched-
  activation coalescing was rejected — §7).

## 9. Relation to other docs

- **`architecture/routing-and-ingress.md` §3 (inbound chunks) + §4 (outbound chunks)**
  — the execution model WS rides. No changes needed.
- **`architecture/effects-and-handlers.md` §6.3** (WebSocket projection) + §6.5
  (atproto firehose) — superseded by this doc. §6.3 should
  collapse to "see websocket-plan.md"; §6.5 keeps the chain-merge
  semantics specific to atproto.
- **`architecture/effects-and-handlers.md` Phase 4.1.4** (`conn_write` Cmd
  slot) — **superseded:** the Phase-2 `stream.*` reshape made
  `stream.write` the one connection-output surface, so outbound WS
  frames lower to `Cmd.stream_chunk` (opcode-tagged), not a new
  `conn_write` Cmd (§2.4). That reservation can be struck.
- **Held outbound subscription** (`architecture/effects-and-handlers.md`) — shipped via
  `http.subscribe`; the "WS framing remains separate" note now
  resolves to this doc.
- **`architecture/effects-and-handlers.md` §13** (out of scope: WS transport)
  — resolves to this doc.
- **`PLAN.md` §2.12 "Why SSE not WebSockets"** — the deferral
  rationale; this doc is where the v2 work lives.
