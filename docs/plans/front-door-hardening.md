# Front-door hardening — reverse-proxy best-practice gaps

> 🟡 **In-flight plan** (2026-07-04). Audit of `src/front/` against
> established reverse-proxy practice (nginx / HAProxy / Envoy), motivated
> by ongoing front-door reliability issues. Each finding names the gap,
> the mechanism, and the conventional cure. Phasing at the bottom.
> As-built reference: [`../architecture/routing-and-ingress.md`](../architecture/routing-and-ingress.md).

## Scope

The V2 front door (`src/front/main.zig`, `src/front/proxy.zig`,
`src/front/route_resolver.zig`) plus the rove-h2 / rove-io behavior it
depends on. Deliberate architecture differences from nginx (streaming-first,
no response buffering, h2c multiplexed upstream) are NOT findings; only
places where the difference loses a protection nginx's choice provided.

## A. Reliability-incident candidates

### A1. No upstream connect timeout ⭐

The io_uring connect (`src/io/root.zig` `prep_connect`) has no linked
timeout, and a flow parked on a pending connect (`Upstream.waiters`) is
covered by no proxy deadline — `ROUTE_WAIT_NS` covers only route parking,
`RESPONSE_WAIT_NS` arms only after the stream is registered. A backend
that blackholes SYNs (node down hard, partition, firewall drop) hangs
every flow aimed at it for the kernel SYN-retry default (~2 min). The
500 ms `CONNECT_BACKOFF_NS` never engages — it is failure-triggered.

nginx: `proxy_connect_timeout`, conventionally 1–5 s with immediate
failover. Cure: a connect deadline (proxy-level sweep of `.connecting`
pool entries, or an io-level linked timeout), then fail waiters over to
the next node.

### A2. Transport-error retry can double-execute writes ⭐

`attemptFailed` retries when `canRetry()` = `replayable and
!resp_started`. A POST whose body was **fully sent** upstream, where the
connection then died before response headers, is replayed on the same
node (reconnect budget) and then the next. If the worker executed and
committed before the connection died, the handler runs twice. This is
exactly the ambiguity decisions.md §10.5 refuses to retry for
post-propose 503s — 421 proves non-execution; transport error after
full-body-sent proves nothing.

nginx: `proxy_next_upstream` excludes `non_idempotent` by default.
Cure: on transport error, retry only if the method is idempotent
(GET/HEAD/OPTIONS/PUT/DELETE per RFC 9110 — we gate on GET/HEAD/OPTIONS,
since rewind handlers make PUT/DELETE semantics customer-defined) OR no
request byte was ever handed to the upstream attempt. The 421 re-aim
path is untouched.

### A3. Single pooled h2c connection per backend node

One connection multiplexes every flow to a node. (a) One TCP congestion
window head-of-line-blocks all tenants' traffic to that node; (b) the
connection dying fails everything in flight to that node at once — a
correlated error spike; (c) past the peer's `max_concurrent_streams`
(512), nghttp2 queues submissions invisibly with no depth bound and no
load shedding. Envoy bounds this with `max_pending_requests`; nginx
sizes `keepalive` pools. Cure (later phase): a small per-node conn pool
(2–4) + a bounded pending-submit queue that sheds with 503 when full.

### A4. Connections stuck in TLS handshake are never reaped ⭐

`reapIdleConnections` (rove-h2) walks only `_conn_active`; the
`_conn_tls_handshake` collection has no deadline sweep. With
`max_connections = 1024`, a peer that opens TCP and stalls
mid-handshake pins a slot forever — classic slowloris, and consistent
with the connection-setup-collapse symptoms the front-diag log was
built to observe. Cure: handshake deadline (~10 s) swept in rove-h2.

### A5. No mid-stream progress timeouts

`expireStalledResponses` covers exactly one window: body complete,
response headers not yet arrived. Not covered: a client stalling
mid-request-body (skipped via `!body_complete`) while holding worker
resources — per-STREAM, so the conn-level idle reap never fires while
any sibling stream (or a PING) keeps the connection active. nginx:
`client_body_timeout`. Cure: a between-bytes request-body budget
(`REWIND_FRONT_BODY_STALL_TIMEOUT_MS`, default 60 s).

**Deliberate divergence (resolved during implementation):** the
mid-RESPONSE-body window (`proxy_read_timeout` between reads) is NOT
policed at the front. A quiet held SSE stream — a first-class product
primitive (connection-actor) — is indistinguishable from a stalled
worker at the proxy, and held-connection deadlines belong to the
worker (parked chains carry their own budgets). A worker that dies
mid-response already aborts the flow via the conn/stream teardown.

### A6. Cold-route resolution is a serial, unprotected bottleneck

The resolver is one thread, one blocking curl at a time, 2 s timeout,
popping LIFO (`pop()` takes the newest — under backlog the oldest
parked flows starve into their 2.5 s 503 deadline). And `not_found` is
never cached: internet scanners probing garbage Host values each
trigger a fresh CP query, serially queued with real tenants' cold
resolves. When the CP is slow, garbage at up to 2 s each starves
legitimate resolution. nginx resolver caches negatives (`valid=`);
Envoy's DNS cache likewise. Cure: FIFO pop + negative cache entries
with a short TTL (~5 s). Parallelizing the resolver is a follow-up.

## B. Protocol hygiene

### B7. No forwarding headers; inbound ones unsanitized

`packUpstreamHeaders` adds nothing and forwards client headers
verbatim: workers never learn the client IP (no per-client limits,
abuse attribution, honest logs possible downstream); a client can spoof
`x-forwarded-for` / `x-forwarded-proto` and the worker can't tell; and
`:scheme` is hardcoded `http`, so TLS-ness is lost. Cure: strip inbound
`x-forwarded-*` / `forwarded` at the trust boundary; set
`x-forwarded-for` from the peer address and `x-forwarded-proto` from
whether the front terminated TLS.

### B8. Connection-nominated hop-by-hop headers not stripped

`dropFromRequest` drops the fixed hop-by-hop set, but RFC 7230 §6.1
also requires removing any header *named in* the `Connection` header
value (h1 ingress). Forwarding them is the mechanism behind published
request-smuggling / cache-poisoning classes. (A `Via` header, which
§5.7.1 says proxies must append, rides along with this fix.)

### B9. Host handling un-normalized

Route cache, leader cache, and CP queries key on the raw
client-supplied host: `HOST.example` vs `host.example` are distinct
entries and distinct CP round-trips (DNS names are case-insensitive).
`hostOnly` mis-splits a bracketed IPv6 authority without a port. The
host also lands unescaped in `/_cp/route?host=`. Cure: lowercase at
intake; fix the bracket edge; percent-escape the query value.

## C. Operational gaps

### C10. No graceful drain on SIGTERM

`stop_flag` flips and the loop exits; in-flight flows are abandoned.
Every rolling deploy of the front is client-visible errors. Cure:
stop accepting, GOAWAY existing conns, finish in-flight flows under a
deadline (~10 s), then exit.

### C11. Near-zero per-request observability ⭐

No access log; no status-code counters, latency histograms, re-aim /
connect-failure / resolver-depth counters, no request ID. What exists:
connection-level gauges, two flow gauges, a stress log. This gap makes
every other gap expensive — incidents can't be decomposed into connect
failures vs 421 storms vs stalls vs resolver starvation. Cure: one
access-log line per completed flow + counters/histograms in the front
metrics text.

### C12. No health checking in either direction

Upstream health is purely passive (connect failure → 500 ms backoff);
no active probes or outlier ejection — the first request after any
failure window is a guinea pig. Downstream, there is no `/healthz` for
an L4 ingress to gate on (only loopback `/metrics`).

### C13. No per-client limits

One client/IP can hold all 1024 connections × 512 streams. nginx ships
`limit_conn` / `limit_req`. Global cap only today; fairness under abuse
is zero. Depends on B7 for identity when behind another hop.

## Phasing

Phase 1 (this branch — the ⭐ items plus the small correctness fixes):

1. C11 access log + metrics (turns complaints into data; cheapest).
2. A1 connect timeout, A4 handshake reap, A5 mid-stream timeouts —
   the timeout matrix.
3. A2 idempotency-gated retry (correctness bug by our own standard).
4. A6 negative cache + FIFO resolver.
5. C10 graceful drain.
6. B7 + B8 forwarding-header hygiene (B7 is also the prerequisite for
   C13).

Phase 2 (follow-ups, separate branches):

- A3 upstream conn pool + bounded pending queue.
- A6b parallel resolver (curl multi or small pool).
- B9 host normalization.
- C12 `/healthz` + active upstream probes.
- C13 per-client connection/request limits.

## Verification

- Unit: inline Zig tests beside each change (retry gate, negative
  cache, header filtering).
- Smokes: `three_node_smoke.py` (leader-kill failover must stay green —
  the retry-gate change must not regress 421 re-aim),
  `front_streaming_smoke_v2.py`, `h1_streaming_smoke_v2.py`,
  `ws_worker_smoke_v2.py`, `ctl_smoke_v2.py`.
- New targeted smokes where a gap is deterministically reproducible
  (blackholed-connect timeout; drain-under-load).
