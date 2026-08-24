// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! THE registry of platform-reserved header names: every `x-rewind-*` /
//! `x-rove-internal-*` name on the internal wire, spelled ONCE here and
//! referenced everywhere else. `scripts/ops/reserved_header_lint.py`
//! fails the build on a literal spelled anywhere but here and the prefix
//! authority (`src/js/reserved_headers.zig`).
//!
//! Two things need that, and only one is the usual don't-repeat-yourself
//! argument. The first is class-3 drift (`docs/defect-patterns.md`):
//! `x-rewind-move-secret` was typed out in six files across four
//! binaries, and a sender/receiver pair that disagrees on a spelling
//! fails at the far end as a MISSING header, far from the edit. The
//! second is that the reservation is only worth what its enumerability
//! is worth — the inbound strip, the response gate, and the replay
//! mirror all reason about "a reserved header", and a name that exists
//! only as a literal inside one call site is invisible to all three.
//!
//! Pure std, no dependencies, so every binary that speaks the wire can
//! hold the one spelling — including `rewind-ops` and `rewind`, which
//! link no libcurl and so cannot reach `rove-wire` itself (it carries
//! the attach codec, typed as `curl.Header`). That is the same reason
//! `sigv4.zig` and `namespace.zig` are imported into the CLI by path
//! rather than restated there. `rove-wire` re-exports the lot, which is
//! how the worker and CP read it (`wire.TENANT` and friends).
//!
//! Lowercase (HTTP/2 wire form); libcurl sends names verbatim and HTTP
//! headers are case-insensitive, so one spelling serves both directions.

pub const TENANT = "x-rewind-tenant";
pub const INCARNATION = "x-rewind-incarnation";
/// The tenant's keyring root secret, 64 lowercase hex, minted ONCE at
/// birth. Present only on a birth attach; see `AttachEnvelope.secret`.
pub const KEYRING_SECRET = "x-rewind-keyring-secret";
pub const PLAN = "x-rewind-plan";
/// RETIRED (with the buffered bundle path + the atomic baseline attach): a
/// joiner is born EMPTY and its state arrives raft-natively — log
/// replication, or the streamed catch-up whose END_STREAM install carries
/// the baseline. The names are kept only so the decoder can REJECT a stale
/// sender loudly instead of silently birthing a group it thinks is at a
/// baseline it never installed.
pub const BASELINE_INDEX = "x-rewind-baseline-index";
pub const BASELINE_TERM = "x-rewind-baseline-term";
pub const EPOCH = "x-rewind-epoch";
pub const JOIN_AS_LEARNER = "x-rewind-join-as-learner";
pub const VOTERS = "x-rewind-voters";
pub const LEARNERS = "x-rewind-learners";
pub const PEER_ADDRS = "x-rewind-peer-addrs";

/// Transport auth on every CP↔worker `/_system/*` call and the CP's own
/// `/_control/*` writes — a shared secret, compared in constant time by
/// the receiver (`js/v2_move.zig`). Deliberately NOT part of any envelope
/// above: it authenticates the call, it is not payload.
///
/// The value is what carries authority, never the presence of the name.
/// A client-supplied copy rides the cross-cluster forward verbatim
/// (`worker_dispatch.zig` `buildForwardSpec` relays every non-pseudo,
/// non-hop-by-hop header), so any receiver that grows a cheaper check
/// than "compare the secret" hands the fleet to whoever can set a header.
pub const MOVE_SECRET = "x-rewind-move-secret";

/// v2-snapshot-push: the dest node base URL the source streams to.
pub const DEST = "x-rewind-dest";

// Streamed-snapshot baseline, carried in headers so the body stays the
// pure pair stream.
pub const SNAPSHOT_INDEX = "x-rewind-snapshot-index";
pub const SNAPSHOT_TERM = "x-rewind-snapshot-term";
/// "replace" (default, catch-up/promote-back) | "merge" (zero-downtime move).
pub const SNAPSHOT_MODE = "x-rewind-snapshot-mode";

/// Worker→front, on a 421: the raft node id the worker believes leads
/// this tenant, so the front's leader-aware walk retargets instead of
/// re-scanning (`front/proxy.zig` `leaderOriginHint`). A RESPONSE header,
/// and the one name here that crosses the worker↔front boundary rather
/// than the CP↔worker one — which is why it belongs in the same registry
/// and not in either binary.
pub const LEADER = "x-rewind-leader";
