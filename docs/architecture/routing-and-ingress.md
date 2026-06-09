# Routing & ingress

> 🟢 **As-built reference.** How a request gets from the client to the owning
> worker, the wire protocols accepted at the edge, and the streaming substrate
> underneath held connections. Owns `src/front/` (the front door), `src/h2/`
> (HTTP/2 + HTTP/1.1 + WebSocket + TLS), and the streaming substrate in
> `src/blob/coordinator.zig` + `src/js/chunk_spool.zig`. For the directory that
> backs routing and tenant-move orchestration see
> [`control-plane.md`](control-plane.md); for the handler side of held
> connections see [`effects-and-handlers.md`](effects-and-handlers.md). Why:
> [decisions.md §10](../decisions.md) (V2 front door), §3.4–3.5 (streaming).

## The shape in one paragraph

`rewind-front` is a **stateless** TLS-terminating reverse proxy: it resolves
`Host → cluster` from the control-plane directory (cached), then proxies
**leader-aware** (retry-on-503 self-routes a write to the group leader). The
front accepts HTTP/2, HTTP/1.1, and WebSocket at the edge and speaks h2c to the
data-plane on the private network. Streaming obeys one rule — a byte reaches the
wire only after the activation that produced it commits — and a blob coordinator
+ per-fetch chunk spool decouple a fast upstream from the raft-commit cadence.

## Code map

| File | Role |
|---|---|
| `src/front/main.zig` | `rewind-front`: `Router` + `RouteCache` (Host→nodes, TTL), `proxyToCluster` (libcurl h2c, 503 leader-retry), `/_cp/route` + cert polling, the `:80` ACME HTTP-01 responder + HTTPS redirect, the move-orchestration entry. |
| `src/h2/root.zig` | rove-h2 server (nghttp2): per-stream request entities; `Conn` dual-stack (h2 + `Http1Conn`); the WebSocket collections `ws_message_out` / `ws_send_in`. |
| `src/h2/http1.zig` | Pure HTTP/1.1 codec: `parseHead` → `:method/:path/:authority/:scheme`, resumable `decodeChunked`, `Expect: 100-continue`, keep-alive, chunked response serialize. |
| `src/h2/ws.zig` | Pure RFC 6455 codec: `acceptKey`, `Opcode`, `parseFrame` (unmask in place, FIN/fragmentation surfaced), server-frame serialize. |
| `src/h2/tls.zig` | TLS termination (OpenSSL): `alpnSelectCb` advertises `h2` + `http/1.1`; SNI `host_store` + per-host `SSL_CTX`; `reloadCustomCerts` mtime poll; optional mTLS. |
| `src/blob/coordinator.zig` | Blob coordinator: per-worker submission queue + monotonic seq, durable HWM (`durableSeq`), K=32 executor PUT pool, `bodyRef`/`readBody`. |
| `src/js/chunk_spool.zig` | Per-fetch FIFO chunk spool: K-deep RAM window (default 4), evicts to the coordinator, reads back on dispatch. |

## Front door & routing

- **Stateless**: holds no raft state. Per request it resolves `:authority` →
  cluster via `Router.resolveRoute(host)`, backed by `RouteCache` (host → node
  URLs, TTL-bound) with a CP query (`GET /_cp/route?host=`) on miss.
- **Leader-aware proxy** (`proxyToCluster`): tries the cluster's nodes in order
  and stops at the first non-503. A follower 503s a write (the bridge faults a
  non-leader propose), so a write self-routes to the leader; a read is served by
  any synced node. See [decisions.md §10.5](../decisions.md).
- **Serve-or-forward**: a request that reaches the wrong cluster is forwarded by
  the data plane, not failed (the directory is the cutover authority; a stale
  front-door hint is one extra hop, never an error). See `control-plane.md`.

## TLS & ACME

- **Termination is ours, at the front door** (not a CDN/LB) — decisions.md §10
  / the V2 front-door design. Client→front is TLS; front→DP is h2c on the
  private network.
- **ALPN** (`alpnSelectCb`) advertises `h2` then `http/1.1` (server preference);
  the negotiated protocol selects the h2 path or the h1 codec path. No-ALPN
  clients default to h1.
- **SNI**: `host_store` maps host → per-host `SSL_CTX` (built with the same ALPN
  + TLS-min), wildcard fallback for unknown SNI. `reloadCustomCerts` polls the
  cert dir (mtime-driven) so newly-issued certs install within ~1 s.
- **ACME HTTP-01** runs on a dedicated `:80` plaintext listener:
  `/.well-known/acme-challenge/<token>` is answered from the CP; everything else
  308-redirects to HTTPS. Issuance itself lives in the control plane / auth layer
  — see [`auth-and-domains.md`](auth-and-domains.md).

## HTTP/1.1 ingress

The same `Conn` carries either an nghttp2 session or an `Http1Conn` (mutually
exclusive). A plaintext first read that `looksLikeHttp1Request` (or an ALPN-h1
negotiation) swaps in the h1 path. `parseHead` synthesizes the h2 pseudo-headers
(`:authority` from `Host`, `:scheme` from TLS-or-plaintext) on a synthetic
`StreamId=1`, so the rest of the pipeline is protocol-agnostic. `decodeChunked`
is resumable; `Expect: 100-continue` is answered once at the edge; responses
serialize with `Content-Length` or `Transfer-Encoding: chunked`, with one-write-
in-flight backpressure on the streaming path. h1→h2c translation is **edge-only**.

## WebSocket (RFC 6455)

- **Handshake**: an h1 `GET` with `Upgrade: websocket` is detected in
  `parseHead`; the server replies `101` with the derived `Sec-WebSocket-Accept`,
  flips `Http1Conn.ws_mode`, and continues into `wsDrive`.
- **Inbound**: `wsDrive` parses frames (unmask in place), auto-replies to pings,
  reassembles fragments to a complete message, echoes close, and moves the
  message onto `ws_message_out` (opcode on `WsMeta`).
- **Outbound**: a worker `stream.write` lowers to a frame on `ws_send_in`
  (reusing `Cmd.stream_chunk`, opcode-tagged — there is **no** separate
  `conn_write`), serialized with one write in flight per connection.
- **Status**: the transport (handshake + framing + inbound/outbound collections)
  is shipped and proven (`zig build ws-echo`, `scripts/ws_echo_smoke.py`). The
  remaining piece is the worker-side `onMessage` dispatch seam (piece D) — see
  `effects-and-handlers.md`.

## Streaming substrate

- **The one rule** (decisions.md §3.5): a chunk reaches the wire only after the
  activation that produced it commits. An ordinary request is one activation →
  one commit → one flush (so a 5xx is clean and effects are durable before the
  response). A streaming chain flushes per-chunk, each post-commit.
- **Inbound coalescing**: the runtime introspects the handler — a `default`
  export coalesces the whole body (≤ 1 MB) into one activation (the fast path);
  an `onChunk` export takes it per-chunk. Outbound `http.fetch` coalescing is the
  auto-bind behavior described in `effects-and-handlers.md`.

## Blob coordinator & chunk spool

- **Coordinator** (`src/blob/coordinator.zig`): a worker `submit`s bytes to an
  MPSC queue and gets a monotonic `seq` with no allocation on the path; a K=32
  executor pool PUTs each batch to `_pool/{batch_id}` with backoff on 503/429;
  `durableSeq(worker_id)` is the contiguous-prefix durable high-water mark (a
  raft analog); `bodyRef`/`readBody` serve bytes once durable. `batch_id`s come
  from a raft-reserved block (cross-leader-unique). This is the durability ground
  truth for streamed bytes.
- **Chunk spool** (`src/js/chunk_spool.zig`): a per-fetch FIFO RAM window (default
  K=4, `ROVE_BOUND_FETCH_SPOOL_DEPTH`) over the coordinator. It lets a fast
  upstream race ahead of the raft-commit cadence: chunks past the window evict to
  the coordinator and read back on dispatch. The spool is ephemeral — taped bytes
  are captured at activation time, so the spool never affects replay.

## Held connections (connection-actor)

SSE, WebSocket, and held-sync third-party calls are one primitive: a held entity
on the worker (`parked_continuations`), driven by per-connection wakes (open /
inbound / timeout / signal / close), with **no handle exposed to JS** — the chain
*is* the connection by construction. The held-sync call (a cosmetically-synchronous
third-party request → callback → response, with a mandatory timeout) is shipped;
the design and the wake model live in [`effects-and-handlers.md`](effects-and-handlers.md)
and the customer contract in [`handler-shape.md`](../handler-shape.md).

## Known limitations (as-built)

- **Worker `onMessage` seam (WebSocket piece D)** is the one transport-adjacent
  gap; everything below it is wired.
- **Front→DP is per-request connect** today (no keep-alive pool to the data
  plane) — a known follow-up, not a correctness issue.
- **Held connections are single-node** per cluster in the baseline; the
  cross-worker locator that held primitives share is described in
  `effects-and-handlers.md`.
