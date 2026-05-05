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
│ (any     │   .ndjson.gz  │   {tenant}/{node}/{batch_id}.ndjson.gz  │
│  node)   │   .idx.json   │   {tenant}/{node}/{batch_id}.idx.json   │
└──────────┘               └─────────────────────────────────────────┘
                                  ▲                          ▲
                                  │ poll LIST + GET          │ ranged GET
                                  │ (.idx files only)        │ (on click)
                                  │                          │
                           ┌──────┴───────┐           ┌──────┴──────┐
                           │   indexer    │           │ log-server  │
                           │ (singleton   │◀──────────│ (per node;  │
                           │  or sharded; │   query   │  fans out   │
                           │  rebuildable │           │  to indexer)│
                           │  from S3)    │           │             │
                           │              │           │             │
                           │ log_index.db │           │             │
                           └──────────────┘           └─────────────┘
                                  ▲
                                  │ HTTP query
                                  │
                              dashboard
```

S3 is the **only** coupling point between worker and indexer. There is
no RPC, no message queue, no raft cluster for the index. The worker
doesn't know whether an indexer is running; the indexer doesn't know
which workers exist. Both can be killed and restarted at will.

---

## 2. Data model

### 2.1 Object naming

```
{tenant_id}/{node_id}/{batch_id}.ndjson.gz   ← record bodies
{tenant_id}/{node_id}/{batch_id}.idx.json    ← index sidecar
```

- `tenant_id` is the leftmost prefix so per-tenant LIST + retention
  delete is one prefix scan.
- `node_id` is the raft node id (u32, hex-formatted) so the indexer's
  `--start-after` cursor advances monotonically per node and concurrent
  uploads from different nodes don't collide.
- `batch_id` is `{first_request_id:020d}-{flush_unix_ms:013d}`.
  Zero-padded so lexical sort = chronological. The leading
  `request_id` makes "last batch I indexed for this node" trivially a
  string comparison; the trailing timestamp disambiguates if a node
  ever resets request_id allocation.

Lexical iteration of the bucket prefix `{tenant_id}/` returns
`(node, batch)` pairs in (node, time) order; merging by `received_ns`
at read time gives global newest-first.

### 2.2 `.ndjson.gz` payload

One JSON object per line, gzip-compressed. Schema matches today's
`log_mod.LogRecord` plus the existing optional fields (`console`,
`exception`, `tape_refs`, `parent_request_id`, `deployment_id`).
Records within a batch are ordered by ascending `received_ns`.

The full record body is read only on dashboard click-through, never
during list/filter operations.

### 2.3 `.idx.json` sidecar

One JSON object describing the batch + per-record index entries:

```json
{
  "v": 1,
  "tenant_id": "acme",
  "node_id": "00000001",
  "batch_id": "00000000000000000042-1730764800000",
  "ndjson_key": "acme/00000001/00000000000000000042-1730764800000.ndjson.gz",
  "ndjson_size": 84321,
  "ndjson_sha256": "abc...",
  "first_received_ns": 1730764800000000000,
  "last_received_ns":  1730764802349000000,
  "records": [
    {
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
`.ndjson.gz` size) and never fetches the payload during indexing.
`offset` + `length` are byte ranges into the **decompressed** ndjson
so the dashboard can request `Range: bytes=offset-(offset+length-1)`
of the gzip stream after a transparent re-decode (or, if we want to
skip the decompression dance, the offsets are into a *raw concatenated*
ndjson and we drop gzip — see §6 open question).

`ndjson_sha256` lets the indexer (and the dashboard) verify the
payload bytes match what the sidecar describes. Cheap insurance
against a partial S3 upload that surfaced before the sidecar got
written.

---

## 3. Write path

### 3.1 Buffering on the worker

Each worker keeps a per-tenant in-memory buffer (the existing
`LogStore.buffer` rebuilt around the new flush target). A record is
appended at the end of every dispatch tick that produced one.

**Flush triggers** (whichever fires first, per-tenant):

- **Count:** 1024 records (matches the current `flushLogs` threshold).
- **Bytes:** 1 MiB uncompressed.
- **Time:** 1s since the buffer's first record (caps tail latency for
  low-traffic tenants).

### 3.2 Flush ordering

```
1. Serialize buffer → ndjson bytes (in-process)
2. Compute sha256 + per-record offset table (in-process)
3. PUT {batch_id}.ndjson.gz       ← payload first, sidecar second
4. PUT {batch_id}.idx.json        ← only references valid keys after step 3 succeeds
5. Drop the buffer entries
```

**Crash between 3 and 4** = orphan `.ndjson.gz` in S3 with no sidecar.
The indexer ignores `.ndjson.gz` files without a matching `.idx.json`
(it only keys off sidecars), so the orphan is invisible to dashboards.
A janitor pass can collect orphans on a long cadence (weekly) — cheap
at OVH/S3 storage prices, and the orphan rate is bounded by
node-crash frequency × ~1MB.

**Crash before 3** = records stayed in the in-memory buffer and are
lost on the worker that crashed. Other workers' buffers are
unaffected. Acceptable per the stated lossy semantics.

**Never** index-then-upload; that creates pointers to non-existent
objects.

### 3.3 What goes away

The current model's:

- Envelope type 1 (log_batch) in `src/js/apply.zig`.
- `RaftLogHandle` / `applyLogBatch` / follower-side log.db apply.
- Per-tenant `log.db` + `log-blobs/` on every node.
- The raft propose call inside `flushLogs`.

All of those are replaced by direct S3 PUT. The local
`LogStore` shrinks to "buffer + serialize + flush"; nothing else.

---

## 4. Indexer

### 4.1 Process model

A standalone binary (`rove-log-indexer`) with one job: keep
`log_index.db` in sync with the S3 bucket.

- Single process per cluster is fine for v1 (workload is small —
  LIST + GET of a few KB sidecars at 5s cadence).
- Horizontal scale by sharding on `tenant_id` prefix later. Two
  indexers running against the same S3 bucket and writing to separate
  SQLite files is *correct* (idempotent inserts; each is a complete
  copy); they just duplicate work.
- Crash recovery: restart and resume from `last_seen_key` (stored in
  the `_meta` table). No external state needed.

### 4.2 SQLite schema

```sql
CREATE TABLE _meta (
    k TEXT PRIMARY KEY,
    v TEXT NOT NULL
);
-- _meta rows: 'last_seen_key', 'schema_version', etc.

CREATE TABLE batches (
    tenant_id     TEXT NOT NULL,
    node_id       TEXT NOT NULL,
    batch_id      TEXT NOT NULL,
    ndjson_key    TEXT NOT NULL,
    ndjson_size   INTEGER NOT NULL,
    ndjson_sha256 TEXT NOT NULL,
    first_received_ns INTEGER NOT NULL,
    last_received_ns  INTEGER NOT NULL,
    indexed_at_ns INTEGER NOT NULL,
    PRIMARY KEY (tenant_id, node_id, batch_id)
);
CREATE INDEX batches_recv ON batches (tenant_id, last_received_ns DESC);

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

Per-tenant separation lives in the indexed columns, not in separate
files. Single `log_index.db` simplifies cross-tenant ops (retention
sweep, vacuum, schema migration) at the cost of one big file. If file
size becomes a problem before sharding indexers is needed, split by
`hash(tenant_id) % N` into N files.

### 4.3 Polling loop

```
loop every 5s:
    last = SELECT v FROM _meta WHERE k='last_seen_key' (or '' if absent)
    keys = S3 LIST --prefix '' --start-after last        ← all .ndjson.gz + .idx.json
    sidecars = [k for k in keys if k.endswith('.idx.json')]
    for sidecar_key in sidecars:                          ← batch in groups of N
        idx = GET sidecar_key                             ← parse JSON
        BEGIN TRANSACTION
            INSERT INTO batches (...)
            INSERT INTO log_index (...)  ← bulk insert
            UPDATE _meta SET v = sidecar_key WHERE k='last_seen_key'
        COMMIT
```

Notes:

- One transaction per sidecar keeps `last_seen_key` always pointing at
  a sidecar that is fully indexed. A crash in the middle of inserting
  a batch's records rolls the txn back; the next loop iteration redoes
  the same sidecar.
- `INSERT OR IGNORE INTO log_index` makes re-indexing the same sidecar
  a no-op, so `last_seen_key` advancing slightly out of order (which
  shouldn't happen with `--start-after`, but defensively) is harmless.
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
log-server fans out → indexer's HTTP API:

  GET /v1/{tenant_id}/list?after={cursor}&limit=100&status=>=500

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
GET /v1/{tenant_id}/show/{request_id:hex}

→ SELECT ndjson_key, offset, length FROM log_index WHERE ...
→ S3 GET ndjson_key WITH Range: bytes=offset-(offset+length-1)
→ gunzip → return JSON record
```

One ranged GET. Latency dominated by S3 RTT (~50-150ms typical).

### 5.3 log-server's role

`log-server` becomes a thin shim that:

1. Authenticates the request (root token, same as today).
2. Validates the tenant_id is the caller's scope.
3. Forwards to the indexer's HTTP API (or queries the local
   `log_index.db` directly if log-server and indexer co-locate).
4. Returns the response.

If the indexer is the singleton process model: `log-server` on every
node points at the same indexer's HTTP endpoint. If sharded:
`log-server` uses `hash(tenant_id) % N` to pick the right indexer.

---

## 6. Open questions / deferred items

### 6.1 gzip vs raw ndjson for batch payloads

Tradeoff: gzip saves ~70% of S3 storage and egress, at the cost of
either (a) re-decoding the whole batch to serve a single record on
click-through, or (b) computing offsets into the decompressed stream
and asking S3 for byte ranges of the gzip-encoded stream — which only
works if we use *gzip with sync flush points per record*, a non-default
encoding mode that's awkward to produce in Zig.

Decision deferred to implementation: start with **raw ndjson**
(simpler, ranged GETs work), revisit gzip-with-sync-flush only if S3
storage cost becomes meaningful.

### 6.2 Sidecar format: JSON vs CBOR vs binary

JSON is human-readable and the indexer cost is negligible. Sticking
with JSON for v1 unless sidecar parse time shows up in profiling.

### 6.3 Indexer redundancy

V1: single indexer process, restart on crash. The 5s catch-up window
on restart is acceptable.

If the dashboard ever needs <1s availability post-indexer-crash, run
two indexers against the same S3 bucket, each with its own
`log_index.db`. log-server's fan-out can pick whichever responds
first. Trivial because the indexers are pure functions of S3 state.

### 6.4 Cross-cluster (multi-region) queries

Out of scope for v1. Each cluster has its own S3 bucket + its own
indexer. Federation is a future problem.

### 6.5 Log payload encryption

PLAN §2.7 (page-level encryption at rest) covers the
encrypt-customer-data story. Logs contain customer data (request
bodies, console output) and should ride the same encryption envelope.
Specifics deferred to the encryption phase; storage shape here is
agnostic — encrypted bytes go in `.ndjson.gz` exactly like plaintext.

### 6.6 Janitor pass for orphan `.ndjson.gz`

A weekly process that lists `.ndjson.gz` files without a matching
`.idx.json` and deletes them after a 24h grace period (avoids racing
in-flight uploads). Trivial; defer until orphan accumulation matters.

---

## 7. Migration order

The rip-and-replace is staged so each step is independently
shippable + smoke-testable.

1. **`rove-blob` already supports S3 (commit ce29f26).** No change.
2. **Build the indexer binary.** Standalone; can be exercised against
   a hand-populated bucket. Smoke: PUT a few sidecars, verify the
   indexer's `log_index.db` reflects them.
3. **Add the new flush path to `LogStore`** behind a config flag
   (`log.backend = raft | s3`). Default stays `raft`. Run both code
   paths in dev to compare.
4. **Switch `loop46 worker --log-backend=s3`** in dev. Verify
   end-to-end (worker writes → indexer indexes → dashboard reads).
5. **Switch the production default to `s3`.** Old `log.db` files on
   disk become read-only (still readable by the existing `log-server`
   for historical queries during the transition window).
6. **Remove envelope type 1, `RaftLogHandle`, `applyLogBatch`,
   per-tenant `log.db` opens.** Drop the config flag.
7. **Old `log.db` files** can be migrated by a one-shot
   `rove-log-cli migrate-to-s3 --data-dir ... --bucket ...` if any
   operator wants to retain old records; otherwise let TTL expire
   them on disk.

Each step is a separate commit, with smokes at every transition.
