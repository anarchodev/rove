import { test, expect } from "@playwright/test";
import { reachIdpLoginForm, requestAndOpenMagicLink } from "../lib/flow.js";
import {
  UNAUTHORIZED_EMAIL,
  RESEND_API_KEY,
  APP,
  APP_HOST,
  dbg,
} from "../lib/config.js";

// A non-operator email is NOT rejected by the platform — it signs in like
// any customer. The authorization boundary is operator-only surfaces. This
// test proves both halves: a non-operator lands on the customer provision
// flow, and operator-only endpoints answer 403 (authenticated, not 401).
//
// It deliberately stops BEFORE submitting the provision form, so it creates
// no tenant on the prod cluster.
test("non-operator: routed to provision, denied operator surfaces", async ({
  page,
}) => {
  test.skip(!RESEND_API_KEY, "RESEND_API_KEY not set");

  const emailField = await reachIdpLoginForm(page);
  await requestAndOpenMagicLink(page, emailField, UNAUTHORIZED_EMAIL);

  // No owned instances → app auto-routes to the provision form. (Not a
  // 403/redirect-to-error: a non-operator is a normal customer here.)
  await page.waitForURL(
    (u) => u.host === APP_HOST && u.hash.includes("/provision"),
    { timeout: 60_000 },
  );
  dbg("non-operator landed at:", page.url());
  await expect(
    page.getByRole("heading", { name: /name your instance/i }),
  ).toBeVisible();

  // Operator-only control-plane reads are forbidden for this session. The
  // request carries the RP cookie (page.request shares the context), so a
  // non-operator gets 403 "operator only" — distinct from an unauthenticated
  // 401.
  const res = await page.request.get(
    APP + "/v1/cp/route?host=example.com",
  );
  dbg("GET /v1/cp/route →", res.status());
  expect(res.status()).toBe(403);
  expect(await res.text()).toContain("operator only");
});
