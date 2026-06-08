# V2 — HTTP/1.1 edge ingress (design)

> **Status: design (2026-06-07). Not built.** Adds HTTP/1.1 *ingress* to
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

1. **`src/h2/http1.zig` — the codec (no I/O).** A request parser (request line
   → `:method`/`:path`; headers → fields + synthesized `:authority` from `Host`,
   `:scheme`; body via `Content-Length`) and a response serializer (status line
   + headers + content-length + body; `Connection` keep-alive/close). Pure +
   table-unit-tested. **This is the self-contained first step.**
2. **Plaintext h1 ingress.** `Conn.h1`; in `readsFeedData`, a plaintext-sniffed
   h1 first-read opens an `Http1Conn` (instead of the `426`) and drives the
   parser; an h1 response path serializes + writes. Keep-alive across requests.
   Smoke: `curl --http1.1` (no `--http2-prior-knowledge`) against an h2c
   listener gets a real response.
3. **h1 over TLS (ALPN).** Advertise `http/1.1`; route ALPN-h1 connections to
   the codec (decrypt → parse; serialize → encrypt). Smoke: `curl --http1.1`
   over TLS; `openssl s_client -alpn http/1.1`.
4. **Chunked transfer-encoding** (request + response) + `Expect: 100-continue`.
   Most webhooks send `Content-Length`, so this is a fast-follow, not a blocker.
5. **Front-door `:80` plaintext listener** (ACME HTTP-01 + HTTP→HTTPS redirect),
   retiring the gap #3 slice-3 wrinkle — the h1 front answers `:80` directly.
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
