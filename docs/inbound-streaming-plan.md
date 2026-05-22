# Inbound body streaming — Gap 2.4 sub-plan

**Status:** Plan. No code yet. Elaborates `docs/primitive-gaps.md`
§2.4. Sibling of `docs/upstream-streaming-plan.md` (Gap 2.3) —
same chunked-bytes *shape*, inbound direction.

---

## 1. Motivation

An inbound request body is buffered whole, up to `REQUEST_BODY_CAP`,
before the handler is dispatched at all. The handler sees one
`request.body`. Consequences:

- A multi-gigabyte upload is a 413, not a stream-to-blob.
- Chunked progress reporting, duplex-shaped endpoints — unrepresentable.
- The platform files-server has a multipart endpoint as a built-in
  shortcut; a customer cannot write their own equivalent.

The fix: let a handler consume the request body incrementally, as
the `DATA` frames arrive — symmetric to how Gap 2.3's `http.fetch`
hands a handler upstream response chunks.

---

## 2. The opt-in problem (correcting the catalog)

`primitive-gaps.md` §2.4 suggested opting in "via a response header
on the first activation, or by returning `__rove_stream` from an
`inbound` Msg before the body has fully arrived."

**That is chicken-and-egg and does not work.** To opt in by
*returning* something, the handler must first *run*. To run today,
the body must already be buffered — which is the exact thing we're
trying to avoid. A handler cannot both "decide via its return
value" and "not have the body yet."

So the opt-in **must be static — known before dispatch.** A
streaming-body handler is **declared in the manifest**, the same
way `_subscriptions/*` chain origins are declarations rather than
runtime calls. The runtime reads the declaration and changes *when*
it dispatches.

This also keeps every existing handler untouched: `request.body`
stays fully-buffered-and-present for the default (undeclared) case.
Dispatch-on-headers happens **only** for declared modules.

**Decision D1 — declaration syntax.** A boolean on the manifest's
route/file entry: `streaming_body: true`. (Open: a per-route flag
vs a `spec.json` sidecar like subscriptions use. Routes are not
directories, so a flag on the file entry is the lighter fit — §9.)

---

## 3. The model — a held inbound connection

An inbound request with a streaming body IS a held connection: the
client socket stays open, we are receiving its body, and we still
owe it a response. That is exactly the connection-actor shape —
reuse it, do not invent a parallel one.

Lifecycle of a declared streaming-body handler:

```
client ──HEADERS──▶  inbound activation   (request.body EMPTY; headers present)
                     handler returns __rove_stream  → chain parks, holds the socket
client ──DATA────▶   inbound_chunk activation  { seq, byte_offset, bytes }
client ──DATA────▶   inbound_chunk activation  { seq, byte_offset, bytes }
         …
client ──DATA(END)─▶ inbound_end activation    { total_bytes }
                     handler returns Response   → flushed to the client, chain ends
```

- **First hop (`inbound`)** — dispatched the moment HEADERS land.
  `request.body` is empty; `request.headers` / `request.method` /
  `request.path` are all present. The handler inspects the headers
  (auth, content-type, content-length) and returns `__rove_stream`
  to accept the body, or a terminal `Response` to reject it early
  (e.g. 401 / 415 — the runtime then drains + discards the body).
- **`inbound_chunk`** — one activation per body `DATA` frame,
  re-chunked to a cap (§6). The bytes are a taped input. The
  handler does its work (write to blob, hash, validate) and
  returns `__rove_stream` again to keep receiving, or a terminal
  `Response` to stop early (the runtime drains the rest).
- **`inbound_end`** — fires once when the client sets `END_STREAM`.
  The handler returns its terminal `Response`.

**Cmd surface stays at three.** `__rove_stream` is "hold this
connection, wake me on its events" — Gap 2.2 already made its wake
set a fan-in (`wake_batch`). `inbound_chunk` / `inbound_end` are
two more Msg variants, not new Cmds. This is the same discipline
2.1/2.2/2.3 held: extension goes into Msg, never Cmd.

**Decision D2 — body chunks do NOT ride the §9.4 `wake_batch`
ring.** That ring fans in *small* events (kv key, timer tick). A
body chunk carries bytes (up to the per-chunk cap). `inbound_chunk`
is its own activation kind — structurally like `fetch_chunk`, not
like a wake-ring entry. A streaming-body chain that *also*
registers kv/timer `waitFor`s keeps those on the ring as today;
the two are independent.

---

## 4. Activation Msg shape

Two new `Msg` variants (and `ActivationSource` enum entries):

```
inbound_chunk — { seq, byte_offset, bytes }
inbound_end   — { total_bytes }
```

`inbound_chunk`:
- `seq` — 0-based body-chunk index.
- `byte_offset` — cumulative body bytes before this chunk.
- `bytes` — the chunk payload (Uint8Array; runtime owns the
  buffer, valid for the activation — copy to retain). Surfaces at
  `request.activation.bytes`, mirroring `fetch_chunk`.

`inbound_end`:
- `total_bytes` — full received body length (after any cap drops).

The first-hop `inbound` activation is unchanged in shape except
`request.body` is empty and `request.activation.kind` is still
`"inbound"` — a declared handler knows to branch on
`request.streaming_body === true` (or simply: it knows it is the
streaming handler) and not read `request.body`.

**Decision D3 — should the first hop's `kind` differ?** Option:
a distinct `inbound_headers` kind so the handler can't confuse a
streaming first-hop with a normal buffered request. Recommendation:
**no** — keep `kind: "inbound"`. The handler is statically the
streaming one; a separate kind is redundant ceremony. Revisit only
if a module is ever both (it should not be).

---

## 5. h2 wire-up — where the work lands

This is the load-bearing unknown. rove-h2's inbound request
lifecycle today buffers the body and dispatches once. The phases
below need an h2-code investigation first.

- **Dispatch-on-headers.** Today the worker dispatches a request
  when the body is complete. For a declared module the dispatch
  trigger moves to HEADERS-complete. The h2 request entity must
  carry "streaming-body, first hop dispatched" state so subsequent
  `DATA` frames route to the chain instead of a body buffer.
- **`DATA` frame → activation.** h2 receives body `DATA` on the
  connection thread; the handler runs on a worker thread. The
  bytes cross that boundary the same way Gap 2.3's chunks do — a
  per-worker cross-thread inbox, drained on the worker tick and
  turned into an `inbound_chunk` activation against the held
  chain. (The chain is found by entity identity, not a
  correlation scan — h2 already holds the stream entity.)
- **The held chain** reuses the `__rove_stream` park: the entity
  sits in the stream pipeline, `inbound_chunk` is a wake source
  that re-activates it, `inbound_end` is the terminal wake.

---

## 6. Backpressure

This is the inbound mirror of Gap 2.2's write-pressure surface, and
unlike the outbound case h2 gives us a *real* flow-control lever:
HTTP/2 `WINDOW_UPDATE`.

- The runtime withholds `WINDOW_UPDATE` while the handler is behind
  on its chunk queue — the client's transport slows itself. This
  is true backpressure, not drop-and-count.
- A per-chain inbound chunk queue cap bounds memory if the client
  ignores flow control (a non-conformant client). On overflow:
  RST_STREAM the request (a misbehaving client, fail-fast — §5
  strike posture), not a silent drop.
- `REQUEST_BODY_CAP` becomes, for streaming-mode handlers, a
  *total* cap (max whole-body bytes) rather than a buffer size;
  exceeding it RST_STREAMs.

**Decision D4 — drop vs RST on overflow.** Gap 2.2's outbound
`StreamChunks` drops newest + counts (the producer is the trusted
customer handler). Here the producer is an *untrusted client*;
overflow despite withheld `WINDOW_UPDATE` means a misbehaving
client → RST_STREAM. Do not drop-and-continue.

---

## 7. Replay determinism

Each `inbound_chunk`'s bytes are a taped input, exactly like an
`inbound` request body is today and like a `fetch_chunk`'s bytes
are (Gap 2.3) — small inline, large content-addressed
(`connection-actor-plan.md` §8). `inbound_end.total_bytes` is
taped. Re-execution feeds the same chunk sequence in the same
order. The §6 bounded-tape-per-chain cap applies (this IS a
handler-observed input, unlike `pipe_to` — cf.
`project_pipe_to_untaped`).

---

## 8. Phasing

| Phase | Content |
|---|---|
| A | Manifest `streaming_body` declaration + plumb to the dispatch decision. Inert — nothing dispatches differently yet. |
| B | h2 dispatch-on-headers for declared modules: the `inbound` activation fires with an empty body; the entity parks on `__rove_stream`. |
| C | `DATA` frame → cross-thread inbox → `inbound_chunk` activation. Re-chunk to the per-chunk cap. |
| D | `inbound_end` terminal activation + the response flush. |
| E | Backpressure: `WINDOW_UPDATE` gating + the per-chain queue cap + RST-on-overflow. |
| F | Replay tape: `inbound_chunk` / `inbound_end` as taped inputs. |
| G | Smoke (customer streaming-upload handler → blob) + docs; retire the files-server multipart shortcut's special-casing if it now composes from this. |

A+B are the risky h2 surgery; C–F reuse established shapes (Gap
2.3's cross-thread chunk inbox, Gap 2.2's backpressure surface).

---

## 9. Open decisions

- **D1 manifest syntax** — `streaming_body: true` flag on the file
  entry (recommended) vs a `spec.json` sidecar.
- **D5 — duplex.** A handler that streams the body IN *and* a
  response OUT (true duplex) is expressible — the held chain can
  emit response chunks (`__rove_stream` write) while receiving
  `inbound_chunk`s. v1 may restrict to "receive fully, then
  respond" and lift the restriction later; decide before Phase D.
- **D6 — early reject drains.** When the first hop returns a
  terminal `Response` (401/415), the client may still be sending
  the body. The runtime must drain-and-discard (or RST_STREAM)
  cleanly. Pick per h2's behavior in Phase B.

## 10. Out of scope / locked

- No exposed body-reader handle in any JS surface — affine
  discipline (`project_connection_actor_unified_trigger`). The
  chain receiving `inbound_chunk` Msgs IS the reader.
- No inline/synchronous body read. Chunks arrive as activations.
