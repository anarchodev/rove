// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The spine-free kv facade — the `raft-kv` module root, imported by the
//! data plane and the rove-js worker in place of the consensus-carrying
//! kv module. It re-exports the kvexp-backed "limbs" — `kvstore.zig`
//! (per-tenant state engine) + `writeset.zig` (writeset builder +
//! `applyEncoded`) — plus the metrics types, but no consensus spine.
//!
//! Why a re-export rather than importing the two files directly: Zig
//! forbids `@import` across a module's directory boundary, and
//! `writeset.zig` imports `kvstore.zig` by relative path — so they must be
//! compiled inside ONE module rooted here in `src/kv/` for `KvStore` to be
//! a single type across both (otherwise `writeset.applyEncoded(*kvstore
//! .KvStore, ...)` wouldn't accept a `KvStore` opened by the node). This
//! file is that single root.
//!
//! It pulls in ONLY `kvstore.zig` + `writeset.zig` + `dispatch_metrics
//! .zig`, whose sole non-`std` dependency is `kvexp` — no consensus
//! engine. So this module's link closure is kvexp + liblmdb: the worker
//! binary satisfies rove-js's `@import("raft-kv")` with this module to get
//! the limb types without dragging in a consensus spine.

pub const kvstore = @import("kvstore.zig");
pub const writeset = @import("writeset.zig");
pub const usage = @import("usage.zig");
pub const snapshot_stream = @import("snapshot_stream.zig");

// ── Flat facade ──────────────────────────────────────────────────────
//
// rove-js imports the kv module flat (`kv_mod.KvStore` / `kv_mod.WriteSet`
// / `kv_mod.TrackedTxn` / …), so the LIMB + METRICS exports are mirrored
// flat here. Deliberately ABSENT: every consensus-spine symbol —
// `Cluster*`, `RaftNode*`, `RaftNet*`, `RaftLog*` — the bridge provides
// consensus, so this module carries only the limb types.

// writeset.zig
pub const WriteSet = writeset.WriteSet;
pub const WriteSetOp = writeset.Op;
pub const applyEncodedWriteSet = writeset.applyEncoded;
pub const scanWriteSetPutValue = writeset.scanPutValue;
pub const decodeWriteSetOps = writeset.decodeOps;

// usage.zig (per-tenant stored-byte accounting, folded at apply time)
pub const UsagePool = usage.Pool;
pub const usageRowKey = usage.rowKey;
pub const storedBytes = usage.storedBytes;

// snapshot_stream.zig (raft streaming transfer codec)
pub const StreamDumper = snapshot_stream.StreamDumper;
pub const StreamLoader = snapshot_stream.StreamLoader;
pub const StreamLoaderOptions = snapshot_stream.LoaderOptions;

// kvstore.zig
pub const KvStore = kvstore.KvStore;
pub const KvEntry = kvstore.Entry;
pub const KvDeltaEntry = kvstore.DeltaEntry;
pub const KvRangeResult = kvstore.RangeResult;
pub const KvDeltaResult = kvstore.DeltaResult;
pub const KvError = kvstore.Error;
pub const TrackedTxn = kvstore.KvStore.TrackedTxn;
pub const SeqCounter = kvstore.SeqCounter;
pub const SeqCounterRegistry = kvstore.SeqCounterRegistry;
pub const hashStoreId = kvstore.hashStoreId;
pub const StoreUsage = kvexp.StoreUsage;

// kvexp metrics
const kvexp = @import("kvexp");
pub const KvexpMetricsSnapshot = kvexp.MetricsSnapshot;
pub const KvexpHistogramSnapshot = kvexp.HistogramSnapshot;
pub const KvexpHistogram = kvexp.Histogram;

// dispatch_metrics.zig (std-only; histograms for /_system/metrics)
const dispatch_metrics = @import("dispatch_metrics.zig");
pub const CountHistogram = dispatch_metrics.CountHistogram;
pub const MicrosHistogram = dispatch_metrics.MicrosHistogram;

// envelope_codec.zig (std-only; the replicated-payload header codec —
// the worker (apply.zig) encodes/decodes envelopes through this).
pub const envelope_codec = @import("envelope_codec.zig");
pub const Envelope = envelope_codec.Envelope;
pub const MAX_ID_LEN = envelope_codec.MAX_ID_LEN;
pub const ENVELOPE_TYPE_WRITESET = envelope_codec.ENVELOPE_TYPE_WRITESET;
pub const ENVELOPE_TYPE_MULTI = envelope_codec.ENVELOPE_TYPE_MULTI;
pub const decodeEnvelope = envelope_codec.decodeEnvelope;
pub const encodeEnvelope = envelope_codec.encodeEnvelope;
pub const encodeMulti = envelope_codec.encodeMulti;
pub const decodeMultiInner = envelope_codec.decodeMultiInner;
pub const WriteSetPayload = envelope_codec.WriteSetPayload;
pub const decodeWriteSetPayload = envelope_codec.decodeWriteSetPayload;
pub const encodeWriteSetPayload = envelope_codec.encodeWriteSetPayload;

// Pull the imported files' inline tests into the `raft-kv` test build —
// a bare `pub const = @import(...)` does NOT (Zig only runs tests from files
// referenced by a `test` block / refAllDecls from the test root). Without this
// `zig build kv-test` silently runs zero tests.
test {
    _ = kvstore;
    _ = writeset;
    _ = usage;
    _ = snapshot_stream;
    _ = envelope_codec;
    _ = dispatch_metrics;
}
