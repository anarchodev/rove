# Pricing model — what to sell and why

> **Status**: Design proposal, 2026-06-02; revised 2026-08-01 to add the
> third axis (§4) and correct three claims about the shipped storage
> layout (§2, §3.2); revised 2026-08-17 to sell axis 2 as a **time
> window** rather than a capacity ring (§3), on legal grounds the earlier
> drafts never weighed. Captures the economic model behind the tiers; the
> *enforcement* mechanism is the plan-tiers enforcement (`architecture/control-plane.md` "Operational state")
> (tier plumbing + per-lever wire-up). This doc is the "what to charge
> for and why" that sits upstream of that one. It **confirms** that
> enforcement's retention lever (§Lever 3) as a time window, and adds the
> deletion the shipped read clamp still lacks —
> see §7 for the reconciliation. Axis 1 (§2) is now built — measured,
> plan-derived, and enforced — while axes 2 and 3 remain proposals; the
> load-bearing unmeasured assumption is the per-record deflate ratio (§8),
> and §9 is the break-even arithmetic those tier numbers get chosen
> against.

## 1. The principle — price the scarce resources, guard the rest

Two distinct jobs, and conflating them is where serverless pricing
usually goes wrong:

- **Billing axes** — the things a customer *buys more of*. These should
  map to genuinely scarce, expensive resources, so price tracks marginal
  cost and no workload can be cheap on every axis while expensive to run.
- **Guardrails** — per-tier ceilings that exist to stop abuse and bound
  blast radius, *not* to generate line items. A guardrail keeps the
  invoice short while plugging the arbitrage a pure billing model leaves
  open.

We sell **three billing axes** and back them with **one new guardrail**
(plus the rate/body levers already specced in the plan-tiers enforcement (`architecture/control-plane.md`)):

| | What | Role | Ceiling behavior | Scarcity |
|---|---|---|---|---|
| Billing axis 1 | **Max KV size** | buy more | refuse the write | HIGH — raft-replicated, RAM/fsync-bound, on the hot path |
| Billing axis 2 | **Replay retention** (days) | buy more | deleted past the window | LOW per byte, but the product's core durable artifact |
| Billing axis 3 | **Customer object storage** | buy more | refuse the write | LOW per byte, but customer-controlled and unbounded |
| Guardrail | **Log-byte ingest rate** | bound, not billed | admission 429 | the universal cost currency (see §6) |

The **ceiling behavior** column is the load-bearing one, and it is why
axes 2 and 3 stay separate despite both being S3 bytes in one bucket —
see §4.1.

Why these are the right axes — and not "requests" — is the rest of this
doc.

## 2. Axis 1 — Max KV size

Per-tenant `app.db` lives in raft: replicated to every node in the
group, held in the kvexp/LMDB overlay, and on the latency-critical
path. It is the one resource we genuinely *cannot* make elastic, so
pricing on it is pricing on real marginal cost. This is the strong
axis.

- **Define it as logical committed bytes**, not raw `app.db` file size.
  LMDB reuses freed pages and the file never shrinks, so file size
  ratchets upward and drifts away from live data — a denomination that
  produces billing disputes we would lose.

- **Overage semantics = throttle → upgrade, never elastic billing.**
  KV is RAM/raft-bound; at some point we physically cannot honor more
  without OOM-ing a node and hurting every co-tenant. So at the cap, go
  read-only / reject writes and prompt an upgrade. Selling "unlimited KV
  at $X/GB" writes a check the cluster can't cash. This is the key
  asymmetry vs. axis 2: meter all three, bill elastically only on the
  elastic one.

- **Measured and enforced as of #296/#298.** The durable size is an
  O(1)-ish stat on the store's own LMDB DBI —
  `(branch + leaf + overflow pages) × page_size`, plus committed-overlay
  bytes — cached with a short TTL and exposed per tenant as
  `kv_store_used_bytes`. Enforcement is batch-level (checked after the
  handler walk, before the propose), because a live size check *inside* a
  handler would be an untaped replay input. Over the cap a write batch is
  refused with a non-retriable **507** naming used/cap; reads and deletes
  keep working, so the recovery path is never blocked.

- **The cliff was real, and node-wide rather than per-tenant.** In
  production every tenant's KV is a sibling store inside the one node-wide
  `cluster.kv` env, not a per-tenant `app.db` file (an earlier draft of
  this section said otherwise, and so did the code comment it was taken
  from). So the ceiling to respect is a per-NODE total against
  `CLUSTER_MAP_SIZE`, and axis 1 is "make that cliff explicit,
  plan-derived, and graceful" — which is what shipped: a runaway tenant
  now meets its own attributable 507 instead of LMDB's unattributed
  `MDB_MAP_FULL`.

  **That total is deliberately over-subscribed, and no tier is capped by
  it.** Sizing the map to `tenants × cap` would reserve for a
  simultaneous worst case that never arrives. What makes oversubscription
  safe is the trio above plus the relief valve: usage is metered per
  tenant, any one tenant is bounded attributably, and a node approaching
  its drive sheds tenants with the zero-downtime move
  (`architecture/control-plane.md`) rather than having pre-reserved for
  them. The map is sparse address space — 64 GiB mapped against under a
  megabyte resident in production — and LMDB accepts a larger size on a
  later open, so raising it costs one restart and no migration. The one
  hard bound is the node's drive: past free disk, `MDB_MAP_FULL` becomes
  `ENOSPC`, which takes the raft WAL and log spool down instead of
  refusing a single write. Selling a larger KV tier is therefore a
  capacity + pricing decision, not blocked engine work.

## 3. Axis 2 — Replay retention as a time window (capacity is derived)

Every transaction deposits ~1 KB of replay log into object storage
(`docs/architecture/deployment-and-logs.md`; the key layout is
node-interleaved rather than per-tenant — see §3.2). So
for any tenant that retains logs, object-storage growth *tracks
transaction volume* — something Lambda/Cloudflare can't price because
they can't see invocations as storage. Here the product literally stores
every transaction, so storage is a legitimate proxy for usage.

This axis covers **platform-generated bytes only**: the replay log and
the recorded request/response bodies it references. Bytes the customer
deliberately stored are axis 3.

The model is **a sold time window with a derived byte ceiling**: you buy
N days of replay history; records past the window are deleted. The tier
never quotes a byte capacity — capacity is what *we* provision, computed
from the window and the ingest guardrail of §6:

```
log_capacity_bytes = log_refill_bytes_per_sec × 86400 × retention_days
                     + log_burst_bytes
```

This is §6's identity solved for the other unknown. The ring model (an
earlier draft of this section) sold bytes and *derived* the time floor;
this sells time and *derives* the byte ceiling. Same equation, and the
derived direction is the one that matters: the number written into the
contract is the number that bounds the spend, so the promise and the COGS
cap are the same fact and cannot drift apart.

Worst-case COGS per tenant is therefore provable rather than modeled. At
the shipped uniform 64 KiB/s ingest cap (5.66 GB/day) and OVH list
($0.0081/GB/mo):

| tier | window | derived ceiling | worst-case COGS |
|---|---|---|---|
| free | 7 d | 40 GB | $0.32/mo |
| pro | 30 d | 170 GB | $1.38/mo |
| enterprise | 365 d | 2.1 TB | $16.70/mo |

Those are ceilings at *maximum* ingest. A median tenant runs orders of
magnitude under, so real spend is a rounding error and deflate is
unmodeled margin on top (§6.1).

**Derive the ceiling from the byte bucket, never from a request rate.** A
request is not a fixed quantity of log: deriving from `rps` would require
multiplying by a worst-case bytes-per-request, and `rps × max_body_bytes`
at the free tier is 500 × 4 MiB = 2 GB/s — a meaningless bound. Both caps
are enforced at once and the byte bucket always binds first, which is the
whole reason §6 exists. Request rate contributes to this axis only
through §6's `k·count` floor term.

### 3.1 Why time-as-a-cap, when an earlier draft rejected it

The ring model rejected a time cap as a pure *takeaway* — bytes already
bound COGS, so capping by time costs us nothing and shrinks the light
customer's deal, throwing away the "kept basically forever unless you get
huge" pitch. That reasoning is sound **on customer-value grounds alone,
and those are not the only grounds.** It never weighed the liability side,
which points the other way hard enough to reverse the conclusion:

- **Storage limitation.** Request bodies and headers are recorded and
  replayed, so the replay log holds the customer's end-users' personal
  data and we hold it as a processor. A retention period is a required
  term of the DPA (rove#326) and the privacy policy (rove#324). "Until
  your bytes run out, which depends on your traffic" is not a period; it
  is the absence of one.
- **Erasure.** Every extra month of history is more surface for an
  erasure request to sweep, making an obligation we already carry
  (rove#340) strictly more expensive to discharge.
- **Legal process and breach blast radius.** Data held is data that can be
  compelled or leaked. A bounded window is what buys the cheapest possible
  answer to a subpoena, and it caps what any single incident exposes.

So for the segment that pays the most, **"we keep it basically forever"
is a liability rather than a feature.** Enterprise buyers require a
documented maximum; an absence of one is a procurement defect. The pitch
the ring model was protecting sells to hobbyists and repels the
compliance buyer.

The trade is real and taken knowingly: the light customer loses the
decade-long tail. What replaces it is a number they can plan and audit
against — which is what the ring model itself identified as the thing a
time number actually sells.

**It also fixes the ring's own sharp edge rather than trading it away.**
A variable window has a rewind-specific failure mode: a traffic spike
burns the window fastest exactly when its logs matter most, so the window
*contracts* right when you most want to rewind into it — the same shape
as "the request that crashed is the one you can't replay"
(`architecture/effects-and-handlers.md` §1). Under a fixed window a spike
costs *us* bytes and the customer's horizon is unchanged, and that cost is
bounded by exactly the derived ceiling above. Strictly better for the
customer, and affordable precisely because the bound is provable.

Two consequences to carry into the policy text, not just the code:

1. **Pinning is a stated exception.** Letting customers mark an
   incident's request tree as "keep" is still the right mitigation for
   the window expiring mid-investigation — but a pinned record outlives
   the published retention period, so the policy must describe it
   ("deleted at N days, except records you explicitly retain"). Ship the
   exception in the prose or the first pin makes the retention claim
   false.
2. **The window is customer-lowerable.** A tenant may set a window
   *below* their tier's maximum. That is a compliance feature for buyers
   who want data minimization, and it lowers our COGS — the rare control
   that is a concession in both directions. The tier maximum is a ceiling
   on what we will keep, never a floor on what they must.

### 3.2 Implementation cost to go in eyes-open

**Every object in axis 2 is cross-tenant.** A previous draft claimed log
records are per-tenant prefixed at `{instance}/log-blobs/` and concluded
that only the bodies needed a compactor. That claim does not match the
shipped layout and is retracted here:

- **Log records** are node-interleaved — one object per node per flush at
  `_logs/{node}/{batch}.ndjson`, holding every tenant's records for that
  flush, each raw-deflate-framed (`decisions.md` §11.4). Bodies ≤16 KiB
  ride *inline* in the record. There is no per-tenant `log-blobs/` store;
  the log-server says so directly (`src/log_server/standalone.zig`).
- **Bodies >16 KiB** spill to a second cross-tenant pool at
  `_pool/{batch_id}` (`src/bodies/root.zig`, rove#304).

That layout is deliberate and worth keeping: per-tenant keys would cost
`O(active tenants on node)` PUTs per flush, which is precisely what
§11.4's interleaving exists to avoid.

**The time window is what makes this tractable — the ring could not have
been.** Per-*tenant* byte eviction from a cross-tenant object requires a
compacting rewrite; there is no way around it, which is why the ring's
real price was a continuous compactor over both stores. Deletion by
*age* needs no such thing, on one condition: **an object must be
homogeneous in expiry, so it dies whole.**

It isn't today. A node-interleaved batch mixes a free tenant's records
(7 d) with an enterprise tenant's (365 d), so the object is deletable
only at the longest window in it — in practice 365 days for nearly every
batch, which would silently void the free tier's COGS bound and its
published period alike.

The fix is cheap and belongs at the write path, not the sweep: **shard
the flush by retention class**, `_logs/{node}/{class}/{batch}.ndjson`
with `class ∈ {7d, 30d, 365d}`, and pool bodies the same way. Then every
object has exactly one expiry, the sweep is a prefix-and-age delete, and
**no compactor is required for either store.** The cost is one PUT per
*class* per node per flush instead of one — bounded by the number of
tiers (3), never by tenant count, so §11.4's rationale survives intact.

Two consequences of sharding to carry into the design:

- **A tier change does not move records already written.** They expire
  under the class they were flushed into. A downgrade therefore keeps old
  records slightly longer than the new window (the read clamp hides them
  meanwhile, and `billing-policy.md` rule 9 wants a 30-day destruction lag
  anyway — compatible). An upgrade does *not* retroactively extend
  history that has already been swept, which narrows decisions.md §10.9's
  "upgrade reveals" to "reveals whatever the sweep has not yet taken."
  Say so on the pricing page rather than discovering it in a support
  ticket.
- **`Overrides.retention_days` breaks class homogeneity.** A custom
  enterprise window that is not one of the named classes needs either its
  own class or rounding up to the next one. Round up: it over-retains
  slightly, which is a cost question, where rounding down would breach a
  contracted period.

Whichever way it lands, the compactor question does not disappear
quietly — if sharding is rejected, rove#304 becomes mandatory *and*
grows to cover the log records too, and it is then **legally
load-bearing** rather than a cost line: a published deletion period that
leaves records resident is a false statement in the DPA.

Three further realities to go in eyes-open:

- **Nothing expires anything today.** The one GC in the tree is the
  deprovision sweep (`src/cp/storage_sweep.zig`, rove#350), which deletes
  a *deleted tenant's* per-tenant prefixes. Nothing deletes on age. The
  shipped `retention_days` lever is a *read* clamp — it hides records
  older than the window, it never removes them. So we currently occupy
  the worst quadrant: unbounded S3 growth, storing data no customer can
  read, while a policy commits us to deleting it. rove#333 is the sweep
  that closes this, and it is what makes the published window true.
- **Deprovision does not erase log records either, and sharding will not
  fix that.** The sweep can only delete per-tenant prefixes, so a closed
  account's records and spilled bodies survive inside the cross-tenant
  `_logs/` and `_pool/` objects — exactly the data class that holds
  end-user personal data. Retention-by-age and erasure-on-demand are
  different problems: age is solved by making objects homogeneous in
  expiry, whereas erasing *one tenant* from a shared object needs either
  compaction or per-tenant crypto-shred (rove#91). The window is
  deliverable without solving erasure; the account-closure promise in the
  privacy policy (rove#324) is not.
- **Deletion must be honest at the read surface.** A query for an expired
  window has to report "beyond your retention window" rather than
  silently return a short result set.

## 4. Axis 3 — Customer object storage

`blob.*` ([`handler-shape.md`](../handler-shape.md)) is a full
customer-facing content-addressed
object store: `put` / `get`, presigned `url` for zero-copy downloads,
`write` + `seal` for streaming recipes, and `receive` to pipe an inbound
request body straight to storage. Customer runtime objects land in
`{instance}/app-blobs/`; deploy-time statics and bytecode land in
`{instance}/file-blobs/`. Both are **customer-controlled** — bytes exist
because the customer chose to store them.

**It is entirely unmetered today.** The only limit in the tree is a
per-session 64 MiB cap on a single `blob.write` chain; `put` may be
called without bound, and the tier table has no storage field at all.
This axis is the newest of the three and the reason this doc needed
revising: the original two-axis model predates the `blob.*` API.

- **Overage semantics = refuse the write, like axis 1.** See §4.1.
- **Measurement is a running per-tenant byte counter** over the
  customer-controlled prefixes, never an S3 LIST per query. Axis 2 no
  longer shares this machinery — selling days means it needs no byte
  accounting at all (§3.2), so this counter is axis 3's alone.
- **This axis cannot be added later.** Customers accumulate objects
  freely, and a cap imposed after the fact either breaks existing
  customers or gets grandfathered away for exactly the customers who
  matter. That is the same "impossible later" property as axis 1, and the
  opposite of axis 2 — a shorter window can arrive at any time because
  deletion is prospective. **Axes 1 and 3 gate launch; axis 2's
  enforcement does not — but its *promise* does, because the privacy
  policy states the window before the sweep exists (§3.2).**

### 4.1 Why this is not just more of axis 2

Both axes are S3 bytes, in one bucket, differing only by key prefix.
There is nothing to physically separate — and they still must not share
a metered pool, because they differ in the single property enforcement
turns on: **what happens at the ceiling.**

- **Axis 2 is platform exhaust.** The customer never chose to write a
  replay log; it is a byproduct of being served. Deletion on a published
  schedule is fair *because* of that, and §6's ingest throttle is the
  matching guardrail — we bound what we generate on their behalf.
- **Axis 3 is deliberate customer data.** They called `put` because they
  wanted the object kept, and the documented pattern is to store the hash
  in KV and dereference it later. Deleting it on a timer is destroying
  data they asked us to hold.

Merge the pools and you are forced into one of two bad outcomes: expire
customer uploads (silent data loss), or refuse writes when the shared
pool fills — which means a traffic spike, by generating logs, breaks the
customer's `blob.put`. Coupling a deliberate write path to an exhaust
stream's fullness is a worse failure than either axis has alone.

So: one bucket, one accounting mechanism, **two axes with opposite
ceiling rules.**

### 4.2 The durability nuance — and why it does not change the answer

[`effect-algebra.md`](../effect-algebra.md) classifies blob bytes by
recoverability, and under
that lens axis 3 looks softer than stated above: **input bytes** (request
and fetch bodies) are unrecoverable because they came from outside, while
**output bytes** — a `blob.put` payload — are a pure function of the
source activation and its readset, so in principle they are a *cache*
that could be re-derived rather than storage that must be kept.

Two reasons that does not license deleting it:

1. **Re-derivation depends on the readset, which axis 2 deletes.** Once
   the source activation's readset ages past the retention window, the
   output is no longer re-derivable either. A cache whose backing is on a
   TTL is not a durable store.
2. **Nothing re-materializes on read.** There is no on-demand
   re-derivation path behind `blob.get`; an absent object is an absent
   object from the handler's seat.

The recoverability classification is the right model for *durability
engineering* — what a fault can lose and what it must not. It is the
wrong model for *billing*, where the question is what the customer
believes they bought. Record the distinction; price on the belief.

### 4.3 Egress — state the allowance now, enforce later

Serving is free on the current backend (§8), so nothing about egress is
urgent as *cost*. It is urgent as a *promise*: an allowance published at
launch is part of the deal a customer accepted, while one introduced
after they have built on unlimited serving is a takeaway. This is §3.1's
cap-versus-floor asymmetry pointed at bandwidth — so publish the number
from day one and leave enforcement for when it is needed.

**The allowance is derived, not a new knob:**

```
egress_allowance_per_month = 10 × stored_max_bytes
```

Computed off the tier's *quota*, not off actual stored bytes, so a
customer is never penalised for storing less than they bought. A 100 GB
tier serves 1 TB/month; the free tier scales down with it. No new tier
field, no new product decision per tier — it moves when axis 3 moves.

Why 10× is the right shape: it comfortably covers an application serving
its own assets — the hot subset of a customer's objects re-served many
times over a month — while a content-distribution workload sits orders of
magnitude above it. The ratio is what separates "storage with normal
serving" from "using us as a free CDN", and it separates them without
anyone having to define a CDN.

**Fair use, not a hard cutoff.** Cutting off a customer's public assets
mid-month is a severe, visible failure, and the cost of overshoot to us
is currently zero. So the stated posture is: an allowance, a conversation
and an upgrade path on sustained breach, and hard enforcement only if
abuse actually materialises. Publish it as a fair-use ceiling, not a
guillotine.

**Enforcement is architecturally non-trivial, which is the real reason it
waits.** `blob.url` hands the client a presigned URL and the bytes flow
client→object-store directly, never touching our compute. **We cannot
currently measure presigned egress at all** — not "we haven't built the
counter", but "the traffic does not pass through us." Enforcing would
mean either ingesting the object store's access logs (asynchronous,
provider-specific, and the only option that preserves zero-copy) or
proxying downloads through the worker, which discards the entire point of
presigned URLs and puts customer asset bandwidth back on our NIC. Prefer
the former when the time comes; note that a stated-but-unmeasured
allowance is honest only while the posture is fair-use.

## 5. Why not price "requests" / transactions directly

Per-request billing is the surprise-invoice customers hate, and it
fights our no-`O(N_tenants)`-on-the-hot-path rule (a per-request meter
keyed by tenant is exactly the per-tenant hot-path accounting we keep
out). The storage axes are measurable at existing batch/snapshot seams;
a transaction counter is not. So we never put transactions on the
invoice — we bound them with a guardrail instead (§6).

## 6. Guardrail — throttle log-byte *ingest rate* (the keystone)

Rate-limiting by request *count* is dimensionally wrong: a 1 MB-body
request costs ~1000× a tiny one but counts the same. Throttle the actual
cost driver — **bytes into the log** — and one identity falls out that
makes everything else consistent:

```
capacity = max_ingest_rate × retention_window
```

Once byte-ingest is throttled, capacity / rate / window stop being
independent, and §3 reads this identity left-to-right: **sell the
window, derive the capacity.** Provision to hold exactly the maximum a
throttled tenant could produce over the window they bought, and the
promise physically cannot cost more than that.

The upside is that the ceiling binds only at **max** rate. A tenant
running below their cap costs a fraction of the provisioned figure, so
worst-case COGS is a bound we quote against and never the bill we
actually pay. This is what makes a fixed window affordable: without the
throttle the same promise integrates an unbounded flow, and per-tenant
cost grows as ½·r·t² with no ceiling at all.

Read the other way — fixing capacity and deriving a retention *floor* —
the same identity describes the capacity-ring model §3 rejected. The
equation is neutral; which side you sell is the decision, and §3.1 is why
it is the window.

Note this guardrail bounds **axis 2 only.** It throttles what the
platform writes on the customer's behalf. Axis 3 needs no rate
guardrail — a customer storing their own objects is bounded by the axis-3
quota directly, and refusing at the ceiling is the whole mechanism.

### 6.1 Denominate everything in RAW bytes — deflate must not move the ceiling

The identity only holds if both sides are the same unit, and the
dangerous trap is metering the throttle in *ingested* (raw) bytes while
sizing the provisioned capacity in *stored* (post-deflate, on-S3) bytes —
the conversion between them is the compression ratio. Provision assuming,
say, 2× compression and a customer sending **encrypted /
already-compressed / random payloads (ratio ≈ 1.0)** consumes twice the
modeled bytes over the same window. Under the ring model that silently
halved the customer's guaranteed floor; under a sold window it instead
silently doubles *our* spend — the failure moved from them to us, which
is the better direction but still a failure.

Fix: denominate **throttle, provisioning, and deletion all in raw ingest
bytes.** Then the ratio drops out of the derivation entirely —
`capacity_raw = max_rate_raw × window`, exact for any input, including
incompressible. Consequences:

- **COGS** `= raw_resident × actual_ratio ≤ capacity_raw`. Price as if
  1 raw GB = 1 S3 GB (the incompressible worst case); **compression is
  pure unmodeled margin** — it lowers the bill, never a dependency we can
  be wrong about. The derived ceiling being a raw-byte figure means
  worst-case S3 spend is bounded regardless.
- **Customer-facing, the denomination disappears entirely.** Selling days
  means the customer never sees a byte figure for axis 2 — the one place
  raw bytes surface to them is the ingest guardrail's `429`, which is
  *bytes you sent*, the only denomination a customer can predict (they
  can't model our deflate, but they know what they pushed).
- **Do NOT model compression in any guarantee or any customer promise.**
  It is a margin / capacity-planning input only (§8).

The same rule applies to axis 3: quote and enforce the storage quota in
the bytes the customer handed us, not in what they occupy after deflate.

Two constraints this exposes:

- **Encryption-at-rest must sit below/after compression — but that's
  automatic for the likely near-term form.** Encryption at rest is
  currently **deferred** (no page encryption today). The likely launch
  baseline is *transparent* encryption — an encrypted volume under LMDB
  plus S3 SSE for the log/blob backend — which sits *below* compression
  (you deflate, the block/SSE layer encrypts the compressed bytes), so
  the ratio is preserved with no ordering hazard. Only a *future
  app-level page encryption* would risk defeating deflate, and only if
  mis-ordered (it must run after `flush_writer`'s deflate). Either way,
  raw-byte denomination keeps every guarantee safe; this only affects
  whether margin exists. NB: disk+SSE is an at-rest baseline only — it
  does NOT give provider-blind logs / per-tenant crypto isolation /
  crypto-shred, which is what `project_observability_split`'s
  "page-encrypted" property requires; that remains demand-gated.
- **Size `k` (the per-request floor, below) on uncompressed
  overhead** — header + sidecar + raft entry — same worst-case logic.

Byte-rate is also close to a *universal* cost currency here: those bytes
are downstream of raft entry size, fsync budget, S3 PUT volume, and the
~117 MB/s NIC egress ceiling (`project_s3_throughput_ceiling`).
Throttling them incidentally protects all of those at once.

Three implementation realities:

- **Price the per-request floor too**, or count-heavy/byte-light floods
  slip through. A flood of tiny requests is byte-cheap but still pays
  fixed overhead (64 B header + ~250 B sidecar + a raft entry + an fsync
  slot, every time). Throttle on
  `effective_bytes = actual_bytes + k·count` so every request costs at
  least `k`. This folds the old req/s guardrail and the new byte
  guardrail into one byte-denominated bucket.

- **Enforcement = lagging token bucket → admission 429, not
  log-dropping.** We can't drop a served request's log without breaking
  the replay guarantee, so the throttle must refuse *traffic* when the
  sustained byte-rate is exceeded. Wrinkle: the full log cost (the
  readset — kv reads, fetch bodies pulled in) is known only *after* the
  handler runs, and a handler can pull a 50 MB fetch into its readset
  that the inbound size never hinted at. So debit the bucket
  *post-execution* (it may go negative) and throttle the *next* request;
  lean on the existing per-request hard caps (50 MB response, 16 MB
  batch, 1 MB inbound coalesce) to bound single-shot overshoot. Two
  mechanisms: hard caps bound one request, the byte-bucket bounds
  sustained rate.

- **It's hot-path-safe.** A per-tenant token bucket is O(1) per request
  (one keyed lookup + an atomic), not an O(N_tenants) scan. The
  no-per-tenant-work rule is about sweeping all tenants, not touching the
  one in front of you. This composes directly with the existing
  `src/js/limiter.zig` token-bucket machinery — add a `log_bytes` action
  alongside the existing `request` / `outbound` pair.

**Residual gap:** a genuinely CPU-heavy, byte-light handler (lots of
compute, tiny readset) stays under-priced even with the `k·count` term.
Acceptable to ignore pre-launch — but it's the one workload this
guardrail doesn't catch, so note it rather than assume bytes covers
everything.

## 7. The tier as a (kv, storage, days, rate) quadruple

A tier is therefore an honest quadruple, where the last two fix the
derived ceiling:

```
tier = {
  kv_max_bytes:        <axis 1 — hard cap, throttle→upgrade at limit>
  stored_max_bytes:    <axis 3 — hard cap on customer objects>
  retention_days:      <axis 2 — the sold replay window; deletion, not a clamp>
  log_max_ingest_rate: <bytes/sec, incl. k·count overhead>
  ⇒ log_capacity      = log_max_ingest_rate × 86400 × retention_days
                        + log_burst_bytes                          (derived, internal — §3)
  ⇒ egress_allowance  = 10 × stored_max_bytes / month              (derived, published, unenforced — §4.3)
}
```

Neither derived row is separately configurable, and they face opposite
directions: the egress allowance is a *ceiling the customer owes us*, and
is published; the log capacity is a *bound we owe ourselves*, and is a
provisioning input the customer never sees. Each falls out of a field
already in the tier, so a tier stays four numbers.

`retention_days` is the field that does two jobs at once — the term in
the DPA and the multiplier on worst-case spend. That coupling is the
point of the model: the promise cannot be quietly enlarged without the
cost moving in the same edit, and the cost cannot be trimmed without
breaking a published term.

**`log_max_ingest_rate` is not yet per-tier.** The shipped
`log_refill_bytes_per_sec` is a uniform 64 KiB/s across free, pro,
enterprise and platform (`src/plan/root.zig`; a test asserts the
uniformity). That was defensible while the rate was purely a
runaway-cost guard, but under this model it is the multiplier on both the
customer's usable traffic and our provisioned bytes — so enterprise is
currently throttled to the same sustained ingest as a free hobby site.
Differentiating it is the one new product number this model needs
(rove#301).

### Reconciliation with the plan-tiers enforcement

The plan-tiers enforcement (folded into `architecture/control-plane.md`; decisions.md §10.9) is the shipped mechanism; this is the model it
enforces. Mapping:

- **Lever 1 (request rate)** → augmented. Keep the limiter, but the
  sharper axis is the `log_bytes` ingest bucket of §6 (with `k·count`
  folding request-rate into it). Request-count rate stays as the cheap
  CPU/ops-axis backstop for the §6 residual gap.
- **Lever 2 (max body size)** → unchanged and complementary. Per-request
  413 gate bounds single-shot overshoot; the §6 bucket bounds sustained
  rate.
- **Lever 3 (tape retention)** → **confirmed as the axis, completed as a
  mechanism.** The shipped Lever 3 is a read-path *time clamp* (return
  only the last N days, no GC). `retention_days` is the right billed
  axis and stays; what it lacks is the deletion behind it. The clamp
  becomes the *read* half of a two-part lever whose *write* half is the
  per-tenant sweep of §3.2 (rove#333) plus the body-pool compactor
  (rove#304). Until the sweep ships, the published window is a promise
  the storage layer does not yet keep — which is a policy exposure, not
  merely an unpaid cost line.

  The clamp keeps one job the sweep must not take over: **a downgrade
  hides immediately but must not destroy for 30 days**
  (`billing-policy.md`, rule 9). So the sweep's horizon is not simply the
  current plan's `retention_days` — it lags a plan drop, and the clamp is
  what makes the lag invisible to the reader.

No new control-plane state is required. The ring model needed per-tenant
resident-byte accounting plus an eviction watermark; a time window needs
neither — object age is already on the object. KV-size and log-bytes
remain readable at the snapshot /
flush seams, so neither adds hot-path work.

## 8. Open decisions / unmeasured assumptions

- **Deflate ratio — margin input, NOT a guarantee input (§6.1).** By
  denominating throttle/provisioning/deletion in raw bytes, no ceiling or
  customer promise depends on the ratio; worst-case (incompressible:
  encrypted, already-compressed, or random payloads, ratio ≈ 1.0) is
  assumed for all guarantees and pricing. The level-1 raw-deflate ratio
  over real records (unmeasured; `architecture/deployment-and-logs.md` defers the benchmark) now
  only tells us our *margin* — how much under the raw quota actual S3
  spend runs. Still worth measuring for capacity planning, but it no
  longer gates correctness. **Caveat:** encryption at rest is deferred;
  the likely transparent baseline (encrypted volume + S3 SSE) sits below
  compression so margin is preserved, but a future mis-ordered app-level
  page encryption would zero the margin (§6.1).
- **Egress on axis 3 — free today, but that is a provider fact, not a
  property of the model.** `blob.url` mints presigned URLs, so customer
  objects serve directly from the object store to the public at whatever
  volume the customer drives, metered by nothing here. On the current
  backend that costs nothing: OVHcloud removed Object Storage egress fees
  effective December 2025 consumption, across all storage classes and
  regions (US included), and lists incoming, outgoing, and internal
  traffic as included. Presigned traffic also bypasses our compute nodes
  entirely, so it does not consume the ~117 MB/s NIC ceiling either.

  A stated allowance rides on top of this regardless — `10 ×
  stored_max_bytes` per month, published from launch and unenforced
  (§4.3) — because the reason to name a number is the promise, not the
  bill. Two residual concerns survive, and neither is COGS:

  - **Portability.** Free egress is an OVH (and R2) property, not an
    industry one — AWS S3 charges roughly $0.09/GB out. A backend move
    would turn a free feature into the single largest line on the bill,
    so treat zero-egress as a constraint on where we can host, not as a
    permanent given.
  - **Promise creep.** Free egress makes the free-CDN outcome *more*
    likely, not less, because the cost signal that would otherwise bound
    it is absent. Decide deliberately whether unbounded public serving is
    part of the offer, since withdrawing it later is a takeaway.
- **`k` (per-request byte floor).** Set against measured fixed overhead
  (header + sidecar + raft entry); needs a real measurement.
- **Per-tier `log_max_ingest_rate` — the one open number this model
  needs.** `kv_max_bytes` / `stored_max_bytes` / `retention_days` are
  decided (`billing-policy.md`, "The launch tiers"); the ingest rate is
  not, and it is uniform in the tree today (§7). It is now a *billed*
  input rather than a guardrail, because it multiplies both the
  customer's usable traffic and the derived ceiling. Choose it against a
  real traffic distribution, and note the enterprise end is where it
  bites: 365 days × a raised rate is the largest COGS figure in the
  model.
- **Backend pricing.** COGS math elsewhere in this doc uses S3-standard
  rates; the live backend is OVHcloud US. Published list price as of
  2026-08-01 is **$0.0081/GB/month** standard and **$0.0203/GB/month**
  high-performance, with no charge for API calls, ingress, or egress —
  materially cheaper than the S3-standard figures the storage-cost
  estimate was built on, so that estimate is conservative. Confirm
  against an actual invoice before it reaches a pricing page; the OVH API
  credential in `~/.config/rove/ovh.env` is currently expired (403
  "This credential is not valid"), so this is list price, not our bill.
- **The bodies compactor.** Per-tenant deletion from the cross-tenant
  `_pool/` batch objects (§3.2, rove#304) is the one substantial new
  build this model requires — scoped to bodies alone, since log records
  are already per-tenant prefixed. Not an open *decision* so much as an
  open *build*, and the one that stands between a published retention
  period and a true one.

## 9. Break-even — how many paying customers cover the platform

Everything above prices *what* to sell. This section is the other
direction: given a price, how many subscribers clear the floor. It is
parameterised rather than tabulated-in-stone, because both inputs move.

**The cost shape is unusual, and it is what makes the answer small.**
Dedicated hardware, zero egress fees, and no per-request cloud billing
mean there is **no meaningful marginal cost per paying customer** — a
tenant that fits on an existing cluster is served by hardware already
paid for. So this is not a per-unit-margin question at all; it is fixed
cost divided by net revenue per subscriber.

```
  N  =  fixed_monthly  /  (price × (1 − payment_fee) − per_txn_fee)
```

- `fixed_monthly` = 3 × server + the small tail (domains, corporate
  filings). Servers dominate by an order of magnitude; object storage is
  rounding error at current volumes ($0.0081/GB/mo, §8) and egress is
  free.
- Payment fees are the only per-subscriber deduction: card processing
  plus subscription billing, roughly 3.4% + $0.30 on the current
  provider's published rates.

At any plausible price point the answer lands in the **low tens of
subscribers** — single digits at a $50+ price, a few dozen at $10.
Substitute the real invoice line before this reaches a pricing page; §8
records that the OVH API credential is expired, so we have list price
rather than our bill.

**Three properties of the curve matter more than its precision:**

- **It is a step function, not a line.** Capacity scales by adding
  *clusters*, not nodes — every tenant's raft group spans all three nodes
  of its cluster, so growth is free until a cluster fills and then costs
  three servers at once. Each step re-runs the same division. Knowing
  where the next step falls is a capacity-telemetry question, which is
  why the size + growth-rate alerting is a pricing input and not only an
  ops one.
- **Free tenants are the variable cost, not paying ones.** The
  free-to-paid ratio decides how soon a step arrives. That is the
  economic return on the per-tenant caps (§2, §4) and the abuse
  gates — they bound what a non-paying tenant can consume before the
  step.
- **This is the infrastructure floor, not the business floor.** No
  salary, support time, or marketing spend is in it. Read it as "what
  the platform costs to keep running", which is the number that decides
  whether the service can exist at low volume — not as a target.
