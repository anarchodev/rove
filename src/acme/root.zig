//! rove-acme — in-tree ACME (RFC 8555) HTTP-01 issuance.
//!
//! See `docs/architecture/auth-and-domains.md`. Public surface:
//!   - `crypto` — EC P-256 keys, ES256 JWS, JWK thumbprint, CSR.
//!   - `Responder` — the dedicated :80 HTTP-01 challenge server.
//!   - `Client` — the RFC 8555 order→challenge→finalize state machine.
//!
//! Cert distribution + leader-gated issuance orchestration lives in
//! `src/cp/` (it needs raft + the tenant domain registry); this
//! module is the reusable, network/crypto core.

pub const crypto = @import("crypto.zig");
pub const Responder = @import("responder.zig").Responder;
pub const Client = @import("client.zig").Client;

test {
    @import("std").testing.refAllDecls(@This());
}
