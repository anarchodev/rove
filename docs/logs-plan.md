# Logs plan — S3-direct + sidecar index

This document expands `docs/PLAN.md` §2.9 (Logs + observability) into
an implementable plan and supersedes the current "log batch through
raft + per-tenant `log.db` on every node" model. The motivating
framing: logs have *different durability + consistency requirements*
than kv writes, and forcing them through the same machinery (raft
envelope type 1, follower-applied SQLite stores) overpays for
guarantees the product doesn't need.

Stated semantics for logs in this design:

- **Lossy on node failure.** A node crash drops at most one in-flight
  batch (the one buffered in memory but not yet flushed to S3).
- **Eventually visible.** New log records appear in the dashboard
  within ~10s p95 (worker flush interval + indexer poll).
- **Cross-node mergeable.** A query for "tenant X's last 100 requests"
  returns records from every node that handled traffic, in the right
  newest-first order.
- **Retention-bounded.** Default 30d (matches the existing tape TTL);
  per-tenant override later.
- **Searchable on a small fixed set of columns.** `tenant_id`,
  `received_ns`, `status`, `outcome`, `path`, `method`, `host`,
  `duration_ns`, `deployment_id`. Full-text search over console /
  exception text is out of v1 scope.

---

## 1. Architecture

```
┌──────────┐  flush batch  ┌─────────────────────────────────────────┐
│  worker  │──────────────▶│  S3 bucket                              │
│ (any     │   .ndjson     │   _logs/{node_id}/{batch_id}.ndjson     │
│  node)   │   .idx.json   │   _logs/{node_id}/{batch_id}.idx.json   │
└──────────┘               └─────────────────────────────────────────┘
                                  ▲                          ▲
                                  │ poll LIST + GET          │ ranged GET
                                  │ (.idx files only,        │ (on record show
                                  │  background task)        │  click-through)
                                  │                          │
                                  └────────┬─────────────────┘
                                           │
                                ┌──────────┴────────────────┐
                                │  log-server                │
                                │  (single process,          │
                                │   own subdomain            │
                                │   logs.{public_suffix},    │
                                │   own TLS, token-handoff   │
                                │   auth — same shape as     │
                                │   sse-service)             │
                                │                            │
                                │   log_index.db (local      │
                                │   SQLite; rebuildable      │
                                │   from S3 at any time)     │
                                └──────────┬─────────────────┘
                                           │ HTTPS
                                           ▼
                                ┌────────────────────────┐
                                │ dashboard / customer JS│
                                │ (token from app domain)│
                                └────────────────────────┘
```

**Single binary, single hostname.** What was originally sketched as
two processes (a background indexer + a per-node log-server with
fan-out) collapses to one process: the polling-and-indexing loop and
the HTTP query API live together, the index lives next to them in
local SQLite, the public surface is one subdomain. Same architectural
shape sse-service ended up at — single instance, LB+restart for
failover, no cross-replica coordination.

S3 is the **only** coupling point between worker and log-server.
Worker writes batches; log-server reads them. Neither knows the other
exists at runtime beyond the S3 bucket. Both can be killed and
restarted at will. log-server's local SQLite is recoverable from S3
on any startup — `last_seen_key` is just a steady-state-polling
optimization, not a crash-recovery dependency.

---

## 2. Data model

### 2.1 Object naming

```
_logs/{node_id}/{batch_id}.ndjson     ← record bodies (per-record raw-deflate frames)
_logs/{node_id}/{batch_id}.idx.json   ← index sidecar
```

- `_logs/` is a cluster-scoped top-level prefix (the batch store also
  takes an optional `LOG_S3_KEY_PREFIX` configured at process start, so
  the fully-qualified key is `{LOG_S3_KEY_PREFIX}_logs/...`).
  Cluster-scoped, not per-tenant: a single batch contains records from
  every active tenant on the writing node — tenant discrimination
  lives in the per-record sidecar entries (§2.3), not in the key path.
- `node_id` is the raft node id (u32, zero-padded to 8 hex chars) so
  concurrent uploads from different nodes don't collide and lexical
  iteration walks `(node, time)` order per node.
- `batch_id` is `{first_request_id:020d}-{flush_unix_ms:013d}`.
  Zero-padded so lexical sort = chronological per node. The leading
  `request_id` makes "last batch I indexed for this node" trivially a
  string comparison; the trailing timestamp disambiguates if a node
  ever resets request_id allocation.

**Why no `{tenant}/` prefix.** An earlier sketch led with `tenant_id`
so per-tenant LIST + retention delete were one prefix scan. That made
the write side O(active-tenants-on-node) PUTs per flush — a node
serving 50 tenants paid 100 PUTs per flush window. The interleaved
layout collapses that to 2 PUTs per node per flush regardless of
tenant fan-in. Per-tenant queries are served from `log_index.db`
(local SQLite, indexed by `tenant_id`) — the S3 key shape no longer
needs to support per-tenant access patterns. Retention/GC is the
remaining open question; see §6.7.

Lexical iteration of `_logs/` returns `(node, batch)` pairs in
`(node, time)` order; the indexer reads sidecars from any node and
the dashboard's "newest first" comes from the SQLite index, not from
S3 key order.

### 2.2 `.ndjson` payload

The payload is a concatenation of **per-record raw-deflate frames**,
not a single gzip stream and not plaintext ndjson. Each record:

1. Is encoded as a single-line JSON object (the `LogRecord` schema —
   tenant, request, timing, status, plus optional `console`,
   `exception`, and the `tapes.*_b64` channels for replay).
2. Is then deflated through libz with `windowBits = -15` (raw
   deflate, no zlib/gzip header) at level 1, with `Z_FINISH` set so
   each frame's terminating block has BFINAL=1.

Concatenating self-terminating raw-deflate frames produces a single
file where the sidecar's `(offset, length)` per record bounds a
ranged GET to exactly one frame. `/show` does one Range-GET + one
`inflate(Z_FINISH)` to recover the JSON; no whole-batch
decompression is ever needed.

Why libz directly: Zig 0.15.x's `std.compress.flate.Compress.drain`
has `@panic("TODO")` in the tokenization path for inputs above the
lookahead window — fine on toy strings, fatal on real records with
inline base64 tape bytes. We pin libz both ends. (See the
`zig_flate_compress_incomplete` memory note.)

Records within a batch are ordered by ascending `received_ns` (the
worker sorts defensively before encoding, even though same-thread
buffer append order is already in-order). The full record body is
read only on dashboard click-through, never during list/filter.

The `.gz` suffix is gone: raw-deflate frames aren't gzip and the old
suffix would be misleading. Operators with existing `.ndjson.gz`
objects from earlier rollout pre-dating Phase 5.5(a-2) are addressed
in §6.6.

### 2.3 Embedded sidecar header

Each `.ndjson` object opens with a length-prefixed sidecar JSON
blob, then the concatenated raw-deflate frames. The whole batch
lives in **one** S3 object — there is no separate `.idx.json` file.

```
+0         [4 bytes]   sidecar_size_le  (u32, little-endian)
+4         [N bytes]   sidecar JSON     (the structure shown below)
+(4+N)     [M bytes]   raw-deflate frames region
```

Sidecar JSON shape:

```json
{
  "v": 1,
  "node_id": "00000001",
  "batch_id": "00000000000000000042-1730764800000",
  "ndjson_size": 84321,
  "ndjson_sha256": "abc...",
  "first_received_ns": 1730764800000000000,
  "last_received_ns":  1730764802349000000,
  "records": [
    {
      "tenant_id":    "acme",
      "request_id":   42,
      "received_ns":  1730764800000000000,
      "duration_ns":  3100000,
      "method":       "GET",
      "path":         "/api/foo",
      "host":         "acme.loop46.me",
      "status":       200,
      "outcome":      "ok",
      "deployment_id": 7,
      "offset":       0,
      "length":       412
    },
    ...
  ]
}
```

- `ndjson_size` is the size of the **frames region** (the bytes
  after `4 + sidecar_size`).
- `ndjson_sha256` is computed over the same frames region — cheap
  insurance against a partial upload.
- The sidecar's per-record `offset` is **frame-relative** (offset
  into the frames region only). The indexer adds `4 + sidecar_size`
  when populating `log_index.offset` so /show's stored offset is
  file-relative and the read path needs no further math.
- There is no `ndjson_key` in the sidecar (the sidecar lives inside
  the same object it would have pointed at).

The indexer issues a Range-GET of the head of the object (default
512 KB) to read the size prefix + sidecar JSON without fetching the
frames; oversized sidecars trigger a single re-fetch with the exact
size now known. The frames are touched only on dashboard click-
through (one Range-GET + one `inflate(Z_FINISH)`).

---

## 3. Write path

### 3.1 Buffering on the worker

Each worker keeps a single **node-wide** in-memory `LogRecord`
buffer (`NodeLogBuffer`). Every tenant's dispatch tick appends here;
each record carries its own `tenant_id`. Per-tenant `RequestIdMinter`s
still exist for issuing request_ids (chunked-reservation persisted
to the tenant's app.db), but they no longer carry a buffer.

Flush triggers on the combined buffer (whichever fires first):

- **Count:** 1024 records.
- **Bytes:** 1 MiB uncompressed.
- **Time:** 1s since the buffer's first record.

When any threshold trips, `flushLogs` drains the whole buffer and
PUTs one `_logs/{node}/{batch}.ndjson` object — a single PUT per
node per flush window, regardless of tenant fan-in.

Customer dispatch already runs leader-only (followers reply 503 to
tenant traffic and ask the caller to retry against the leader), so a
follower's log buffer should normally be empty. `flushLogs`
nonetheless re-checks `isLeader()` after draining and drops the
records with a warning if leadership flipped mid-tick. Matches the
lossy-on-failure semantics — bounded by however much a single node
buffered between leadership transitions.

### 3.2 Flush ordering

```
0. Drain the node-wide buffer into a combined record list (in-process;
   clears the buffer under its mutex)
1. For each record: encode JSON → raw-deflate frame → append to the
   frames buffer; record (offset, length) in the sidecar's records
   array (frame-relative offsets)
2. Compute sha256 over the frames region
3. Encode the sidecar JSON; compute sidecar_size
4. Build the object: [u32 LE sidecar_size][sidecar JSON][frames]
5. PUT _logs/{node}/{batch}.ndjson — single PUT
```

**Crash before 5** = records stayed in the in-memory buffer and are
lost on the worker that crashed (the drain in step 0 already cleared
them, but they hadn't reached S3). Acceptable per the stated lossy
semantics.

**Crash mid-PUT** = the BatchStore's underlying object semantics
(S3 / fs / mem) make a partial object either invisible (object
never appears) or detectable (size mismatch + truncated sidecar);
the indexer's parse step rejects anything malformed.

### 3.3 Decommissioned (historical)

The legacy "log batch through raft + per-tenant `log.db` on every
node" path was removed during the Phase 5.5(a) rollout. Specifically
gone: envelope type 1 in `src/js/apply.zig` (the comment there
records its retirement); `RaftLogHandle` / `applyLogBatch`; the
per-tenant `log.db` + `log-blobs/` directories; the raft propose
inside `flushLogs`; the `/_system/log/*` proxy on the worker; the
in-process log-server thread; and the temporary `log.backend = raft|s3`
config flag (production path is the only path).

The local `LogStore` on the worker is now just buffer + drain.
S3 PUT is the only sink; standalone log-server is the only reader.

---

## 4. log-server (single binary: indexer + query API)

### 4.1 Process model

A standalone binary (`rove-log-server`) with two cooperating jobs:

1. **Background indexing task** keeps `log_index.db` in sync with the
   S3 bucket (the polling loop in §4.3).
2. **Public HTTP API** on `logs.{public_suffix}` (own TLS, own h2
   listener) serves dashboard / customer queries against the index
   (§5).

Single process per cluster — same architectural shape as sse-service.
The two jobs share an `*sqlite.Connection` to the local
`log_index.db`; the indexing task writes, the HTTP API reads.

- Failover: if the process dies, restart on whatever node the LB
  routes to. log-server's local SQLite is recoverable from S3 — on
  cold start with no `_meta.last_seen_key`, the polling loop walks
  the entire bucket and rebuilds (bounded; see §4.4). The
  steady-state `last_seen_key` is just a polling-efficiency
  optimization, not a crash-recovery dependency.
- Cap on horizontal scale at v1: one process per cluster. The
  workload is small (LIST + small GETs at 5s cadence; SQLite reads
  for queries). When scale demands it, shard by `hash(tenant_id) % N`
  into N processes — each owns a subset of tenants. Defer until
  measurement says so.

### 4.2 SQLite schema

```sql
CREATE TABLE _meta (
    k TEXT PRIMARY KEY,
    v TEXT NOT NULL
);
-- _meta rows: 'last_seen_key', 'schema_version', etc.

CREATE TABLE batches (
    node_id       TEXT NOT NULL,
    batch_id      TEXT NOT NULL,
    ndjson_key    TEXT NOT NULL,
    ndjson_size   INTEGER NOT NULL,
    ndjson_sha256 TEXT NOT NULL,
    first_received_ns INTEGER NOT NULL,
    last_received_ns  INTEGER NOT NULL,
    indexed_at_ns INTEGER NOT NULL,
    PRIMARY KEY (node_id, batch_id)
);
CREATE INDEX batches_recv ON batches (last_received_ns DESC);

CREATE TABLE log_index (
    tenant_id      TEXT NOT NULL,
    request_id     INTEGER NOT NULL,
    received_ns    INTEGER NOT NULL,
    duration_ns    INTEGER NOT NULL,
    method         TEXT,
    path           TEXT,
    host           TEXT,
    status         INTEGER,
    outcome        TEXT,
    deployment_id  INTEGER,
    ndjson_key     TEXT NOT NULL,
    offset         INTEGER NOT NULL,
    length         INTEGER NOT NULL,
    PRIMARY KEY (tenant_id, request_id)
);
CREATE INDEX log_idx_recv    ON log_index (tenant_id, received_ns DESC);
CREATE INDEX log_idx_status  ON log_index (tenant_id, status, received_ns DESC);
CREATE INDEX log_idx_failure ON log_index (tenant_id, received_ns DESC) WHERE outcome != 'ok';
CREATE INDEX log_idx_deploy  ON log_index (tenant_id, deployment_id, received_ns DESC);
```

Per-tenant separation lives in `log_index.tenant_id` (and the
indexes that lead with it), not in the `batches` table or in the S3
key shape. The `batches` row only describes a per-node-per-flush S3
object, which is shared across tenants by construction. Single
`log_index.db` simplifies cross-tenant ops (retention sweep, vacuum,
schema migration) at the cost of one big file. If file size becomes
a problem before sharding indexers is needed, split by
`hash(tenant_id) % N` into N files.

### 4.3 Polling loop

```
loop every 5s:
    cursor = ""                                       ← always start from the beginning
    while true:
        keys = batch_store.list("", cursor, page_size)  ← walk page-by-page
        if keys.empty: break
        for key in keys where key.endswith(".ndjson"):
            head = batch_store.getRange(key, 0, HEAD_FETCH_BYTES)  ← 512 KB by default
            sidecar_size = u32 LE from head[0..4]
            if 4 + sidecar_size > head.len:
                head = batch_store.getRange(key, 0, 4 + sidecar_size)  ← refetch oversized
            sidecar_json = head[4 .. 4 + sidecar_size]
            BEGIN TRANSACTION
                INSERT OR IGNORE INTO batches (...)
                INSERT OR IGNORE INTO log_index (...)
                  ← per-record offset stored as `sidecar_record.offset + 4 + sidecar_size`
                    so /show's range-GET reads at this offset directly
            COMMIT
            UPDATE _meta SET v = key WHERE k='last_seen_key'  ← observability only
        cursor = keys[-1]
```

Notes:

- **Full scan per pass, not `--start-after last_seen_key` across passes.**
  Within a single pass `cursor` advances monotonically (paging through
  the LIST response), but each pass restarts at `""`. `INSERT OR IGNORE`
  on both tables makes re-walking already-indexed batches a cheap
  PK-lookup-and-skip. The cross-pass cursor optimization is a v2
  refinement (the `_logs/{node}/{batch}` key shape *is* lex-monotonic
  per node, so `--start-after` per-(node) book-keeping would be safe —
  see `src/log_server/indexer.zig` doc comment).
- `_meta.last_seen_key` is updated for observability/operator
  visibility but is **not consulted on read**. Cold-start recovery
  doesn't need it.
- The 5s cadence is tunable; 1s is plausible for a "live tail" feature
  later, at the cost of more LIST calls.
- The frames region (the bulk of each object) is never fetched
  during indexing — only the head bytes containing the sidecar.
  /show fetches one frame's range on click-through.

### 4.4 Rebuild from scratch

Set `last_seen_key` = '' (or just delete the meta row). Next loop
iteration walks the entire bucket. With embedded-sidecar heads at
~256 KB each and a year of logs at 1k batches/day = 365k objects =
~90 GB of GETs to rebuild a year (note: only the head bytes per
object, not the full frames region). Bounded; acceptable for a
one-shot recovery.

---

## 5. Read path

### 5.1 Dashboard "list recent requests"

```
GET https://logs.{public_suffix}/v1/{tenant_id}/list
    ?after={cursor}&limit=100&status=>=500&token=<jwt>

→ validate JWT (signed by platform key; payload = {tenant_id, scope, exp})
→ verify URL path tenant_id matches token's tenant_id
→ SELECT request_id, received_ns, method, path, status, outcome, ...
  FROM log_index
  WHERE tenant_id = ?
    AND status >= 500
    AND (received_ns, request_id) < (cursor_ns, cursor_id)
  ORDER BY received_ns DESC, request_id DESC
  LIMIT 100;
```

Returns the index columns directly. No S3 fetch. Sub-millisecond
SQLite query for typical ranges.

### 5.2 Dashboard "show full record"

```
GET https://logs.{public_suffix}/v1/{tenant_id}/show/{request_id_decimal}
    ?token=<jwt>

→ validate JWT (same shape as list)
→ SELECT ndjson_key, offset, length FROM log_index WHERE ...
→ S3 GET ndjson_key WITH Range: bytes=offset-(offset+length-1)
→ inflate(Z_FINISH) the returned bytes (one self-terminating raw-deflate
  frame, BFINAL=1 set at write time — see §2.2)
→ wrap as `{"record": <JSON>}` and return
```

One ranged GET + one decompress per record. Latency dominated by S3
RTT (~50-150ms typical); decompress is microseconds. Range size is
bounded — a single record's compressed frame is typically a few KB,
sub-MB in the worst case (large console + tape bytes).

### 5.3 Auth: token handoff (same shape as sse-service)

log-server lives on `logs.{public_suffix}` — single platform-managed
hostname for all tenants, mirroring the sse-service model. JWT
carries identity; queries run with `Authorization: Bearer <jwt>`
header (or `?token=` query param for environments that prefer it),
no cookies, no CORS preflight.

Token-mint endpoints live on whichever domain the caller is on:

- **Admin UI on `app.{public_suffix}`** wants to read any tenant's
  logs. Calls `app.{public_suffix}/_admin/log-token?tenant=acme&scope=read`
  (auth: root-token cookie). Returns JWT scoped to `(tenant=acme,
  scope=read, exp)`.
- **Customer's own app on `acme.{public_suffix}` or `acme.com`**
  (custom domain) wants to expose a self-service log view to its
  users. Calls `/_session/log-token?scope=read-self` on its own
  domain (auth: `__Host-rove_sid` cookie). Returns JWT scoped to
  `(tenant=acme, scope=read-self, exp)`.

JWT shape:

```json
{
  "v":         1,
  "tenant_id": "acme",
  "scope":     "read",            // or "read-self" / "admin"
  "exp":       1730768400
}
```

log-server validates: signature, expiry, URL path tenant_id matches
token tenant_id, query type is allowed by `scope`. Any failure → 401.

Token leakage hardening: same as sse-service — strip `?token=` from
access logs before logging; tokens TTL'd to ~1h; scope-bound so a
leaked token only exposes that tenant's logs at that scope.

The worker's old `/_system/log/*` proxy is gone (removed during the
Phase 5.5(a) rollout); admin UI talks to `logs.{public_suffix}`
directly.

---

## 6. Open questions / deferred items

### 6.1 Compression framing — *resolved (per-record raw deflate)*

Initial sketch was gzip-per-batch with a deferred decision between
"raw ndjson" and "gzip-with-sync-flush." The shipped implementation
went a third way: **per-record raw-deflate frames** concatenated into
the `.ndjson` payload. Rationale captured in §2.2 — bounded ranged
GETs work, compression ratio is close to gzip-per-batch, and we
sidestep the Zig stdlib `flate.Compress` bug. Revisit only if the
per-record compression overhead (~tens of bytes of deflate framing
per record) shows up at scale.

### 6.2 Sidecar format: JSON vs CBOR vs binary

JSON is human-readable and the indexer cost is negligible. Sticking
with JSON for v1 unless sidecar parse time shows up in profiling.

### 6.3 log-server redundancy

V1: single process, LB+restart on crash. The 5s polling-catch-up
window on restart is acceptable; query-API downtime is bounded by
"how fast does the LB notice the failure and start a fresh
process."

If the dashboard ever needs <1s availability post-crash, run two
log-server processes against the same S3 bucket, each with its own
`log_index.db`. The LB picks whichever responds first; both indexes
converge to the same state because both read the same S3. Trivial
because log-server is a pure function of S3 state.

### 6.4 Cross-cluster (multi-region) queries

Out of scope for v1. Each cluster has its own S3 bucket + its own
indexer. Federation is a future problem.

### 6.5 Log payload encryption

PLAN §2.7 (page-level encryption at rest) covers the
encrypt-customer-data story. Logs contain customer data (request
bodies, console output) and should ride the same encryption envelope.
Specifics deferred to the encryption phase; storage shape here is
agnostic — encrypted bytes go in `.ndjson` exactly like plaintext.

### 6.6 Janitor pass for orphan `.ndjson`

A weekly process that lists `.ndjson` files without a matching
`.idx.json` and deletes them after a 24h grace period (avoids racing
in-flight uploads). Trivial; defer until orphan accumulation matters.

### 6.7 Embedded sidecar — *shipped*

The sidecar lives at the head of the `.ndjson` object as a
length-prefixed JSON blob; one PUT per flush. See §2.3 for the
on-disk layout and §4.3 for how the indexer Range-GETs just the
head bytes. Replaces the previous payload + `.idx.json` pair.

### 6.8 Retention / GC — *compacting GC + current-policy retention*

**Status: design locked; not yet implemented.**

#### Constraints

- Retention is **per-tenant**, plan-driven, and supports arbitrary
  per-tenant overrides ("custom retention" — enterprise customer
  paid for 5y, etc.). Not a fixed 3-4 plan ladder.
- Tenants on different retention policies coexist on the same node
  and write into the same shared `_logs/{node}/{batch}.ndjson`
  objects. A batch is "deletable" only when *every record inside it*
  is past its owning tenant's retention.
- Long-retention tenants can pin co-flushed neighbours indefinitely
  unless we rewrite.
- Delete cost on S3 is per-object; we want to bound the number of
  small objects that accumulate.

#### Rejected alternatives

- **S3 lifecycle rules over a prefix-per-retention-class layout.**
  Doesn't represent custom (per-tenant) retention without an
  unbounded number of prefixes; loses the 1-PUT-per-node-per-flush
  property; assumes a fixed plan ladder we don't have.
- **Bucket-per-retention-class with cluster-pinning.** Same problem
  on custom retention, and forces cross-cluster tenant migration on
  plan change as a hard prerequisite for shipping GC. Cross-cluster
  migration will need to exist eventually for compute-isolation
  reasons, but coupling GC to it is the tail wagging the dog.
- **Write-time retention** (each record's TTL frozen to the
  tenant's plan-at-write). Pins our storage cost at whatever the
  highest plan a tenant ever held was — a customer who buys 5y
  retention, fills 100 TB, then downgrades to 7d, leaves us paying
  monthly storage for years. Cost ceiling unbounded by current
  revenue; rejected.

#### Design

**Compacting GC against a single bucket, retention evaluated against
each tenant's current policy at compaction time.**

A periodic compactor (sibling to the indexer in the log-server
process — same access pattern, opposite direction) walks
`log_index.batches` and classifies each batch:

- **All records expired** → DELETE both objects (`.ndjson` +
  `.idx.json`); DELETE the `batches` row + every `log_index` row
  pointing at that `ndjson_key`. Free.
- **No records expired** → skip.
- **Partially expired, below rewrite threshold** (e.g., <50% of the
  batch's bytes are dead) → skip; revisit next pass once more has
  expired. Bounded waste.
- **Partially expired, above rewrite threshold** → read the
  `.ndjson`, drop expired records, write a new batch object under a
  fresh key (`_logs/{node}/{new_batch_id}.ndjson` + sidecar — same
  prefix; the new batch_id distinguishes it from the original).
  Atomically: insert the new `batches` row + new `log_index` rows;
  point the existing `log_index` rows for the surviving records at
  the new key; DELETE the old `batches` row and old objects.

Retention is evaluated against `tenant_retention.get(tenant_id)` at
compaction time, not stamped on the record at write time. Plan
downgrades take effect on the next sweep; plan upgrades extend the
TTL for any record still alive (records already swept stay gone).
This trades a small amount of conceptual fuzziness ("retention is
whatever the policy says today") for cost-bounded storage.

#### Tenant retention sync

log-server learns each tenant's current retention by polling a
`/_admin/tenants` endpoint on the worker (or whatever the canonical
read path becomes once the admin surface stabilizes). Cached in a
local SQLite table:

```sql
CREATE TABLE tenant_retention (
    tenant_id        TEXT PRIMARY KEY,
    retention_seconds INTEGER NOT NULL,
    fetched_at_ns    INTEGER NOT NULL
);
```

Cadence: poll every ~5 minutes. Plan changes are rare enough that
eventually-consistent is fine; the worst case is one extra compactor
pass under the old policy, which we already tolerate as part of the
"skip below rewrite threshold" loop.

A tenant_id seen in records but missing from the cache falls back
to a system-wide default (operator config, default 30d). Avoids
"forgot to populate cache → records retained forever."

#### Atomicity and crash recovery

The dangerous moment is the partial-rewrite case. Sequence:

```
1. PUT _logs/{node}/{new_batch}.ndjson         ← new payload
2. PUT _logs/{node}/{new_batch}.idx.json       ← new sidecar
3. SQLite txn:
     INSERT new batches row
     UPDATE log_index SET ndjson_key=new, offset=new, length=new
       WHERE (tenant, request_id) IN <surviving records>
     DELETE old batches row
4. DELETE old _logs/{node}/{old_batch}.ndjson + .idx.json
```

Crash between 2 and 3 = orphan new batch with no index pointer.
Indexer's full-scan pass will pick it up on its next loop and
re-index — at which point the SQLite txn either succeeds (now we
have *both* batches indexed; both contain the surviving records;
duplicates) or `INSERT OR IGNORE` skips the new batch (we never
re-pointed `log_index` at it; surviving records still point at the
old batch; the new orphan needs a janitor pass to clean up).

To keep this clean, the compactor takes a per-batch lock (a row in
a small `compaction_inflight` table) before step 1 and clears it
after step 4. The indexer skips any batch with an inflight
compaction. A crash leaves the lock row stale; a recovery pass on
log-server startup either resumes (re-detect surviving records, re-
issue step 3 onward) or rolls back (DELETE the new batch from S3,
clear the lock).

Crash between 3 and 4 = old objects still in S3 with no `batches`
row. Indistinguishable from §3.2's "orphan ndjson" case from the
indexer's POV (no sidecar would still be matched), which is fine
because the sidecar IS present — but `log_index` no longer
references it, so `/show` won't issue a Range-GET against it. The
janitor pass §6.6 reaps it.

#### Cadence

Open sub-question. The compactor's work scales with bucket size
and retention churn (new expirations / day). Daily seems right as
a starting point — long enough that a tenant's downgrade-followed-
by-immediate-upgrade doesn't cost a full pass per flap, short
enough that storage stays bounded. Re-evaluate post-launch with
real workload data.

#### Sub-questions that fall out

- **Rewrite threshold.** 50% expired bytes is a guess. Probably want
  to measure on real workloads.
- **Compactor placement.** Sibling thread inside log-server (single
  binary), or separate process? Sibling is simpler at v1 — same
  SQLite handle, same access patterns. Promote to its own process
  if it ever needs to scale independently.
- **Interaction with §6.7 (embedded sidecar).** Embedded sidecar
  shipped — the compactor's rewrite path produces objects with the
  same `[u32 sidecar_size][sidecar JSON][frames]` layout as fresh
  flushes, and the indexer treats them identically.
- **Interaction with §6.5 (encryption at rest).** Compactor reads
  ciphertext, drops expired records, writes new ciphertext. Needs
  the page-level encryption envelope to be record-granular, not
  batch-granular, so that "drop expired records" doesn't require
  knowing the plaintext of records we're keeping. Flag for the
  encryption phase.

### 6.9 Per-node log buffer — *shipped*

The old per-tenant `LogStore` split into:

- `RequestIdMinter` — per-tenant, holds the chunked-reservation
  counter persisted into the tenant's app.db (genuinely per-tenant
  because each tenant's request_id space must be monotonic across
  cluster restarts).
- `NodeLogBuffer` — per-node, single in-memory `LogRecord` buffer
  every tenant's dispatch tick appends to. Thresholds (1024 records
  / 1 MiB / 1s) apply to the combined buffer.

`flushLogs` collapsed from a two-pass any-should-flush + per-tenant
drain to a single threshold check + drain. `TenantLog.blob_backend`
(dead post-tape-inlining) was removed at the same time.

---

## 7. Rollout (completed)

The original 9-step rip-and-replace has shipped. For history:
standalone log-server with its own SQLite index landed first behind
a temporary `log.backend = raft|s3` flag; the flag was removed
together with envelope type 1, `RaftLogHandle`, `applyLogBatch`,
the per-tenant `log.db` files, the `log_proxy` subsystem, the
in-process log-server thread, and the worker's `/_system/log/*`
proxy. The interleaved-per-node layout (one PUT/flush regardless of
tenant fan-in) and the per-record raw-deflate framing landed in
follow-up commits — see `git log -- docs/logs-plan.md src/log_server/
src/log/ src/js/worker.zig` and the Phase 5.5(a) markers in
`apply.zig` / `flush_writer.zig`.

Open work tracked here (not in §7): retention/GC (§6.8), embedded vs
separate sidecar (§6.7), and the cross-pass indexer cursor (§4.3).
