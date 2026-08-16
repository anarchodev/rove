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
exists: rove#91's crypto-erasure, rove#333's sweep) must lag a plan
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

## Stripe dashboard configuration this assumes

Not code — recorded so going live doesn't miss them: Smart Retries
enabled; "cancel subscription" as the final-failure action (grace ≈ 14
days); built-in failed-payment emails on; prices carry `metadata.tier`
(`pro` / `enterprise`) because the webhook derives the plan from the
subscription's own metadata and nothing else.
