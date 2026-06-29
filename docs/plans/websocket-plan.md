# WebSocket — outbound (future work)

> **Status: outbound WS is unbuilt.** A handler acting as a *client* of an
> upstream WebSocket server — consuming the atproto firehose, a Pub/Sub
> stream, or a custom WS API. The transport is the only real gap (~1–2
> weeks, low architectural risk); the execution model and tape determinism
> already fall out of the shipped held-fetch machinery.
>
> **Inbound WS (serving WS endpoints to a tenant's clients) is shipped** —
> single-node baseline (2026-06-09) + WS-through-the-front via RFC 8441
> Extended CONNECT (2026-06-12). Its as-built design lives in
> [`architecture/websockets.md`](../architecture/websockets.md); the edge
> transport is [`architecture/routing-and-ingress.md`](../architecture/routing-and-ingress.md)
> `## WebSocket`. This doc is **only** the outbound half.

## 1. Why outbound is close

- **Transport is mostly here.** `fetch_engine.zig` is a curl_multi engine
  driving N concurrent transfers on one thread; libcurl supports WebSocket
  in recent versions (`CURLOPT_CONNECT_ONLY=2` + `curl_ws_recv` /
  `curl_ws_send`). The closest unstarted work is a `ws: true` mode on the
  existing `held` `PendingFetch`.
- **Execution model is fully shipped.** Each upstream WS frame resumes the
  held chain as a bound-`on.fetch` chunk activation — the same `onFetchChunk`
  export `http.subscribe`'s streamed reads already dispatch to. No new
  activation kind, no handler-surface work.
- **Tape determinism is already covered.** An upstream WS frame replays the
  same way as an SSE / `on.fetch` chunk: a `fetch_responses` entry per frame,
  bytes inline when small or by `BodyRef` extent when large
  (`decisions.md` §3.9).

## 2. The forcing function — atproto firehose consumer

`com.atproto.sync.subscribeRepos` — server→client, binary, sequenced,
cursor-resumable. The forcing function for the fediverse vertical
([[project_fediverse_libs]]).

Status:
- ✅ Long-lived held connection — `http.subscribe` shipped 2026-05-24.
- ✅ Per-frame activation model — the `onFetchChunk` activation shape works.
- ✅ Per-tenant cap, cooperative cancellation.
- ❌ **WS framing** — currently just HTTP body chunks via curl_multi; needs
  WebSocket frame parsing (binary opcodes, ping/pong). **This is the gate.**
- ❌ **CBOR / DAG-CBOR decoding** of frame payloads — atproto-specific, out
  of any transport plan (a customer JS library).
- ❌ **Cursor / sequence persistence** — customer-composed via kv, per the
  framework's "customer owns reconnect state" principle.

So the gate IS the WS frame parsing: add a `ws: true` mode to the existing
`held` `PendingFetch`; libcurl handles the frame parsing; the chunk callback
delivers frames instead of bytes. Reuses the existing chain activation
machinery.

## 3. Transport — the build

**Recommended path:** add a `ws: true` mode to `PendingFetch`; extend
`FetchEngine` to set `CURLOPT_CONNECT_ONLY=2` (libcurl's WebSocket handshake
mode); use `curl_ws_recv` / `curl_ws_send` in the engine loop. The
held-transfer infrastructure (no timeout, per-tenant cap, cooperative
cancellation) is unchanged.

Outbound frames a handler sends to the upstream are the **one**
`stream.write` surface (a string → text frame, bytes → binary), the same
effect inbound WS and SSE use — no separate `conn_write` Cmd (the Phase-2
reshape collapsed connection output onto `Cmd.stream_chunk`; the old
`effects-and-handlers.md` Phase 4.1.4 `conn_write` reservation is struck).
Ping/pong are runtime-internal; close is the handler's terminal return.

**Estimated cost: ~1–2 weeks** for a working `http.subscribe`-style WS
subscription, plus tests against the atproto firehose. Low architectural
risk — it rides shipped held-fetch machinery.

## 4. Use cases unlocked

| Use case | Transport needed | Other prereqs |
|---|---|---|
| atproto firehose consumer | this doc (libcurl WS) | CBOR decoding (customer JS) |
| Pub/Sub / Kafka WS consumer | this doc (libcurl WS) | per-vendor framing (customer JS) |

(Inbound use cases — chat, presence, collab editing, ActivityPub C2S,
atproto PDS server — are served by the shipped inbound stack,
`architecture/websockets.md`.)

## 5. Open questions

- **Binding shape.** `http.subscribeWs(opts)` as a sibling of
  `http.subscribe`, or a `ws: true` flag on the existing binding. Decide
  when implementing.
- **Per-tenant cap.** Same cap as `http.subscribe` (`HELD_MAX_PER_TENANT`).
- **Large binary frame threshold.** Streaming-model §3 says ≤16 KB inline /
  >16 KB through the coordinator; WS frames probably inherit the same
  threshold but should be verified against typical sizes (atproto repo
  commits).
- **Reconnect / cursor policy.** Customer-composed via kv, per the framework
  principle. No platform-managed cursor store.

## 6. Out of scope (locked rejections)

- **A platform-managed reconnect/cursor store.** Reconnect state is the
  customer's kv (the "customer owns reconnect state" principle).
- **Vendor framing baked into the engine** (CBOR/DAG-CBOR, Kafka framing).
  Customer JS libraries on top of the raw frame stream.

(Inbound-specific rejections — the batched `frames:[...]` activation,
permessage-deflate, etc. — are in `architecture/websockets.md`.)
