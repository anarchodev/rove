---
title: Format & protocol versioning (as-built reference)
status: SHIPPED — the freeze landed 2026-06-23; prod re-genesis'd 2026-06-26. This is the as-built spec-of-record for rove's version scheme; the §-anchors here are what the source cites.
date: 2026-06-18
updated: 2026-07-10
---

# Format & protocol versioning — as-built reference

> **Shipped.** This began as a pre-launch audit; the freeze it recommended is
> **built and deployed** (all format-version bytes + the JS engine version +
> the id prefixes landed 2026-06-23; prod was re-genesis'd 2026-06-26 under the
> frozen v1 formats — `decisions.md` no-pre-launch-back-compat). It now stands
> as the **as-built reference** the source cites by section: the wire/on-disk
> version-byte scheme (§3), the JS engine version tag (§4), and the
> customer-observable freeze rules (§7). The locked *rules* are also recorded in
> `decisions.md` (Format & protocol versioning); this doc is the full spec.

Sweep of every wire protocol, on-disk format, and persisted key-schema in
`rove` — the current versioning of each and the uniform, backward-compatible
scheme now in place. Also defines the **JS engine version** concept so replay
can pull the matching engine for an old request. §6 (phasing) and §8
(consolidated change list) are retained as the historical record of what
shipped.

## TL;DR — what we found

- **Almost nothing is explicitly versioned.** Three formats carry a real
  version field today: the snapshot-stream wire (`STREAM_VERSION = 1`), the
  tape/readset bundle (per-channel tape `v5`, readset `v6`), and the JSON
  artifacts (deployment manifest + log sidecar, both `"v": 1`). Everything else
  relies on an implicit magic byte, a type-byte enum, or nothing at all.
- **Pre-launch wipe is our friend.** We can *freeze v1* of every format now and
  wipe dev/prod data, so we never need a v0→v1 migration. The whole point is to
  have the version field *in place* so the *next* change is backward-compatible.
- **Three sensitivity tiers** drive the strategy (see §2). The hardest are the
  raft-log-persisted formats (replicas must agree) and the cross-node coalesced
  wire (deliberately shrunk 28→20B — every byte is load-bearing).
- **JS engine version is a genuine net-new concept** (§4). There is zero notion
  of "which engine ran this request" anywhere today. Clear plumbing path exists.

## 1. Master inventory

Legend — **Ver?**: explicit version field present today. **Tier**: see §2.

**Class** answers the question `Ver?` cannot: *why* a format has no version.
An unclassified `none` is indistinguishable from an oversight, which is what
lets the next new format inherit a precedent nobody chose.

| Class | Meaning |
|---|---|
| **versioned** | carries its own version field, and is named in the runtime registry (`src/rewind/version.zig`) |
| **inherits** | governed by an enclosing frame's version — the frame is named, and must be recoverable **at read time**, not merely at write time |
| **by-decision** | deliberately unversioned, with the reason: immutable shape, derived/rebuildable, or never persisted across a deploy |
| **gap** | should carry a version and does not |
| **unwritten** | a claimed namespace with no producer yet — not a format, and classified when one appears |

The read-time clause in *inherits* is load-bearing. A value whose writer is
versioned does not thereby inherit that version: if the value outlives the
frame that produced it, the reader has nothing to dispatch on. §1f is where
that distinction decides most of the rows.

Every table below carries the **Class** column. The tally across all 55
rows: **23 versioned · 8 inherits · 17 by-decision · 0 gap · 7 unwritten.**

No gaps remain. The last two were the rows read by something NOT upgraded
in lockstep with their writer, and they closed differently because that
difference is what a version field can and cannot fix:

- `<bundle>/rewind.lock` took a `"v"`. Its reader is the customer's
  `rewind` binary, upgraded on their schedule, and a version field
  works there because the file is handed over whole.
- `cluster/{id}` could not. Its readers are the two halves of a rolling
  CP upgrade, both live at once, so an in-band marker is indistinguishable
  from data to the older one — the field cannot be introduced by the
  deploy that introduces it. It versions by KEY instead, and the value's
  shape is guarded so it cannot be widened in place.

That asymmetry is the general rule: a version field needs a reader that
can be told about it before it arrives. Where the reader is already
running, the version belongs in the NAME.

The runtime registry (`src/rewind/version.zig`, dumped by
`rewind --version`) names every row that is not in the *inherits* class,
including the ones with no Zig constant to import: the JS-owned shim
record versions and the two path-versioned HTTP surfaces are listed as
mirrored values, because a format the dump omits reads as one with
nothing to see.

### 1a. Raft-replicated / log-persisted (hardest — replicas must agree)

| Format | File | Layout (current) | Ver? | Class | Tier |
|---|---|---|---|---|---|
| Entry frame (per raft entry) | `src/consensus/envelope.zig` (`ENTRY_FRAME_MAGIC=0xF7`, `encodeEntryFrame`/`decodeEntryFrame`) | `[1B 0xF7][8B origin LE][8B seq LE][envelope]` | magic only | **versioned** — magic IS the version (registry `entry_frame`); the next change reserves `0xF8`, and an unframed byte is rejected loudly | A |
| Envelope codec header | `src/consensus/envelope.zig`; lib copy `src/kv/envelope_codec.zig` | `[1B type][2B id_len BE][id][payload]`; types 0=writeset,1=multi,2=root_writeset (3–11 retired, rejected loud) | type enum | **versioned** — the type byte IS the discriminant (registry `envelope_codec`); a retired or unknown type is rejected loudly, which is what makes a stale log entry surface instead of mis-applying | A |
| Writeset payload (type 0) | `src/kv/writeset.zig`; readset framing `src/js/apply.zig` | `[u32 BE op_count]·[op][klen][k][vlen][v]…` then `[u32 ws_len][ws][u32 rs_len][rs]` | none | **inherits** ← the envelope type byte (0). The frame is recoverable at read time by construction: the type precedes the payload in the same entry, and no payload is ever read without it | A |
| Multi payload (type 1) | `src/kv/envelope_codec.zig` | `[u8 count]·[u32 LE inner_len][inner_envelope]…` | none | **inherits** ← the envelope type byte (1); same argument | A |
| Snapshot baseline (index/term/ConfState) | raft-rs opaque; installed `src/consensus/node.zig` | `{index u64, term u64, conf_state{voters,learners}}` | raft-rs internal | **inherits** ← the `raft-rs-zig` pin in `build.zig.zon`. A dependency pin is a legitimate frame, but a weaker one than a byte on the wire: it is recoverable from the BUILD, not from the data, so it only holds while every node reading a WAL was built from the same pin | C |

### 1b. On-wire ephemeral (cross-node / inter-binary)

| Format | File | Layout | Ver? | Class | Tier |
|---|---|---|---|---|---|
| Coalesced raft transport | `src/consensus/transport.zig` (`FRAME_VERSION`, `RECORD_HDR_SIZE=20`) | `[u8 ver][u32 count]·[u64 group][u64 epoch][u32 msg_len][msg]…` (msg = raft-rs protobuf) | **yes (v1 frame byte)** + epoch fences | **versioned** (registry `coalesced_transport`). Its version byte shares `payload[0]` with raft-net's `ident` tag (=5) one layer down, so `FRAME_VERSION` may never become 5 — a comptime assert beside the constant fails the build on the bump that would collide | **B-hot** |
| Raft-net frame codec | `src/kv/raft_rpc.zig` | `[u32 BE len][u32 BE crc][payload]`; ident handshake type=5 | MsgType enum | **by-decision** — the framing carries a length and a checksum and nothing to interpret; what the payload MEANS is versioned one layer in (the coalesced frame's byte, or the fixed 5-byte `ident`). See the byte-0 constraint noted above | B-hot |
| Snapshot stream wire | `src/kv/snapshot_stream.zig` (`STREAM_VERSION`) | `[u32 LE MAGIC "MGS2"][u8 ver=1][u64 store_id]·[u16 klen][u32 vlen][k][v]…` | **yes (v1)** | **versioned** (registry `snapshot_stream`); an unknown version is `UnsupportedStreamVersion` | B |
| Snapshot sink endpoint | `src/js/snapshot_sink.zig` + `POST /_system/v2-snapshot-stream` | headers `{mode,tenant,index,term,move-secret}` + stream body | path `v2-` | **versioned** — in HTTP's own idiom, the version is a path segment: a new shape is a new path, and an old peer 404s instead of mis-parsing | B |
| Worker→log-server push | `src/js/worker_log.zig` (`POST /v1/_internal/batch-pushed`) | newline-delimited S3 keys, Bearer JWT | path `/v1/` | **versioned** — same path-segment idiom | B |
| Front↔worker proxy (h2c) | `src/front/proxy.zig` | RFC 7540/8441 h2c; headers | n/a (HTTP) | **by-decision** — the format is an RFC, versioned by its own negotiation. Not ours to version, and adding a field would be inventing a dialect | B |

### 1c. S3 objects (content-addressed or batched)

| Format | File | Layout | Ver? | Class | Tier |
|---|---|---|---|---|---|
| Content-addressed blob keys | `src/blob/backend.zig` | `{prefix_base}{instance}/{file-blobs\|log-blobs}/{sha256}` | no key version | **by-decision** — the key IS the SHA-256 of the bytes, so different content is a different key and there is no shape to disagree about. A content address is the one kind of name that cannot go stale | B |
| Deployment manifest object key | `src/files/manifest_json.zig`, `src/blob/namespace.zig` | `tenants/{id}/deployments/e{bc_version}/{dep_id:020d}.json` | **yes — `e{bc_version}` segment** | **versioned** — the key-prefix version segment §6's Phase 2 asks about, for the one namespace that needs it. The object is DERIVED (a compile keyed by engine build), not content-addressed, so its name carries the derivation's version and a miss recompiles instead of mis-reading | B |
| Deployment manifest | `src/files/manifest_json.zig` (`VERSION`) | JSON `{v:2, deployment_id, entries[…], packages?, app_imports?}` | **yes (v2)** | **versioned** (registry `deployment_manifest`) — and the only format here that has ALREADY been bumped: v1→v2 was resolved by refusing v1 and redeploying, not by a compatibility branch | B |
| Log batch object | `src/log_server/flush_writer.zig` | `[u32 LE sidecar_len][sidecar JSON][deflate frames…]` | sidecar **v1** | **inherits** ← the log sidecar's `v`, which sits at a fixed offset 4 in the SAME object and is read before anything it describes. The 4-byte length prefix ahead of it is a fixed frame with nothing to interpret | B |
| Log sidecar JSON | `src/log_server/sidecar.zig` (`VERSION`) | JSON `{v:1, node_id, batch_id, records[…]}` | **yes (v1)** | **versioned** (registry `log_sidecar`) | B |
| Per-record JSON (+ inline tapes) | `src/log_server/flush_writer.zig` | deflate-wrapped JSON incl. base64 tape payloads | none | **inherits** ← the log sidecar's `v`. This is the §1f test passing rather than failing: the records and the sidecar are written by one writer into one sealed object, and the reader reaches a record only through the sidecar's offsets — so unlike a shim-owned kv row, the frame genuinely travels with the value | B |
| Body-batch pool object | `src/blob/pool_object.zig` (`_pool/{written_ms}-{digest}`) | `[u32 magic "RPL1"][u16 ver]…` + entry table + bodies, referenced by `BodyRef{written_unix_ms,digest,offset,len}` | **yes (v1)** | **versioned** (registry `pool_object`); a `VERSION + 1` object is refused, and there is a test that says so | B |

### 1d. Local on-disk (opaque / pinned by dep)

| Format | File | Layout | Ver? | Class | Tier |
|---|---|---|---|---|---|
| Raft WAL (shared, all groups) | raft-rs-zig (`{data_dir}/raft-wal/`); opened `src/consensus/node.zig` | raft-rs segments + CRC records + hardstate; rove wraps each entry w/ 0xF7 frame | raft-rs internal + entry frame | **inherits** ← the `raft-rs-zig` pin (segments) + the entry frame's magic (rove's wrapper). Two frames, one per layer, which is why the row reads as two things | C |
| kvexp store (app.db / __root__.db) | kvexp (fetched, **not vendored**); `data_dir/{id}/app.db` | LMDB B+tree; applied-raft-idx watermark in kvexp meta | LMDB internal | **inherits** ← the `kvexp` pin. LMDB's own on-disk format is versioned by LMDB and refuses a file it does not know | C |
| Group manifest (node-local) | `src/consensus/node_core.zig` (`{data_dir}/__groups__/app.db`) | kvexp; key=group id, value=epoch decimal ASCII | none | **by-decision** — a monotonic decimal integer has no shape to change, and the file is node-local: a node that loses it re-derives its groups from the directory rather than reading a peer's copy, so no two builds ever read the same bytes | C |
| ACME account key | `src/cp/acme.zig` (`{data_dir}/acme/account.key`) | PKCS#8 PEM | none | **by-decision** — PKCS#8 is an external standard with its own structure. Versioning it would be inventing a dialect of someone else's format | C |
| Bundle lockfile (`<bundle>/rewind.lock`) | written `src/cli/rewind.zig` `writeLockfile`, read `readLockfile`; shape + stamp `src/cli/packages.zig` (`LOCKFILE_VERSION`, `stampLockfile`, `lockfileVersion`) | JSON `{v:1, packages[…], app_imports{…}}` — the registry's `/v1/resolve` body with the CLI's stamp inserted, otherwise byte-for-byte | **yes (`v`)** | **versioned** — the stamp is the CLI's, not the registry's: `parseResolveResponse` still reads a live response that carries no `v`. Read-side checks the version BEFORE the shape, because a lock from a newer `rewind` mis-PINS a deploy rather than failing it | C |

> **`rewind.lock` became load-bearing** when `deploy` started resolving through
> it (#630): it is an INPUT to a deploy, not a record of one, so a shape change
> would silently mis-pin rather than be ignored. That is what its `"v"` guards,
> and why the reader checks the version before the shape — a lock written by a
> newer `rewind` than the one reading it is the ordinary case here, not an edge.

> **Stale / dead (not live formats):** the per-instance SQLite `files.db` /
> `log.db` are gone. What survives is prose: `src/tenant/root.zig` still names
> them in three comments describing the on-disk layout. No code opens either,
> and `src/files/root.zig` and `src/log/root.zig` no longer mention them at
> all. Treat SQLite-per-instance as retired; the remaining comments are a
> naming cleanup, not a format.

### 1e. Replay / tape (already the best-versioned subsystem)

| Format | File | Layout | Ver? | Tier |
|---|---|---|---|---|
| Per-channel tape | `src/tape/root.zig` `VERSION` | `[u32 MAGIC "RTAP"][u16 ver=9][u16 channel][u32 count][entries…]` (v6: fetch content-hash; v7: kv outcome `refused` — outcome-replay; v8: content-addressed `BodyRef`; v9: kv outcome `elided` + a trailing `value` on prefix entries — the read budget) | **yes (v9, MIN = v9)** | A* |
| Readset bundle (whole request) | `src/tape/root.zig` (`READSET_MAGIC`, `Readset.serialize`) | `[u32 "RREA"][u16 ver=11][i64 ts_ns][u64 seed][u16 js_engine_version]·6 channel blobs·LogHeader (carries `received_ns` + `exec_seq`)` | **yes (v11)** | A* |
| WASM parser mirror | rewind-apps `replay/_static/rtap.mjs` | mirrors **per-tape** blobs only (NOT RREA — see §4 step 3) | tracks the tape version (`RTAP_VERSION`), rejecting any other | A* |

`A*` = log-persisted (tapes ride inline in `LogRecord`) **and** must stay
in lockstep with the JS-side `rtap.mjs` parser.

### 1f. Persisted KV key-schemas (implicit value formats)

Each `_`-prefixed namespace is an implicit format, and none carries a version
field. The reservation itself is blanket rather than enumerated: `kv.set` /
`kv.delete` from customer or shim JS refuse **every** leading-`_` key except the
shim-writable exceptions, so the platform can claim a new `_…/` family later
without colliding with customer data (`src/reserved/root.zig`
`isCustomerWriteReserved`).

Three lists in `src/reserved/root.zig` carve that keyspace up, and a namespace's
list membership is what its versioning story will inherit from:

- `PLATFORM_KV_PREFIXES` — the catalog of known platform-owned namespaces,
  used for the bidirectional trigger-prefix collision check.
- `SHIM_WRITABLE_PREFIXES` — the exceptions: prefixes platform JS *libraries*
  write from ordinary handler context. Platform-managed but not
  platform-reserved; a tenant that writes one corrupts only its own durability
  markers.
- `ENGINE_ONLY_PREFIXES` — keys a handler cannot even *see*; a read behaves as
  though the key is absent. This is what lets an engine write to them without
  an activation or a log record, since nothing a handler observes ever moved.

| Key | Value | Class | Producer | Notes |
|---|---|---|---|---|
| `_admin/operator/{sha256(email)}` | empty marker | **by-decision** — the key *is* the datum; an empty value has no format to change | seeded out-of-band by `rewind-ops`; read by `@rewind/oidc` (`src/js/packages/@rewind/oidc/index.mjs` `operator_prefix`) | operator allowlist; in NO list — reserved by the blanket leading-`_` rule, and deliberately read-only from shims |
| `_app/` | — | **unwritten** | none | Reserved for a distributable app's manifest + derived capability set (`handler-shape.md` §8); consumer is post-launch |
| `_audit/` | — | **unwritten** | none | Reserved for a future audit log |
| `_blob/owed/{hash}` | JSON `{v, hash, content_type, attempts, …}` | **versioned** (`BLOB_OWED_V`) | `src/js/globals/blob.js` (`blob.put`) | shim-writable; `blob.put` durability marker. Survives the deployment that wrote it |
| `_callback/` | — | **unwritten** | none | Engine-only. Sends resolve via in-memory Completions, not rows here; stays reserved so customer JS cannot forge a receipt key |
| `_config/{dep_id:016x}/{path}` | JSON | **inherits** ← deployment manifest (`{v:2}`), and the frame is recoverable at read time because `dep_id` is *in the key* | `src/js/config_mirror.zig` (release-time mirror of the deploy tree's `_config/*.json`) | **storage key is deployment-scoped**; a handler names the *visible* key `_config/{path}` and `reserved.configStorageKey` maps it. Immutable write-once rows, so the single `_deploy/current` flip switches code and config atomically — including a rollback and a deploy that REMOVES a key. `dep_id == 0` (sim / replay arena) uses the visible key unchanged |
| `_deploy/current` | hex u64 (`{x:0>16}`) | **by-decision** — fixed-width immutable shape; a different pointer format is a different key | `src/js/starter.zig` (the release stage), `src/js/worker_system.zig` | atomic release pointer; customer-readable (rest of `_deploy/` reserved, unwritten). What it points AT is versioned |
| `_dispatch/owed/{id}` | JSON `{v, tenant, module, ctx, fn, actor}` | **versioned** (`DISPATCH_OWED_V`) | `src/js/globals/platform.js` (`platform.dispatch`) | shim-writable; `platform.dispatch`'s owed marker — same posture as `_send/owed/`. Cross-tenant intent, so the record outlives both deployments involved |
| `_export/{job}` | JSON `{v, format, state, cursor, parts[], …}` | **versioned** (`EXPORT_REC_V`) — `v` versions this RECORD, `format` versions the export ARTIFACT; they move independently | `src/js/packages/@rewind/export/index.mjs` via `src/js/kv_export.zig` (`EXPORT_STATE_PREFIX`) | shim-writable; excluded from its own export — the record mutates as the export proceeds. A long-running job spans deploys |
| `_keys/next_slot` | `[1B v][8B end LE][8B nonce LE]` | **versioned** (`keyspace.VALUE_VERSION`, registry `keyring_kv_value`) | `src/js/keyring_slots.zig` (`COUNTER_KEY`) | engine-only. Slots RESERVED |
| `_keys/minted`, `_keys/bind/{identity}`, `_keys/dead/{slot}` | `[1B v][8B end LE]` / `[1B v][8B slot LE][32B HMAC]` / `[1B v][8B destroyed_ns LE]` | **versioned** — one `VALUE_VERSION` for the whole namespace; readers check the byte BEFORE the width, so a future value reads as `UnsupportedVersion` rather than as corruption | `src/keyring/keyspace.zig` (`VALUE_VERSION`, `encodeBinding`/`encodeDead`/`encodeMinted`) | engine-only. Crypto-shredding: `minted` is slots made quorum-durable, `bind/` is identity→slot, `dead/` carries an erasure through the log. The one namespace here a wipe cannot rescue — `bind/` is the only route from an identity to the slot its ciphertext was sealed under |
| `_log/next_request_seq` | decimal counter | **by-decision** — a monotonic integer has no shape to change, and advancing it past any observed value repairs it | `src/js/worker_log.zig` (`seq_key`) | engine-only. In app.db, not a log.db — so the worker opens no log.db |
| `_magic/` | — | **unwritten** | none | Engine-only; reserved for magic-link tokens |
| `_oidc/*` | JSON `{v, …}` for the records the package WRITES | **versioned** (`REC_V`, one for the whole namespace — the shapes it owns are halves of a single login). **Two sub-keys are excluded and the exclusion is the point:** `_oidc/session/{sid}` is written by the TENANT's login handler (`web/auth/index.mjs`) and only read here, and `_oidc/config/{name}` is operator-seeded. A reader cannot demand a stamp from a writer it does not own — that is a reader upgraded ahead of its writers, which is the same hazard `cluster/{id}` has in §1g | `src/js/packages/@rewind/oidc/index.mjs` | shim-writable; keyset/code/at/rt/device/state. Mostly RFC-shaped, but the *envelope* is ours |
| `_rp/*` | JSON `{v, …}` | **versioned** (`REC_V`, shared with `_oidc/*`) | `src/js/packages/@rewind/oidc/index.mjs` (relying-party half); read by `src/js/starter/upload.mjs` | shim-writable; RP state — `state`/`sess/{sid}`/`jwks` |
| `_sched/by_time/{ns_hex}/{id}`, `_sched/by_id/{id}` | JSON wake `{v, when_ns, target, msg, key?, armed_by?}` | **versioned** (`SCHED_REC_V`) — written from SIX near-identical `schedArm` copies, which is why `scripts/ops/record_version_lint.py` exists | `src/js/globals/schedule.js` + `src/js/durable_wake.zig` | shim-writable; load-bearing. Fixed-width zero-pad so lexicographic order == time order |
| `_seg/{log}/n` | decimal counter | **by-decision** — monotonic integer, same as `_log/next_request_seq` | `src/js/packages/@rewind/segments/index.mjs` (`append`) | shim-writable |
| `_seg/{log}/h/{seq:020}` | the customer's own record bytes, opaque | **by-decision** — not our format; the value is passed through untouched | `src/js/packages/@rewind/segments/index.mjs` (`append`) | shim-writable; hot rows, deleted on seal |
| `_seg/{log}/s/{first:020}` | JSON `{v, hash, first_seq, last_seq, count}` | **versioned** (`SEG_IDX_V`) | `src/js/builtin_modules/segments_onsealed.mjs` | shim-writable; the permanent pointer to a sealed segment blob — outlives everything around it |
| `_send/owed/{id}` | JSON `{v, url, method, body, …}` | **versioned** (`SEND_OWED_V`) | `src/js/globals/webhook.js` (`webhook.send`); Zig-visible surface `src/js/owed_retry.zig` (`OWED_PREFIX`) | shim-writable; `webhook.send` / `email.send` durability marker (ordinary envelope-0 kv — no apply-time special case) |
| `_sessions/` | — | **unwritten** | none | Engine-only; reserved for future platform session storage. The platform session *cookie* (`src/js/session.zig`) stores nothing here |
| `_triggers/` | — | **unwritten** as kv | none in app.db | Engine-only. Trigger modules are deploy-tree paths in the manifest (`_triggers/{prefix}/index.mjs`), not rows |
| `_usage/blob/{app\|file}/{sha256}` | length in decimal ASCII | **by-decision** — derived and rebuildable by rescanning the blob store; the key is a content hash, so a rebuild is idempotent | `src/kv/usage.zig` (`ROW_PREFIX`), platform Zig at write time | engine-only. One row per stored object and **no stored total** — the total is a prefix scan, because a value folded at apply time exists on followers and not on the leader. This is the number the storage quota is enforced against |

The shim-owned records above cannot share a version constant: a baked
`__system/*` module runs post-harden and cannot reach a shim's closure, a
package ships in the tenant's deployment, a global ships in the prelude,
and there is no import path between the three. Each declares its own, and
`scripts/ops/record_version_lint.py` (run by `zig build test`) enforces
both halves — that every file touching a namespace declares the constant,
and that no file outside the list writes into one.

A reader refuses a version it does not implement the same way it refuses
an unparseable record, because these namespaces are shim-WRITABLE: a `v`
this build does not know is as likely a customer's forged row as a newer
engine, and both deserve the same answer. The exception is the OIDC
keyset, which throws instead — absent means GENESIS there, so failing
soft would mint a fresh key over the record it could not read and destroy
every token derived from it.

`_subscriptions/` is **not** a KV namespace — it is a deploy-tree path prefix
for subscription modules (`_subscriptions/{name}/index.mjs`,
`src/js/deployment_cache.zig`), and appears in none of the three lists.

### 1g. Control-plane directory (replicated KV in `__directory__` group)

Source: `src/cp/directory.zig`.

| Key | Value | Ver? | Class | Notes |
|---|---|---|---|---|
| `cluster/{id}` | `"url1,url2,…"` comma-joined origins | none (versioned by KEY) | **by-decision** — the directory's values are read across a ROLLING CP upgrade, where no in-band marker is distinguishable from data: prefix `v1,` and the previous build dials a node called `v1`. The field cannot be introduced by the deploy that introduces it. So the directory versions by KEY — a changed shape is a NEW key, invisible to old readers by construction — the same idiom as the path-versioned surfaces in §1b. `applyClusterFromJoined` guards the shape so it cannot be widened in place instead | topology SSOT |
| `placement/{tenant}` | bare `{cluster_id}` | none | **by-decision** — wipe-on-change, and that is not a hope: this value has ALREADY changed shape once, from `{state}:{cluster}` to a bare id, and the wipe is how it was done | domain of one identifier |
| `plan/{tenant}` | JSON `{tier, overrides{…}}` | none | **by-decision** — additive by construction (`ignore_unknown_fields`), and a blob the parser cannot read resolves to the tenant's DEFAULT rather than failing the request: free for a customer, platform for a reserved id. A format that fails toward a safe answer does not need a version to fail safely | CP dumb, DP parses (`src/plan/root.zig` `parseBlob`) |
| `host/{host}` | `{tenant_id}` | none | **by-decision** — a single identifier; a richer value would be a different key | domain index |
| `cert/{host}` | **packed binary** `[u8 v=1][u32 BE cert_len][cert_pem][key_pem]` (`directory.zig` `packCert`/`CERT_PACK_VERSION`) | **yes (v1)** | **versioned** (registry `cert_pack`) — the packed-binary KV idiom `_keys/*` now follows | front-door mirror in `front/main.zig` |

### 1h. Tokens / credentials

| Format | File | Layout | Ver? | Class |
|---|---|---|---|---|
| Service JWT (HS256) | `src/jwt/root.zig` (`mint`, `CLAIMS_VERSION`) | `{v:1, exp[,caps][,tenant]}` HS256 | **yes (`v`)** | **versioned** (registry `service_jwt`). The claim shipped at the freeze and NOTHING read it until §1i's pass — a token stamped with an unknown version is now refused, before any claim is parsed. A `v`-less token is still accepted: service tokens are minted outside this repo too | 
| SSE/rich-payload JWT | `src/jwt/root.zig` (`mintWithPayload`) | `{v,tenant_id,sid,caps,exp}` as the SSE design describes it | — | **unwritten** — the mint FUNCTION exists and nothing calls it. The shape in this row lives in a doc comment, not in a producer, so there is no format here yet to version. Found by asking whether the `v` was exercised, which is the question §1i exists to ask |
| Move secret | `src/js/snapshot_catchup.zig` (`MOVE_SECRET_HEADER`) | hex shared secret | n/a | **by-decision** — an opaque secret compared for equality. There is no structure to interpret, so there is nothing a version could change |
| Services JWT secret | `src/jwt/root.zig` | hex shared secret | n/a | **by-decision** — same |

### 1i. Exercising the switch

Every version in the inventory is at v1 (the deployment manifest at v2), so
until these tests existed no reader had ever *branched* on one — the first
real bump would have been the first execution of every switch site, at the
moment a mistake means a replica or a replay reads the wrong bytes.

Each versioned format with a Zig decoder now has a test that encodes the
current version and a synthetic future one and asserts the reader refuses
what it does not implement. (The JS-owned records are the exception, and
the note at the end of this section says so rather than implying otherwise.) Three properties are worth stating, because they are what the
tests are actually for:

- **Refusal, not interpretation.** No reader here dispatches to a second
  implementation, and that is the deliberate posture, not a gap: pre-launch
  there is no corpus to keep readable, so a version it does not know is
  refused and the data is rewritten (`decisions.md` — no pre-launch
  back-compat). The switch these fields buy is *fail loudly instead of
  mis-reading*; a genuine two-version reader is a post-launch problem.
- **Version before width.** A future value is usually a different length
  too, and checking length first reports a rolling upgrade as corruption —
  which sends an operator after a disk fault. The keyring, the JWT and the
  lockfile all check version first, and their tests pin that ordering.
- **Drive the real decoder.** A test that re-implements the decode to assert
  on it passes with the check deleted. The transport test calls `onRecv`
  itself for exactly this reason.

A version field no reader branches on is indistinguishable from no field at
all, and the base service JWT was the proof: it stamped `"v":1` from the
freeze onward, nothing ever read it, and a second minter (the smoke harness)
did not even emit it — for months, with no symptom.

**What is still untested, stated rather than papered over:** the eight
shim-owned records in §1f have their readers' checks written but not
exercised. Those readers are baked `__system/*` modules and packages, which
the Zig unit-test harness cannot dispatch (it compiles inline source, not a
deployment), so a refusal test needs a conformance case or a smoke. What IS
covered today is the writer side — that the marker carries `v` — plus
`record_version_lint.py`, which proves every file touching a namespace
declares the constant. Neither proves the reader drops a record it cannot
read.

## 2. Sensitivity tiers (drives the strategy)

- **Tier A — raft-log-persisted formats.** Entry frame, envelope codec, writeset
  ops, multi payload, and (A*) the inline tapes. A format change here must be
  agreed by every replica and survives in the durable log. The entry-frame magic
  `0xF7` and the "reject retired type bytes loudly" discipline already give us a
  *fail-loud* guarantee; we want to add an *explicit, forward-compatible* version
  so the next change can be a soft upgrade, not a wipe.
- **Tier B — on-wire / S3 / config.** Versionable cheaply: a magic+version-byte
  header (binary wire), a `"v":N` field (JSON), an HTTP path/header bump, or an
  S3 key-prefix version. Mostly additive; mixed-version coexistence is fine.
  - **B-hot** is the exception: the coalesced raft transport was deliberately
    shrunk 28→20B (Phase 2f deleted the `floor` field). Adding bytes here costs
    per-message bandwidth at high group fan-out. Version it *without widening the
    per-record header* — see §3.
- **Tier C — opaque / externally pinned.** raft-rs WAL, kvexp/LMDB, PEM keys. We
  don't own these byte layouts; they're pinned by dependency commit. Our lever is
  a **rove binary version + js-engine version stamped at startup and into the log**
  so a WAL/store replay is auditable, plus a per-store schema marker for the
  small node-local manifests we *do* own (group manifest).

## 3. Recommended versioning convention

Adopt **one idiom per format class**, plus a single in-code registry so the whole
surface is auditable at a glance.

1. **Binary wire/log formats (Tier A + binary B):** prefix with a 1-byte version
   *after* the existing magic/type discriminant. Where there's a magic
   (`0xF7`, `"MGS2"`, `"RTAP"`, `"RREA"`), keep the magic and add/keep a
   `u8 version`. Where there's only a type byte (envelope codec), reserve a
   version: option (a) a `u8 version` after the type byte, or option (b) carve a
   version nibble into the type byte's high bits. Recommend (a) — explicit and
   roomy. Decoders reject unknown versions loudly (we already do this for retired
   types).
2. **B-hot coalesced transport (no widening):** put one **frame-level** version
   byte at offset 0 of the *payload* (before `count`), not in each 20-byte
   record. Cost: 1 byte per coalesced frame (amortized over many records), zero
   per-record growth. Alternative: steal the top 8 bits of `count` (count never
   approaches 2^24). Recommend the single leading byte — clearer.
3. **JSON artifacts (manifest, sidecar, configs, plan):** keep/standardize the
   `"v": N` field; decoders tolerate unknown *higher* minor fields, reject
   unknown *major*. Already done for manifest + sidecar.
4. **Packed-binary KV values (cert):** prepend a 1-byte version:
   `[u8 v=1][u32 BE cert_len][cert_pem][key_pem]`.
5. **KV key-schema namespaces:** rather than version every value, write a single
   per-store `_meta/schema_version` key (one per `app.db` / `__root__.db` /
   `__directory__`) recording the bundle of schema versions the store was last
   written under. Individual JSON values that need finer tracking get their own
   `"v"`. JS-shim-owned formats (`_send/owed`, `_sched/*`, `_blob/owed`) carry a
   `"v"` inside their JSON, owned and bumped by the shim.
6. **Tokens:** add `"v":1` to the base service-JWT payload (the rich SSE token
   already has it).
7. **S3 key prefix:** make `key_prefix_base` carry an optional layout version
   segment (e.g. `…/v1/{instance}/…`) so a future object-layout change is a new
   prefix, old objects coexist. Content-addressed blobs themselves need no
   internal version.
8. **One registry:** a `src/version.zig` (or `src/format_versions.zig`) that
   declares every format's current version constant in one place, imported by each
   codec. Bumping a format = editing one line + the decoder. This file is the
   single source of truth for the audit and for the `--version` dump.

## 4. JS engine version (net-new)

**Goal:** replay must run an old request on the *same* JS engine that produced it.
Tapes are engine-agnostic *data*; the engine is the *interpreter*. A quickjs/
arenajs behavior change (e.g. a numeric or `Intl` tweak) would make an old tape
replay diverge under a new engine.

**Current state:** zero. `Snapshot` (`src/qjs/snap.zig`) has no version field;
arenajs is pinned only by the `build.zig.zon` commit hash
(`arenajs#15e77d1…`); the browser WASM engine lives as a single
`web/replay/_static/qjs_arena_wasm.{js,wasm}` with no version. Nothing records
which engine ran a request.

**Engine-version identity.** Define a small monotonic integer
`js_engine_version` (NOT the arenajs commit hash — too unwieldy and not
ordered). Bump it whenever we adopt an arenajs build whose *observable semantics
or bytecode* could change replay. Source it from a single constant
(`src/qjs/version.zig` → `pub const JS_ENGINE_VERSION: u16 = 1;`), bumped by SOP
when the arenajs pin moves in a semantics-affecting way. Keep a mapping
`engine_version → arenajs commit` in that file's comments.

**Where to stamp it (in dependency order):**

1. `src/qjs/snap.zig` — add `version: u16` to `Snapshot`, set from the constant
   at worker startup. *(Phase 0, trivial.)*
2. `src/log/root.zig:275-326` — add `js_engine_version: u16` to `LogRecord`
   (passenger field), set at dispatch from `snapshot.version`. Carries into the
   ndjson log batch. *(Phase 0.)*
3. `src/tape/root.zig` — add `js_engine_version: u16` to the readset header
   (a peer of `seed`/`timestamp_ns`), bump `READSET_VERSION` 6→7, header 22→24B.
   This is the authoritative per-request stamp. *(Phase 1 — **DONE** 2026-06-23.)*
   **Correction:** the original plan said "mirror in `rtap.mjs`," but `rtap.mjs`
   only parses per-tape blobs, NOT the RREA readset — replay reads `seed` /
   `timestamp_ns` (and now `js_engine_version`) from a structured **bundle JSON**
   the log-server builds (`flush_writer` emits it; `web/admin/_static/api.js`
   composes it; `web/replay/_static/wasm-app.mjs` reads `bundle.js_engine_version`
   and errors if it ever mismatches `REPLAY_ENGINE_VERSION`). So the real
   "mirror" is the bundle JSON + `wasm-app.mjs`, which is where it landed. No
   `rtap.mjs` change was needed.
4. `src/files/manifest_json.zig` — add optional `"js_engine_version"` to the
   deployment manifest as the *default* for the deploy; per-request readset wins
   if present (covers a worker upgraded mid-deploy). *(Phase 2.)*

**Selecting the engine at replay time (Phase 3, post-GA):**

- Publish per-version WASM engines as content-addressed blobs, e.g.
  `_static/__replay__/qjs_wasm_{version}.wasm`, and a registry mapping
  `version → blob hash` (in the manifest or a well-known object).
- Replay driver: `version = readset.js_engine_version ?? manifest.js_engine_version`
  → fetch the matching WASM → run. Falls back to the bundled engine if a version
  isn't published yet.
- This is the only HIGH-effort piece and is genuinely deferrable: until we ship a
  semantics-affecting engine bump, there is exactly one engine version, so the
  selection is a no-op. The *stamp* (Phases 0–2) is what must land pre-launch so
  old requests are forever attributable; the *multi-engine fetch* can wait until
  the first bump.

## 5. Open questions / things to confirm

- **`tenant/root.zig` SQLite naming** — confirm `files.db`/`log.db` per-instance
  files are fully dead (comments say retired; the provisioning path still names
  them). If dead, delete the naming so it stops reading as a live format.
- **raft-rs WAL / kvexp internal versions** — do raft-rs-zig and kvexp expose any
  on-disk format version we can read at open() for the audit log? If so, log it
  at startup; if not, the dependency commit pin is the only handle.
- **Entry-frame version vs. wipe** — **RESOLVED (2026-06-23): magic-IS-the-version.**
  `0xF7` == entry-frame v1; the next change reserves `0xF8`. No per-entry version
  byte was added (Tier-A, every raft entry — `wire width vs interpretation`).
  Same idiom for the envelope codec (the type byte is the discriminant; v1 is the
  current 0/1/2 set, the next change reserves a new type). Both are recorded in
  the registry (`src/rewind/version.zig` `ENTRY_FRAME_VERSION` /
  `ENVELOPE_FORMAT_VERSION`) and the decoders already reject unknown
  discriminants loudly. The two formats that had NO discriminant DID get an
  explicit leading version byte: the coalesced transport frame (one byte per
  frame, not per record) and the packed cert frame.
- **`_meta/schema_version` granularity** — one bundle key per store vs. per
  namespace. Bundle is simpler; per-namespace is finer for independent shim
  upgrades. Lean bundle.
- **engine-version bump policy** — **RESOLVED (2026-06-23): SOP written** in
  `src/qjs/version.zig`'s doc comment (bump on observable numeric/string/`Intl`/
  `Date`/regex formatting changes, emitted-bytecode changes, or PRNG/clock
  plumbing changes; do NOT bump for allocator/perf/GC/build-flag changes). The
  file also keeps the `version → arenajs commit` map. The WASM replay engine
  mirrors the constant as `REPLAY_ENGINE_VERSION` in `wasm-app.mjs` (bump in
  lockstep when the WASM is rebuilt from a semantics-affecting pin).

## 6. Proposed phasing

- **Phase 0 — registry + cheap stamps (pre-launch, low risk).**
  `src/version.zig` registry; `rove --version` dumps binary + engine + all format
  versions; `js_engine_version` constant + `Snapshot.version` + `LogRecord`
  passenger field; `_meta/schema_version` written on store create. No wire changes.
- **Phase 1 — binary wire/log version bytes (pre-launch).** Entry frame, envelope
  codec, writeset/multi, coalesced transport (frame-level byte), cert packing,
  base JWT `"v"`. Bump readset 6→7 to add `js_engine_version`; mirror `rtap.mjs`.
  Wipe data after. This is the "freeze v1" milestone.
- **Phase 2 — JSON/config + S3 prefix (pre-launch or fast-follow).** Standardize
  `"v"` across manifest/sidecar/plan/configs; optional engine-version default in
  manifest; optional S3 key-prefix version segment.
- **Phase 3 — multi-engine replay (post-GA, on first engine bump).** Per-version
  WASM publishing + registry + replay-driver selection.

Validation throughout: `zig build test`, `v2-test`, and the consensus +
front/route smokes (run consensus smokes ≥6× — a 1-in-3 flake is a real abort).

---

# Part II — Customer-observable contracts to freeze before launch

The format versioning above is only half the story. The bigger, more
*irreversible* surface is anything a **customer** can observe or depend on. By
Hyrum's law, the moment a customer exists, every observable becomes a contract —
the key they wrote, the ID we showed them, the header they read, the API shape
they coded against. Pre-launch we can wipe and re-cut; post-launch we can't.

The lever at every level below is the same and it is cheap **today** and
impossible **later**: *reserve a generous namespace and make outputs
self-describing now.*

Irreversibility ladder (worst first):
**crypto envelopes → shared namespaces (KV / headers / paths / IDs) → customer
API shapes → wire/disk formats (Part I).**

## 7. The pre-customer freeze list

### 7.1 KV namespace reservation — **CRITICAL, do now**

`src/js/reserved.zig:82-92` (the module now lives at `src/reserved/root.zig`)
reserves only **9 enumerated prefixes** from customer
writes (`isCustomerWriteReserved`, `globals.zig:738,832`). A customer can write
`_mydata`, `_events/...`, `_outbox/...`, or any `_foo` that isn't one of the 9 —
so we can **never** claim a new `_`-prefix for the platform later. Worse: the
"retired" prefixes (`_events/`, `_outbox/`, `_dlq/`, `_send/`, `_blob/`,
`_sched/`) are currently *free for customers to grab*, and three of them
(`_send/owed`, `_blob/owed`, `_sched/*`) are actively written by JS shims as
ordinary customer `kv.set` — so a customer can today collide with their own
webhook/scheduler state.

- **DECIDED (2026-06-18):** reserve the **entire leading-`_` keyspace** from
  customer writes. Route the JS-shim writes through a *privileged* write path
  instead of the customer-guarded `kv.set`, so the shims keep working while
  customers are blocked from the whole `_` namespace.
- Customers get the entire non-`_` keyspace; platform owns all of `_`. One rule,
  documented, forever-extensible.
- Reads of reserved keys are NOT blocked and must not be — `_config/` is a
  documented customer-readable namespace (`kv.js`/`reserved.zig`). Reservation is
  a write-side concern only.

> **CORRECTION (2026-06-19, during impl):** the shims write more `_`-prefixes
> than the original audit's three. Enumerated from `src/js/globals/*.js`, the
> prefixes written from JS-shim code (some in non-`__system/` handler context,
> `is_system_module=false`) are at least: `_send/` (webhook), `_blob/` (blob),
> `_sched/` (scheduler), and — crucially — `_oidc/`, `_rp/`, `_admin/`
> (`oidc.js`) and `_seg/` (`segments.js`). So the privileged path / writable
> allowlist must cover all of these, not just three.
>
> **Also:** `_harden.js` (which deletes `globalThis._system`) is documented in
> `globals.zig` as **"NOT a privilege boundary"** (natives self-gate; deletion
> is API hygiene). A `_system.kv.setReserved` that bypasses the guard purely by
> being unreachable would lean on `_harden` as a boundary. Since the reservation
> is per-tenant integrity-hygiene (a customer writing a `_` key only corrupts
> their OWN store — no cross-tenant impact), that reliance is the same risk class
> as the reservation itself, but it is a deviation from the stated principle and
> needs a conscious call. Two viable shapes:
>   - **(b) allowlist:** reserve all `_` from customers EXCEPT the verified
>     shim-writable prefixes above; `reserved.zig`-only, no native/freeze/auth
>     surgery, zero regression risk, and a strict prerequisite for (a). Residual:
>     customers can still write the shim prefixes in their own store (per-tenant
>     self-footgun). Needs multi-binary smoke verification that the allowlist is
>     complete (a missing entry throws `reserved_key` inside a live shim).
>   - **(a) privileged binding:** add `_system.kv.setReserved`/`deleteReserved`,
>     edit webhook/blob/scheduler/oidc/segments shims to capture `_system.kv` and
>     use it, reserve ALL `_`. Closes the footgun but touches auth-sensitive and
>     base-snapshot-eval (segfault-prone) code.

### 7.2 KV write-time limits — **do now (also a correctness bug)**

Max key 256B / max value 1 MiB are enforced **only at snapshot-replication time**
(`snapshot_stream.zig:48-49,154`), not at `kv.set` (`globals.zig` jsKvSet has no
check, nor does `kvstore.put`). A customer's 2 MiB value succeeds locally, then
the tenant fails on snapshot/move — a divergence + opaque failure, not just UX.

- **Decision:** enforce limits at `kv.set` with a clear error. Pick the numbers
  now and set them **conservatively** — limits can be *raised* later safely,
  never *lowered*.

### 7.3 Internal HTTP headers — **CRITICAL (security + reservation), do now**

`installHeaders` (`globals.zig:2787-2812`) strips only IP-transport headers. The
platform's own `X-Rewind-*` headers (`X-Rewind-Tenant`, `X-Rewind-Move-Secret`,
`X-Rewind-Snapshot-*`, membership headers — full list in
`src/js/snapshot_catchup.zig:41-44`, `src/cp/main.zig:182-186,1474-1480`) are
**passed through to the customer handler** on inbound, and customers can also
*set* `X-Rewind-*` on responses (`response_building.zig` `isEmittableHeaderName`
doesn't reject them).

- **Decision (must, before any customer):** strip the whole `X-Rewind-*` prefix
  from inbound before the handler sees it, and reject it from customer response
  headers. Reserve `X-Rewind-*` (internal) and `X-Rove-Internal-*` (future)
  prefixes platform-wide; keep `X-Rove-Correlation-Id` as the one
  intentionally-customer-facing tracing header.
- **Verify** whether any internal endpoint *trusts* an inbound `X-Rewind-Tenant`
  / `X-Rewind-Move-Secret` (confused-deputy). Stripping closes it regardless, but
  confirm there isn't a live privilege path. (Related:
  `project_connection_holder_security` — confused-deputy via customer
  `http.send` is the known threat model.)

### 7.4 Tenant ID charset/length — **do now**

Tenant/instance ID is **customer-chosen**, capped at 64 chars
(`tenant/root.zig:84`). It's the permanent primary identity (URL host, S3 key
segment, log scope).

> **CORRECTION (2026-06-19):** the audit's "no enforced charset" was wrong.
> `validateInstanceId` (`tenant/root.zig:812`) already enforces 1–64 chars and
> `[a-zA-Z0-9_-]` (rejects spaces, slashes — tested at :1106). So this item is
> *tightening*, not adding-from-scratch.

- **Decision:** if instance_id will ever be a DNS subdomain
  (`*.rewindjs.app`), tighten to DNS-label-safe now —
  `^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$` (lowercase, hyphen-only — **drop `_`**,
  which is invalid in DNS labels; no leading/trailing/double hyphen; ≤63). This
  is the strictest plausible spec; loosening later is always safe, tightening is
  not.
- **Carve-out required:** the platform's own reserved tenants use the `__*__`
  form (`__admin__`/`__root__`/`__auth__`/`__replay__`), which a DNS-label-safe
  validator would reject. Confirm whether those are created via
  `validateInstanceId` and, if so, exempt the `__*__` form. So this is not a
  one-line regex swap.

### 7.5 Customer-visible IDs — **decided now**

| ID | Today | Leak / risk |
|---|---|---|
| `request_id` | bare 16-hex, **bit-packs `worker_id` in top 16 bits** (`log/root.zig:547-564`); shown in logs API + `request.actor.request_id` | customers will parse worker identity / assume monotonicity |
| `deployment_id` | bare 16-hex truncated SHA-256 of manifest (`manifest_json.zig:281-310`) | content-hash semantics + hash algo frozen |
| `session_id`, `fetch_id` | bare 64-hex (CSPRNG / `SHA256(request_id‖"FTCH"‖idx)`) | uniqueness/determinism assumed |

- **DECIDED (2026-06-18):** add Stripe-style **type prefixes to *all*
  customer-visible IDs** — `dep_` (deployment), `req_` (request, in the logs
  API + `request.actor`), plus prefixes for session and fetch IDs — so every ID
  format stays versionable behind its prefix. Touches `request.actor`, log
  cursors, and S3 key segments; sequence accordingly.
- **DECIDED (2026-06-18):** stop leaking `worker_id` in `request_id` — do not
  surface internal node identity to tenants (the prefixed `req_…` becomes the
  only customer-facing form).
- Cursor (`kv.prefix`) is "pass back the last key" — fine; just **document it as
  opaque** so we're free to change it.
- Content-hash (SHA-256) is genuinely frozen; mitigate future change via the S3
  key-prefix version segment (Part I §3.7), not a re-hash.

### 7.6 Handler API headroom — **mostly document, cheap**

Good news: most effect APIs already take **extensible options objects** (unknown
fields are ignored), so additive growth is safe. The reservations to make now:

- Reserve a **platform option-key namespace** in every options object — e.g. a
  `$rewind` / leading-`_` key convention — so we can add platform directives
  (priority, zone) without colliding with customer keys.
- Reserve `request.rewind.*` (or `request.platform.*`) for future request fields.
- Reserve handler **export names** `onError` / `onPanic` for future
  error/uncaught-exception callbacks (deferred today; just don't let them mean
  anything customer-defined).
- Activation `kind` is a sealed enum (fine — new kinds are opt-in via new export
  names; missing export = fail-loud).
- Reserve the `__system/*` builtin-module names and `__*__` tenant names with an
  explicit validator (today it's collision-by-convention, not enforced).

### 7.7 Reserved URL paths / hostnames — **mostly done; add validation**

- `/_system/*` and `/_assets/{hash}` are already intercepted before tenant
  routing (`worker_dispatch.zig:2693,2717,2482`) — **document them as reserved**;
  customers can't route there.
- Hostnames: the CP directory accepts **any** host (`directory.zig:752`) with no
  reserved-subdomain check. If platform services will live at `auth.` / `app.` /
  `api.` / `admin.` (they already do on `rewindjs.com`), **reserve those labels**
  at `/_control/host` write time before customers can claim them.

### 7.8 Crypto algorithm agility — **gate the design now**

- **Encryption at rest is not built yet** (PLAN §9) — this is the *ideal* moment.
  Mandate that the at-rest ciphertext envelope carries `[alg_id][key_version][iv]
  …[tag]` from the first line of code, with a documented algorithm-id space, so
  key/algorithm rotation is forever possible. Make this a design-review gate on
  Phase 9.
- **Service JWT (HS256)** has no `kid` and no rotation window
  (`jwt/root.zig:9`). Add `"v"` + a `kid`/secret-version so we can roll the
  shared secret with a grace period. OIDC's RS256 path already has `kid` +
  current/next/retiring rotation (`oidc.js`) — good, leave it.
- **Shared secrets** (move-secret, services-JWT secret): write the rotation SOP;
  accept N-old + 1-current during a window.
- Content-hash + `crypto.sha256`/`hmacSha256` customer outputs are bare hex —
  document as algorithm-implicit (SHA-256 forever) or add an explicit `alg` arg
  in a future `crypto` v2; do not silently swap the algorithm.

## 8. Consolidated pre-customer change list (prioritized)

**MUST (irreversible if skipped; mostly cheap):**
1. Reserve the entire leading-`_` KV keyspace from customer writes; move shim
   writes to a privileged path (§7.1).
2. Enforce KV key/value size limits at write time, set conservatively (§7.2).
3. Strip `X-Rewind-*` inbound + reject from customer responses; reserve the
   internal header prefixes (§7.3). *(security)*
4. Lock tenant-id charset/length spec + validate at provision (§7.4).
5. Gate Phase-9 encryption-at-rest on an alg-id + key-version ciphertext envelope
   (§7.8) — design now even though code is later.

> **IMPLEMENTATION STATUS (2026-06-20, branch
> `worktree-docs+format-versioning-audit`).** All five MUST items landed; full
> `zig build test` green after each.
> 1. **DONE** `40ed6c9` — `reserved.zig` denies all leading-`_` except the
>    verified `SHIM_WRITABLE_PREFIXES` allowlist (option (b)). Privileged-binding
>    (a) — to also close the per-tenant self-footgun on the shim prefixes —
>    remains deferred. **Allowlist runtime-verified:** `oidc_smoke_v2`
>    (provider `_oidc/` writes) and `oidc_rp_smoke_v2` (relying-party `_rp/`
>    writes + operator dashboard / log + CP chokepoints) both PASS against
>    binaries built with all four changes — confirming the allowlist is complete
>    and that items 2–4 don't regress the auth stack. Static grep also clean.
> 2. **DONE** `5e22a06` — `kv.set`/`kv.delete` reject oversized writes fail-fast
>    (`key_too_large`/`value_too_large`); caps referenced from the canonical
>    kvexp `snapshot_stream` constants.
> 3. **DONE** `c2932c8` — `x-rewind-*` / `x-rove-internal-*` stripped inbound +
>    rejected on responses (`reserved_headers.zig`); `x-rove-correlation-id`
>    preserved.
> 4. **DONE** `f20c2de` — `validateInstanceId` tightened to DNS-label-safe with
>    a `__*__` platform carve-out.
> 5. **DONE** — Phase-9 design gate written into PLAN.md §Phase 9 (self-
>    describing ciphertext envelope mandatory; code still UNBUILT).

**SHOULD (cheap headroom, do during the freeze):**
6. Type-prefix displayed IDs (`dep_`/`req_`); stop surfacing `worker_id` in
   `request_id`; document cursor opacity (§7.5).
7. Reserve handler export names + platform option-key namespace + `request.rewind.*`
   (§7.6).
8. Reserve platform subdomains at host-registration; document reserved paths
   (§7.7).
9. Service-JWT `"v"` + `kid`/secret-rotation SOP (§7.8).
10. The Part I format version bytes / `src/version.zig` registry + the
    `js_engine_version` stamp (Part I §6, Phases 0–1).

> **SHOULD STATUS (2026-06-23).**
> - **7 DONE** — handler-shape.md §9 "Reserved for the platform": export names
>   (`onError`/`onPanic`, `on*`), `$`-prefixed effect option keys,
>   `request.rewind.*`, plus the platform-identifiers-are-opaque contract and
>   cross-refs to the kv / header / identity reservations. Doc-only (reserving =
>   documenting so a future feature can claim it without breaking handlers).
> - **8 DONE** `5ffd2a8` — `validateInstanceId` denies a curated set of
>   platform/infra subdomain labels (auth/api/app/admin/www/…), so a customer
>   can't claim `{label}.<zone>` via the wildcard route. `acme` deliberately
>   left available (example-tenant convention; ACME label is `_acme-challenge`).
> - **9 PARTIAL** `7bf2528` — service-JWT payload carries `"v":1`. The `kid` +
>   N-secret rotation window (the valuable half) is deferred; tokens are
>   internal + ~5-min, so versioning value is modest.
> - **6 DONE** (2026-06-23) — type prefixes on all customer-visible ids, applied
>   **only at customer boundaries** (internal u64 / hex / router-keys / S3-keys /
>   manifest stay bare): `request.actor.request_id`→`req_<16hex>`
>   (`trigger_dispatch.zig`), `request.session.id`→`sess_<64hex>` +
>   `activation.fetch_id`→`ftch_<64hex>` (`globals.zig`), and the served logs API
>   (`flush_writer` record JSON + `standalone` list/cursor/`/show`)→`req_`/`dep_`
>   prefixed strings, with `web/admin/_static/api.js` updated to match. Central
>   format/parse helpers live in `rove-log` (`formatPrefixedId` /
>   `parsePrefixedId` / the prefix consts). **worker_id removal**: per the
>   2026-06-23 decision we kept the *opaque-by-contract* form — the internal u64
>   (worker_id in the top 16 bits) is unchanged for index/pagination/uniqueness;
>   the `req_` prefix + the documented don't-parse contract is the mitigation
>   (NOT a reversible mix). Verified e2e by `inbound_chunk_smoke_v2` (`/list`→
>   `/show` round-trip) + a flush_writer unit assertion on the served JSON.
> - **10 DONE** (2026-06-23) — js-engine-version stamp + Part I format-version
>   bytes. `JS_ENGINE_VERSION` const (`src/qjs/version.zig`) → `Snapshot.version`
>   → stamped on every production `Readset` → `READSET_VERSION` 6→7 (header
>   22→24B) → `TapePayloads`/`LogRecord` → served log JSON → replay bundle →
>   `wasm-app.mjs` (engine-mismatch guard). Format-version bytes: coalesced
>   transport frame (`transport.zig` `FRAME_VERSION`), packed cert
>   (`directory.zig` `CERT_PACK_VERSION` + the front-door's mirror); entry-frame /
>   envelope use magic-IS-the-version (see §5). Registry + `rewind --version`
>   dump in `src/rewind/version.zig`. The READSET bump forces the pre-prod data
>   wipe noted in the resume note + §6.

**DECIDED (2026-06-18):**
- KV: blanket leading-`_` reservation (§7.1), not the single-`_rove/`-prefix
  variant.
- IDs: type-prefix **all** customer-visible IDs and hide `worker_id` (§7.5).

**STILL OPEN (judgment calls):**
- S3 key-prefix version segment now vs. at first layout change.

**EXPLICITLY NOT doing (avoid over-engineering — simplicity/safety pref):**
- Opaque cursor objects (current last-key cursor is fine; just document).
- Multihash content addressing (prefix-version the S3 layout instead).
- TLV/extension areas in wire formats (a version byte is enough).
