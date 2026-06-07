# V2 — front door / control-plane split + CF-free edge architecture (design)

> **Status: design (2026-06-07). Not built — this records the responsibility
> split and the decisions behind it.** Establishes how public ingress, request
> routing, the control plane (CP), and TLS/cert issuance divide across tiers in
> V2. **Decision: own the edge — no Cloudflare dependency.** rove terminates its
> own TLS, issues its own certs (ACME), and routes via the CP; the host
> provides only commodity L3/L4 (a TCP path + transparent network DDoS). This
> makes the product self-hostable and host-agnostic — the AGPL "runs anywhere"
> story falls out of the architecture, it isn't bolted on. Companions:
> [`v2-cp-directory-replication.md`](v2-cp-directory-replication.md) (the
> replicated directory this builds on), `src-v2/front/main.zig` (today's
> conflated binary), `src-v2/cp/directory.zig` (the directory interface),
> `src-v2/rewind/main.zig` (the DP worker), `loop46/acme.zig` +
> `src/acme/` (V1's ACME issuer — *evolve, do not delete*),
> `docs/v2-build-order.md` §Phase 7,
> [`v2-cp-operational-state.md`](v2-cp-operational-state.md) (the CP axes:
> plan/limits/domains/certs), [`project_v2_zero_downtime_move`] memory.

## TL;DR

- **Two structural bugs in the prototype:** the front door is welded to the CP
  (every front-door replica is a CP raft voter), and the front door is h2c.
- **Split:** CP becomes its own binary + fixed raft cluster; the front door
  becomes a stateless TLS-terminating router that follows the CP as a
  read-replica.
- **No Cloudflare.** rove terminates public TLS and runs its own ACME. The host
  supplies only L3/L4 (a TCP load path) and, ideally, transparent network DDoS
  (OVH gives this free and always-on). Nothing in the stack is vendor-specific.
- **One authority** (CP directory), **one correctness backstop**
  (serve-or-forward in the DP), everything else is an intentionally-stale hint.
- **One genuinely new build:** cert state moves into the CP directory, served to
  the front-door pool, written by a single leader-elected ACME issuer.

## The problem this fixes

Today `src-v2/front/main.zig` is **one binary doing two jobs with opposite
scaling and consistency profiles**:

1. **Edge proxy** — per-request hot path; wants *many stateless replicas* behind
   a load path; scales with traffic.
2. **CP directory** — a *small fixed raft voter set*; consensus-bound; rarely
   written; must stay *off* the hot path.

The smoking gun: the front binary takes `REWIND_CP_NODE_ID / VOTERS / PEERS`, so
**every front-door replica is a CP raft voter** → *front-door count == CP voter
count*. You cannot scale the edge without growing the raft group. The split
isn't missing; it's *inverted*.

## The organizing principle

What makes the edge coherent is **serve-or-forward** (`96e0d90` — async proxy of
mis-routed requests off the worker loop). Once any DP cluster can forward a
mis-routed request to the real owner:

> **One authority** (the CP directory), **one correctness mechanism**
> (serve-or-forward in the DP), and **everything else is a best-effort,
> intentionally-stale hint.** Staleness costs an extra hop, never a wrong
> answer.

A front-door's cached projection, a DNS record, an L4 LB's member list — all may
lag, because the DP self-corrects. That property is what lets the routing layers
be eventually-consistent without risk.

## Why no Cloudflare

The earlier draft of this doc leaned on Cloudflare for SaaS (custom-hostname TLS
automation) and hit a wall: **Cloudflare cannot proxy to an h2c origin** (origin
pull supports only h2-over-TLS; cloudflared `http2Origin` requires a cert;
plaintext-h2 is unsupported — cloudflared issues #625/#1304). And rove is
nghttp2 (HTTP/2-only), so the HTTP/1.1-cleartext origin path is closed too. That
would have forced us to terminate origin TLS *anyway*, just to satisfy CF.

Once you're terminating TLS regardless, CF's remaining unique value is narrow:
**only the SaaS custom-hostname cert automation** — *not* DDoS or WAF. Those are
commodities the host already provides:

- **DDoS** — OVH's anti-DDoS (VAC) is always-on, cannot be disabled, on every
  bare-metal/VPS product, ~1.3 Tbit/s, with DPI + ML scrubbing, and **requires
  zero integration**. You run your stack and you're protected.
  ([OVH Anti-DDoS](https://www.ovhcloud.com/en/security/anti-ddos/))
- **WAF** — available via OVH's CDN Security tier or the UBIKA partnership if
  wanted; not required for the baseline.

So the only thing CF would have saved us is writing the custom-hostname ACME
flow — and **V1 already wrote it** (`loop46/acme.zig`, `src/acme/`). Re-homing
that beats taking a hard dependency on a single vendor for the whole edge.
Dropping CF also **deletes the h2c problem entirely**: the only TLS hop is
client→our-edge, which we own; front-door→DP can be plain h2c on the private
network.

The trade we accept: OVH's VAC is volumetric (L3/L4); CF additionally does
inline L7 DDoS + bot management. If L7/bot pressure becomes real, an L7 WAF
(OVH CDN / UBIKA / self-hosted) slots *in front* of the same contract without
changing rove. We are not architecturally married to that choice either way.

## The tier split

```
   tenant DNS: app.acme.com  CNAME ──▶  edge.rewindjs.app
                                            │
                            host DDoS (transparent L3/L4 scrub — OVH VAC, free)
                                            │
                            L4 ingress  (TCP + ALPN passthrough — NO TLS here)
                                            │  h2 over TLS
                       ┌────────────────────┴───────────────────┐
                       ▼                                         ▼
              ┌──────────────────┐                     ┌──────────────────┐
              │  front door #1   │   ...stateless...   │  front door #N   │
              │  • terminate     │                     │                  │
              │    h2+TLS (SNI)  │   cert pull +        │                  │
              │  • route via CP  │◀── directory proj. ─▶│   CP cluster     │
              │  • proxy to DP   │                      │  (3–5 voters)    │
              └────────┬─────────┘                      │  directory:      │
                       │ h2c (private network)          │   placement,     │
                       ▼                                │   domain index,  │
              ┌──────────────────┐   serve-or-forward   │   plan/limits,   │
              │   DP clusters    │◀──── (backstop) ─────│   CERT STATE     │
              │  (worker + raft) │                      └────────┬─────────┘
              └──────────────────┘                               ▲ writes
                                                                 │
                                      ACME issuer (single, leader-elected)
                                      • *.rewindjs.app  → DNS-01
                                      • custom hostnames → HTTP-01 / TLS-ALPN-01
```

- **L4 ingress** — a TCP load path: OVH IP Load Balancer in **TCP + ALPN
  passthrough** (OVH's L7 LB does not speak HTTP/2 directly; TCP+ALPN is the
  supported way and keeps certs off the LB), or failover/anycast IPs, or DNS
  round-robin. Commodity; every host has an equivalent. Host DDoS sits
  transparently in front.
  ([HTTP/2 on OVH LB](https://support.us.ovhcloud.com/hc/en-us/articles/19805896005139-Configuring-HTTP-2-on-an-OVHcloud-Load-Balancer-Service))
- **Front door** — stateless replicas. **Terminate public h2-over-TLS**
  (nghttp2/OpenSSL, the existing rove-h2 path), SNI-selecting the platform
  wildcard or a per-tenant cert. Read a cached projection of the CP directory
  (CP read-replica, **not a voter**), route host→tenant→cluster, proxy to the DP
  over private h2c. Scale horizontally behind the L4 ingress.
- **CP** — its own small raft cluster (3–5 voters), **separate binary**.
  Authoritative directory: placement, domain→tenant index, plan/limits, and
  **cert state**. Runs move orchestration + stuck-move reconciliation. **Never on
  the request hot path.** Read API (`/_cp/route`) + control-write API
  (`/_control/move`, future `/_control/plan`).
- **DP clusters** — execution + serve-or-forward (the correctness backstop) +
  DP-local enforcement (rate `429`, body `413`, plan limits cached on
  `TenantSlot`, per [`v2-cp-operational-state.md`](v2-cp-operational-state.md)).
- **ACME issuer** — a **single leader-elected** role (not one per front-door, so
  replicas don't race or burn Let's Encrypt rate limits). Issues the platform
  wildcard via DNS-01 and tenant custom hostnames via HTTP-01 / TLS-ALPN-01;
  writes certs into the CP cert state. Evolved from V1's `loop46/acme.zig`.

The reframe to hold: it is **not "front door vs CP."** It is *one authority
(CP), one backstop (serve-or-forward), and a stack of intentionally stale hints
in front of it.* The prototype's bug is that the authority and one hint are
welded into the same process.

## TLS termination is ours, by design

We terminate public TLS at the front-door pool. This is the *point*, not a cost:
because tenant custom-domain certs come from **our** ACME, our edge must hold and
SNI-serve them.

- **L4 ingress stays passthrough.** OVH IP LB in TCP+ALPN (or anycast/DNS) never
  sees our certs. (TERMINATED_HTTPS exists but would require uploading every
  per-tenant cert to the LB — defeats self-contained automation. Use
  passthrough.)
- **Public hop:** client → front-door = h2 over TLS (we terminate).
- **Private hop:** front-door → DP = h2c on the private network (our own hop; no
  vendor in the middle, so no h2c-to-third-party problem).

## Certs: issuance + state

This is the one genuinely new design piece; everything else is reuse.

**Two cert kinds:**
- **Platform wildcard** `*.rewindjs.app` — one cert, **DNS-01** challenge (we
  control that zone; wildcards require DNS-01). Needs the DNS provider's API.
- **Tenant custom hostnames** `app.acme.com` — per-domain, **HTTP-01** (port-80
  responder, as V1 did) or **TLS-ALPN-01** (port-443 ALPN). Works because the
  tenant CNAMEs to our edge and we terminate 443/80. Triggered when a domain is
  written into the CP domain index.

**Cert state lives in the CP directory.** V1 replicated `cert/{host}` through
*per-cluster* raft into `__root__.db`; that's the wrong home in V2 because certs
are admin-authored and **placement-independent** — they must survive tenant
moves and be visible to every stateless front-door. That's exactly the
cp-operational-state filter, so cert state is a sibling axis in the
`__directory__` group beside placement/domains/plan. The issuer writes certs
there; front-doors load them from their CP projection for SNI selection.

**Single issuer.** Leader-elect one issuer so N front-doors don't each attempt
issuance (duplicate orders, rate-limit waste). It watches the CP domain index,
issues/renews, and commits results to CP cert state.

V1's ACME apparatus (`loop46/acme.zig`, `src/acme/`, the HTTP-01 responder) is
**evolved and re-homed, NOT deleted** — the change is *where cert state lives*
(CP, not `__root__.db`) and *that there is one coordinated issuer* (not
leader-pinned-per-cluster).

## Why this runs on almost any host

Once we own TLS + ACME + routing, rove depends only on **commodity L3/L4** — a
TCP load path and, ideally, transparent network DDoS — which every host
provides. The reference deployments all satisfy the same contract:

| Host        | L4 ingress                    | Network DDoS            |
|-------------|-------------------------------|-------------------------|
| OVH (ref.)  | IP LB (TCP+ALPN) / failover IP | VAC — free, always-on   |
| AWS         | NLB                           | Shield (Standard free)  |
| GCP         | L4 / passthrough NLB          | Cloud Armor             |
| bare metal  | keepalived / anycast / DNS RR | host/upstream-dependent |
| self-hoster | one box, DNS A record         | whatever's upstream     |

Nothing in the stack is OVH-specific; OVH is the recommended *default* because
its DDoS is free, strong, and zero-config. This is what makes the AGPL,
self-hostable, "runs anywhere" positioning real rather than marketing.

**Honest self-host caveats:**
- **Wildcard needs DNS-01** → the operator must supply DNS-provider API creds, or
  skip wildcards and use per-host HTTP-01 for everything. Make the wildcard path
  optional.
- **Let's Encrypt rate limits** are a non-issue at self-host scale but matter at
  SaaS scale — hence the single coordinated issuer + cert caching in the CP.

## The public-entry contract (the stable seam)

Define one wire contract and point every ingress at it:

> *an h2 request (TLS-terminated at our front-door) carrying an authoritative
> original-host, delivered to a serve-or-forward-capable backend.*

Anything satisfying it is a valid ingress — OVH LB today, an L7 WAF later, a
self-hoster's single box, even a future CDN. This is more durable than a plugin
trait, and it is what keeps the front-door from ever becoming load-bearing: the
DP must never trust a header only the front-door injects, so swapping the ingress
is always a topology change, never a code change.

## Build order

1. **Split the CP into its own binary + fixed raft cluster**; make the front door
   a stateless CP read-replica, not a voter. (Fixes the inverted scaling.)
2. **Front door terminates public TLS** with SNI cert selection (reuse the
   rove-h2 TLS path); front-door → DP is private h2c.
3. **CP cert-state axis** + **CP domain-index axis** in the `__directory__`
   group; front-door cert-pull from the CP projection.
4. **Single leader-elected ACME issuer**, evolved from `loop46/acme.zig`:
   wildcard via DNS-01, custom hostnames via HTTP-01 / TLS-ALPN-01, writing to CP
   cert state.
5. **Reference deployment**: OVH IP LB in TCP+ALPN passthrough, edge nodes
   terminating TLS, VAC transparent in front. Document the any-host contract.

This turns parity-audit gap #3 (TLS/ACME) from "delete and outsource to CF" into
"split cert state into the CP + coordinate one issuer" — contained, and it
removes a vendor dependency instead of adding one.

## Open questions

- **Cert-state size in the CP.** Certs/keys are larger than placement records; if
  the `__directory__` group's entries get heavy, store cert *bytes* in a shared
  blob store and keep only pointers + metadata in the CP. Decide before wiring.
- **Issuer failover.** Leader-election mechanism for the single issuer (reuse the
  CP raft leadership vs a dedicated lease) and what happens to in-flight orders
  on failover.
- **TLS-ALPN-01 vs HTTP-01 for custom hosts.** ALPN-01 avoids a port-80
  responder but needs the terminator to handle the `acme-tls/1` ALPN handshake;
  HTTP-01 reuses V1's responder. Pick one as the default.
- **CP read-replica mechanism.** How front-doors follow the directory + cert
  state: CP learner vs poll vs stream. Lands behind the `Directory` interface.
- **L7/bot DDoS escalation path.** If volumetric (host) protection proves
  insufficient, which L7 WAF goes in front of the contract (OVH CDN / UBIKA /
  self-hosted) — validated, not built.
