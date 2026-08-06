# Pricing model — what to sell and why

> **Status**: Design proposal, 2026-06-02; revised 2026-08-01 to add the
> third axis (§4) and correct three claims about the shipped storage
> layout (§2, §3.2). Captures the economic model behind the tiers; the
> *enforcement* mechanism is the plan-tiers enforcement (`architecture/control-plane.md` "Operational state")
> (tier plumbing + per-lever wire-up). This doc is the "what to charge
> for and why" that sits upstream of that one. It **revises** the
> retention lever of the plan-tiers enforcement (`architecture/control-plane.md`) (§Lever 3) from a time-window clamp
> to a capacity ring with a derived time floor — see §7 for the
> reconciliation. Axis 1 (§2) is now built — measured, plan-derived, and
> enforced — while axes 2 and 3 remain proposals; the load-bearing
> unmeasured assumption is the per-record deflate ratio (§8), and §9 is
> the break-even arithmetic those tier numbers get chosen against.

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
| Billing axis 2 | **Replay-log capacity** (the ring) | buy more | evict oldest (FIFO) | LOW per byte, but the product's core durable artifact |
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

## 3. Axis 2 — Replay-log storage as a capacity ring (not a time window)

Every transaction deposits ~1 KB of replay log into object storage
(`{instance}/log-blobs/`, `docs/architecture/deployment-and-logs.md`). So
for any tenant that retains logs, object-storage growth *tracks
transaction volume* — something Lambda/Cloudflare can't price because
they can't see invocations as storage. Here the product literally stores
every transaction, so storage is a legitimate proxy for usage.

This axis covers **platform-generated bytes only**: the replay log and
the recorded request/response bodies it references. Bytes the customer
deliberately stored are axis 3.

The model is **capacity-based retention, not time-based**: you buy N GB
of replay-log space; logs accumulate; when the ring is full the oldest
are evicted (FIFO). Retention *duration* therefore floats with traffic
— a busy site's 500 GB might be 10 days, a quiet site's 10 years.

Why a byte-ring beats a time TTL:

- **Self-regulating; no gaming lever.** There's no retention knob to set
  to zero to dodge storage cost — you bought the bytes, they fill up
  regardless of traffic.
- **COGS is hard-capped and known.** A 500 GB tier is 500 GB of S3,
  fixed. No GB-month integration, no proration, no overage surprises.
  Billing collapses to "under quota? yes/no."
- **It matches how replay value decays.** People debug last week's
  incident far more than last year's. "Always keep the most recent N GB"
  retains the high-value recent data and sheds the low-value tail — the
  *right* eviction policy for a replay product, better than a uniform
  time TTL that keeps stale data and drops nothing preferentially.

### 3.1 The sharp edge — and why we do NOT impose a time cap

A variable window has a rewind-specific failure mode: **a traffic spike
burns the window fastest exactly when its logs matter most.** During an
incident or viral spike, log production jumps, so the window *contracts*
right when you most want to rewind into it — the same shape as
"the request that crashed is the one you can't replay"
(`architecture/effects-and-handlers.md` §1).

The tempting fix is "evict at 90 days OR N GB, whichever first." That is
**strictly worse for the customer** and we reject it. A time number can
play two opposite roles:

- **Time as a cap** (evict at 90 days even if bytes remain) — a
  *takeaway*. Costs us nothing (bytes already bound COGS) and shrinks the
  light customer's deal. It also throws away a marketing asset: a light
  site's 500 GB is ~500 M requests ≈ a decade-plus of history. "Kept
  basically forever unless you get huge" is a selling point, and those
  bytes sit in the ring regardless — capping by default is paying to
  delete our own pitch.
- **Time as a floor** (guarantee ≥90 days even if bytes overflow) — a
  *gift*. Strictly better than pure capacity, but we'd eat the overflow
  (variable COGS) unless that overflow is bounded. §6 is what bounds it.

What a time number actually sells is *removal of uncertainty*, not
bytes. "Unlimited, probably, depends on your traffic" reads as flaky;
"90 days, period" is a commitment customers can plan and audit against.
But that legibility is a **UI problem, not a product one** — solve it
without degrading the deal:

1. **Live replay-horizon display.** "500 GB, currently reaching back to
   March 3 (~14 months); 340/500 GB used." Converts the vague-unlimited
   into a concrete, trustworthy number and doubles as an upsell moment.
2. **Pinning.** Let customers mark an incident's request tree as "keep,"
   exempt from the ring. Neutralizes the worst case (the incident you're
   actively debugging getting evicted mid-investigation) and doubles as
   a save/engagement surface.
3. **Opt-in auto-delete** for the compliance segment that actively
   *wants* deletion (GDPR / data-minimization). A cap they enable, never
   one we impose.

### 3.2 Implementation cost to go in eyes-open

An earlier draft of this section claimed all log batch objects are
cross-tenant fan-in, and concluded that the deferred compacting GC
(`architecture/deployment-and-logs.md` §6.8) becomes mandatory and
continuous for this model. That is **half wrong**, and the correction
materially lowers the price of the ring:

- **Log records are already per-tenant prefixed** —
  `{key_prefix_base}{instance}/log-blobs/`. Reclaiming a tenant's oldest
  log bytes is an ordinary per-tenant FIFO sweep over its own prefix. No
  compaction, no cross-tenant coordination.
- **Request/response bodies are the cross-tenant part** — they batch into
  a shared pool at `{key_prefix_base}_pool/{batch_id}`, so one object
  holds slices belonging to many tenants and cannot be dropped until
  every tenant's slice in it is evictable. This is where the compacting
  GC is genuinely required.

So the compactor is scoped to the **bodies** half, not the whole ring,
and the two halves can ship independently. The open choice for bodies is
compaction (rewrite live slices, keep the S3-request amortisation the
pool exists for) versus per-tenant pools (trivial eviction, lose the
batching win for low-traffic tenants) — decide it on measured pool
occupancy, not taste.

Two further realities to go in eyes-open:

- **Nothing evicts anything today.** No blob GC of any kind exists; the
  only blob delete in the tree is a temp-key cleanup on a failed upload.
  The shipped `retention_days` lever is a *read* clamp — it hides records
  older than the window, it never removes them. So S3 grows without bound
  right now, including data no customer can read.
- **Eviction must be honest at the read surface.** A query for an evicted
  window has to report "beyond your horizon" rather than silently return
  a short result set.

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
- **Measurement is the same machinery as axis 2**, pointed at the
  customer-controlled prefixes instead of `log-blobs/` — a running
  per-tenant byte counter, never an S3 LIST per query.
- **This axis cannot be added later.** Customers accumulate objects
  freely, and a cap imposed after the fact either breaks existing
  customers or gets grandfathered away for exactly the customers who
  matter. That is the same "impossible later" property as axis 1, and the
  opposite of axis 2 — a ring can arrive at any time because eviction is
  prospective. **Axes 1 and 3 gate launch; axis 2 does not.**

### 4.1 Why this is not just more of axis 2

Both axes are S3 bytes, in one bucket, differing only by key prefix.
There is nothing to physically separate — and they still must not share
a metered pool, because they differ in the single property enforcement
turns on: **what happens at the ceiling.**

- **Axis 2 is platform exhaust.** The customer never chose to write a
  replay log; it is a byproduct of being served. FIFO eviction is fair
  *because* of that, and §6's ingest throttle is the matching guardrail —
  we bound what we generate on their behalf.
- **Axis 3 is deliberate customer data.** They called `put` because they
  wanted the object kept, and the documented pattern is to store the hash
  in KV and dereference it later. Evicting it is destroying data they
  asked us to hold.

Merge the pools and you are forced into one of two bad outcomes: evict
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

Two reasons that does not license eviction:

1. **Re-derivation depends on the readset, which axis 2 evicts.** Once
   the source activation's readset ages out of the ring, the output is no
   longer re-derivable either. A cache whose backing is on a FIFO is not
   a durable store.
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
capacity = max_ingest_rate × retention_floor
```

Once byte-ingest is throttled, capacity / rate / floor stop being
independent. **A guaranteed minimum-retention floor becomes free** — not
a promise we might eat overflow to honor, but `capacity ÷ max_rate`,
true by construction. Provision the ring to hold exactly the maximum a
throttled tenant could produce over the floor window, and it physically
cannot be violated.

And it preserves the pure-capacity upside: the floor is the **minimum**,
hit only at **max** rate. A tenant running below their cap overshoots
the floor for free — busy tenants get a guaranteed minimum, quiet
tenants still get "basically forever," at zero extra COGS. This is the
synthesis that reconciles §3's pure-capacity model with a legible floor
promise.

Note this guardrail bounds **axis 2 only.** It throttles what the
platform writes on the customer's behalf. Axis 3 needs no rate
guardrail — a customer storing their own objects is bounded by the axis-3
quota directly, and refusing at the ceiling is the whole mechanism.

### 6.1 Denominate everything in RAW bytes — the floor must not depend on deflate

The identity only holds if both sides are the same unit, and the
dangerous trap is metering the throttle in *ingested* (raw) bytes while
sizing the ring in *stored* (post-deflate, on-S3) bytes — the conversion
between them is the compression ratio. Size the floor assuming, say, 2×
compression and a customer sending **encrypted / already-compressed /
random payloads (ratio ≈ 1.0)** fills the ring twice as fast as modeled
and gets *half* the guaranteed floor. The guarantee silently breaks for
exactly the adversarial input.

Fix: denominate **quota, throttle, and eviction all in raw ingest
bytes.** Then the ratio drops out of the guarantee entirely —
`floor = capacity_raw ÷ max_rate_raw`, exact for any input, including
incompressible. Consequences:

- **COGS** `= raw_resident × actual_ratio ≤ capacity_raw`. Price as if
  1 raw GB = 1 S3 GB (the incompressible worst case); **compression is
  pure unmodeled margin** — it lowers the bill, never a dependency we can
  be wrong about. The ring being a fixed raw-byte cap means worst-case
  S3 spend is bounded regardless.
- **Customer-facing** "500 GB of logs" means *bytes you sent* — the most
  intuitive denomination anyway, since a customer can't predict our
  deflate but knows what they pushed.
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

## 7. The tier as a (kv, storage, capacity, rate) quadruple

A tier is therefore an honest quadruple, where the last two fix the
derived floor:

```
tier = {
  kv_max_bytes:        <axis 1 — hard cap, throttle→upgrade at limit>
  stored_max_bytes:    <axis 3 — hard cap on customer objects>
  log_capacity_bytes:  <axis 2 — the replay-log ring size>
  log_max_ingest_rate: <bytes/sec, incl. k·count overhead>
  ⇒ retention_floor   = log_capacity_bytes / log_max_ingest_rate  (derived, displayed)
  ⇒ egress_allowance  = 10 × stored_max_bytes / month             (derived, published, unenforced — §4.3)
}
```

Both derived rows are published, and neither is separately configurable:
the retention floor is a *guarantee* we owe the customer, the egress
allowance is a *ceiling* they owe us. Each falls out of a field already
in the tier, so a tier stays four numbers.

Surface the *derived* floor in the live-horizon UI: "500 GB at 64 KB/s
⇒ ≥90 days guaranteed, ~14 months at your current traffic." Legible, a
real commitment, light sites still win, costs nothing beyond the
capacity already sold.

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
- **Lever 3 (tape retention)** → **revised.** the shipped Lever 3 fakes
  retention as a read-path *time clamp* (return only the last N days,
  no GC). This doc replaces that with a **capacity ring + derived time
  floor**. The read-path clamp is fine as a launch stopgap (instant,
  reversible, no GC), but the billed axis is *bytes of capacity*, not
  *days*, and the real eviction is the per-tenant sweep of §3.2. When
  that ships, the time-clamp retires. **Until it does, `retention_days`
  is both the enforced and the advertised retention mechanism** — the
  pricing page sells days, not a byte floor, and switching the two is a
  later revision of the page.

New control-plane state (beyond the plan axis `plan/{tenant}`): per-tenant
resident-byte accounting for both storage axes, plus the ring's eviction
watermark. KV-size and log-bytes are both readable at the snapshot /
flush seams, so neither adds hot-path work.

## 8. Open decisions / unmeasured assumptions

- **Deflate ratio — margin input, NOT a guarantee input (§6.1).** By
  denominating quota/throttle/eviction in raw bytes, no floor or
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
- **Concrete tier rows.** `kv_max_bytes` / `stored_max_bytes` /
  `log_capacity_bytes` / `log_max_ingest_rate` per named tier — a product
  call, gated on the axis-1 and axis-3 measurements landing first so the
  numbers are chosen against a real distribution. The shipped
  `max_kv_bytes` is a uniform 1 GiB placeholder; per §2 that is not a
  ceiling the engine imposes, so the axis-1 figure is chosen from expected
  usage and blast radius rather than from `disk ÷ tenants`.
- **Backend pricing.** COGS math elsewhere in this doc uses S3-standard
  rates; the live backend is OVHcloud US. Published list price as of
  2026-08-01 is **$0.0081/GB/month** standard and **$0.0203/GB/month**
  high-performance, with no charge for API calls, ingress, or egress —
  materially cheaper than the S3-standard figures the storage-cost
  estimate was built on, so that estimate is conservative. Confirm
  against an actual invoice before it reaches a pricing page; the OVH API
  credential in `~/.config/rove/ovh.env` is currently expired (403
  "This credential is not valid"), so this is list price, not our bill.
- **The bodies compactor.** Per-tenant eviction over the cross-tenant
  `_pool/` batch objects (§3.2) is the one substantial new build this
  model requires — and it is scoped to bodies alone, not to the whole
  ring.

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
