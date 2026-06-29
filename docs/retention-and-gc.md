# Retention & garbage collection — the one compacting GC

> 📋 **Design / plan (unbuilt).** Retention and reclamation across every
> durable byte-store rove keeps: log-blobs, kv pages, the `_pool/` body
> batches, and replay tape blobs. It is **one mechanism** — a per-tenant
> compacting GC over cross-tenant batch objects — not four. This doc
> consolidates threads previously scattered across
> [`pricing-model.md`](pricing-model.md) (the capacity model + the
> "compacting GC rewrite"), [`decisions.md`](decisions.md) (§3.6 the
> tape-retention axis, §3.8 the blob delete/GC + pinning openness), and
> [`architecture/deployment-and-logs.md`](architecture/deployment-and-logs.md)
> §6.8 (no log compactor yet). The replay-tape angle was the trigger:
> tape-minimization left **GC + retention-pinning** as its sole open item,
> which is not tape-specific and belongs here. The effect-model frame is
> [`effect-algebra.md`](effect-algebra.md) L3; the four tape record kinds
> are `decisions.md` §3.9.

## 1. Why one mechanism, not four

Four byte-stores accumulate per tenant, and the naive "delete the oldest
object" reclaim fails the same way on three of them:

| Store | Object shape | Why per-tenant delete is hard |
|---|---|---|
| **log-blobs** | `_logs/.../{batch}.ndjson` | **cross-tenant fan-in** — `flush_writer` bundles many tenants' records into one PUT; you can't drop a tenant's oldest bytes by deleting a batch (it holds others') |
| **`_pool/` body batches** | `_pool/{batch_id}` | same cross-tenant fan-in (the coordinator collapsed per-(tenant,worker) lanes into one global `_pool/` prefix); referenced by `BodyRef{batch_id,offset,len}` extents in live tapes |
| **kv pages** | LMDB pages in `{id}/app.db` | per-tenant already, but reclaim is the engine's page reuse, not object delete |
| **tape blobs** | readset entries + their CAS-extent targets | a tape is only reclaimable once past its tenant's retention window AND no longer the input-home for anything live |

The shared hard part is the cross-tenant batch object: precise per-tenant
eviction **requires** a compacting rewrite (read live records out of a
batch, re-pack into a fresh batch, delete the old one), not an object
delete. That compactor is the real cost of the capacity-based pricing
model (`pricing-model.md` §3.2) and the missing piece behind the
"no retention/GC compactor yet" limitation
(`architecture/deployment-and-logs.md` §6.8). Building it once serves all
four stores; building four bespoke reclaimers is the anti-pattern this doc
exists to prevent.

## 2. The retention model (locked — see pricing-model.md)

Capacity-based, not time-based: a tenant buys N GB of stored bytes; the
retention *floor* is derived, not set
(`pricing-model.md` §3, §5). The keystone identity:

```
capacity = max_ingest_rate × retention_floor
```

Once byte-**ingest** is throttled (the guardrail, `pricing-model.md` §5),
capacity / rate / floor stop being independent and a guaranteed minimum
retention floor becomes free — `capacity ÷ max_rate`, true by
construction. The compactor is what makes capacity-based eviction
*enforceable* per tenant; without it, retention can only be faked as a
read-path time clamp (`pricing-model.md` §Lever 3, the shipped stopgap).

**This doc does not re-decide the pricing model** — it owns the
*reclamation engine* that model assumes.

## 3. The pinning obligation — GC must never orphan a live input

Some objects are not just *stored output* a tenant might want to keep —
they are the **input home** that a replay tape references. Deleting one
past tape retention is fine; deleting one a *live* tape still points at
makes that tape unreplayable. Every input-home class must be **fenced
against GC** until the tapes referencing it expire:

- **`_pool/` body batches.** A `fetch_responses` chunk over the inline
  threshold lives in `_pool/{batch_id}`; the tape carries a
  `BodyRef{batch_id, offset, len}` extent (the shipped tape-by-reference
  mechanism — `rove-bodies`, `decisions.md` §3.9). The batch must outlive
  every tape that extents into it. This is the obligation tape-minimization
  flagged as its one remaining infrastructure piece.
- **Sealed CAS segments** (`segments.js`, `decisions.md` §3.8). A sealed
  segment is **durable-class, not cache-class**: once the hot kv rows are
  deleted it is the sole copy past tape retention. The hot-row delete is
  already gated on the confirmed PUT; GC of the segment must be fenced the
  same way.
- **Customer blob objects** (`app-blobs/{hash}`). `decisions.md` §3.8
  leaves delete/GC deliberately open: "any delete must be fenced against
  tape retention where the object is an input home." Day-one defensible
  default is **no delete**.

The mechanism need not be new: `rove-files`' `TenantFilesSnapshot` already
does refcount-pinned snapshots. The pinning here is a **refcount edge**
from a live tape to the blob it references, not new machinery — but it is
unbuilt, and it is the safety-critical invariant of this whole doc. A GC
that can reap a referenced input home is a correctness bug, not a cost
knob.

## 4. The `tape_mode` retention lever (deferred knob)

`decisions.md` §3.6 removed the per-chain tape cap (its worst case is
already bounded by sequential commit latency) and named per-tenant
**retention/sampling** as the correct axis instead. The deferred knob:

| Mode | Behavior |
|---|---|
| `always` | every activation taped (today's only behavior) |
| `on_exception` | tape retained only for chains that threw |
| `sampled` | retain a configurable fraction |
| `never` | replay disabled for this tenant |

This composes with the plan-level capacity cap: `tape_mode` controls *what
gets written*, the compactor + floor control *how long it survives*. It is
the right place to add tape-cost control when storage bills earn the
optionality — not before.

## 5. Status & open questions

**Unbuilt.** Nothing in this doc ships today; the read-path time clamp
(`pricing-model.md` §Lever 3) is the only retention behavior live, and it
is explicitly a stopgap.

Locked:
- One compacting GC over cross-tenant batches serves all stores (§1).
- Capacity-based retention with a derived floor (§2, `pricing-model.md`).
- Input-home objects must be pinned against GC (§3) — safety-critical.

Open:
- **Refcount-edge mechanism**: how a live tape pins its `_pool/` /
  segment / blob extents, and how that edge is dropped at tape expiry
  (candidate: reuse `TenantFilesSnapshot` refcounting).
- **Compactor scheduling**: continuous vs. watermark-triggered; where it
  runs (leader-local? a CP-driven sweep?); how it avoids the
  `O(N_tenants)`-on-the-hot-path rule.
- **kv page reclaim** vs. LMDB's own free-list — whether tenant eviction
  needs anything beyond db-level reclaim.
- **Orphan-batch janitor** (`deployment-and-logs.md` §6.8) — batches no
  live tenant references at all, distinct from per-tenant eviction.
- `tape_mode` surface: per-tenant config home + default.
- Customer `blob.delete(hash)` + customer-owned refcounting
  (`decisions.md` §3.8 open).
