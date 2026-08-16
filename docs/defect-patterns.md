# Defect patterns

The recurring *shapes* of bugs in this codebase, with the real instances that
name each shape and the structural changes that would make them unlikely rather
than merely caught.

This is not a bug list. A bug list is worked through once; a pattern list tells
you where the next one will be. Every class below has **at least two independent
instances**, most of them found long after they shipped, and every one of them
passed `zig build test` — they are not the kind of defect a unit test is
positioned to catch.

Compiled from the rove#355 smoke-suite sweep (which found five live production
bugs in one pass) plus the incarnation work in rove#357 that preceded it. Read
alongside [decisions.md](decisions.md) (what is settled) and
[architecture/overview.md](architecture/overview.md) (how the pieces fit).

---

## 1. One value, two identities

**Shape.** A field means two things because, at the time it was written, the two
things happened to be equal. Later one of them changes and the other silently
inherits the new value.

**Instances.**

- `worker.log.log_worker_id` was the request-id minter identity *and* the blob
  coordinator's queue id. rove#281 repacked the minter identity as
  `(node_id << 8) | worker_idx` so ids stay unique across nodes — making its
  smallest legal value **256**. Three call sites did
  `@intCast(worker.log.log_worker_id)` down to the coordinator's `u8`, so
  **every inbound body over the inline threshold panicked the worker thread, on
  every node, unconditionally.** It shipped and ran in production.
- The equivalence was even written down as an invariant:
  `src/js/fetch_engine.zig` carried the comment *"the owning worker's id (== its
  coord queue id, == its `log_worker_id`)"*. It was true when written. Nothing
  re-checked it when #281 landed.
- The producer *did* validate: `RequestIdMinter.mintIdentity` refuses to start
  on an out-of-range node/worker pair. Validation at the producer does not
  protect a consumer that re-derives — the narrowing cast was three modules
  away.

**Why the code permitted it.** Every identity in the worker was a bare integer
(`u16`, `u8`, `usize`). `log_worker_id`, `msg_inbox_idx` and `coord_worker_id`
were mutually assignable, so nothing distinguished "this is a raft-partitioned
minter identity" from "this is an index into a queue array".

**The structural fix (landed, rove#363).**

- Distinct types for the two identities that collided:
  `log.MinterId` (`enum(u16)`, constructed only by `MinterId.init`'s packed
  node/worker rule) and `coordinator.QueueId` (`enum(u8)`, constructed only
  from a registered msg-inbox slot via `QueueId.fromInboxIdx`). Every carrier
  — the coordinator API, the fetch events, the durability parks — holds the
  type, so a cast between identities has to be written as a greppable
  `@enumFromInt` on purpose.
- One named source per identity: the queue id derives from `msg_inbox_idx` at
  registration — the same slot the fetch engine's owner lookup uses — so the
  two submit paths cannot drift.
- Still true, and worth keeping in review: treat "A == B today" comments as a
  smell, not documentation. If two values must be equal, derive one from the
  other.

---

## 2. A derived path with more than one constructor

**The most expensive class in this codebase — seven instances, one root.**

**Shape.** A value is *derived* from an identity (a storage key, a directory, a
hash). One place derives it correctly; other places re-derive it by hand. When
the derivation rule changes, only the first place is updated, and the rest
silently address the wrong thing. There is no error — both sides are internally
consistent, they just disagree.

**Instances** (all rove#357, all found one at a time over two sessions):

| where | what it did |
|---|---|
| `PumpStores.resolve` (`src/rewind/main.zig`) | re-hashed the tenant NAME, so applied writesets landed in the previous lifetime's store while the dispatcher read the current one |
| `DeploymentCache` slot key | keyed by name alone, so a reborn tenant was served its predecessor's **code**, from memory, without touching storage |
| fetch-engine app-blobs door | hand-built `{tenant}/app-blobs/…` |
| fetch-engine static-origin door (`rove-static.internal`) | hand-built `{tenant}/file-blobs/…`; a cold static read got S3's `NoSuchKey` document and the relay served *that* as the asset body |
| `jsBlobPresign` (`src/js/bindings/blob.zig`) | signed the legacy prefix, so **every presigned URL handed to a customer 404'd** |
| CP `handleMove` / provisioning attach | delivered the incarnation only at provision, so a move or backfill opened a legacy-keyed store |
| CP membership reconciler bootstrap | same, for a node it grew or healed — the node caught up on the raft log, was promoted to voter, and served an **empty tenant** |

**Why the code permitted it.** The intended constructor returned a *backend
handle*. Any code that needed a signed URL, a raw path, or a key string could
not use it and reached for `std.fmt.allocPrint` with `cfg.key_prefix_base` and
a bare `instance_id`. The tenant id was a `[]const u8` available everywhere;
the incarnation was a second `[]const u8` that had to be fetched and threaded
separately, so forgetting it was the path of least resistance and produced no
diagnostic. The asymmetry that made it so costly: an **empty** incarnation is
legitimate (pre-#357 tenants stay on the legacy layout), so "nobody passed
one" and "this tenant has none" were the same value — every miss was a quiet
wrong answer instead of a loud failure.

**The structural fix (landed, rove#363).**

- **`TenantStorage` (`src/tenant/storage.zig`) is the only way to name a
  tenant's bytes**: one value carrying `(id, incarnation)` exposing
  `keyPrefix(subdir)` / `s3ObjectPath(subdir, key)` / `openBackend(subdir)` /
  `storeId()` / `dirPath()`. The legacy-vs-incarnation branch lives only
  there; the four doors that used to hand-build paths take the handle.
- **Unset is unrepresentable.** `Incarnation` is `legacy | token`, with no
  default on any struct that carries one — omitting it is a compile error,
  not a legacy-shaped guess. `Tenant.storageOf` answers by name and returns
  `InstanceNotFound` for an absent marker; the `"" = maybe-legacy` collapse
  (and every `catch dupe("")` quiet default downstream of it) is gone.
- **A lint for the residue**: `scripts/ops/tenant_prefix_lint.py` flags a
  format string building a per-tenant object path (or interpolating
  `key_prefix_base`) outside the handle and the few cluster-scoped key
  builders.

---

## 3. A contract carried by convention across a process boundary

**Shape.** Two processes agree on a wire format by each writing it out by hand.
Adding a field means editing every sender. A sender that misses it does not
fail — the receiver defaults.

**Instances.**

- `/_system/v2-attach` reads **8** `X-Rewind-*` headers (tenant, plan,
  epoch, voters, learners, join-as-learner, peer-addrs,
  incarnation). When the incarnation was added it reached the provisioning
  sender and not the move sender, the reconciler sender, or any of the four
  smokes that simulate a CP join. Each smoke had its own private copy of the
  header list.
- The same shape, benign before it was closed: `v2-applied-baseline` was
  parsed by an anonymous struct in `src/cp/reconciler.zig` with defaults for
  every field, so a field the leader stopped sending read as its default
  rather than an error.

**Why the code permitted it.** The attach contract had no single definition.
It existed as: a `curl.Header` array in `move.zig`, another in
`reconciler.zig`, header-name constants in `v2_move.zig`, and four Python
lists.

**The structural fix (landed, rove#363).**

- **`rove-wire` (`src/wire/root.zig`) is the one encode/decode pair.**
  `encodeAttach` is the only Zig sender path (provision/move fan-out and the
  reconciler bootstrap both drive it; the positional header juggling in the
  reconciler is gone) and `decodeAttach` the only receiver path; the Python
  smokes' mirror stays `smoke_lib_v2.attach_join`. `AppliedBaseline` gets
  the same treatment: one JSON encoder at the worker, one parser at the
  reconciler with **every field required** — a field the leader stops
  sending is a parse error, not a zero (`ignore_unknown_fields` stays on, so
  *adding* a field remains compatible).
- **Decode failures over defaults.** The incarnation header is required on
  every attach — a legacy tenant sends the explicit wire token `legacy`
  (an empty header value would be dropped by libcurl's serialization), and
  an ABSENT header is a 400 naming the rule, because absence means the
  sender bypassed the encoder. Malformed values never collapse to
  "absent-field" behavior.
- **Attach is the only instance-creating door.** The streamed snapshot door
  (`v2-snapshot-stream`) never carries (or guesses) a storage identity — the
  move/catch-up protocol attaches first, so the door 404s on a
  never-attached tenant instead of minting an instance with a guessed
  incarnation.

---

## 4. Identity used as a key without its lifetime component

**Shape.** A cache, index, or map is keyed by a name that is *reused* over time.
The second holder of the name reads the first holder's entry.

**Instances.**

- `DeploymentCache` keyed by tenant name — a reborn tenant served its
  predecessor's code (see class 2; it is the same root cause seen through a
  cache).
- The log index dropped repeated `request_id`s because the id was not unique
  across nodes (rove#266 / rove#281) — the same shape in the identity direction
  rather than the lifetime one.
- Storage namespace (rove#266) and storage incarnation (rove#357) are both this
  class solved deliberately, one level apart: per-cluster-lifetime and
  per-tenant-lifetime. That they were needed twice is the signal.

**What would make it unlikely.** Make the composite key the *only* key type. If
`TenantStorage` (class 2) is the handle, caches key on it, and keying on a bare
name stops type-checking.

---

## 5. Two pieces of state encoding the same fact

**Shape.** The same question ("which upstreams have I tried?") is answered by
two variables. An edit that updates one leaves the other stale.

**Instances.**

- Front-door retry (rove#353) tracked progress with a linear `node_idx` cursor.
  Adding a leader-hint re-aim jumped `node_idx` to the hint, which broke the
  scan's invariant — one repro run lost **all 24** writes. Fixed by making a
  `tried_mask` the single source and deriving the next candidate from it.

**What would make it unlikely.** Prefer one representation and derive the rest.
When a second variable appears that answers a question the first already
answers, that is the moment to collapse them.

---

## 6. A consumer inventing a producer's contract

**Shape.** A consumer re-parses or re-derives something the producer already
provides, based on an assumption that is documented to be false.

**Instances.**

- The admin dashboard's router split `request.path` on `?` to extract the query
  string. `handler-shape.md` states plainly that `request.path` **never**
  contains the query — it lives on `request.query`. So every routed read
  needing a parameter reached its door with the parameter missing:
  `/v1/cp/route?host=` arrived at the CP bare and 400'd, taking the whole
  operator cluster page with it. The same split existed in the OIDC middleware.

**What would make it unlikely.** Where a contract says "X never contains Y",
consider whether the shape can make that structural — and prefer shipping
already-parsed values over strings that invite re-parsing.

---

## 7. Renames and wire changes with no mechanical consumer sweep

**Shape.** A surface is renamed; the code is updated; fixtures, smokes, docs and
sibling apps are not.

**Instances (six in one sweep).** `v2-bundle` → `v2-snapshot` (and its
pause/resume pair dropped when the dump went non-quiescing); plan tiers
`email_*` → `outbound_*`; `email.send`'s `key` → `apiKey`;
`platform.compile`'s `name` → `on`; the cert frame gaining a leading version
byte; `dep_id` becoming a hex string; provision answering `200`+body instead of
`204`.

**What already works, and should be copied.** The cheapest of these to diagnose
were the ones that **rejected the old spelling by name**: `email.send` answered
*"option `key` was renamed — use `apiKey`"*, and the envelope decoder rejects
every retired type byte loudly rather than mis-applying. The expensive ones were
those that just… stopped matching: an unpacker returning `None`, a field reading
as `0`.

- Retire loudly. A removed option, header, or type byte should produce an error
  that names its replacement, and should stay in place for at least one release.
- The cert frame is the right pattern for wire changes (a version byte, checked
  on decode) — see [architecture/format-versioning.md](architecture/format-versioning.md).
  The defect there was that the *test* hand-rolled the old layout, which is
  class 3.

---

## 8. Late outcome, early commitment

**Shape.** An irreversible step is taken before the information needed to decide
it is available.

**Instances.**

- The static stream relay commits the response head (`200` + a strong ETag) on
  the first chunk, but the upstream status is only delivered on the *final*
  event. A small S3 error document fits in one chunk, so the client got
  `200` + the `NoSuchKey` XML as the asset body, then a reset. The handler's
  gate is correct and simply runs too late. **Open** — the fix is either to
  deliver the upstream status from chunk 0 or to refuse to relay body bytes for
  a non-2xx upstream, and that is a customer-facing streaming semantic worth
  deciding deliberately.
- `run_all.py` killed a timed-out smoke but not the cluster it spawned. The
  orphans held the fixed ports and every later smoke failed `EADDRINUSE` — one
  hang reported as a dozen failures. (Fixed: `start_new_session=True` +
  `os.killpg`.)

**What would make it unlikely.** Where a decision commits to something
irreversible, require the deciding input to be present at the type level — not
"valid only when `final == true`" in a doc comment.

---

## 9. Tests that assert a retired contract

**Shape.** A behaviour is deliberately removed. A test still demands it, so the
test can only pass by resurrecting the defect.

**Instances.**

- `streaming_write_pressure_smoke_v2` required a **positive dropped-chunk
  count**. `stream.write` had since become lossless — the 256 KB soft cap is
  back-pressure and the 4 MB hard cap throws — and
  `src/js/globals_request.zig` says so at the exact site where the counter used
  to be populated. The smoke reported the *absence of data loss* as a failure
  and would have gone green only if the engine started truncating.

**What would make it unlikely.** Removing a surface is not done until its
assertions are gone. The engine comment marking the removal was written; the
test was not swept. A grep for the retired identifier is a thirty-second step
that no process required.

---

## 10. Verification that is not wired to anything

**The meta-class. It is why classes 1–9 survived to production.**

**Shape.** A check exists, is maintained, is believed, and never runs.

**Instances.**

- The smoke suite (rove#355): 142 end-to-end tests, the only coverage of raft +
  S3 + the front door + the JS dispatcher together, unrun for months. Roughly a
  third were red. Running it once surfaced five live production bugs.
- The Zig analogue already has a guard: a test file not referenced from a test
  root never compiles and never runs — `scripts/ops/test_reachability_lint.py`
  exists precisely because that failure is invisible from every direction.
- A related trap seen during this work: **an A/B against an older commit tells
  you *when*, never *what*.** The front-door 502 cluster was written off as
  "pre-existing" on that basis for weeks. The actual cause —
  `thread panic: integer does not fit in destination type` — was in the log the
  whole time.

**The structural fix (landed, rove#363 — owner decision taken).**

- **The suite is wired to two things that run it** (see
  `scripts/smoke/README.md`, "How it runs now"): a nightly systemd timer
  (`scripts/smoke/nightly.sh` — dedicated checkout of `origin/main`, full
  suite, baseline diff, alert to the standing issue rove#373 on anything
  newly broken **or on a nightly that could not run** — a build break is an
  alert, not silence) and a deploy gate in `scripts/ops/build.sh` that
  refuses to ship on a newly-broken smoke (`ROVE_SKIP_SMOKES=1` is the
  conscious override; a missing `.env` is a hard stop, never a silent skip).
- `--baseline` diffing is what makes both livable: a partly-red suite still
  answers the only question that blocks a change — *did I break something?* —
  so long-standing reds stay backlog instead of teaching everyone to ignore
  the gate. The baseline is refreshed manually, on purpose.

---

## What already works

Worth preserving through any refactor:

- **Loud retirement.** Envelope type bytes reject retired values instead of
  mis-applying; `email.send` names the option's replacement. Every defect that
  announced itself cost minutes; every one that defaulted cost a session.
- **Lints for invisible rules.** `test_reachability_lint.py`,
  `doc_pointer_lint.py`, `globals_lint.py`, `spdx_lint.py`. A rule that lives
  only in a reviewer's head is a rule that breaks.
- **Refusing to start.** `MinterId.init` refuses an out-of-range identity;
  services refuse to start against an unmarked object store (rove#266). Both
  turn a silent wrong answer into an immediate stop. Their limit is class 1:
  they protect the producer, not a consumer that re-derives.

## Suggested order for a refactor

By expected defects prevented per unit of work. (All four landed via
rove#363: classes 2+1 in PR #365, class 3 in PR #370, class 10 as the
nightly timer + deploy gate above.)

1. **Class 2** — the tenant-storage handle. Seven instances, one root, and the
   fix is mechanical once the handle exists.
2. **Class 1** — distinct identity types in the worker. One instance so far, but
   it was an unconditional production crash that the surface (three
   mutually-assignable integer identity fields) invited.
3. **Class 3** — one definition of the attach envelope. Removes the duplication
   that made class 2's worst instance possible.
4. **Class 10** — decide how the suite gets run. Everything above is only
   verified by it.
