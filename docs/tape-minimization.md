# Tape minimization — the minimal replay tape

> 🟢 / 📋 **As-built + design.** What a deterministic replay tape must record, and
> the arc that reduced it to four record kinds. §1 (the removed per-chain cap) and
> §3–§5 (minimal read set, seeds, the four-kind synthesis) are **shipped**; §2
> (tape-by-reference for streamed bytes) is **design-only**, gated on customer
> LLM-stream demand. The effect-model frame is [`effect-algebra.md`](effect-algebra.md);
> the readset / blob-coordinator mechanics are in
> [`architecture/effects-and-handlers.md`](architecture/effects-and-handlers.md)
> and [`architecture/routing-and-ingress.md`](architecture/routing-and-ingress.md).
> (Harvested from the retired `primitive-gaps.md` §6–§10.)

## 1. Bounded tape per chain — **CONSIDERED AND REMOVED 2026-05-26**

The original framing was: streaming primitives can produce unbounded
per-`correlation_id` tape (LLM proxies, held outbound subscriptions); without a
per-chain byte budget those classes either drown the replay store in cost or
force "non-replayable" carve-outs. The mechanism shipped briefly: a sharded
`NodeState.tape_state_shards` map (correlation_id → `{bytes_used, capped,
last_touch_seq}`), 10 MB default, sharded 16-way after a ~4× regression on 8w
sharded writes when a single global mutex was tried.

**Why removed.** Per-chain activation throughput is bounded by sequential commit
latency (~ms per activation, i.e. low hundreds to ~1k activations/sec). Aggregate
normal traffic across many independent chains outpaces any single chain by 2–3
orders of magnitude, so the dominant driver of replay-store cost is total tenant
volume, not pathological chains. The cap was solving a narrow worst-case (one
chain hours-long enough to accumulate hundreds of thousands of small activations)
at the price of a node-wide map + mutex traffic on the dispatch hot path. The
benefit was real but small; the storage-cost lever lives one level up.

**What replaces it.** Per-tenant retention / sampling (originally specced as v2's
`tape_mode` knob: `always` | `on_exception` | `sampled` | `never`). That knob
addresses the actual cost driver — *total* tape stored per tenant — and composes
cleanly with a plan-level retention cap. It is **not shipped yet** and is the
right place to add cost control when storage bills earn the optionality.

**What remains.** Content-addressed-large-bytes is still the right pattern
(`architecture/effects-and-handlers.md`, readset section): chunk bytes go to
blob, the tape carries the hash. This was independent of the cap; §2 below builds
on it directly.

## 2. Tape-by-reference for streamed bytes — **design-only, unbuilt**

**The gap.** §1 records chunk bytes by sending them to blob and keeping the hash
in the tape (~50 bytes/chunk). That works for Pattern A (`on_chunk`) — the bytes
cross a handler activation, so there is an activation to hang a tape entry on.
Pattern B (`pipe_to`) has no activation: upstream bytes are plumbed straight to
the held client by the transport, the handler JS never sees them, and the chain
is **structurally untaped** past the `pipe_to` Cmd ([[project_pipe_to_untaped]]).
A replay reconstructs everything except the one thing the chain existed to do.

**The mechanism.** Record a stream as a list of **extents** — `{hash, offset,
length}` — instead of inline bytes; the tape holds the pointer, the bytes live in
a content-addressed store, replay resolves the extents back. Crucially the
recording happens at the **transport layer**, so `pipe_to` gets a tape without
the handler touching a byte. This is §1's pattern lifted from per-activation to
per-transport. The only real variable is *where the bytes already live*:

- **Tier 1 — source is already a CAS (zero-copy).** A `pipe_to` of a static asset
  out of `file-blobs/` streams bytes that are already content-addressed and
  immutable. The tape records `{existing-hash, range}` and copies nothing — the
  CAS doubles as the tape's byte store. Genuinely free; closes the `pipe_to` gap
  outright for static serves.
- **Tier 2 — remote source, bytes cross an activation.** Pattern A against a
  remote upstream. §1 already specs it (copy chunk to blob, tape the hash).
  Unchanged.
- **Tier 3 — remote source, no activation, or full-fidelity demand.** The bytes
  exist nowhere durable; the tape cannot reference them until we *make* them
  content-addressed (hash-on-ingest). Not free — it relocates bytes from nowhere
  into CAS. CAS is a defensible home (dedup across replays, the page-encryption
  story, content-addressed-everything), but this is relocation, not elimination.

### 2.1 The LLM stream case — Tier 3, opt-in, not built

Proxying an LLM token stream is the worst Tier-3 case and the most valuable at
once. **Non-reproducible by re-execution** — re-calling the API on replay costs
money and returns different tokens (even provider `seed` parameters are
best-effort + void on model-version change). For an LLM stream, the tape is the
*only* path to faithful replay. Without it the chain isn't expensive to replay,
it's unreplayable.

LLM-stream tape capture is an **opt-in, plausibly billed** primitive when it
ships — Tier 3 adds a CAS write to the streaming hot path, a real cost the
customer elects for replay fidelity available no other way. Persist-before-observe
at chunk grain; local hash + async PUT keeps first-token latency intact. Pattern
A also needs a boundary-offset list since activation sequence depends on network
chunking; Pattern B is a single whole-body extent.

The retention coupling — a blob referenced by a live tape must be pinned against
GC — is the only new infrastructure obligation, and `rove-files`'s
`TenantFilesSnapshot` already does refcount-pinned snapshots; this is a refcount
edge, not new machinery.

**Status: design-only, unbuilt.** Trigger to ship: customer with real LLM-stream
replay demand. Tier 1 (zero-copy extents for CAS-sourced `pipe_to`) is a cheap
incidental that closes the static-serve replay gap if anyone wants it. Tier 2
(Pattern A against remote upstream, copy chunk to blob + tape the hash) needs no
new work — falls out of the per-chunk capture once Tier 3 ships.

### 2.2 ~~Customer-facing blob primitives~~ — canceled with effect-reification Phase 7

Originally specced as `blob.put` / `blob.get` JS shims giving customer handlers
direct access to the BlobBackend, with bytes-as-derivable-output recovery via
re-execution. Canceled 2026-05-27 alongside effect-reification Phase 7
(files-server-standalone stays a separate binary, doesn't fold into JS-shim
composition). No customer demand established; defer until a concrete use case
forces it.

**The input/output asymmetry the cancelation rests on still holds.** It's the
cross-cutting principle behind gap 2.4's design: inbound bytes are recorded
inputs (durable home, persist-before-observe); outbound bytes are derived outputs
(ephemeral, re-derivable from inputs). Readset-replication's per-tenant buffer +
callback-gate IS the inbound primitive — inbound streaming ships as "wire
readset-replication into the inbound path," not as a separate effect. See
`effect-algebra.md` §2.5 for the "inputs durable / outputs derivable" frame.

## 3. Minimal read set — drop writes and own-reads from the tape

**SHIPPED 2026-05-26.** RTAP wire bumped 1 → 2. Capture-side: `globals.zig`'s
`jsKvGet` skips the tape append when `state.writeset.containsKey(key)` (own-read);
`jsKvSet` and `jsKvDelete` no longer append at all (writes are outputs, replay
re-issues them). Replay-side: the WASM host callbacks
(`_arena_host_kv_get/set/delete` in `web/replay/_static/qjs_arena_wasm.js`) now
maintain a `Module._kvOverlay` Map per replay session; `kv.set`/`delete` write to
the overlay, `kv.get` checks the overlay first and falls through to the tape only
on miss (foreign-read path). `cursor.mjs:_installReplay` resets the overlay
between replays.

The principle the change rests on: replay re-runs the handler, so the tape only
needs inputs re-execution *cannot* reproduce. Writes (`.set` / `.delete`) are
outputs — re-issued by re-running. Own-reads (a `.get` of a key in the same
activation's writeset) read a value the activation itself produced. What remains
is the **minimal read set**: gets + prefix scans resolving to state committed
before the activation began, plus date/random/crypto/module channels.

Divergence detection is preserved: a diverging write can only be the symptom of a
diverging read or bytecode mismatch — both caught by the remaining input-channel
coverage.

`kv.prefix` is unminimized in v1 (the merge of committed rows + in-range overlay
writes is fiddly). `KvOp.set` / `.delete` wire variants stay readable for old
tapes but stop being written.

## 4. Generative channels — record the seed, not the draws

**SHIPPED 2026-05-26.** §2.2 split taped inputs into *generative* (a seed the
runtime re-runs to recompute the input) and *referential* (a pointer resolved
against a store). `math_random` is generative — but only if the PRNG is
**bit-identical between the capture engine and the replay engine**. That
precondition is now met.

The principle: `Math.random` is a rove override drawing from a rove-owned PRNG
seeded per request. Record the **seed**, not the draws — replay re-seeds
identically and re-runs; every draw reproduces bit-for-bit. Same argument as §3's
writes: given pinned bytecode and faithful other channels, control flow is
identical, so the PRNG is called the same number of times in the same order. The
unlock: the WASM replay engine runs rove's *own* JS host compiled to WASM
(arenajs + globals.zig overrides), so the same PRNG executes on replay —
value-recording's engine-drift safety isn't lost, because both sides ship in
lockstep.

Cross-version replay needs an engine/PRNG-version pin on the tape header (sibling
to `.module` source-hash). PRNG-algorithm change = tape-format version bump.

`crypto.*` follows the same shape via the seed entry; secret-in-tape exposure is
unchanged from the prior value-recording (page-encryption at rest remains the
mitigation). `Date.now` is unaffected — a clock read is genuinely external, not
generative; stays value-recorded as the `timestamp_ns` scalar.

## 5. The complete minimal tape

§2–§4 converge on a closed result: every taped input is one of **four record
kinds** — a minimal read set, a timestamp, a random seed, or (where bytes live in
a content-addressed store) a `{address, offset, length}` extent. The five
channels collapse onto them:

| Channel | Today | Minimal form | Kind | Section |
|---|---|---|---|---|
| `kv` | foreign gets/prefixes only | foreign gets/prefixes only | read set | §3 ✅ |
| `date` | — (deleted) | pinned `timestamp_ns` scalar | timestamp | §4 fold-in ✅ |
| `math_random` | — (deleted) | one per-request seed | seed | §4 ✅ |
| `crypto_random` | — (deleted) | one seed | seed | §4 ✅ |
| `module` | specifier → bytecode hash | unchanged — already a hash | CAS extent | §2 |

§4 shipped 2026-05-26: `math_random` + `crypto_random` were retired as dedicated
tape channels. arenajs's per-context xorshift64star is seeded once per request via
`JS_SetRandomSeed(ctx, readset.seed)` in `globals.installRequest`;
`crypto.getRandomValues` / `randomUUID` / `randomBytes` draw from the same state
via `JS_FillRandomBytes`. Replay reseeds with the captured request's seed via
`arena_set_random_seed` (cwrapped from the WASM build) — no per-draw entries, no
host callouts.

§4 fold-in (same day): `date` was retired as a tape channel too. `Date.now()` and
`new Date()` (no args) are pinned per-request via arenajs's `JS_SetDateNow` API —
every call within one request returns `@divTrunc(readset.timestamp_ns,
ns_per_ms)`. Same posture as Cloudflare Workers / Lambda SnapStart. Replay pins
via the WASM reactor's `arena_set_date_now` export. The remaining wire channels
are `kv` + `module` + `fetch_responses` + `trigger_payload` (4 channels,
READSET_VERSION 4).

By the §2.2 mechanism axis: the read set and the timestamp are **direct values** —
recorded inline, irreducibly; a clock read is neither generative nor referential,
just a small external number. The seed is **generative** (re-run to recompute).
The extent is **referential** (resolved against a store).

Two consistencies close the loop:

- **`module` was always a CAS reference.** It records a bytecode *hash*, not the
  bytecode — an address with an implicit whole-blob extent. §2 does not invent the
  CAS-reference pattern for the tape; it generalizes the one the module channel
  has used all along.
- **Read set and CAS extent meet at the size threshold.** A small kv read is
  recorded inline; a large one is recorded as an extent
  (`architecture/effects-and-handlers.md`, readset section). Same input — the
  threshold picks the form. The four kinds are not disjoint; "extent" is what any
  oversized value-record becomes.

The activation's own triggering Msg is recorded the same way — a direct value when
small, an extent when large — so it is not a fifth kind.

That is the whole tape. A minimal read set, timestamps, seeds, and CAS extents
are the entire non-deterministic frontier; everything else a handler does — every
write, every own-read, every computed value — is recomputed on replay.
