//! V2 kv reuse seam — the spine-free kv module the V2 data plane (and,
//! from Phase 2, the reused rove-js worker) imports in place of
//! `src/kv/root.zig` (the `raft-kv` module). It re-exports the kvexp-
//! backed "limbs" — `kvstore.zig` (per-tenant state engine) +
//! `writeset.zig` (writeset builder + `applyEncoded`) — plus the metrics
//! types, but NONE of the V1 consensus spine.
//!
//! Why a re-export rather than importing the two files directly from
//! `src-v2/`: Zig forbids `@import` across a module's directory
//! boundary, and `writeset.zig` imports `kvstore.zig` by relative path —
//! so they must be compiled inside ONE module rooted here in `src/kv/`
//! for `KvStore` to be a single type across both (otherwise
//! `writeset.applyEncoded(*kvstore.KvStore, ...)` wouldn't accept a
//! `KvStore` opened by the V2 node). This file is that single root.
//!
//! Crucially this pulls in ONLY `kvstore.zig` + `writeset.zig` +
//! `dispatch_metrics.zig`, whose sole non-`std` dependency is `kvexp` —
//! NOT `cluster.zig` / `raft_node.zig` / `raft_net.zig` / `raft_log.zig`
//! (the willemt-raft + io_uring V1 consensus spine the rewrite replaces).
//! So this module's link closure is kvexp + liblmdb, nothing from V1
//! consensus. That is the whole point: the V2 worker binary satisfies
//! rove-js's `@import("raft-kv")` with this module to get the limb types
//! without dragging in willemt.
//!
//! Deleted at the V1 cutover along with the rest of `src/kv/` — by then
//! `kvstore.zig` + `writeset.zig` move under `src-v2/` and this seam is
//! unnecessary.

pub const kvstore = @import("kvstore.zig");
pub const writeset = @import("writeset.zig");
pub const snapshot_stream = @import("snapshot_stream.zig");

// ── Flat facade (Phase 2) ────────────────────────────────────────────
//
// rove-js imports the kv module flat (`kv_mod.KvStore` / `kv_mod.WriteSet`
// / `kv_mod.TrackedTxn` / …). Mirror `src/kv/root.zig`'s LIMB + METRICS
// exports here so the V2 worker binary can satisfy that `@import` with
// this spine-free module. Deliberately ABSENT: every spine symbol —
// `Cluster*`, `RaftNode*`, `RaftNet*`, `RaftLog*`, `Envelope*` — the V2
// bridge replaces those, and the worker's references to them are cut in
// the same seam change.
//
// Source of truth for the symbol list is `src/kv/root.zig` lines 36-65
// (the non-spine half); keep the two in sync until the V1 cutover deletes
// root.zig.

// writeset.zig
pub const WriteSet = writeset.WriteSet;
pub const WriteSetOp = writeset.Op;
pub const applyEncodedWriteSet = writeset.applyEncoded;
pub const scanWriteSetPutValue = writeset.scanPutValue;
pub const decodeWriteSetOps = writeset.decodeOps;

// snapshot_stream.zig (raft Phase 2.5 streaming transfer codec)
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

// kvexp metrics
const kvexp = @import("kvexp");
pub const KvexpMetricsSnapshot = kvexp.MetricsSnapshot;
pub const KvexpHistogramSnapshot = kvexp.HistogramSnapshot;
pub const KvexpHistogram = kvexp.Histogram;

// dispatch_metrics.zig (std-only; histograms for /_system/metrics)
const dispatch_metrics = @import("dispatch_metrics.zig");
pub const CountHistogram = dispatch_metrics.CountHistogram;
pub const MicrosHistogram = dispatch_metrics.MicrosHistogram;

// envelope_codec.zig (std-only; the replicated-payload header codec,
// extracted out of cluster.zig so it has a spine-free home — the worker
// (apply.zig) and files-server encode/decode envelopes through this).
pub const envelope_codec = @import("envelope_codec.zig");
pub const Envelope = envelope_codec.Envelope;
pub const MAX_ID_LEN = envelope_codec.MAX_ID_LEN;
pub const ENVELOPE_TYPE_WRITESET = envelope_codec.ENVELOPE_TYPE_WRITESET;
pub const ENVELOPE_TYPE_MULTI = envelope_codec.ENVELOPE_TYPE_MULTI;
pub const decodeEnvelope = envelope_codec.decodeEnvelope;
pub const encodeEnvelope = envelope_codec.encodeEnvelope;
pub const encodeMulti = envelope_codec.encodeMulti;
pub const decodeMultiInner = envelope_codec.decodeMultiInner;

// Pull the imported files' inline tests into the `raft-kv` test build —
// a bare `pub const = @import(...)` does NOT (Zig only runs tests from files
// referenced by a `test` block / refAllDecls from the test root). Without this
// `zig build kv-test` silently runs zero tests.
test {
    _ = kvstore;
    _ = writeset;
    _ = snapshot_stream;
    _ = envelope_codec;
    _ = dispatch_metrics;
}
