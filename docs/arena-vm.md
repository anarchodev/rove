# Arena VM

A speculative plan for evolving the JS runtime from a refcounted general-purpose
engine into a purpose-built arena VM. Not a commitment — a sketch of what the
path looks like if we decide to take it, with phase boundaries that each leave
the system better than they found it.

## Motivation

Today's JS path is QuickJS-ng with a hand-tuned snapshot/restore mechanism:
~5-7μs cold start, <150KB per-instance overhead. This is already faster than
anything in the WASM-serverless ecosystem (StarlingMonkey, Fastly Compute,
Fermyon Spin) by 1-2 orders of magnitude.

The friction we keep hitting:

- **CoW pooling doesn't work for QJS**, because refcounting writes are
  scattered across the heap and a 4-byte refcount bump faults a 4KB page. We
  tried it; it tanked.
- **Refcount manipulation is overhead** in every property access, function
  call, return, argument pass. For interpreter-bound workloads this compounds.
- **Determinism for replay (rove-tape)** has to be carefully managed because
  the runtime has timing-dependent code paths (cycle collector, allocator
  reuse) that aren't naturally deterministic.
- **The debugger story is thin.** QJS has limited debug hooks compared to
  SpiderMonkey, and adopting SpiderMonkey trades one set of problems for
  another (interpreter-only in WASM, ~50× memory footprint, and the
  refcount/CC writes-on-read pathology relocates to the GC marking phase
  rather than going away).
- **High concurrency density is bounded by per-instance memory**, because each
  in-flight request holds a private snapshot.

The structural observation: every workaround we've considered is dancing
around the fact that the runtime semantics that fit the request model are
**arena-scoped** — a request gets a heap, runs to completion, throws the
heap. Refcounting and cycle collection are general-purpose lifetime
mechanisms; in this product they're vestigial.

## Thesis

Build a runtime where:

- The entire JS heap is request-scoped. End of request resets the bump
  pointer; no frees, no GC, no refcounts.
- Runtime data structures (shapes, atoms, bytecode, prototypes, ICs) are
  immutable and shared across concurrent requests via a read-only mmap.
- User-allocated state (objects, strings, arrays) lives in a small private
  per-request bump arena.
- Mutation in JS source maps to append-only operations under the hood.

This is what QJS's snapshot path is *trying* to be; it's just being held back
by QJS's general-purpose lifetime model. Going to a real arena VM unlocks
several wins that aren't achievable with the current path:

- Faster execution (no refcount manipulation in hot paths)
- Higher concurrency density (shared snapshot, small private arenas)
- Provable determinism (deterministic-by-construction allocator + immutable
  runtime structures)
- Time-travel debugging (snapshot the bump pointer, step backward)
- Simpler runtime, fewer subsystems, smaller footprint
- Architectural option value (the runtime layer becomes language-agnostic;
  JS becomes one possible source language rather than a structural
  assumption)

## Non-goals

- Compatibility with general-purpose JS workloads. Long-lived heaps,
  mid-execution memory reclamation, and `WeakRef` cleanup don't have to work
  in arena mode.
- Drop-in replacement for QJS upstream. Once we commit, we own the runtime;
  upstream tracking ends.
- ECMAScript spec compliance for things that depend on GC observation
  semantics (FinalizationRegistry, WeakRef-based memoization). Document the
  divergences; reject handlers that depend on them.

## Related work

The integrated package this doc proposes — bump-allocated request-scoped
heap + immutable runtime data structures + append-only object
representation + record-replay debugging derived from inputs — does not
appear to exist as a single shipped system, based on a literature pass.
Several pieces have meaningful overlap with prior art worth knowing about.

**Theoretical foundations.** Region-based memory management (Tofte-Talpin
region calculus, MLKit, Cyclone) is the academic lineage. Decades of
research formalize the idea that lifetime-bounded heaps can replace
tracing GC. The arena VM is a practical instance of this lineage applied
to a JS-shaped surface language.

**Per-request memory pools in C servers.** Apache APR and AOL Server /
NaviServer have shipped per-request memory pools for decades. Same
lifetime model, but for handwritten C handlers, not a managed-language
runtime.

**Per-execution heaps in managed runtimes.** Erlang BEAM gives each
process its own heap, freed on process exit. Closest "managed runtime
with per-execution heap" model in production, but per-process not
per-request, and BEAM still has tracing GC inside each process heap.

**Per-request V8 isolates.** Cloudflare Workers and similar platforms run
each request in a fresh V8 isolate, discarded between requests (with
pooling). Closest production JS analog, but each isolate has full V8 GC
inside; no arena lifetime model.

**WASM instance pooling.** Wasmtime's pooling allocator with
copy-on-write linear memory templates (Bytecode Alliance,
productionized by Fastly Compute) gives the per-request fresh-state
model at the WASM instance level. Doesn't address what runs *inside* the
WASM instance.

**Wizer.** Bytecode Alliance OSS that snapshots a WASM module after
initialization, freezing parser/globals/top-level eval into a pre-run
image. The canonical name for the "snapshot the runtime after init"
pattern as applied to WASM. The QJS snapshot trick we already use is
conceptually identical, just outside WASM.
https://github.com/bytecodealliance/wizer

**StarlingMonkey + Wizer.** SpiderMonkey-on-WASI with parser, globals,
and top-level eval baked in via Wizer. Snapshots immutable runtime
metadata; still has SpiderMonkey's full GC inside the per-request
instance. Discussed in the Motivation section above.

**weval (Chris Fallin, PLDI 2025).** Most closely overlapping prior
work. Partial-evaluates the SpiderMonkey Portable Baseline Interpreter
against a snapshot containing parsed bytecode and pre-warmed inline
caches, producing AOT-specialized WASM. The canonical "freeze the
interpreter and program together at compile time" technique. Reports
2.77×-5× speedups on Octane vs the base interpreter. Critically, weval
and the arena VM are **complementary, not competing**: weval freezes
the *interpreter and program*; the arena VM freezes the *heap layout
and lifetime*. A future combined system could do both — arena heap
*plus* weval-style AOT specialization of the interpreter loop. If
interpreter dispatch ever becomes a measured bottleneck after the arena
VM is in place, weval is the next optimization to layer on rather than
something to choose between. https://cfallin.org/pubs/pldi2025_weval.pdf,
https://github.com/bytecodealliance/weval

**Lobster (Wouter van Oortmerssen).** Refcount + compile-time lifetime
analysis, no tracing GC, game-shaped scripting language. Different point
in the design space — same "no GC" philosophy via static analysis
instead of arenas. Worth reading as a comparison.

**Stored-procedure runtimes.** PL/V8 (Postgres) runs JS code in a
per-query lifetime context inside a per-session V8 runtime. Weakest
analog; database stored-procedure example of "scoped lifetime" applied
to JS, but not arena-shaped.

**Record-replay debuggers.** rr (Mozilla, Linux), Replay.io (commercial
Node/browser), Microsoft Time Travel Debugging. All implement timeline
scrubbing UX, but on top of existing GC'd runtimes by recording
syscall-level nondeterminism. None tied to arena runtimes; the
record-replay mechanism is heavyweight (gigabytes of trace per session)
compared to what an arena VM enables.

**Timelapse (Burg et al., UW, 2013).** Academic work on input-driven web
debugging where execution is re-derived from recorded inputs and the
developer scrubs through bookmark points. Closest published prior art
for the debugger UX this doc proposes — frames derived from inputs, not
stored. Not tied to an arena runtime, but the "frames as a function of
inputs" insight is the same one.
https://faculty.washington.edu/ajko/papers/Burg2013Timelapse.pdf

**What appears to be novel.** The combination that doesn't have clean
prior art: **append-only property storage in a bump arena, with shapes
and ICs frozen into the snapshot**. weval freezes ICs but the heap is
mutable; StarlingMonkey snapshots globals but objects mutate normally;
arena allocators in C servers don't have shapes to freeze. The
integrated "frozen runtime metadata + append-only object representation
in a request-scoped arena" combination is the load-bearing novel claim.
Worth a deeper literature pass on OOPSLA/PLDI 2023-2025
object-representation papers before treating it as definitively novel.

**Counter-examples worth knowing.** Hermes (React Native) is sometimes
characterized as arena-shaped but actually has a generational tracing
GC. Luau (Roblox) has a custom pool allocator but a tracing GC; not
arena-VM-shaped. Both are good examples of "AOT bytecode + tuned GC"
rather than "no GC, arena lifetime."

## Design

### Two-region heap

```
┌─────────────────────────────────────────────────────────────┐
│  Snapshot region (mmap'd read-only, shared across requests) │
│  - Atom table                                               │
│  - Shape transition tree (immutable, append-only at build)  │
│  - Module bytecode                                          │
│  - Pre-warmed inline caches                                 │
│  - Constructed prototype chain                              │
│  - Customer handler bytecode + closures                     │
└─────────────────────────────────────────────────────────────┘
                           ▲
                           │ pointers OK (snapshot lives forever)
                           │
┌─────────────────────────────────────────────────────────────┐
│  Per-request region (private bump arena, ~64KB-1MB)         │
│  - User-allocated objects, strings, arrays                  │
│  - New shape transitions discovered this request            │
│  - Mutable closure cells                                    │
│  - Stack frames                                             │
└─────────────────────────────────────────────────────────────┘
```

Pointers from the per-request region into the snapshot are common (any
reference to a builtin, a prototype, the handler itself). Pointers from the
snapshot into the per-request region never exist by construction — the
snapshot was built before any request started.

End of request: drop the per-request region (reset bump pointer). Snapshot
untouched.

### Immutable data structures

**Shapes (hidden classes).** Pure transition tree. Adding a property follows
an existing transition or appends a new node. No refcounting, no cloning, no
hashing of mutable shapes. The shape table grows monotonically through the
arena; old shapes are never freed because they're never garbage. Snapshot
contains the pre-explored portion of the tree (built during snapshot
construction by running representative inputs); per-request region holds any
new shapes discovered during execution.

**Property storage.** Append-only. When an object's property array fills,
allocate a fresh 2× array adjacent in the arena, copy contents, update the
object's property pointer. Old array is unreachable but not freed. Amortized
O(1) per add, same as in-place realloc but with no refcount check and no
clone path.

**Strings.** Ropes by default for concat-heavy code:

- `s += t` allocates a rope node pointing at both. O(1).
- Linearization happens lazily on access (e.g., when `length` is read or the
  string crosses an FFI boundary).
- For small strings (under some threshold), inline as flat byte arrays.
- Atoms (interned property names) live in the snapshot region for stable
  pointer identity.

**Closures.** Two cases:

- *Read-only captures* (most cases): embed the captured value directly in the
  closure object. Trivial.
- *Mutable captures* (`let x = 0; () => x++`): heap-allocate a cell in a
  dedicated mutable-cells sub-arena. Confine all mutation to this sub-arena
  so the rest of the runtime stays truly immutable.

**Inline caches.** Bake into the snapshot during pre-warming: run the
handler against representative inputs, capture the resulting IC state,
freeze it. Per-request execution reads the warmed ICs but never mutates
them. Adaptive IC behavior across requests is lost; for short-lived
handlers it never paid off anyway.

### Lifetime model

- No refcounts. Anywhere.
- No cycle collector.
- No mid-request frees.
- End of request: reset the per-request bump pointer to 0.
- OOM: per-request region exceeded → return error to handler. Surfaces as a
  per-handler memory budget in the API.

### Object identity

`obj1 === obj2` must keep working across "modifications." Approach:

- The JSObject struct stays at its allocated address; never moves.
- The struct holds a pointer to its current property storage (and its current
  shape).
- "Modifying" the object writes new pointers to the struct's fixed slots; the
  struct itself is mutable in place but only at the indirection level. The
  object identity (the struct's address) is stable.

This adds one indirection on property access. For a hot path, this is the
main cost relative to in-place mutation. Likely 5-10% interpreter overhead;
recoverable with escape analysis (see Phase 7).

### Determinism contract

The snapshot is byte-stable: same handler bytecode produces same snapshot
bytes. The per-request execution is deterministic-by-construction:

- Allocator state is purely a function of allocation history.
- Hash iteration order = insertion order (already JS spec for objects).
- No timing-dependent code paths (no CC, no GC, no async I/O during pure
  compute regions).
- All host-call results are recorded by rove-tape.

Result: for any (snapshot, input sequence) pair, the per-request arena bytes
at end-of-request are identical across runs. Replay verification reduces to
memcmp of the final arena. rove-tape can drop most of its
nondeterminism-handling code.

## Phased plan

Each phase is independently shippable and leaves the runtime strictly better
than it started. The plan should be paused after each phase and re-evaluated
against measured outcomes.

### Phase 1: Selective no-op fork (foundation)

**Goal:** Get the runtime cost wins without redesigning data structures.

**Effort:** ~2-3 months for one engineer.

**Changes:**

- No-op `JS_DupValue` / `JS_FreeValue` for non-shape types. Hide behind
  `QJS_ARENA_MODE` ifdef so the diff stays auditable.
- Replace shape refcount with monotonic "shared" bit (set once on first
  alias; never unset). Preserves the clone-before-mutate correctness path
  with much sparser writes.
- Replace `js_malloc` / `js_free` with bump allocator. Free becomes a no-op.
  `realloc` becomes "alloc new, copy, leak old."
- Remove cycle collector code paths.
- OOM = error, not GC trigger.

**Wins:**

- Faster execution. Removing refcount manipulation should yield ~20-40%
  interpreter throughput improvement on object-heavy workloads. Needs
  measurement.
- Simpler runtime (no CC, no free paths).
- Foundation for later phases.

**Validation:**

- test262 conformance (modulo documented divergences).
- Existing scripts/*_smoke.sh pass.
- Throughput benchmarks vs current QJS path.

**Stop here if:** the throughput win is enough on its own and the other
benefits aren't currently load-bearing. Phase 1 is a clean stopping point —
the runtime is still recognizably QJS, just stripped down.

### Phase 2: Pure transition tree shapes

**Goal:** Remove all shape uniqueness tracking.

**Effort:** ~1 month.

**Changes:**

- Remove shape refcount / shared bit entirely.
- Property addition: walk transition tree, append node if needed, never
  clone.
- Shape table is append-only.
- Remove `js_shape_prepare_update` and related cloning paths.

**Wins:**

- Removes the only remaining refcount-related write surface.
- CoW pooling becomes structurally viable from this point onward.
- Closer alignment with how SpiderMonkey / V8 work.

**Stop here if:** the structural cleanliness is enough and the further
phases aren't justified by measured demand.

### Phase 3: Append-only property storage

**Goal:** Eliminate in-place realloc of property arrays.

**Effort:** ~1-2 months.

**Changes:**

- Object property add: bump-allocate fresh 2× array, copy contents, update
  object's property pointer. Eliminate `realloc` path.
- Eliminate in-place mutation in `JS_ConcatString2` and rope linearization.
- Replace string concat fast path with rope-by-default.
- Audit all remaining mutation sites; convert to allocate-new where
  feasible, document where unavoidable.

**Wins:**

- Heap is purely append-only.
- Determinism contract becomes provable.
- String-builder loops go from "fast if uniquely owned, quadratic otherwise"
  to "always O(N) via ropes."

### Phase 4: Two-region heap

**Goal:** Snapshot-shared, per-request-private memory layout.

**Effort:** ~1-2 months.

**Changes:**

- mmap snapshot read-only at process start; share across requests.
- Per-request: allocate small private bump arena (start at 64KB, grow
  geometrically as needed up to a per-handler ceiling).
- Pointer segregation enforced by build-time invariant: snapshot construction
  cannot produce pointers into per-request region (because the region
  doesn't exist yet).
- Reset between requests: drop the private arena.

**Wins:**

- Per-process memory drops dramatically. Concurrency density up 10×+ on
  small handlers.
- Snapshot is shared once across all in-flight requests; only the small
  private arenas multiply.
- Cold start drops further: no memcpy of the snapshot region per request,
  just allocate a fresh private arena.

### Phase 5: Determinism contract for rove-tape

**Goal:** Provable byte-equal replay.

**Effort:** ~1 month.

**Changes:**

- Audit all sources of nondeterminism (allocator order, hash iteration,
  random sources, environment access).
- Document determinism contract.
- Update rove-tape to use new contract; remove nondeterminism-handling
  code.
- Add a CI check: replay random handler/input pairs from production traces;
  compare arena bytes; fail on divergence.

**Wins:**

- rove-tape simpler, stronger trust model.
- Replay verification reduces to memcmp.
- Foundation for time-travel debugging (Phase 6).

### Phase 6 (optional): Record-replay debugging

**Goal:** Treat each request as a scrubbable timeline. Step forward and
backward, branch into hypothetical executions, diff two requests against
each other.

**Effort:** ~1-2 months.

**Why it works in this VM:** the arena is the entire mutable state of a
request, so "state at this point" is contiguous bytes. Combined with
Phase 5's determinism contract, the entire execution is a pure function
of (snapshot, inputs, host-call results) — all of which rove-tape already
records. **Frames are derivable, not stored.** They're generated locally
on the developer's machine when a debug session opens, by replaying the
recorded execution and sampling the arena at requested frame points.

**Snapshots are also derivable, not shipped.** The debug path is
latency-tolerant — a developer opening a trace can wait a few seconds
for the local machine to rebuild a fresh snapshot from the handler's
source. So production never has to serialize snapshot bytes, never has
to design the snapshot encoding for cross-process portability, and the
runtime is free to use whatever pointer encoding is fastest (absolute
pointers within an in-process region work fine; no MAP_FIXED, no
relative-pointer overhead in the hot path). The debug payload that
flows from production to a developer is just `(handler-source-ref,
inputs, host-call-results)` — already what rove-tape records.

**Server-side storage stays at rove-tape sizes** (KB per request, not MB).
You don't pay for frames you never view; you don't have to encrypt or
retention-policy intermediate state; sharing a trace is a few-KB payload.

**Changes:**

- Local debug client: pull (handler source ref, inputs, host-call
  results); rebuild a fresh snapshot from source locally; replay against
  that snapshot with recorded results substituted for real I/O; sample
  the arena at requested frame points.
- Two-pass rendering for responsive scrubbing: coarse pass first
  (function-entry frames only) for the overview timeline; on-demand
  re-replay at higher fidelity for the segment the developer is currently
  inspecting. Same pattern as seek-in-video: cheap overview, expensive
  detail only where you're looking.
- DAP integration so VS Code / Chrome DevTools can drive scrubbing,
  branching, breakpoint search, and differential execution.

**Capabilities unlocked:**

- **Timeline scrubbing.** Drag through the request like a video; variable
  values update live in the inspector as you move the cursor.
- **Find-first-occurrence.** "When did `user.email` first become null?"
  Binary-search frames against a predicate. Impossible in any production
  debugger today.
- **Branching execution.** Scrub to a frame, mutate a value in the
  debugger, run forward. You're now in a hypothetical timeline; the
  original frames are still there. First-class "what if?" debugging.
- **Differential execution.** Run two requests with slightly different
  inputs against the same handler. Compare arena bytes at corresponding
  frames. Highlight exactly where execution diverges. The serverless
  equivalent of `git diff` for running code.
- **Post-mortem replay.** Customer hits a bug in production. Bundle the
  input + recorded frames + snapshot pointer; ship to a developer. They
  scrub through the failed request locally without reproducing it.

**Wins:**

- A genuinely differentiating product feature. No other serverless
  platform has anything like this. Most serverless debugging today is
  printf-and-pray; this is record-replay-and-scrub.
- Falls out cheaply once Phases 1-5 are in place. The hard part is
  building the arena VM; the recording mechanism on top is days of work.

### Phase 7 (optional): Persistent property maps

**Goal:** Better scaling for objects with many properties.

**Effort:** ~1-2 months.

**Changes:**

- HAMT (hash array mapped trie) for objects above a threshold (e.g., 16
  properties). Below threshold, keep flat array.
- Tradeoff: O(log n) lookup vs O(1) for flat, but full structural sharing
  for "modifications."

**Stop here if:** measured customer workloads don't stress
many-property objects. Most JS objects have few properties; this might
never pay off.

### Total

- Phases 1-5: ~6-9 months for one engineer at full focus.
- Phases 6-7: optional, ~2-4 additional months.

## Open questions

1. **Snapshot scope: per-handler, per-process, or layered?**
   Per-handler (snapshot includes handler bytecode + warmed ICs): snapshot
   is large but per-request work is tiny. Per-process (base engine + std
   lib only): smaller snapshots but per-request work includes loading the
   handler. Layered (base snapshot + per-handler delta): best of both.
   Probably layered, but the engineering complexity is real.
2. **Per-request memory budget.** Default? Configurable per-handler? How
   does it interact with handler timeout? What's the right error mode when
   exceeded — terminate the handler, or let it observe and gracefully
   reject?
3. **Bytecode format.** Likely diverges from QJS upstream by Phase 3 (IC slot
   layout, shape references). The compile pipeline produces a Loop46-
   specific artifact. Do we keep QJS's parser or fork that too?
4. **Async / generators.** These suspend execution mid-handler. Frame state
   needs to live across suspension. Fine in arena mode (frame state is just
   more arena), but complicates the "snapshot is fresh per request" mental
   model. Probably defer to v2; require pure-sync handlers initially.
5. **WeakRef / FinalizationRegistry.** No GC means no cleanup. WeakRef
   referents are never collected mid-request. Document as
   spec-divergence; reject handlers that depend on cleanup observation.
6. **Exception handling.** Allocations during exception flow live until
   end-of-request. Catching and continuing means error objects accumulate.
   Probably fine for short handlers; surface as part of the memory budget.
7. **Naming.** By Phase 5 the runtime is different enough from QJS that the
   name is misleading. New name? Probably yes; don't paint ourselves into
   defending "we run QuickJS" when we don't.
8. **Test262 strategy.** Run early and often. Document every divergence with
   a paragraph explaining why. The discipline of writing those paragraphs
   tends to expose accidental divergences.

## Risks

1. **Pathological customer code.** Some JS idioms work fine on V8/SpiderMonkey
   but might be hostile to this VM:
   - Long string-builder loops with intermediate accesses force repeated
     linearization.
   - Objects with thousands of properties added one-at-a-time hit
     geometric-growth memory ceilings.
   - Very long-running handlers exhaust the per-request arena.

   Mitigation: per-handler memory + time budgets, plus documentation of
   supported patterns. Most real Loop46-style handlers are short and
   well-behaved; the risk is mostly around edge cases.

2. **Spec compliance regressions.** QJS is well-conformant. Diverging the
   runtime risks subtle violations. Test262 after each phase, every commit
   ideally.

3. **Maintenance burden.** Once forked, we own everything: parser,
   bytecode compiler, interpreter, stdlib. Pulling fixes from upstream
   becomes manual. Real ongoing cost, probably 5-10% of one engineer
   indefinitely.

4. **Engineering opportunity cost.** 6-9 months of focused work is
   significant for a pre-launch product. The features that don't get built
   during that time are real. The arena VM has to be worth more than
   those features.

5. **The "elegance trap."** Phase 1 might be enough. Phases 2-5 are tempting
   because they're architecturally clean, but the customer-visible benefit
   may not justify the additional cost. Discipline to stop at "good enough"
   is important; each phase should require explicit justification.

## Triggers for committing

Don't pursue this unless one of the following has fired:

- **Concurrency density limit.** Production hardware can't hold enough
  in-flight requests because per-instance memory is the bottleneck.
- **Compute-heavy workload demand.** Customers running parsers, transforms,
  or other CPU-bound JS that's underserved by current QJS speed.
- **Debugger demand.** "I want to debug my handler" becomes a recurring
  customer ask. Phase 1-5 makes a real DAP integration tractable; Phase 6
  delivers it as a differentiator.
- **rove-tape determinism gaps.** Real divergences in production replay that
  trace back to runtime nondeterminism, not host-call recording bugs.
- **Strategic option value.** A decision to support non-JS source languages
  (WASM, typed-functional, etc.) where the runtime layer needs to be
  language-agnostic.

## Comparison to alternatives

| Path | Cold start | Throughput | Concurrency | Debugger | Effort |
|---|---|---|---|---|---|
| Current QJS-snapshot | 5-7μs | baseline | OK | thin | 0 |
| Selective fork (Phase 1) | 2-5μs est. | +20-40% est. | OK | thin | 2-3 mo |
| Full arena VM (Phases 1-5) | 1-3μs est. | +30-60% est. | 10× | foundation | 6-9 mo |
| Migrate to StarlingMonkey | 0.5-2ms est. | unclear | worse | excellent | 4-6 mo |
| Stay on current path | 5-7μs | baseline | OK | thin | 0 |

All performance numbers in the middle three rows are estimates; the prototype
work is what would replace them with measurements.

## Recommendation

Wait. The current path is genuinely good — better than anything in the WASM
ecosystem, sufficient for the workloads we expect, and the costs aren't
constraining the product yet. Pre-launch, the engineering opportunity cost of
a 6-9 month runtime project is high.

When triggers fire, start with Phase 1. It's a contained ~2-3 month project
with measurable wins and a clean stopping point. If the post-Phase-1 metrics
justify going further, Phase 2 onward unlocks the more architectural
benefits.

The full plan exists so that when we're ready to commit, we don't relitigate
the design from scratch. Treat it as a deferred branch in the roadmap, not a
roadmap item.
