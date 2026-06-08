# V2 — HTTP/1.1 edge ingress (design)

> **Status: phases 1–5 shipped (2026-06-07).** Codec + plaintext h1 ingress +
> h1-over-TLS via ALPN + chunked-request decode & `100-continue` are live in
> `rove-h2`, and the `rewind-front` `:80` listener (ACME HTTP-01 + HTTP→HTTPS
> redirect) is wired — all proven end-to-end (see Build order). Phase 6
> (WebSocket) remains; chunked *response* is deferred to the streaming-over-h1
> integration, and the ACME `200` challenge path lands with gap #3 slice 3 (the
> CP issuer + `/_cp/acme-challenge` endpoint). Adds HTTP/1.1 *ingress* to
> `rove-h2` (today nghttp2/HTTP-2-only) so the edge can accept inbound traffic
> from h1-only clients without Cloudflare in front. Amends an assumption in
> [`v2-front-door-architecture.md`](v2-front-door-architecture.md) (which
> assumed client→edge is always h2-over-TLS). Companions: `src/h2/root.zig`
> (the server), `src/h2/tls.zig` (ALPN), `src/acme/responder.zig` (an existing
> standalone h1 `:80` server), [`project_fediverse_libs`] memory (WS-origin
> already flagged as forcing an h1 stack).

## Why (three forcing functions converge)

With Cloudflare gone (the no-vendor edge decision), our front door faces the
raw internet and must speak HTTP/1.1 for inbound traffic, because:

1. **Inbound webhooks.** Most webhook senders (the services calling *our*
   tenants' callback URLs) POST over HTTP/1.1; outbound h2 is uncommon. Over
   TLS they ALPN-negotiate, and an h1-only sender against an **h2-only ALPN
   edge fails the handshake**. CF used to absorb this (accept h1, speak h2 to
   origin); without it, we must.
2. **ACME HTTP-01.** The `:80` challenge is HTTP/1.1 plaintext (the gap #3
   slice-3 wiring wrinkle — an h1 front answers it natively).
3. **WebSocket upgrade origin.** A WS connection opens as an HTTP/1.1
   `Upgrade`. Already identified in the fediverse work as *"the only thing that
   forces an h1 stack."*

Building h1 ingress into `rove-h2` once removes the need to design around its
absence at every one of these.

**Out of scope / already handled:**
- **Outbound is fine.** `http.send` / webhook *sending* goes through libcurl
  (`fetch_engine`), which already speaks h1/h2. This gap is purely **inbound**.
- **Browsers** all do h2 — they're unaffected; this is for non-browser clients.
- **WebSocket framing** (101 + frame relay) is a *follow-on* that h1 ingress
  unlocks (Phase 5), not part of basic request/response h1.

## The scoping insight: front-door-only, h1→h2c at the edge

**Only the front door needs HTTP/1.1.** It terminates public TLS and proxies to
the DP over **private h2c** (via libcurl today). So it accepts h1 at the edge,
produces the same internal request representation, and the existing proxy path
carries it inward unchanged. The **DP/worker stays h2-only** — it only ever
talks to the front. All new protocol code lives in **one place: the `rove-h2`
server listener**, which both the front door and (incidentally) the worker use.

```
h1-only client ──TLS(ALPN: http/1.1)──▶ front door (rove-h2 listener)
                                            │  h1 parse → request entity
                                            │  (existing routing + proxy)
                                            ▼  libcurl h2c (unchanged)
                                          DP worker (still h2-only)
```

The internal seam that makes this cheap: `rove-h2` already turns every inbound
request into a **stream entity** carrying `ReqHeaders` (with h2-style
pseudo-headers `:method` / `:path` / `:authority` / `:scheme`), `ReqBody`,
`StreamId`, `Session`; responses come back as `Status` + `RespHeaders` +
`RespBody`. **If the h1 codec synthesizes the same pseudo-headers on parse and
serializes h1 bytes from the same response components, all routing/dispatch/
proxy code is protocol-agnostic and untouched.** That is the whole trick.

## Where it forks in `rove-h2`

Today (`root.zig`):
- **Read** (`readsFeedData`): decrypted/plaintext bytes go to
  `nghttp2_session_mem_recv`. A plaintext first-read that `looksLikeHttp1Request`
  is rejected with `426 Upgrade Required`.
- **Request creation**: nghttp2 callbacks build a `request_out` entity.
- **Response** (`processResponses`): `nghttp2_submit_response` + a data provider,
  then `nghttp2_session_mem_send` → write.
- **ALPN** (`tls.zig alpnSelectCb`): selects only `h2`.

The fork adds a per-connection **protocol mode**. `Conn` gains an
`h1: ?*Http1Conn` (mutually exclusive with `ng_session`). Then:
- **ALPN**: advertise `h2` **and** `http/1.1` (prefer h2); an ALPN-h1 or
  plaintext-sniffed-h1 connection gets an `Http1Conn` instead of an
  `ng_session`.
- **Read**: an h1 connection feeds bytes to the h1 parser (after TLS decrypt,
  same `tls_conn.feed` as h2); a completed request creates the same
  `request_out` entity (synthetic `StreamId = 1`; one in-flight request per
  connection — no pipelining).
- **Response**: an h1 connection's `response_in` entity serializes
  `HTTP/1.1 {status}\r\n{headers}\r\nContent-Length: N\r\n\r\n{body}` and
  `submitWrite`s it (bypassing nghttp2), honoring `Connection: keep-alive`
  vs `close`.

## Non-goals (keep it small + safe)

- **No request pipelining.** One in-flight h1 request per connection; the next
  is read after the response is written. (Pipelining is near-dead and a
  footgun.)
- **No h1 *egress*.** The front→DP and `http.send` hops stay as they are
  (h2c / libcurl).
- **No `Upgrade: h2c`.** We don't do cleartext-h2 upgrade negotiation; plaintext
  is either the h2 preface (prior-knowledge) or h1.
- **Trust boundary unchanged.** h1 requests get the same scope/auth treatment as
  h2; nothing downstream may trust a property only the h1 path could inject.

## Build order

1. ✅ **`src/h2/http1.zig` — the codec (no I/O).** A request parser (request line
   → `:method`/`:path`; headers → fields + synthesized `:authority` from `Host`,
   `:scheme`; body via `Content-Length`) and a response serializer (status line
   + headers + content-length + body; `Connection` keep-alive/close). Pure +
   table-unit-tested (`zig build h1-test`). **The self-contained first step.**
   *(commit `6bff631`.)*
2. ✅ **Plaintext h1 ingress.** `Conn.h1: ?*Http1Conn` (mutually exclusive with
   `ng_session`); in `readsFeedData`, a plaintext-sniffed h1 first-read swaps the
   eagerly-created (unused) nghttp2 session for an `Http1Conn` (`http1SwapIn`,
   replacing the old `426`) and drives the parser (`http1Feed`/`http1Drive`); a
   complete head+body emits the same `request_out` entity with synthesized
   pseudo-headers (`http1BuildReqHeaders`, `StreamId = 1`). `consumeResponses`
   forks on `conn_ptr.h1` to serialize + `submitWrite` (`http1WriteResponse`),
   honoring keep-alive (compact buffer, re-drive for a coalesced next request)
   vs `Connection: close`. Malformed/`411` chunked/missing-`Host`/`413`
   over-cap (`Http1Conn.MAX_BODY_BYTES = 16 MiB`) all return a real status +
   close (`http1ErrorClose`). Streaming responses over h1 (the
   `stream_response_in` path) safely degrade to an io-error until Phase 4.
   Proven against the h2c echo example (`zig build h2-echo-server`): `curl
   --http1.1` POST/GET echo, keep-alive connection reuse (two distinct requests,
   one socket), 21 KB multi-read body round-trip, `Connection: close`, HTTP/1.0
   close-default, and the `400/411` error paths — all green, with
   `--http2-prior-knowledge` h2 unaffected.
3. ✅ **h1 over TLS (ALPN).** `tls.zig` `alpnSelectCb` now advertises `h2` +
   `http/1.1` in **server-preference order** (h2 wins when both offered); a new
   `TlsConn.alpnProtocol()` (`SSL_get0_alpn_selected`) reads the negotiated
   protocol. `readsTlsHandshake`'s `handshake_done` takes the h2 path **only
   when ALPN explicitly negotiated `h2`** — `http/1.1` *or no ALPN at all*
   creates an `Http1Conn` (no nghttp2 session) and feeds the first decrypted
   app-data flight. (h2-over-TLS *requires* ALPN `h2` per RFC 7540 §3.4, so an
   h2 client always advertises it; a no-ALPN TLS client — HTTPS predates ALPN,
   and minimal/older h1 clients omit it — can therefore only be HTTP/1.1, so h1
   is the correct default, not a fallback.) The h1 read branch decrypts
   via `tc.feed` before `http1Feed`; a shared `http1Send` encrypts via
   `tc.encrypt` before `submitWrite` so the plaintext and TLS egress paths share
   one framing. `:scheme` is `https` for TLS conns. Two lifecycle fixes the TLS
   path forced (also correct for plaintext h1): `transitionHandshakeConnections`
   and the `driveAllSends` idle-GC now treat `h1 != null` like `ng_session !=
   null`, so an ALPN-h1 conn reaches `_conn_active` and idle keep-alive/closing
   h1 conns are reaped (closes the design's "idle reuse vs GC" open question).
   Proven against `zig build h2-tls-test` (added a named run step): `curl
   --http1.1` over TLS echoes h1, default curl negotiates h2, `openssl s_client
   -alpn http/1.1|h2|h2,http/1.1` selects http/1.1|h2|h2 (preference) and an
   ALPN-less `s_client` routes to h1, h1-over-TLS keep-alive reuses one TLS
   conn, a **133 KB multi-record body** round-trips identically, `Connection:
   close` + `411` over TLS, server survives errors; plaintext phase-2
   unaffected.
4. ✅ **Chunked transfer-encoding (request) + `Expect: 100-continue`.** The codec
   gains a resumable `decodeChunked` (`pos` in / `consumed` out, body assembled
   into a caller-kept buffer so consumed chunks are never re-scanned — O(n)
   across partial reads; chunk extensions + trailers tolerated; `max_body` →
   413, bad framing → 400) and an `expect_continue` flag on `Head`. `Http1Conn`
   carries the decode state (`chunk_body`/`chunk_pos`) + `continue_sent`;
   `http1Drive` frames the body via chunked-or-Content-Length, resetting the
   per-request state at emit. `http1MaybeContinue` answers `100 Continue` once,
   at the edge, when an `Expect` request's body hasn't fully arrived — so the DP
   never sees `Expect` (it's added to the hop-by-hop drop list alongside
   `Transfer-Encoding`; the DP gets a fully-decoded body). Codec unit-tested
   (`h1-test`: assemble, partial-read resume, extensions/trailers, 413, 400) +
   proven against the echo examples: `curl -T -` chunked echo, a 266 KB chunked
   body round-tripping across many reads, `Expect: 100-continue` (curl and a
   staged raw socket showing the `100` sent *before* the body), keep-alive
   mixing a chunked then a plain request on one socket, malformed→400, and a
   66 KB chunked body over TLS. **Chunked *response* (output) is deferred** — the
   buffered response path always knows its length so it emits `Content-Length`;
   the only consumer of chunked output is a streaming handler over h1, which is
   coupled to the `stream_response_in` subsystem (today an io-error degrade) and
   belongs with that integration, not the codec.
5. ✅ **Front-door `:80` plaintext listener** (ACME HTTP-01 + HTTP→HTTPS
   redirect), retiring the gap #3 slice-3 wrinkle — the h1 front answers `:80`
   directly. `rewind-front` (`src-v2/front/main.zig`) gains a second `FrontH2`
   server (its own registry, plaintext) polled non-blocking in the same loop:
   `/.well-known/acme-challenge/<token>` fetches the key-authorization from the
   CP issuer (`GET /_cp/acme-challenge?token=` — the CP side is slice 3, so it
   404s until then, the correct "no challenge in flight" answer) and everything
   else gets a `308` to `https://<host><path>` (method + path + query preserved;
   missing `Host` → 400). Enabled via `REWIND_HTTP_PORT` (defaults to `80` when
   the front terminates TLS, disabled in h2c mode where the upstream LB owns
   `:80`). Proven: `curl --http1.1` on the `:80` port returns `308` with the
   right `Location` (GET + POST), the ACME path 404s with no CP endpoint, a
   no-`Host` request 400s, and the main TLS/h2c listener keeps serving under the
   two-server loop. (A redirect/ACME smoke lands with slice 3, which supplies
   the CP endpoint the `200` challenge path needs.)
6. **(Later) WebSocket upgrade** — `101 Switching Protocols` + frame relay, the
   connection-actor / fediverse unlock. Its own design.

Phases 1–3 deliver the core (h1 webhooks over TLS). Phase 4 covers the long
tail of senders. Phase 5 closes the ACME wiring. Phase 6 is a separate feature.

## Relationship to other gaps

- **gap #3 (TLS/ACME):** Phase 5 here subsumes the slice-3 `:80` responder
  placement question — so the interim choice there can be minimal (reuse
  `acme/responder.zig`), knowing the h1 front absorbs it.
- **gap #5 (provisioning) / WS / fediverse:** Phase 6 (WS upgrade) is the
  enabler; not needed for the SaaS edge baseline.

## Open questions

- **Codec home.** New `src/h2/http1.zig` inside `rove-h2` (shares the conn /
  entity / write plumbing) vs a sibling module. Inside `rove-h2` is simpler —
  it needs the `Conn`, the collections, and `submitWrite`.
- **Header limits.** h2 enforces header-list size via nghttp2; the h1 parser
  needs its own bound (max request-line + header bytes) to avoid unbounded
  buffering — coherent with the gap #1 body cap.
- **Keep-alive idle reuse vs the connection idle-timeout GC** already in
  `root.zig` — make sure an idle keep-alive h1 conn is reaped on the same path.
