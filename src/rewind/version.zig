//! Format-version registry (`docs/format-versioning-audit.md` §3.8) —
//! the single in-binary place that names every wire / on-disk / persisted
//! format version, so the whole surface is auditable at a glance and the
//! worker can dump it (`rewind --version`).
//!
//! Each entry below REFERENCES the owning module's constant rather than
//! re-declaring the value, so the registry can never silently drift from
//! the codec it documents. The few formats whose owning module is not in
//! the worker's import graph (the control-plane cert frame lives in
//! `src/cp/directory.zig`, a different binary) are listed with their
//! value plus a pointer to where the canonical constant + its tests live.
//!
//! ## Versioning idioms (audit §3), for reading the dump
//!
//!  - Where a format has a fail-loud MAGIC or type discriminant
//!    (entry frame `0xF7`, envelope type byte, `RTAP`/`RREA`, `MGS2`),
//!    "version 1" is that discriminant's current shape; the NEXT change
//!    bumps the embedded version field (RTAP/RREA/MGS2) or reserves the
//!    next magic/type value (entry frame `0xF8`, a new envelope type) —
//!    decoders already reject unknown discriminants loudly, so no new
//!    per-record byte was added to the Tier-A raft-log formats
//!    (`wire width vs interpretation`, §5 entry-frame open question
//!    resolved: magic-IS-the-version).
//!  - Where there was NO discriminant, a single version byte was added:
//!    the coalesced transport frame (one byte per frame, not per record)
//!    and the packed cert frame.
//!
//! Pre-launch freeze: every format here is "v1". The point of the field
//! being in place now is that the NEXT change is a soft, fail-loud
//! upgrade instead of a silent mis-decode — see `docs/decisions.md` /
//! the audit for the no-pre-launch-back-compat stance (we wipe, we don't
//! migrate v0→v1).

const std = @import("std");

const qjs = @import("rove-qjs");
const kv = @import("raft-kv");
const files = @import("rove-files");
const log_server = @import("rove-log-server");
const rjs = @import("rove-js");
const bridge = @import("bridge");

/// Human-facing rove binary version. Bump on a release cut. (Git-hash
/// baking via a build option can replace this later; a manual string
/// avoids build-graph surgery for the registry MVP.)
pub const ROVE_BINARY_VERSION = "0.1.0-pre";

/// The JS engine version every request is stamped with (replay-critical).
pub const JS_ENGINE_VERSION = qjs.JS_ENGINE_VERSION;

/// Entry-frame format: magic-IS-the-version. `0xF7` == v1; the next
/// change reserves `0xF8`. No per-entry version byte (Tier-A, every raft
/// entry). Canonical: `src/consensus/envelope.zig`.
pub const ENTRY_FRAME_VERSION: u8 = 1;
/// Envelope codec format: the type byte (0=writeset,1=multi,2=root) is
/// the discriminant; v1 is the current set, the next change reserves a
/// new type. Canonical: `src/kv/envelope_codec.zig` /
/// `src/consensus/envelope.zig`.
pub const ENVELOPE_FORMAT_VERSION: u8 = 1;

/// Cert-pack frame carries an explicit leading version byte. Canonical
/// constant + tests live in `src/cp/directory.zig` (`CERT_PACK_VERSION`),
/// which the worker does not link — mirrored here for the audit dump.
pub const CERT_PACK_VERSION: u8 = 1;

/// Base service-JWT claims-schema version (`"v":1`). Canonical:
/// `src/jwt/root.zig` (string-embedded; not a numeric const to import).
pub const SERVICE_JWT_VERSION: u8 = 1;

/// Write the whole registry as human-readable lines to `w`.
pub fn dump(w: *std.Io.Writer) !void {
    try w.print("rove {s}\n", .{ROVE_BINARY_VERSION});
    try w.print("  js_engine_version    {d}\n", .{JS_ENGINE_VERSION});
    try w.writeAll("  -- raft-log (Tier A; magic/type IS the version) --\n");
    try w.print("  entry_frame          v{d} (magic 0x{X:0>2})\n", .{ ENTRY_FRAME_VERSION, bridge.envelope.ENTRY_FRAME_MAGIC });
    try w.print("  envelope_codec       v{d} (types: writeset={d} multi={d})\n", .{
        ENVELOPE_FORMAT_VERSION,
        kv.envelope_codec.ENVELOPE_TYPE_WRITESET,
        kv.envelope_codec.ENVELOPE_TYPE_MULTI,
    });
    try w.writeAll("  -- on-wire / S3 / tokens --\n");
    try w.print("  coalesced_transport  v{d}\n", .{bridge.transport.FRAME_VERSION});
    try w.print("  snapshot_stream      v{d} (magic 0x{X:0>8})\n", .{ kv.snapshot_stream.STREAM_VERSION, kv.snapshot_stream.STREAM_MAGIC });
    try w.print("  cert_pack            v{d} (src/cp/directory.zig)\n", .{CERT_PACK_VERSION});
    try w.print("  service_jwt          v{d}\n", .{SERVICE_JWT_VERSION});
    try w.print("  deployment_manifest  v{d}\n", .{files.manifest_json.VERSION});
    try w.print("  log_sidecar          v{d}\n", .{log_server.sidecar.VERSION});
    try w.writeAll("  -- replay / tape (must lockstep with rtap.mjs / wasm-app.mjs) --\n");
    try w.print("  tape                 v{d} (magic 0x{X:0>8})\n", .{ rjs.tape.VERSION, rjs.tape.MAGIC });
    try w.print("  readset              v{d} (magic 0x{X:0>8})\n", .{ rjs.tape.READSET_VERSION, rjs.tape.READSET_MAGIC });
    try w.writeAll("  -- customer-visible id prefixes (opaque; §7.5) --\n");
    try w.print("  request_id           {s}<16hex>\n", .{rjs.log.REQUEST_ID_PREFIX});
    try w.print("  deployment_id        {s}<16hex>\n", .{rjs.log.DEPLOYMENT_ID_PREFIX});
    try w.print("  session_id           {s}<64hex>\n", .{rjs.log.SESSION_ID_PREFIX});
    try w.print("  fetch_id             {s}<64hex>\n", .{rjs.log.FETCH_ID_PREFIX});
}

test "registry dump renders all format lines without error" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try dump(&w);
    const out = w.buffered();
    // A couple of anchors so a dropped line is caught.
    try std.testing.expect(std.mem.indexOf(u8, out, "js_engine_version") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "readset              v7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "request_id           req_<16hex>") != null);
}
