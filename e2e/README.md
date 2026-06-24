# rove e2e (Playwright)

Browser-driven end-to-end tests for the rewind.js platform. Unlike the
Python smokes in `scripts/` (HTTP-level, spawn their own cluster), these
drive a real browser against the **live production** platform and exercise
flows a user actually performs.

## First test: magic-link login

`tests/login.spec.js` drives the full operator sign-in:

1. Open `app.rewindjs.com` unauthenticated → the admin SPA bounces through
   the OIDC relying-party handshake to the `auth.rewindjs.com` IdP login
   form.
2. Submit the operator email; the platform sends a magic-link email via
   **Resend** (`web/auth/index.mjs` → `email.send`).
3. Read that email back out of **our own Resend account** using the
   "list sent emails" API (`GET /emails` → `GET /emails/{id}`) and extract
   the `…/login/verify?mt=…` link. No inbox needed — it's an email *we
   sent*.
4. Open the link in the same browser context → verify → `/authorize` →
   app `/_rp/callback` poll page completes the session.
5. Assert we land authenticated at `app.rewindjs.com/#/instances`.

Each run sends a real email and mints a real prod session. That's by
design (true end-to-end), but it means: don't run it in a tight loop.

## Setup

```bash
cd e2e
npm install
npx playwright install chromium   # one-time browser download
cp .env.example .env              # then fill in RESEND_API_KEY
```

`RESEND_API_KEY` must be a **full-access** key (read scope) for the Resend
account that sends rewindjs sign-in emails. A send-only key 401s on the
list call. The test `skip`s itself if the key is absent.

## Run

```bash
set -a; . ./.env; set +a     # load env into the shell
npm test                     # headless
npm run test:headed          # watch the browser
npm run test:debug           # Playwright inspector (step through)
npm run report               # open the HTML report after a run
```

## Config

All targets are env-overridable (see `.env.example`): `E2E_APP_URL`,
`E2E_AUTH_URL`, `E2E_LOGIN_EMAIL`. Defaults point at production with the
seeded operator identity.

## Notes

- `retries: 0`, `workers: 1` — never hammer prod. Re-run by hand.
- Traces / screenshots / video are retained only on failure
  (`playwright-report/`).
- The magic-link extraction lives in `lib/resend.js`, reusable by future
  email-driven tests (signup, password reset, etc.).
