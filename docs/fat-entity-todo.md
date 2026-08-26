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
fat-bench (parity at every altitude measured).

## 1 — Universe composition (blocks the h2 port)

- [ ] A way for a stacking layer to widen the universe: either an
      `extra_components: Row` option threading up from the top, or the
      app computes the union and hands the `Reg` type into each layer.
      Mirrors what coll-enum already does for the id namespace with
      `opts.extra_collections`.
- [ ] "In the world, materialized nowhere": a component in no row
      currently has no shadow field. Same mechanism as above — the
      universe must be declarable beyond the union of rows.

## 2 — The h2 port (the real consumer test)

- [ ] Genericize rove-h2 over the registry model the way io went.
      Expected mostly mechanical after item 1; the `conn_closing`
      two-type `getAny` seam dissolves under fat (rows never diverge).
- [ ] The h2-side call sites that want `getRow` (close/dispatch paths
      reading several components of a stream).
- [ ] **Smoke suite** (`scripts/smoke/run_all.py --baseline`) — owed
      since the coll-enum merge regardless, mandatory before any of this
      approaches main. `zig build test` cannot see socket lifecycle.

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
      partial axis with zero components; whether sets keep the bitmask
      implementation is an implementation choice, not semantic.
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
