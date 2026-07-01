# Replay & sim — the engine model and the as-built driver

> **Status.** The *model* (§1–§4) is locked — it is a restatement of the
> determinism contract in [`effect-algebra.md`](../effect-algebra.md),
> [`handler-shape.md`](../handler-shape.md), and
> [`effects-and-handlers.md`](effects-and-handlers.md), focused on what
> replay/sim need. The *as-built driver state* (§5–§6) is a snapshot
> (2026-06-30) of `src/replay/` + `src/cli/rewind.zig` and the recording side;
> it drifts as the gaps close. **Read this before touching `rewind replay` /
> `rewind sim` / `export-fixture`** — the recurring mistake is pattern-matching
> rewind onto a generic continuation/serverless model, which is wrong in ways
> that produce bad designs (see §2, the resolved-export nuance, and §5 G3).

## 1. One operation: `run(world, code, on-miss)`

Replay, sim, test, and regression are **one operation** with three knobs, not
separate engines. The foundation is the determinism boundary
(`effect-algebra.md` §1):

> An effect may return data to a handler **only as a recorded Msg.**

arenajs makes the **within-activation** non-determinism replayable (it captures
every non-deterministic read onto a tape); the engine makes the
**between-activation** flow replayable by recording every Msg (L3). Together
those are *why* replay/sim can exist.

- **world** — everything one activation reads (see §2). A **recording** is a
  world that was *captured*; a **fixture** is one that was *authored*. Same
  shape, different provenance.
- **code** — the handler module (the recorded source, or a working-tree
  override — the `--source-dir` "does my change still satisfy this?" lever).
- **on-miss** — what a read the world doesn't supply does: `fail` (refuse to
  invent → the replay corner) or `resolve` (answer not_found + record a typed
  hole → the sim corner). This is the **replay↔sim axis**.

| mode | world | code | on-miss |
|---|---|---|---|
| replay | captured | original | fail |
| sim / what-if | authored and/or captured | any | resolve |
| test | authored | any | fail |
| regression | captured | original vs changed | — (diff two runs) |

**Inputs are recorded; outputs are derived** (`effect-algebra.md` §2.5). The
world carries *inputs* (the Msg, the readset, ctx, seed, bytecode-by-hash). The
*outputs* — writeset, `Cmd`s, the wire response — are a deterministic function
of those inputs and are the run's **result**, never part of its world. Don't
put a response/status into a world expecting it to "play back"; it falls out of
re-running.

### Resolution is by-key; faithfulness lives at the output

Replay's job is to **re-materialise the run so you can inspect it** (outputs,
state at each step, a scrubbable timeline) — not to *prove* accuracy on every
read. Accuracy is a property you rely on *from the capture*. So KV reads resolve
**by key** against the recorded values (a key→value map + a write-through
overlay for the handler's own writes), **not** through an ordered cursor.
Serving the recorded value for each key re-materialises byte-identical JS
behaviour — the *order* the engine hands out reads is invisible to the handler —
while being **robust to benign reordering** of independent reads (which an
ordered cursor spuriously flagged as divergence, a false negative that made
`replay --source-dir` unusable for refactored code).

The map is a lossy representation of the raw *tape* (it drops read-order, holds
one value per key) but is **not lossy for executing the JS**: within an
activation the handler only ever needs the recorded value per key plus its own
writes, and the overlay supplies the latter (read-modify-read reproduces; a
pinned per-activation snapshot means no key returns two different values without
a local write).

**Faithfulness, when you want it, is an output-level assertion** — does the
re-run reproduce the recorded status / response / writeset (`status_match`)? —
not a per-read order check. That's the altitude that matters and it's
implementation-agnostic. The `fail` miss-policy therefore fires only on a read
the recording **never captured** (an honest "your code walked into territory the
recording doesn't cover"), never on a reorder. `resolve` makes such a read
best-effort (`not_found` + a typed hole). The ordered-cursor `.tape` mode
survives in `host.zig` only as an optional strict / non-determinism audit
primitive; it is no longer the default replay path.

## 2. The activation is the unit; a request is a fold of worlds

An activation is the pure function the engine already runs:

```
update : (Msg, Ctx) -> (Writeset, Cmd Msg)
```

run against its recorded **Msg**, a pinned **Model snapshot** (the readset —
foreign kv reads, fetch-response `BodyRef`s, module hashes, the seed), and the
threaded **ctx**. That tuple *is* a world.

**A handler is a module of named exports** — the Elm `update` with each
`case msg of` arm hoisted to `export function on…` (`handler-shape.md` §1).
Dispatch is **activation-kind → named export**.

**The resolved-export nuance (the thing that is easy to get wrong).** For a
*callback/continuation* activation — an `on.fetch` result, a `{to}` override, a
`webhook.send` `onResult` — the export is the **resolved name carried on the
wake**, *not* derived from the activation kind:

- `UpstreamFetchEvent.resolvedExport()` (`src/js/components.zig:377`): `{to}`
  name if given, else `onFetchResult` (whole body) / `onFetchChunk`
  (intermediate) / `onFetchDone` (terminal) by event shape.
- `defaultExportForKind()` (`src/js/rpc_dispatch.zig:63`) is only the
  **fallback** when the resume didn't name one: `wake_batch`/`kv_wake`/`timer`
  → `onWake`, `disconnect` → `onDisconnect`, `ws_message` → `onMessage`,
  `inbound_headers` → `onHeaders`, `inbound_chunk` → `onChunk`, else `default`.
  Note `fetch_chunk` falls to `default` here — which is *wrong* for a fetch
  callback; the real export came from `resolvedExport`, computed at runtime.

So `fetch_chunk` does **not** dispatch to `default`. A world for a callback
activation must carry *which export ran* (§5 G3).

**A request is `foldl(handlers, kv0, activations)`** (`handler-shape.md` §11) —
a chain of per-activation worlds linked by `Cmd(http_fetch) → fetch_chunk Msg`.
Each activation is independently runnable; a "saga" is the optional composition
that feeds one activation's emitted fetch result into the next activation's Msg.
There is **no continuation reconstruction** — no live closures cross
activations, only the serializable `ctx`. The cross-activation "same key, two
values" worry is a non-issue: each activation has its *own* tape/snapshot, so
they are simply different worlds.

## 3. What a world must carry, per activation kind

The per-activation `request` surface (`handler-shape.md` §7) is what a world
declares/captures:

| activation | export | world inputs (beyond kv readset + seed + bytecode) |
|---|---|---|
| `inbound` (default) | `default` | `request.method/.path/.headers/.body/.cookies/.ip` (read-recorded) |
| `inbound_chunk` | `onChunk` | this chunk's bytes (binary), `request.done`, `request.chunkSeq`, `request.ctx` |
| `on.fetch` result/chunk/done | `onFetchResult`/`Chunk`/`Done` or `{to}` | flattened: `request.body` (bytes), `request.status/.ok/.done/.fetchId`, threaded `request.ctx`, `request.activation.*` metadata |
| `on.kv`/`on.timer` wake | `onWake` or `{to}` | `request.ctx`; matched keys on `request.activation.wakes[]` (edge — "go look") |
| `ws_message` | `onMessage` | `request.activation = {opcode, data}`, `request.ctx` |
| `disconnect` | `onDisconnect` | `request.ctx` |
| `durable_wake` / `cron` / `schedule` | the named target | `request.activation.msg`; no inbound headers/body; connection verbs inert |
| `onBoot` / `onSubscription` | `onBoot` / `onSubscription` | origin-specific; no inbound surface |

`request.ctx` is `undefined` on the **first** activation of a chain. The
request surface is **read-recorded** (`handler-shape.md` §7.1): names always
recorded, values/body/ip on access; an unrecorded read on replay is a loud
`REPLAY DIVERGENCE`.

## 4. The five tape channels (capture) vs what the driver decodes (replay)

Capture writes five channels (`src/tape/root.zig:127`):

| channel | carries |
|---|---|
| `kv` (0) | ordered kv **reads** (`get`/`prefix` + outcome); `set`/`delete` are outputs, never taped |
| `module` (1) | resolved module specifier → source hash (bytecode pin) |
| `fetch_responses` (2) | a fetch result's bytes + terminal `status`/`ok`/`body_truncated` (`worker_streaming.zig:3236`) |
| `trigger_payload` (3) | the request **body** (inbound) **or** a synthesized `{"ctx": …}` envelope (continuation resume) — `worker_drain.zig:1448`, `liftThreadedCtx` `globals.zig:2253` |
| `request_reads` (4) | the read-recorded `request` surface (header names/values, body-read flag, ip) |

So the inputs for *every* activation kind are taped — `ctx` rides
`trigger_payload`, a fetch result rides `fetch_responses`. The capture side is
(largely) complete.

## 5. As-built driver gaps (snapshot 2026-06-30)

The offline driver (`src/replay/`) and the recording side do **not** yet make
every activation runnable. Three gaps, in priority order:

- **G1 — the driver decodes only `kv` + `request_reads`.** `root.zig` never
  decodes `fetch_responses` or `trigger_payload`, and `epilogue.zig` rebuilds
  only the inbound surface. So `request.ctx` and the flattened fetch-result
  fields are **absent** on replay → any non-`inbound` activation hits a
  spurious `REPLAY DIVERGENCE`. The data is taped; the driver just doesn't read
  it. *(Replay-side fix.)*
- **G2 — `epilogue.exportForActivation` can't select the right export.** It
  lacks `fetch_chunk` (falls to `default`) and has no way to honor a resolved
  export / `{to}`. *(Replay-side fix, but depends on G3 for the input.)*
- **G3 — the resolved export (the dispatch target) is not persisted.** The
  `LogRecord` stores only the `ActivationSource` *kind* (`src/log/root.zig:386`);
  `resolvedExport`'s discriminators (`stream`/`final`, the `{to}` `name`) live
  only in the live event. The no-`{to}` fetch export is *derivable* from the
  `fetch_responses` terminal flag, but a **`{to}` override is lost entirely**.
  Faithful replay of callbacks therefore needs a **recording-side** change:
  persist the export actually invoked (it is an input per L3/§2.5). *(Recording-side fix.)*

**Update 2026-06-30 — mechanism landed, then a REAL recording refuted the fetch
data-path.** The driver gained decoders + install for `trigger_payload` (the
`{"ctx": …}` envelope → `request.ctx`) and `fetch_responses` (→ the flattened
`request.status/.ok/.done/.fetchId` + body), export-resolution by event shape,
and `pull` carries the channels. That passed a *programmatic* fixture — but
validating against a **real** `fetch_chunk` recording (a live `on.fetch` →
`onFetchResult`, `scripts/smoke/replay_noninbound_smoke_v2.py`) refuted the
assumption the fixture baked in:

- **The pulled `fetch_chunk` record's tapes are ALL empty (0 B)** — not just
  `fetch_responses`, but `activation_bytes`, `trigger_payload`, `request_body`,
  `request_reads`, `kv` too. The handler demonstrably read the 170-byte fetch
  result at runtime (`request.body = fc.bytes`, `globals.zig:2610`), yet none of
  it is in the pulled record. So the gap is at the **recording/pull layer** —
  what a callback activation persists for offline replay — not the decode layer.
  `root.run` reading `fetch_responses` was doubly moot: the data isn't in *any*
  channel of the pulled record.
- **Open question: where (if anywhere) is a `fetch_chunk`'s result captured?**
  Either it rides a record/field `pull` doesn't surface, or it lands on a
  *different* record than the `fetch_chunk` one, or callback activations don't
  fully self-capture their Msg. This needs a recording-side investigation
  (the validation smoke dumps every record's tape sizes to start it).
- **The reference is no further along.** `rewind-apps/replay/_static/request-replay.mjs`
  also maps `fetch_chunk → "default"` and never reconstructs the fetch/ctx
  surface. Faithful non-inbound replay is unimplemented *across the stack*, not
  just in this port.
- Secondary: the bare replay arena lacks `TextDecoder` (a handler using it
  ReferenceErrors on replay) — an engine-global gap independent of this work.

**Update 2026-06-30 (b) — FIXED (recording side) + validated.** The root cause
was a capture bug: the bound-fetch resume paths logged the `fetch_chunk`
activation with **empty tapes** (`.{}`), so its Msg — the fetch result, an input
(L3) — was never recorded. Fixed by `captureFetchChunkTapes`
(`worker_log.zig`): each `fetch_chunk` resume now records the fetch event onto
its readset's `fetch_responses` channel (inline raw bytes for ≤16 KB → fully
replayable offline; a `BodyRef` for larger, offline-out-of-scope) and captures
the real tapes. Wired across **all three resume paths** — `resumeBoundFetchChain`
(buffered HTTP), `resumeBoundFetchStream` (streaming HTTP),
`resumeBoundFetchChainWs` (WS). Plus `pull` carries `fetch_responses` +
`trigger_payload`, and `root.run` decodes them. **Validated end-to-end against a
REAL recording** (`scripts/smoke/replay_noninbound_smoke_v2.py`): a live
`on.fetch` → `onFetchResult` now tapes the fetch event and offline `rewind
replay` reproduces `request.body` + `request.status`. `on_fetch_smoke_v2` and
`ws_fetch_smoke_v2` confirm the effect paths are unregressed.

**Update 2026-06-30 (c) — the WS resume class fixed too.** The same empty-tape
bug affected the WS `ws_message` / `wake_batch` / `disconnect` resumes (via
`finishWsResume` + `fireWsDisconnect`). Fixed with the same shape — tape the
activation's Msg: `ws_message` records the frame (`captureWsFrameTapes` →
`activation_bytes = [opcode][data]`; `root.run` rebuilds
`request.activation = {opcode, data}` — text frames reproduce, binary is a
follow-up), `wake_batch` / `disconnect` record readset + ctx. `pull` carries
`activation_bytes`. **Validated end-to-end** (`replay_ws_message_smoke_v2.py`): a
live WS text frame → `onMessage` now tapes the frame and offline replay
reproduces `request.activation.data` (asserted via the handler's `kv` write).
`ws_worker`/`ws_wake`/`ws_fetch` smokes unregressed. (HTTP non-fetch continuation
resumes — `onWake`/`timer`/`onChunk` — already captured; they were never in this
class.)

Remaining: ~~(a) a `{to}` override is unrecorded (**G3**)~~ **FIXED** — the
resolved export (`ev.resolvedExport()`) now rides `TapePayloads.export_name`
(recorded per fetch resume, emitted as the record's `export` field), `pull`
carries it, and `root.run` prefers it over the event-shape derivation. So an
overridden callback replays under its actual export. Validated in the matrix
(`replay_matrix_smoke_v2.py` uses `{to:'onUpstream'}` with **no** `onFetchResult`
— reproduction proves the recorded export is used). ~~(b) `TextDecoder`/`stream.*`/`next` absent in the bare
replay arena~~ **FIXED** — the epilogue now shims `TextDecoder`/`TextEncoder`,
`stream.*`/`on.*`/`next`/`webhook`/`schedule`/`cron`/`blob`/`request.tag`; outputs
are captured into the bundle (`stream`/`wakes`/`sends`) rather than fired.
`stream`/`on`/`next`/`TextDecoder` are fully faithful; `webhook`/`schedule`/
`cron`/`blob` record but don't re-run their durability shims (their kv markers
aren't reproduced — the handler's own kv writes are). ~~(c) binary WS frames need
a `Uint8Array` surface~~ **FIXED** — a binary frame (opcode 2) carries its bytes
as base64 (`activation.dataB64`); the epilogue rebuilds the `Uint8Array` on
`request.activation.data` (text frames keep their string). The
**sim** path (authored worlds) never depended on any of this.

**Update 2026-06-30 (d) — regression guards built.** So this class can't
silently return: (1) an **L3 capture-time assert** (`worker_log.l3AssertMsgRecorded`
at the `captureLogWithId` chokepoint) — a successful callback activation whose
Msg channel is known-and-always-populated (`fetch_chunk`→`fetch_responses`,
`ws_message`→`activation_bytes`) that ships **empty tapes** panics in debug/
tests (loud-logs in prod — the log path must never crash a live request) and
names the fix. Zero false positives: kinds whose Msg may legitimately be empty
(disconnect/boot/edge-wakes) aren't asserted; **extend the switch when a new
callback kind lands**. Because smokes run Debug workers, *every* smoke is now an
L3 checker — it caught a deliberately-regressed capture site (fired during the
deploy flow, before the test even ran). (2) A **per-kind replay matrix**
(`scripts/smoke/replay_matrix_smoke_v2.py`) captures + replays a real `inbound` /
`fetch_chunk` / `ws_message` recording and asserts each reproduces. The pure
predicate `l3MissingChannel` has an inline unit test.

## 6. Implications for the sim / export-fixture plan

- **Sim (authored world) works for *any* activation with `world.zig` changes
  alone** — the author/transcoder declares the activation kind, the export, the
  Msg, `ctx`, and the fetch-result fields. No recording change. This is the
  cheap, high-leverage path.
- **Replay (captured world)** is faithful for `inbound` today; non-`inbound`
  needs G1+G2 (decode the taped channels) and G3 (persist the dispatch target).
- **`export-fixture` (capture → authored world)** transcodes a `rewind pull`
  fixture into a declarative world. The within-activation KV correctness it
  needs — a **write-through overlay** (read-your-writes) plus an explicit
  **`kvAbsent` set** (recorded not-found reads, so `miss-policy=fail` reproduces
  the recording exactly) — is local to one activation; cross-activation is just
  separate worlds (§2). **Landed 2026-06-30 for the inbound family** (`rewind
  export-fixture`, `src/replay/export_fixture.zig`): the KV read cursor →
  initial-snapshot map + `kvAbsent` (the first taped read per key; re-reads /
  post-write reads are reproduced by the sim overlay), the `request_reads` fold
  → `request` surface, sources passed through (self-contained), `missPolicy:
  "fail"`. Non-inbound activations warn — the pulled fixture lacks `ctx` /
  fetch-result / the resolved export (G1/G3 above), so their worlds are
  incomplete until the recording-side fix.

Landed 2026-06-30: the declarative-world sim path (`world.zig`, the host's
`.map` mode + miss policy, `runWorld`, `rewind sim`), now covering **all
activation kinds** — a world declares the `activation` kind, the resolved
`export` (the `{to}` / callback name), the threaded `ctx` (→ `request.ctx`), the
flattened fetch/callback result (`request.status/.ok/.done/.fetchId/.chunkSeq`),
and the `request.activation` metadata bag, per the §3 table. So G1/G2/G3 above
constrain **replay** (captured worlds) only; **sim** of any activation needs no
recording change, because the authored world supplies the export and the
result/ctx surface directly. See
[`../plans/sim-test-framework.md`](../plans/sim-test-framework.md)
§"Built 2026-06-30" and §"The model — one run, parameterized".

## 7. See also

- [`effect-algebra.md`](../effect-algebra.md) — §1 determinism boundary, §2.5
  inputs-durable/outputs-derivable, §6 trigger scope (connection vs tenant).
- [`handler-shape.md`](../handler-shape.md) — §3 activation kinds → exports,
  §7 the `request` surface per kind, §11 `foldl` replay.
- [`effects-and-handlers.md`](effects-and-handlers.md) — the reified primitives,
  the readset in the raft entry, the continuation runtime.
