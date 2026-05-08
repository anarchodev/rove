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

### 2.3 `.idx.json` sidecar

One JSON object describing the batch + per-record index entries.
Tenant lives per-record (records mix tenants under the interleaved
layout); the top-level no longer carries one:

```json
{
  "v": 1,
  "node_id": "00000001",
  "batch_id": "00000000000000000042-1730764800000",
  "ndjson_key": "_logs/00000001/00000000000000000042-1730764800000.ndjson",
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

The indexer downloads `.idx.json` (small — typically <1% of the
`.ndjson` size) and never fetches the payload during indexing.
`offset` + `length` are byte ranges into the **on-the-wire** ndjson
(i.e. the concatenated raw-deflate frame stream), so a record fetch
is `Range: bytes=offset-(offset+length-1)` followed by one
`inflate(Z_FINISH)` of the returned bytes. No whole-batch
decompression dance.

`ndjson_sha256` is computed over the on-the-wire bytes and lets the
indexer (and the dashboard) verify the payload matches what the
sidecar describes. Cheap insurance against a partial S3 upload that
surfaced before the sidecar got written.

---

## 3. Write path

### 3.1 Buffering on the worker

Each worker today keeps a **per-tenant** `LogStore` buffer (leftover
from the raft-era per-tenant `log.db`; see §6.9 for the planned
simplification to a single node-wide buffer). A record is appended
at the end of every dispatch tick that produced one.

Per-tenant flush triggers (whichever fires first):

- **Count:** 1024 records.
- **Bytes:** 1 MiB uncompressed.
- **Time:** 1s since the buffer's first record (caps tail latency for
  low-traffic tenants).

When *any* tenant's threshold trips, `flushLogs` drains **every
non-empty tenant's buffer on the node** into a single combined batch
and PUTs it as one `_logs/{node}/{batch}.ndjson` plus its sidecar.
Per-tenant thresholds gate *when* a flush happens; the flush itself
is node-global. Result: 2 PUTs per node per flush window regardless
of how many tenants contributed records, with each tenant's records
still labelled by `tenant_id` per row in the sidecar.

The combined-batch policy means a tenant doing one request per minute
gets its records flushed roughly every 1s anyway (whenever a busier
tenant on the same node trips a threshold), without paying for its
own dedicated PUT. A node with no traffic at all does no flushes —
`flushLogs` returns early when no tenant has crossed a threshold.

Customer dispatch already runs leader-only (followers reply 503 to
tenant traffic and ask the caller to retry against the leader), so a
follower's log buffer should normally be empty. `flushLogs`
nonetheless re-checks `isLeader()` after draining and drops the
records with a warning if leadership flipped mid-tick. Matches the
lossy-on-failure semantics — bounded by however much a single node
buffered between leadership transitions.

### 3.2 Flush ordering

```
0. Drain every non-empty per-tenant LogStore on the node into one
   combined record list (in-process; clears the buffers under their
   per-tenant locks)
1. For each record: encode JSON → raw-deflate frame → append to
   on-the-wire ndjson buffer; record (offset, length) in sidecar
2. Compute sha256 over the on-the-wire bytes
3. PUT _logs/{node}/{batch}.ndjson    ← payload first, sidecar second
4. PUT _logs/{node}/{batch}.idx.json  ← only references valid keys
                                        after step 3 succeeds
```

**Crash between 3 and 4** = orphan `.ndjson` in S3 with no sidecar.
The indexer ignores ndjson files without a matching `.idx.json` (it
only keys off sidecars), so the orphan is invisible to dashboards.
A janitor pass can collect orphans on a long cadence (weekly) —
cheap at S3 prices, and the orphan rate is bounded by node-crash
frequency × the per-flush batch size.

**Crash before 3** = records stayed in the in-memory buffer and are
lost on the worker that crashed (the drain in step 0 already cleared
them, but they hadn't reached S3). Acceptable per the stated lossy
semantics.

**Never** index-then-upload; that creates pointers to non-existent
objects.

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
        for key in keys where key.endswith(".idx.json"):
            idx = GET key                              ← parse JSON
            BEGIN TRANSACTION
                INSERT OR IGNORE INTO batches (...)
                INSERT OR IGNORE INTO log_index (...)  ← bulk insert
            COMMIT
        cursor = keys[-1]
    UPDATE _meta SET v = <last sidecar seen> WHERE k='last_seen_key'  ← observability only
```

Notes:

- **Full scan per pass, not `--start-after last_seen_key` across passes.**
  Within a single pass `cursor` advances monotonically (paging through
  the LIST response), but each pass restarts at `""`. `INSERT OR IGNORE`
  on both tables makes re-walking already-indexed sidecars a cheap
  PK-lookup-and-skip. The cross-pass cursor optimization is a v2
  refinement (the new `_logs/{node}/{batch}` key shape *is* lex-monotonic
  per node, so `--start-after` per-(node) book-keeping would be safe —
  see `src/log_server/indexer.zig` doc comment).
- `_meta.last_seen_key` is updated for observability/operator
  visibility but is **not consulted on read**. Cold-start recovery
  doesn't need it.
- The 5s cadence is tunable; 1s is plausible for a "live tail" feature
  later, at the cost of more LIST calls.

### 4.4 Rebuild from scratch

Set `last_seen_key` = '' (or just delete the meta row). Next loop
iteration walks the entire bucket. With sidecars at ~10KB each and a
year of logs at 1k batches/day = 365k sidecars = ~3.6GB of GETs to
rebuild a year. Bounded; acceptable for a one-shot recovery.

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

### 6.7 Embedded sidecar vs separate `.idx.json`

Today every flush issues two PUTs (payload + sidecar). The orphan-on-
crash story (§3.2) and the indexer's "list-only-`.idx.json`"
shortcut (§4.3) both depend on the sidecar being a separate object.

Open question: collapse to a single PUT by prefixing the `.ndjson`
with a fixed-size header (sidecar length + bytes) so the indexer
does a small ranged GET on the head of the object instead of a
separate sidecar GET. Halves PUT count per flush; complicates the
"orphan" story (a partially-uploaded object with a header-prefix
needs to be detectable by the indexer rather than skipped by suffix
matching). Defer until PUT cost shows up; revisit alongside the
retention/GC design (§6.8) since GC will care about object count.

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
- **Interaction with §6.7 (embedded sidecar).** If we ever collapse
  to a single PUT per flush with a header-prefix sidecar, the
  compactor's rewrite path also halves PUT count. Design the
  compactor against the current shape; revisit if §6.7 lands.
- **Interaction with §6.5 (encryption at rest).** Compactor reads
  ciphertext, drops expired records, writes new ciphertext. Needs
  the page-level encryption envelope to be record-granular, not
  batch-granular, so that "drop expired records" doesn't require
  knowing the plaintext of records we're keeping. Flag for the
  encryption phase.

### 6.9 Collapse per-tenant `LogStore` to a single per-node buffer

Tech debt from the raft-era per-tenant `log.db` model. With the
interleaved-per-node flush there is no per-tenant state worth
keeping in the buffer: every record already carries `tenant_id` as
a field, and the only operation we do on the per-tenant slices is
"drain everything into one combined batch" at flush time.

Proposed: replace `tenant_logs: HashMap(instance_id, *LogStore)`
with one node-wide `LogStore` (or just an `ArrayList(LogRecord)`
behind a mutex). The flush triggers fold to a single check on the
combined buffer:

- Count: 1024 records
- Bytes: 1 MiB uncompressed
- Time: 1s since the buffer's first record

Drops the two-pass `flushLogs` (any-should-flush check, then per-
tenant drain) for a single threshold check + drain. No behaviour
change at the S3 layer — same key shape, same combined batch — just
fewer maps and one fewer indirection on every log append.

Defer to a small dedicated commit; orthogonal to retention/GC
(§6.8) and to the embedded-sidecar question (§6.7).

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
