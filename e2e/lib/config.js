// Shared env-driven config for the e2e suite. Defaults target live prod.
export const APP = (process.env.E2E_APP_URL || "https://app.rewindjs.com").replace(
  /\/$/,
  "",
);
export const AUTH = (
  process.env.E2E_AUTH_URL || "https://auth.rewindjs.com"
).replace(/\/$/, "");

// The seeded operator — authorized to reach the app.rewindjs.com dashboard.
export const OPERATOR_EMAIL = process.env.E2E_LOGIN_EMAIL || "an@rcho.dev";

// A NON-operator address. The magic-link round-trip still completes
// (anyone can sign in) but __admin__ treats it as a plain customer, not an
// operator. `delivered@resend.dev` is Resend's test recipient — a real,
// listable send with no inbox to spam and no sender-reputation hit.
export const UNAUTHORIZED_EMAIL =
  process.env.E2E_UNAUTH_EMAIL || "delivered@resend.dev";

export const RESEND_API_KEY = process.env.RESEND_API_KEY;

export const APP_HOST = new URL(APP).host;
export const AUTH_HOST = new URL(AUTH).host;

// Set E2E_DEBUG=1 to trace each leg (no secrets are logged).
export const dbg = process.env.E2E_DEBUG
  ? (...a) => console.log("  [e2e]", ...a)
  : () => {};
