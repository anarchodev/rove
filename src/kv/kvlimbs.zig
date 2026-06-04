//! V2 reuse seam — re-exports the two V1 KV "limbs" the V2 spine reuses
//! unchanged (docs/v2-build-order.md §Phase 1 "reuse the limbs"):
//! `kvstore.zig` (the kvexp-backed per-tenant state engine) and
//! `writeset.zig` (the writeset builder + `applyEncoded`).
//!
//! Why a re-export rather than importing the two files directly from
//! `src-v2/`: Zig forbids `@import` across a module's directory
//! boundary, and `writeset.zig` imports `kvstore.zig` by relative path —
//! so they must be compiled inside ONE module rooted here in `src/kv/`
//! for `KvStore` to be a single type across both (otherwise
//! `writeset.applyEncoded(*kvstore.KvStore, ...)` wouldn't accept a
//! `KvStore` opened by the V2 node). This file is that single root.
//!
//! Crucially this pulls in ONLY `kvstore.zig` + `writeset.zig`, whose
//! sole dependency is `kvexp` — NOT `cluster.zig` / `raft_node.zig` /
//! `raft_net.zig` (the willemt-raft + io_uring V1 consensus spine the
//! rewrite replaces). V2 links kvexp + liblmdb, nothing else from V1.
//!
//! Deleted at the V1 cutover along with the rest of `src/kv/` — by then
//! `kvstore.zig` + `writeset.zig` move under `src-v2/` and this seam is
//! unnecessary.

pub const kvstore = @import("kvstore.zig");
pub const writeset = @import("writeset.zig");
