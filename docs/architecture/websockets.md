# WebSockets (inbound, as-built)

> 🟢 **As-built.** Inbound WebSocket serving — a tenant's clients open
> WS connections, the handler receives frames and replies. Shipped: the
> single-node baseline (2026-06-09) and WS-through-the-front via RFC 8441
> Extended CONNECT (2026-06-12). The raw RFC 6455 transport at the edge is
> in [`routing-and-ingress.md`](routing-and-ingress.md) (the `## WebSocket`
> section + code map); the held-connection handler surface is
> [`handler-shape.md`](../handler-shape.md) and
> [`effects-and-handlers.md`](effects-and-handlers.md). **Outbound** WS
> (a handler as a *client* of an upstream WS server — atproto firehose,
> Pub/Sub) is a separate, unbuilt plan: [`../websocket-plan.md`](../websocket-plan.md).

## The shape in one paragraph

A WS connection is a **held continuation chain** — the same primitive as a
held `http.subscribe` or an SSE stream (`effects-and-handlers.md`,
connection-actor). Each inbound frame dispatches to the customer's
`onMessage` export (the WS analog of `onChunk`); outbound frames are the
`stream.write` effect; a client close routes to `onDisconnect`. Idle held
connections ride Phase-6 hibernation. There is exactly **one** new runtime
activation kind (`onMessage`); everything else reuses the shipped
held-handler vocabulary.

## Tenant = the Durable Object

The model is deliberately Cloudflare-Durable-Object-shaped. A DO is
single-object-affinity: one addressable instance, all its WS connections
terminate there, that is where state lives. rove's "one tenant → one raft
group → one serving worker" is the same shape, so **a tenant is the DO
analog** — held connections in the tenant's worker, durable state in the
tenant's KV, idle connections riding the hibernation active-set (the DO
"WebSocket Hibernation" analog).

**Scope: single-node.** The baseline targets a tenant served on one node.
Multi-node held connections (a tenant whose connections span machines) are
out of scope — held state is single-node by construction today
(`effects-and-handlers.md`).

## Two fan-out operations, forced apart by the model

| Operation | What | Mechanism | Owner |
|---|---|---|---|
| **point-to-point** | a chunk/disconnect/`send_callback` for *one* known continuation | holder locator (`worker_idx, slot, gen`) + cross-worker inbox | platform |
| **broadcast** | push to *everyone* in a room | `on.kv` trigger + a durable write | customer recipe |

The runtime knows the target of a point-to-point wake (it owns the
continuation), so it routes to the worker that holds it — the existing
held-state routing shared by every held primitive, not a WS tax. Broadcast
is the opposite: the connection-actor model **never exposes a connection
handle** (`decisions.md` §13.2), so broadcast *cannot* be "enumerate the
connections and push" — it must be pub-sub on a trigger. So broadcast is
`on.kv`: subscribers park on a room key; a durable write fires the wake;
each parked continuation reads the new message and pushes it down its
socket. The hidden-handle rule guarantees there is no other way to
broadcast anyway, which is why fan-out is a customer recipe (a `channel.js`
/ `room.js` shim may follow once a common shape emerges from real use), not
a platform API.

## Durability — per-frame raft cost is opt-in

A frame costs a raft round-trip **iff its handler activation commits a
non-empty writeset.** That is the whole rule.

- **Ephemeral frame** = empty writeset = zero raft + moot-on-loss:
  cursor / presence / typing / live-pointer broadcasts, pure read-and-reply.
  If the holding worker dies the frame is lost — but the socket died with
  it, so it is consistent precisely because it promised nothing durable.
- **Durable frame** = non-empty writeset: a persisted chat message, a
  committed CRDT op, or a durable effect (whose owed-marker is a KV write).

The atomicity unit is **one activation**: an `onMessage` run's `kv.*`
writes + `stream.write`s commit together as one writeset → one raft entry,
exactly like any other connection activation. The cut ships **batch-of-1**
(each writing frame is its own activation → its own propose; ephemeral
frames skip raft).

**Amortization is inherent, not a future coalescing goal.** Per-frame
activations are fire-and-forget (`proposeForgetfulWrites` enqueues and
returns; replies park commit-gated); every activation's writeset funnels
into the one per-tenant propose inbox; the bridge's `pumpOnce` submits the
*entire* drained inbox to the group before driving one Ready cycle — so a
K-frame burst is K entries in **one** Ready: one log append, one fsync, one
MsgAppend RTT, ~one commit round wall-clock. Durability acks stay
per-activation (a writing frame's replies gate on its own commit). The
batched `frames:[...]` activation that would have chased this amortization
is **rejected** (see rejections below).

## Strict ordering + read-your-writes — the per-connection input gate

Built 2026-06-09; the DO-input-gate analog, in the worker, no
handler-surface change. While a writing frame's forgetful unit awaits raft
(`WsConnState.gate_seq`), frames arriving on that connection **queue**
(`WsConnState.queue`) instead of activating. `flushWsGates` re-opens the
gate once the seq is committed **and** the drain has released the unit's
reply frames (the unit check — not just the commit watermark — is what
makes "prior replies already reached `ws_send_in`" true; the watermark
advances on the pump thread and can lead the drain), then dispatches the
queue in arrival order. Consequences:

- replies on one socket arrive in **message order** across the durability
  boundary;
- frame K+1 activates post-commit, so it **reads frame K's writes** (without
  the gate it read the committed-only view — a smoke caught `read:`
  returning `<none>` for a value the previous frame had written);
- a queued client-Close runs `onDisconnect` only after the data frames
  ahead of it;
- fault/timeout of the gated commit **closes the connection** (the discarded
  reply can't be honestly re-created).

The independent-read fast path is preserved: a read-only frame with no
in-flight write emits inline. Companion read-side dual
(`worker_dispatch.zig`): a read-only frame whose commit returns kvexp
`NotChainHead` (its read crossed *another producer's* in-flight overlay)
re-ships through an empty-writeset **barrier propose**, so frames computed
on un-durable state reach the wire only after the chain commits. Smoke:
`scripts/ws_ordering_smoke_v2.py`.

## Handler surface

Per `handler-shape.md`:

- `request.activation` carries `{ opcode, data }` — **one message per
  activation, permanently**. `opcode` is numeric (1 = text → `data` is a
  string; 2 = binary → `data` is a `Uint8Array` the handler owns). Binary
  frames > 16 KB go content-addressed via the blob coordinator
  (`routing-and-ingress.md` §7).
- Outbound frames are `stream.write(chunk)` (commit-gated, like every
  connection write): a string → a text frame, bytes → a binary frame;
  the WS-mode connection applies RFC 6455 framing at the serialize fork.
  Ping/pong are runtime-internal (auto-pong); the handler never sees them.
- **Park for the next frame** = `return next({ctx?})`; **close** = a
  terminal return. A client-initiated close routes to `onDisconnect`
  (optional — a missing `onDisconnect` is a no-op).

```js
export function onMessage() {
  const { opcode, data } = request.activation;          // inbound frame
  stream.write(opcode === 2 ? data : `echo:${data}`);   // 2 = binary
  return next();                                        // park for the next
}
export function onDisconnect() { /* optional cleanup */ }
```

Output reuses the one `stream.write` surface (`Cmd.stream_chunk`,
opcode-tagged) — there is no separate `conn_write` Cmd.

## Transport — build status

The raw transport is `src/h2/ws.zig` (pure RFC 6455 codec) + the rove-h2
seam (`ws_message_out` inbound / `ws_send_in` outbound collections). Pieces:

| # | Piece | Status |
|---|---|---|
| A | `101` Upgrade handshake (`wsIsUpgrade` / `wsHandshake`) | ✅ done |
| B | RFC 6455 frame codec (`src/h2/ws.zig`, table-tested, `zig build ws-test`) | ✅ done |
| C | connection mode switch (`Http1Conn.ws_mode` → `wsDrive`) | ✅ done |
| D | frame → `onMessage`/`onDisconnect` activation (`serviceWsMessages`, `src/js/worker_ws.zig`) | ✅ done (2026-06-09) |
| E | outbound framing (`consumeWsSends` / `wsFlush`, one write in flight) | ✅ done |
| F | functional smoke (`scripts/ws_worker_smoke_v2.py`) | ✅ done (2026-06-09) |

Edge transport detail (handshake, `wsDrive`, the seam) lives in
`routing-and-ingress.md` `## WebSocket (RFC 6455)`.

## Through the front — Extended CONNECT (RFC 8441); the worker is h2c-only

Shipped 2026-06-12. The front terminates the WS handshake at the edge and
tunnels each connection upstream as an RFC 8441 Extended CONNECT stream
(`:method CONNECT`, `:protocol websocket`) on the **existing pooled h2c
connection** — no per-WS upstream socket, per-stream flow control for free.
Once the worker accepts WS as h2 streams, nothing pins h1 to the worker, so
the **worker is h2c-only** (`accept_http1 = false`); h1 termination, like
TLS, is the front's job alone. (Rejected alternative: a dedicated
h1-upgrade client leg per WS connection — a throwaway half-measure that
keeps h1 + socket-hijack in the worker forever.)

**Identity model.** A logical WS connection is an opaque `Entity`
everywhere in the worker seam (`ws_conns` keys, `ws_message_out` Session,
`emitWsSend`). Under 8441 it is a per-CONNECT-stream identity entity in the
`ws_streams` collection; routing comes from the CONNECT `:authority`/`:path`.

**Worker server side** (`H2Options.extended_connect`):
1. `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1` on server sessions.
2. `:method CONNECT` + `:protocol websocket` → identity entity into
   `ws_connect_out`; the worker dispositions the tunnel (resolve tenant,
   leadership check, auth/plan gates) and either `wsConnectAccept`
   (`:status 200`, no END_STREAM) or `wsConnectReject(status)` — a **421**
   makes the front re-aim at the next node (fixes the h1-direct flaw where
   the `101` succeeded on a follower and the first frame then failed).
3. Inbound stream DATA carries RFC 6455 frames (browser masking intact, the
   front relays bytes verbatim): per-stream `WsReassembler`, auto-pong,
   close → `ws_message_out` opcode 8. Window consumed immediately — the
   §input-gate is the real backpressure.
4. Outbound: `consumeWsSends` grows an h2 arm (frames onto a per-stream byte
   queue through the streaming-response data provider). Stream close →
   destroy the identity entity (the seam sweep fires `onDisconnect`).

**Front side.** The h1 listener surfaces Upgrade requests to the consumer
(`ws_upgrade_out`); the proxy resolves the route and opens the upstream
CONNECT (`client_ws_connect_in`, gated on the peer's
ENABLE_CONNECT_PROTOCOL). Only on upstream `:status 200` does it complete
the downstream `101` and enter raw-relay tunnel mode (no frame parsing at
the front). Upstream 421 → next node; exhausted → plain 502 downstream (no
`101` ever sent — clean failure).

Open verify-items: nghttp2 1.66 Extended CONNECT client-submit ordering
(peer SETTINGS observed first); shared-conn fairness for a firehose WS vs
request traffic on the pooled conn; WS close-handshake ↔ stream half-close
mapping in both directions.

## Locked rejections (do not re-propose)

- **A batched `frames:[...]` `onMessage` activation** (the former
  coalesced-trigger perf phase). Rejected 2026-06-09: fsync/RTT
  amortization is inherent in the batch-of-1 propose pipeline (K frames =
  K entries in one Ready/fsync), handler runs are cheap, and the batch
  shape would re-introduce batch-granular durability acks plus a second
  activation contract for no win. Strict cross-frame ordering was demanded
  and built runtime-level as the input gate — proving the point: no
  handler-surface change. If extreme-rate per-entry overhead ever
  materializes, the lever is pump-side (linger), still not a surface change.
- **permessage-deflate (RFC 7692).** Memory + CPU overhead; the small-frame
  use case doesn't need it. Revisit if WS becomes a large-frame workhorse.
- **Multi-frame transactions.** Frame ordering is per-connection;
  cross-connection ordering is the customer's problem.
- **Server-pushed WS via h2 PUSH_PROMISE.** Deprecated by browsers.
- **Replacing SSE with WS for live-UI updates.** SSE via the `stream.*`
  surface covers that today (`routing-and-ingress.md` §3–§4); WS is for the
  cases SSE can't — bidirectional, binary, custom framing.

## Use cases this unlocks

Real-time chat / presence, collaborative editing (CRDT sync), ActivityPub
C2S streams, an atproto PDS server — all the **inbound** rows of the
use-case table. The **outbound** consumer cases (atproto firehose, Pub/Sub)
need the separate outbound transport — `../websocket-plan.md`.
