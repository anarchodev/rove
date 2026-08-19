# Billing policy — the unhappy paths, decided together

> **Status**: Decided 2026-08-16 (rove#313). These are the product-policy
> answers every enforcement surface defers to. The economic model is
> `pricing-model.md`; the account/tenant split is
> `platform-accounts-model.md`; the mechanisms are the Stripe lane
> (rove#320: the `@rewind/stripe` package, the webhook route, the plan
> push, the allowance gates). This doc is *what happens to a customer*
> when payment breaks, a plan drops, or a subscription ends — recorded
> in one place because piecemeal answers contradict each other.

## The guiding principle

**A customer who stops paying must always be able to get their data
out.** Nothing below makes an account unrecoverable, and no unhappy path
destroys data without prior warning. Two shipped mechanisms carry most
of this on their own: the free tier still *serves* (inbound, kv, statics
— what it lacks is outbound, headroom, and retention), and exports are
unmetered (rove#429), so a tenant at any cap can still leave.

## The decisions

**1. Downgrade never deletes instances.** Creation-gated only
(rove#312): an account holding more instances than its new tier allows
keeps every one running and simply cannot create more until back under
the allowance.

**2. Downgrade never destroys KV.** Over the new cap, writes refuse
(batch-level 507, rove#298) and reads survive. Combined with unmetered
exports, over-cap is an inconvenience, not a trap.

**3. Cancellation is not a shutoff.** The account lands on free, and
free serves. There is no read-only window because there is no read-only
state — free *is* the indefinite get-your-data-out tier. What ends:
outbound (the paid capability), the paid tier's caps and retention.

**4. Billing never touches the suspend axis — in either direction.**
Suspension is abuse-only, deliberately a sibling of `plan/` so a billing
push can never un-suspend an abuse response (`cp/directory.zig`). The
converse is policy: nonpayment never suspends. Billing moves plans;
abuse moves suspension; the two surfaces stay disjoint.

**5. Cancellation is period-end.** The customer paid through the
period, so service runs to the boundary (`cancel_at_period_end`,
rewind-apps#59); Stripe emits `subscription.deleted` there and the
webhook walks the plan to free. Immediate cancellation is not a
customer surface — it remains a support/operator action via Stripe.

**6. Stripe ends the grace period, not us.** `past_due` changes nothing
on our side (the webhook deliberately holds the plan). Stripe's Smart
Retries + "cancel the subscription after the final failed attempt"
(dashboard settings, target ~14 days) produce the `canceled` event that
ends grace. We run no dunning timers; the grace length is a Stripe
setting, not code.

**7. Nothing degrades during grace.** A `past_due` account keeps full
paid service until Stripe gives up. Stolen-card exposure is bounded by
rove#339 (Radar), not by degrading paying-adjacent customers.

**8. Dunning email is Stripe's, for now.** Their built-in failed-payment
emails (a dashboard checkbox). Branded escalation via `email.send` is a
fast-follow, not a launch requirement.

**9. Retention downgrade hides immediately, destroys after 30 days.**
The read clamp follows the plan live, so history beyond the new tier's
retention becomes unreadable at once — but physical erasure (when it
exists: rove#592's crypto-shredding, rove#333's sweep) must lag a plan
drop by **30 days**, so an accidental downgrade or a support case can
recover. This is the one destructive path in the system, and it gets
the one warning window.

**10. Nonpayment is never deprovision.** No automatic deletion of
tenants or accounts, ever. The account rests on free indefinitely; data
follows free-tier retention. (This is the promise the privacy policy
and DPA lean on — rove#324/#326.)

## What each surface does, in one table

| event | plan | serving | outbound | data |
|---|---|---|---|---|
| `past_due` (grace) | unchanged | full | unchanged | untouched |
| grace ends (`canceled` from Stripe) | → free | free-tier serving continues | off | untouched; retention clamp at 7d; erasure lags 30d |
| customer cancels | unchanged until period end, then → free | uninterrupted through the boundary | off at the boundary | as above |
| downgrade (paid → smaller paid) | → new tier at webhook | full | per new tier | over-cap kv/instances kept; creation/writes gated |
| abuse suspension | untouched | stops (front 403) | — | untouched (reversible) |


## The launch tiers (decided 2026-08-16, rove#314)

| | free | pro | enterprise |
|---|---|---|---|
| **price** | $0 | **$25 / mo, flat per account** | **$250 / mo listed**; custom via `Overrides` |
| instances | 1 | 5 | 25 |
| team accounts | 2 | 5 | 20 |
| outbound | off | on | on |
| replay retention | 7 days | 30 days | 365 days |
| KV per tenant | 64 MiB | 512 MiB | 2 GiB |
| blobs per tenant | 1 GiB | 50 GiB | 500 GiB |
| max request body | 4 MiB | 32 MiB | 256 MiB |

**Why these numbers, against the field** (verified 2026-08-16): the platform
price band is $20–25 (Deno Deploy 20, Vercel 20/seat, Convex 25/seat,
Supabase 25); the durable-execution band is $50–100+ (Trigger.dev 50, Inngest
75, Temporal Cloud 100 minimum). We bundle both categories and price at the
top of the platform band — the durable/replay half is the reason to choose
us, not a separate SKU. Flat per-account (members included) is a deliberate
wedge against the per-seat pricers: a four-person team is $80–100 elsewhere.

**Retention is the headline.** Our free tier's 7-day full-request replay
equals Supabase *Pro*; our 30 days is what Vercel sells per-event as an
add-on and Supabase gates behind its $599 Team tier — and theirs are logs,
not deterministic replay. 365 days has no comparable at any price.

**KV is transactional state, not storage — sized as runway, sold as OLTP.**
1 MiB per value, 256 B keys, strongly consistent, replicated 3× (every sold
GiB is three on disk), every write replayable. 512 MiB is ~half a million
1 KB rows — real runway for a serious site's state. Bulk data belongs on the
blob axis, where 50/500 GiB stands against Deno's 5 GiB and Supabase's
100 GB. We do not chase the database-headline number (Supabase's 8 GB is a
Postgres disk, a different product); density math also forbids it — at
2 GiB/tenant a node's 64 GiB map holds ~32 maxed tenants, where 8 GiB/tenant
would let two or three accounts saturate a cluster the over-subscription
design assumes stays sparse.

**The top of the range is the cluster, not a bigger cap.** A customer who
outgrows enterprise buys a **dedicated three-node cluster at a custom
price** — the architecture's own capacity step, onboarded with the
zero-downtime move. `Overrides` handles small stretches; the cluster handles
scale. Shared tiers are never stretched to hold a whale.

**Marketing guardrails for the pricing page (rove#315):**

- **No "encrypted at rest"** — Phase 9 is deferred, so today the claim is
  false, and even once it ships the ceiling is "encrypted at rest", never
  "we cannot read your logs" (customer-held keys are deliberately deferred).
  This is the rove#322 false-claims class; check the page against it.
- Advertised retention = enforced retention, in **days**, permanently —
  days are the sold axis and the byte capacity is derived and internal
  (`pricing-model.md` §3; `decisions.md` §11.6). The capacity-ring
  revision this line once anticipated is not coming.
- **Say "deleted after N days", not "we keep N days"** — the deletion is
  the half the DPA and privacy policy commit to. Two riders belong in the
  same breath: records a customer explicitly **pins** outlive the window,
  and a customer may set a **shorter** window than their tier's. Both are
  exceptions to a published period, so both have to appear in the prose
  or the claim is false the first time either is used.
- Requests are not priced and not advertised as a quota — the caps exist to
  protect the node, not to meter.

**Operational rider:** these numbers sell storage against a bound nothing
monitors (rove#472 — no disk metrics). The disk gauge belongs in the go-live
checklist ahead of the first enterprise deal.

## Stripe dashboard configuration this assumes

Not code — recorded so going live doesn't miss them: Smart Retries
enabled; "cancel subscription" as the final-failure action (grace ≈ 14
days); built-in failed-payment emails on; prices carry `metadata.tier`
(`pro` / `enterprise`) because the webhook derives the plan from the
subscription's own metadata and nothing else.
