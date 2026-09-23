# Backup and restore

Three raft nodes in one datacenter is replication, not backup. Raft protects
against a node dying; it faithfully replicates a bad apply, an operator
mistake, a bug that corrupts state, and a `DELETE` a customer regrets. The
nodes share a building, a network, a power feed, an object-storage account,
and an operator with `rm`.

So there is a second copy, in a store the cluster's own credentials do not
reach, and it is restored on a schedule — because an untested backup is a
belief, not a control.

## The shape

    rewind-backup run      → per tenant: POST /_system/v2-backup on its leader
                             → the worker streams a held snapshot to the
                               backup store
                           → manifest.json, written LAST
    rewind-backup verify   → re-read every object; size, sha256, framing
    rewind-backup restore  → GET the object → POST /_system/v2-snapshot-stream
                             on a destination node

**Neither direction invents a format or an apply path.** The bytes are what a
tenant MOVE ships — the worker's `StreamDumper` over a held snapshot — and a
restore is the request a move's destination already serves. Both sides run in
production on every move and every raft catch-up, rather than being exercised
for the first time on the worst day of the year.

The upload runs on the off-loop snapshot driver, the same thread a move push
uses, for the same reason: a held snapshot pins LMDB pages for the duration of
the transfer, so it must not run on the poll loop, and the page-pinning
deadline (`REWIND_SNAPSHOT_XFER_MAX_MS`) bounds it.

## Separate store, separate credentials

The backup target is its own store (`BACKUP_S3_*`, read through the same
loader as `S3_*` so the two contracts cannot drift), never a prefix in the
live bucket. A backup reachable by the credentials that address the data it
protects does not survive the scenarios that motivate keeping one: a
compromise, a billing dispute, an operator mistake with broad reach.

It is deliberately **not namespaced**. The live keyspace is scoped to the
storage generation so a wiped cluster cannot re-issue ids over a previous
lifetime's keys — but a backup exists to be read *after* exactly that kind of
event, and a restore that could not find the objects of the generation it is
recovering from would be no restore at all.

`rewind-backup` holds the backup credentials and the move secret; it never
needs the cluster root token. The thing that can read every tenant's state out
of the cluster is not also the thing that can deploy code into it.

## Storage identity is part of the backup

A tenant's pairs are addressed by a store id derived from its **storage
incarnation** — a random token minted at provision and recorded in the CP
directory. A dump therefore only makes sense against a group attached under
the same incarnation, which is why the manifest records it per tenant and why
`restore` is a two-step operation: attach the tenant under the recorded
incarnation, then stream.

Two things enforce that rather than trusting it:

- The **loader refuses a mismatched stream at the header**
  (`LoaderOptions.expect_store_id`), before a single pair is applied, and the
  door answers 409. Without the guard the load reports success and the
  destination reads back empty — a restore that says it worked.
- A run writes **no manifest** unless every tenant in it succeeded. A manifest
  is the claim that a set is restorable; a partial run has no business making
  it, and `verify` refuses a run that has none.

## What a run contains

    {prefix}{run_id}/manifest.json       run id, and per tenant:
                                         key, bytes, sha256, store_id,
                                         incarnation
    {prefix}{run_id}/tenants/{id}.snap   one held-snapshot dump per tenant

Run ids are `YYYYMMDDTHHMMSSZ` by default, so they sort lexically — which is
what makes listing and a retention sweep simple.

## What is not covered yet

Stated plainly, because a backup whose coverage is assumed rather than known
is the failure this document exists to prevent. Each is a leaf of rove#341:

- **Per-tenant keyring shards** (`{keyring_dir}/{tenant}/`) are node-local
  files, not raft state. Values sealed under a tenant key stay sealed in a
  restored store without them. They are KEK-sealed, so backing them up keeps
  the backup ciphertext-only — but it also means a restore could resurrect a
  key that a crypto-shred destroyed, which is a policy question (the erasure
  claim in rove#592) before it is a code one.
- **The CP directory rows** — placement, incarnation, plan. The incarnation in
  particular is what a restore must attach under, so today it survives only
  because the backup manifest copies it.
- **The object store** — bundles, static assets, log and tape batches. These
  are content- or id-addressed and survive a cluster wipe, but not the loss of
  the provider account.
- **A schedule, a retention policy, and a scheduled restore test.** The test
  that exists today is `scripts/smoke/backup_restore_smoke_v2.py`, which
  restores into a second cluster and reads the value back on every suite run.
  What is missing is the same thing running against production data on a
  timer, and a stated RPO/RTO derived from it.

## Recovery-point reality today

A backup reflects the leader's committed state at the moment the snapshot was
opened, so the recovery point is "when the run took that tenant", and the
recovery time is dominated by re-attaching tenants and streaming them back.
Neither is a number worth publishing until the schedule and the restore test
exist — and no customer-facing document should claim one before then.
