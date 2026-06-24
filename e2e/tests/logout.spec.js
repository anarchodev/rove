import { test, expect } from "@playwright/test";
import { loginAsOperator } from "../lib/flow.js";
import { OPERATOR_EMAIL, RESEND_API_KEY, AUTH_HOST, APP, dbg } from "../lib/config.js";

// Log in, then sign out, and confirm the logout is a FULL one: both the
// RP session (app) and the IdP session (auth) are cleared, so the app
// forces a fresh magic-link round-trip rather than silently re-authing.
test("logout clears the session and forces re-auth", async ({ page }) => {
  test.skip(!RESEND_API_KEY, "RESEND_API_KEY not set");

  await loginAsOperator(page, OPERATOR_EMAIL);

  // "Sign out" in the dashboard header → whole-page nav to /_rp/logout,
  // which 302s to the IdP end-session endpoint and back to /#/login.
  await page.getByRole("button", { name: /sign out/i }).click();

  // Because the IdP session is also cleared, the bounce back through
  // /_rp/login lands us on the IdP login FORM again — not straight into
  // the dashboard. Seeing the email field on the auth host proves both
  // sessions were dropped.
  const emailField = page.locator('input[name="email"]');
  await emailField.waitFor({ state: "visible", timeout: 30_000 });
  dbg("after sign out, back at:", page.url());
  expect(new URL(page.url()).host).toBe(AUTH_HOST);

  // No lingering session: hitting the app again still demands login.
  await page.goto(APP + "/");
  await emailField.waitFor({ state: "visible", timeout: 30_000 });
  dbg("re-entering app after logout, at:", page.url());
  expect(new URL(page.url()).host).toBe(AUTH_HOST);
});
