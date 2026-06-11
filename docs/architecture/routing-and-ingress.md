# Routing & ingress

> 🟢 **As-built reference.** How a request gets from the client to the owning
> worker, the wire protocols accepted at the edge, and the streaming substrate
> underneath held connections. Owns `src/front/` (the front door), `src/h2/`
> (HTTP/2 + HTTP/1.1 + WebSocket + TLS), the streaming substrate in
> `src/blob/coordinator.zig` + `src/js/chunk_spool.zig`, and the customer blob
> ingress (`src/blob/s3.zig`, `src/js/blob_receive.zig`,
> `src/js/blob_sessions.zig`). For the directory that
> backs routing and tenant-move orchestration see
> [`control-plane.md`](control-plane.md); for the handler side of held
> connections see [`effects-and-handlers.md`](effects-and-handlers.md). Why:
> [decisions.md §10](../decisions.md) (V2 front door), §3.4–3.5 (streaming).

## The shape in one paragraph

`rewind-front` is a **stateless** TLS-terminating reverse proxy: it resolves
`Host → cluster` from the control-plane directory (cached), then proxies
**leader-aware** (retry-on-421 self-routes a write to the group leader). The
front accepts HTTP/2, HTTP/1.1, and WebSocket at the edge and speaks h2c to the
data-plane on the private network. Streaming obeys one rule — a byte reaches the
wire only after the activation that produced it commits — and a blob coordinator
+ per-fetch chunk spool decouple a fast upstream from the raft-commit cadence.

## Code map

| File | Role |
|---|---|
| `src/front/main.zig` | `rewind-front` boot + edge config: TLS termination + cert polling, the `:80` ACME HTTP-01 responder + HTTPS redirect, the poll loop driving the proxy. |
| `src/front/proxy.zig` | The streaming reverse-proxy core: `Proxy` (per-request `Flow` state machine, pooled h2c client conn per backend node, bidirectional body pumps with window-repayment backpressure, 421 re-aim with a replay buffer), `RouteCache` + the `/_cp/route` lookup (libcurl, control-plane only). |
| `src/h2/root.zig` | rove-h2 server (nghttp2): per-stream request entities; `Conn` dual-stack (h2 + `Http1Conn`); the WebSocket collections `ws_message_out` / `ws_send_in`. |
| `src/h2/http1.zig` | Pure HTTP/1.1 codec: `parseHead` → `:method/:path/:authority/:scheme`, resumable `decodeChunked`, `Expect: 100-continue`, keep-alive, chunked response serialize. |
| `src/h2/ws.zig` | Pure RFC 6455 codec: `acceptKey`, `Opcode`, `parseFrame` (unmask in place, FIN/fragmentation surfaced), server-frame serialize. |
| `src/h2/tls.zig` | TLS termination (OpenSSL): `alpnSelectCb` advertises `h2` + `http/1.1`; SNI `host_store` + per-host `SSL_CTX`; `reloadCustomCerts` mtime poll; optional mTLS. |
| `src/blob/coordinator.zig` | Blob coordinator: per-worker submission queue + monotonic seq, durable HWM (`durableSeq`), K=32 executor PUT pool, `bodyRef`/`readBody`. |
| `src/js/chunk_spool.zig` | Per-fetch FIFO chunk spool: K-deep RAM window (default 4), evicts to the coordinator, reads back on dispatch. |
| `src/blob/s3.zig` | S3 client incl. the multipart substrate (`createMultipartUpload`/`uploadPart`/`complete`/`abort`/`copyObject`). |
| `src/js/blob_receive.zig` | `blob.receive` per-upload driver: socket→multipart pipe, zero handler activations. |
| `src/js/blob_sessions.zig` | `blob.write`/`seal` upload sessions: capped worker-RAM buffer, one PUT at seal. |

## Front door & routing

- **Stateless**: holds no raft state. Per request it resolves `:authority` →
  cluster via `Proxy.resolveRoute(host)`, backed by `RouteCache` (host → node
  URLs, TTL-bound) with a CP query (`GET /_cp/route?host=`) on miss.
- **Streaming proxy** (`src/front/proxy.zig`, 2026-06-11 — replaced the
  blocking-curl first cut that buffered whole bodies): the data path is a
  same-poll-loop rove-h2 CLIENT leg — one pooled h2c connection per backend
  node, every proxied request a multiplexed stream. Request bodies stream
  upstream as they arrive (`headers_first` + `BodySink` on the front's server
  side → the client streaming leg), so headers-first propagates END TO END —
  the worker makes its `onChunk`/`blob.receive` disposition while the body is
  still arriving at the edge. Response bodies stream downstream
  (`client_headers_first` + `BodySink` on the client side → the server's
  `stream_response`/`stream_data` pipeline, h2 AND h1 downstream) — held SSE
  streams relay frames mid-stream. Backpressure is end-to-end: each side's
  flow-control window is repaid only as the opposite side drains. h1 ingress
  streams too (2026-06-11 — see the HTTP/1.1 section). A bodyless proxied
  request carries END_STREAM on its upstream HEADERS (`ReqBody.complete` on
  the pump submit) so the worker's headers-first disposition never sees a
  phantom inbound body. Deferred: WebSocket tunneling (an Upgrade proxies as
  a plain GET; needs an h1-upgrade client leg). Proven by
  `scripts/front_streaming_smoke_v2.py` + `scripts/h1_streaming_smoke_v2.py`.
- **Leader-aware proxy**: tries the cluster's nodes in order and stops at the
  first non-421. A follower 421s a write (`Bridge.propose` rejects
  synchronously on a formed group it doesn't lead — nothing enters the log, so
  re-executing elsewhere is safe), and a write self-routes to the leader; a
  read is served by any synced node. Streaming changes the mechanics, not the
  contract: a 421 (or transport error before any response) re-aims at the next
  node by REPLAYING the request body from a replay buffer — kept whole for
  body-complete (classic/h1) requests at any size, and up to 256 KiB for
  streamed bodies. A streamed body past the cap maps a 421 to a plain
  retryable 503 (nothing executed — the follower refused at the door). A
  **503 is never retried by the platform**: the worker's post-propose failures
  (commit-wait fault/timeout, leadership-loss sweep) are ambiguous — the entry
  may still commit under a new leader — and a blind retry double-executes the
  handler. Ambiguous 503s relay to the client, whose retry policy owns that
  decision; all-nodes-421 (mid-election) maps to a plain retryable 503. Same
  discipline in the DP's serve-or-forward (`proxy_engine.zig`). See
  [decisions.md §10.5](../decisions.md).
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
is resumable; responses serialize with `Content-Length` or
`Transfer-Encoding: chunked`, with one-write-in-flight backpressure on the
streaming path. h1→h2c translation is **edge-only**.

- **Inbound body streaming** (2026-06-11): on `headers_first` instances
  (worker, front) an h1 body that hasn't fully arrived at head-parse
  early-emits the request into `request_receiving` and streams through the
  SAME `Stream`/`BodyMode` machinery as h2 DATA — `requestBodyBuffer`,
  `requestBodySink`, discard — so `onChunk`, `blob.receive`, and the front's
  flow relay work over h1 with zero consumer changes. A body already complete
  in the buffer keeps the classic body-complete emit (the h1 mirror of h2's
  END_STREAM-at-HEADERS path). Backpressure is the socket read: the conn's
  read entity parks in `_read_h1_paused` once held (`.hold`) or
  pushed-but-undrained (`.sink`) bytes cross 1 MiB (matching the h2 stream
  windows) and re-arms as the sink drains — TCP receive-window pushback is
  h1's flow-control window. The 16 MiB edge backstop guards BUFFERING only; a
  sunk body is unbounded at the edge and paced end to end.
  `Expect: 100-continue` is decision-gated — sent when the consumer commits
  to the body (buffer / sink attach); an early reply to a client never told
  to proceed closes the connection out (it will never send the body). A
  response mid-body flips hold/buffer to discard and drains the remaining
  wire bytes so keep-alive framing survives. Non-`headers_first` instances
  (examples, log-server) keep the classic body-complete contract. Proven by
  `scripts/h1_streaming_smoke_v2.py` (worker-direct + through the front).

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
- **Status**: shipped end to end. The transport (handshake + framing +
  inbound/outbound collections) is proven by `zig build ws-echo` +
  `scripts/ws_echo_smoke.py`; the worker-side `onMessage` dispatch seam
  (piece D, 2026-06-09) by `scripts/ws_worker_smoke_v2.py` (deployed handler,
  durable frames, both disconnect paths) — see `effects-and-handlers.md`.

## Streaming substrate

- **The one rule** (decisions.md §3.5): a chunk reaches the wire only after the
  activation that produced it commits. An ordinary request is one activation →
  one commit → one flush (so a 5xx is clean and effects are durable before the
  response). A streaming chain flushes per-chunk, each post-commit.
- **Inbound coalescing**: the runtime introspects the handler — a `default`
  export coalesces the whole body (≤ 1 MB) into one activation (the fast path);
  an `onChunk` export takes it per-chunk. Outbound `http.fetch` coalescing is the
  auto-bind behavior described in `effects-and-handlers.md`.

## Outbound policy gate (SSRF / TLS-always)

- Every **customer-supplied** outbound URL (`http.fetch` and everything shimmed
  over it — `webhook.send`, `email.send`, scheduler fires) passes
  `rove-ssrf.checkUrl` in the fetch engine's `startTransfer`, **per attempt**:
  scheme must be `https` (TLS-always), the host must resolve, and **every**
  resolved address must clear the blocklist (RFC 1918, loopback, link-local /
  cloud metadata, CGNAT, multicast/reserved — `src/ssrf/root.zig` has the full
  table). A blocked URL surfaces as the standard failed outcome
  (`ok=false, status=0`) plus an operator-readable `outbound blocked` log line.
- **Rebinding defense**: the full vetted address set is pinned on the transfer
  via `CURLOPT_RESOLVE` (whole set, not first-only, so curl keeps its
  multi-address connect fallback), so the connect can only land on an address
  the gate approved. **Redirects are OFF for customer transfers** (decisions.md
  §3.8) — the handler sees the 3xx and composes its own follow, which re-enters
  the gate as a fresh fetch. Transfers are also protocol-restricted to
  `http,https` at the curl layer (`file:`/`gopher:`/… can't slip through even
  if the gate regresses).
- **Exempt**: the `rove-blob.internal` trusted door — its URL is rewritten to
  the platform-configured S3 endpoint (legitimately private in some
  deployments), never customer-controlled; it keeps redirect-following for S3
  307s.
- **Test hatch**: `REWIND_UNSAFE_OUTBOUND=1` on `rewind` relaxes ONLY the
  loopback block + TLS-always (smoke topologies echo over on-box plaintext
  h2c; the harness sets it on spawned workers). The metadata range stays
  blocked unconditionally. Never set in production. Gate smoke:
  `scripts/ssrf_smoke_v2.py`.

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

## Customer blob storage (`blob.*`) — ingress & signing

The customer surface (`blob.put/get/url/write/seal/receive`, contract in
[`handler-shape.md`](../handler-shape.md)) is **CAS-only**: every object lives at
`{key_prefix_base}{instance_id}/app-blobs/{hash}`; the store has no names — the
naming layer is the customer's kv (decisions.md §3.8). Engine pieces:

- **The signing door**: the shims fetch `http://rove-blob.internal/{hash}`; the
  fetch engine's special-origin interceptor (`rewriteAndSignBlobFetch`,
  `src/js/fetch_engine.zig`) rewrites + SigV4-signs in-process — tenant prefix
  from `pf.tenant_id`, keys never reachable from JS, no extra hop or listener.
  `blob.url` presigns the same way (timestamp from the **taped clock**, so
  replay reproduces the URL bit-for-bit). `_blob/` markers are ordinary
  customer kv, deliberately not platform-reserved (the `_send/` rule).
- **Upload sessions** (`blob.write`/`seal`): a capped Zig-side buffer (64 MiB,
  2/tenant, 120 s idle-TTL sweep) on the worker-owned `blob_sessions`
  collection, keyed `(tenant, correlation_id)`, **connection-scoped** — one
  implicit session per connection, abandoned on disconnect (pure RAM reclaim;
  nothing reaches storage before `seal`). `seal` hashes incrementally, returns
  the hash synchronously, PUTs once through the door, and resumes `{to}` with
  `request.ctx.hash`; the customer's `{to}` export writing its kv index *is*
  the durability commit point.
- **S3 multipart substrate** (`src/blob/s3.zig`): multipart verbs on a
  generalized `requestExt` (wire-encoded query signed verbatim so uploadId
  encoding can't drift; ETags captured from response headers;
  `<Error>`-in-200-body detected). The temp→CAS move is `complete` at
  `app-blobs/.uploads/{id}` then server-side `copyObject` to
  `app-blobs/{hash}` + delete — zero bytes transit the worker.
- **Headers-first h2** (`h2_opts.headers_first`, rewind worker only — front
  door/examples keep the classic contract): sessions run
  `NGHTTP2_OPT_NO_AUTO_WINDOW_UPDATE`; every body-carrying request is emitted
  into the `request_receiving` collection at the HEADERS frame with the
  stream's window held shut. State is collection membership:
  `request_receiving` (undecided) → `request_buffering` (classic decision) →
  `request_out` (body attached). The worker's disposition point
  (`drainRequestReceiving`) consults a worker-local per-(deployment, module)
  `onHeaders` export cache: exported → an `.inbound_headers` activation with an
  **empty body** (early 4xx and the plan-tier 413 fire before any body byte is
  accepted; the body is untaped by construction); not exported (the cached
  common case) → attach-in-place + same-tick classic dispatch, zero hot-path
  cost. A 1 KiB and a 12 MiB upload to the same module take the same path.
- **`blob.receive({to})`**: a connection-scoped PendingFetch through the
  `rove-receive.internal` door (`blob.seal`'s exact pattern — bind-or-drop at
  handler success, commit-gating via `Cmd.http_fetch`, held-chain resume all
  reused). At its commit points the worker arms a per-upload **driver thread**
  (`src/js/blob_receive.zig`): h2 `.sink` mode routes DATA into its queue; it
  accumulates ≥ 5 MiB parts, hashes incrementally, completes + copies + deletes
  on END_STREAM, aborts on disconnect, and emits ONE terminal event
  (`request.ctx = {hash, len}`). Flow control is end-to-end: `sweepBodySinks`
  repays window only as the driver drains, so the client's send rate follows
  the S3 upload rate (≤ one window + one 5 MiB part buffer per job; node cap
  64 jobs). Receive-holding chains park with a 15 min deadline.
- h1 ingress streams the same way (2026-06-11): an incomplete-at-parse h1
  body rides the identical disposition machinery — see the HTTP/1.1 ingress
  section.

Smokes: `scripts/blob_smoke_v2.py` (put/get/url + sessions + `segments.js`),
`scripts/blob_receive_smoke_v2.py` (12 MiB streamed byte-exact, zero chunk
activations), `scripts/inbound_body_smoke_v2.py` (headers-first classic
fallback).

## Held connections (connection-actor)

SSE, WebSocket, and held-sync third-party calls are one primitive: a held entity
on the worker (`parked_continuations`), driven by per-connection wakes (open /
inbound / timeout / signal / close), with **no handle exposed to JS** — the chain
*is* the connection by construction. The held-sync call (a cosmetically-synchronous
third-party request → callback → response, with a mandatory timeout) is shipped;
the design and the wake model live in [`effects-and-handlers.md`](effects-and-handlers.md)
and the customer contract in [`handler-shape.md`](../handler-shape.md).

## Known limitations (as-built)

- **Front→DP is per-request connect** today (no keep-alive pool to the data
  plane) — a known follow-up, not a correctness issue.
- **Held connections are single-node** per cluster in the baseline; the
  cross-worker locator that held primitives share is described in
  `effects-and-handlers.md`.
- **The h2-layer size cap is narrowed but not closed**: the per-tenant 413
  fires from the declared content-length before buffering, but a length-less
  h2 stream still buffers up to the cap before the recheck (follow-up: an
  h2-level running-length cap).
