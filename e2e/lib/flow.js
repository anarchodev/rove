import { expect } from "@playwright/test";
import { waitForMagicLink } from "./resend.js";
import { APP, APP_HOST, AUTH_HOST, RESEND_API_KEY, dbg } from "./config.js";

// Navigate into the app unauthenticated and land on the __auth__ IdP
// email form. Returns the email-field locator. Tolerant of the SPA
// interstitial timing: falls back to kicking /_rp/login directly.
export async function reachIdpLoginForm(page) {
  const emailField = page.locator('input[name="email"]');
  await page.goto(APP + "/");
  try {
    await emailField.waitFor({ state: "visible", timeout: 20_000 });
  } catch {
    await page.goto(
      APP + "/_rp/login?return_to=" + encodeURIComponent("/#/instances"),
    );
    await emailField.waitFor({ state: "visible", timeout: 20_000 });
  }
  dbg("on IdP form:", page.url());
  expect(new URL(page.url()).host).toBe(AUTH_HOST);
  return emailField;
}

// From the IdP form: submit `email`, read the magic link back out of
// Resend, assert it's FRESH, and open it in the same context (which runs
// verify → /authorize → app callback). Does NOT assert the final landing
// — the caller decides whether to expect the dashboard (authorized) or a
// rejection (unauthorized). Returns { link, email } from Resend.
export async function requestAndOpenMagicLink(page, emailField, email) {
  const sinceMs = Date.now();
  await emailField.fill(email);
  await page.getByRole("button", { name: /sign-in link/i }).click();
  await expect(page.getByText(/check your email/i)).toBeVisible({
    timeout: 15_000,
  });
  dbg("submitted", email, "— 'check your email' shown; sinceMs =", sinceMs);

  const { link, email: resendEmail } = await waitForMagicLink(RESEND_API_KEY, {
    to: email,
    sinceMs,
  });
  dbg(
    "magic email id:", resendEmail.id,
    "created_at:", resendEmail.created_at,
    "(", Date.parse(resendEmail.created_at) - sinceMs, "ms after submit )",
  );
  expect(link).toContain("/login/verify?mt=");
  // Must be the email we just triggered, not a stale link from an earlier run.
  expect(Date.parse(resendEmail.created_at)).toBeGreaterThanOrEqual(
    sinceMs - 5_000,
  );

  await page.goto(link);
  return { link, email: resendEmail };
}

// Full authorized login: form → magic link → land authenticated at the
// dashboard. Use as setup for tests that need to start logged in.
export async function loginAsOperator(page, email) {
  const emailField = await reachIdpLoginForm(page);
  await requestAndOpenMagicLink(page, emailField, email);
  await page.waitForURL(
    (u) => u.host === APP_HOST && u.hash.includes("/instances"),
    { timeout: 60_000 },
  );
  dbg("landed authenticated at:", page.url());
  expect(new URL(page.url()).host).toBe(APP_HOST);
  await expect(page.locator('input[name="email"]')).toHaveCount(0);
}
