// Read magic-link emails back out of Resend.
//
// The platform sends the sign-in email *through our own Resend account*
// (web/auth/index.mjs → email.send → POST https://api.resend.com/emails).
// So we don't need to receive anything: the "list sent emails" endpoint
// lets us find the email we just triggered and pull its body. The link
// lives in the plain-text body ("Sign in: <url>").
//
// Requires a FULL-ACCESS Resend key — the list endpoint needs read scope,
// which a send-only key does not have (it 401s).

const RESEND_BASE = "https://api.resend.com";

// Matches the magic link the auth app emits:
//   https://auth.rewindjs.com/login/verify?mt=<base64url>
const VERIFY_RE = /https?:\/\/[^\s"'<>]+\/login\/verify\?mt=[A-Za-z0-9_\-=]+/;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function resendGet(apiKey, path) {
  const res = await fetch(`${RESEND_BASE}${path}`, {
    headers: { Authorization: `Bearer ${apiKey}` },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(
      `Resend GET ${path} → ${res.status} ${res.statusText}` +
        (body ? ` — ${body.slice(0, 300)}` : ""),
    );
  }
  return res.json();
}

// Last `limit` emails sent from the account, most-recent first.
export async function listSentEmails(apiKey, limit = 20) {
  const json = await resendGet(apiKey, `/emails?limit=${limit}`);
  return json.data || [];
}

// Full email incl. `html` and `text` bodies.
export async function retrieveEmail(apiKey, id) {
  return resendGet(apiKey, `/emails/${id}`);
}

export function extractMagicLink(email) {
  const hay = [email.text, email.html].filter(Boolean).join("\n");
  const m = hay.match(VERIFY_RE);
  return m ? m[0] : null;
}

// Poll the sent-email list until a fresh magic-link email addressed to
// `to` shows up, then return its verify URL. `sinceMs` (a Date.now() from
// just before we submitted the form) guards against picking up a stale
// link from an earlier run — magic tokens are single-use.
export async function waitForMagicLink(
  apiKey,
  {
    to,
    sinceMs,
    subjectIncludes = "sign-in link",
    timeoutMs = 90_000,
    intervalMs = 2_000,
  },
) {
  const deadline = Date.now() + timeoutMs;
  const wantTo = to.toLowerCase();
  let lastErr = null;
  let attempts = 0;

  while (Date.now() < deadline) {
    attempts++;
    let list = null;
    try {
      list = await listSentEmails(apiKey);
    } catch (e) {
      lastErr = e;
    }

    if (list) {
      const candidates = list
        .filter((e) => {
          const toMatch = (e.to || []).some(
            (addr) => String(addr).toLowerCase() === wantTo,
          );
          const createdMs = e.created_at ? Date.parse(e.created_at) : 0;
          // 5s skew tolerance against the locally-captured `sinceMs`.
          const fresh = !sinceMs || createdMs >= sinceMs - 5_000;
          const subjOk =
            !subjectIncludes ||
            String(e.subject || "")
              .toLowerCase()
              .includes(subjectIncludes.toLowerCase());
          return toMatch && fresh && subjOk;
        })
        .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));

      for (const c of candidates) {
        const full = await retrieveEmail(apiKey, c.id).catch((e) => {
          lastErr = e;
          return null;
        });
        const link = full && extractMagicLink(full);
        if (link) return { link, email: full };
      }
    }

    await sleep(intervalMs);
  }

  throw new Error(
    `No magic-link email for ${to} within ${timeoutMs}ms ` +
      `(${attempts} polls)` +
      (lastErr ? ` — last error: ${lastErr.message}` : ""),
  );
}
