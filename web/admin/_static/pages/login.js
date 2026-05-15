// Login + signup landing. Two modes toggled via the link at the
// bottom: sign in (paste a token, mints a session via /v1/login) or
// sign up (name + email, kicks off the magic-link flow via
// /v1/signup → email → /v1/auth → session). When the server isn't
// configured with a Resend key, /v1/signup returns the magic_link
// directly in the response body so dev + first-customer flows work
// without email plumbing — we surface it as a clickable link.

import { ApiError } from "../api.js";

export function render(root, { goto, api }) {
  const wrap = document.createElement("div");
  wrap.className = "login";
  wrap.innerHTML = `
    <h1>rove admin</h1>

    <section class="login-mode" data-mode="signin">
      <p>Paste the bootstrap root token issued to js-worker.</p>
      <form class="login-form">
        <label>
          <span>Token</span>
          <input type="password" name="token" autocomplete="off" required minlength="32" maxlength="128" spellcheck="false">
        </label>
        <button type="submit">Sign in</button>
        <p class="error" hidden></p>
      </form>
      <p class="mode-toggle">
        Need an account? <a href="#" data-target="signup">Create one</a>.
      </p>
    </section>

    <section class="login-mode" data-mode="signup" hidden>
      <p>Pick an instance name and we'll email you a sign-in link.</p>
      <form class="signup-form">
        <label>
          <span>Instance name</span>
          <input type="text" name="name" autocomplete="off" required
                 minlength="1" maxlength="32"
                 pattern="[a-z0-9][a-z0-9-]*"
                 title="lowercase letters, digits, and dashes; must start with a letter or digit"
                 spellcheck="false">
        </label>
        <label>
          <span>Email</span>
          <input type="email" name="email" autocomplete="email" required>
        </label>
        <button type="submit">Create account</button>
        <p class="error" hidden></p>
        <p class="success" hidden></p>
      </form>
      <p class="mode-toggle">
        Already have a token? <a href="#" data-target="signin">Sign in</a>.
      </p>
    </section>
  `;

  // ── Mode toggle ──────────────────────────────────────────────────
  const modes = wrap.querySelectorAll(".login-mode");
  function showMode(target) {
    for (const m of modes) m.hidden = m.dataset.mode !== target;
    const focusEl = wrap.querySelector(
      `.login-mode[data-mode="${target}"] input:not([hidden])`,
    );
    if (focusEl) focusEl.focus();
  }
  for (const link of wrap.querySelectorAll("a[data-target]")) {
    link.addEventListener("click", (ev) => {
      ev.preventDefault();
      showMode(link.dataset.target);
    });
  }

  // ── Sign in ──────────────────────────────────────────────────────
  const signinForm = wrap.querySelector(".login-form");
  const tokenInput = signinForm.querySelector("input[name=token]");
  const signinSubmit = signinForm.querySelector("button[type=submit]");
  const signinError = signinForm.querySelector(".error");

  function showSigninError(msg) {
    signinError.textContent = msg;
    signinError.hidden = false;
  }

  signinForm.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    signinError.hidden = true;
    const token = tokenInput.value.trim();
    if (token.length < 32 || token.length > 128) {
      showSigninError("Token must be 32–128 characters.");
      return;
    }
    signinSubmit.disabled = true;
    try {
      await api.login(token);
      goto("#/instances");
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        showSigninError("Server rejected the token.");
      } else {
        showSigninError(`Sign-in failed: ${err.message}`);
      }
      signinSubmit.disabled = false;
    }
  });

  // ── Sign up ──────────────────────────────────────────────────────
  const signupForm = wrap.querySelector(".signup-form");
  const nameInput = signupForm.querySelector("input[name=name]");
  const emailInput = signupForm.querySelector("input[name=email]");
  const signupSubmit = signupForm.querySelector("button[type=submit]");
  const signupError = signupForm.querySelector(".error");
  const signupSuccess = signupForm.querySelector(".success");

  function showSignupError(msg) {
    signupError.textContent = msg;
    signupError.hidden = false;
    signupSuccess.hidden = true;
  }

  function showSignupSuccess(html) {
    signupSuccess.innerHTML = html;
    signupSuccess.hidden = false;
    signupError.hidden = true;
  }

  signupForm.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    signupError.hidden = true;
    signupSuccess.hidden = true;
    const name = nameInput.value.trim().toLowerCase();
    const email = emailInput.value.trim();
    if (!name || !email) {
      showSignupError("Both fields are required.");
      return;
    }
    signupSubmit.disabled = true;
    try {
      const res = await api.signup(name, email);
      // Server sends `magic_link` only when no Resend key is
      // configured (dev / first-customer mode). Either way, the
      // account is provisioned and the next step is the auth click.
      if (res && res.magic_link) {
        showSignupSuccess(
          `Account <code>${escapeText(name)}</code> ready. ` +
          `Email isn't configured on this server — ` +
          `<a href="${escapeAttr(res.magic_link)}">click here to sign in</a>.`,
        );
      } else {
        showSignupSuccess(
          `Check <code>${escapeText(email)}</code> for a sign-in link. ` +
          `Account <code>${escapeText(name)}</code> is ready.`,
        );
      }
      // Disable the form on success so the customer can't double-submit
      // and end up generating a second magic link.
      nameInput.disabled = true;
      emailInput.disabled = true;
    } catch (err) {
      if (err instanceof ApiError) {
        if (err.status === 409) {
          showSignupError("That instance name isn't available — try another.");
        } else if (err.status === 400) {
          showSignupError("That email looks invalid.");
        } else {
          showSignupError(`Sign-up failed (${err.status}): ${err.message}`);
        }
      } else {
        showSignupError(`Sign-up failed: ${err.message}`);
      }
      signupSubmit.disabled = false;
    }
  });

  // Default to sign in (preserves existing UX for token holders).
  tokenInput.focus();

  root.appendChild(wrap);
}

// Minimal text + attribute escapers so customer-supplied name/email
// strings can't smuggle markup into the success message.
function escapeText(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
function escapeAttr(s) {
  return escapeText(s).replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
