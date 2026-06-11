# Pricing model — what to sell and why

> **Status**: Design proposal, 2026-06-02. Captures the economic model
> behind the tiers; the *enforcement* mechanism is the plan-tiers enforcement (`architecture/control-plane.md` "Operational state")
> (tier plumbing + per-lever wire-up). This doc is the "what to charge
> for and why" that sits upstream of that one. It **revises** the
> retention lever of the plan-tiers enforcement (`architecture/control-plane.md`) (§Lever 3) from a time-window clamp
> to a capacity ring with a derived time floor — see §6 for the
> reconciliation. Nothing here is built; the load-bearing unmeasured
> assumption is the per-record deflate ratio (§7).

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

We sell **two billing axes** and back them with **one new guardrail**
(plus the rate/body levers already specced in the plan-tiers enforcement (`architecture/control-plane.md`)):

| | What | Role | Scarcity |
|---|---|---|---|
| Billing axis 1 | **Max KV size** | buy more | HIGH — raft-replicated, RAM/fsync-bound, on the hot path |
| Billing axis 2 | **Object-storage capacity** (replay-log ring) | buy more | LOW per byte, but the product's core durable artifact |
| Guardrail | **Log-byte ingest rate** | bound, not billed | the universal cost currency (see §5) |

Why these are the right two axes — and not "requests" — is the rest of
this doc.

## 2. Axis 1 — Max KV size

Per-tenant `app.db` lives in raft: replicated to every node in the
group, held in the kvexp/LMDB overlay, and on the latency-critical
path. It is the one resource we genuinely *cannot* make elastic, so
pricing on it is pricing on real marginal cost. This is the strong
axis.

- **Define it as logical committed bytes**, not raw `app.db` file size.
  SQLite free pages, pre-VACUUM bloat, and WAL make file size jump
  around and produce billing disputes we'd lose.

- **Overage semantics = throttle → upgrade, never elastic billing.**
  KV is RAM/raft-bound; at some point we physically cannot honor more
  without OOM-ing a node and hurting every co-tenant. So at the cap, go
  read-only / reject writes and prompt an upgrade. Selling "unlimited KV
  at $X/GB" writes a check the cluster can't cash. This is the key
  asymmetry vs. axis 2: meter both, bill elastically only on the elastic
  one.

- **Already cheap to measure off the hot path.** The snapshot manifest
  already computes per-tenant `db_size` (`docs/architecture/consensus-and-storage.md`), so
  billing rides an existing seam without violating the
  no-`O(N_tenants)`-on-dispatch rule.

## 3. Axis 2 — Object storage as a capacity ring (not a time window)

Every transaction deposits ~1 KB of replay log into object storage
(`_logs/...`, `docs/architecture/deployment-and-logs.md`). So for any tenant that retains
logs, object-storage growth *tracks transaction volume* — something
Lambda/Cloudflare can't price because they can't see invocations as
storage. Here the product literally stores every transaction, so
storage is a legitimate proxy for usage.

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
  (variable COGS) unless that overflow is bounded. §5 is what bounds it.

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

Capacity-based per-tenant eviction is meaningfully harder than
time-based, because log batch objects are **cross-tenant fan-in**
(`flush_writer` bundles many tenants' records into one
`_logs/.../{batch}.ndjson` PUT). You can't reclaim a tenant's oldest
bytes by deleting a batch object — it holds other tenants' records too.
So precise per-tenant eviction *requires* the compacting GC rewrite that
`architecture/deployment-and-logs.md` §6.8 currently lists as deferred — and makes it
**mandatory and continuous**, not a someday-nicety. Time-based, by
contrast, can drop whole objects past their newest record's TTL, or even
be a plain S3 lifecycle rule. That compactor is the real price of this
model; scope it before committing the pricing page to capacity.

## 4. Why not price "requests" / transactions directly

Per-request billing is the surprise-invoice customers hate, and it
fights our no-`O(N_tenants)`-on-the-hot-path rule (a per-request meter
keyed by tenant is exactly the per-tenant hot-path accounting we keep
out). The storage axes are measurable at existing batch/snapshot seams;
a transaction counter is not. So we never put transactions on the
invoice — we bound them with a guardrail instead (§5).

## 5. Guardrail — throttle log-byte *ingest rate* (the keystone)

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

### 5.1 Denominate everything in RAW bytes — the floor must not depend on deflate

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
  It is a margin / capacity-planning input only (§7).

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
- **Size `k` (the per-request floor, §5 below) on uncompressed
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
  alongside `request` / `email`.

**Residual gap:** a genuinely CPU-heavy, byte-light handler (lots of
compute, tiny readset) stays under-priced even with the `k·count` term.
Acceptable to ignore pre-launch — but it's the one workload this
guardrail doesn't catch, so note it rather than assume bytes covers
everything.

## 6. The tier as a (capacity, rate, floor) triple

A tier is therefore an honest triple where any two fix the third:

```
tier = {
  kv_max_bytes:        <hard cap, throttle→upgrade at limit>
  log_capacity_bytes:  <the replay-log ring size>
  log_max_ingest_rate: <bytes/sec, incl. k·count overhead>
  ⇒ retention_floor  = log_capacity_bytes / log_max_ingest_rate   (derived, displayed)
}
```

Surface the *derived* floor in the live-horizon UI: "500 GB at 64 KB/s
⇒ ≥90 days guaranteed, ~14 months at your current traffic." Legible, a
real commitment, light sites still win, costs nothing beyond the
capacity already sold.

### Reconciliation with the plan-tiers enforcement

The plan-tiers enforcement (folded into `architecture/control-plane.md`; decisions.md §10.9) is the shipped mechanism; this is the model it
enforces. Mapping:

- **Lever 1 (request rate)** → augmented. Keep the limiter, but the
  sharper axis is the `log_bytes` ingest bucket of §5 (with `k·count`
  folding request-rate into it). Request-count rate stays as the cheap
  CPU/ops-axis backstop for the §5 residual gap.
- **Lever 2 (max body size)** → unchanged and complementary. Per-request
  413 gate bounds single-shot overshoot; the §5 bucket bounds sustained
  rate.
- **Lever 3 (tape retention)** → **revised.** the shipped Lever 3 fakes
  retention as a read-path *time clamp* (return only the last N days,
  no GC). This doc replaces that with a **capacity ring + derived time
  floor**. The read-path clamp is fine as a launch stopgap (instant,
  reversible, no GC), but the billed axis is *bytes of capacity*, not
  *days*, and the real eviction is the per-tenant compactor of §3.2.
  When that compactor ships, the time-clamp retires.

New control-plane state (beyond the plan axis `plan/{tenant}`): the ring
needs per-tenant resident-log-bytes accounting and the eviction
watermark. KV-size and log-bytes are both readable at the snapshot /
flush seams, so neither adds hot-path work.

## 7. Open decisions / unmeasured assumptions

- **Deflate ratio — margin input, NOT a guarantee input (§5.1).** By
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
  page encryption would zero the margin (§5.1).
- **`k` (per-request byte floor).** Set against measured fixed overhead
  (header + sidecar + raft entry); needs a real measurement.
- **Concrete tier rows.** `kv_max_bytes` / `log_capacity_bytes` /
  `log_max_ingest_rate` per named tier — a product call, gated on the
  deflate measurement.
- **Backend pricing.** COGS math here uses S3-standard rates; the live
  backend is OVH (`reference_s3_smoke_env`). Plug in OVH GB-month + PUT
  pricing for the real bill; order of magnitude is similar.
- **The compactor.** Per-tenant log GC over cross-tenant batch objects
  (§3.2) is the one substantial new build this model requires.
