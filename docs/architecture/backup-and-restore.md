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

## The keyring travels with the dump

Every value a tenant sealed under `shredKey` is ciphertext in the store dump,
and the keys that open it are **not raft state**: they are node-local files
under `{data_dir}/keyrings/{hash(tenant)}/` — a secret plus one file per shard
— rewritten whole and sealed under the cluster KEK. A backup that copied only
the store would restore a tenant whose rows are all present and all
unreadable, and report success doing it.

So a run copies them too, verbatim: `{prefix}.kr` for the secret,
`{prefix}.shard-{8 hex}` for each shard, named in the manifest. A restore
POSTs each to `/_system/v2-keyring-restore`, the sibling of the
`v2-keyring-shard` door that replicates a freshly minted shard between peers.
Both verify under the destination's KEK before anything lands — an unverified
install poisons a node silently and surfaces at a failover, which is exactly
when that copy becomes the only copy.

**Nothing is ever decrypted to make the copy.** The bytes that leave are the
bytes on disk, which is what keeps the backup ciphertext-only: it is inert
without `REWIND_KEYRING_KEK`, and that lives in SOPS, never in the backup
store. Two factors, separated by construction — which is the property that
makes shipping this off-provider defensible at all.

### Why a restore cannot undo an erasure

Holding keys in a backup raises the obvious question: an old backup's shard
still contains a key the tenant has since destroyed, so does restoring it
bring the key back? No — and the reason is the split crypto-shredding already
makes. A destroy carries no key material, so it rides the tenant's **raft
log** as `_keys/dead/{slot}`; the key itself never does. The tombstone is
therefore part of the store dump, and `TenantKeys.open` reconciles against it
before anything can reach the keyring: any slot with a tombstone is evicted
and its shard rewritten without it.

That makes the restore **order** load-bearing rather than stylistic:

    store dump first  →  the tombstones are present
    keyring second    →  the first open reconciles against them

`rewind-backup restore` does both in that order in one command. Reversing them
would leave a window where the keyring is open and the tombstones are not yet
there, and reconciliation does not re-run on its own. The interlock is pinned
by a test in `tenant_keys.zig` that fails if reconciliation is skipped.

## The directory says where a tenant belongs

A tenant's pairs are addressed by a store id derived from its **storage
incarnation** — a random token minted at provision and recorded in the CP
directory, alongside its placement and its plan. Lose the CP's raft state and
every restored tenant is data with no identity: nothing says which cluster it
belongs to, nothing says what to attach it under.

So a run captures the directory rows first — it is the smallest object in the
run and the one that makes the rest meaningful, and capturing it first means a
run that cannot reach the CP fails before spending twenty minutes streaming
stores. `POST /_control/directory-dump` returns them as base64 values (the
rows are opaque; nothing in the copy path should start caring what a plan blob
means), and `/_control/directory-restore` puts them back.

`rewind-backup run` **requires `--cp`** unless `--no-directory` is passed. An
operator may take tenant-data-only backups, but has to say so out loud: the
alternative is a run that silently restores tenants nobody can place.

### What the dump leaves out, and why

`Directory.BACKUP_AXES` is the list, and everything in a dump is something the
restore will apply — a dump carrying rows the restore refuses reads like data
that was saved when it was not. Three axes are absent:

- **`cluster/` and `node/`** are topology, not tenant state. A cluster rebuilt
  after a loss has its own node addresses, and restoring the dead ones would
  point the directory at hosts that are gone. They come from config, which is
  where the operator already declares them; placement references a cluster by
  logical id, so a rebuild that keeps the ids restores cleanly.
- **`cert/`** holds custom domains' private keys in the clear — the directory
  has no KEK to seal them under, and the backup store is off-provider by
  design. A certificate re-issues over ACME at the cost of rate limits
  (rove#269 measured exactly that); a private key copied somewhere it need not
  be is not undoable. **The backup holds no key material it cannot seal.**

### A restore is for a rebuilt control plane

`/_control/directory-restore` refuses (409) when the directory already places
tenants. Run against a live CP it would overwrite the placements, plans and
incarnations of tenants that are serving — which is not a restore, it is an
outage with a manifest.

Order, end to end:

    restore-directory   →  the rebuilt CP can place tenants again
    attach each tenant  →  at the incarnation the directory now holds
    restore each tenant →  store dump, then keyring

## What is not covered yet

Stated plainly, because a backup whose coverage is assumed rather than known
is the failure this document exists to prevent. Each is a leaf of rove#341:

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
