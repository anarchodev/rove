---
title: Format & Protocol Versioning Audit (pre-launch)
status: in progress — all 5 MUST landed (smoke-verified); SHOULD 7/8 done, 6/9 partial; item-10 slice remains
date: 2026-06-18
updated: 2026-06-23
---

# Format & Protocol Versioning Audit

> **Resume note (2026-06-23).** Implementation lives on the unmerged worktree
> branch `worktree-docs+format-versioning-audit` (do **not** merge/deploy — other
> deploy work is in flight). Status of every item is in §8. All 5 MUST items and
> SHOULD 7/8 are landed; 6/9 are partial. The one remaining focused effort is the
> **item-10 slice** (Part I format version-bytes + js-engine-version stamp +
> the item-6 `req_`/`dep_` prefix), which needs a coordinated dev-data wipe —
> start it as its own dedicated run. See §8 and `src/qjs/snap.zig` /
> `src/tape/root.zig` / `web/replay/_static/rtap.mjs`.

Pre-launch sweep of every wire protocol, on-disk format, and persisted
key-schema in `rove`, with the current versioning status of each and a
recommended path to a uniform, backward-compatible versioning scheme. Also
scopes the new **JS engine version** concept so replay can pull the matching
engine for an old request.

This is the survey + strategy. Implementation is phased in the last section;
nothing here is built yet.

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

### 1a. Raft-replicated / log-persisted (hardest — replicas must agree)

| Format | File | Layout (current) | Ver? | Tier |
|---|---|---|---|---|
| Entry frame (per raft entry) | `src/consensus/envelope.zig:68` (`ENTRY_FRAME_MAGIC=0xF7`), encode/decode `:83-109` | `[1B 0xF7][8B origin LE][8B seq LE][envelope]` | magic only | A |
| Envelope codec header | `src/consensus/envelope.zig:116-199`; lib copy `src/kv/envelope_codec.zig:27-57` | `[1B type][2B id_len BE][id][payload]`; types 0=writeset,1=multi,2=root_writeset (3–11 retired, rejected loud) | type enum | A |
| Writeset payload (type 0) | `src/kv/writeset.zig:127-201`; readset framing `src/js/apply.zig:116-170` | `[u32 BE op_count]·[op][klen][k][vlen][v]…` then `[u32 ws_len][ws][u32 rs_len][rs]` | none | A |
| Multi payload (type 1) | `src/kv/envelope_codec.zig:80-100` | `[u8 count]·[u32 LE inner_len][inner_envelope]…` | none | A |
| Snapshot baseline (index/term/ConfState) | raft-rs opaque; installed `src/consensus/node.zig:824-850` | `{index u64, term u64, conf_state{voters,learners}}` | raft-rs internal | C |

### 1b. On-wire ephemeral (cross-node / inter-binary)

| Format | File | Layout | Ver? | Tier |
|---|---|---|---|---|
| Coalesced raft transport | `src/consensus/transport.zig:22-35`, `RECORD_HDR_SIZE=20 :86` | `[u32 count]·[u64 group][u64 epoch][u32 msg_len][msg]…` (msg = raft-rs protobuf) | none (epoch fences staleness) | **B-hot** |
| Raft-net frame codec | `src/kv/raft_rpc.zig:18-47` | `[u32 BE len][u32 BE crc][payload]`; ident handshake type=5 | MsgType enum | B-hot |
| Snapshot stream wire | `src/kv/snapshot_stream.zig:43-52` | `[u32 LE MAGIC "MGS2"][u8 ver=1][u64 store_id]·[u16 klen][u32 vlen][k][v]…` | **yes (v1)** | B |
| Snapshot sink endpoint | `src/js/snapshot_sink.zig` + `POST /_system/v2-snapshot-stream` | headers `{mode,tenant,index,term,move-secret}` + stream body | path `v2-` | B |
| Worker→log-server push | `src/js/worker_log.zig:630` `POST /v1/_internal/batch-pushed` | newline-delimited S3 keys, Bearer JWT | path `/v1/` | B |
| Front↔worker proxy (h2c) | `src/front/proxy.zig` | RFC 7540/8441 h2c; headers | n/a (HTTP) | B |

### 1c. S3 objects (content-addressed or batched)

| Format | File | Layout | Ver? | Tier |
|---|---|---|---|---|
| Blob keys (source/bytecode/static) | `src/blob/backend.zig:74-100` | `{prefix_base}{instance}/{file-blobs\|deployments\|log-blobs}/{sha256}` | **no key-prefix version** | B |
| Deployment manifest | `src/files/manifest_json.zig:42,86` | JSON `{v:1, deployment_id, entries[{path,kind,content_type,hash,bytecode_hash}]}` | **yes (v1)** | B |
| Log batch object | `src/log_server/flush_writer.zig:6-18` | `[u32 LE sidecar_len][sidecar JSON][deflate frames…]` | sidecar **v1**; records none | B |
| Log sidecar JSON | `src/log_server/sidecar.zig:23,80-104` | JSON `{v:1, node_id, batch_id, records[…]}` | **yes (v1)** | B |
| Per-record JSON (+ inline tapes) | `src/log_server/flush_writer.zig:232-266` | deflate-wrapped JSON incl. base64 tape payloads | none | B |
| Body-batch pool object | `src/bodies/` (`_pool/{batch_id}`) | concatenated bodies referenced by `BodyRef{batch_id,offset,len}` | none | B |

### 1d. Local on-disk (opaque / pinned by dep)

| Format | File | Layout | Ver? | Tier |
|---|---|---|---|---|
| Raft WAL (shared, all groups) | raft-rs-zig (`{data_dir}/raft-wal/`); opened `src/consensus/node.zig:593` | raft-rs segments + CRC records + hardstate; rove wraps each entry w/ 0xF7 frame | raft-rs internal + entry frame | C |
| kvexp store (app.db / __root__.db) | kvexp (fetched, **not vendored**); `data_dir/{id}/app.db` | LMDB B+tree; applied-raft-idx watermark in kvexp meta | LMDB internal | C |
| Group manifest (node-local) | `src/consensus/node.zig:703-789` (`{data_dir}/__groups__/app.db`) | kvexp; key=id_str, value=epoch decimal ASCII | none | C |
| ACME account key | `src/cp/acme.zig:199-220` (`{data_dir}/acme/account.key`) | PKCS#8 PEM | none | C |

> **Stale / dead (not live formats):** per-instance SQLite `files.db` / `log.db`
> referenced in `src/files/root.zig`, `src/tenant/root.zig:146`, `src/log/root.zig`
> — all comments describe the **retired** files-server/log.db model. The
> `tenant/root.zig` provisioning comment still *names* them; confirm it's dead
> code before relying on it, but treat SQLite-per-instance as gone.

### 1e. Replay / tape (already the best-versioned subsystem)

| Format | File | Layout | Ver? | Tier |
|---|---|---|---|---|
| Per-channel tape | `src/tape/root.zig:73,82` | `[u32 MAGIC "RTAP"][u16 ver=5][u16 channel][u32 count][entries…]` | **yes (v5)** | A* |
| Readset bundle (whole request) | `src/tape/root.zig:88-111,741-786` | `[u32 "RREA"][u16 ver=6][i64 ts_ns][u64 seed]·5 channel blobs·LogHeader` | **yes (v6)** | A* |
| WASM parser mirror | `web/replay/_static/rtap.mjs` | mirrors the above in JS | tracks v5/v6 | A* |

`A*` = log-persisted (tapes ride inline in `LogRecord`) **and** must stay
in lockstep with the JS-side `rtap.mjs` parser.

### 1f. Persisted KV key-schemas (implicit value formats)

Each `_`-prefixed namespace is an implicit format. None are versioned. Source:
`src/js/reserved.zig:82-92` (registry), plus the producers below.

| Key | Value | Producer | Notes |
|---|---|---|---|
| `_deploy/current` | hex u64 (`{x:0>16}`) | `src/js/starter.zig:200` | atomic release pointer |
| `_config/{path}` | JSON | `src/js/config_mirror.zig:26` | mirrors deploy-tree `_config/*.json` |
| `_send/owed/{id}` | JSON marker | `globals/webhook.js` (envelope-0); recognized `src/js/owed_retry.zig:23` | JS-shim-owned |
| `_blob/owed/{hash}` | marker | `globals/blob.js` | JS-shim-owned |
| `_sched/by_time/{ns_hex}/{id}`, `_sched/by_id/{id}` | JSON wake | `globals/scheduler.js` + `src/js/durable_wake.zig:32` | load-bearing; JS-shim-owned |
| `_oidc/*`, `_rp/*` | JSON | `src/js/globals/oidc.js` | many sub-keys; mostly RFC-shaped |
| `_admin/operator/{sha256(email)}` | empty marker | `oidc.js:1242` | allowlist |
| `_log/next_request_seq` | decimal counter | `src/js/worker_log.zig` | internal |
| `_app/`, `_audit/`, `_magic/`, `_triggers/`, `_subscriptions/`, `_sessions/` | mixed | `reserved.zig` | some reserved/unused |

### 1g. Control-plane directory (replicated KV in `__directory__` group)

Source: `src/cp/directory.zig`.

| Key | Value | Ver? | Notes |
|---|---|---|---|
| `cluster/{id}` | `"url1,url2,…"` comma-joined origins | none | topology SSOT |
| `placement/{tenant}` | bare `{cluster_id}` | none | **already post-wipe shape** (was `{state}:{cluster}`) |
| `plan/{tenant}` | opaque JSON | in-payload | CP dumb, DP parses |
| `host/{host}` | `{tenant_id}` | none | domain index |
| `cert/{host}` | **packed binary** `[u32 BE cert_len][cert_pem][key_pem]` (`directory.zig:804-828`) | none | brittle; needs a version byte |

### 1h. Tokens / credentials

| Format | File | Layout | Ver? |
|---|---|---|---|
| Service JWT (HS256) | `src/jwt/root.zig:1-110` | `{exp[,caps][,tenant]}` HS256 | none |
| SSE/rich-payload JWT | `src/jwt/root.zig:218-255` | `{v,tenant_id,sid,caps,exp}` | **yes (`v`)** |
| Move secret | `src/js/snapshot_catchup.zig:6` header | hex shared secret | n/a |
| Services JWT secret | `src/jwt/root.zig:18-21` | hex shared secret | n/a |

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
3. `src/tape/root.zig:741-786` — add `js_engine_version` to the readset bundle
   wire, bump `READSET_VERSION` 6→7, mirror in `web/replay/_static/rtap.mjs`.
   This is the authoritative per-request stamp the replayer reads. *(Phase 1.)*
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
- **Entry-frame version vs. wipe** — since we wipe pre-launch, do we even add an
  explicit entry-frame version, or declare `0xF7`-magic == v1 and reserve
  `0xF8` for v2? (Cheaper, equally fail-loud, but less self-describing.)
- **`_meta/schema_version` granularity** — one bundle key per store vs. per
  namespace. Bundle is simpler; per-namespace is finer for independent shim
  upgrades. Lean bundle.
- **engine-version bump policy** — what counts as "semantics-affecting" enough to
  bump `JS_ENGINE_VERSION`? Need a written SOP so the integer stays meaningful.

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

`src/js/reserved.zig:82-92` reserves only **9 enumerated prefixes** from customer
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
> - **6 PARTIAL** — DECIDED "prefix + document opaque." The *document-opaque*
>   half landed (handler-shape.md §9: platform ids are opaque, don't parse —
>   this is the part that preserves our freedom to change them). The `req_`/`dep_`
>   prefix itself is **all-or-nothing across surfaces** (deployment_loader.zig,
>   web/admin JS deploy app, trigger_dispatch.zig `request.actor`, log-server
>   indexer+flush_writer query/`/show/{id}`, CLI, + several smokes that assert
>   bare hex), so it's a focused cross-cutting effort — bundle with item 10.
> - **10 — REMAINING FOCUSED EFFORT (full slice, DECIDED):** the js-engine-version
>   stamp where replay reads it lives in the replicated tape/readset
>   (READSET_VERSION 6→7 + rtap.mjs mirror + dev-data wipe), coupled to the
>   Part I format-version-bytes Phase 1 (entry frame, envelope codec, transport
>   frame byte, cert packing). The natural next dedicated effort.

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
