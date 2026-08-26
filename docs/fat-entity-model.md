# The fat-entity model

**Status: design exploration on the `fat-entity` branch.** The prototype is
`FatRegistry` (`src/rove/fat.zig`), living beside `Registry` on the same
`Collection` machinery; the measurements are `zig build fat-bench`
(`src/rove/fat_bench.zig`). Nothing here is a decision, and the branch's
merged coll-enum work has not been through the smoke suite. This doc is the
design record so the argument survives the conversation that produced it.

## Thesis

**The simplicity of the fat-structs model with the performance of the
archetype model.** Every entity conceptually carries every component — the
fat struct every systems programmer already knows how to reason about — and
collections become materialized views over those records: the dense,
type-gated iteration sets that are the reason an ECS exists.

## The model

One sentence per piece:

- **Base table.** The shadow store: one column per component in a
  comptime-closed `Universe`, `max_entities` long, addressed by
  `entity.index` — the same never-compacted shape as the registry's own
  metadata arrays, so a parked component's address is stable for the
  entity's lifetime. Conceptually this *is* the fat-struct array, stored
  SoA.
- **Materialized views.** A collection is a membership predicate (the
  state) plus a column projection (the row), physically maintained: moving
  an entity copies shared columns view-to-view, *parks* dropped columns in
  the base table, *unparks* gained ones. Move copies are incremental view
  maintenance, nothing more.
- **Total moves.** Any collection to any collection, no row-subset
  requirement, lossless by construction. A component's value is
  path-independent: always the last value a system wrote, never a function
  of the route the entity took through the collection graph.
- **One defaulting point.** Birth writes declared field defaults
  (`row.fillDefault`); per-slot generation stamps make a virgin or reborn
  slot read as the default lazily, so birth and death are O(row), not
  O(universe), and a reborn index can never resurrect its predecessor's
  values.
- **No lifecycle hooks.** Moves and destroys run no component init/deinit.
  Release is a transition owned by a system (rove-style §16); the releasing
  system writes the component back to its default as part of the release it
  already owns.
- **Universal reads.** `getFat(entity, T)` resolves a component wherever it
  lives — the owning view's column when resident, the base table when
  parked — with no candidate set at the call site.

"Safe to read" — the row — stops being a storage fact and becomes the
view's contract: the type system still stops a system from naming a
component its view lacks, but existence is no longer state-dependent.

## Why the simplicity is real

The fat struct is the model everyone already has: create the record, fields
persist, tear down with the whole record in hand. Archetype ECS deviates
from that intuition — fields appear and vanish with state — and the
deviation is where rewind's resource-ordering bugs lived. The fat model
restores the intuition and keeps what the ECS machinery is actually good
for: state as membership that cannot disagree with itself, and read-safety
as a typed property of a system's signature instead of a comment.

The sharpest consequence is the resource story. A layer creates an `Fd` on
an entity; the component rides the base table through every state any layer
invents — there is no operation that strips it — and the owner's
close-collection system, a real system with phase ordering and a full view,
is *guaranteed* to see it again. "The creating layer destroys" (§17)
upgrades from a discipline every path had to respect into a property the
framework enforces, and the failure mode flips from silent (a component
stripped en route is a leak with no trace) to visible (an entity stuck
short of teardown is countable membership). Two residuals stay honest:
something must still route the entity into the teardown chain — the
decide/execute split remains a protocol — and value-invalidation (writing
`fd = -1` after close) is the releasing system's contract, checked by
nothing.

Composition inverts from thread-down to gather-up. Libraries stop being
generic over user rows: your components survive passage through another
layer's states without that layer's cooperation, any layer can attach
components to any entity unilaterally, and views can span layers. The
row-fragment threading of principle #9, the superset rule's row pollution,
and the resolver hooks of rove#877 all dissolve rather than get patched.

## Why the performance holds (measured)

`fat-bench`, ReleaseFast, one quiet box, min-of-5 — parity or better
everywhere except one knowable premium:

| scenario | archetype | fat |
|---|---|---|
| phase move (identical 40B rows), batch / immediate | 5.9 / 8.8 ns | 5.8 / 9.1 ns |
| detour with survival, batch / immediate | 9.7 / 12.7 ns (carry-all) | 10.3 / 12.6 ns (park/unpark) |
| detour, lossy `moveStrip` (values destroyed) | 11.4 ns | — |
| resident churn, K=4096 / K=16384 | 12.1 / 12.0 ns | 13.8 / 11.7 ns |
| iterate a column | 0.3 ns | 0.3 ns |
| resolve unknown home (11 same-row colls) | 1.6 ns id-index, 2.1–3.5 ns getAny scan | 2.9 ns getFat |
| close from unknown home | ~62 ns any dispatch | ~62 ns |

Findings that matter more than any single number:

- **Survival is nearly free.** The archetype's cheapest detour — destroying
  the values — saves about a nanosecond over the fat model's lossless one.
- **SoA insulates both models from row width.** Untouched columns never
  enter cache, so the "carry-all footprint tax" mostly does not exist
  mechanically; carry-all's real cost is semantic (every intermediate row
  must name every surviving component).
- **Dispatch does not matter for moves** (~62 ns is the deferred-move
  machinery itself) **and barely matters for reads** (everything ≤ 3.5 ns).
  The coll-enum declared-id index is the fastest resolver; `getFat` pays
  ~1.4 ns for its fn-pointer generality.
- Microbench caveats: hot cache, one machine, and the ECS layer is
  nanoseconds under a request path dominated by nghttp2/TLS/syscalls.
  These numbers bound relative overhead; they predict no throughput.

## Relationship to coll-enum

The declared-collection-id work (merged into this branch) composes with the
fat model rather than competing: it supplies the readable namespace —
membership as an enum value, typed recovery through an exhaustive switch —
and the fat model is a storage rule on top of it. `FatRegistry` registers
under declared ids with the same guards as `Registry`; `collectionIdOf` is
the readable-membership primitive, and typed recovery lives in the layer
that declares the enum, where it is checked. Notably, coll-enum alone
already wins the unknown-home resolve case on archetype storage; what it
cannot do — span row-divergent candidates, resolve without any candidate
knowledge — is exactly what the fat model adds, because under fat, rows
never diverge.

## Costs and open questions

- **Memory:** union-of-universe × `max_entities`, mostly cold; plus 4 bytes
  per (component, entity) of stamps. Charged even for components three
  entities ever hold.
- **Closed world:** the component universe must be known at one comptime
  point. Composition becomes gather-up (each layer exports components +
  collections; the app unions them) — the same direction coll-enum's
  namespace already took, and the registry declaration doubles as a
  manifest of all entity state.
- **The subset check's successor.** The comptime row-subset rule also
  forced you to notice when a destination expected a component nobody had
  written. Total moves delete the check; whether "the sender wrote what the
  receiving view trusts" stays convention or gains a checkable handoff is
  the one unreplaced safety.
- **Materialize vs read-through is a per-(view, column) knob.** A column
  iterated every tick wants materialization; one read once per entity could
  read through to the base table (the §2 fixed-pool exemption, reappearing
  as "don't materialize this column"). Kernel-visible components should be
  base-table-only: intermittent address stability is worse than none.
- **Views are still a partition.** An entity is in exactly one collection;
  seams-as-reference-sets (membership without data implications, possibly
  overlapping) is the natural generalization the model makes expressible
  but the prototype does not implement.
- **What the archetype still holds:** "left the collection" is structural
  destruction there. Under fat it is a contract kept by releasing systems.
  Whether any component *wants* enforced destruction on exit is a
  per-component question this model answers with convention.

## What would come next (none of it committed)

The h2-shaped composite-tick benchmark (does the bookkeeping show at h2's
real op mix); seam views as reference sets; a port experiment of one small
consumer. The V1-style question — should rove *become* this — is a
separate decision this doc deliberately does not argue.
