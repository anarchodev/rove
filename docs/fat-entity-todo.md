# fat-entity branch — task ledger

Working state for the `fat-entity` branch. The design record and the
arguments live in [`fat-entity-model.md`](fat-entity-model.md); this file
is only what remains to do, roughly in dependency order. If the direction
is adopted, in-flight items graduate to GitHub issues and durable residue
into `docs/architecture/` + `decisions.md` per the repo's normal process —
this file then dissolves.

## Shipped on this branch (orientation only)

FatRegistry (shadow now AoS with per-entity `{gen, written}` header) ·
total/lossless moves · `getFat` · `getRow`/RowView · declared collection
ids (coll-enum merged) · `collectionIdOf` · `EntitySet` + per-entity mask ·
`evictImmediate` · Io generic over registry model · echo server on fat
(probe-verified) · zero hooks and zero residency contracts in fat io ·
`all_conns` admission + sweep · empty-queue precondition on the sweep ·
fat-bench (parity at every altitude measured) · getAny/moveAny compat ·
extra_components threading (io + h2) · conn_dead hand-off phase +
reaper · **rove-h2 ported** (h2-echo-fat probe-verified).

## 1 — Universe composition — BUILT 2026-08-26 (as the threading mechanism)

"Top" is a role, not a layer: whoever terminates the stack in a given
program (echo example → io directly; h2-echo example → h2; the rewind
worker → h2 + its own collections — the case `extra_collections`
already exists for). The design must work when top is two layers above
io with components io has never heard of.

- [x] **`extra_components: Row` at every layer boundary, folded
      downward.** Each layer merges its own non-row components plus its
      caller's extras into what it passes the layer below; io (bottom)
      computes `universe = own_rows ∪ extras` and defines `Reg`; each
      layer re-exports `pub const Reg = Below.Reg`. Exactly parallel to
      `extra_collections` for the id namespace — one aggregate per
      boundary, threaded down.
      - Division of labor: the BOTTOM defines the type, MIDDLES fold
        and forward, the TOP contributes, constructs the registry
        value (`Reg.init`), and registers its own collections against
        it. Row options stay the materialization requests ("in your
        views"); extra_components is existence ("in the world").
- [x] **No ordering fragility, unlike the id enum.** Row unions are
      canonical (sorted, deduplicated), so the same component set gives
      the identical type regardless of merge order or which layer
      computes it — no prefix assertion needed; a mismatched union is a
      pointer-coercion error at the seam, a missing component is the
      coverage error at the offender's own registerCollection, both at
      compile time.
- [x] **Gap B, same mechanism:** "in the world, materialized nowhere" —
      a component in no row gets its shadow field via extra_components
      alone; the materialization knob's zero position.
- [x] Built FLAT. The declared-world interface (components +
      collections tables, table-position ids, registry-owned storage)
      remains the intended successor; the threading is its sanctioned
      fallback and is subsumed by it.
- [ ] **DECIDED (2026-08-26): the `rove_world` root pattern is the
      intended endpoint** — the std_options idiom: each binary's root
      module declares `pub const rove_world = rove.World(.{ .parts =
      ... })` once; rove exposes `declared_world` via @import("root")
      with null fallback; layers consult it instead of threading.
      Rules that make it sound: (1) the root declares TYPES, main and
      each worker thread construct VALUES — one world type per program,
      N registries of it (prod's 8 shared-nothing workers are 8 values
      of one type; a registry VALUE at root scope is forbidden and
      corrupting); (2) `.registry_model = .fat` stays on
      instantiations as intent, and fat-without-a-root-world is a
      compile error — no silent mode flip; (3) parts must be pure data
      declared outside the layer type functions (no value recursion
      through @import("root")); (4) library test builds see no world
      (their root is the library file) and default archetype; explicit
      World(...) construction remains load-bearing underneath — tests'
      mini-worlds and any heterogeneous-worlds binary use it directly;
      (5) heterogeneous worlds in one binary are out of scope by
      construction (rove ships separate binaries). Lands naturally
      WITH the declared-world tables, since those make parts pure data
      anyway.; when axes (item 4) land,
      the contribution becomes per-axis and the re-grouping is
      mechanical. Do not block the h2 port on axes.

## 2 — The h2 port (the real consumer test)

- [x] Genericize rove-h2 over the registry model — DONE (2026-08-26).
      extra_components threading built at both boundaries (item 1's
      fallback mechanism; the declared-world interface still supersedes
      it later); Reg re-exported; hooks not installed under fat. Two
      foreign-state problems surfaced and solved: (a) Conn.deinit's
      work (nghttp2/TLS/h1) moved to the `conn_dead` hand-off phase —
      io retires by move under `on_retire = .hand_off`, h2's
      pollPostlude reaps (free via getFat, then destroy), teardown
      reaps conn_dead AND still-closing; (b) the four buffer-owning
      stream components route every ending through `destroyEntity`
      (frees-then-destroys under fat; safe on any entity via
      null-defaults). Probe-verified: churn/multiplex/concurrency,
      byte-exact, archetype control identical.
- [ ] Convert the four stream components (Req/Resp Headers/Body) to
      release-by-transition or per-request arena — h2's analog of
      rove#885. Retires destroyEntity's fat branch and the consumer
      contract ("end terminal entities through destroyEntity").
- [ ] The h2-side call sites that want `getRow` (close/dispatch paths
      reading several components of a stream) — currently on compat
      getAny/moveAny, which FatRegistry now provides.
- [ ] **Smoke suite** (`scripts/smoke/run_all.py --baseline`) — owed
      since the coll-enum merge regardless, mandatory before any of this
      approaches main. `zig build test` cannot see socket lifecycle.
      NOTE: the worker still runs archetype — the suite exercises the
      port only via unit gates until the worker opts in.

## 3 — Edge clauses

- [ ] `leaves = .{...}` on moves/evicts: the edge performs membership
      repair atomically. Prefer over asserts (edges do work).
- [ ] `asserts = .{...}`: framework-owned explicit check-and-abort that
      survives ReleaseFast. This is also where the lost `Fd.deinit`
      bypass-abort class returns — declared preconditions on edges
      instead of destructor-time detection.
- [ ] Constraint: evict edges can carry only destination-dependent
      clauses (source is runtime-resolved); source-dependent ones
      degrade to runtime asserts. Write this down in the clause design.
- [ ] The checkable-handoff successor to the row-subset rule; a debug
      `getRow` variant asserting requested members were written this
      generation (the header mask already answers it).

## 4 — Membership axes

Ship each step alone: (a) is pure annotation, (b) must be bit-identical
for the single-axis case, (c) delivers the first real second axis, (d)
comes last so only the constraints that survive 4a–4c get syntax.

- [ ] **4a. Partition.** `rove.Axes(.{ .lifecycle = Row(...), .throttle
      = Row(...), ... })` — every component in exactly ONE axis (compile
      error otherwise); every collection declares `.axis` with row ⊆
      axis row checked at registration; universe = union of axis rows;
      the shadow struct is axis-blind and unchanged. Co-residency safe
      by construction — the disjointness condition becomes a property of
      the type system, no pairwise or runtime checks. Why a
      data-carrying axis at all: a system gets DENSE iteration over an
      orthogonal concern's state (a `throttled` collection whose refill
      system iterates only limited conns) — a set can't (no columns), a
      flag can't (scan everything), the single membership can't (slot
      taken by lifecycle). `close_requested`, the style guide's
      confessed flag-exception, exists because the slot was occupied.
- [ ] **4a-identity. Axes are declared VALUES with owners, not merged
      names.** String-matched axis names invite accidental capture: two
      layers independently inventing `.pending` for unrelated concerns
      get silently fused into one axis, imposing exclusivity between
      states that have nothing to do with each other — valid
      declarations, no error. So: a part EXPORTS the axes it owns
      (`pub const throttle_axis = ...`), layers above reference the
      decl (`.axis = rio.throttle_axis`) — unforgeable, typo-proof,
      private by default, shared only by explicit import; the world
      merges by identity. The total axis is rove's own (`rove.
      lifecycle`, the default when `.axis` is omitted) because
      liveness is the registry's concept. Layering is reference-DOWN
      only: upper layers contribute collections into axes lower layers
      export; io cannot see h2's. Cross-layer shared axes are not new
      capability — today's single membership byte IS an unnamed
      lifecycle axis spanning io and h2 (conn adoption is a move
      because of cross-layer exclusivity on it); naming makes the
      sharing addressable. Interface rule per co-residency: overlap
      freely WITHIN an axis (state alternation — the whole h2 chain),
      never across axes (contested storage); the checker's error names
      the component and both sites. Not axis-representable (conflict
      graphs that are not disjoint unions of cliques, e.g. two
      overlapping tilings / K2,2): rejected at declaration — remodel
      by flattening cliques, splitting meanings into distinct
      components with declared sync, or (someday, with cause) a mode
      byte selecting the active partition.
- [ ] **4b. Mechanics.** Membership record becomes one `(id, offset)`
      pair PER AXIS — per-axis arrays, not per-collection sparse tables,
      because membership within an axis is exclusive (sets needed
      per-set tables only because sets are not mutually exclusive; they
      rehearsed the mechanism and axes skip its expensive half). Keep
      the id namespace global 0..255 so coll_ptrs / column_fns /
      destroy+evict recipes are unchanged. move comptime-checks
      src.axis == dst.axis; getFat computes axisOf(T) at comptime, same
      instruction count; evict infers the axis from dst; destroy exits
      every axis (K id bytes, K small); create births onto dst's axis.
      Cost: 5 bytes per entity per axis.
- [ ] **4c. Total vs partial.** Exactly ONE total axis (lifecycle):
      position always exists, 0 = free pool, birth requires it, no
      leave, evict's reserve-first no-limbo discipline applies. All
      other axes partial: 0 = "not on this axis" (legal — liveness is
      the total axis's and the generations' job). Partial axes gain
      `enter` (Gained-path with no source) and `leave` (Dropped-path
      with no destination — PARKS, nothing destroyed). Freshness sharp
      edge: re-enter restores parked values (path-independence); the
      system deciding `leave` owns resetting first if policy wants a
      fresh start — same contract as `fd = -1` at close. A set is a
      partial axis with zero components — and at this step the
      implementations MERGE (no half-refactor): EntitySet is deleted;
      sets become Collection(empty row) on one-state axes (the shared
      recipes' component loops vanish at comptime for an empty row);
      the set's sparse table moves into the per-axis offsets where it
      always belonged; the membership mask is deleted too (its drain
      win is moot when destroy walks K axis bytes anyway) and may
      return as a private compression only if dozens of tag axes ever
      exist. What stays distinct is verb availability derived from
      axis shape: total = create/move/evict, no leave; multi-state
      partial = enter/move/leave; one-state partial = enter/leave.
- [ ] **4d. Cross-axis constraints ("entanglement") — the real design
      work.** Two attachment points: edge-attached clauses (precise,
      but every call site must repeat them — forgettable) vs
      STATE-ATTACHED declarations on the collection (`on_enter_leaves =
      .{ .throttle }`, `excludes = ...`) enforced on every entry however
      reached — cannot be bypassed, and being destination-properties
      they are exactly what an erased-source evict can honor. Lean
      state-attached as default, edge-attached as override. Standing
      example: "no send work once lifecycle ∈ conn_closing", today a
      runtime skip-check in processWriteIn. Asserts remain for genuine
      can't-happens — framework-owned check-and-abort surviving
      ReleaseFast — which is where the lost Fd bypass-abort class
      returns, firing at the transition where the story is tellable
      rather than at destruction where it is archaeology.

## 5 — Deferred + batch evict

- [ ] Count-N evict recipe (the generalization `moveRecipe` already has).
- [ ] Deferred evict: coherent because PENDING_MOVE freezes the entity;
      needs the source id/recipe threaded through the op.
- [ ] Batch evict: sort the worklist (counting pass on the id byte,
      offsets within), runs form at enqueue via RLE; all-members sets
      yield complete contiguous runs (K entities, M collections, M ops).
- [ ] The shadow bypass: components the source also materializes
      (null-check in the accessor table) copy column-to-column, one
      memcpy per component per run; only the row difference parks
      (scatter — unavoidable, the price of address stability). Needs a
      destination component-mask handed to the erased half.
- [ ] Rewire the fat sweep onto sorted batch evict once built.
- [ ] First deferred-evict consumer when it appears: the mid-tick idle
      reaper pattern (cannot prove immediate-safety, unlike teardown).

## 6 — Smaller items, any order

- [ ] Cold-working-set benchmark for the AoS shadow (the clustering win
      is claimed from mechanics, unmeasured — hot-cache bench shows
      parity only).
- [ ] Bench scenario B (h2-shaped composite tick) if the h2 port wants a
      number before committing.
- [ ] `EntitySet` dense-half capacity option for genuinely bounded sets
      (deliberately deferred: reintroduces the `Full` arm and a
      backpressure story; "join cannot fail" is worth real money).
- [ ] Consider root-level exports for `RowView`/`EntitySet` (currently
      via `rove.fat_mod`).
- [ ] Universe > 64 components: widen the header mask (compile error
      guards it today).

## 7 — Main-worthy independent of this branch (cherry-pick candidates)

- [ ] `moveAny` comptime quota fix (`584c4e19`) — any wide-row
      many-candidate call site on main hits it.
- [ ] Echo example modernization (`9de61f85`) — the example on main
      still destroys conns directly (aborts on first disconnect under
      the Fd guard) and leaks write buffers.

## Process, before merging anywhere

- [ ] Smoke suite green with baseline (see item 2).
- [ ] Decide the relationship to the parked `coll-enum` branch (this
      branch contains it; landing either implies sequencing).
- [ ] The actual adoption decision — "does rove become this" — is
      deliberately not argued in the model doc and needs its own
      conversation, with PLAN/decisions.md updates if yes.
