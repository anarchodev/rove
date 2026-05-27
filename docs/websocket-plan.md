# WebSocket plan — transport, handler shape, and the use cases it unlocks

> **Status**: planned, not started — 2026-05-27. Consolidates the
> WebSocket-blocked items scattered across other docs (`connection-actor-plan.md`
> §6.3 + §6.5, `effect-reification-plan.md` Phase 4.1.4 `conn_write`,
> `primitive-gaps.md` §2.5 forward note, `streaming-handlers-plan.md`
> §13 out-of-scope, the deleted `curl-multi-plan.md` Phase 4) into one
> place. The execution model is already specified (`streaming-model.md`
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
- Execution model is **fully shipped.** Each upstream WS frame is
  an `inbound_chunk`-shaped Msg on the held chain — the same shape
  `http.subscribe`'s on_chunk activations already use.
- Tape determinism is **already covered.** Per-chain tape budget
  (`streaming-model.md` §3) handles WS frame replay the same way it
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
  `effect-reification-plan.md` Phase 4.1.4 `conn_write` — added
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
- ✅ Per-frame activation model — `inbound_chunk` shape works
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
build the receive-half via long-poll over `__rove_stream` (works but
chatty), but they can't expose a real WebSocket endpoint that browsers
expect.

Blocked on the h1 stack work above. The execution model is fully
covered by streaming-handlers `__rove_stream` + per-frame
`inbound_chunk` activations — no design work, just transport.

### 2.3 Federation inbound (ActivityPub C2S, atproto PDS server)

ActivityPub C2S Streams API uses WS. Same as inbound WS endpoints —
gated on the h1 stack. ActivityPub S2S (server-to-server) is
HTTP-only and already works without WS per
[[project_fediverse_libs]] ("AP needs ZERO transport work").

### 2.4 effect-reification `conn_write` Cmd slot

`effect-reification-plan.md` Phase 4.1.4 deferred adding the
`conn_write` Cmd variant for inbound-WS frame writes. The typed Cmd
union has slots for every producer-bearing variant; `conn_write`
gets added when the inbound-WS producer exists, not before
(parking the typed slot in advance was caught as Option-1
scaffolding in the 2026-05-24 audit).

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
documented edge proxy requirement, `deployment.md`), this option
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

Estimated cost for 4.3: **6-10 weeks** including framing, ping/pong,
fragmentation, smoke coverage.

## 5. Handler execution model — already shipped, recap

Per `streaming-model.md` and `connection-actor-plan.md` §6.3:

- A WS connection IS a held stream chain. `correlation_id` per
  connection.
- Each inbound frame is an `inbound_chunk` Msg on the chain. Binary
  frames > 16 KB go content-addressed via the blob coordinator
  (streaming-model.md §7).
- Handler returns `__rove_stream({write: [...frames], waitFor: {...}})`
  to send + park for the next wake.
- Disconnect is a `disconnect` Msg.

No new Msg/Cmd vocabulary needed beyond `conn_write` (Phase 4.1.4
deferral) for the outbound-frame Cmd.

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

- **WebSocket compression extensions (permessage-deflate).** RFC 7692.
  Adds memory + CPU overhead; the small-frame use case doesn't need
  it. Revisit if WS becomes a large-frame transport workhorse.
- **Multi-frame transactions.** WS frame ordering is per-connection;
  cross-connection ordering is the customer's problem.
- **Server-pushed WS via h2 PUSH_PROMISE.** Deprecated by browsers;
  doesn't apply.
- **Replacing SSE with WS for the live-UI-update use case.** SSE +
  `__rove_stream` covers that case today (`streaming-model.md` §3-§4);
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

## 9. Relation to other docs

- **`streaming-model.md` §3 (inbound chunks) + §4 (outbound chunks)**
  — the execution model WS rides. No changes needed.
- **`connection-actor-plan.md` §6.3** (WebSocket projection) + §6.5
  (atproto firehose) — superseded by this doc. §6.3 should
  collapse to "see websocket-plan.md"; §6.5 keeps the chain-merge
  semantics specific to atproto.
- **`effect-reification-plan.md` Phase 4.1.4** (`conn_write` Cmd
  slot) — adds when inbound-WS lands per this plan.
- **`primitive-gaps.md` §2.5** — outbound subscription shipped via
  `http.subscribe`; the "WS framing remains separate" note now
  resolves to this doc.
- **`streaming-handlers-plan.md` §13** (out of scope: WS transport)
  — resolves to this doc.
- **`PLAN.md` §2.12 "Why SSE not WebSockets"** — the deferral
  rationale; this doc is where the v2 work lives.
