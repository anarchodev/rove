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

**End to end** — the rove-io echo server runs on both models
(`echo-server` / `echo-server-fat`, same wiring, one option line apart)
and a side-by-side bench (ReleaseFast, 8 client threads, 512B verified
echoes, reps alternating variants) lands where the microbench said it
would: connection churn at parity (~15.8k conns/s both — connect/accept/
shutdown/close syscalls dominate, the ECS layer is invisible), and
persistent round-trips at parity (medians within ~1% across a 10-rep
alternating run, 5 wins each; an earlier 4% fat edge did not reproduce).
Zero payload errors either side across ~10^6 round-trips and ~5x10^5
churned connections. Absolute rates are box-load-dependent; only the
within-run comparison is meaningful.

**The conclusion the measurements support:** at rove's scale — thousands
of entities, components kept small because kernel-visible and large data
live behind pointers anyway — *move cost was never the binding
constraint*. An operation's ECS traffic is ~100ns inside even the
thinnest 7µs echo request; iteration density is the term that actually
scales, and both models share it. The row-subset discipline priced
itself as speed (keep rows tight so moves stay cheap) but was actually
buying safety (don't silently lose data). With safety provided
structurally instead, transitions are free to spend on clarity: as many
phases, seams, and per-resource close collections as the state machine
wants — each hop costs ~10ns, and each buys a place where a system with
a full view owns one step. The regime where this reverses is the one
rove is not in: per-tick moves over game-engine-scale populations, or
large inline components.

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
  The knob already has an API surface: `Io`'s `connection_row` stops
  meaning "required, or your data doesn't exist" and comes to mean
  "materialize my component in io's views, I iterate it" — per-entity
  access needs only universe membership. (Gap: the prototype derives the
  universe from rows, so a row-less component has no shadow column yet;
  an `extra_components` option is the missing "in the world,
  materialized nowhere.")
- **Residency assumptions, censused against io.** Of the three resolver
  hooks the archetype model forced on io, universal reads dissolve two
  (`fd_resolver`, `peer_resolver` — completions name entities by id and
  `getFat` answers wherever the conn lives, so an upper layer may hold
  conn entities in its own collections). What survives as contract: io's
  admission count and shutdown sweep see only io's own collections — a
  membership *aggregate*, which per-entity reads cannot dissolve and a
  shared reference-set view would. The teardown seam itself gets more
  permissive: ending a conn is one total move into `conn_closing` from
  any collection at all.
- **Views are still a partition — in the prototype.** The designed
  generalization is membership axes with edge clauses (next section):
  multiple simultaneous memberships made safe by construction.
- **What the archetype still holds:** "left the collection" is structural
  destruction there. Under fat it is a contract kept by releasing systems.
  Whether any component *wants* enforced destruction on exit is a
  per-component question this model answers with convention.

## Membership axes and edge clauses (sets built; axes and clauses unbuilt)

**The safety condition for multiple membership** falls out of the model's
one invariant: each component has exactly one live home. Two memberships
may coexist iff their *materialized* rows are disjoint — then no component
is contested, and reads/writes stay coherent with zero copies. Overlap is
fine when only one membership materializes the shared component (the
others read through), and a deliberately stale materialized copy is
legitimate only as *declared snapshot semantics* with a named refresh
point (double buffering). "Only one is writable" is not a safety
condition by itself: an unrefreshed read-only copy is a silent fork.

**The axis partition makes disjointness structural.** Assign every
component to an axis; a collection materializes only its own axis's
components. Then an entity holds one membership *per axis* — a product
state: a definite position in each of several independent state machines
— and cross-axis co-residency is safe by construction, no pairwise row
checking. Exclusivity within an axis is maintained by the operation
itself: changing axis-k membership IS the move on axis k. Mechanics:
`collection_ids` grows from one byte to one per axis; per-membership
offsets live in per-collection sparse indexes (the sparse-set layout);
destroy leaves every axis. The phase/seam/home trichotomy collapses into
axis shapes — a phase is a many-state axis, a seam a two-state axis (in
the mailbox or not), a home a one-state axis — and the empty-row set
(pure membership, zero components) is unconditionally safe to overlap
with anything. This also completes rove-library principle #1: flags like
`close_requested` exist today because the single membership slot is
occupied by lifecycle; with axes, "never a flag, always a collection"
becomes fully honorable.

**Edge clauses replace whole-graph analysis.** There is no global
comptime pass over the transition graph, and none is needed: safety is
inductive if every edge either statically preserves the invariants or
carries a declared, runtime-checked clause. Two clause flavors, in
preference order:

- `leaves = .{...}` — the edge *performs* the repair (moving lifecycle
  into `conn_closing` atomically leaves `ws_send_in`). No failure path.
  Prefer this: edges do work, the same philosophy as release-by-transition.
- `asserts = .{...}` — the edge *detects* a can't-happen (the entity
  being in the conflicting state would mean an upstream bug). The check
  is a framework primitive compiling to explicit check-and-abort in every
  build mode — a violated co-residency precondition is an infallibility
  violation (two live copies = corruption), and the shipped build strips
  `std.debug.assert`, so the loudness cannot be left to the caller.

Cross-axis constraints — which product states are legal — are the real
design surface the partition opens ("entanglement": axes that may not
move independently). They are expressed as clauses on the edges that
could violate them, so residual risk is *enumerable*: every edge is
statically discharged, self-repairing, or carries a named assert, and
the assert list is greppable the way `unsafe` blocks are — except these
stay checked at runtime.

**Worked example — `all_conns` retires `extra_conns_fn` (BUILT).**
`EntitySet` is implemented: dense list + sparse index, declared bit ids,
membership orthogonal to the entity's collection, and destroy draining a
per-entity mask so a set can never hold a dead entity — the "leaves on
the terminal edge" clause exists today as destroy-leaves-all, pending
real edge clauses. io (fat model) declares `all_conns`, joins it on the
accept and connect-promotion edges, and admission control reads
`all_conns.count` — O(1), exact, regardless of which layer or collection
holds any conn — so `extra_conns_fn` is void under fat and its setter a
compile error. Verified by the churn probe: 500 sequential connections
against a ~224-conn admission budget stalls within the first 256 if a
member ever leaks.

Still unbuilt from the example: sweeping `all_conns` at shutdown (ending
conns held in foreign collections needs the type-erased *evict* recipe —
park the row, remove from the collection — symmetric with the existing
destroy recipe). Until then the shutdown sweep keeps its
close-your-own-first contract; the admission contract is gone.

## Prior art

The pieces all exist; the package as a *semantic contract* is the
less-traveled part.

- **Handmade Hero sim regions** (Muratori): entities live chunk-resident in
  packed low-frequency form and are unpacked into the sim region's dense
  working collections (static / moving geometry) when near the camera, then
  packed back out. Park/unpark with a *spatial* predicate where ours is
  *state*. His pack step must swizzle entity pointers to stored IDs and
  back; rove's `Entity` handles are already the stable reference, so park
  is bitwise.
- **EnTT sparse sets + owning groups**: per-component sparse sets are the
  base table; an owning group incrementally reorders its pools so members
  sit contiguous — a materialized view maintained by swaps, down to the
  same partition-ish constraint (a pool owned by at most one group). No
  declared state graph, no park (nothing ever leaves the base table).
- **Archetype engines patching toward the same end** — evidence the pain is
  recognized: Unity DOTS enableable components (a state flip masks a
  component instead of causing a structural move; storage stays allocated)
  and flecs union relationships (state changes that do not move the entity
  between tables). Both keep membership as a filtered scan rather than a
  dense set, and neither makes lossless moves a guarantee.
- **Databases**: materialized views + incremental view maintenance is the
  literature this doc's framing borrows. Vertica/C-store is the sharpest
  match — base store plus differently-organized materialized projections,
  with a *tuple mover* migrating records between write- and read-optimized
  homes. SAP HANA's delta/main split is the same shape; a Postgres partial
  index is a membership predicate, materialized.
- **DOD canon**: Fabian's existence-based processing (membership in a table
  IS the boolean) is the ancestry of rove-library principle #1 itself;
  hot/cold structure splitting is what this model does *dynamically per
  state* — the view is the hot split, the shadow the cold one, and the
  split point moves with the entity's phase. Kelley's "Practical
  Data-Oriented Design" is the Zig-world statement of
  state-as-array-membership.
- **Structural analogies** that are more than cute: register allocation
  (columns are registers, the shadow the stack slot, park/unpark are
  spill/fill, "safe to read" is live-range analysis) and virtual memory
  (resident vs paged-out over one canonical backing store) — both live
  under the same one-live-copy discipline.

## What would come next (none of it committed)

The h2-shaped composite-tick benchmark (does the bookkeeping show at h2's
real op mix); seam views as reference sets; a port experiment of one small
consumer. The V1-style question — should rove *become* this — is a
separate decision this doc deliberately does not argue.
