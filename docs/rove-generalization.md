# Rove generalization — exploration

> **Status:** Speculative thinking, not committed direction. This
> document captures a worked-out set of intuitions about a hypothetical
> programming language built around the kernel that rove embodies.
> Rove itself stays as it is — this is about a different, more
> ambitious project that the rove model points toward. Kept here so
> future-me doesn't have to re-derive any of it.

## 0. Framing

The kernel that rove embodies is **row-typed collections + identity**.
Everything else (recipes, deferred ops, lifecycle ctxs) is machinery
serving those two ideas. This document explores what falls out when
you push that kernel further than rove does — past the constraints of
"a Zig library used by an existing codebase" and into "a programming
language designed around the kernel from scratch."

The motivating insight is a position about object-orientation and
functional programming.

OO's load-bearing contribution was that **identity is real**. The
same `Connection` is meaningfully the same thing across its lifetime
even though every byte of its state changes. Pure FP loses that and
pays for it by either threading identity through values manually or
smuggling it back via mutable refs, state monads, actors. The need
keeps reappearing.

OO's mistake was binding identity to behavior, then using inheritance
to model both state-machine variation and capability variation
through the same mechanism. State-as-class
(`OpenConnection extends Connection`) requires upcasting/downcasting;
structural ceremony (visitor patterns, tag-and-switch, `instanceof`)
accumulates around the seam.

FP's mistake was the inverse — erasing identity to make values pure,
then having to add identity back as a second-class concept (Haskell's
`IORef`, Clojure's refs/atoms/agents, Erlang's PIDs). The need for
"the same thing across time" never goes away.

**The middle position:** values are values, identities are entity
handles, and they are *distinguished structurally*. Rove already does
this. A language built around the same kernel could go further — bake
the distinction into the type system, derive a coherent story for
mutability, effects, cross-references, lifecycle, and recovery from
the same small set of primitives.

The closest articulated prior art is Hickey's "values, identities,
time" essays for Clojure — the same separation, but expressed as a
discipline on top of an otherwise-conventional Lisp. Datomic takes
the database-shaped version. Erlang/OTP takes the actor-shaped
version. None of them have the comptime row algebra, none of them
treat collection-membership as state, none of them collapse the
machinery as far as the model below allows.

---

## 1. Identity-bearing types vs value types

"Class" in OO conflates two things — *value types* (`Point`,
`String`, `Duration`) and *identity types* (`User`, `Connection`,
`Order`). Value types are templates for content that's interchangeable.
Identity types are templates for things that have continuous existence
and are referred to from elsewhere. Class syntax doesn't distinguish
them; programmer discipline does.

In this language, the distinction is structural. **Identity-bearing
types' instances live in collections.** Value types stay as ordinary
data passed by value. Tests for whether a type is identity-bearing,
in roughly this order:

- Do other things hold references to instances of it?
- Does it have lifecycle resources to release?
- Does it have states it transitions between?
- Does it have invariants across instances ("no two users with this
  email")?
- Do you ever want to iterate "all of them"?

Any "yes" pulls toward identity. All "no" leaves it a value.

### Two value props of ECS, separated

The pattern usually gets sold on the **cache-friendly batch
processing** angle — Structure-of-Arrays columns, sequential
iteration, SIMD-friendly. There's a second, independent value prop:

**Structural lifetime management.** Auto init/deinit on entity moves,
no orphan bugs, state-as-collection-membership.

These are separable. Things accessed primarily by-key that don't
iterate-as-batch get pushed out of the system entirely in
performance-focused ECS frameworks — into hashmaps with manual
cleanup — losing the lifecycle benefits even though they'd benefit
hugely. The identity-bearing rule pulls them back in. The language
should make it as easy to put a hashmap-shaped thing into the
identity system as a column-iteration-shaped thing.

---

## 2. Mutability and effects

The cocktail, sketched as a coherent design point:

- **Affine entities.** Drop fires deinit; move consumes-and-produces.
  Aliasing prevented at compile time. Affine, not linear, because
  forcing every program to thread destroys explicitly is the
  Mercury/Clean problem and unfriendly.

- **Tracked handles.** Copyable, but the collection an entity
  currently inhabits is part of its type (or tracked statically).
  `Entity<InRequestOut>` vs `Entity<InResponseIn>`; a move changes
  the type. Heavy but real safety.

- **Exclusive collection borrows during a system.** Rust-style.
  Enables auto-parallelization across systems with disjoint
  read/write sets.

- **Mutable-in-system, pure-from-outside.** Koka-style effect
  tracking. A system body uses imperative mutation; from the
  language's view the system is
  `(read_set) → (write_set, deferred_ops, commands)`. Compiler
  verifies the system doesn't escape references, doesn't read
  collections it didn't declare, doesn't produce side effects
  outside its return value.

- **Commands for all external effects.** Elm-style. KV writes,
  webhook sends, log emits, file writes — none happen inside a
  system. They become values returned, applied by the runtime at
  flush.

- **Flush as the only place state actually transitions.** Between
  flushes, the world is frozen; inside a system, you see a
  consistent snapshot. The language-level analogue of rove's
  deferred ops queue.

The deepest property: **every system is a pure function of its read
set**, returning writes and commands. Replay determinism is
structural; time-travel debugging is a primitive operation, not a
special feature. Given the inputs and the command list, you can
rerun any system and get bit-identical output. The whole architecture
is what Loop46's purely-functional handler model already commits to,
lifted from "we hand-write pure handlers and the runtime helps" to
"the language enforces purity and the runtime gives you replay as a
guarantee."

This also recovers value-orientation without sacrificing identity.
Inside a system body, code looks normal — `coll.column(Position)[i]
.x += dx`. From outside, the system is a value transformation. The
imperative ergonomics are local; the pure semantics are global. Koka
proved this combination works.

---

## 3. Cross-references — the Erlang move

The problem: when an entity refers to another entity, what governs
the reference's lifetime?

### Rejected approaches

**Rust-style `Arc`.** What `Arc` is really doing is *retroactively
recovering identity in a value-oriented type system*. The underlying
data has identity (multiple owners refer to "the same" thing), but
Rust's type system only believes in values, so you wrap the value in
a refcounted box that imposes identity from outside. In a language
that already separates identity from values cleanly, Arc is a
workaround for a problem you don't have.

**SQL-style cascade annotations on schema.** Foreign keys with `ON
DELETE CASCADE / RESTRICT / SET NULL`. Too static — the relationship
topology is fixed at schema definition time and can't be rewired at
runtime. Too coarse — cascade behavior is per-column, and the only
reactions are delete/null/restrict. Conflates reference-as-data
(the foreign key) with cascade-as-policy (the action annotation).
Schema-style sugar might be useful as a desugaring target for the
static case, but it's not the right primitive.

### The Erlang-shaped answer

The move worth taking from Erlang/OTP: **the relationship itself is
an identity-bearing thing.** Links, monitors, and supervision trees
are explicit relationship objects with their own semantics, not
properties of either endpoint. Lifted to this language: relationships
are entities. They live in collections. They have lifecycle. They can
be created and removed dynamically.

The two Erlang primitives map naturally:

- **Link** = bidirectional lifetime coupling. Both endpoints share
  fate.
- **Monitor** = unidirectional observation. Watcher learns about the
  watched's failure but isn't killed.

Both are first-class entities; both can be created and destroyed at
runtime; supervisors are entities holding many of them and reacting
to failures via queued moves.

Reference-as-data and cascade-as-policy become **separate concerns.**
An entity holding another's handle is just a value reference — may
dangle, checked at lookup, returns `Option`. To get cascade behavior,
you additionally create a Link or Monitor. Decoupling reference-as-
data from cascade-as-policy is the Erlang insight; SQL conflates them
by making the foreign key both the reference and the cascade trigger.

---

## 4. Destruction is just a transition

The collapse that makes everything else click:

> An entity being destroyed can be seen as merely a transition into
> the null collection. There is no destruction of entities, only of
> components.

This dissolves an asymmetry. A separate `destroy` primitive alongside
`move` becomes one primitive: destruction is "move to the empty
collection, whose row has zero columns, so the move's strip list
happens to include every component the entity had."

Implications:

- **Components are where lifetime exists.** Init/deinit fire on
  component gain/loss. Resource acquisition/release is per-component,
  per-transition. Capabilities live on components.

- **Entities are just identity buckets.** They have no lifetime of
  their own. They group components and serve as observable subjects.

- **The empty collection is one valid destination among many.** Not
  a special "freed" state. Just a collection whose row is empty.
  Entities there have no components, no behavior, but they still ARE
  entities.

### The three-primitive kernel

After this collapse, the entire model is:

- **Move** — the only state-change operation. Every transition
  (creation, mutation, recovery, destruction) is a move between
  collections.
- **The empty collection** — one valid destination. Entities there
  have zero components and zero cost.
- **Observers** — entities watching `(entity, component)` pairs and
  queuing actions on transition events.

That's it. Supervisors, cascades, pinning, futures, capability
revocation, recovery policies — all compose from these. Three
primitives expressing what most languages spread across a dozen
orthogonal features. Usually a sign of a real local minimum in the
design space rather than a contingent point.

---

## 5. Observers — the unifying primitive

The Link/Monitor distinction collapses into one primitive once you
follow the destruction-as-transition insight. If only components
have lifetime, then "I care about something staying true" is
necessarily a claim about a component, not about an entity. The
natural primitive is an *observer*:

```
Observer {
  watches:  (Entity, ComponentTypeId),
  on_loss:  Action,
  on_gain:  Action,
}
```

No "endpoint pair." An observer is just an observation declaration.
A bidirectional Erlang-style link is two unidirectional observers.
A supervisor is an entity holding several observers and reacting via
queued moves. Pinning is an observer with an "abort the move" action
on `on_loss`. Cascade-delete is an observer with "move target to
empty collection" on `on_loss`. Capability revocation is an observer
watching the role-defining component leave. They're all the same
primitive with different actions.

Actions are themselves data — a sum type of "queue this move," "send
this command," "abort the triggering transition," "create a new
entity in collection X," etc. Reactions are queued by the
observer-processing system at flush; re-entrant flush handles
cascades naturally.

### What this enables

**Fine-grained cascade.** "If you lose this specific component, I
need to react." Much more precise than entity-level cascade —
relationships are usually about specific resources going away, not
about the whole entity disappearing.

**Component pinning.** External holders (a C library holding a
buffer pointer, another thread holding an entity reference) create
observers on the specific component they depend on, with `on_loss`
= abort. The entity can transition between any collections that
preserve the pinned component; transitions that would strip it are
rejected (or queued) until the pin releases.

**Futures-like waiting.** Inverse direction: "notify me when entity
X *gains* component Y." When the entity transitions into a
collection that includes Y, the waiter's `on_gain` fires. Async
work without an async runtime; it's just collection transitions and
observers.

**Capability semantics.** Components conceptualized as "the right
to do X." Holding an observer watching `(e, AdminToken)` means "tell
me if e loses admin." This is the E language / capability-security
model expressed in ECS terms. Capability revocation is just
component loss; capability grant is component gain.

### Cycles

Symmetric observer cycles (mutual fate — A and B both watch each
other with on_loss = react) form a cluster that lives or dies
together. Well-defined regardless of graph topology. The
observer-propagation system finds the connected component on any
member's transition and propagates uniformly. No topological sort
needed for symmetric cycles; only directional cascades need
ordering.

---

## 6. Roles, not entities

References never target raw entity identity. They target **roles**
— defined by component possession.
`(connection_entity, ConnectionRole)` means "this entity insofar as
it currently has the connection-defining component(s)." When the
role-defining component leaves (entity moves to a collection that
doesn't have it), the reference fires.

By the time an entity has transitioned through empty and possibly
into some other role, every observer of its previous role has
already fired and unsubscribed. **Slot reuse is invisible to
anything that mattered.** This is what makes permanent-identity
practical without needing to forbid reactivation.

### The Sam example

You might have a supervisor named Sam. If you need vacation
approval, what matters is that Sam *is* your supervisor. If Sam is
fired, or moves positions internally, your reference for
supervisory purposes becomes invalid. But Sam is still Sam.

Two coexisting references to (potentially) the same entity:

- **"Sam"** — `(sam_entity, PersonComponent)`. Long-lived. Fires
  only if Sam stops being a person.
- **"My supervisor"** — `(sam_entity, SupervisorOf<me>)`. Fires
  when Sam stops being your supervisor.

Both reference the same entity right now, but their lifetimes are
governed by entirely different conditions. In OO this is a mess
(one `Sam : Person` object with mutable role fields and no
compiler help). In FP it has to be threaded through every function
that reads a "supervisor" reference. In this model it falls out:
the reference *is* its scope, the scope *is* the role being
observed, the validity *is* the role's continued presence.

### Layered references

Real organizations naturally distinguish multiple levels that no
general-purpose language treats as separate primitives. Natural
language has separate words for each. A language built on this
model has a separate first-class thing for each:

- **Identity** — the person-as-such. Stable across all roles. An
  entity with a permanent component (`PersonComponent` or similar
  marker) that's in every collection that entity can inhabit.
- **Role** — what they're playing right now. Replaceable. A
  component (or set) that defines the current role.
- **Position** — the slot in the org chart. Stable across
  occupants. Its own entity, with a reference to the current
  occupant entity.
- **Capability** — the access granted by the role. Derived from
  role. A component on the same entity, granted by the role's
  collection's row, lost when the role transitions away.

Role-based access control falls out for free. When Sam loses the
supervisor role, the access components leave with the role
transition. No bolt-on RBAC layer; no de-permissioning machinery;
the structural model handles it. This is what RBAC is *trying* to
be in every enterprise system, and what every enterprise system
gets wrong by bolting it onto an OO model that conflates identity
with role.

The slot pattern is worth its own mention because it appears
everywhere once you start looking. "The supervisor of the platform
team" is a position-entity with stable identity, holding a
reference to whoever currently occupies it. Employees' `reports_to`
references the position, not the occupant. When occupants change,
no employee records have to be updated — you update the
position-→-occupant pointer, and downstream lookups dereference
fresh. Erlang's registered names are this pattern at the runtime
level; this language makes it first-class data.

---

## 7. Permanent identity, no generation counters

Generation counters in conventional ECS solve one problem: handles
can be copied freely, but entities have lifetime, so after
destroy-and-reuse an old handle would point at the wrong entity
unless something detects it. The counter is a runtime check that
catches "the slot you're looking at is now a different entity than
when you got the handle."

In this model, that situation doesn't exist:

- Entities don't get destroyed in any meaningful sense. They
  transition through collections (including empty), but identity
  persists.
- References target `(entity, component)` pairs, scoped to roles.
  By the time a slot has moved on to a different role, all
  observers of the previous role have already fired and
  unsubscribed.
- Bare entity handles aren't useful operationally. Every operation
  that could care about role queries the current role, not a
  remembered one.

The failure mode generation counters protect against has been
structurally engineered out.

The implementation choice this opens up: **truly permanent
identities, monotonic ID allocation.**

- Allocate IDs sequentially. Any ID in `[0, max_allocated)` is
  valid; if its slot data has been reclaimed, the entity is "in
  the empty collection" by default.
- Empty entities cost zero. No row data, no per-entity overhead.
- 64-bit IDs handle every plausible workload — a billion creations
  per second for 584 years.

The aesthetic point: generation counters were always a leak — a
runtime concession to a semantic problem (entity reuse) that the
surface model didn't acknowledge. They're the kind of thing where,
if you tried to teach the language to a beginner, you'd have to
say "and also, your handles can silently become invalid; here's
the check you have to remember." That's the smell of an
unaccountable concept. Removing them isn't just an
implementation simplification — it's the language admitting it
never had a real story for entity destruction in the first place,
and now it does (the empty collection), and the workaround is no
longer needed.

Good language design tends to look like this: you find the right
primitive, and a piece of machinery that previously felt
necessary turns out to have been compensating for a missing one.

---

## 8. Knowing current state

For moves to work, you need to know what collection an entity is
currently in. This is a runtime question, not static:

```
reg.is_in(e, &empty)        // bool
reg.current_collection(e)   // returns collection handle
```

Move operations check at flush: `move(e, &src, &dst)` succeeds if
e is currently in src, fails otherwise. Failure is a first-class
event in the failure-as-transition model — queues a `MoveFailed`
op rather than panicking, which means a move that races against
another move handles cleanly without special-casing.

In well-structured code, the question is rarely asked of an
arbitrary handle. Surrounding data structures track state
implicitly:

- **Slot pattern.** A slot entity has
  `CurrentOccupant: Option<Entity>` or two collections
  (`OccupiedSlot` / `EmptySlot`). The slot's state structurally
  encodes whether it has an occupant.
- **Pool pattern.** A pool maintains a collection of empty
  entities; `pool.acquire()` pops one whose state is known by
  invariant.
- **Supervisor pattern.** A supervisor's logic tracks child state
  internally; no external query needed.

For cases that want **static** guarantees, the linear/affine path
is opt-in. Typed handles like `Entity<InEmpty>` and
`Entity<InActive>` where moves are typed transformations:
`fn activate(e: Entity<InEmpty>) → Entity<InActive>`. The type
system tracks current collection through the call graph. Costs
the user lifetime-style annotations, used where it earns its
keep.

Default is dynamic-with-graceful-failure because that's
consistent with how everything else in the model works (observers
fire on transitions, failures are events, the runtime is the
source of truth about current state).

### Fresh allocation

When you want a brand-new entity (not reactivating an existing
one):

- `reg.alloc()` returns a freshly-allocated entity, in the empty
  collection by default.
- `reg.create_in(&coll)` if you want it to land in a real
  collection atomically.

The ID counter increments; no slot is recycled (per permanent
identity); the handle's current state is known by construction.
Most "I have an entity in empty" handles arrive this way.

---

## 9. Failure as a state transition

Combining the Erlang-shaped supervision with collection-as-state
gives a recovery story that no mainstream language matches.

In Erlang, when a process can't handle some failure, it crashes
and the supervisor decides what to do. In this language, when an
entity can't make a state transition (component init fails,
validation rejects, an invariant breaks), it doesn't try to
recover in place — it moves to a `Failed` collection (or
whatever's appropriate), observers fire, supervisors react. The
entity's own logic stays small and forward-progress-only. All the
ugly recovery branching lives in the supervisor layer where it
can be inspected and changed independently.

This composes with the pure-system + commands model. A system
tries to move E from `Active` to `Processing`; the move fails
(init returns error, validation rejects); the failure is *itself*
a queued op — `Failure(E, reason)` gets created, supervisors
monitoring `Active` failures see it on the next flush, dispatch
their strategy. The system that attempted the move doesn't know
about recovery; it just returns the failed move as a command.
Replay-deterministic by construction, inspectable, debuggable.

Failure becomes a kind of state transition, observable by anyone
monitoring for it, with recovery policy declared by relationships
rather than scattered through code. That's a really different
programming model than what most languages offer, and it's
continuous with everything else in the worldview (state-as-
membership, lifecycle-as-moves, identity-as-handle). The whole
model gets more coherent the further you push it.

---

## 10. What this corrects about OO and FP

Pulling the threads together:

**Identity is real and first-class** — recovered from OO. An entity
handle is a name that survives all changes to everything else. It's
not its components (which change), not its collection (which
changes), not its history (which only exists in the runtime's
optional log). It's just *a peg that components attach to and
detach from over time*. That's a much purer notion of identity than
OO offers, because OO bundles identity with current state and
pretends they're the same thing.

**Values stay values** — recovered from FP. Components are values.
Commands are values. Move queues are values. Observer reactions
are values. The only thing with identity is the entity. Everything
else is data flowing through a system that treats it as data.

**Behavior is unbundled from data** — fixing the OO mistake.
Systems are free functions over collections. Components carry no
methods. Inheritance doesn't exist; capability variation is which
row, state variation is which collection. The
`if state == OPEN`/`instanceof`/visitor-pattern apparatus that
every OO codebase grows dissolves into structural collection
membership and comptime-checked row operations.

**Identity is unbundled from continuity** — going past both.
Whether the same identity has continuity across role changes is a
user-controllable property (give the entity a permanent component
that's in every collection it can inhabit). Whether to use
reactivation is a programming discipline, not a language
constraint. Most languages force you to pick continuity-baked-in
(OO) or discontinuity-baked-in (FP); this model makes both
optional and orthogonal.

**Effects are values** — keeping FP's win without losing OO's
identity. External effects are commands returned from systems, not
side effects performed inside them. Replay determinism is
structural. Time-travel debugging is a primitive operation.

**Lifetime is structural** — unique. Components have lifecycle;
entities do not. Observers watch component possession; references
target roles. Resource cleanup, capability revocation, and failure
recovery are all the same machinery — observer-driven reaction to
component transitions.

Most languages give you exactly one of OO's wins or FP's wins, and
the other has to be smuggled in as a second-class concept. This
model gives you both, plus a structural account of relationship
and recovery that neither tradition offers cleanly.

---

## 11. Open questions

Things this exploration hasn't settled:

- **Performance of observer indexes.** Per-component-type
  secondary indexes of "all observers watching component C" are
  the load-bearing data structure. Heavy update traffic; needs
  profiling on realistic workloads.

- **Many-to-many relationships.** The standard SQL move (introduce
  a join entity) works, but the source-language ergonomics of
  expressing "Channel has many Members; Member belongs to many
  Channels" is unsketched.

- **Cycles.** Symmetric observer cycles work cleanly. Asymmetric
  cycles (A observes B's loss with reaction X; B observes A's loss
  with reaction Y) need a propagation order. Topological sort by
  observer dependency graph, probably.

- **The runtime/semantic split for slot reuse.** Permanent
  identity at the language level + runtime memory reclamation for
  bounded usage. The reclamation condition (no live references, no
  live observers, in empty for some duration) is sketched but not
  specified.

- **Components-as-capabilities.** The capability-security framing
  is structurally supported but not designed. Could go further
  than RBAC — capability delegation, attenuation, revocation as
  first-class operations on components.

- **Scheduling and parallelism.** Effect-system tracking of
  read/write sets enables auto-parallelization. The scheduling
  algorithm is unspecified. Topological by data dependency,
  probably, with explicit ordering constraints for cross-system
  invariants.

- **External I/O that can't be replayed in place.** File handles,
  sockets, etc. — the command/effect boundary handles *initiating*
  effects deterministically, but reproducing the same socket
  across replay sessions requires external machinery (cf.
  rove-tape's response-capture approach).

- **Surface syntax.** None of the above is about how the
  programmer writes any of this. The semantic model is the hard
  part; syntax is downstream. But syntax decisions ship and
  constrain forever, so worth being deliberate about ergonomics
  when the time comes.

---

## 12. Considered and rejected

So future explorations don't re-derive dead-ends:

- **Linear handles (no aliasing of entity references).** Too
  restrictive. Real code holds many copies of any given entity
  handle — cross-references between Connection, Listener, Stream,
  etc. The right cocktail is affine for the entity-as-resource +
  freely-copyable handles + role-scoped observers handling
  validity.

- **SQL-style cascade annotations on schema (rather than dynamic
  observers).** Too static, doesn't allow runtime rewiring,
  conflates reference with cascade. Erlang-style relationship-as-
  entity is more expressive. Schema-style sugar can desugar to
  dynamic observers for the static case if ergonomics demand it.

- **Entity destruction as a separate primitive from move.**
  Collapses cleanly into "move to empty collection." Every
  primitive removed is forever; this one wasn't earning its keep.

- **Forbidding entity reactivation
  (once-empty-stays-empty).** Unnecessary given role-scoping.
  Reactivation is invisible to observers of the previous role.
  Whether to use reactivation is a user-facing programming
  discipline, not a language constraint.

- **Generation counters.** Were a workaround for the absence of a
  proper destruction story. Once destruction is "move to empty"
  and references are role-scoped, counters have nothing left to
  count. Slot reuse is invisible by construction.

- **Rust-shaped Arc / Rc for shared ownership.** Recapitulates the
  identity-via-refcounting workaround for a problem the model
  doesn't have. Identity is already a separate first-class concept;
  references just point at entities directly, and the runtime
  manages reachability without per-reference machinery.

- **Pure-functional immutable components (no in-place mutation,
  even within a system).** Forces every state change through value
  reconstruction. Possible but ergonomically painful and
  unnecessary — Koka-style mutable-in-system + pure-from-outside
  recovers the determinism without the ceremony.

- **Per-entity "alive/dead" flag or boolean.** State-as-membership
  + the empty collection cover this without a flag. Adding the
  flag would re-introduce the "is this handle valid" check that
  role-scoping eliminated.
