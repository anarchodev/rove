import { test, expect } from "@playwright/test";
import { waitForMagicLink } from "../lib/resend.js";

// Targets (override via env — see .env.example).
const APP = (process.env.E2E_APP_URL || "https://app.rewindjs.com").replace(
  /\/$/,
  "",
);
const AUTH = (process.env.E2E_AUTH_URL || "https://auth.rewindjs.com").replace(
  /\/$/,
  "",
);
const EMAIL = process.env.E2E_LOGIN_EMAIL || "an@rcho.dev";
const RESEND_API_KEY = process.env.RESEND_API_KEY;

const APP_HOST = new URL(APP).host;
const AUTH_HOST = new URL(AUTH).host;

// Set E2E_DEBUG=1 to trace each leg (no secrets are logged).
const dbg = process.env.E2E_DEBUG
  ? (...a) => console.log("  [e2e]", ...a)
  : () => {};

test("magic-link login: app → IdP → email → dashboard", async ({ page }) => {
  test.skip(
    !RESEND_API_KEY,
    "RESEND_API_KEY not set — needed to read the magic-link email back from Resend",
  );

  const emailField = page.locator('input[name="email"]');

  // 1. Enter the app unauthenticated. The admin SPA bounces through
  //    /_rp/login → __auth__ IdP, which renders the email form.
  await page.goto(APP + "/");
  try {
    await emailField.waitFor({ state: "visible", timeout: 20_000 });
  } catch {
    // Fallback: kick the RP handshake directly if the SPA bounce didn't
    // land us on the form (e.g. interstitial timing).
    await page.goto(
      APP + "/_rp/login?return_to=" + encodeURIComponent("/#/instances"),
    );
    await emailField.waitFor({ state: "visible", timeout: 20_000 });
  }

  // We should now be on the IdP login page.
  dbg("on IdP form:", page.url());
  expect(new URL(page.url()).host).toBe(AUTH_HOST);

  // 2. Submit the operator email and trigger the magic-link send.
  //    Capture the time *before* submit so we only match a fresh email.
  const sinceMs = Date.now();
  await emailField.fill(EMAIL);
  await page.getByRole("button", { name: /sign-in link/i }).click();
  await expect(page.getByText(/check your email/i)).toBeVisible({
    timeout: 15_000,
  });
  dbg("email submitted, 'check your email' shown; sinceMs =", sinceMs);

  // 3. Read the magic link back out of our own Resend sent-mail list.
  const { link, email } = await waitForMagicLink(RESEND_API_KEY, {
    to: EMAIL,
    sinceMs,
  });
  dbg(
    "magic email id:", email.id,
    "created_at:", email.created_at,
    "(", Date.parse(email.created_at) - sinceMs, "ms after submit )",
  );
  dbg("magic link host/path:", link.replace(/mt=[^&]*/, "mt=<redacted>"));
  expect(link).toContain("/login/verify?mt=");
  // The email must be FRESH — created at/after we submitted, not a stale
  // link from an earlier run.
  expect(Date.parse(email.created_at)).toBeGreaterThanOrEqual(sinceMs - 5_000);

  // 4. Open the magic link in the SAME browser context — the verify step
  //    binds the IdP session cookie set when we first hit /authorize.
  await page.goto(link);

  // 5. verify → /authorize → app /_rp/callback → poll page completes the
  //    RP session and returns the browser to #/instances.
  await page.waitForURL(
    (u) => u.host === APP_HOST && u.hash.includes("/instances"),
    { timeout: 60_000 },
  );

  // 6. Authenticated: the login form is gone and we're on the app host.
  dbg("landed authenticated at:", page.url());
  expect(new URL(page.url()).host).toBe(APP_HOST);
  await expect(page.locator('input[name="email"]')).toHaveCount(0);
});
