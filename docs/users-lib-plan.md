# users-lib plan — "Make your own Clerk" (B2C, passwordless)

**Status:** planned 2026-05-16. Elaborates `auth-domain-plan.md` §4.2
(dogfooded customer libraries) + §4.8 (`oauth.verifyIdToken`). No code
yet; 12 tracked tasks (P1a–P5).

**Scope locked (2026-05-16, user decision):** B2C only;
passwordless-only. In: a managed user store, sessions + revocation,
magic-link + social login, TOTP MFA, backend-verify recipe, user.*
webhooks, reference UI. **Out:** email+password (no native KDF
needed), Organizations/B2B, SMS. The tutorial title is honest as "a
Clerk-like auth service for consumer apps" with an explicit
scoping section; it is NOT pitched as full Clerk parity.

**Honesty bar:** the article is publishable once the Tier-1 flows
(signup→user record, social login + account linking, session
list/revoke, backend token verification) pass `clerk_smoke.py`, and
the Tier-2 caveats (no SMS, MFA = TOTP only, Orgs deferred) are
stated up front.

## Why this is mostly a library, not engine work

The two scope decisions collapse the native surface to almost
nothing:

- Passwordless ⇒ **no password KDF** (`crypto.argon2id`/`pbkdf2` not
  needed). sha256 is unacceptable for passwords; not having passwords
  removes the only forced Zig/crypto add.
- B2C ⇒ no orgs data model / role engine / org-scoped tokens.

The entire native delta is:

- **P1a `oauth.verifyIdToken`** — JS only, the §4.8 sketch
  productized. No Zig.
- **P1b `crypto.hmacSha1`** — one ~10-line Zig binding mirroring the
  existing `jsCryptoHmacSha256` (`src/js/bindings/crypto.zig`),
  already pre-proposed in `PLAN.md` §1542. Sole purpose:
  RFC-6238 TOTP that interoperates with SHA-1-default authenticator
  apps. Recommended over the SHA-256-only fallback: a one-time
  10-line cost beats a permanent "your authenticator app may not
  work" caveat in every reader's copy of the tutorial.

Everything else is a dogfooded `src/js/globals/users.js` library +
recipes + reference UI — the exact `oidc.js` / `oauth.js`
"compose from primitives, ship as a library" model (§4.2): no
`platform.*`, no new engine surface.

## Phases & dependency graph

```
Phase 1 (primitives — parallel, unblock strategies)
  P1a oauth.verifyIdToken ───────────────┐
  P1b crypto.hmacSha1 ─────────────┐      │
Phase 2 (users core — KV only, NO native dep: starts parallel with P1)
  P2a record+CRUD+email index → P2b linking → P2c sessions+revoke+aal
Phase 3 (strategies — need 1 + 2)
  P3a magic-link→users   (needs P2b)
  P3b social→users       (needs P1a + P2b)
  P3c TOTP MFA           (needs P1b + P2c)
Phase 4 (integration — need P2, parallel)
  P4a backend-verify recipe   P4b user.* webhooks   P4c reference UI
Phase 5
  P5 clerk_smoke.py gate → freeze (materialize tests) → tutorial
```

**Critical path:** `P2a → P2b → P3b → P5`. P2 is the long pole and
has zero native dependency, so it runs immediately alongside P1 —
the scheduling win from going passwordless. P4c (UI authoring) is the
largest non-critical item; runs anytime after P2c.

**Rough effort:** P1a small (designed already), P1b trivial; P2
medium (the bulk, pure JS/KV); P3 medium; P4 small except P4c; P5
medium.

## kv layout (single tenant — the customer's own "auth" app)

```
users/{uid}                      → {uid,email,email_verified,name,
                                     avatar,status,created_at,
                                     metadata:{public,private}}
idx/email/{sha256(email)}        → uid                  (lookup + link join)
users/{uid}/sessions/{sid}       → {created_at,last_seen,device,aal}
sess/{sid}                       → uid                  (reverse, O(1) guard)
users/{uid}/revoked_before       → unix_s               (revoke-all cutoff)
users/{uid}/totp                 → {secret,confirmed_at}
users/{uid}/backup/{sha256(code)}→ ""                   (single-use)
```

`uid` = `usr_` + base32(`crypto.randomBytes`). Sessions reuse the
platform `__Host-rove_sid`; the lib never mints its own cookie (the
session.zig "bind the sid to your user" model the IdP itself uses).

## Security edges baked into the plan

- **Account-takeover via linking (P2b):** auto-link to an existing
  uid ONLY when the inbound identity's email is verified AND the
  stored user's email is verified. An unverified social-IdP email
  must never attach to an existing user. This is the single sharpest
  edge; it gets a dedicated `clerk_smoke.py` assertion.
- **Revocation:** `revoked_before` is the `min_iat`-style cutoff
  (mirrors `oidc.js` emergency rotation) — "log out everywhere"
  without enumerating sids; the per-sid row covers single-session
  revoke + the device list.
- **Webhooks (P4b) are at-least-once:** the recipe states the
  consumer must dedupe on event id; never implies exactly-once.
- **MFA step-up:** session carries `aal`; TOTP raises it. Sensitive
  routes assert `aal >= 2` rather than re-prompting blindly.

## Freeze workflow

Per the experimental→freeze→TDD-on-modify rule: P1–P4 build
without tests; P5's freeze materializes `clerk_smoke.py` + inline
tests; subsequent edits to frozen code go test-first.

## Task map

P1a–P5 in the session task list. P1a + P2a are the two independent
long poles and start first.
