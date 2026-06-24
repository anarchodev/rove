import { test } from "@playwright/test";
import { loginAsOperator } from "../lib/flow.js";
import { OPERATOR_EMAIL, RESEND_API_KEY } from "../lib/config.js";

// Full magic-link operator sign-in against live prod:
//   app.rewindjs.com → OIDC RP handshake → auth.rewindjs.com/login
//   → submit operator email → magic link via Resend (read back out of our
//     own Resend account) → open verify link → land authed at /#/instances
test("magic-link login: app → IdP → email → dashboard", async ({ page }) => {
  test.skip(
    !RESEND_API_KEY,
    "RESEND_API_KEY not set — needed to read the magic-link email back from Resend",
  );
  await loginAsOperator(page, OPERATOR_EMAIL);
});
