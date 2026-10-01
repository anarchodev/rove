# Security policy

rove is the engine behind [rewind.js](https://rewindjs.com), a hosted
platform that runs untrusted JavaScript from many tenants on shared
machines. Both are operated by **Loop46, Inc.** The full disclosure policy
lives at <https://rewindjs.com/security>; this file is the part you need
before you write.

## Reporting a vulnerability

**Do not open a public issue, pull request or discussion.**

Write to **[security@loop46.com](mailto:security@loop46.com)** (Loop46,
Inc. — the company that operates rewind.js).
> **[DECISION]** if GitHub private vulnerability reporting is enabled on this repository, add: "or use GitHub's private reporting at https://github.com/anarchodev/rove/security/advisories/new. Email is canonical; both reach the same person."

Include what you found, how to reproduce it, what an attacker gains, and
whether you have accessed anyone else's data in the process. A proof of
concept against your own tenant is ideal.

## What to expect

- We acknowledge within **2 working days**.
- We tell you within **[DECISION] 7 days** whether we accept the
  report and how severe we think it is.
- We aim to fix critical issues in production within
  **[DECISION] 7 days** and others within
  **[DECISION] 90 days**, and keep you updated as we go.
- We coordinate disclosure with you. Our default is to publish an advisory
  once a fix is deployed, and no later than **90 days** after your report
  unless we agree otherwise.
- We do not run a bug bounty and cannot pay for reports. We will credit you
  in the advisory if you would like.

## Scope

Most wanted: anything that crosses a tenant boundary.

- reading or altering another tenant's code, data, request records or
  replays;
- escaping the JavaScript sandbox or the per-request time and memory limits;
- reaching the control plane, another tenant's raft group, or internal
  network addresses from a handler;
- defeating encryption or erasure (`shredKey`, account deletion) — reading
  data whose key has been destroyed;
- authentication and session flaws on the sign-in service, the dashboard,
  or the platform session cookie.

In scope: this repository, and the hosted service — `rewindjs.com` and its
subdomains (`app.`, `auth.`, `docs.`, `replay.`, `registry.`), and apps
served under `*.rewindjs.app`, tested through your own app.

Out of scope: volumetric denial of service; rate limits or resource caps on
the free tier; findings needing physical access or social engineering of
our staff; vulnerabilities in a customer's own app code; issues in
third-party services we use, which should go to them; missing hardening
headers or banner disclosures without a demonstrated impact; automated
scanner output without a working proof.

## Testing rules

- Test only against accounts and tenants you own. Sign-up is free.
- Do not access, change or keep other people's data. If you reach any, stop,
  report it, and delete what you hold.
- No denial of service, no spam through the outbound or email primitives,
  and nothing that degrades the service for others.
- Keep the details confidential until we have agreed on disclosure.

## Safe harbour

> **[DECISION]** safe-harbour wording; counsel to review.
If you research and report in good faith and follow this policy, we will
not pursue or support legal action against you for it, including under
anti-hacking or anti-circumvention laws or our Terms of Service, and we
will make that known if a third party takes action against you over it. If
you are unsure whether something is allowed, ask us first at
security@loop46.com.

## Supported versions

rove has no versioned releases yet. Security fixes land on `main` and are
deployed to rewind.js from there; self-hosters should track `main`.
